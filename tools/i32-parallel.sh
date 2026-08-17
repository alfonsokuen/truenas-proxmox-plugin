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
#   i32-parallel.sh <block-device> [mib-per-job]

set -uo pipefail

DEV="${1:-}"
PER="${2:-256}"
[ -n "$DEV" ] || { echo "usage: $0 <block-device> [mib-per-job]" >&2; exit 2; }
[ -b "$DEV" ] || { echo "refusing: $DEV is not a block device" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 2; }

# It writes over the device it is given.
if command -v lsof >/dev/null 2>&1 && lsof "$DEV" >/dev/null 2>&1; then
    echo "refusing: $DEV is open by another process" >&2
    exit 2
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
    local jobs="$1" bs="$2" bsb="$3" mode="$4" i t0 t1 total
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
            dd if="$SRC" of="$DEV" bs="$bs" \
               seek=$(( i * PER * 1048576 / bsb )) count=$(( PER * 1048576 / bsb )) \
               oflag=direct status=none 2>/dev/null &
        else
            dd if="$DEV" of=/dev/null bs="$bs" \
               skip=$(( i * PER * 1048576 / bsb )) count=$(( PER * 1048576 / bsb )) \
               iflag=direct status=none 2>/dev/null &
        fi
    done
    wait
    t1=$(date +%s.%N)
    awk -v a="$t0" -v b="$t1" -v m="$total" \
        'BEGIN { d = b - a; if (d <= 0) d = 0.001; printf "%.0f", m / d }'
}

printf "%-8s %-10s %-14s %-14s\n" "hilos" "bloque" "escritura MB/s" "lectura MB/s"
printf "%-8s %-10s %-14s %-14s\n" "-----" "------" "--------------" "------------"
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
