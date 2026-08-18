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
| F4 | API loss (management VLAN blacked out) | **4 of 4 assertions failed** - see below. Recovers unattended, no data loss. |

F1 refuses to start at all if `nvme_core.multipath != Y`, and measures which path
is actually carrying I/O before cutting it — cutting the path you *assume* is
active proves nothing.

### F4 in detail — the API goes away

`tools/i32-apiloss.sh`. The array stays up, the fabric stays up, guest I/O is
untouched; only the management API stops answering. Reproduced by dropping the
array's *replies* on the input hook — dropping outbound instead returns EPERM in
microseconds, which is a different failure and would have proved nothing.

Two defects, both reproduced in isolation with a positive control:

**`pvesm list` invents an empty storage.** With the API up, 2 volumes in 570 ms.
With the API blacked out: **0 volumes, exit code 0**, after 155 s. It recovers
to 2 as soon as the API returns, so the storage was never the problem — the
plugin simply could not ask, and reported "nothing there" instead of saying so.

This is the most dangerous thing found in the whole campaign, and it is not a
hang. Reconciliation is exactly the job that compares PVE's list against the
array to decide what is an orphan. Fed this answer, a reconciler concludes every
dataset on the array is garbage. **Any cleanup built on `pvesm list` has to
prove the API is reachable first, and must treat "cannot ask" as a state
distinct from "empty".** It is the same shape as the sync script that unexported
every namespace because a failed query looked like an empty list.

**`pvesm alloc` hangs, and keeps the storage lock.** It did not return within
180 s — comfortably past the ~127 s at which a TCP connect gives up, so this is
not the kernel timing out once, it is the plugin retrying. Fleecing calls
`alloc` on every backup, unattended, at night: an API outage during a backup
window parks the storage lock for as long as the outage lasts.

**One unreachable storage darkens the whole node's management plane.** During
the blackout, **6 unrelated storages stopped answering** — `local`, `local-zfs`,
`TN-NVMeOF-VM`, `PBS-S3`, `PB_NFS`, `tn-pilot` — while `local` itself answered
instantly at the filesystem level (`ls`, 3 ms; `zfs list`, 7 ms). `pvesm status`
computes every storage before filtering, so one stalled truenasplugin storage
blocks status for all of them. pvestatd stopped writing metrics entirely — and
systemd still reported it `active`, which is why the test asserts on the RRD
mtime rather than on `systemctl is-active`.

Guests keep running throughout; quorum holds; it recovers unattended with no
restart. The blast radius is observability and management, not data. But it does
mean an API outage on the array makes the whole node look sick.

Timing worth writing down: a TCP connect gives up after ~127 s here
(`tcp_syn_retries=6`). An earlier run capped operations at 120 s and read the
result as "hangs forever" — 7 seconds short of the truth. The cap now sits well
above 127 s, and below the blackout window, so a hang cannot be rescued by the
watchdog and misread as success.

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
- **`pvesm list` reports an empty storage, exit 0, when the API is unreachable.**
  See F4 above. This one gates the orphan reconciler: the reconciler cannot be
  built on `pvesm list` alone.
- **A stalled storage blocks `pvesm status` for every storage on the node**, and
  stops pvestatd writing metrics while systemd still calls it active.

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
