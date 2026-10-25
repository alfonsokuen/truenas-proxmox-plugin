#!/usr/bin/env bash
# 01-reboot.sh — full node reboot
#
# Reproduces GitHub #132's reproducer. Pre-stages N test VMs with
# onboot=1 on the target storage, reboots the target node, waits
# for ssh return + is-system-running to flip to running (or
# degraded), then asserts no `broker socket missing` or `rate
# limited` entries during this boot cycle, and that all autostart
# VMs reached running.
#
# Scenario-specific args:
#   --max-boot-s N   deadline for ssh to come back (default 300).

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SELF_DIR}/common.sh"

LT_MAX_BOOT_S=300
LT_AUTOSTART_WAIT_S=240
lt_init "$@"; set -- "${LT_EXTRAS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-boot-s)        LT_MAX_BOOT_S="$2";        shift 2 ;;
        --autostart-wait-s)  LT_AUTOSTART_WAIT_S="$2";  shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

lt_provision_vms

boot_mark=$(lt_ssh 'date "+%Y-%m-%d %H:%M:%S"')
info "trigger: systemctl reboot (marker: ${boot_mark})"
lt_ssh 'nohup systemctl reboot >/dev/null 2>&1 &' || true
sleep 10
for i in $(seq 1 60); do
    ! ping -c 1 -W 1 "${LT_NODE}" >/dev/null 2>&1 && break
    sleep 1
done

info "waiting for ssh return (deadline ${LT_MAX_BOOT_S}s)"
back=0
for i in $(seq 1 ${LT_MAX_BOOT_S}); do
    if ssh -o ConnectTimeout=3 "root@${LT_NODE}" true 2>/dev/null; then
        back=${i}; info "  back after ${i}s"; break
    fi
    sleep 1
done
[[ ${back} -eq 0 ]] && { fail "node did not accept ssh within ${LT_MAX_BOOT_S}s"; lt_summary; exit 1; }

# ssh being back doesn't mean pve-guests has finished autostarting
# the onboot=1 VMs. Poll qm status until all test VMs are `running`
# or we hit the LT_AUTOSTART_WAIT_S cap. On a healthy boot this is a
# few tens of seconds; on a stuck boot it's catching the fail
# condition we care about. is-system-running can stay `degraded` on
# this node for unrelated reasons (open-iscsi failing a stale
# auto-login portal), so key off VM state directly.
info "waiting for all ${LT_VM_COUNT} test VMs to reach 'running' (cap ${LT_AUTOSTART_WAIT_S}s)"
VMID_END=$((LT_VMID_START + LT_VM_COUNT - 1))
running_at=0
for i in $(seq 1 "${LT_AUTOSTART_WAIT_S}"); do
    running_count=$(lt_ssh "qm list 2>/dev/null | awk 'NR>1 && \$3==\"running\" && \$1>=${LT_VMID_START} && \$1<=${VMID_END} {c++} END{print c+0}'")
    if [[ "${running_count}" == "${LT_VM_COUNT}" ]]; then
        running_at=${i}
        info "  all ${LT_VM_COUNT} running after ${i}s"
        break
    fi
    sleep 1
done
if [[ ${running_at} -eq 0 ]]; then
    warn "autostart didn't finish within ${LT_AUTOSTART_WAIT_S}s (saw ${running_count:-?} / ${LT_VM_COUNT}); assertion will fail"
fi

# `since boot` scopes journalctl to this boot specifically.
lt_assert_no_pattern 'broker socket missing' 'today 00:00:00' "post-reboot"
lt_assert_no_pattern 'rate limited'          'today 00:00:00' "post-reboot"
lt_assert_broker_active
lt_assert_vms_running "post-reboot autostart"

lt_cleanup_vms
lt_summary
