#!/usr/bin/env bash
#
# i32-apiloss.sh -- what does the plugin do when the array's API stops answering?
#
# The failure reproduced here is the common one: the array is up, the fabric is
# up, the data path is fine, and only the management API has gone away -- a
# middleware restart, an upgrade, a partition on the management VLAN. The data
# path does not care. Everything that asks the API does.
#
#     ./i32-apiloss.sh <storage> [--seconds N] --yes
#
# WHAT IT ASSERTS, and why each is the assertion that matters:
#
#   1. `pvesm list` must not report FEWER volumes than it did a minute ago and
#      still exit 0. Inventing an empty storage because the API was unreachable
#      is worse than any hang: anything that reconciles PVE's view against the
#      array -- orphan cleanup above all -- concludes there is nothing to keep.
#      Measured 2 volumes -> 0 volumes, rc=0, on 2.1.24~alpha1+idk5.
#   2. `pvesm alloc` must fail with a non-zero rc. Success it cannot verify is
#      a lie, and a hang holds the storage lock.
#   3. pvestatd must keep writing metrics. Not "must still be active" -- systemd
#      reports a blocked daemon as active. The test is whether the RRD advances.
#   4. Storages with nothing to do with this one must keep answering.
#
# HOW THE BLACKOUT IS MADE. It drops the array's *replies* on the input hook,
# not the node's outbound packets. Dropping on output makes locally-generated
# traffic fail with EPERM in microseconds, which is a different failure: the
# caller gets a hard error instead of a stalled connection. Input-dropping the
# return traffic is what a real API loss looks like -- the SYN leaves and
# nothing comes back.
#
# TIMING. With tcp_syn_retries=6 a connect takes ~127s to give up, and the
# observed list took ~155s. Each operation is capped below the blackout window
# so a hang can never be rescued by the watchdog and misread as a success.
#
# SAFETY
#  - refuses an API host shared by more than one storage unless told otherwise
#  - detached watchdog removes the rule after N seconds even if this script is
#    killed or the ssh session dies
#  - its own nft table; the rest of the ruleset is never touched
#  - positive control before and after: the same operation must work with the
#    API up, or the run proves nothing

set -uo pipefail

STORAGE=""; SECONDS_BLACKOUT=400; CONFIRM=0; ALLOW_SHARED=0
TABLE=i32_apiloss
RRD_STORAGE=/var/lib/rrdcached/db/pve-storage-9.0

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_BLACKOUT="$2"; shift 2 ;;
        --yes) CONFIRM=1; shift ;;
        --yes-shared) ALLOW_SHARED=1; shift ;;
        -h|--help) sed -n '2,42p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) STORAGE="$1"; shift ;;
    esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
[ -t 1 ] || { RED=; GRN=; YEL=; RST=; }
ok()   { printf '%s  OK %s %s\n' "$GRN" "$RST" "$*"; }
bad()  { printf '%s FAIL%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '%s WARN%s %s\n' "$YEL" "$RST" "$*"; }
info() { printf '      %s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

FAILS=0
fail() { bad "$*"; FAILS=$((FAILS+1)); }

[ -n "$STORAGE" ] || { echo "usage: $0 <storage> [--seconds N] --yes" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { bad "must run as root (nft)"; exit 2; }

# ------------------------------------------------------------- preconditions --

step "preconditions"

CFG=/etc/pve/storage.cfg
API_HOST="$(awk -v s="$STORAGE" '
    $1 == "truenasplugin:" { inblk = ($2 == s) }
    inblk && $1 == "tn_api_host" { print $2; exit }
' "$CFG")"
API_PORT="$(awk -v s="$STORAGE" '
    $1 == "truenasplugin:" { inblk = ($2 == s) }
    inblk && $1 == "tn_api_port" { print $2; exit }
' "$CFG")"
[ -n "$API_PORT" ] || API_PORT=443

if [ -z "$API_HOST" ]; then
    bad "no tn_api_host for storage '$STORAGE' in $CFG"
    info "is it a truenasplugin storage?"
    exit 2
fi
info "storage:  $STORAGE"
info "API:      ${API_HOST}:${API_PORT}"

SHARED="$(awk -v h="$API_HOST" '
    $1 == "truenasplugin:" { name = $2 }
    $1 == "tn_api_host" && $2 == h { print name }
' "$CFG" | tr '\n' ' ')"
NSHARED="$(printf '%s' "$SHARED" | wc -w)"
if [ "$NSHARED" -gt 1 ]; then
    warn "this API host is shared by $NSHARED storages: $SHARED"
    if [ "$ALLOW_SHARED" -ne 1 ]; then
        bad "refusing -- pass --yes-shared if that is really what you want"
        exit 2
    fi
fi

INUSE="$(qm list 2>/dev/null | awk '$3=="running"{print $1}' | while read -r v; do
    qm config "$v" 2>/dev/null | grep -q "${STORAGE}:" && echo "$v"
done | tr '\n' ' ')"
if [ -n "$INUSE" ]; then
    warn "VMs running with disks on $STORAGE: $INUSE"
    info "their I/O rides the fabric, not the API, so it should be unaffected"
fi

[ "$CONFIRM" -eq 1 ] || { bad "refusing to inject without --yes"; exit 2; }

# Two operations must fit inside the window with room to spare, otherwise the
# second gets rescued by the watchdog and a hang reads as a success.
OP_LIMIT=$(( (SECONDS_BLACKOUT - 60) / 2 ))
if [ "$OP_LIMIT" -lt 170 ]; then
    bad "--seconds $SECONDS_BLACKOUT is too short"
    info "a TCP connect takes ~127s to give up and the observed list took ~155s,"
    info "so each operation needs at least a 170s cap: use --seconds 400 or more."
    exit 2
fi
info "each of the 2 operations capped at ${OP_LIMIT}s, inside a ${SECONDS_BLACKOUT}s window"

command -v nft >/dev/null || { bad "nft not installed"; exit 2; }
if nft list table inet "$TABLE" >/dev/null 2>&1; then
    bad "table inet $TABLE already exists -- a previous run did not clean up"
    info "inspect it, then: nft delete table inet $TABLE"
    exit 2
fi

# --------------------------------------------------------------- helpers -----

timed() {
    local label="$1" limit="$2"; shift 2
    local t0 t1 rc out
    t0="$(date +%s%N)"
    out="$(timeout "$limit" "$@" 2>&1)"; rc=$?
    t1="$(date +%s%N)"
    LAST_MS=$(( (t1 - t0) / 1000000 )); LAST_RC=$rc; LAST_OUT="$out"
    if [ $rc -eq 124 ]; then
        printf '      %-30s %7s ms  rc=TIMEOUT(>%ss)\n' "$label" "$LAST_MS" "$limit"
    else
        printf '      %-30s %7s ms  rc=%s\n' "$label" "$LAST_MS" "$rc"
    fi
}

count_vols() { pvesm list "$STORAGE" 2>/dev/null | grep -cE "^${STORAGE}:"; }
rrd_mtime()  { stat -c %Y "$RRD_STORAGE/$(hostname)" 2>/dev/null || echo 0; }

remove_blackout() { nft delete table inet "$TABLE" 2>/dev/null && info "blackout removed"; }
trap 'remove_blackout' EXIT INT TERM

# ------------------------------------------------------ 1. positive control --

step "1. positive control -- everything must work with the API up"

timed "pvesm list (API up)" 60 pvesm list "$STORAGE"
if [ "$LAST_RC" -ne 0 ]; then
    bad "the operation already fails with the API up -- nothing to inject into"
    printf '%s\n' "$LAST_OUT" | head -5 | sed 's/^/        /'
    exit 2
fi
BASE_VOLS="$(count_vols)"
ok "baseline: $BASE_VOLS volume(s) in ${LAST_MS} ms"
if [ "$BASE_VOLS" -eq 0 ]; then
    warn "the storage is empty, so assertion 1 cannot tell 'empty' from 'could"
    warn "not ask'. Put at least one volume on it for a meaningful run."
fi

RRD0="$(rrd_mtime)"
if [ "$RRD0" -eq 0 ]; then
    warn "no storage RRD at $RRD_STORAGE/$(hostname) -- the pvestatd check will"
    warn "report INCONCLUSIVE rather than pretend it measured something"
fi

# --------------------------------------------------------- 2. inject --------

step "2. blackout ${API_HOST}:${API_PORT} for ${SECONDS_BLACKOUT}s"

setsid nohup bash -c "sleep $SECONDS_BLACKOUT; nft delete table inet $TABLE 2>/dev/null" \
    >/dev/null 2>&1 </dev/null &
WATCHDOG=$!
info "watchdog pid $WATCHDOG removes the rule in ${SECONDS_BLACKOUT}s no matter what"

nft add table inet "$TABLE" || { bad "could not create nft table"; exit 2; }
nft add chain inet "$TABLE" input '{ type filter hook input priority -300 ; }' \
    || { bad "could not create chain"; exit 2; }
nft add rule inet "$TABLE" input ip saddr "$API_HOST" tcp sport "$API_PORT" drop \
    || { bad "could not add rule"; exit 2; }

if timeout 8 bash -c "</dev/tcp/${API_HOST}/${API_PORT}" 2>/dev/null; then
    fail "the API still answers -- the blackout did NOT take effect"
    info "everything below would be measuring nothing. Stopping."
    exit 1
fi
ok "control: a raw connect to the API no longer completes"

# ------------------------------------------------- 3. behaviour under loss ---

step "3. assertion 1 -- list must not invent an empty storage"

timed "pvesm list (API down)" "$OP_LIMIT" pvesm list "$STORAGE"
if [ "$LAST_RC" -eq 124 ]; then
    fail "pvesm list never returned inside ${OP_LIMIT}s"
else
    DOWN_VOLS="$(printf '%s\n' "$LAST_OUT" | grep -cE "^${STORAGE}:")"
    info "volumes reported: $DOWN_VOLS   (baseline was $BASE_VOLS)"
    if [ "$LAST_RC" -eq 0 ] && [ "$DOWN_VOLS" -lt "$BASE_VOLS" ]; then
        fail "list reported $DOWN_VOLS of $BASE_VOLS volumes and still exited 0"
        info "this is the dangerous one. A reconciler that trusts this concludes"
        info "the storage is empty and that every dataset on the array is an"
        info "orphan. Any cleanup built on pvesm list MUST prove the API is"
        info "reachable first, and treat 'cannot ask' as different from 'empty'."
    elif [ "$LAST_RC" -ne 0 ]; then
        ok "failed with rc=$LAST_RC instead of inventing an answer (${LAST_MS} ms)"
    else
        ok "reported the same $DOWN_VOLS volume(s) -- served from cache, not invented"
    fi
fi

step "4. assertion 2 -- alloc must not claim success it cannot verify"

VOL="vm-9999-disk-apiloss"
timed "pvesm alloc (API down)" "$OP_LIMIT" pvesm alloc "$STORAGE" 9999 "$VOL" 1024
if [ "$LAST_RC" -eq 124 ]; then
    fail "pvesm alloc never returned -- a real allocation would hold the lock"
elif [ "$LAST_RC" -eq 0 ]; then
    fail "pvesm alloc reported SUCCESS with no API -- it cannot know that"
else
    ok "alloc failed cleanly in ${LAST_MS} ms (rc=$LAST_RC)"
    printf '%s\n' "$LAST_OUT" | grep -v 'older storage API' | head -3 | sed 's/^/        /'
fi

step "5. assertions 3 and 4 -- did the rest of the node survive?"

# systemd calls a blocked daemon "active", so ask the metrics instead.
sleep 25
RRD1="$(rrd_mtime)"
if [ "$RRD0" -eq 0 ] || [ "$RRD1" -eq 0 ]; then
    warn "INCONCLUSIVE: no RRD to compare, pvestatd liveness not measured"
elif [ "$RRD1" -gt "$RRD0" ]; then
    ok "pvestatd is still writing metrics (mtime advanced $(( RRD1 - RRD0 ))s)"
else
    fail "pvestatd has not written a metric in 25s -- it is blocked on this storage"
    info "systemd still reports it active. Active is not the same as working."
fi

if timeout 20 pvecm status 2>/dev/null | grep -q "Quorate:.*Yes"; then
    ok "cluster still quorate"
else
    fail "cluster lost quorum"
fi

# Unrelated storages. Distinguish "the storage is broken" from "the status path
# is wedged" -- very different remedies.
OTHER_BAD=0; OTHER_OK=0
while read -r st; do
    [ -n "$st" ] || continue
    if timeout 25 pvesm status --storage "$st" >/dev/null 2>&1; then
        OTHER_OK=$((OTHER_OK+1))
    else
        OTHER_BAD=$((OTHER_BAD+1)); info "  status blocked: $st"
    fi
done <<EOF
$(awk '/^[a-z]+: /{print $2}' "$CFG" | grep -vxF "$STORAGE")
EOF
if [ "$OTHER_BAD" -eq 0 ]; then
    ok "all $OTHER_OK other storages still answer"
else
    fail "$OTHER_BAD unrelated storage(s) stopped answering"
    if timeout 10 ls /var/lib/vz >/dev/null 2>&1; then
        info "but the local filesystem answers instantly, so those storages are"
        info "fine: pvesm status computes every storage before filtering, so one"
        info "unreachable truenasplugin storage darkens status for the whole node."
        info "Guests keep running; it is the management plane that goes away."
    fi
fi

# ------------------------------------------------------------ 6. recovery ---

step "6. recovery"

remove_blackout
trap - EXIT INT TERM
kill "$WATCHDOG" 2>/dev/null
sleep 3

timed "pvesm list (API back)" 90 pvesm list "$STORAGE"
if [ "$LAST_RC" -eq 0 ]; then
    BACK_VOLS="$(count_vols)"
    if [ "$BACK_VOLS" -eq "$BASE_VOLS" ]; then
        ok "recovered unattended: $BACK_VOLS volume(s) again, no restart needed"
    else
        fail "recovered but reports $BACK_VOLS volume(s), baseline was $BASE_VOLS"
    fi
else
    fail "still failing after the blackout was lifted (rc=$LAST_RC)"
fi

if pvesm list "$STORAGE" 2>/dev/null | grep -q "$VOL"; then
    fail "the failed alloc left a volume behind: $VOL"
else
    ok "the failed alloc left nothing behind in PVE's view"
    warn "PVE's view is not the array's view -- confirm on the array too"
fi

step "result"
if [ "$FAILS" -eq 0 ]; then
    ok "F4 passed"
    exit 0
fi
bad "$FAILS assertion(s) failed"
exit 1
