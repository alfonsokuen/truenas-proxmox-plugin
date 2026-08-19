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
#   L4  move disk   to another storage and back - the data is compared after
#                   each hop AND the volume is checked for coming back with the
#                   capabilities it left with, which is a separate question and
#                   the one qm move-disk answers badly without --format
#   L5  template    convert, then linked clone, and confirm writing to the clone
#                   cannot reach the base image underneath it. Storages that
#                   decline linked clones skip that last part - it is recorded
#                   as a skip, and a skip is not a pass
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
# Derived, not fixed: a hard 2048 with --size 2 writes past the end of the disk
# and every phase fails for a reason that has nothing to do with the storage.
# Half the disk, capped, so the run stays short on a large one.
PAT_MIB=$(( SIZE * 1024 / 2 ))
if [ "$PAT_MIB" -gt 2048 ]; then
    PAT_MIB=2048
fi
if [ "$PAT_MIB" -lt 64 ]; then
    echo "refusing: --size $SIZE is too small to test anything useful" >&2
    exit 2
fi
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

# "No matching lines" and "the listing failed" are indistinguishable once piped
# into wc -l, and they mean opposite things: one is a storage with nothing on
# it, the other a storage nobody could read. Reading a failed listing as
# "nothing there" makes the preflight proceed where it should refuse, and makes
# the teardown claim a clean exit while orphans sit on a storage whose broker
# is down. Sets VOLS_OUT; returns 1 if the storage could not be listed.
vols_for() {
    local s="$1" v="$2" out
    out="$(pvesm list "$s" 2>/dev/null)" || return 1
    VOLS_OUT="$(echo "$out" | awk -v x="$v" '$1 ~ ("(vm|base)-" x "-")')"
    return 0
}

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
                # Still zero-sized: the attach never came up. Reporting success
                # would hand every later step a device that fails every I/O,
                # and those failures would then be read as damage.
                qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
                NBD=""
                return 1
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
    # The verifier reads through the page cache. On the qcow2 path the nbd
    # device is created fresh each time, so the cache is cold anyway; on a raw
    # zvol opened directly it is not, and a read could be answered by whatever
    # the write left in memory instead of by the storage.
    #
    # blockdev only works on block devices. On a directory-backed storage the
    # path is a regular file, where it fails silently and leaves the cache
    # exactly as warm as it was - so that case drops the caches globally
    # instead, which is heavier but is the only thing that works there.
    if [ -b "$OPENED" ]; then
        blockdev --flushbufs "$OPENED" 2>/dev/null || true
    else
        sync
        echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi
    return 0
}

# PVE's own answer, not an inference from the volume name.
#
# Three outcomes, not two. Collapsing "the query failed" into "no" is what makes
# a broken checker agree with itself: ask before and after an operation, get an
# error both times, read it as "unchanged", and report that nothing was lost
# while the capability is gone. 0 yes, 1 no, 2 could not tell.
can_snapshot() {
    perl -e 'use PVE::Storage;
             my $cfg = eval { PVE::Storage::config() };
             exit(2) if $@ || !$cfg;
             my $r = eval { PVE::Storage::volume_has_feature($cfg, "snapshot", $ARGV[0], undef, 0) };
             exit(2) if $@;
             exit($r ? 0 : 1);' "$1" 2>/dev/null
}

# yes | no | ? - and "?" must never compare equal to anything, including itself.
snap_state() {
    can_snapshot "$1"
    case $? in
        0) echo si ;;
        1) echo no ;;
        *) echo "?" ;;
    esac
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
    # Every storage this run will clean up, not just the primary one. The
    # cleanup at the end destroys by VMID, so a volume that happens to carry
    # one of these VMIDs is destroyed whether this run created it or not - and
    # the alternate storage was omitted here until it swept away a 2 GiB
    # leftover from an earlier session on the move-disk target. The VMIDs were
    # checked as VMs and found free; nobody checked them as volumes over there.
    for s in "$STORAGE" ${ALT:+"$ALT"}; do
        VOLS_OUT=""
        if ! vols_for "$s" "$v"; then
            echo "refusing: cannot list $s - unable to tell whether leftovers exist" >&2; exit 2
        fi
        if [ -n "$VOLS_OUT" ]; then
            echo "refusing: leftover volume(s) for $v on $s" >&2
            echo "$VOLS_OUT" >&2
            echo "this run would destroy them on cleanup. Move them, or pick a" >&2
            echo "different --vmid base." >&2
            exit 2
        fi
    done
    # A backup left by an earlier run with this same VMID would restore and
    # verify clean, because the seeds are derived from the VMID and would match.
    if pvesm list "$BKP" --content backup 2>/dev/null | awk -v x="$v" '$1 ~ ("qemu-" x "-")' | grep -q .; then
        echo "refusing: a leftover backup for $v already exists on $BKP" >&2; exit 2
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
        # What the disk was before it left. Comparing data alone would call a
        # round trip successful even when the volume comes back in a different
        # format having quietly lost the ability to snapshot - which is exactly
        # what qm move-disk does without an explicit --format.
        ORIG_VOLID="$(volid_of "$CLONE")"
        ORIG_SNAP="$(snap_state "$ORIG_VOLID")"
        note "antes de moverlo: $ORIG_VOLID (snapshot: $ORIG_SNAP)"
        if [ "$ORIG_SNAP" = "?" ]; then
            fail "L4: no se puede consultar la capacidad de snapshot - la comparacion posterior no valdria"
        fi

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

            BACK_SNAP="$(snap_state "$MV2")"
            note "volvio como  : $MV2 (snapshot: $BACK_SNAP)"
            if [ "$ORIG_SNAP" = "?" ] || [ "$BACK_SNAP" = "?" ]; then
                fail "L4: la capacidad de snapshot no se pudo consultar (antes=$ORIG_SNAP despues=$BACK_SNAP)"
            elif [ "$BACK_SNAP" = "$ORIG_SNAP" ]; then
                pass "L4: el volumen vuelve con las mismas capacidades que tenia"
            else
                fail "L4: salio con snapshot=$ORIG_SNAP y vuelve con snapshot=$BACK_SNAP - los datos estan, la capacidad no"
                note "      remedio: qm move-disk ... --format qcow2"
            fi
        else
            fail "L4: qm move-disk de vuelta a $STORAGE fallo"
            tail -5 /tmp/i32-move2.log | sed 's/^/      /'
        fi

        # And the same hop done right, to show the flag is the whole difference.
        # Only worth running when the plain hop actually degraded something and
        # both readings were trustworthy - after an unreadable answer there is
        # nothing to demonstrate.
        if [ "${ORIG_SNAP:-?}" != "?" ] && [ "${BACK_SNAP:-?}" != "?" ] && \
           [ "${BACK_SNAP:-}" != "${ORIG_SNAP:-}" ]; then
            if ! qm move-disk "$CLONE" scsi0 "$ALT" --delete 1 >/tmp/i32-move3a.log 2>&1; then
                fail "L4: no se pudo sacar el disco otra vez para repetir el salto con --format"
                tail -3 /tmp/i32-move3a.log | sed 's/^/      /'
            elif qm move-disk "$CLONE" scsi0 "$STORAGE" --format qcow2 --delete 1 >/tmp/i32-move3.log 2>&1; then
                MV3="$(volid_of "$CLONE")"
                FIX_SNAP="$(snap_state "$MV3")"
                note "con --format qcow2: $MV3 (snapshot: $FIX_SNAP)"
                if [ "$FIX_SNAP" = "$ORIG_SNAP" ]; then
                    pass "L4: con --format qcow2 explicito el volumen vuelve intacto en capacidades"
                else
                    fail "L4: con --format qcow2 la capacidad queda en '$FIX_SNAP' y salio como '$ORIG_SNAP'"
                fi
                check_pattern "L4: y los datos siguen ahi tras la tercera ida y vuelta" "$MV3" "$PAT_MIB" "$SEED_A"
            else
                fail "L4: qm move-disk --format qcow2 fallo"
                tail -5 /tmp/i32-move3.log | sed 's/^/      /'
            fi
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
            # If that write never landed, the template obviously still reads
            # SEED_A, and the isolation assertion would pass without anything
            # having been isolated. So the write is confirmed, and the clone is
            # confirmed to be showing the new data, before the base is asked.
            if write_pattern "$LNKVOL" 512 "$SEED_B"; then
                pass "L5: escritura sobre el clon enlazado completada"
                if check_pattern "L5: el clon enlazado devuelve el patron nuevo" "$LNKVOL" 512 "$SEED_B"; then
                    check_pattern "L5: escribir en el clon no toca la plantilla de debajo" "$TPLVOL" "$PAT_MIB" "$SEED_A"
                else
                    skip "L5: el clon no refleja la escritura, la prueba de aislamiento no se puede evaluar"
                fi
            else
                fail "L5: no se pudo escribir en el clon enlazado - el aislamiento queda sin probar"
            fi
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
unlistable=0
for v in "$VMID" "$CLONE" "$LINKED" "$RESTORE"; do
    for s in "$STORAGE" "$ALT"; do
        VOLS_OUT=""
        if ! vols_for "$s" "$v"; then
            unlistable=$(( unlistable + 1 ))
            note "no se pudo listar $s al buscar restos de $v"
            continue
        fi
        if [ -n "$VOLS_OUT" ]; then
            leftover=$(( leftover + $(echo "$VOLS_OUT" | wc -l) ))
            echo "$VOLS_OUT" | sed 's/^/      /'
        fi
    done
done
if [ "$unlistable" != 0 ]; then
    fail "limpieza: $unlistable listado(s) fallaron - NO se puede afirmar que no queden restos"
elif [ "$leftover" = 0 ]; then
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
SKIPPED=0
i=0
while [ "$i" -lt "${#SUMMARY[@]}" ]; do
    case "${SUMMARY[$i]}" in "--"*) SKIPPED=$(( SKIPPED + 1 )) ;; esac
    i=$(( i + 1 ))
done

echo ""
if [ "$FAILURES" != 0 ]; then
    echo "  $FAILURES comprobacion(es) fallidas - arriba esta cual."
else
    echo "  Los datos sobreviven a crecer, clonar, respaldar, restaurar, mover"
    echo "  de almacenamiento y convertir en plantilla, verificados bloque a bloque."
fi
# A skip is not a pass, and it has to be said whether or not anything failed -
# tucking it inside the success branch means a run with one failure never
# mentions the three checks that did not run at all.
if [ "$SKIPPED" != 0 ]; then
    echo ""
    echo "  Ademas, $SKIPPED comprobacion(es) NO llegaron a ejecutarse. Lo que"
    echo "  prometian NO esta probado - busca las lineas que empiezan por --."
fi

# Anything reading only the exit code has to see the difference between "every
# check ran and passed" and "the checks that ran passed". 77 is the usual
# convention for skipped, and it is not zero, which is the point.
if [ "$FAILURES" != 0 ]; then
    exit "$FAILURES"
elif [ "$SKIPPED" != 0 ]; then
    exit 77
fi
exit 0
