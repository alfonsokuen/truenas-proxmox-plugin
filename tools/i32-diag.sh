#!/bin/bash
# Diagnose issue #32 - disk contents corrupted by moving a VM disk onto NVMe/TCP.
#
# What the issue thread actually establishes
# ------------------------------------------
# The reporter's disks were damaged when moved with "Move Storage" in the web
# interface, and survived when moved with `qm disk move`. Both of those go to
# the same API endpoint, so the interface is not the variable. What changes is
# whether the VM was running: PVE copies a stopped disk with qemu-img convert,
# and mirrors a running one with QEMU's drive-mirror. That is the only
# difference the reporter's own two attempts isolate, so it is what this
# measures.
#
# Issue #45 supplies a candidate mechanism from the other end: nvmet_tcp failing
# to map buffers for large transfers, returning Internal Error, with
# max_sectors_kb=128 on the initiator as the workaround. If that is the cause,
# clamping it turns a failing run into a passing one - which is why the third
# phase exists.
#
# How it decides
# --------------
# Corruption that a filesystem would have hidden is caught by writing a
# self-describing pattern to the source disk, moving it, and regenerating the
# pattern to compare against the destination. The source is re-checked too, so
# a bad verdict cannot come from the harness misreading its own data.
#
#   A  stopped  move   the path the reporter says works        (control)
#   B  running  move   the path the reporter says fails        (suspect)
#   C  running  move   same as B with max_sectors_kb clamped   (#45 workaround)
#
# Each phase writes a DIFFERENT pattern. That matters: with one shared pattern,
# a destination that still held the previous phase's data - a recycled NSID, a
# mover that silently did nothing - would verify clean and be reported as proof
# the storage is sound. Per-phase seeds make stale data fail loudly.
#
# What it touches
# ---------------
# It creates one VM at a VMID it has confirmed is free and unused by any volume
# on any storage, gives it one disk on the source storage and one on the
# destination, and destroys only that VM. It never writes to a volume it did not
# allocate, and it refuses to start unless both storages have room.
#
# Phase C installs a udev rule for the duration of one move. It goes in /run,
# not /etc, so it cannot outlive a reboot if this script is killed outright; it
# is removed as soon as the move finishes and again from the exit trap; any
# namespace it caught by accident is put back; and the phase reports the
# max_sectors_kb it actually observed rather than the one it asked for.
#
# Everything it collects lands under /var/tmp/i32-diag-<vmid>-<stamp>/.
#
# Run it on the Proxmox node, as root:
#
#   ./i32-diag.sh --vmid 9990 --src local-zfs --dst tn-pilot --size 4
#
# Exit: 0 all phases clean, 1 damage or an unusable run, 2 refused to start.

set -euo pipefail

VMID=""
SRC=""
DST=""
SIZE_GB=4
PHASES="A,B,C"
SEED_BASE=""
ASSUME_YES=0
KEEP=0
CLAMP_KB=128
MARKER=""
MAX_SIZE_GB=64

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'
    cat <<'OPTS'
options:
  --vmid N            VMID to create and destroy. Must not already exist.
  --src STOREID       storage the disk starts on (must give a block device)
  --dst STOREID       storage to move it to - the one under test
  --size N            disk size in GiB (default 4, refused above 64)
  --phases A,B,C      which phases to run (default all)
  --clamp-kb N        max_sectors_kb for phase C (default 128, from issue #45)
  --seed N            base pattern seed; default is derived from the VMID
  --keep              do not destroy the VM afterwards (single phase only)
  --yes               skip the confirmation prompt
OPTS
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --vmid)     VMID="${2:-}"; shift 2 ;;
        --src)      SRC="${2:-}"; shift 2 ;;
        --dst)      DST="${2:-}"; shift 2 ;;
        --size)     SIZE_GB="${2:-}"; shift 2 ;;
        --phases)   PHASES="${2:-}"; shift 2 ;;
        --clamp-kb) CLAMP_KB="${2:-}"; shift 2 ;;
        --seed)     SEED_BASE="${2:-}"; shift 2 ;;
        --keep)     KEEP=1; shift ;;
        --yes)      ASSUME_YES=1; shift ;;
        -h|--help)  usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BV="$HERE/i32-blockverify.pl"

die()   { echo "" >&2; echo "REFUSED: $*" >&2; exit 2; }
say()   { echo "[i32] $*"; }
head1() { echo ""; echo "=== $* ==="; }

# ---------------------------------------------------------------------------
# Preflight. Every one of these is a reason not to start.
# ---------------------------------------------------------------------------

[ "$(id -u)" = "0" ]         || die "must run as root on the Proxmox node"
[ -n "$VMID" ]               || die "--vmid is required"
[ -n "$SRC" ]                || die "--src is required"
[ -n "$DST" ]                || die "--dst is required"
[ -r "$BV" ]                 || die "cannot find i32-blockverify.pl next to this script ($BV)"
command -v qm    >/dev/null  || die "qm not found - this must run on a Proxmox VE node"
command -v pvesm >/dev/null  || die "pvesm not found"
command -v perl  >/dev/null  || die "perl not found"
command -v lsblk >/dev/null  || die "lsblk not found"

[[ "$VMID" =~ ^[0-9]+$ ]]    || die "--vmid must be a number"
[[ "$SIZE_GB" =~ ^[0-9]+$ ]] || die "--size must be a whole number of GiB"
[ "$SIZE_GB" -ge 1 ]         || die "--size must be at least 1 GiB"
[ "$SRC" != "$DST" ]         || die "--src and --dst must differ, or nothing moves"
[[ "$CLAMP_KB" =~ ^[0-9]+$ ]] && [ "$CLAMP_KB" -ge 4 ] \
    || die "--clamp-kb must be a number of KiB, at least 4"

SEED_BASE="${SEED_BASE:-$VMID}"
[[ "$SEED_BASE" =~ ^[0-9]+$ ]] || die "--seed must be a non-negative integer"

# A fat-fingered --size is the cheapest way to take production down here: the
# pattern is deliberately incompressible, so every gigabyte asked for is a
# gigabyte physically written into a pool that production shares.
[ "$SIZE_GB" -le "$MAX_SIZE_GB" ] || die "--size $SIZE_GB GiB is above the ${MAX_SIZE_GB} GiB cap.
       This test needs a small disk, not a big one. If you genuinely want more,
       raise MAX_SIZE_GB in this script and say why in the commit."

if [ "$KEEP" = "1" ] && [ "$PHASES" != "${PHASES%,*}" ]; then
    die "--keep only makes sense with a single phase; pass e.g. --phases B --keep"
fi

SIZE_BYTES=$(( SIZE_GB * 1024 * 1024 * 1024 ))
SIZE_KIB=$(( SIZE_GB * 1024 * 1024 ))

# The single most important check in this script. A VMID that is already taken
# belongs to somebody, and everything below assumes the VM is ours to destroy.
if qm status "$VMID" >/dev/null 2>&1; then
    die "VMID $VMID already exists on this node. Pick another:
       $(pvesh get /cluster/nextid 2>/dev/null || echo 'try pvesh get /cluster/nextid')"
fi

# qm status only sees this node, so ask the cluster too - and fail closed. An
# earlier version grepped for '"vmid":N,' which can never match, because vmid
# sorts last in the JSON object and is followed by '}' rather than a comma. It
# also swallowed every pvesh error as "not in use". A check that cannot fire is
# worse than no check, because the plan prints "confirmed free" either way.
if command -v pvesh >/dev/null 2>&1; then
    cl_json="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)" \
        || die "could not ask the cluster whether VMID $VMID is in use. Refusing to guess."
    [ -n "$cl_json" ] || die "the cluster VMID query came back empty. Refusing to guess."
    set +e
    printf '%s' "$cl_json" | VMID="$VMID" perl -MJSON::PP -0777 -e '
        my $j = do { local $/; <STDIN> };
        my $d = eval { decode_json($j) };
        exit 3 unless ref $d eq "ARRAY";
        exit 1 if grep { defined($_->{vmid}) && $_->{vmid} == $ENV{VMID} } @$d;
        exit 0;'
    rc=$?
    set -e
    case "$rc" in
        0) : ;;
        1) die "VMID $VMID is in use elsewhere in the cluster" ;;
        *) die "could not parse the cluster VMID list. Refusing to guess." ;;
    esac
fi

active_storages() {
    pvesm status 2>/dev/null | awk '$3 == "active" { print $1 }'
}

storage_field() {   # <storeid> <awk field>
    pvesm status --storage "$1" 2>/dev/null | awk -v n="$1" '$1 == n { print $'"$2"' }'
}

for s in "$SRC" "$DST"; do
    st="$(storage_field "$s" 3)"
    [ -n "$st" ] || die "storage '$s' is unknown on this node"
    [ "$st" = "active" ] || die "storage '$s' is '$st', not active. Enable it first."
done

# Volumes named for this VMID that we did not create are somebody's orphan, and
# `qm destroy --purge` at the end of a phase would take them with it. The old
# version passed --destroy-unreferenced-disks, which made that certain; dropping
# the flag helps, but refusing to start is what actually protects them.
# Match the volume naming convention rather than trusting --vmid: on a dir
# storage, `pvesm list --vmid` also returns snippets, ISOs and import images,
# none of which belong to any VM. An earlier version took those at face value
# and refused to start on every node that had a snippet.
found_orphans=""
for s in $(active_storages); do
    hits="$(pvesm list "$s" --vmid "$VMID" 2>/dev/null \
        | awk -v v="$VMID" 'NR > 1 && $1 ~ ("(vm|base|subvol)-" v "-") { print $1 }')" || true
    [ -n "$hits" ] && found_orphans="$found_orphans$s: $hits"$'\n'
done
[ -z "$found_orphans" ] || die "volumes for VMID $VMID already exist, though no VM does:
$found_orphans       These are somebody's orphans. Pick a different VMID, or clean them up
       deliberately - this script will not do it for you."

# Room for the pattern on both sides, with margin. The source gets a full-size
# volume and so does the destination.
for s in "$SRC" "$DST"; do
    avail="$(storage_field "$s" 6)"
    if [ -z "$avail" ] || ! [[ "$avail" =~ ^[0-9]+$ ]]; then
        say "warning: could not read free space for '$s'; continuing without that check"
        continue
    fi
    need=$(( SIZE_KIB + SIZE_KIB / 4 ))
    [ "$avail" -ge "$need" ] || die "storage '$s' has $(( avail / 1048576 )) GiB free; this run needs
       about $(( need / 1048576 )) GiB there. Use a smaller --size."
done

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/var/tmp/i32-diag-${VMID}-${STAMP}"
MARKER="i32diag-${VMID}-${STAMP}"
mkdir -p "$OUT"

PLAN="$(cat <<PLANTEXT
  node          $(hostname)
  kernel        $(uname -r)
  pve           $(pveversion 2>/dev/null | head -1)
  VMID          $VMID   (free here and cluster-wide; no volumes carry it)
  VM name       $MARKER
  source        $SRC
  destination   $DST     <-- the storage under test
  disk          ${SIZE_GB} GiB, base seed $SEED_BASE (each phase uses its own)
  phases        $PHASES
  output        $OUT

  This creates one VM, allocates one disk on $SRC and one on $DST, and destroys
  both when done. It writes to no other volume. Phase C additionally installs a
  udev rule under /run for the length of one move, clamping max_sectors_kb to
  ${CLAMP_KB}k on NVMe namespaces that appear while it is in place.
PLANTEXT
)"

head1 "plan"
echo "$PLAN"
printf '%s\n' "$PLAN" > "$OUT/plan.txt"

if [ "$ASSUME_YES" != "1" ]; then
    echo ""
    read -r -p "Proceed? type yes: " ans
    [ "$ans" = "yes" ] || die "not confirmed"
fi

exec > >(tee -a "$OUT/run.log") 2>&1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

vm_exists() { qm status "$VMID" >/dev/null 2>&1; }

# Never destroy a VM we did not create, even if the VMID matches. The name is
# stamped with this run, so a VMID that somehow became someone else's between
# preflight and now will not be touched.
vm_is_ours() {
    vm_exists || return 1
    qm config "$VMID" 2>/dev/null | grep -qx "name: $MARKER"
}

disk_volid() { qm config "$VMID" 2>/dev/null | sed -n "s/^$1: \([^,]*\).*/\1/p" | head -1; }
vol_path()   { pvesm path "$1" 2>/dev/null; }

# On shared LVM the logical volume is only activated when something needs it, so
# `pvesm path` names a device node that does not exist yet and the block-device
# check below rejects a perfectly good destination. Asking PVE to activate it is
# the same thing qm does before starting a VM, and it is a no-op on storages
# that keep their devices present.
activate_vol() {
    perl -e 'use PVE::Storage;
             my $cfg = PVE::Storage::config();
             eval { PVE::Storage::activate_volumes($cfg, [ $ARGV[0] ]) };' "$1" 2>/dev/null || true
}

# Reads must come off the device, not out of the page cache, or a corrupted
# destination can verify clean against the bytes we just wrote through it.
# BLKFLSBUF both syncs and invalidates, which is exactly what we need - and if
# it errors, that is evidence, not noise, so it is not swallowed.
flush_dev() {
    [ -b "$1" ] || return 0
    blockdev --flushbufs "$1" || say "warning: flushing $1 failed - the comparison below may be reading cache"
}

# Wait for a VM state, and say so if it never arrives rather than carrying on.
wait_state() {   # <state> <seconds>
    local want="$1" secs="${2:-60}" i=0
    while [ "$i" -lt "$secs" ]; do
        qm status "$VMID" 2>/dev/null | grep -q "$want" && return 0
        sleep 2; i=$(( i + 2 ))
    done
    return 1
}

# Scope kernel messages by wall clock. The cursor approach silently degraded to
# "the last 500 lines, unscoped" whenever journalctl returned no cursor, and
# those stale lines were then reported under each phase's heading as though they
# had happened during it.
journal_since() {   # <since-timestamp> <destfile>
    journalctl -k --no-pager --since "$1" -n 20000 > "$2" 2>/dev/null || true
}

# Split into the lines that mean something and the ones that are just context.
# A bare 'nvme|timeout|abort' matches routine driver chatter on any NVMe host.
STRONG='failed to map|Internal Error|I/O error|Buffer I/O error|reset controller|controller is down|resetting controller|sct 0x|sc 0x|EIO'
CONTEXT='nvme|nvmet|timeout|abort'

cleanup() {
    local rc=$?
    set +e
    # The exec above sends everything through tee. If tee has died - a full
    # /var/tmp, say - the first echo in here would take SIGPIPE and kill the
    # shell mid-trap, before the VM was destroyed.
    trap '' PIPE
    remove_clamp_rule 2>/dev/null
    if [ "$KEEP" = "1" ]; then
        vm_exists && say "left VM $VMID in place as asked (--keep); remove it with: qm destroy $VMID --purge"
    elif vm_is_ours; then
        say "destroying VM $VMID"
        qm stop "$VMID" >/dev/null 2>&1
        wait_state stopped 60 || qm stop "$VMID" --skiplock >/dev/null 2>&1
        qm destroy "$VMID" --purge >/dev/null 2>&1 \
            || say "could not destroy VM $VMID automatically - do it by hand: qm destroy $VMID --purge"
    elif vm_exists; then
        say "VM $VMID exists but is not the one this run created; leaving it alone"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# One phase
# ---------------------------------------------------------------------------

declare -A RESULT
declare -A MAXSEC

# Every exit from a phase - clean, early, or refused - has to leave the VMID
# free for the next one, because each phase builds its own VM at the same ID.
# Tearing down here rather than at each return means a new early exit cannot
# forget to do it.
run_phase() {
    local phase="$1"
    RESULT[$phase]="NO VERDICT (the phase returned without recording one)"
    phase_body "$@" || true
    if [ "$KEEP" != "1" ] && vm_is_ours; then
        qm stop "$VMID" >/dev/null 2>&1
        wait_state stopped 60 || qm stop "$VMID" --skiplock >/dev/null 2>&1
        qm destroy "$VMID" --purge >/dev/null 2>&1 \
            || die "could not clean up VM $VMID after phase $phase; stopping rather than leaving debris behind"
    fi
    return 0
}

phase_body() {
    local phase="$1" live="$2" clamp="$3" seed="$4"
    local tag="phase$phase"
    head1 "phase $phase - $( [ "$live" = 1 ] && echo 'live mirror (VM running)' || echo 'offline copy (VM stopped)' )$( [ "$clamp" = 1 ] && echo ", max_sectors_kb clamped to $CLAMP_KB" ), seed $seed"

    qm create "$VMID" --name "$MARKER" --memory 1024 --cores 1 \
        --scsihw virtio-scsi-single --ostype l26 --tablet 0 >/dev/null
    # cache=none is not a tuning choice here, it is the premise: with writeback
    # the host page cache could serve correct bytes off a corrupted device, or a
    # hard stop could lose writes that were never damaged.
    qm set "$VMID" --scsi0 "${SRC}:${SIZE_GB},iothread=1,cache=none" >/dev/null
    # No NIC by design: the VM has no OS and no reason to reach the network.

    local src_volid src_path
    src_volid="$(disk_volid scsi0)"
    [ -n "$src_volid" ] || die "could not read the source disk back out of the VM config"
    activate_vol "$src_volid"
    src_path="$(vol_path "$src_volid")"
    [ -n "$src_path" ] || die "pvesm path gave nothing for $src_volid"

    # Writing a raw pattern into a qcow2 file would destroy its header. Only a
    # block device is safe to fill this way, and only a block device compares
    # byte for byte against the destination afterwards.
    [ -b "$src_path" ] || die "source $src_volid resolves to $src_path, which is not a block device.
       Pick a block-backed source storage (ZFS zvol or LVM), or this would write
       raw bytes over an image file's header."

    say "source $src_volid -> $src_path"
    say "writing pattern (${SIZE_GB} GiB, seed $seed)"
    perl "$BV" write "$src_path" "$SIZE_BYTES" "$seed"
    flush_dev "$src_path"

    say "confirming the pattern reads back from the source before we move it"
    if ! perl "$BV" verify "$src_path" "$SIZE_BYTES" "$seed" > "$OUT/$tag.source-pre.txt" 2>&1; then
        cat "$OUT/$tag.source-pre.txt"
        die "the source does not read back what we just wrote. Nothing downstream
       of this would mean anything - fix the source storage first."
    fi

    # The clamp has to be in place before the destination namespace is created,
    # because it is the mirror through that namespace we want to influence and
    # the device does not exist until the move allocates it. A udev rule is the
    # only thing that can act at that moment - and it is also the mitigation we
    # would ship, so this measures the real fix rather than a stand-in.
    if [ "$clamp" = 1 ]; then
        install_clamp_rule || { RESULT[$phase]="SKIPPED (could not install the clamp rule)"; return 0; }
    fi

    local since; since="$(date '+%Y-%m-%d %H:%M:%S')"

    if [ "$live" = 1 ]; then
        say "starting VM (no OS: it will sit at the BIOS, issuing no writes of its own)"
        qm start "$VMID" >/dev/null
        wait_state running 30 || die "VM $VMID did not start"
        sleep 3
    fi

    say "moving scsi0 to $DST$( [ "$live" = 1 ] && echo ' (drive-mirror)' || echo ' (qemu-img convert)' )"
    local t0 t1 mv_rc=0
    t0=$(date +%s)
    qm disk move "$VMID" scsi0 "$DST" --delete 0 > "$OUT/$tag.move.txt" 2>&1 || mv_rc=$?
    t1=$(date +%s)
    say "move finished in $((t1 - t0))s with rc=$mv_rc"
    if [ "$mv_rc" != "0" ]; then
        tail -20 "$OUT/$tag.move.txt"
        # A move that errors out is not corruption. It is the opposite of what
        # #32 describes, and reporting it as damage would have this harness
        # confirm silent data loss on a run where nothing was even compared.
        RESULT[$phase]="MOVE FAILED (rc=$mv_rc) - nothing was compared"
        journal_since "$since" "$OUT/$tag.kernel.txt"
        collect_nvme "$tag"       # the controller log is the whole story here
        return 0
    fi

    local dst_volid dst_path
    dst_volid="$(disk_volid scsi0)"
    [ -n "$dst_volid" ] || die "scsi0 has no volume after the move"
    # After `qm disk move --delete 0`, scsi0 must be the new volume and the old
    # one must have become unused0. If that is not what happened, comparing
    # against scsi0 would be comparing against the source, which would report
    # clean no matter what the transport did.
    case "$dst_volid" in
        "$DST":*) : ;;
        *) die "after the move scsi0 is $dst_volid, which is not on $DST.
       Comparing against it would measure the wrong volume." ;;
    esac
    activate_vol "$dst_volid"
    dst_path="$(vol_path "$dst_volid")"
    [ -n "$dst_path" ] || die "pvesm path gave nothing for $dst_volid"
    [ -b "$dst_path" ] || die "destination $dst_volid resolves to $dst_path, which is not a
       block device. A raw comparison against an image container would report
       total corruption that is not there."
    [ "$(readlink -f "$dst_path")" != "$(readlink -f "$src_path")" ] \
        || die "source and destination resolve to the same device ($dst_path).
       Whatever the move did, this cannot measure it."
    say "destination $dst_volid -> $dst_path"

    MAXSEC[$phase]="$(read_max_sectors "$dst_path")"
    say "max_sectors_kb on the destination device: ${MAXSEC[$phase]:-unreadable}"

    if [ "$clamp" = 1 ]; then
        remove_clamp_rule
        if [ "${MAXSEC[$phase]}" != "$CLAMP_KB" ]; then
            say "the clamp did not take, so this phase cannot say anything about #45"
            RESULT[$phase]="INCONCLUSIVE (clamp asked for ${CLAMP_KB}k, device reports ${MAXSEC[$phase]:-unknown})"
            return 0
        fi
    fi

    if [ "$live" = 1 ]; then
        say "stopping VM so the destination is quiesced before we read it"
        qm stop "$VMID" >/dev/null 2>&1
        wait_state stopped 60 || die "VM $VMID would not stop; refusing to read a destination
       that something may still be writing to."
    fi

    journal_since "$since" "$OUT/$tag.kernel.txt"
    collect_nvme "$tag"

    # Stopping the VM deactivates a shared LVM volume again, so the device node
    # that existed a moment ago is gone by the time we want to read it. Activate
    # once more here rather than earlier: this is the point where the comparison
    # actually needs the device.
    activate_vol "$dst_volid"
    [ -b "$dst_path" ] || die "destination $dst_path is not present after stopping the VM.
       The volume could not be activated for reading, and comparing against a
       missing device would say nothing about the storage."
    flush_dev "$dst_path"

    say "verifying the destination"
    local vrc=0
    perl "$BV" verify "$dst_path" "$SIZE_BYTES" "$seed" > "$OUT/$tag.destination.txt" 2>&1 || vrc=$?
    cat "$OUT/$tag.destination.txt"

    # If the destination is damaged, the source tells us whether the damage
    # happened in the move or was there all along.
    say "re-verifying the source"
    flush_dev "$src_path"
    local src_rc=0
    perl "$BV" verify "$src_path" "$SIZE_BYTES" "$seed" > "$OUT/$tag.source-post.txt" 2>&1 || src_rc=$?

    # The verifier exits 1 only when it compared the whole extent and found
    # blocks that differ. Anything higher means it could not finish - a short
    # device, an unreadable path - and that is a different thing entirely.
    # Calling it damage would blame the transport for a size mismatch.
    if [ "$vrc" -gt 1 ] || [ "$src_rc" -gt 1 ]; then
        RESULT[$phase]="COULD NOT VERIFY - see $tag.destination.txt and $tag.source-post.txt"
    elif [ "$vrc" = 0 ] && [ "$src_rc" = 0 ]; then
        RESULT[$phase]="CLEAN"
    elif [ "$vrc" != 0 ] && [ "$src_rc" = 0 ]; then
        RESULT[$phase]="DAMAGED in the move (source intact)"
    elif [ "$vrc" != 0 ]; then
        RESULT[$phase]="DAMAGED on both sides - suspect the source storage, not the move"
    else
        RESULT[$phase]="DAMAGED: source only (destination clean)"
    fi
    say "phase $phase: ${RESULT[$phase]}"

    if [ -s "$OUT/$tag.kernel.txt" ]; then
        local ns nc
        ns=$(grep -Eci "$STRONG" "$OUT/$tag.kernel.txt" || true)
        nc=$(grep -Eci "$CONTEXT" "$OUT/$tag.kernel.txt" || true)
        if [ "${ns:-0}" -gt 0 ]; then
            say "the kernel logged something that matters during this phase:"
            grep -Ei "$STRONG" "$OUT/$tag.kernel.txt" | head -20 | sed 's/^/      /'
        else
            say "no kernel errors this phase (${nc:-0} routine nvme line(s) in $tag.kernel.txt)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# The clamp, and why it lives in /run
# ---------------------------------------------------------------------------

# A rule under /etc/udev/rules.d outlives a SIGKILL, an OOM kill, a panic and a
# power cut, and at the next boot systemd-udev-trigger replays an add event for
# every block device - so a leftover would silently clamp every NVMe namespace
# on the node, production paths included, at every boot until a human noticed.
# /run/udev/rules.d has the same precedence over /usr/lib and is tmpfs.
CLAMP_RULE="/run/udev/rules.d/99-i32-diag-max-sectors.rules"
CLAMP_INSTALLED=0
CLAMP_SNAPSHOT=""

# The rule acts on ADD, and the only namespace added during the window should be
# the one the move creates - but this fabric has path flaps, and a production
# namespace that reconnected inside the window would otherwise stay clamped with
# nothing in any log to say so.
snapshot_max_sectors() {
    CLAMP_SNAPSHOT="$OUT/max_sectors.before"
    : > "$CLAMP_SNAPSHOT"
    for q in /sys/block/nvme*/queue/max_sectors_kb; do
        [ -r "$q" ] && echo "$q $(cat "$q")" >> "$CLAMP_SNAPSHOT"
    done
    return 0
}

restore_max_sectors() {
    [ -n "$CLAMP_SNAPSHOT" ] && [ -r "$CLAMP_SNAPSHOT" ] || return 0
    local q was now
    while read -r q was; do
        [ -w "$q" ] || continue
        now="$(cat "$q" 2>/dev/null)" || continue
        [ "$now" = "$was" ] && continue
        echo "$was" > "$q" 2>/dev/null \
            && say "put $q back to $was (the clamp rule had caught it at $now)"
    done < "$CLAMP_SNAPSHOT"
    return 0
}

install_clamp_rule() {
    command -v udevadm >/dev/null || { say "udevadm not found - cannot clamp"; return 1; }
    mkdir -p /run/udev/rules.d 2>/dev/null || { say "cannot create /run/udev/rules.d"; return 1; }
    if [ -e "$CLAMP_RULE" ]; then
        say "$CLAMP_RULE already exists - another run may be in progress; refusing"
        return 1
    fi
    snapshot_max_sectors
    if ! cat > "$CLAMP_RULE" <<RULE
# Installed by i32-diag.sh at $(date -Is), removed when it exits. This lives in
# /run deliberately: if you are reading it after a reboot, something is wrong.
ACTION=="add", SUBSYSTEM=="block", KERNEL=="nvme*n*", ATTR{queue/max_sectors_kb}="$CLAMP_KB"
RULE
    then
        say "could not write $CLAMP_RULE"
        rm -f "$CLAMP_RULE"
        return 1
    fi
    CLAMP_INSTALLED=1
    udevadm control --reload >/dev/null 2>&1 || true
    say "clamping newly added NVMe namespaces to ${CLAMP_KB}k for the length of one move"
    return 0
}

remove_clamp_rule() {
    [ "${CLAMP_INSTALLED:-0}" = "1" ] || return 0
    rm -f "$CLAMP_RULE"
    udevadm control --reload >/dev/null 2>&1 || true
    CLAMP_INSTALLED=0
    say "removed the clamp rule"
    restore_max_sectors
}

read_max_sectors() {
    local dev base
    dev="$(readlink -f "$1" 2>/dev/null)" || return 0
    base="$(basename "$dev")"
    [ -r "/sys/block/$base/queue/max_sectors_kb" ] && cat "/sys/block/$base/queue/max_sectors_kb"
}

collect_nvme() {
    local tag="$1" c
    if command -v nvme >/dev/null; then
        nvme list        > "$OUT/$tag.nvme-list.txt"   2>&1 || true
        nvme list-subsys > "$OUT/$tag.nvme-subsys.txt" 2>&1 || true
        for c in /dev/nvme[0-9]*; do
            [ -c "$c" ] || continue
            echo "--- $c ---"
            nvme error-log "$c" 2>&1 | head -40
        done > "$OUT/$tag.nvme-errorlog.txt" 2>&1 || true
    fi
    for q in /sys/block/nvme*/queue/max_sectors_kb; do
        [ -r "$q" ] && echo "$q = $(cat "$q")"
    done > "$OUT/$tag.max_sectors.txt" 2>&1 || true
}

# ---------------------------------------------------------------------------

head1 "environment"
collect_nvme "env"
uname -a
pveversion 2>/dev/null | head -1 || true
cat "$OUT/env.max_sectors.txt" 2>/dev/null || true

IFS=',' read -r -a want <<< "$PHASES"
for p in "${want[@]}"; do
    case "$p" in
        A) run_phase A 0 0 $(( SEED_BASE * 10 + 1 )) ;;
        B) run_phase B 1 0 $(( SEED_BASE * 10 + 2 )) ;;
        C) run_phase C 1 1 $(( SEED_BASE * 10 + 3 )) ;;
        *) die "unknown phase '$p' (expected A, B or C)" ;;
    esac
done

# ---------------------------------------------------------------------------

head1 "result"
worst=0
for p in A B C; do
    [ -n "${RESULT[$p]:-}" ] || continue
    printf "  phase %s  %-12s %s\n" "$p" "max_sectors=${MAXSEC[$p]:-?}" "${RESULT[$p]}"
    case "${RESULT[$p]}" in
        DAMAGED*|*"MOVE FAILED"*|*"COULD NOT VERIFY"*|*"NO VERDICT"*) worst=1 ;;
    esac
done

echo ""
a="${RESULT[A]:-}"; b="${RESULT[B]:-}"; c="${RESULT[C]:-}"

damaged()    { case "$1" in DAMAGED*) return 0 ;; *) return 1 ;; esac; }
srcdamaged() { case "$1" in *"source only"*|*"both sides"*) return 0 ;; *) return 1 ;; esac; }
failed()     { case "$1" in *"MOVE FAILED"*) return 0 ;; *) return 1 ;; esac; }
unusable()   { case "$1" in *"COULD NOT VERIFY"*|*"NO VERDICT"*) return 0 ;; *) return 1 ;; esac; }

if unusable "$a" || unusable "$b"; then
    cat <<'VERDICT'
  A phase could not finish its comparison, so these results cannot be read as a
  whole. The usual cause is the destination volume coming out a different size
  than the pattern. Fix that and re-run before drawing any conclusion.
VERDICT
elif srcdamaged "$a" || srcdamaged "$b" || srcdamaged "$c"; then
    cat <<'VERDICT'
  The SOURCE storage did not read back what was written to it. That invalidates
  every comparison here, because the pattern the move copied was already wrong.
  This is its own problem and a serious one - look at the source storage before
  anything else, and re-run from a source you trust.
VERDICT
elif failed "$a" || failed "$b"; then
    cat <<'VERDICT'
  The move itself failed, and nothing was compared. That is not issue #32 - #32
  is silent corruption from a move that appeared to succeed. Read the move log
  and the controller error log for that phase: this is a plugin or transport
  error, and it has to be fixed before the corruption question can be asked.
VERDICT
elif damaged "$a"; then
    cat <<'VERDICT'
  The plain offline copy is already damaged. That is a larger finding than #32
  as reported, and it means no move onto this storage is safe. Stop here, read
  the phase A destination report and its kernel log, and do not run the pilot
  until it is understood.
VERDICT
elif damaged "$b" && [ "$a" = "CLEAN" ]; then
    if [ "$c" = "CLEAN" ] && [ -n "${MAXSEC[B]:-}" ] && [ -n "${MAXSEC[C]:-}" ] \
       && [ "${MAXSEC[B]}" -gt "${MAXSEC[C]}" ] 2>/dev/null; then
        cat <<'VERDICT'
  Reproduced, and the clamp changed the outcome. The live mirror damaged data at
  the device's default max_sectors_kb and did not at the clamped value, and the
  two values are on record above, so the clamp demonstrably did something. That
  is consistent with issue #45's mechanism and makes #32 the same fault seen
  from the other side.

  Consistent with, not proven: this is one run of an intermittent fault. Re-run
  phases B and C a few times before acting on it. If it holds, the mitigation is
  a permanent udev rule pinning max_sectors_kb on these namespaces.
VERDICT
    elif [ "$c" = "CLEAN" ]; then
        cat <<'VERDICT'
  Reproduced, and phase C came back clean - but the two phases ran at the same
  max_sectors_kb (see the values above), so the clamp cannot be what made the
  difference. Either the device was already at the clamped value and the rule
  was a no-op, or the fault is intermittent and phase C simply got lucky. Re-run
  before concluding anything.
VERDICT
    elif damaged "$c"; then
        cat <<'VERDICT'
  Reproduced, and the clamp does not fix it. The offline copy is clean and the
  live mirror is not, so the fault is in the mirror path over this transport,
  but not through the buffer-mapping mechanism #45 describes. Go to the offset
  alignment in the phase B destination report: periodic or not decides whether
  to keep looking at the transport or at QEMU.
VERDICT
    else
        cat <<'VERDICT'
  Reproduced. The live mirror damages data and the offline copy does not, which
  is exactly the difference the reporter of #32 stumbled onto. Phase C did not
  run or could not apply its clamp, so nothing here confirms or rules out #45's
  mechanism - re-run with --phases C once the clamp takes.
VERDICT
    fi
elif damaged "$b"; then
    cat <<'VERDICT'
  The live mirror damaged data, but phase A did not run or did not come back
  clean, so there is no control to compare against. Without it this cannot say
  whether the mirror is at fault or every write to this storage is. Run phase A
  before reading anything into phase B.
VERDICT
elif [ "$a" = "CLEAN" ] && [ "$b" = "CLEAN" ]; then
    cat <<'VERDICT'
  Nothing reproduced. That does not clear the transport - it means the fault
  needs an ingredient this run did not supply. The obvious one is a guest
  writing to the disk while the mirror is copying it, which needs a bootable
  image and is the natural next step. Keep the output either way: a clean run
  on this hardware is the baseline every later comparison needs.
VERDICT
elif [ "$a" = "CLEAN" ]; then
    cat <<'VERDICT'
  The control is clean and the suspect path was not exercised. Run phase B -
  that is the one the reporter of #32 found to fail.
VERDICT
else
    echo "  No phase produced a verdict. Read run.log - something refused early."
fi

if [ "${c#INCONCLUSIVE}" != "$c" ]; then
    echo ""
    echo "  Note: phase C is inconclusive, not clean. $c"
fi

echo ""
say "everything collected under $OUT"
cat <<'TN'

  Nothing above sees the TrueNAS side, and that is where issue #45's mechanism
  actually lives. Run this on the TrueNAS host over the same window and keep it
  with the rest:

    dmesg -T | grep -Ei 'nvmet|nvme_tcp|failed to map|Internal Error'

TN
exit "$worst"
