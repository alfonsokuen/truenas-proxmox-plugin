#!/bin/bash
# Does the data survive everything PVE does to a disk after it is created?
#
# i32-qcow.sh covers the format and the snapshot chain. This covers the rest of
# the operations a production VM actually goes through, and each one is checked
# the same way: write a pattern that can be regenerated from (seed, offset), do
# the operation, read every block back and compare. A clone that reports success
# and a clone that copied the data are not the same claim.
#
#   L1  resize      grow the disk and confirm what was already there is untouched
#   L2  full clone  the copy carries the data, and the original still does too
#   L3  backup      vzdump then restore into a new VM, compared block by block
#   L4  move disk   to another storage and back, compared after each hop
#   L5  template    convert, linked clone, and confirm writing to the clone
#                   cannot reach the base image underneath it
#
#   i32-lifecycle.sh --storage <sid> --vmid <9990-9996> [--size GiB] \
#                    [--alt <sid>] [--backup <sid>] [--phases L1,...] --yes
#
# Uses VMID and the three that follow it. All four must be in the scratch range.

set -uo pipefail

STORAGE=""; VMID=""; SIZE=4; GROW=2; ALT="local-zfs"; BKP="local"
PHASES="L1,L2,L3,L4,L5"; YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --storage) STORAGE="$2"; shift 2 ;;
        --vmid)    VMID="$2";    shift 2 ;;
        --size)    SIZE="$2";    shift 2 ;;
        --alt)     ALT="$2";     shift 2 ;;
        --backup)  BKP="$2";     shift 2 ;;
        --phases)  PHASES="$2";  shift 2 ;;
        --yes)     YES=1;        shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$STORAGE" ] || [ -z "$VMID" ]; then
    echo "usage: $0 --storage <sid> --vmid <9990-9996> [--size GiB] [--alt <sid>] [--backup <sid>] --yes" >&2
    exit 2
fi
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 2; }

CLONE=$(( VMID + 1 ))
LINKED=$(( VMID + 2 ))
RESTORE=$(( VMID + 3 ))
for v in "$VMID" "$CLONE" "$LINKED" "$RESTORE"; do
    case "$v" in
        999[0-9]) ;;
        *) echo "refusing: $v is outside the scratch range 9990-9999" >&2; exit 2 ;;
    esac
done

BV="$(dirname "$0")/i32-blockverify.pl"
[ -x "$BV" ] || { echo "missing $BV" >&2; exit 2; }

SEED_A=$(( VMID * 100 + 11 ))
SEED_B=$(( VMID * 100 + 22 ))
PAT_MIB=2048
NBD=""
LOADED_NBD=0
FAILURES=0
SUMMARY=()
BACKUP_VOLID=""

say()  { echo ""; echo "=== $* ==="; }
note() { echo "    $*"; }
pass() { SUMMARY+=("PASS  $*"); note "PASS  $*"; }
fail() { SUMMARY+=("FALLO $*"); note "FALLO $*"; FAILURES=$(( FAILURES + 1 )); }
skip() { SUMMARY+=("--    $*"); note "--    $*"; }
has_phase() { case ",$PHASES," in *",$1,"*) return 0 ;; *) return 1 ;; esac }

activate_vol() {
    perl -e 'use PVE::Storage;
             my $cfg = PVE::Storage::config();
             eval { PVE::Storage::activate_volumes($cfg, [ $ARGV[0] ]) };' "$1" 2>/dev/null || true
}

volid_of() { qm config "$1" 2>/dev/null | sed -n 's/^scsi0: \([^,]*\).*/\1/p'; }

nbd_attach() {
    local path="$1" fmt="$2" i w
    for i in 0 1 2 3 4 5 6 7; do
        if [ ! -e "/sys/block/nbd$i/pid" ]; then
            if qemu-nbd --connect="/dev/nbd$i" --format="$fmt" --cache=none "$path" 2>/dev/null; then
                NBD="/dev/nbd$i"
                for w in 1 2 3 4 5 6 7 8 9 10; do
                    [ "$(blockdev --getsize64 "$NBD" 2>/dev/null || echo 0)" -gt 0 ] && return 0
                    sleep 0.3
                done
                return 0
            fi
        fi
    done
    NBD=""
    return 1
}

nbd_detach() {
    [ -n "$NBD" ] || return 0
    sync
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
    NBD=""
}

# A volume can be qcow2 on an LV here and a raw zvol over there. Opening it the
# wrong way would read metadata as data and report damage that is not there, so
# the format is asked for rather than assumed.
open_vol() {
    local volid="$1" p fmt
    activate_vol "$volid"
    p="$(pvesm path "$volid" 2>/dev/null)" || return 1
    [ -n "$p" ] || return 1
    fmt="$(qemu-img info "$p" 2>/dev/null | sed -n 's/^file format: //p' | head -1)"
    case "$fmt" in
        qcow2) nbd_attach "$p" qcow2 || return 1; OPENED="$NBD"; OPENED_NBD=1 ;;
        *)     OPENED="$p"; OPENED_NBD=0 ;;
    esac
    OPENED_FMT="${fmt:-raw}"
    return 0
}
close_vol() { [ "${OPENED_NBD:-0}" = 1 ] && nbd_detach; OPENED=""; OPENED_NBD=0; }

write_pattern() {
    local volid="$1" mib="$2" seed="$3"
    open_vol "$volid" || return 1
    "$BV" write "$OPENED" "$(( mib * 1024 * 1024 ))" "$seed" >/dev/null 2>&1
    local rc=$?
    sync
    close_vol
    return $rc
}

# label, volid, mib, seed -> pass/fail. Every phase ends in one of these.
check_pattern() {
    local label="$1" volid="$2" mib="$3" seed="$4" out rc
    if ! open_vol "$volid"; then
        fail "$label: no se pudo abrir $volid para verificar"
        return 1
    fi
    note "  verificando $volid ($OPENED_FMT, ${mib} MiB, semilla $seed)"
    out="$("$BV" verify "$OPENED" "$(( mib * 1024 * 1024 ))" "$seed" 2>&1)"
    rc=$?
    close_vol
    if [ "$rc" = 0 ]; then
        pass "$label"
        return 0
    fi
    echo "$out" | sed 's/^/      /' | head -10
    fail "$label"
    return 1
}

cleanup_all() {
    nbd_detach
    for v in "$LINKED" "$RESTORE" "$CLONE" "$VMID"; do
        if qm status "$v" >/dev/null 2>&1; then
            qm destroy "$v" --purge --destroy-unreferenced-disks 1 >/dev/null 2>&1 || true
        fi
    done
    [ -n "$BACKUP_VOLID" ] && pvesm free "$BACKUP_VOLID" >/dev/null 2>&1
    if [ "$LOADED_NBD" = 1 ]; then
        modprobe -r nbd >/dev/null 2>&1 || true
    fi
}
trap 'nbd_detach' EXIT

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

say "preflight"
note "nodo      : $(hostname)"
note "storage   : $STORAGE   alterno: $ALT   backup: $BKP"
note "vmids     : base $VMID, clon $CLONE, enlazado $LINKED, restaurado $RESTORE"
note "disco     : ${SIZE} GiB -> +${GROW} GiB, patron ${PAT_MIB} MiB, semillas ${SEED_A}/${SEED_B}"

for v in "$VMID" "$CLONE" "$LINKED" "$RESTORE"; do
    if qm status "$v" >/dev/null 2>&1; then
        echo "refusing: VM $v already exists" >&2; exit 2
    fi
    if pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | grep -q "\"vmid\":$v,"; then
        echo "refusing: VMID $v is in use in the cluster" >&2; exit 2
    fi
    n="$(pvesm list "$STORAGE" 2>/dev/null | awk -v x="$v" '$1 ~ ("(vm|base)-" x "-")' | wc -l)"
    if [ "$n" -gt 0 ]; then
        echo "refusing: $n leftover volume(s) for $v on $STORAGE" >&2; exit 2
    fi
done
note "los cuatro vmids libres y sin restos"

nbd_loaded() { [ -d /sys/module/nbd ]; }
if ! nbd_loaded; then
    modprobe nbd max_part=0 nbds_max=8 2>/dev/null && LOADED_NBD=1
    for t in 1 2 3 4 5; do nbd_loaded && break; sleep 0.4; done
fi
nbd_loaded || { echo "refusing: cannot load the nbd module" >&2; exit 2; }

if [ "$YES" != 1 ]; then
    echo ""
    echo "Crea hasta 4 VMs de prueba y las destruye al terminar. Relanza con --yes."
    exit 0
fi

trap cleanup_all EXIT

# ---------------------------------------------------------------------------
# L0 - the disk everything else is built from
# ---------------------------------------------------------------------------

say "L0 - disco base con patron conocido"
if qm create "$VMID" --name "i32-life-$VMID" --memory 512 --cores 1 \
       --scsihw virtio-scsi-single --scsi0 "$STORAGE:$SIZE" >/dev/null 2>&1; then
    pass "L0: VM $VMID creada con disco de ${SIZE} GiB"
else
    fail "L0: qm create fallo - no hay nada que probar"
    say "resumen"; echo "  abortado"; exit 1
fi
BASEVOL="$(volid_of "$VMID")"
note "volumen base: $BASEVOL"
if write_pattern "$BASEVOL" "$PAT_MIB" "$SEED_A"; then
    pass "L0: patron de ${PAT_MIB} MiB escrito"
else
    fail "L0: no se pudo escribir el patron"
fi
check_pattern "L0: el disco base lee lo que se le escribio" "$BASEVOL" "$PAT_MIB" "$SEED_A"

# ---------------------------------------------------------------------------
# L1 - resize
# ---------------------------------------------------------------------------

if has_phase L1; then
    say "L1 - crecer el disco"
    before=""
    if open_vol "$BASEVOL"; then
        before="$(blockdev --getsize64 "$OPENED" 2>/dev/null)"
        close_vol
    fi
    note "tamano antes: $before bytes"
    if qm resize "$VMID" scsi0 "+${GROW}G" >/dev/null 2>&1; then
        pass "L1: qm resize +${GROW}G aceptado"
    else
        fail "L1: qm resize fallo"
    fi
    after=""
    if open_vol "$BASEVOL"; then
        after="$(blockdev --getsize64 "$OPENED" 2>/dev/null)"
        close_vol
    fi
    note "tamano despues: $after bytes"
    want=$(( before + GROW * 1024 * 1024 * 1024 ))
    if [ "${after:-0}" = "$want" ]; then
        pass "L1: el dispositivo crecio exactamente ${GROW} GiB"
    else
        fail "L1: se esperaban $want bytes y hay ${after:-0}"
    fi
    check_pattern "L1: crecer el disco no toca los datos que ya estaban" "$BASEVOL" "$PAT_MIB" "$SEED_A"
fi

# ---------------------------------------------------------------------------
# L2 - full clone
# ---------------------------------------------------------------------------

if has_phase L2; then
    say "L2 - clon completo"
    if qm clone "$VMID" "$CLONE" --name "i32-clone-$CLONE" --full 1 --storage "$STORAGE" >/dev/null 2>&1; then
        pass "L2: qm clone --full completado"
        CLONEVOL="$(volid_of "$CLONE")"
        note "volumen clon: $CLONEVOL"
        check_pattern "L2: el clon lleva los datos, no solo la configuracion" "$CLONEVOL" "$PAT_MIB" "$SEED_A"
        check_pattern "L2: el original sigue intacto tras clonarlo" "$BASEVOL" "$PAT_MIB" "$SEED_A"
    else
        fail "L2: qm clone --full fallo"
    fi
fi

# ---------------------------------------------------------------------------
# L3 - backup and restore
# ---------------------------------------------------------------------------

if has_phase L3; then
    say "L3 - copia de seguridad y restauracion"
    if vzdump "$VMID" --storage "$BKP" --mode stop --compress zstd --notes-template "i32 lifecycle" >/tmp/i32-vzdump.log 2>&1; then
        pass "L3: vzdump completado a $BKP"
    else
        fail "L3: vzdump fallo"
        tail -5 /tmp/i32-vzdump.log | sed 's/^/      /'
    fi
    BACKUP_VOLID="$(pvesm list "$BKP" --content backup 2>/dev/null | awk -v v="$VMID" '$1 ~ ("qemu-" v "-")' | awk '{print $1}' | tail -1)"
    note "backup    : ${BACKUP_VOLID:-ninguno}"
    if [ -n "$BACKUP_VOLID" ]; then
        BACKUP_FILE="$(pvesm path "$BACKUP_VOLID" 2>/dev/null)"
        note "ruta      : $BACKUP_FILE"
        note "tamano    : $(du -h "$BACKUP_FILE" 2>/dev/null | cut -f1)"
        if qmrestore "$BACKUP_FILE" "$RESTORE" --storage "$STORAGE" >/tmp/i32-restore.log 2>&1; then
            pass "L3: qmrestore creo la VM $RESTORE"
            RESTVOL="$(volid_of "$RESTORE")"
            note "volumen restaurado: $RESTVOL"
            check_pattern "L3: lo restaurado es byte a byte lo que se respaldo" "$RESTVOL" "$PAT_MIB" "$SEED_A"
        else
            fail "L3: qmrestore fallo"
            tail -5 /tmp/i32-restore.log | sed 's/^/      /'
        fi
    else
        fail "L3: no aparece ningun archivo de backup para $VMID en $BKP"
    fi
fi

# ---------------------------------------------------------------------------
# L4 - move the disk to another storage and back
# ---------------------------------------------------------------------------

if has_phase L4; then
    say "L4 - mover el disco entre almacenamientos"
    if ! qm status "$CLONE" >/dev/null 2>&1; then
        skip "L4: no hay clon $CLONE que mover"
    else
        if qm move-disk "$CLONE" scsi0 "$ALT" --delete 1 >/tmp/i32-move1.log 2>&1; then
            pass "L4: disco movido a $ALT"
            MV1="$(volid_of "$CLONE")"
            note "ahora en : $MV1"
            check_pattern "L4: los datos sobreviven al salto a $ALT" "$MV1" "$PAT_MIB" "$SEED_A"
        else
            fail "L4: qm move-disk a $ALT fallo"
            tail -5 /tmp/i32-move1.log | sed 's/^/      /'
        fi
        if qm move-disk "$CLONE" scsi0 "$STORAGE" --delete 1 >/tmp/i32-move2.log 2>&1; then
            pass "L4: disco devuelto a $STORAGE"
            MV2="$(volid_of "$CLONE")"
            note "ahora en : $MV2"
            check_pattern "L4: y sobreviven tambien a la vuelta" "$MV2" "$PAT_MIB" "$SEED_A"
        else
            fail "L4: qm move-disk de vuelta a $STORAGE fallo"
            tail -5 /tmp/i32-move2.log | sed 's/^/      /'
        fi
    fi
fi

# ---------------------------------------------------------------------------
# L5 - template and linked clone
# ---------------------------------------------------------------------------

if has_phase L5; then
    say "L5 - plantilla y clon enlazado"
    if qm template "$VMID" >/tmp/i32-tpl.log 2>&1; then
        pass "L5: qm template convirtio $VMID en plantilla"
        TPLVOL="$(volid_of "$VMID")"
        note "volumen plantilla: $TPLVOL"
        check_pattern "L5: convertir en plantilla no altera los datos" "$TPLVOL" "$PAT_MIB" "$SEED_A"

        if qm clone "$VMID" "$LINKED" --name "i32-linked-$LINKED" >/tmp/i32-linked.log 2>&1; then
            pass "L5: clon enlazado creado"
            LNKVOL="$(volid_of "$LINKED")"
            note "volumen enlazado: $LNKVOL"
            activate_vol "$LNKVOL"
            qemu-img info --backing-chain "$(pvesm path "$LNKVOL")" 2>/dev/null \
                | grep -E '^(image|backing file|file format):' | sed 's/^/      /' || true

            check_pattern "L5: el clon enlazado lee los datos de la plantilla" "$LNKVOL" "$PAT_MIB" "$SEED_A"

            # The point of the phase. Writing into the clone must land in the
            # clone's own layer; if it reached the base, every other clone of
            # that template would be silently corrupted too.
            note "escribiendo la semilla $SEED_B en el clon enlazado..."
            write_pattern "$LNKVOL" 512 "$SEED_B"
            check_pattern "L5: escribir en el clon no toca la plantilla de debajo" "$TPLVOL" "$PAT_MIB" "$SEED_A"
        else
            reason="$(tail -2 /tmp/i32-linked.log | tr '\n' ' ')"
            skip "L5: el almacenamiento no admite clones enlazados: $reason"
        fi
    else
        fail "L5: qm template fallo"
        tail -5 /tmp/i32-tpl.log | sed 's/^/      /'
    fi
fi

# ---------------------------------------------------------------------------
# teardown
# ---------------------------------------------------------------------------

say "limpieza"
nbd_detach
for v in "$LINKED" "$RESTORE" "$CLONE" "$VMID"; do
    if qm status "$v" >/dev/null 2>&1; then
        if qm destroy "$v" --purge --destroy-unreferenced-disks 1 >/dev/null 2>&1; then
            note "VM $v destruida"
        else
            fail "limpieza: no se pudo destruir la VM $v"
        fi
    fi
done
if [ -n "$BACKUP_VOLID" ]; then
    if pvesm free "$BACKUP_VOLID" >/dev/null 2>&1; then
        note "backup $BACKUP_VOLID borrado"
    else
        fail "limpieza: no se pudo borrar el backup $BACKUP_VOLID"
    fi
fi
BACKUP_VOLID=""
leftover=0
for v in "$VMID" "$CLONE" "$LINKED" "$RESTORE"; do
    for s in "$STORAGE" "$ALT"; do
        n="$(pvesm list "$s" 2>/dev/null | awk -v x="$v" '$1 ~ ("(vm|base)-" x "-")' | wc -l)"
        leftover=$(( leftover + n ))
        [ "$n" -gt 0 ] && pvesm list "$s" | awk -v x="$v" '$1 ~ ("(vm|base)-" x "-")' | sed 's/^/      /'
    done
done
if [ "$leftover" = 0 ]; then
    pass "limpieza: no queda ningun volumen de las VMs de prueba"
else
    fail "limpieza: quedan $leftover volumen(es) sueltos"
fi

say "resumen"
i=0
while [ "$i" -lt "${#SUMMARY[@]}" ]; do
    echo "  ${SUMMARY[$i]}"
    i=$(( i + 1 ))
done
echo ""
if [ "$FAILURES" = 0 ]; then
    echo "  Los datos sobreviven a crecer, clonar, respaldar, restaurar, mover"
    echo "  de almacenamiento y convertir en plantilla, verificados bloque a bloque."
else
    echo "  $FAILURES comprobacion(es) fallidas - arriba esta cual."
fi
exit "$FAILURES"
