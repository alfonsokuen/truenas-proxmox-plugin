# NVMe-oF host tuning

Everything here was measured on a three-node Proxmox VE cluster against a
TrueNAS 25.10.x array over nvme-tcp, with `nvme_core.multipath=Y` and two
fabrics. Where something is inferred rather than measured it says so.

The theme is repeated often enough to state once: **several of the obvious
configurations install cleanly, report no error, and do nothing.** Confirm the
effect, not the exit code.

---

## 1. Cap the NVMe command size (`tools/udev/99-nvme-tcp-max-sectors.rules`)

The target advertises **MDTS = 0** — no limit — so command size is decided
entirely by the host. `nvmet_tcp` on 25.10.x fails to map data buffers for very
large reads and returns Internal Error, which shows up as I/O errors during
`vzdump` and disk moves (upstream #45; most likely the window in which the
corruption of #32 occurred).

**The obvious rule does not work.** `ATTRS{transport}=="tcp"` never matches:
with native multipath the `transport` attribute lives on the per-path
controllers (`nvme0c0n1`), not on the namespace head (`nvme0n1`) that carries
the queue limits. Match on `subsysnqn` instead — see the rule file for the
measurements and for why a blanket `nvme` match would throttle the node's local
SSD, where `local-lvm` lives.

| Configuration | Actual request size |
|---|---|
| head 1280, paths 1280 | 1024 KB |
| **head 128, paths 1280** | **128 KB** |
| head 128, paths 128 | 128 KB |

Setting it on the head is enough — it splits the bio before forwarding. Verified
to survive a full disconnect/reconnect, which is what matters because namespaces
come and go.

---

## 2. LVM filter (upstream #4)

**Check your profile before copying anyone's filter.** The upstream reporter
exposes guest LVM directly on the namespace. A deployment that keeps qcow2
inside LVs of a host VG is a different shape: measured at rest, with the default
`scan_lvs=0`, connecting the namespace does **not** reproduce the reported
storm — `pvs`/`vgs` see only the host VG, no warnings, no growth of
`/etc/lvm/archive`.

In that shape the real vector is **`qemu-nbd`**, because the qcow2 header hides
the LVM label: the host only sees inside when a disk is attached over nbd for
maintenance. A **raw** LV would leak with `scan_lvs=1`.

In `/etc/lvm/lvm.conf`, inside `devices { }`:

```
global_filter = [ "r|/dev/zd.*|", "r|/dev/rbd.*|", "r|^/dev/mapper/<your-vg>-.*|", "r|^/dev/nbd.*|" ]
scan_lvs = 0
```

- **`global_filter`, not `filter`.** Measured on LVM 2.03.16 that `pvscan --cache`
  honours both, but `filter` can be overridden per command with
  `--config devices/filter` and `global_filter` cannot. PVE already publishes its
  `zd`/`rbd` exclusions there — extend that array, do not replace it.
- **`scan_lvs = 0` is the primary protection**, because it is a behaviour flag and
  therefore immune to aliasing. Measured: rejecting a device by **one** path
  (`r|^/dev/nvme0n2$|`) does **not** hide it — LVM rediscovers it through
  `/dev/disk/by-diskseq/…`.

> **Do not copy the filter suggested in issues #4/#93.** It proposes
> `r|^/dev/disk/by-id/nvme-TrueNAS_.*|`. If your own PV is exported by the same
> TrueNAS, its `by-id` almost certainly also starts with `nvme-TrueNAS_`, and
> that reject **would drop your own PV and take the storage down**. (Inferred
> from the reporter's `lsblk`; verify on each node with
> `ls -l /dev/disk/by-id/ | grep -i truenas` and `pvs -o pv_name,vg_name`
> before changing anything.) A generic `r|^/dev/nvme|` is worse — it includes
> the node's local SSD.

Apply on one node first:

```bash
# before
lvmconfig devices/scan_lvs devices/global_filter
pvs -o pv_name,vg_name; ls -l /dev/disk/by-id/ | grep -iE 'truenas|nvme-uuid'
cp -a /etc/lvm/lvm.conf /etc/lvm/lvm.conf.bak-$(date +%F)

# dry run, writes nothing (inside --config the elements are SPACE-separated, not comma)
pvs --config 'devices{global_filter=["r|/dev/zd.*|","r|^/dev/nbd.*|"] scan_lvs=0}'

# apply
lvmconfig --validate
rm -f /etc/lvm/cache/.cache; pvscan --cache; vgscan --cache
systemctl restart lvm2-monitor
update-initramfs -u

# after
pvs; vgs                            # only your VG, no warnings
pvesh get /nodes/<node>/storage     # clean -- this is the real symptom of #4
lvs <your-vg>                       # then boot a VM on the storage
```

Rollback is restoring the `.bak` and `pvscan --cache`. Immediate, no reboot.

**This is a data-loss risk, not just noise.** Measured in the lab: from the host
you can activate a guest's VG, mount its ext4 read-write, write inside it, and
rename its LVM metadata (`seqno` 2→3 *inside the VM's disk*). Autoactivation
fires on its own through udev. If that coincides with the VM running, there are
two independent writers on one filesystem.

---

## 3. Repairing a guest filesystem over nbd

Activating a guest VG **by name** (`vgchange -ay ubuntu-vg`) and repairing
`/dev/ubuntu-vg/ubuntu-lv` is unsafe: `ubuntu-vg` is the Ubuntu installer's
default, so two guests routinely share it.

Measured with both connected: `vgchange -ay ubuntu-vg` prints *"Multiple VGs
found with the same name: skipping"*, and because the device-mapper names
collide only one can be active. If an earlier session left another VM's VG
active, `/dev/ubuntu-vg/ubuntu-lv` points at **that** one and `e2fsck -y` eats it.

Do it this way instead: abort if any guest VG is already active, select by the
`vg_uuid` of the PV on `/dev/nbd0`, and resolve the real kernel device through
`lv_kernel_major:minor` rather than by name. Verified in the lab with two
labelled disks: resolves to the correct device.

---

## 4. Kernel restrictions on the NVMe-oF host whitelist

Measured, and all four are things you want to know *before* you start:

- `attr_allow_any_host=1` and having `allowed_hosts` are **mutually exclusive** —
  each direction returns EINVAL. The order is forced: **close first, authorise
  second.**
- Closing does **not** drop existing sessions; the ACL is evaluated at connect.
  The exposure is the *reconnect*.
- An unauthorised host gets **EIO in ~0.01 s**; a down fabric gives
  **ETIMEDOUT in ~3 s**. They are distinguishable, so a probe can tell "refused"
  from "unreachable".
- The rollback is **not symmetric**: reopening `allow_any_host` while hosts are
  still listed is rejected. The associations have to be deleted first.

---

## 5. `ctrl_loss_tmo`

`ctrl_loss_tmo=-1` ("off") parks controllers in `connecting` forever, so I/O
**blocks instead of erroring**. For a cluster with fencing that is the behaviour
you want: a VM that hangs and resumes beats a VM whose filesystem takes EIO.

Measured across a three-node cluster: every controller was already at `off` —
but *accidentally*, because the plugin only passes the option when it is
configured and the kernel default happened to agree. Set it explicitly. A value
you did not choose is a value that can change under you on the next upgrade.
