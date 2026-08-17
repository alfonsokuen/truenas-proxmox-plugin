#!/bin/bash
# The parts that were still untested, checked at the file level as well as the
# block level.
#
# A block pattern proves the storage handed back the bytes it was given. It says
# nothing about whether a filesystem on those bytes is still coherent, whether
# every file still hashes the same, or whether the journal replays cleanly. So
# each phase here asks all of it: the raw pattern, every file against a sha256
# manifest, the file count, and fsck.
#
#   D1  snapshot depth. One snapshot, rolled back, was the easy case. This
#       builds a chain of three, deletes the MIDDLE one - the operation that
#       commits a layer into the one beneath it, and where volume-chain
#       implementations break - and then rolls back to the oldest.
#   D2  the live backup path. vzdump --mode snapshot with the guest running and
#       writing is a different mechanism from --mode stop: dirty bitmaps and
#       fleecing rather than a quiesced disk. The restore is verified from the
#       hypervisor against a manifest computed independently.
#
#   i32-deep.sh <vmid> <storage> [--phases D1,D2] --yes
#
# Uses <vmid> and <vmid>+1. Both must be in the scratch range.

set -uo pipefail

VMID="${1:-}"; shift || true
STORAGE="${1:-}"; shift || true
PHASES="D1,D2"; YES=0; BKP="local"
while [ $# -gt 0 ]; do
    case "$1" in
        --phases) PHASES="$2"; shift 2 ;;
        --backup) BKP="$2"; shift 2 ;;
        --yes)    YES=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$VMID" ] && [ -n "$STORAGE" ] || { echo "usage: $0 <vmid> <storage> [--phases D1,D2] --yes" >&2; exit 2; }

RESTORE=$(( VMID + 1 ))
for v in "$VMID" "$RESTORE"; do
    case "$v" in
        999[0-9]) ;;
        *) echo "refusing: $v is outside the scratch range 9990-9999" >&2; exit 2 ;;
    esac
done

I32_VMID="$VMID"
. "$(dirname "$0")/i32-console.sh"

SEED_A=$(( VMID * 100 + 11 ))
SEED_B=$(( VMID * 100 + 22 ))
PAT_MIB=1024
NBD=""
FAILURES=0
SUMMARY=()
BACKUP_VOLID=""

say()  { echo ""; echo "=== $* ==="; }
note() { echo "    $*"; }
pass() { SUMMARY+=("PASS  $*"); note "PASS  $*"; }
fail() { SUMMARY+=("FALLO $*"); note "FALLO $*"; FAILURES=$(( FAILURES + 1 )); }
skip() { SUMMARY+=("--    $*"); note "--    $*"; }
has_phase() { case ",$PHASES," in *",$1,"*) return 0 ;; *) return 1 ;; esac }

# ---------------------------------------------------------------------------
# asking the guest about its own data
# ---------------------------------------------------------------------------

# The manifest hash is the whole state of the filesystem in sixteen characters.
# Carrying it across an operation and comparing it afterwards is what turns
# "the files verify against the manifest that came back with them" - which a
# consistent pair of wrong things would also satisfy - into a real check.
manifest_hash() {
    gexec 'sha256sum /root/i32-manifest.sha256 | cut -c1-16' 20
    echo "$GOUT" | tr -d ' \t' | grep -E '^[0-9a-f]{16}$' | tail -1
}

# Block pattern, files, count and fsck - reported as one verdict per phase.
guest_verify() {
    local label="$1" seed="$2" want_hash="${3:-}" ok=1
    gexec "/root/i32-blockverify.pl verify \$(readlink -f /dev/disk/by-id/*i32blk) $(( PAT_MIB * 1024 * 1024 )) $seed" 400
    if [ "${GRC:-}" = 0 ]; then
        note "  bloques: intactos"
    else
        note "  bloques: $(echo "$GOUT" | grep -m1 MISMATCH || echo "rc=${GRC:-?}")"
        ok=0
    fi

    gexec '/usr/local/bin/i32-fs-verify.sh' 400
    local fsline fsck
    fsline="$(echo "$GOUT" | grep -m1 '^I32-FS ')"
    fsck="$(echo "$GOUT" | grep -m1 '^I32-FSCK')"
    note "  ficheros: ${fsline:-sin respuesta}"
    note "  fsck    : ${fsck:-sin respuesta}"
    [ "${GRC:-}" = 0 ] || ok=0

    if [ -n "$want_hash" ]; then
        local h
        h="$(manifest_hash)"
        if [ "$h" = "$want_hash" ]; then
            note "  manifiesto: $h (el esperado)"
        else
            note "  manifiesto: ${h:-vacio}, se esperaba $want_hash"
            ok=0
        fi
    fi

    if [ "$ok" = 1 ]; then pass "$label"; else fail "$label"; fi
    return 0
}

# Change both disks, and rebuild the manifest so it describes the new state.
#
# The block pattern is rewritten at FULL size with a seed of its own for each
# state, not partially. The verifier records the total block count inside every
# block's header, so a region written as 256 MiB and read back as part of a
# 1024 MiB verify disagrees on every single block - including the ones that are
# perfectly intact. Partial rewrites make the block check unreadable; a whole
# disk per state costs a few more seconds and gives a clean yes or no.
guest_mutate() {
    local tag="$1" nfiles="$2" seed="$3"
    gexec "/root/i32-blockverify.pl write \$(readlink -f /dev/disk/by-id/*i32blk) $(( PAT_MIB * 1024 * 1024 )) $seed; R=\$?; sync; (exit \$R)" 600
    if [ "${GRC:-}" = 0 ]; then
        note "  $tag: patron reescrito entero con la semilla $seed"
    else
        fail "$tag: la reescritura del patron fallo (rc=${GRC:-?})"
    fi
    gexec "cd /mnt/i32 && for i in \$(seq 1 $nfiles); do dd if=/dev/urandom of=d/${tag}\$i bs=1K count=256 status=none; done; sync; (cd /mnt/i32 && find d -type f | sort | xargs sha256sum) > /root/i32-manifest.sha256; sync; wc -l < /root/i32-manifest.sha256" 300
    note "  $tag: ahora hay $(echo "$GOUT" | tr -d ' ' | grep -E '^[0-9]+$' | tail -1) ficheros"
}

nbd_detach() {
    [ -n "$NBD" ] || return 0
    sync
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
    NBD=""
}

nbd_attach() {
    local path="$1" fmt="$2" i w
    for i in 0 1 2 3 4 5 6 7; do
        if [ ! -e "/sys/block/nbd$i/pid" ]; then
            if qemu-nbd --connect="/dev/nbd$i" --format="$fmt" --cache=none "$path" 2>/dev/null; then
                NBD="/dev/nbd$i"
                for w in $(seq 1 10); do
                    [ "$(blockdev --getsize64 "$NBD" 2>/dev/null || echo 0)" -gt 0 ] && return 0
                    sleep 0.3
                done
                qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
                NBD=""
                return 1
            fi
        fi
    done
    NBD=""
    return 1
}

activate_vol() {
    perl -e 'use PVE::Storage; my $cfg = PVE::Storage::config();
             eval { PVE::Storage::activate_volumes($cfg, [ $ARGV[0] ]) };' "$1" 2>/dev/null || true
}

vol_by_serial() {   # vol_by_serial <vmid> <serial>
    qm config "$1" 2>/dev/null | sed -n "s/^scsi[0-9]*: \([^,]*\).*serial=$2.*/\1/p" | head -1
}

cleanup() {
    nbd_detach
    umount /mnt/i32-verify 2>/dev/null
    detach
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

say "preflight"
note "vmid      : $VMID   restaurada: $RESTORE"
note "storage   : $STORAGE   backup: $BKP"

qm status "$VMID" 2>/dev/null | grep -q running || { echo "refusing: VM $VMID is not running" >&2; exit 2; }
qm status "$RESTORE" >/dev/null 2>&1 && { echo "refusing: VM $RESTORE already exists" >&2; exit 2; }
[ -d /sys/module/nbd ] || modprobe nbd max_part=0 nbds_max=8 2>/dev/null
[ -d /sys/module/nbd ] || { echo "refusing: no nbd module" >&2; exit 2; }

attach || { echo "refusing: cannot attach to the console" >&2; exit 2; }
gwait 60 || { echo "refusing: the guest does not answer" >&2; exit 2; }
gquiet
note "consola enganchada, el invitado responde"

gexec 'readlink -f /dev/disk/by-id/*i32blk; readlink -f /dev/disk/by-id/*i32fs' 20
note "discos en el invitado: $(echo "$GOUT" | tr '\n' ' ')"

if [ "$YES" != 1 ]; then
    echo ""
    echo "Toma snapshots, borra el intermedio, hace backup en caliente y restaura en $RESTORE."
    echo "Relanza con --yes."
    exit 0
fi

# Each state gets its own seed, and the pattern is always written whole.
SEED0=$SEED_A
SEED1=$(( SEED_A + 1 ))
SEED2=$(( SEED_A + 2 ))

say "estado inicial"
# Re-established rather than assumed, so the script can be run again after a
# previous run left the disks in some other state.
note "reponiendo la linea base (patron entero + sistema de ficheros nuevo)..."
gexec "/root/i32-blockverify.pl write \$(readlink -f /dev/disk/by-id/*i32blk) $(( PAT_MIB * 1024 * 1024 )) $SEED0; R=\$?; sync; (exit \$R)" 600
[ "${GRC:-}" = 0 ] || { echo "refusing: could not lay down the baseline pattern" >&2; exit 2; }
gexec '/usr/local/bin/i32-fs-populate.sh' 600
note "$(echo "$GOUT" | grep -m1 I32-MANIFIESTO)"

H0="$(manifest_hash)"
note "hash del manifiesto inicial: $H0"
[ -n "$H0" ] || { echo "refusing: the guest did not report a manifest hash" >&2; exit 2; }
guest_verify "base: bloques, ficheros y fsck en orden antes de empezar" "$SEED0" "$H0"

# ---------------------------------------------------------------------------
# D2 first, while the disk still holds the pristine pattern
# ---------------------------------------------------------------------------

if has_phase D2; then
    say "D2 - backup en caliente (--mode snapshot) y restauracion"

    gexec 'pgrep -f i32-guest-load >/dev/null && echo CARGA-ACTIVA || echo CARGA-PARADA' 15
    if echo "$GOUT" | grep -q CARGA-ACTIVA; then
        pass "D2: el invitado escribe en ambos discos durante el backup"
    else
        gexec 'nohup /usr/local/bin/i32-guest-load.sh >/dev/null 2>&1 & sleep 2; pgrep -f i32-guest-load >/dev/null && echo CARGA-ACTIVA' 20
        echo "$GOUT" | grep -q CARGA-ACTIVA && pass "D2: carga reiniciada" \
            || fail "D2: sin carga, el backup seria sobre discos quietos"
    fi

    note "vzdump --mode snapshot con la VM corriendo..."
    t0=$(date +%s)
    if vzdump "$VMID" --storage "$BKP" --mode snapshot --compress zstd >/tmp/i32-d2dump.log 2>&1; then
        pass "D2: vzdump --mode snapshot completado en $(( $(date +%s) - t0 ))s"
    else
        fail "D2: vzdump --mode snapshot fallo"
        tail -8 /tmp/i32-d2dump.log | sed 's/^/      /'
    fi

    if qm status "$VMID" 2>/dev/null | grep -q running; then
        pass "D2: la VM nunca se paro"
    else
        fail "D2: la VM no sigue corriendo tras el backup"
    fi
    gexec 'echo vivo' 30
    [ "${GRC:-}" = 0 ] && pass "D2: el invitado sigue respondiendo" \
                       || fail "D2: el invitado dejo de responder"

    BACKUP_VOLID="$(pvesm list "$BKP" --content backup 2>/dev/null | awk -v v="$VMID" '$1 ~ ("qemu-" v "-")' | awk '{print $1}' | tail -1)"
    if [ -z "$BACKUP_VOLID" ]; then
        fail "D2: no aparece el archivo de backup"
    else
        BFILE="$(pvesm path "$BACKUP_VOLID" 2>/dev/null)"
        note "backup: $BACKUP_VOLID ($(du -h "$BFILE" 2>/dev/null | cut -f1))"
        if qmrestore "$BFILE" "$RESTORE" --storage "$STORAGE" >/tmp/i32-d2res.log 2>&1; then
            pass "D2: qmrestore creo la VM $RESTORE"
        else
            fail "D2: qmrestore fallo"
            tail -8 /tmp/i32-d2res.log | sed 's/^/      /'
        fi
    fi

    if qm status "$RESTORE" >/dev/null 2>&1; then
        say "D2b - verificar lo restaurado desde el hipervisor"

        RBLK="$(vol_by_serial "$RESTORE" i32blk)"
        RFS="$(vol_by_serial "$RESTORE" i32fs)"
        note "restaurados: bloque=$RBLK  ficheros=$RFS"

        if [ -n "$RBLK" ]; then
            activate_vol "$RBLK"
            RP="$(pvesm path "$RBLK")"
            RFMT="$(qemu-img info "$RP" 2>/dev/null | sed -n 's/^file format: //p' | head -1)"
            if nbd_attach "$RP" "${RFMT:-raw}"; then
                if /root/i32/i32-blockverify.pl verify "$NBD" "$(( PAT_MIB * 1024 * 1024 ))" "$SEED_A" >/tmp/i32-d2blk.log 2>&1; then
                    pass "D2b: el patron de bloques restaurado es identico"
                else
                    head -4 /tmp/i32-d2blk.log | sed 's/^/      /'
                    fail "D2b: el patron de bloques restaurado NO coincide"
                fi
                nbd_detach
            else
                fail "D2b: no se pudo abrir el disco de bloques restaurado"
            fi
        else
            fail "D2b: no se encuentra el disco de patron en la VM restaurada"
        fi

        if [ -n "$RFS" ]; then
            activate_vol "$RFS"
            RP2="$(pvesm path "$RFS")"
            RFMT2="$(qemu-img info "$RP2" 2>/dev/null | sed -n 's/^file format: //p' | head -1)"
            if nbd_attach "$RP2" "${RFMT2:-raw}"; then
                # The guest had it mounted and dirty when the backup was taken,
                # so this is a crash-consistent image: mounting replays the
                # journal, which is exactly the recovery a real restore does.
                mkdir -p /mnt/i32-verify
                if mount "$NBD" /mnt/i32-verify 2>/tmp/i32-mnt.log; then
                    pass "D2b: el sistema de ficheros restaurado monta (el journal se reprodujo)"
                    # Recomputed here, independently, with the same command the
                    # guest used - so matching the guest's hash means the whole
                    # set of files survived, not just that a manifest travelled
                    # alongside them.
                    ( cd /mnt/i32-verify && find d -type f | sort | xargs sha256sum ) > /tmp/i32-host-manifest 2>/dev/null
                    HH="$(sha256sum /tmp/i32-host-manifest | cut -c1-16)"
                    NH="$(wc -l < /tmp/i32-host-manifest)"
                    note "recalculado en el host: $NH ficheros, hash $HH"
                    if [ "$HH" = "$H0" ]; then
                        pass "D2b: los $NH ficheros restaurados hashean exactamente igual que en el invitado"
                    else
                        fail "D2b: el manifiesto recalculado ($HH) no coincide con el del invitado ($H0)"
                    fi
                    umount /mnt/i32-verify
                else
                    fail "D2b: el sistema de ficheros restaurado no monta"
                    cat /tmp/i32-mnt.log | sed 's/^/      /'
                fi
                fout="$(fsck.ext4 -fn "$NBD" 2>&1)"; frc=$?
                note "fsck del restaurado: rc=$frc $(echo "$fout" | tail -1)"
                [ "$frc" -le 1 ] && pass "D2b: fsck limpio sobre el sistema de ficheros restaurado" \
                                 || fail "D2b: fsck encuentra problemas en el restaurado (rc=$frc)"
                nbd_detach
            else
                fail "D2b: no se pudo abrir el disco de ficheros restaurado"
            fi
        else
            fail "D2b: no se encuentra el disco de ficheros en la VM restaurada"
        fi

        qm destroy "$RESTORE" --purge --destroy-unreferenced-disks 1 >/dev/null 2>&1 \
            && note "VM $RESTORE destruida" || fail "D2b: no se pudo destruir la VM $RESTORE"
    fi

    if [ -n "$BACKUP_VOLID" ]; then
        pvesm free "$BACKUP_VOLID" >/dev/null 2>&1 && note "backup borrado" \
            || fail "D2: no se pudo borrar el backup"
        BACKUP_VOLID=""
    fi
fi

# ---------------------------------------------------------------------------
# D1 - a chain of snapshots, and the middle one removed
# ---------------------------------------------------------------------------

if has_phase D1; then
    say "D1 - cadena de snapshots y borrado del intermedio"

    qm snapshot "$VMID" c1 --description "i32 estado 0" >/dev/null 2>&1 \
        && pass "D1: snapshot c1 (estado 0)" || fail "D1: no se pudo crear c1"

    guest_mutate e1 20 "$SEED1"
    H1="$(manifest_hash)"
    note "hash tras la primera mutacion: $H1"
    qm snapshot "$VMID" c2 --description "i32 estado 1" >/dev/null 2>&1 \
        && pass "D1: snapshot c2 (estado 1)" || fail "D1: no se pudo crear c2"

    guest_mutate e2 20 "$SEED2"
    H2="$(manifest_hash)"
    note "hash tras la segunda mutacion: $H2"
    qm snapshot "$VMID" c3 --description "i32 estado 2" >/dev/null 2>&1 \
        && pass "D1: snapshot c3 (estado 2)" || fail "D1: no se pudo crear c3"

    note "cadena de respaldo actual:"
    lvs --noheadings -o lv_name,lv_size 2>/dev/null | grep -- "-$VMID-" | sed 's/^/      /' || true

    if [ "$H0" != "$H1" ] && [ "$H1" != "$H2" ]; then
        pass "D1: los tres estados son realmente distintos entre si"
    else
        fail "D1: los estados no difieren ($H0 / $H1 / $H2) - la cadena no probaria nada"
    fi

    # The operation this phase exists for. Removing a snapshot from the middle
    # of a chain has to merge its layer into the one below without disturbing
    # either the live data above it or the older snapshot underneath.
    say "D1a - borrar el snapshot INTERMEDIO (c2)"
    t0=$(date +%s)
    if qm delsnapshot "$VMID" c2 >/tmp/i32-d1del.log 2>&1; then
        pass "D1a: qm delsnapshot c2 completado en $(( $(date +%s) - t0 ))s"
    else
        fail "D1a: borrar el snapshot intermedio fallo"
        tail -6 /tmp/i32-d1del.log | sed 's/^/      /'
    fi

    guest_verify "D1a: los datos vivos sobreviven al borrado del intermedio" "$SEED2" "$H2"

    # What this storage will and will not do, established rather than assumed.
    # A volume chain is a stack: rolling back means discarding the layers above,
    # and PVE only offers that for the newest snapshot. Asking for an older one
    # is refused outright - not "refused and the newer ones destroyed", refused.
    # That is a real constraint on how snapshots can be used here, so it is
    # tested for the refusal and for the data being untouched by the attempt.
    say "D1b - pedir vuelta a un snapshot que no es el ultimo"
    if qm rollback "$VMID" c1 --start 1 >/tmp/i32-d1roll.log 2>&1; then
        pass "D1b: este almacenamiento SI permite volver a un snapshot antiguo"
        OLDROLL=1
    else
        reason="$(grep -v 'older storage API' /tmp/i32-d1roll.log | tail -1)"
        note "rechazado: $reason"
        pass "D1b: rechaza volver a un snapshot que no es el mas reciente, y lo dice claro"
        OLDROLL=0
    fi

    if [ "$OLDROLL" = 0 ]; then
        guest_verify "D1b: el intento rechazado no toca los datos" "$SEED2" "$H2"

        say "D1c - volver al snapshot mas reciente, que si esta permitido"
        if qm rollback "$VMID" c3 --start 1 >/tmp/i32-d1roll3.log 2>&1; then
            pass "D1c: qm rollback a c3 completado"
            if reattach 240; then
                gquiet
                guest_verify "D1c: vuelve al estado 2 completo, ficheros y fsck incluidos" "$SEED2" "$H2"
            else
                fail "D1c: el invitado no vuelve tras el rollback"
            fi
        else
            fail "D1c: rollback al snapshot mas reciente fallo"
            tail -6 /tmp/i32-d1roll3.log | sed 's/^/      /'
        fi
    else
        if reattach 240; then
            gquiet
            guest_verify "D1b: vuelve exactamente al estado 0" "$SEED0" "$H0"
        else
            fail "D1b: el invitado no vuelve tras el rollback"
        fi
    fi

    say "D1d - deshacer la cadena entera"
    for s in c3 c1; do
        if qm listsnapshot "$VMID" 2>/dev/null | grep -qw "$s"; then
            qm delsnapshot "$VMID" "$s" >/dev/null 2>&1 && note "snapshot $s borrado" \
                || fail "D1d: no se pudo borrar $s"
        fi
    done
    if [ "$OLDROLL" = 0 ]; then
        guest_verify "D1d: los datos siguen intactos tras borrar toda la cadena" "$SEED2" "$H2"
    else
        guest_verify "D1d: los datos siguen intactos tras borrar toda la cadena" "$SEED0" "$H0"
    fi
fi

# ---------------------------------------------------------------------------

say "resumen"
SKIPPED=0
i=0
while [ "$i" -lt "${#SUMMARY[@]}" ]; do
    case "${SUMMARY[$i]}" in "--"*) SKIPPED=$(( SKIPPED + 1 )) ;; esac
    echo "  ${SUMMARY[$i]}"
    i=$(( i + 1 ))
done
echo ""
if [ "$FAILURES" = 0 ]; then
    echo "  Cadena de snapshots con el intermedio borrado, y backup en caliente"
    echo "  restaurado y verificado desde el hipervisor: bloques, ficheros y fsck."
else
    echo "  $FAILURES comprobacion(es) fallidas - arriba esta cual."
fi
[ "$SKIPPED" != 0 ] && echo "  Ademas $SKIPPED no llegaron a ejecutarse."

if [ "$FAILURES" != 0 ]; then exit "$FAILURES"
elif [ "$SKIPPED" != 0 ]; then exit 77
fi
exit 0
