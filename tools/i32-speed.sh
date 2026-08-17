#!/bin/bash
# Sequential throughput of a block device, honestly measured.
#
# Three things make a naive dd lie about a storage this one is built on, and
# each is handled here rather than hoped away.
#
# Writing zeros measures nothing: ZFS turns an all-zero record into a hole and
# never sends it, so /dev/zero reports the speed of not doing the work. The
# payload here is drawn from urandom into RAM once and written from there, so
# every byte crosses the transport.
#
# Page cache measures the host, not the device. Every transfer uses O_DIRECT,
# and the read pass drops the device's buffers first, so a read cannot be
# served from what the write just left behind.
#
# One sample is a number, not a measurement. Each block size is run three times
# and all three are reported, because the spread is what tells you whether the
# figure means anything - a fabric that is fine on average and terrible once is
# a fabric with a problem.
#
#   i32-speed.sh <block-device> [size-mib]
#
# It writes over the device it is given. That device must be a scratch volume.

set -euo pipefail

DEV="${1:-}"
SIZE_MIB="${2:-2048}"

[ -n "$DEV" ] || { echo "usage: $0 <block-device> [size-mib]" >&2; exit 2; }
[ -b "$DEV" ] || { echo "refusing: $DEV is not a block device" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 2; }

# Refuse anything that is currently part of a running guest. The caller is
# expected to pass a scratch volume, but a typo should not cost a VM.
if command -v lsof >/dev/null 2>&1 && lsof "$DEV" >/dev/null 2>&1; then
    echo "refusing: $DEV is open by another process" >&2
    exit 2
fi

SRC=/dev/shm/i32-speed-src
CHUNK_MIB=256

cleanup() { rm -f "$SRC"; }
trap cleanup EXIT

echo "dispositivo : $DEV"
echo "tamano      : ${SIZE_MIB} MiB por pasada"
base="$(basename "$(readlink -f "$DEV")")"
for q in max_sectors_kb nr_requests scheduler; do
    [ -r "/sys/block/$base/queue/$q" ] && echo "$q: $(cat "/sys/block/$base/queue/$q")" | sed 's/^/            /'
done
echo ""

echo "preparando ${CHUNK_MIB} MiB de datos incompresibles en RAM..."
dd if=/dev/urandom of="$SRC" bs=1M count="$CHUNK_MIB" status=none
echo ""

# dd reports its own rate, but parsing that across locales is fragile; time the
# whole transfer here instead and compute from bytes moved.
run_write() {
    local bs="$1" total="$2" loops i
    loops=$(( total / CHUNK_MIB ))
    [ "$loops" -ge 1 ] || loops=1
    local t0 t1
    t0=$(date +%s.%N)
    for ((i = 0; i < loops; i++)); do
        dd if="$SRC" of="$DEV" bs="$bs" seek=$(( i * CHUNK_MIB * 1024 * 1024 / bs_bytes )) \
           count=$(( CHUNK_MIB * 1024 * 1024 / bs_bytes )) oflag=direct status=none 2>/dev/null
    done
    t1=$(date +%s.%N)
    awk -v t0="$t0" -v t1="$t1" -v mb="$(( loops * CHUNK_MIB ))" \
        'BEGIN { d = t1 - t0; if (d <= 0) d = 0.001; printf "%.0f", mb / d }'
}

run_read() {
    local bs="$1" total="$2"
    blockdev --flushbufs "$DEV" 2>/dev/null || true
    local t0 t1
    t0=$(date +%s.%N)
    dd if="$DEV" of=/dev/null bs="$bs" count=$(( total * 1024 * 1024 / bs_bytes )) \
       iflag=direct status=none 2>/dev/null
    t1=$(date +%s.%N)
    awk -v t0="$t0" -v t1="$t1" -v mb="$total" \
        'BEGIN { d = t1 - t0; if (d <= 0) d = 0.001; printf "%.0f", mb / d }'
}

printf "%-8s  %-28s  %s\n" "bloque" "escritura MB/s (3 pasadas)" "lectura MB/s (3 pasadas)"
printf "%-8s  %-28s  %s\n" "------" "----------------------------" "------------------------"

for bs in 64k 1M 4M 32M; do
    case "$bs" in
        64k) bs_bytes=65536 ;;
        1M)  bs_bytes=1048576 ;;
        4M)  bs_bytes=4194304 ;;
        32M) bs_bytes=33554432 ;;
    esac
    w=""; r=""
    for _ in 1 2 3; do w="$w $(run_write "$bs" "$SIZE_MIB")"; done
    for _ in 1 2 3; do r="$r $(run_read  "$bs" "$SIZE_MIB")"; done
    printf "%-8s %-29s %s\n" "$bs" "$w" "$r"
done

echo ""
echo "Un solo valor bajo entre tres altos importa mas que la media: en un fabric"
echo "sano las tres pasadas se parecen. Si no, mira el log del kernel de la ventana."
