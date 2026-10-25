#!/usr/bin/env bash
# 04-package-upgrade.sh — reinstall the plugin .deb while VMs are running
#
# Exercises postinst's broker-restart behavior under live load.
# `apt install` over an existing install triggers prerm (stop broker),
# dpkg -i (replace files), postinst (daemon-reload + restart broker).
# During the brief gap pvedaemon/pvestatd calls into the plugin see
# the socket missing. We assert no storm.
#
# Scenario-specific args:
#   --deb-path PATH   path to the .deb to install (default: find under /home/wmo/)
#   --skip-start-vms  don't start the staged VMs before upgrade (default: start)

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SELF_DIR}/common.sh"

LT_DEB_PATH=""
LT_SKIP_START_VMS=0
lt_init "$@"; set -- "${LT_EXTRAS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --deb-path)        LT_DEB_PATH="$2"; shift 2 ;;
        --skip-start-vms)  LT_SKIP_START_VMS=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "${LT_DEB_PATH}" ]]; then
    # Pick the most-recently-built .deb from the orchestrator's /home/wmo
    LT_DEB_PATH=$(ls -t /home/wmo/truenas-proxmox-plugin_*.deb 2>/dev/null | head -1)
fi
if [[ -z "${LT_DEB_PATH}" || ! -f "${LT_DEB_PATH}" ]]; then
    fail "could not find a .deb to install (pass --deb-path)"
    lt_summary; exit 1
fi
info "will install: ${LT_DEB_PATH}"

lt_provision_vms

# Optionally start the VMs so there's active I/O against the plugin
# while we upgrade.
if [[ ${LT_SKIP_START_VMS} -eq 0 ]]; then
    for ((i=0; i<LT_VM_COUNT; i++)); do
        id=$((LT_VMID_START + i))
        lt_ssh "qm start ${id} >/dev/null 2>&1 || true"
    done
    info "waiting 10s for VMs to be up"
    sleep 10
fi

mark=$(lt_ssh 'date "+%Y-%m-%d %H:%M:%S"')
info "trigger: scp + dpkg -i ${LT_DEB_PATH} on ${LT_NODE} (mark: ${mark})"
scp -q "${LT_DEB_PATH}" "root@${LT_NODE}:/tmp/"
lt_ssh "DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/$(basename "${LT_DEB_PATH}") 2>&1 | tail -5 && rm -f /tmp/$(basename "${LT_DEB_PATH}")"

info "waiting ${LT_SETTLE_S}s for broker + callers to settle"
sleep "${LT_SETTLE_S}"

lt_assert_no_storm "${mark}" "post-upgrade"
lt_assert_broker_active
lt_assert_vms_running "after apt upgrade"

lt_cleanup_vms
lt_summary
