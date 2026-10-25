#!/usr/bin/env bash
# 06-network-flap.sh — drop the storage-NIC link for a few seconds
#
# Breaks every live broker WS session mid-flight. Broker's upstream
# calls get socket errors; next client call forces a reconnect
# through auth.login_with_api_key. Our concern: that reconnect
# doesn't fan out into a per-worker auth storm, and iSCSI/NVMe
# sessions resume cleanly.
#
# This test is self-stranding: we cannot ssh into the target while
# its NIC is down. We schedule the flap via `at` (or background
# sleep + ip link toggle) and ssh in AFTER it ends.
#
# Scenario-specific args:
#   --flap-s N  seconds to keep the NIC down (default 5).
#   --iface S   NIC to flap (default: autodetect from `ip -4 r get <tn-host>`).
#
# CAUTION: this test will drop ssh to the target node for the flap
# duration. If the target node is the only path to the TrueNAS,
# the broker will take longer to reconnect.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SELF_DIR}/common.sh"

LT_FLAP_S=5
LT_IFACE=""
lt_init "$@"; set -- "${LT_EXTRAS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --flap-s) LT_FLAP_S="$2"; shift 2 ;;
        --iface)  LT_IFACE="$2";  shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

lt_provision_vms

if [[ -z "${LT_IFACE}" ]]; then
    # Autodetect: the interface used to reach the TN host configured on
    # this storage. Read it off the plugin's own storage.cfg + ip-route.
    tn_host=$(lt_ssh "awk '/^\s*tn_api_host/ && !h {h=\$NF} END{print h}' /etc/pve/storage.cfg")
    [[ -z "${tn_host}" ]] && { fail "could not find tn_api_host"; lt_summary; exit 1; }
    LT_IFACE=$(lt_ssh "ip -4 route get ${tn_host} 2>/dev/null | awk '/dev / {for(i=1;i<=NF;i++) if (\$i==\"dev\") {print \$(i+1); exit}}'")
fi
[[ -z "${LT_IFACE}" ]] && { fail "could not autodetect iface"; lt_summary; exit 1; }
info "will flap iface ${LT_IFACE} for ${LT_FLAP_S}s"

mark=$(lt_ssh 'date "+%Y-%m-%d %H:%M:%S"')
info "trigger: ip link set ${LT_IFACE} down + sleep + up, scheduled via nohup (mark: ${mark})"

# The flap must survive our ssh connection being dropped. Schedule it
# as a nohup background job on the target with its own sleep.
lt_ssh "nohup bash -c '
    ip link set ${LT_IFACE} down
    sleep ${LT_FLAP_S}
    ip link set ${LT_IFACE} up
    # Give DHCP / addressing a few seconds
    sleep 10
    systemctl restart networking.service 2>/dev/null || true
' > /tmp/flap.log 2>&1 </dev/null &" || true

# Wait out the flap + a small cushion.
info "waiting out flap + 20s reconnect"
sleep "$((LT_FLAP_S + 20))"

# Reconnect.
for i in $(seq 1 60); do
    ssh -o ConnectTimeout=3 "root@${LT_NODE}" true 2>/dev/null && break
    sleep 1
done
sleep "${LT_SETTLE_S}"

lt_assert_no_storm "${mark}" "post-network-flap"
lt_assert_broker_active
lt_assert_vms_present "after network flap"

lt_cleanup_vms
lt_summary
