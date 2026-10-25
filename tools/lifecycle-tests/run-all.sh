#!/usr/bin/env bash
# run-all.sh — run every lifecycle-tests scenario in sequence
#
# Order is deliberate: cheapest and most-contained first, then the
# ones that disturb more (network flap, TN control-plane bounce,
# reboot last since it kicks the node itself).
#
# Pass the same --node / --storage / --vmid-start as to the
# individual scenarios; this script forwards them unchanged. Each
# scenario cleans up its own test VMs. Allocate a disjoint VMID
# range per run so parallel orchestrators don't collide.
#
# Exit 0 iff every scenario exits 0.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORDER=(
    "05-pvestatd-restart.sh"
    "02-broker-restart-under-load.sh"
    "03-broker-crash.sh"
    "04-package-upgrade.sh"
    "08-clock-jump.sh"
    "06-network-flap.sh"
    "07-tn-controller-restart.sh"
    "01-reboot.sh"
)

FAIL=0
for s in "${ORDER[@]}"; do
    echo
    echo "################################################################"
    echo "## $s"
    echo "################################################################"
    if ! bash "${SELF_DIR}/${s}" "$@"; then
        FAIL=$((FAIL + 1))
        echo "---- $s FAILED ----"
    fi
done

echo
echo "================================================================"
if [[ ${FAIL} -eq 0 ]]; then
    echo "===== lifecycle-tests: all 8 scenarios PASS ====="
    exit 0
else
    echo "===== lifecycle-tests: ${FAIL} scenarios FAILED ====="
    exit 1
fi
