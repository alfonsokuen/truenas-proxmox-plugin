#!/bin/bash
# i32-faultinject.sh — inject a path failure into an nvme-tcp storage and check
# that the host fails over, that the path comes back on its own, and that the
# data is unchanged.
#
# The reason this file is longer than the test it runs: a path-failure test is
# very easy to write so that it cannot fail. Three ways this one nearly did.
#
#   1. Cutting "one of the two paths" proves nothing if all the I/O is already
#      on the other one. Measured: with iopolicy=queue-depth and both
#      controllers on the same NIC, a sequential read put 200 of 200 requests
#      down a single path and zero down its partner. Cutting the idle path is
#      a test that passes without a fabric.
#   2. A DROP in the OUTPUT hook on locally generated traffic can hand the
#      socket an immediate EPERM instead of swallowing the packet, which is a
#      different failure from the one being characterised. The rule belongs in
#      input, matching the reply direction: saddr/sport, not daddr/dport.
#   3. "The I/O never stopped" is only evidence if the I/O could have stopped.
#      Cutting BOTH paths has to bring it to a halt; if it does not, the writer
#      was never reaching the fabric and every earlier line of output is void.
#
# Never `nvme disconnect-all` and never `nft flush ruleset` here: a node that
# serves this storage may also carry an unrelated fabric with guests on it.
set -euo pipefail

SUBSTR="${1:?usage: i32-faultinject.sh <substring-of-subsysnqn> <target-ip>}"
TARGET="${2:?usage: i32-faultinject.sh <substring-of-subsysnqn> <target-ip>}"
TABLE="i32_fault"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
note() { echo "  ..    $*"; }

cleanup() { touch /tmp/i32fi.stop 2>/dev/null || true
            nft delete table inet "$TABLE" 2>/dev/null || true; }
trap cleanup EXIT

# --- locate the subsystem, its head and its paths -------------------------
SUB=""
for s in /sys/class/nvme-subsystem/*/; do
    grep -q "$SUBSTR" "$s/subsysnqn" 2>/dev/null && SUB="$(basename "$s")"
done
[ -n "$SUB" ] || { echo "no subsystem matching '$SUBSTR'"; exit 2; }
HEAD="$(ls -d /sys/block/nvme*n* 2>/dev/null | while read -r d; do
          b=$(basename "$d"); case "$b" in *c*) continue;; esac
          [ -e "$d/multipath" ] && grep -q "$SUBSTR" \
            "/sys/class/nvme-subsystem/$SUB/subsysnqn" && echo "$b"; done | head -1)"
[ -n "$HEAD" ] || { echo "no multipath head for $SUB"; exit 2; }
DEV="/dev/$HEAD"
mapfile -t PATHS < <(ls "/sys/block/$HEAD/multipath")

echo "== preconditions =="
[ "$(cat /sys/module/nvme_core/parameters/multipath)" = "Y" ] \
    && ok "nvme_core.multipath=Y" \
    || { bad "nvme_core.multipath is not Y: two devices, not two paths"; exit 2; }
[ "${#PATHS[@]}" -ge 2 ] && ok "${#PATHS[@]} paths under $HEAD" \
    || { bad "only ${#PATHS[@]} path; nothing to fail over to"; exit 2; }

# Which path actually carries I/O? Do not assume; measure. round-robin first,
# so the answer is about the fabric and not about the policy.
echo round-robin > "/sys/class/nvme-subsystem/$SUB/iopolicy" 2>/dev/null || true
declare -A BEFORE
for p in "${PATHS[@]}"; do BEFORE[$p]=$(awk '{print $1}' "/sys/block/$p/stat"); done
dd if="$DEV" of=/dev/null bs=64k count=2000 iflag=direct status=none
ACTIVE=""; BEST=0
for p in "${PATHS[@]}"; do
    d=$(( $(awk '{print $1}' "/sys/block/$p/stat") - ${BEFORE[$p]} ))
    note "$p carried $d reads"
    [ "$d" -gt "$BEST" ] && { BEST=$d; ACTIVE=$p; }
done
[ "$BEST" -gt 0 ] || { bad "no path carried any I/O; the test would be vacuous"; exit 2; }
ok "active path is $ACTIVE ($BEST reads) - that is the one to cut"

# port of the active path's controller
CTRL="$(echo "$ACTIVE" | sed -E 's/^(nvme[0-9]+)c([0-9]+)n[0-9]+$/nvme\2/')"
PORT="$(cat "/sys/class/nvme/$CTRL/address" 2>/dev/null | tr ',' '\n' \
        | awk -F= '/trsvcid/{print $2}')"
[ -n "$PORT" ] || { bad "could not read trsvcid of $CTRL"; exit 2; }
note "cutting $TARGET:$PORT (controller $CTRL)"

REF="$(dd if="$DEV" bs=1M count=256 status=none | sha256sum | cut -c1-32)"

# --- continuous direct I/O ------------------------------------------------
rm -f /tmp/i32fi.log /tmp/i32fi.stop
( i=0; while [ ! -f /tmp/i32fi.stop ]; do
    if dd if=/dev/zero of="$DEV" bs=64k count=8 seek=$((16384 + i % 50)) \
         oflag=direct conv=notrunc status=none 2>/dev/null
    then i=$((i+1)); echo "$(date +%s) ok" >> /tmp/i32fi.log
    else echo "$(date +%s) fail" >> /tmp/i32fi.log; fi
  done ) & sleep 3
N0=$(grep -c ok /tmp/i32fi.log || true)
[ "$N0" -gt 0 ] && ok "writer is running ($N0 writes)" || { bad "writer wrote nothing"; exit 2; }

# --- cut one path ---------------------------------------------------------
echo "== one path down =="
nft add table inet "$TABLE"
nft add chain inet "$TABLE" input '{ type filter hook input priority -200 ; policy accept ; }'
nft add rule inet "$TABLE" input ip saddr "$TARGET" tcp sport "$PORT" counter drop
sleep 20
DROPPED=$(nft list table inet "$TABLE" | grep -oE 'packets [0-9]+' | awk '{print $2}' | head -1)
[ "${DROPPED:-0}" -gt 0 ] && ok "the rule is matching ($DROPPED packets dropped)" \
                          || bad "the rule matched nothing; it is not cutting anything"
N1=$(grep -c ok /tmp/i32fi.log || true)
[ "$((N1 - N0))" -gt 10 ] && ok "I/O continued through the survivor ($((N1-N0)) writes)" \
                          || bad "I/O stalled with one path still up"
nvme list-subsys 2>/dev/null | grep -q 'connecting' \
    && ok "the cut controller left 'live'" \
    || bad "no controller changed state; the cut did not reach the fabric"

# --- positive control: cut everything ------------------------------------
echo "== positive control: both paths down =="
for p in "${PATHS[@]}"; do
    c="$(echo "$p" | sed -E 's/^(nvme[0-9]+)c([0-9]+)n[0-9]+$/nvme\2/')"
    pt="$(tr ',' '\n' < "/sys/class/nvme/$c/address" | awk -F= '/trsvcid/{print $2}')"
    [ "$pt" = "$PORT" ] && continue
    nft add rule inet "$TABLE" input ip saddr "$TARGET" tcp sport "$pt" counter drop
done
N2=$(grep -c ok /tmp/i32fi.log || true); sleep 25; N3=$(grep -c ok /tmp/i32fi.log || true)
[ "$((N3 - N2))" -lt 20 ] \
    && ok "I/O stops with every path cut - the check above can fail" \
    || bad "I/O continued with every path cut: it never reached the fabric, and every PASS above is void"

# --- restore --------------------------------------------------------------
echo "== restore =="
nft delete table inet "$TABLE"
touch /tmp/i32fi.stop
sleep 20
nvme list-subsys 2>/dev/null | grep -A6 "$SUBSTR" | grep -q 'connecting' \
    && bad "a path is still connecting after the rules were removed" \
    || ok "every path returned to live on its own"
sync; echo 3 > /proc/sys/vm/drop_caches
NOW="$(dd if="$DEV" bs=1M count=256 status=none | sha256sum | cut -c1-32)"
[ "$NOW" = "$REF" ] && ok "the reference region is byte-identical" \
                    || bad "the data changed: $REF -> $NOW"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
