#!/usr/bin/env bash
# 02-broker-restart-under-load.sh — restart the broker while PVE
# plugin callers are hitting the socket
#
# Fires N concurrent `pvesm status --storage <id>` loops in the
# background on the target node, then does `systemctl restart
# truenas-plugin-broker`. During the brief socket-gap, each loop's
# call either queues (good, Type=notify) or falls back to direct
# WS auth (bad, triggers rate-limit storm). Settle, then assert the
# storm counters are clean.
#
# Scenario-specific args:
#   --load-workers N  concurrent pvesm status loops (default 10).
#   --load-s N        duration of the load window in seconds (default 30).

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SELF_DIR}/common.sh"

LT_LOAD_WORKERS=10
LT_LOAD_S=30
lt_init "$@"; set -- "${LT_EXTRAS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --load-workers) LT_LOAD_WORKERS="$2"; shift 2 ;;
        --load-s)       LT_LOAD_S="$2";       shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

lt_provision_vms

mark=$(lt_ssh 'date "+%Y-%m-%d %H:%M:%S"')
info "trigger: restart broker under ${LT_LOAD_WORKERS}-way pvesm-status load (mark: ${mark})"

# Fire the load loops on the target. Each worker runs `pvesm status
# --storage <id>` in a tight loop for LT_LOAD_S seconds. Loop runs
# detached so our ssh returns immediately.
lt_ssh "
for w in \$(seq 1 ${LT_LOAD_WORKERS}); do
    nohup bash -c '
        end=\$(( \$(date +%s) + ${LT_LOAD_S} ))
        while [[ \$(date +%s) -lt \$end ]]; do
            pvesm status --storage ${LT_STORAGE} >/dev/null 2>&1 || true
            sleep 0.5
        done
    ' > /dev/null 2>&1 </dev/null &
done
"
# Let load ramp up for ~2 s before cycling the broker.
sleep 2
info "  restarting truenas-plugin-broker"
lt_ssh 'systemctl restart truenas-plugin-broker'

info "waiting ${LT_LOAD_S}s for load window to end + ${LT_SETTLE_S}s settle"
sleep "$((LT_LOAD_S + LT_SETTLE_S))"

lt_assert_no_storm "${mark}" "post-broker-restart"
lt_assert_broker_active
# A fresh broker + no storm == everything downstream should still be fine.
lt_assert_vms_present "after broker restart under load"

lt_cleanup_vms
lt_summary
