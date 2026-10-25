#!/usr/bin/env bash
# 08-clock-jump.sh — jump the target's wall clock and watch recovery
#
# The plugin uses Time::HiRes `time()` for backoff deadlines, retry
# timeouts, cache liveness windows (LIVENESS_CACHE_SECS=60) and the
# NVMe stale-recovery iteration count. All of those read a monotonic
# clock on Linux, so a wall-clock jump shouldn't affect them — but
# the broker's and plugin's log timestamps, API-call auditing on the
# TN side, and TLS cert validity checks all touch wall time. This
# scenario forces +1 hour then -1 hour jumps and asserts no storm.
#
# NOTE: this test suspends NTP for its duration, then re-enables it.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SELF_DIR}/common.sh"

lt_init "$@"; set -- "${LT_EXTRAS[@]}"
[[ $# -gt 0 ]] && { echo "unknown args: $*" >&2; exit 2; }

lt_provision_vms

info "pausing timesyncd / chronyd so our clock jumps stick"
lt_ssh "systemctl stop systemd-timesyncd 2>/dev/null || true; systemctl stop chrony 2>/dev/null || true"

mark=$(lt_ssh 'date "+%Y-%m-%d %H:%M:%S"')
info "trigger A: jump +1h (mark: ${mark})"
lt_ssh "date -s '+1 hour' >/dev/null"
sleep 30

info "scanning for storm post-jump-forward"
lt_assert_no_storm "${mark}" "post-jump-+1h"
lt_assert_broker_active

mark_back=$(lt_ssh 'date "+%Y-%m-%d %H:%M:%S"')
info "trigger B: jump back -1h (mark: ${mark_back})"
lt_ssh "date -s '-1 hour' >/dev/null"
# Important: journalctl queries use timestamps in the current clock;
# scanning backwards after a backward jump will double-cover a window.
# That's harmless for a 'no match' assertion.
sleep 30

info "scanning for storm post-jump-backward"
lt_assert_no_storm "${mark_back}" "post-jump--1h"
lt_assert_broker_active

info "re-enabling timesyncd / chrony"
lt_ssh "systemctl start systemd-timesyncd 2>/dev/null || true; systemctl start chrony 2>/dev/null || true"
# Give NTP a few seconds to resync.
sleep 15

lt_assert_vms_present "after clock jumps + ntp resync"

lt_cleanup_vms
lt_summary
