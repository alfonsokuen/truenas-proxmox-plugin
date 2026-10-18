#!/usr/bin/env bash
# tools/boot-reboot-test.sh
#
# Integration test for the plugin's boot-time behavior. Covers the
# class of regressions that the main `dev-truenas-plugin-full-function-test.sh`
# suite misses because that suite runs on an already-booted cluster.
#
# What this test exercises:
#   1. The broker's systemd unit comes up correctly and signals ready
#      (Type=notify + sd_notify_ready) before pvestatd/pvedaemon start.
#   2. pvestatd/pvedaemon never fall back to direct-WS auth at boot,
#      so TrueNAS's auth.login_with_api_key rate limit is never tripped.
#   3. Autostart VMs with disks on the plugin storage actually start.
#   4. graphical.target / is-system-running = running within a deadline.
#
# Related failure: GitHub #132 (phantomdez, 2026-10-16). Before the
# Type=notify + Before= ordering fix, boot would hang 10+ minutes with
# "broker socket missing" and "TrueNAS API rate limited" storms,
# graphical.target never reached, autostart VMs never fired.
#
# Usage:
#   tools/boot-reboot-test.sh \
#     --node <ssh-target> \
#     --storage <storage-id> \
#     [--vmid-start N] \
#     [--vm-count N] \
#     [--max-boot-s N]
#
# Example (against this project's test cluster):
#   tools/boot-reboot-test.sh \
#       --node 192.168.1.183 \
#       --storage truenas-storage \
#       --vmid-start 9880 --vm-count 3 --max-boot-s 300
#
# IMPORTANT: this test reboots the target node. Run against a
# DISPOSABLE PVE node, never against the orchestration host that is
# driving the main test suite. The target node must be a cluster
# member whose VMs can briefly go down (the test provisions and
# destroys its own VMs; it does not touch anything else).

set -uo pipefail

NODE=""
STORAGE=""
VMID_START=9880
VM_COUNT=3
MAX_BOOT_S=300
KEEP_VMS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node)        NODE="$2";       shift 2 ;;
        --storage)     STORAGE="$2";    shift 2 ;;
        --vmid-start)  VMID_START="$2"; shift 2 ;;
        --vm-count)    VM_COUNT="$2";   shift 2 ;;
        --max-boot-s)  MAX_BOOT_S="$2"; shift 2 ;;
        --keep-vms)    KEEP_VMS=1;      shift   ;;
        -h|--help)
            sed -n '2,/^$/p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "${NODE}" || -z "${STORAGE}" ]]; then
    echo "usage: $0 --node <ssh-target> --storage <storage-id> [--vmid-start N] [--vm-count N] [--max-boot-s N] [--keep-vms]" >&2
    exit 2
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
info() { echo -e "[INFO] $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }

# Hard-stop on ssh failure during setup/teardown; the per-assert
# invocations do their own checks and tolerate failure.
ssh_do() {
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@${NODE}" "$@"
}

###############################################################################
info "========== TARGET =========="
info "node:         ${NODE}"
info "storage:      ${STORAGE}"
info "VMID range:   ${VMID_START}..$((VMID_START + VM_COUNT - 1))"
info "max boot:     ${MAX_BOOT_S}s"
info "keep VMs:     ${KEEP_VMS}"
info "orchestrator: $(hostname)"
echo

###############################################################################
info "========== CLEANUP: residue from any previous run =========="
for ((i=0; i<VM_COUNT; i++)); do
    id=$((VMID_START + i))
    ssh_do "qm stop ${id} 2>&1 | head -2 || true; qm destroy ${id} --purge 1 2>&1 | head -2 || true" >/dev/null 2>&1 || true
done
echo

###############################################################################
info "========== PROVISION: ${VM_COUNT} VMs with onboot=1 on ${STORAGE} =========="
for ((i=0; i<VM_COUNT; i++)); do
    id=$((VMID_START + i))
    out=$(ssh_do "qm create ${id} \
        -name boot-test-${id} \
        -memory 128 -cores 1 -cpu host -ostype l26 \
        -onboot 1 \
        -scsihw virtio-scsi-single \
        -scsi0 ${STORAGE}:1,discard=on \
        -net0 virtio,bridge=vmbr0 \
        2>&1 | tail -3")
    if [[ "${out}" != *"successfully created disk"* ]]; then
        fail "VM ${id} create: ${out}"
        info "aborting; the environment is not clean"
        exit 1
    fi
    info "  VM ${id} created"
done
echo

###############################################################################
info "========== REBOOT: triggering systemctl reboot on ${NODE} =========="
boot_start=$(date +%s)
ssh_do 'nohup systemctl reboot >/dev/null 2>&1 &' || true
sleep 10

info "waiting for ${NODE} to go down..."
for i in $(seq 1 60); do
    if ! ping -c 1 -W 1 "${NODE}" >/dev/null 2>&1; then
        info "  down after ${i}s"
        break
    fi
    sleep 1
done

info "waiting for ${NODE} to come back (ssh)..."
back_at=0
for i in $(seq 1 ${MAX_BOOT_S}); do
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "root@${NODE}" true 2>/dev/null; then
        back_at=$(date +%s)
        info "  back after $(( back_at - boot_start ))s"
        break
    fi
    sleep 1
done
if [[ ${back_at} -eq 0 ]]; then
    fail "node did not accept SSH within ${MAX_BOOT_S}s of reboot"
    exit 1
fi
echo

###############################################################################
info "========== WAIT: is-system-running = running (deadline $((MAX_BOOT_S))s total) =========="
state=""
for i in $(seq 1 60); do
    state=$(ssh_do 'systemctl is-system-running' 2>&1)
    case "${state}" in
        running)        info "  reached 'running' after ${i}s of polling"; break ;;
        starting)       sleep 2 ;;
        degraded)       warn "  state=degraded (some unit failed); continuing to probe once"; break ;;
        *)              sleep 2 ;;
    esac
done

now=$(date +%s)
if [[ "${state}" == "running" ]]; then
    pass "systemctl is-system-running = running (total $(( now - boot_start ))s from reboot)"
elif [[ "${state}" == "degraded" ]]; then
    warn "systemctl is-system-running = degraded (continuing with other checks)"
    ssh_do 'systemctl --failed --no-pager' || true
else
    fail "systemctl is-system-running = '${state}' (not running) at $(( now - boot_start ))s"
fi
echo

###############################################################################
info "========== ASSERT: no 'broker socket missing' errors this boot =========="
bsm=$(ssh_do "journalctl -b 0 -t truenasplugin --no-pager 2>/dev/null | grep -c 'broker socket missing' || true")
bsm=${bsm:-0}
if [[ "${bsm}" -eq 0 ]]; then
    pass "zero 'broker socket missing' entries in journalctl -b 0 -t truenasplugin"
else
    fail "${bsm} 'broker socket missing' entries this boot — broker ordering regression"
    ssh_do "journalctl -b 0 -t truenasplugin --no-pager 2>/dev/null | grep 'broker socket missing' | head -5" || true
fi
echo

info "========== ASSERT: no 'rate limited' errors this boot =========="
rl=$(ssh_do "journalctl -b 0 -t truenasplugin --no-pager 2>/dev/null | grep -c 'rate limited' || true")
rl=${rl:-0}
if [[ "${rl}" -eq 0 ]]; then
    pass "zero 'rate limited' entries in journalctl -b 0 -t truenasplugin"
else
    fail "${rl} 'rate limited' entries this boot — direct-WS auth storm regression"
    ssh_do "journalctl -b 0 -t truenasplugin --no-pager 2>/dev/null | grep 'rate limited' | head -3" || true
fi
echo

###############################################################################
info "========== ASSERT: broker service is active =========="
if ssh_do 'systemctl is-active truenas-plugin-broker >/dev/null 2>&1'; then
    pass "truenas-plugin-broker is active"
else
    fail "truenas-plugin-broker is not active"
    ssh_do 'systemctl status truenas-plugin-broker --no-pager | head -10' || true
fi
echo

info "========== ASSERT: broker unit uses Type=notify + correct Before= =========="
unit_type=$(ssh_do 'systemctl show truenas-plugin-broker --property=Type --value' 2>/dev/null)
unit_before=$(ssh_do 'systemctl show truenas-plugin-broker --property=Before --value' 2>/dev/null)
if [[ "${unit_type}" == "notify" ]]; then
    pass "broker unit Type=notify"
else
    fail "broker unit Type=${unit_type} (expected notify)"
fi
need_before=(pvestatd.service pvedaemon.service pveproxy.service)
missing=()
for svc in "${need_before[@]}"; do
    [[ "${unit_before}" != *"${svc}"* ]] && missing+=("${svc}")
done
if [[ ${#missing[@]} -eq 0 ]]; then
    pass "broker Before= includes pvestatd/pvedaemon/pveproxy"
else
    fail "broker Before= missing: ${missing[*]}"
fi
echo

###############################################################################
info "========== ASSERT: all ${VM_COUNT} onboot VMs are running =========="
not_running=0
for ((i=0; i<VM_COUNT; i++)); do
    id=$((VMID_START + i))
    s=$(ssh_do "qm status ${id} 2>&1 | awk '{print \$2}'")
    if [[ "${s}" == "running" ]]; then
        info "  VM ${id}: running"
    else
        warn "  VM ${id}: ${s}"
        not_running=$((not_running + 1))
    fi
done
if [[ ${not_running} -eq 0 ]]; then
    pass "all ${VM_COUNT} onboot=1 VMs are running"
else
    fail "${not_running} of ${VM_COUNT} VMs are not running — pve-guests autostart failed"
fi
echo

###############################################################################
if [[ ${KEEP_VMS} -eq 0 ]]; then
    info "========== CLEANUP: destroy test VMs =========="
    for ((i=0; i<VM_COUNT; i++)); do
        id=$((VMID_START + i))
        ssh_do "qm stop ${id} 2>&1 | head -2 || true; qm destroy ${id} --purge 1 2>&1 | head -2" | head -3
    done
    echo
fi

###############################################################################
echo
if [[ ${FAIL} -eq 0 ]]; then
    echo -e "${GREEN}===== PASS ===== ${PASS} assertions passed =====${NC}"
    exit 0
else
    echo -e "${RED}===== FAIL ===== ${FAIL} assertion(s) failed, ${PASS} passed =====${NC}"
    exit 1
fi
