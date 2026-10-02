# Known Limitations

Important limitations, restrictions, and workarounds for the TrueNAS Proxmox VE Storage Plugin.

## Table of Contents

- [Critical Workflow Limitations](#critical-workflow-limitations)
  - [Offline cross-storage disk operations (upstream QEMU regression)](#offline-cross-storage-disk-operations-upstream-qemu-regression)
  - [VM deletion (`qm destroy`)](#vm-deletion-qm-destroy)
- [Storage Feature Limitations](#storage-feature-limitations)
  - [Clone semantics](#clone-semantics)
  - [No Volume Shrinking](#no-volume-shrinking)
  - [Resize Headroom Limit](#resize-headroom-limit)
- [Content Type Limitations](#content-type-limitations)
  - [Supported content types](#supported-content-types)
  - [Not supported (and probably shouldn't be, in this plugin)](#not-supported-and-probably-shouldnt-be-in-this-plugin)
- [Snapshot Limitations](#snapshot-limitations)
  - [vzdump captures live state, not snapshot history](#vzdump-captures-live-state-not-snapshot-history)
- [Live Migration Limitations](#live-migration-limitations)
  - [Requires Shared Storage](#requires-shared-storage)
  - [vmstate Storage Considerations](#vmstate-storage-considerations)
  - [Shared CPU model required across heterogeneous nodes](#shared-cpu-model-required-across-heterogeneous-nodes)
- [TrueNAS Specific Limitations](#truenas-specific-limitations)
  - [API Rate Limits](#api-rate-limits)
  - [WebSocket Connection Stability](#websocket-connection-stability)
  - [Version Compatibility](#version-compatibility)
- [Proxmox Specific Limitations](#proxmox-specific-limitations)
  - [Proxmox Version Requirements](#proxmox-version-requirements)
  - [Custom Storage Plugin Directory](#custom-storage-plugin-directory)
- [Network Limitations](#network-limitations)
  - [No NFS/CIFS Support](#no-nfscifs-support)
  - [IPv6 Considerations](#ipv6-considerations)
- [Security Limitations](#security-limitations)
  - [No Mutual CHAP](#no-mutual-chap)
  - [API Key Storage](#api-key-storage)
  - [No SCSI persistent reservations for HA fencing](#no-scsi-persistent-reservations-for-ha-fencing)
  - [`rename_volume` not implemented](#rename_volume-not-implemented)
- [Performance Limitations](#performance-limitations)
  - [Clone Performance](#clone-performance)
  - [Snapshot Overhead](#snapshot-overhead)
  - [Network-Bound Performance](#network-bound-performance)
  - [Multipath Read Performance Limitation](#multipath-read-performance-limitation)
- [Platform Limitations](#platform-limitations)
  - [Linux/Proxmox Only](#linuxproxmox-only)
  - [ZFS Dependency](#zfs-dependency)
- [Operational Limitations](#operational-limitations)
  - [No Bulk Deletion](#no-bulk-deletion)
  - [Configuration Changes Require Restart](#configuration-changes-require-restart)
  - [No Storage Overcommit Protection](#no-storage-overcommit-protection)
- [Workarounds Summary](#workarounds-summary)

---

## Critical Workflow Limitations

### Offline cross-storage disk operations (upstream QEMU regression)

**Limitation (external, not our plugin):** `qm move_disk` and
`qm clone --full` for a **stopped** VM, when source or destination is
on this plugin, fail against QEMU 10.1.x with:

```
qemu-img: error while writing at byte 2145386496: Invalid argument
```

The exact byte number (1023 × 2 MiB) is a structural QEMU regression.
PVE routes these operations straight to `qemu-img convert`, which
tries to hole-punch with a trailing 3584-byte non-4K-aligned chunk
and gets EINVAL from the kernel's `BLKZEROOUT`/`FALLOC_FL_PUNCH_HOLE`
path against our 4K-logical iSCSI LUNs. The write path is in QEMU,
not in us; no plugin method is on the call stack. Tracking:
[Proxmox bugzilla #7197](https://bugzilla.proxmox.com/show_bug.cgi?id=7197)
(status: **PATCH AVAILABLE**, assignee Fiona Ebner) and
[QEMU GitLab #3257](https://gitlab.com/qemu-project/qemu/-/issues/3257).

**Workarounds until the patch ships:**

- **Downgrade `pve-qemu-kvm` to 10.0.2-4** on every node and
  `apt-mark hold pve-qemu-kvm`. The regression is specific to 10.1.x.
  Example (apply on each node, then restart running VMs so they pick
  up the downgraded binary):
  ```bash
  wget http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/pve-qemu-kvm_10.0.2-4_amd64.deb
  apt-get install --allow-downgrades ./pve-qemu-kvm_10.0.2-4_amd64.deb
  apt-mark hold pve-qemu-kvm
  ```
- **Do the move or clone while the VM is running.** Online operations
  use QEMU's `drive-mirror` (via QMP), a different code path that
  does not trip the regression.
- **Use `pvesm export | pvesm import`** between storages. The plugin's
  `volume_import`/`volume_export` methods use `dd`-with-sparse rather
  than `qemu-img convert`, and work regardless of this bug.

Paths that bypass this bug and work normally: `vzdump → PBS` and
`qmrestore` from PBS (chunk-stream, not `qemu-img`), live migration
with shared storage (RAM-only), linked clones from templates (plugin's
own `clone_image` → ZFS clone on TrueNAS), and all normal VM I/O.

### VM deletion (`qm destroy`)

**Works correctly.** `qm destroy VMID --purge` cleans the Proxmox-side
config *and* calls the plugin's `free_image()` for every disk the VM
owned, which removes the zvol, the iSCSI extent, and the target-extent
mapping on TrueNAS. The same path runs when you delete the VM from
the web UI — both go through `PVE::QemuServer::destroy_vm` →
`foreach_volume_full` → `path()` → `remove_owned_drive` → `free_image()`.

Earlier plugin releases (pre-2.1.23~beta8) had a bug where `path()`
could hang 60 seconds and abort the destroy loop before `free_image`
ran, leaking state when the destroy ran on a node that had never
activated the disk locally (cross-node destroy of an orphan, destroy
after a leaked config-migrate, destroy on a node with the iSCSI
session down). That is tracked as #88 and is fixed in beta8:
`path()` now returns a deterministic by-path string when the device
is not locally attached, so the destroy loop never hangs. If you are
running pre-beta8 and see orphan zvols on TrueNAS after
`qm destroy` on a node where the disk was never activated, upgrade
to beta8 or later.

## Storage Feature Limitations

### Clone semantics

The plugin exposes two clone paths with different performance
characteristics. Which one PVE picks depends on whether you are
cloning a template or a running/stopped VM.

**Linked clones from a template (fast, native ZFS clone).** When
you convert a VM to a template with `qm template VMID`, the plugin
runs `create_base`: it renames the source zvol to `base-VMID-disk-N`
and takes an immutable `@__base__` snapshot. A subsequent
`qm clone BASE_VMID NEW_VMID` (linked clone) calls the plugin's
`clone_image()`, which issues `pool.snapshot.clone` on TrueNAS →
instant ZFS clone, no data copy, pure metadata operation. This is
the "fast clone" path, works today, and is the recommended way to
spin up copies of a known-good image.

**Full clones (`qm clone --full`) of a stopped VM.** PVE routes
these through `PVE::QemuServer::clone_disk` → `vdisk_alloc` →
`PVE::QemuServer::QemuImage::convert`, which runs `qemu-img convert`
over the raw block device. The plugin's `clone_image()` is **not**
on this call stack. Two consequences:

- Full-clone performance is bounded by `qemu-img convert`'s speed
  across the storage fabric, not by ZFS clone speed.
- On QEMU 10.1.x this path hits
  [Proxmox bugzilla #7197](https://bugzilla.proxmox.com/show_bug.cgi?id=7197)
  and fails at byte 2145386496. See the "Offline cross-storage disk
  operations" section above for the workaround (downgrade
  `pve-qemu-kvm` to 10.0.2-4) and the running-VM alternative that
  uses `drive-mirror` instead.

**Full clones of a running VM** (`qm clone --full` while the source
VM is powered on): PVE uses `drive-mirror` via QMP. Also not a
plugin method, but it bypasses the QEMU 10.1 regression — the
sparse-write path lives in `qemu-img convert`, not in the live
block-mirror code.

**Cross-storage full clone** (source and destination on different
storages): same as full clone above, same QEMU 10.1 caveat. For
cross-storage *moves*, prefer `pvesm export | pvesm import` or
`qm migrate … --targetstorage`, which route through the plugin's
`volume_export`/`volume_import` (as of 2.1.23~beta8+). Those stream
with `dd` and avoid `qemu-img convert` entirely.

### No Volume Shrinking

**Limitation**: Cannot reduce volume size, only grow

**Explanation**: ZFS does not support zvol shrinking

**Impact**:
- Can only use `qm resize VMID diskN +SIZE` (grow)
- Cannot use `qm resize VMID diskN SIZE` (set absolute size smaller)

**Workaround**:
```bash
# To "shrink" a disk:
# 1. Create new smaller volume
pvesm alloc truenas-storage 100 vm-100-disk-1 32G

# 2. Clone data from old disk to new disk (within VM or using rescue)
# 3. Detach old disk, attach new disk
qm set 100 --scsi1 truenas-storage:vm-100-disk-1

# 4. Delete old disk
pvesm free truenas-storage:vm-100-disk-0-lun1
```

### Resize Headroom Limit

**Limitation**: Can only resize volumes up to 80% of available dataset space

**Explanation**: Pre-flight checks enforce 20% safety margin for ZFS overhead

**Example**:
```
Dataset has 100GB free
Maximum resize: 80GB
Safety margin: 20GB (for ZFS metadata, snapshots, etc.)
```

**Impact**:
- Cannot resize volume to consume all available space
- Prevents pool exhaustion

**Workaround**:
```bash
# If you need more space:
# 1. Add storage to ZFS pool
# 2. Or free up space by deleting snapshots/volumes
# 3. Or use different dataset with more space
```

## Content Type Limitations

### Supported content types

The plugin ships block storage over iSCSI or NVMe/TCP. Two PVE
content types are supported:

- **`images`** — VM virtual disks (default; always available).
- **`rootdir`** — LXC container root volumes (opt-in; add `rootdir`
  to the storage's `content` field in `storage.cfg`). The plugin
  allocates a zvol per container, formats it ext4, mounts it on the
  node under `/mnt/<storage>/pct-<vmid>-rootdir/` during
  `activate_volume`, and tears the mount down in `deactivate_volume`.
  Tested end-to-end by the Proxmox storage-plugin-validation suite:
  container create, start, backup to PBS, restore round-trip.

### Not supported (and probably shouldn't be, in this plugin)

- **`iso`** (ISO images), **`vztmpl`** (LXC templates), **`snippets`**
  (cloud-init hook scripts and user-data).
- **`backup`** (vzdump archives).
- **`import`** (OVF/VMA staging).

**Why not here**: all of these are file-level content, not block.
PVE has first-class storage types (NFS, dir, CephFS, PBS) that are
better fits — point one of those at a TrueNAS NFS share, PBS
datastore, or local directory. Running these through this plugin
would mean growing a parallel NFS-mount code path next to the
iSCSI/NVMe one.

**Workaround — split by content type in `storage.cfg`:**

```ini
truenasplugin: truenas-storage
    # ... VM disks and LXC root volumes ...
    content images,rootdir

nfs: truenas-iso
    server 192.168.1.100
    export /mnt/tank/pve-iso
    content iso,vztmpl,snippets

pbs: pbs
    server 192.168.0.145
    datastore main
    content backup
    # ... fingerprint/username/password elsewhere ...
```

## Snapshot Limitations

### vzdump captures live state, not snapshot history

`vzdump` (and PBS backup) always captures the **current** VM disk
state. The ZFS snapshot history on TrueNAS is separate — it stays on
TrueNAS, not in the backup archive. This is standard PVE behavior,
same as any other block-based storage plugin.

**What this means in practice:**

- `vzdump → PBS` and `vzdump → local directory` both work end-to-end
  for VMs with disks on this plugin, in both `--mode stop` and
  `--mode snapshot`. For running VMs in snapshot mode, the plugin's
  `volume_snapshot` is called to create an ephemeral ZFS snapshot and
  `_expose_snapshot_device` publishes a clone-of-snapshot as a device
  the backup can read, then both are torn down after. Verified on
  the storage-plugin-validation suite 2026-10 against both iSCSI and
  NVMe/TCP, into PBS.
- Restoring a backup produces a VM with the **disk contents as of
  backup time**. It does NOT recreate the chain of ZFS snapshots that
  existed on TrueNAS at backup time.

**If you want snapshot history preserved offsite:**

- Set up TrueNAS-side snapshot schedules on `tank/proxmox` (or
  whatever dataset the plugin manages). TrueNAS keeps the full
  snapshot chain under its retention rules.
- Add a TrueNAS replication task to replicate `tank/proxmox` to
  another TrueNAS. ZFS send/recv preserves the full snapshot chain.
- Keep PBS as your Proxmox-side VM backup (fast dedup, cross-storage
  restore). It will keep its own history of backup snapshots.

The two mechanisms are complementary, not substitutes. Use PBS for
"restore the VM", TN replication for "preserve the ZFS snapshot
chain for forensics or long-term rollback".

### VM clones from a template use ZFS clone; cross-storage full clone does not

See the "Clone semantics" section above. Linked clones from a
template take the fast ZFS-clone path. Full clones from a snapshot
of a non-template VM, or full clones across storages, use PVE's
`qemu-img convert` path — not plugin's `clone_image()`. That is a
PVE design choice, not a plugin bug; the plugin's `clone_image()`
is called for the linked-clone path only.

## Live Migration Limitations

### Requires Shared Storage

**Limitation**: Live migration requires `shared 1` configuration

**Configuration**:
```ini
# Required for live migration
shared 1
```

**Impact**:
- Cannot live migrate VMs between nodes if `shared 0`
- Offline migration still works (VM stopped during migration)

### vmstate Storage Considerations

**Limitation**: Live migration with existing snapshots requires vmstate to be reachable from the target node.

**Explanation**:
- If VM has snapshots with vmstate on local storage
- Live migration fails (vmstate not accessible from target node)

> ⚠️ `tn_vmstate_storage` is not currently implemented by this plugin (see [Configuration Reference](Configuration.md#tn_vmstate_storage)) — vmstate placement is controlled entirely by Proxmox core, not by this setting.

**Workaround**:
```ini
# Use shared storage for vmstate in environments requiring migration
# (configure via Proxmox's own vmstate storage selection, not this plugin)

# Or delete snapshots before migration
# Or use offline migration (stop VM, migrate, start)
```

### Shared CPU model required across heterogeneous nodes

Live migration between nodes with **different physical CPUs** (even
within the same Intel generation line) will crash the destination
QEMU with a `kvm_buf_set_msrs` assertion if the VM is configured
with `cpu: host`. Example from a mixed cluster that includes a
Westmere node and an Ivy Bridge node:

```
kvm: warning: TSC frequency mismatch between VM (2393998 kHz)
     and host (3300022 kHz), and TSC scaling unavailable
kvm: error: failed to set MSR 0x202 to 0xe000000000
kvm: ../target/i386/kvm/kvm.c:3888: kvm_buf_set_msrs:
     Assertion `ret == cpu->kvm_msr_buf->nmsrs' failed.
```

Older Intel generations (pre-Haswell on most SKUs) lack hardware
TSC scaling, so the destination KVM cannot rewrite a running
guest's TSC rate during the resume step.

**Fix**: pick a CPU model that is actually portable across your
cluster. The common denominator for a mixed Westmere/Ivy Bridge
fleet is `Nehalem`. For modern-only clusters, `x86-64-v2-AES` or
`x86-64-v3` are typical choices. Set with `qm set VMID --cpu
Nehalem`, then reboot the VM. Not a plugin bug — same limitation
applies to every PVE storage backend.

## TrueNAS Specific Limitations

### API Rate Limits

**Limitation**: TrueNAS limits API requests to 20 calls per 60 seconds

**Impact**:
- Exceeding limit triggers 10-minute cooldown
- Bulk operations (creating many VMs) may hit limit

**Plugin Mitigation**:
- Automatic retry with exponential backoff
- Bulk operations batching (when `enable_bulk_operations=1`)
- Connection caching and reuse

**User Mitigation**:
```ini
# Increase retry tolerance
tn_api_retry_max 5
tn_api_retry_delay 2

# Enable bulk operations
tn_enable_bulk_operations 1
```

**Manual Recovery**:
```bash
# If rate limited, wait 10 minutes
# Check TrueNAS logs:
tail -f /var/log/middlewared.log | grep rate
```

### WebSocket Connection Stability

**Limitation**: WebSocket connections may be unstable in some network environments

**Symptoms**:
- Random connection drops
- "WebSocket closed unexpectedly" errors
- Increased latency

**Mitigation**:
- Ensure reliable network path (avoid flaky links, check MTU consistency)
- Use TLS (`api_scheme wss`) and valid certificates
- Increase retry settings: `tn_api_retry_max`, `tn_api_retry_delay`
- Verify firewall allows TCP 443 from all Proxmox nodes

## Proxmox Specific Limitations

### Proxmox Version Requirements

**Limitation**: Some features require specific Proxmox VE versions

**Feature Requirements**:
- **Basic functionality**: Proxmox VE 8.x+
- **Volume snapshot chains**: Proxmox VE 9.x+
- **Optimal storage plugin API**: Proxmox VE 8.2+

**Recommendation**: Use Proxmox VE 8.2 or later (or Proxmox VE 9.x for volume chains)

### Custom Storage Plugin Directory

**Limitation**: Plugin must be in `/usr/share/perl5/PVE/Storage/Custom/`

**Impact**:
- Updates to Proxmox may require plugin reinstallation
- Manual installation required (not in Proxmox repositories)

**Mitigation**:
```bash
# Keep plugin source in safe location
cp TrueNASPlugin.pm /root/truenas-plugin-backup/

# Use installer for easy cluster-wide reinstall
./install.sh  # Select "Install latest version (all cluster nodes)"
```

## Network Limitations

### No NFS/CIFS Support

**Limitation**: Plugin only supports iSCSI and NVMe/TCP block storage

**Not Supported**:
- NFS file shares
- SMB/CIFS file shares
- Direct ZFS dataset mounting

**Explanation**: Plugin architecture designed specifically for block storage (iSCSI and NVMe/TCP)

**Workaround**:
```bash
# Use separate TrueNAS NFS/SMB shares for file-based storage
# Example /etc/pve/storage.cfg:

# iSCSI for VM disks
truenasplugin: truenas-vms
    content images
    # ... config ...

# NFS for LXC/backups
nfs: truenas-files
    server 192.168.1.100
    export /mnt/tank/nfs-share
    content rootdir,vztmpl,backup
```

### IPv6 Considerations

**Limitation**: IPv6 requires specific configuration

**Required Settings**:
```ini
tn_prefer_ipv4 0
tn_ipv6_by_path 1  # not currently implemented, see Configuration.md#tn_ipv6_by_path
tn_use_by_path 1
```

**Portal Format**:
```ini
# Must use brackets for IPv6 addresses
tn_discovery_portal [2001:db8::100]:3260
tn_portals [2001:db8::101]:3260,[2001:db8::102]:3260
```

## Security Limitations

### No Mutual CHAP (iSCSI)

**Limitation**: Only one-way CHAP authentication supported for iSCSI transport

**Explanation**:
- iSCSI transport supports CHAP authentication (initiator → target)
- Mutual CHAP (target → initiator) not implemented for iSCSI

**Note**: NVMe/TCP transport supports full bidirectional DH-HMAC-CHAP authentication (host + controller secrets). See [NVMe Setup Guide](NVMe-Setup.md#authentication) for details.

**Impact**: Slightly reduced security in high-security iSCSI environments

**Mitigation**:
- Use NVMe/TCP transport for bidirectional authentication
- Use network segmentation (VLANs)
- Firewall rules restricting iSCSI access
- Strong CHAP passwords

### API Key Storage

**Limitation**: API key stored in plaintext in `/etc/pve/storage.cfg`

**Impact**: Anyone with root access to Proxmox can read API key

**Mitigation**:
- Restrict TrueNAS API user permissions (least privilege)
- Use dedicated API user (not root)
- Monitor TrueNAS audit logs
- Rotate API keys regularly

**File Permissions**:
```bash
# /etc/pve/storage.cfg is readable by root only
ls -la /etc/pve/storage.cfg
# -rw-r----- 1 root www-data
```

### No SCSI persistent reservations for HA fencing

**Limitation**: The plugin does not acquire or release SCSI
persistent reservations on `activate_volume` / `deactivate_volume`.

**Explanation**: In a Proxmox HA cluster, when a node is fenced
out, the fenced node's iSCSI target-extent mapping stays as-is on
TrueNAS. HA will restart the VM on another node, which re-activates
the same LUN. If the fenced node ever comes back and re-enters the
cluster before TrueNAS has invalidated the stale initiator session,
both nodes briefly have the LUN visible — split-brain write risk,
bounded only by what the TrueNAS target enforces at the SCST layer
(which, without reservations configured, is nothing).

**Impact**: Serious HA deployments on top of this plugin do not get
plugin-level split-brain protection. The TN target itself does not
currently drive persistent reservations on behalf of the plugin.

**Mitigation**:
- Rely on PVE's own fencing (watchdog + corosync membership
  consensus) to ensure the fenced node is truly down before the
  surviving node takes over.
- Keep storage-network and corosync-network reliable; most "false
  fence" scenarios come from flaky corosync, not storage.
- A plugin that drives SCSI PR explicitly is on the roadmap but not
  shipped as of 2.1.23~beta8.

### `rename_volume` not implemented

**Limitation**: The plugin does not implement PVE's
`rename_volume()` method.

**Impact**: A few housekeeping paths in PVE core die with
`not implemented in storage plugin 'PVE::Storage::Custom::TrueNASPlugin'`:

- Changing a VM's VMID (`qm set --newid`-style flows).
- Some edge cases of PVE's volume-renaming utilities.

**Workaround**: These are uncommon operations. For VMID change,
clone → verify → destroy old is the stable workflow until
`rename_volume` lands. The implementation path exists on the
TrueNAS side (`zfs rename` + iSCSI extent `name` update); the
plugin just doesn't expose it yet.

## Performance Limitations

### Clone Performance

**Limitation**: See "No Fast Clone Support" above

**Impact**: Large VM clones are slow

### Snapshot Overhead

**Limitation**: Many snapshots can impact performance

**Explanation**:
- Each snapshot creates metadata overhead
- Write performance degrades with many snapshots
- Space usage increases as data diverges from snapshots

**Recommendation**:
```bash
# Manage snapshot lifecycle
# Delete old snapshots regularly
# TrueNAS automated snapshot retention policy

# Example: Keep 7 daily snapshots
# In TrueNAS: Storage > Snapshots > Add
# Lifetime: 1 week
```

### Network-Bound Performance

**Limitation**: Performance limited by network speed and latency

**Impact**:
- VM disk I/O limited by network bandwidth
- Latency affects random I/O performance

**Mitigation**:
- Use 10GbE or faster network
- Jumbo frames (MTU 9000)
- Dedicated storage network
- Multiple paths (multipath I/O)

### Multipath Read Performance Limitation

**Limitation**: Multipath read performance is constrained by iSCSI protocol limitations in TrueNAS SCALE

**Explanation**:
- TrueNAS SCALE (as of version 25.04) sets `MaxOutstandingR2T=1` on iSCSI targets
- This limits each iSCSI session to **1 outstanding read request** at a time
- Even with multiple paths configured, read operations cannot fully utilize aggregate bandwidth
- Write operations are **not affected** (use immediate/unsolicited data transfer)

**Observed Behavior**:
```
Configuration: 2x 1GbE multipath (theoretical 250 MB/s aggregate)

Write Performance: ~100-110 MB/s ✅
- Both paths utilized simultaneously
- Full aggregate bandwidth achieved

Sequential Read Performance: ~50-100 MB/s ⚠️
- Paths alternate handling requests (round-robin)
- Limited by serialized read operations (one R2T per session)
- Both paths ARE being used, but not fully in parallel

Parallel Read Performance: ~100-110 MB/s ✅
- Multiple parallel I/O streams (e.g., fio with numjobs=4)
- Can achieve near-full aggregate bandwidth
```

**Technical Details**:
- `MaxOutstandingR2T=1` is an iSCSI protocol parameter
- Controls how many read requests can be in-flight simultaneously per session
- TrueNAS SCALE does not currently expose this parameter for configuration
- Configuration files (`/etc/ctl.conf`, `/etc/scst.conf`) are auto-generated and manual edits are overwritten
- This is a **known limitation** with an active feature request in the TrueNAS community

**Impact**:
- Single-threaded sequential reads (e.g., disk benchmarks like kdiskmark) show lower performance
- Real-world workloads with multiple VMs or parallel I/O see better performance
- Write-heavy workloads are not affected
- Random I/O workloads naturally create parallelism and perform better

**Workarounds**:

1. **Upgrade to 10GbE Network** (Recommended)
   - Single 10GbE path provides ~1000 MB/s
   - Bypasses R2T bottleneck entirely
   - Best long-term solution

2. **Accept Current Performance**
   - ~100 MB/s read is still reasonable for many workloads
   - Most real-world applications do parallel I/O
   - Multiple VMs naturally create parallel load

3. **Add More Network Paths**
   - 4x 1GbE = 4 concurrent read operations possible
   - Diminishing returns, but may help read-heavy workloads

4. **Optimize Workloads for Parallelism**
   - Applications that issue multiple concurrent reads perform better
   - Databases and random I/O workloads less affected
   - Avoid single-threaded sequential read benchmarks as sole metric

5. **Monitor TrueNAS Feature Requests**
   - Feature request exists for configurable iSCSI parameters
   - May be addressed in future TrueNAS SCALE releases
   - Check TrueNAS forums for updates

**Available Solution: NVMe/TCP**:
- Use NVMe over TCP (NVMe-oF) to eliminate this limitation
- NVMe protocol supports native parallelism and higher queue depths
- Fully supported in this plugin version (requires TrueNAS SCALE 25.10+)

**Note**: This is a TrueNAS SCALE platform limitation, not a plugin configuration issue. Multipath is configured correctly and both paths are being utilized - the bottleneck is at the iSCSI protocol layer.

## Platform Limitations

### Linux/Proxmox Only

**Limitation**: Plugin is Proxmox VE specific

**Not Supported**:
- Generic Linux systems
- Other hypervisors (VMware, Hyper-V, etc.)
- FreeBSD/BSD systems

**Explanation**: Plugin uses Proxmox storage plugin API

### ZFS Dependency

**Limitation**: Requires TrueNAS with ZFS

**Not Supported**:
- TrueNAS CORE (FreeBSD-based) - untested, may work
- Other iSCSI targets (not designed for them)
- Non-ZFS storage backends

**Explanation**: Plugin assumes ZFS dataset/zvol semantics

## Operational Limitations

### No Bulk Deletion

**Limitation**: Deleting many VMs sequentially may hit rate limits

**Explanation**: Each VM deletion makes multiple API calls

**Workaround**:
```bash
# Delete VMs with delays
for vm in 100 101 102 103; do
    qm destroy $vm --purge
    sleep 5
done

# Or delete zvols directly on TrueNAS after qm destroy
# (But loses automatic cleanup benefit)
```

### Configuration Changes Require Restart

**Limitation**: Changes to `/etc/pve/storage.cfg` require service restart

**Procedure**:
```bash
# After editing /etc/pve/storage.cfg
systemctl restart pvedaemon pveproxy
```

**Impact**: Brief interruption to API (web UI may disconnect)

### No Storage Overcommit Protection

**Limitation**: Plugin doesn't prevent overcommitting storage

**Explanation**:
- Thin provisioning allows allocating more virtual capacity than physical
- Plugin enforces 20% safety margin on individual operations
- But doesn't track total allocated vs available

**Mitigation**:
```bash
# Monitor actual space usage
zfs list tank/proxmox

# Set ZFS quotas/reservations if needed
zfs set quota=500G tank/proxmox
```

## Workarounds Summary

| Limitation | Recommended Workaround |
|------------|------------------------|
| No fast clones | Use smaller templates, faster network, accept limitation |
| No volume shrink | Create new smaller volume, migrate data, delete old |
| Images only | Use separate storage for LXC/ISO/backups |
| No backup integration | Use TrueNAS replication or Proxmox Backup Server |
| `qm destroy` orphans | Always use GUI deletion or add cleanup to scripts |
| API rate limits | Enable bulk operations, increase retry limits, pace operations |
| WebSocket instability | Improve network stability, verify TLS/certs, tune retry settings |
| Clone performance | Faster network, smaller images, accept limitation |
| Multipath read performance | Upgrade to 10GbE, accept ~100 MB/s, or use parallel workloads |

## See Also
- [Troubleshooting Guide](Troubleshooting.md) - Solutions to common issues
- [Advanced Features](Advanced-Features.md) - Performance optimization
- [Configuration Reference](Configuration.md) - All configuration options
- [Multi-Tenancy](Multi-Tenancy.md) - Sharing a TrueNAS system across multiple clusters
