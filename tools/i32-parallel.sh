#!/bin/bash
# What the fabric can actually carry, as opposed to what one process can wait for.
#
# A single dd with O_DIRECT has exactly one request outstanding at a time, so
# its throughput is transfer size divided by round-trip latency and nothing
# else. On a 40 Gb link that number says how fast one thread can wait, not how
# fast the link is - and reporting it as the speed of the storage is simply the
# wrong measurement, however carefully it was taken.
#
# This runs N transfers concurrently at different offsets and divides the total
# bytes by the wall clock, then repeats for several values of N. If throughput
# climbs with N, the single-stream figure was latency-bound. Where it stops
# climbing is the real limit, and that is the number worth quoting.
#
# Payload is incompressible and comes from RAM, because a constant pattern is
# compressed away by ZFS on the far side and never crosses the wire at all.
#
#   i32-parallel.sh <block-device> --overwrite <same-device> [mib-per-job]
#
# It DESTROYS the contents of the device. Everything below is the interlock.

set -uo pipefail

DEV="${1:-}"; shift || true
CONFIRM=""; PER=256
while [ $# -gt 0 ]; do
    case "$1" in
        --overwrite) CONFIRM="${2:-}"; shift 2 ;;
        [0-9]*) PER="$1"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$DEV" ] || { echo "usage: $0 <block-device> --overwrite <same-device> [mib-per-job]" >&2; exit 2; }
[ -b "$DEV" ] || { echo "refusing: $DEV is not a block device" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 2; }

# Naming the device twice is the only way in. Every other guard here can be
# fooled by a device that is in use from somewhere this host cannot see.
[ "$CONFIRM" = "$DEV" ] || {
    echo "refusing: this OVERWRITES $DEV. Repeat it: $0 $DEV --overwrite $DEV" >&2
    exit 2
}

B="$(basename "$(readlink -f "$DEV")")"

# lsof was the only interlock here and it is close to useless for this: it sees
# processes, and the things that own a block device on this host are not
# processes. A VG, a mounted filesystem, a device-mapper table or a QEMU on
# ANOTHER node of the cluster all leave lsof silent.
refuse_dev() { echo "refusing: $DEV $*" >&2; exit 2; }

[ -n "$(ls -A "/sys/block/$B/holders" 2>/dev/null)" ] && \
    refuse_dev "has holders ($(ls -m "/sys/block/$B/holders")): something is layered on it"
grep -qE "^$(readlink -f "$DEV") " /proc/mounts 2>/dev/null && refuse_dev "is mounted"
ls -d "/sys/block/$B/$B"p* >/dev/null 2>&1 && refuse_dev "has partitions"
if command -v pvs >/dev/null 2>&1 && pvs --noheadings -o pv_name 2>/dev/null | grep -qw "$(readlink -f "$DEV")"; then
    refuse_dev "is an LVM physical volume"
fi
if command -v blkid >/dev/null 2>&1; then
    sig="$(blkid -o value -s TYPE "$DEV" 2>/dev/null)"
    [ -n "$sig" ] && refuse_dev "carries a $sig signature - it is not scratch"
fi
if command -v lsof >/dev/null 2>&1 && lsof "$DEV" >/dev/null 2>&1; then
    refuse_dev "is open by another process"
fi

SIZE=$(blockdev --getsize64 "$DEV")
SRC=/dev/shm/i32-par-src
cleanup() { rm -f "$SRC"; }
trap cleanup EXIT

echo "dispositivo : $DEV  ($(( SIZE / 1073741824 )) GiB)"
b="$(basename "$(readlink -f "$DEV")")"
echo "max_sectors_kb: $(cat "/sys/block/$b/queue/max_sectors_kb" 2>/dev/null)"
for s in /sys/class/nvme-subsystem/nvme-subsys*/; do
    if ls "$s" 2>/dev/null | grep -q "^$b\$"; then
        echo "iopolicy    : $(cat "$s/iopolicy" 2>/dev/null)"
        echo "rutas       : $(ls -1 "$s" | grep -cE '^nvme[0-9]+$')"
    fi
done
echo ""

echo "preparando ${PER} MiB incompresibles en RAM..."
dd if=/dev/urandom of="$SRC" bs=1M count="$PER" status=none
echo ""

run_par() {
    local jobs="$1" bs="$2" bsb="$3" mode="$4" i t0 t1 total pids=() p bad=0
    total=$(( jobs * PER ))
    # Offsets must not overlap or the jobs fight over the same blocks.
    if [ $(( total * 1048576 )) -gt "$SIZE" ]; then
        echo "n/a"
        return
    fi
    blockdev --flushbufs "$DEV" 2>/dev/null || true
    t0=$(date +%s.%N)
    for ((i = 0; i < jobs; i++)); do
        if [ "$mode" = w ]; then
            # conv=fdatasync: without it the target can acknowledge from RAM and
            # the number becomes the speed of filling a ZFS transaction group.
            dd if="$SRC" of="$DEV" bs="$bs" \
               seek=$(( i * PER * 1048576 / bsb )) count=$(( PER * 1048576 / bsb )) \
               oflag=direct conv=fdatasync status=none 2>/dev/null &
        else
            dd if="$DEV" of=/dev/null bs="$bs" \
               skip=$(( i * PER * 1048576 / bsb )) count=$(( PER * 1048576 / bsb )) \
               iflag=direct status=none 2>/dev/null &
        fi
        pids+=("$!")
    done
    # Every job's exit status, checked. Dividing an ASSUMED byte count by the
    # wall clock is only a throughput if the bytes actually moved: fifteen dd
    # processes dying instantly on EIO would otherwise report a spectacular
    # number instead of an error.
    for p in "${pids[@]}"; do
        wait "$p" || bad=$(( bad + 1 ))
    done
    t1=$(date +%s.%N)
    if [ "$bad" != 0 ]; then
        echo "ERROR($bad/$jobs)"
        return
    fi
    awk -v a="$t0" -v b="$t1" -v m="$total" \
        'BEGIN { d = b - a; if (d <= 0) d = 0.001; printf "%.0f", m / d }'
}

printf "%-8s %-10s %-15s %-15s\n" "hilos" "bloque" "escritura MiB/s" "lectura MiB/s"
printf "%-8s %-10s %-15s %-15s\n" "-----" "------" "---------------" "-------------"
for jobs in 1 2 4 8 16; do
    for pair in "1M 1048576" "4M 4194304"; do
        set -- $pair
        w="$(run_par "$jobs" "$1" "$2" w)"
        r="$(run_par "$jobs" "$1" "$2" r)"
        printf "%-8s %-10s %-14s %-14s\n" "$jobs" "$1" "$w" "$r"
    done
done

echo ""
echo "Si las cifras suben con el numero de hilos, la medida de un solo hilo era"
echo "latencia disfrazada de ancho de banda. Donde dejan de subir esta el limite"
echo "de verdad: ahi es donde hay que mirar si es la red, el objetivo o el ZFS."
echo ""
echo "Lo que estas cifras NO son: rendimiento de almacenamiento. Las lecturas"
echo "repiten los offsets recien escritos, asi que las sirve la ARC del objetivo"
echo "y no sus discos. Son ancho de banda de la ruta NVMe-oF, que es justo lo"
echo "que se queria medir, pero citarlas como 'lo que da la cabina' seria falso."
