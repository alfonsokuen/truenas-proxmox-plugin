#!/bin/bash
# Minimal reproduction: does deleting a middle snapshot break the chain?
#
# Observed once on a three-disk guest: qm delsnapshot on the middle of a
# three-snapshot chain returned success, and afterwards one disk's newest
# snapshot still referenced the volume that had just been removed. Rolling back
# and deleting the remaining snapshots both failed from then on, and the VM was
# left locked with a half-deleted snapshot in its config.
#
# One observation on one guest is not a finding. This strips everything that
# could be incidental - no operating system, no boot, no I/O, no filesystem -
# down to: create a VM with N disks, take three snapshots, delete the middle
# one, and read the backing chain of every disk. If the chain is intact for
# N=1 and broken for N=3, the disk count is the trigger and that is worth
# telling people. If it never breaks here, that is NOT a refutation: this strips
# out the guest I/O, the filesystem and the data that the failing run had, so a
# clean result only rules out "the disk count alone is enough". Say that, and
# leave the hypothesis open.
#
#   i32-snapchain-repro.sh <storage> <vmid> <ndisks>

set -uo pipefail

STORAGE="${1:-}"; VMID="${2:-}"; NDISKS="${3:-3}"; RUNNING="${4:-stopped}"
[ -n "$STORAGE" ] && [ -n "$VMID" ] || { echo "usage: $0 <storage> <vmid> <ndisks> [running]" >&2; exit 2; }
case "$VMID" in 999[0-9]) ;; *) echo "refusing: $VMID outside scratch range" >&2; exit 2 ;; esac
qm status "$VMID" >/dev/null 2>&1 && { echo "refusing: VM $VMID exists" >&2; exit 2; }

BROKEN=0
INCONCLUSIVE=0
say() { echo ""; echo "--- $* ---"; }

# The chain inspector reads LVs out of a volume group. That group used to be
# hardcoded, while the storage was a free parameter - so pointing this at any
# other storage listed zero LVs, iterated over nothing, and printed "the chain
# survives" without having read a single qcow2 header. A detector that can only
# ever say "intact" is not evidence, so it now has to find its VG or say so.
VG="$(awk -v s="$STORAGE" '
    $1 == "lvm:" && $2 == s { inblk = 1; next }
    /^[a-z]+:/ { inblk = 0 }
    inblk && $1 == "vgname" { print $2; exit }
' /etc/pve/storage.cfg 2>/dev/null)"

cleanup() {
    qm stop "$VMID" >/dev/null 2>&1; sleep 2
    qm unlock "$VMID" >/dev/null 2>&1
    qm destroy "$VMID" --purge --destroy-unreferenced-disks 1 >/dev/null 2>&1
    # A half-deleted chain can leave LVs the destroy does not claim.
    for l in $(lvs --noheadings -o lv_name ${VG:-} 2>/dev/null | grep -- "-$VMID-" | tr -d " "); do
        lvremove -f "$VG/$l" >/dev/null 2>&1 && echo "    LV huerfano borrado: $l"
    done
}
trap cleanup EXIT

echo "=== reproduccion con $NDISKS disco(s), VM $VMID ==="
qm create "$VMID" --name "i32-repro-$VMID" --memory 512 --cores 1 \
    --scsihw virtio-scsi-single >/dev/null 2>&1 || { echo "qm create fallo" >&2; exit 1; }
for i in $(seq 0 $(( NDISKS - 1 ))); do
    qm set "$VMID" --scsi$i "$STORAGE:1" >/dev/null 2>&1 || { echo "no se pudo añadir scsi$i" >&2; exit 1; }
done
echo "  discos: $(qm config "$VMID" | grep -c '^scsi[0-9]')"

# With the VM running, deleting a layer goes through qemu's live block-commit
# rather than a plain qemu-img commit on a closed file. Different code, and the
# only difference between this and the run where the chain broke.
if [ "$RUNNING" = running ]; then
    qm set "$VMID" --boot order= >/dev/null 2>&1
    if qm start "$VMID" >/dev/null 2>&1; then
        sleep 5
        echo "  VM ARRANCADA (sin disco de arranque; qemu tiene los discos abiertos)"
    else
        echo "  no se pudo arrancar, se sigue en frio"
        RUNNING=stopped
    fi
else
    echo "  VM parada"
fi

for s in s1 s2 s3; do
    if qm snapshot "$VMID" "$s" >/dev/null 2>&1; then
        echo "  snapshot $s creado"
    else
        echo "  FALLO creando $s"; BROKEN=1
    fi
done

say "cadena antes de borrar nada"
lvs --noheadings -o lv_name ${VG:-} 2>/dev/null | grep -- "-$VMID-" | tr -d " " | sort | sed 's/^/    /'

say "borrando el snapshot INTERMEDIO s2"
if qm delsnapshot "$VMID" s2 >/tmp/i32-repro-del.log 2>&1; then
    echo "    qm delsnapshot s2 devolvio EXITO"
else
    echo "    qm delsnapshot s2 devolvio FALLO:"
    grep -v 'older storage API' /tmp/i32-repro-del.log | tail -3 | sed 's/^/      /'
fi

say "que quedo, y a que apunta cada cosa"
DANGLING=0
if [ -z "$VG" ]; then
    echo "    no se pudo deducir el grupo de volumenes de '$STORAGE'"
    echo "    esta reproduccion NO puede concluir nada sobre la cadena"
    INCONCLUSIVE=1
else
    CHAIN="$(lvs --noheadings -o lv_name "$VG" 2>/dev/null | grep -- "-$VMID-" | tr -d ' ' | sort)"
    if [ -z "$CHAIN" ]; then
        echo "    0 LV encontrados en $VG para la VM $VMID: INCONCLUSO"
        INCONCLUSIVE=1
    fi
    for l in $CHAIN; do
        # PVE leaves snapshot LVs deactivated, so qemu-img cannot open them.
        # Treating that failure as "no backing file" is what turned a broken
        # chain into a clean bill of health.
        lvchange -ay "$VG/$l" >/dev/null 2>&1
        if ! info="$(qemu-img info "/dev/$VG/$l" 2>&1)"; then
            echo "    $l  ->  no se pudo leer la cabecera: INCONCLUSO"
            echo "$info" | tail -1 | sed 's/^/          /'
            INCONCLUSIVE=1
            continue
        fi
        bf="$(echo "$info" | sed -n 's/^backing file: \([^ ]*\).*/\1/p')"
        if [ -z "$bf" ]; then
            echo "    $l  (sin respaldo)"
        elif [ -e "/dev/$VG/$bf" ] || [ -e "$bf" ]; then
            echo "    $l  ->  $bf"
        else
            echo "    $l  ->  $bf   *** NO EXISTE ***"
            DANGLING=$(( DANGLING + 1 ))
            BROKEN=1
        fi
    done
fi

say "consecuencias practicas"
for op in "rollback s3" "delsnapshot s3" "delsnapshot s1"; do
    set -- $op
    if qm "$1" "$VMID" "$2" >/tmp/i32-repro-op.log 2>&1; then
        echo "    qm $1 $2: funciona"
    else
        echo "    qm $1 $2: FALLA -> $(grep -v 'older storage API' /tmp/i32-repro-op.log | tail -1)"
        BROKEN=1
    fi
    qm unlock "$VMID" >/dev/null 2>&1
done

say "estado final de la config"
grep -E '^(lock|parent|snapstate|unused)' "/etc/pve/qemu-server/$VMID.conf" 2>/dev/null | sed 's/^/    /' || echo "    (sin anomalias)"

echo ""
if [ "$BROKEN" != 0 ]; then
    echo "=== $NDISKS disco(s): CADENA ROTA ($DANGLING referencia(s) colgante(s)) ==="
    exit 1
elif [ "$INCONCLUSIVE" != 0 ]; then
    # "No encontre nada" y "no pude mirar" no son la misma respuesta, y solo una
    # de las dos puede retirar una hipotesis.
    echo "=== $NDISKS disco(s): INCONCLUSO - no se pudo inspeccionar la cadena ==="
    echo "    Esto NO es evidencia de que la cadena este sana."
    exit 3
else
    echo "=== $NDISKS disco(s): la cadena sobrevive al borrado del intermedio ==="
    exit 0
fi
