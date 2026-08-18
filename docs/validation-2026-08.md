# Validation record — August 2026

What was actually exercised, how, and — the part that matters more — what was
not. Run against a TrueNAS 25.10.4 array over nvme-tcp from a three-node
Proxmox VE 9 cluster, with native multipath over two fabrics.

## Suites

| Suite | Result | Covers |
|---|---|---|
| `tools/i32-lifecycle.sh` | 25/25 | create, resize, clone, vzdump + qmrestore, move-disk round trip, template, linked clone with isolation proven |
| `tools/i32-deep.sh` D1+D2 | 23/23 | chain of 3 snapshots including deletion of the middle one, hot backup + restore |
| `tools/i32-livevm-test.sh` | 17/17 | `--vmstate` snapshot in 3 s without stopping the VM, rollback in 26 s, RAM restored |

Verification is at file level, not block level: 203–243 files per `sha256`, with
the manifest **recomputed independently on the hypervisor**, and `fsck` producing
real output (`Pass 5`) at every phase. Separately, a 256 MiB end-to-end transfer
compared byte-identical, with a generator-determinism control.

Two places where this plugin beats qcow2-on-LVM outright:

- **Deleting an intermediate snapshot works** (ZFS snapshots, not backing
  chains). On qcow2-over-LVM that breaks the chain permanently.
- **A disk returns from another storage without losing capabilities.** LVM hands
  it back as raw and drops the snapshots silently.

## Fault injection

| # | Injection | Result |
|---|---|---|
| F1 | Path failure (`nft` input hook, `saddr`/`sport`) | I/O continues on the surviving path. Positive control: cutting *every* path must stop I/O — it did. |
| F2 | Target `nvmet` stopped under load | I/O **stopped** rather than erroring (`ctrl_loss_tmo=-1`), 0 failures, other protocols on the array unaffected, full render on restart, data intact |
| F3 | Broker killed mid-flight | systemd revives it; **found a real bug**, see below |
| F5 | discard / TRIM | Space reclaimed in both directions, with a positive **and** a negative control |
| F4 | API loss | **not run** |

F1 refuses to start at all if `nvme_core.multipath != Y`, and measures which path
is actually carrying I/O before cutting it — cutting the path you *assume* is
active proves nothing.

## Bugs this found

- **`pvesm free` exits 0 regardless of the worker's outcome.** Only a nonexistent
  *storage* yields 255; a failed delete is recorded solely in the task log. The
  volume is dropped from PVE's view while the dataset stays on the array —
  orphans accumulate with no signal. (An earlier claim about this was retracted
  as unreproducible; it is reproducible, but the mechanism is PVE's exit code,
  not PVE forgetting the volume.)
- **`free_image` inferred deletion from a substring** of the error text. Now it
  probes the array and refuses to report success while the dataset is still
  there, and refuses to guess when the API cannot be reached.
- **`nvme-recovery.sh` ran `nvme disconnect-all`** and told the operator to do it
  on every node — which on a node whose local VG rides an NVMe namespace would
  disconnect live VMs. It now disconnects only the NQNs named in
  `/etc/pve/storage.cfg`, and says so when it finds none.
- **The broker let one caller hold every storage on the node** for the full
  budget. Budget is now validated, and the listen backlog raised.
- **`nvmet.subsys.update` does not accept `model`** — which falsified the cheapest
  proposed workaround for NAS-140266 before it was written.

## NAS-140266 (the blocker)

Root-caused end to end: `dmidecode` reports an empty `system-product-name` on
this chassis, so the middleware builds the model string `'TrueNAS '` with a
trailing space; `update_attrs()` reads configfs back with `.strip()`, so the
comparison never matches and every render retries the `attr_model` write; the
kernel refuses it once a host has discovered the subsystem, and the exception
aborts the rest of the render — so namespaces and `allowed_hosts` never reach
the kernel. A/B confirmed against a second array on different hardware, which
reports a real product name and works unpatched.

Fixed by iX only in TrueNAS 26 BETA. See `contrib/truenas/` for the patch and a
checker; it is worth stressing that a system update reverts the patch silently,
which is why the checker exists and why it has a `--self-test`.

## What is NOT proven

Stated plainly, because a green run is not evidence of anything it did not test:

- **Node failure with fencing, carrying plugin volumes.** The validated live
  migration is a *graceful* one — the source cooperates. A fenced node does not.
- **Soak.** Every measurement above is a burst of minutes. Leaks, session-pool
  degradation and orphan accumulation are by construction invisible at that
  timescale.
- **Concurrency.** One VM at a time, never N across three nodes with `pvestatd`
  polling and a backup window on top.
- **Performance.** Unmeasured. This gates the *justification* for migrating, not
  the safety of it.
- **Fleecing**, which does `alloc` + `free` on every backup, unattended. Highest
  orphan-production rate of any path; do not migrate it before reconciliation
  exists.
- **iSCSI.** The `path()` branch still dies. nvme-tcp only.

## Method

Two independent QA passes on every stage, and a rule learned the hard way:
**a check that cannot fail is not a check.** Families of vacuous PASS found and
corrected in these very suites:

- `pass` on both branches of an `if`
- rollback to the state the system was already in — a no-op that passed
- a tool that aborts and still exits 0 (`e2fsck -fn` on a mounted fs); and with
  `-n`, `rc=1` means *there are errors*, so only 0 is clean
- a failed query read as an empty list, which drove a withdrawal loop to
  unexport everything
- a detector that could only ever say "healthy", with no INCONCLUSIVE state

The remedy in every case is a positive control: break it on purpose and require
the test to notice. Several conclusions in this document were reversed by doing
that, including two "failures" that turned out to be the harness, not the plugin.
