#!/usr/bin/env bash
# 05-pvestatd-restart.sh — restart pvestatd alone, broker up
#
# Inverse-race direction from 01/02: broker is up and listening the
# whole time, but pvestatd restarts. On restart, pvestatd issues a
# fresh wave of status() calls against every truenasplugin storage
# as part of its startup pass. We assert that first wave doesn't
# trip any storm counters.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SELF_DIR}/common.sh"

lt_init "$@"; set -- "${LT_EXTRAS[@]}"
[[ $# -gt 0 ]] && { echo "unknown args: $*" >&2; exit 2; }

lt_provision_vms

# Verify broker is up and settled first.
lt_assert_broker_active

mark=$(lt_ssh 'date "+%Y-%m-%d %H:%M:%S"')
info "trigger: systemctl restart pvestatd (mark: ${mark})"
lt_ssh 'systemctl restart pvestatd'

info "waiting ${LT_SETTLE_S}s for pvestatd ticks"
sleep "${LT_SETTLE_S}"

lt_assert_no_storm "${mark}" "post-pvestatd-restart"
lt_assert_broker_active
lt_assert_vms_present "after pvestatd restart"

lt_cleanup_vms
lt_summary
