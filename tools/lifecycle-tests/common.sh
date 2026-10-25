#!/usr/bin/env bash
# tools/lifecycle-tests/common.sh
#
# Shared harness for the lifecycle-tests suite. Sourced (not executed)
# by the per-scenario scripts in this directory. Each scenario parses
# the standard args, calls `lt_init "$@"`, provisions N test VMs on
# the target node, triggers its specific lifecycle event, and uses
# the shared assertion helpers.
#
# Scenarios: tests under lifecycle-tests/ cover one lifecycle event
# per script (reboot, broker-restart, broker-crash, package-upgrade,
# etc.). Every scenario is destructive to the target node in some
# way; see each script's header for the specific scope.

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'

LT_NODE=""
LT_STORAGE=""
LT_VMID_START=10100
LT_VM_COUNT=3
LT_SETTLE_S=30
LT_KEEP_VMS=0
LT_PASS=0
LT_FAIL=0

# ------------------------------------------------------------------ output
info() { echo -e "${BLU}[INFO]${NC} $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; LT_PASS=$((LT_PASS + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; LT_FAIL=$((LT_FAIL + 1)); }

# ------------------------------------------------------------------ ssh wrapper
# Short connect timeout so a hung target doesn't block us.
lt_ssh() {
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@${LT_NODE}" "$@"
}
lt_ssh_tn() {
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "truenas_admin@$1" "${@:2}"
}

# ------------------------------------------------------------------ arg parse
lt_usage() {
    cat <<EOF
Usage: $0 --node <ssh-target> --storage <storage-id>
          [--vmid-start N] [--vm-count N] [--settle-s N]
          [--keep-vms]

Standard args understood by every scenario in this directory.

  --node        ssh target (hostname or IP) of a DISPOSABLE PVE node.
  --storage     truenasplugin storage id configured on that node.
  --vmid-start  first VMID to use for test VMs (default 10100).
  --vm-count    how many test VMs to provision (default 3).
  --settle-s    seconds to wait after the lifecycle event before
                scanning for the no-storm counters (default 30).
  --keep-vms    don't destroy the test VMs on exit (debugging only).

Per-scenario args, if any, are documented in each script's header.
EOF
}

# Parse the standard args. Must be called in the OUTER shell (not in a
# command substitution) so the LT_* globals it sets survive. Scenarios
# use the LT_EXTRAS array for the args this function didn't consume.
#
#   lt_init "$@"
#   set -- "${LT_EXTRAS[@]}"   # if the scenario has extra args
#
# Not: EXTRAS=$(lt_init "$@") — that subshells the function and the
# globals die with it; every ssh then runs with LT_NODE empty.
LT_EXTRAS=()
lt_init() {
    LT_EXTRAS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node)        LT_NODE="$2";       shift 2 ;;
            --storage)     LT_STORAGE="$2";    shift 2 ;;
            --vmid-start)  LT_VMID_START="$2"; shift 2 ;;
            --vm-count)    LT_VM_COUNT="$2";   shift 2 ;;
            --settle-s)    LT_SETTLE_S="$2";   shift 2 ;;
            --keep-vms)    LT_KEEP_VMS=1;      shift   ;;
            -h|--help)     lt_usage; exit 0  ;;
            *)             LT_EXTRAS+=("$1");  shift   ;;
        esac
    done
    if [[ -z "${LT_NODE}" || -z "${LT_STORAGE}" ]]; then
        lt_usage; exit 2
    fi
}

# ------------------------------------------------------------------ VM provisioning
lt_provision_vms() {
    info "provisioning ${LT_VM_COUNT} VMs with onboot=1 on ${LT_STORAGE} (VMIDs ${LT_VMID_START}..$((LT_VMID_START + LT_VM_COUNT - 1)))"
    # Clean any residue first.
    for ((i=0; i<LT_VM_COUNT; i++)); do
        local id=$((LT_VMID_START + i))
        lt_ssh "qm stop ${id} 2>&1 | head -1 || true; qm destroy ${id} --purge 1 2>&1 | head -2 || true" >/dev/null 2>&1 || true
    done
    sleep 2
    for ((i=0; i<LT_VM_COUNT; i++)); do
        local id=$((LT_VMID_START + i))
        local out=$(lt_ssh "qm create ${id} \
            -name lt-${id} \
            -memory 128 -cores 1 -cpu host -ostype l26 \
            -onboot 1 \
            -scsihw virtio-scsi-single \
            -scsi0 ${LT_STORAGE}:1,discard=on \
            -net0 virtio,bridge=vmbr0 \
            2>&1 | tail -3")
        if [[ "${out}" != *"successfully created disk"* ]]; then
            fail "VM ${id} create: ${out}"
            info "aborting; the environment is not clean"
            exit 1
        fi
    done
}

lt_cleanup_vms() {
    [[ "${LT_KEEP_VMS}" -eq 1 ]] && return
    info "destroying test VMs"
    for ((i=0; i<LT_VM_COUNT; i++)); do
        local id=$((LT_VMID_START + i))
        lt_ssh "qm stop ${id} 2>&1 | head -1 || true" >/dev/null 2>&1 || true
    done
    sleep 2
    for ((i=0; i<LT_VM_COUNT; i++)); do
        local id=$((LT_VMID_START + i))
        lt_ssh "qm destroy ${id} --purge 1 2>&1 | head -2" | head -2
    done
}

# ------------------------------------------------------------------ assertion helpers
# `since` is a timestamp understood by `journalctl --since`, e.g.
# `"-2min"` or `"2026-10-16 13:30:00"`. All assertions grep against
# `journalctl -t truenasplugin` since that moment.
lt_assert_no_pattern() {
    local pattern="$1" since="$2" label="$3"
    local n=$(lt_ssh "journalctl -t truenasplugin --since '${since}' --no-pager 2>/dev/null | grep -c -F -- '${pattern}' || true")
    n=${n:-0}
    if [[ "${n}" -eq 0 ]]; then
        pass "zero '${pattern}' entries since ${since} (${label})"
    else
        fail "${n} '${pattern}' entries since ${since} (${label}) — regression"
        lt_ssh "journalctl -t truenasplugin --since '${since}' --no-pager 2>/dev/null | grep -F -- '${pattern}' | head -5" || true
    fi
}

lt_assert_broker_active() {
    if lt_ssh 'systemctl is-active truenas-plugin-broker >/dev/null 2>&1'; then
        pass "truenas-plugin-broker is active"
    else
        fail "truenas-plugin-broker is not active"
        lt_ssh 'systemctl status truenas-plugin-broker --no-pager | head -10' || true
    fi
}

lt_assert_vms_running() {
    local label="$1"
    local not=0
    for ((i=0; i<LT_VM_COUNT; i++)); do
        local id=$((LT_VMID_START + i))
        local s=$(lt_ssh "qm status ${id} 2>&1 | awk '{print \$2}'")
        if [[ "${s}" == "running" ]]; then
            info "  VM ${id}: running"
        else
            warn "  VM ${id}: ${s}"
            not=$((not + 1))
        fi
    done
    if [[ ${not} -eq 0 ]]; then
        pass "all ${LT_VM_COUNT} test VMs are running (${label})"
    else
        fail "${not} of ${LT_VM_COUNT} VMs not running (${label})"
    fi
}

# For scenarios that don't start the test VMs (no reboot, no autostart
# trigger): verify the VMs still exist and are in a known state
# (running OR stopped — never missing / in-error). Catches VM state
# corruption without over-asserting "must be running".
lt_assert_vms_present() {
    local label="$1"
    local bad=0
    for ((i=0; i<LT_VM_COUNT; i++)); do
        local id=$((LT_VMID_START + i))
        local s=$(lt_ssh "qm status ${id} 2>&1 | awk '{print \$2}'")
        case "${s}" in
            running|stopped) info "  VM ${id}: ${s}" ;;
            *)               warn "  VM ${id}: ${s}"; bad=$((bad + 1)) ;;
        esac
    done
    if [[ ${bad} -eq 0 ]]; then
        pass "all ${LT_VM_COUNT} test VMs are in a known state (${label})"
    else
        fail "${bad} of ${LT_VM_COUNT} VMs in unknown state (${label})"
    fi
}

# Verifies the standard storm counters are clean since the given moment.
# All lifecycle scenarios call this after their event + settle.
lt_assert_no_storm() {
    local since="$1" label="$2"
    lt_assert_no_pattern 'broker socket missing' "${since}" "${label}"
    lt_assert_no_pattern 'rate limited'          "${since}" "${label}"
}

# ------------------------------------------------------------------ summary / exit
lt_summary() {
    echo
    if [[ ${LT_FAIL} -eq 0 ]]; then
        echo -e "${GREEN}===== PASS ===== ${LT_PASS} assertions passed =====${NC}"
        return 0
    else
        echo -e "${RED}===== FAIL ===== ${LT_FAIL} assertion(s) failed, ${LT_PASS} passed =====${NC}"
        return 1
    fi
}
