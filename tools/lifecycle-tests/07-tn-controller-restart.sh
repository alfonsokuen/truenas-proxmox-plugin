#!/usr/bin/env bash
# 07-tn-controller-restart.sh — restart middlewared on the TrueNAS
#
# Mimics a TN control-plane bounce (upgrade install, config apply,
# cron-triggered restart). The broker's upstream WS gets severed;
# plugin status() calls in flight either queue through the broker's
# reconnect or fail with transient errors. On a healthy fix we see
# no per-caller re-auth storm, and the broker's pool-liveness check
# re-detects live state once middlewared comes back.
#
# Scenario-specific args:
#   --tn-host H      TrueNAS host to restart middlewared on
#                    (default: autodetect from storage.cfg tn_api_host).
#   --tn-user U      ssh user (default: truenas_admin).
#
# CAUTION: `midclt call system.reboot.info` and `nvmet.port.query`
# will fail during the ~30-60 s window. OTHER truenasplugin
# storages pointing at the same TN will be affected too.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SELF_DIR}/common.sh"

LT_TN_HOST=""
LT_TN_USER="root"   # was truenas_admin; sudo normally wants a password,
                    # while root ssh (if enabled on the TN) runs systemctl
                    # directly. Override with --tn-user if your TN config
                    # requires it.
lt_init "$@"; set -- "${LT_EXTRAS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tn-host) LT_TN_HOST="$2"; shift 2 ;;
        --tn-user) LT_TN_USER="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "${LT_TN_HOST}" ]]; then
    LT_TN_HOST=$(lt_ssh "awk '/^\s*tn_api_host/ && !h {h=\$NF} END{print h}' /etc/pve/storage.cfg")
fi
[[ -z "${LT_TN_HOST}" ]] && { fail "could not find TN host"; lt_summary; exit 1; }
info "TN target for middlewared restart: ${LT_TN_HOST}"

# Scenario needs root privileges on the TN to restart the middlewared
# service. If LT_TN_USER is root (default), we go direct; otherwise we
# fall back to `sudo -n systemctl …`. If neither works, skip cleanly.
TN_RESTART_CMD=""
if [[ "${LT_TN_USER}" == "root" ]]; then
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "${LT_TN_USER}@${LT_TN_HOST}" 'id -u' 2>/dev/null | grep -q '^0$'; then
        TN_RESTART_CMD='systemctl restart middlewared'
    fi
else
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "${LT_TN_USER}@${LT_TN_HOST}" 'sudo -n true' 2>/dev/null; then
        TN_RESTART_CMD='sudo systemctl restart middlewared'
    fi
fi
if [[ -z "${TN_RESTART_CMD}" ]]; then
    warn "no root/passwordless-sudo access on ${LT_TN_USER}@${LT_TN_HOST}; cannot restart middlewared non-interactively"
    warn "scenario skipped. Enable root ssh (or NOPASSWD sudo for systemctl) on the TN, or pass --tn-user with a user that has it."
    echo
    echo "===== SKIP ===== 07-tn-controller-restart (environment lacks privileged ssh) ====="
    exit 0
fi

lt_provision_vms

mark=$(lt_ssh 'date "+%Y-%m-%d %H:%M:%S"')
info "trigger: ${TN_RESTART_CMD} on ${LT_TN_HOST} (mark: ${mark})"
ssh -o ConnectTimeout=5 "${LT_TN_USER}@${LT_TN_HOST}" "${TN_RESTART_CMD}" || {
    fail "could not restart middlewared on ${LT_TN_HOST}"
    lt_summary; exit 1
}

# Wait for TN to report ready again.
info "waiting for middlewared to come back"
for i in $(seq 1 120); do
    if ssh -o ConnectTimeout=3 "${LT_TN_USER}@${LT_TN_HOST}" 'midclt ping 2>/dev/null | grep -q pong' 2>/dev/null; then
        info "  middlewared up after ${i}s"; break
    fi
    sleep 1
done

info "waiting ${LT_SETTLE_S}s for broker reconnect + pvestatd ticks"
sleep "${LT_SETTLE_S}"

lt_assert_no_storm "${mark}" "post-middlewared-restart"
lt_assert_broker_active
lt_assert_vms_present "after middlewared restart"

lt_cleanup_vms
lt_summary
