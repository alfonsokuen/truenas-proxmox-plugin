#!/usr/bin/env bash
# 03-broker-crash.sh — SIGKILL the broker; systemd must respawn it
#
# The broker's unit has `Restart=on-failure RestartSec=2`. SIGKILL
# counts as failure, so systemd should restart within ~2 s. During
# the gap, plugin status() calls will find the socket missing. We
# assert that:
#   - the broker comes back active within ~10 s
#   - no `rate limited` storm appears post-respawn
#   - a light pvesm-status probe burst immediately before + after
#     doesn't lock us out
#
# Related memory: project_broker_transient_downtime_retry — this
# scenario reproduces exactly the window that memory is tracking.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SELF_DIR}/common.sh"

lt_init "$@"; set -- "${LT_EXTRAS[@]}"
[[ $# -gt 0 ]] && { echo "unknown args: $*" >&2; exit 2; }

lt_provision_vms

mark=$(lt_ssh 'date "+%Y-%m-%d %H:%M:%S"')
info "trigger: SIGKILL truenas-plugin-broker main PID (mark: ${mark})"

old_pid=$(lt_ssh 'systemctl show -p MainPID --value truenas-plugin-broker')
info "  pre-kill MainPID=${old_pid}"
# Light pre-kill load so some calls are in flight when the broker dies.
lt_ssh "nohup bash -c '
    for i in \$(seq 1 20); do pvesm status --storage ${LT_STORAGE} >/dev/null 2>&1 || true; sleep 0.2; done
' > /dev/null 2>&1 </dev/null &"
sleep 1
lt_ssh "kill -9 ${old_pid} 2>&1 || true"

# Wait up to 15 s for the respawn.
info "waiting for systemd respawn"
new_pid=""
for i in $(seq 1 15); do
    new_pid=$(lt_ssh 'systemctl show -p MainPID --value truenas-plugin-broker' 2>/dev/null)
    [[ "${new_pid}" != "0" && "${new_pid}" != "${old_pid}" && -n "${new_pid}" ]] && { info "  respawned MainPID=${new_pid} after ${i}s"; break; }
    sleep 1
done
if [[ "${new_pid}" == "${old_pid}" || "${new_pid}" == "0" || -z "${new_pid}" ]]; then
    fail "broker did not respawn (old_pid=${old_pid} new_pid=${new_pid})"
    lt_ssh 'systemctl status truenas-plugin-broker --no-pager | head -10' || true
else
    pass "broker respawned by systemd (new MainPID=${new_pid})"
fi

info "waiting ${LT_SETTLE_S}s for callers to settle"
sleep "${LT_SETTLE_S}"

lt_assert_no_storm "${mark}" "post-crash respawn"
lt_assert_broker_active
lt_assert_vms_present "after broker SIGKILL + respawn"

lt_cleanup_vms
lt_summary
