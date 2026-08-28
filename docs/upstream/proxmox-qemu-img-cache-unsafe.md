# Proxmox: `qemu-img convert` runs with `cache=unsafe` on every block storage but `zfspool`

**Status:** not reported yet. Needs a Bugzilla account (https://bugzilla.proxmox.com) or a
post to `pve-devel@lists.proxmox.com`.

**Verified against:** `qemu-server 9.1.18` on `pve-manager/9.2.4`, 2026-08-28.

## The report

`PVE/QemuServer/QemuImage.pm` protects the destination only when it is a ZFS pool:

```perl
122:    $cachemode = 'none' if $src_scfg->{type} eq 'zfspool';    # source cache (-T)
149:    push @$cmd, '-t', 'none' if $dst_scfg->{type} eq 'zfspool';   # target cache (-t)
```

For every other destination, `qemu-img convert` falls back to its own default for `-t`,
which is `unsafe`, i.e. `BDRV_O_NO_FLUSH`. If a write fails while the data is still a dirty
page, the page is dropped, the `errseq` is never consumed by an `fsync` that would report
it, and `qemu-img` exits **0**. PVE then reports `TASK OK` for a disk move or migration
that silently lost data.

This affects any block destination: iSCSI, FC, LVM over SAN, NVMe-oF, and third-party
storage plugins. It is not specific to any one of them.

### Why the existing safety argument does not hold

The pve-devel thread that introduced this (Aug 2016) asked the right question —
*"is this really safe?"* — and the answer was that `bdrv_close()` sends a flush. But QEMU's
`bdrv_co_flush()` contains:

```c
/* But don't actually force it to the disk with cache=unsafe */
if (bs->open_flags & BDRV_O_NO_FLUSH) {
        goto flush_children;
}
```

The flush is issued, and `cache=unsafe` is precisely the mode in which it does nothing. The
argument invalidates itself. It has been in production for ten years.

### What it cost us

Three PVE 9 nodes against a TrueNAS SCALE 25.10.4 NVMe/TCP target. The target was failing
large commands (separate bug, see
https://github.com/truenas/truenas-proxmox-plugin/issues/96). Those failures should have
surfaced as a failed migration. Instead:

- A 2 TiB image copy lost roughly **98 GiB**, and `qemu-img` exited 0.
- The guest then ran **41 hours** on that copy, logging **2346 XFS metadata corruption
  events**, before anyone noticed.
- All 520 `lost async page write` events were on the destination.

With `-t none` the copy would have failed loudly and no data would have been lost. The
storage bug was ours to fix; the silence was not.

### Suggested fix

Pass `-t none` for any destination that is not a file-backed storage where the performance
tradeoff was deliberately accepted — or, more conservatively, invert the condition so that
`unsafe` is opt-in per storage type rather than the default for everything except one.

## Reproducing without a faulty array

`dmsetup` a `flakey` or `error` target under a test LV, `qemu-img convert` onto it, and
observe the exit code. The point of the report is that the exit code is 0.
