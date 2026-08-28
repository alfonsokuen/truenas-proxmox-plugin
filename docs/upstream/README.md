# Upstream reports

What was sent outside this repository about the NVMe/TCP corruption investigated in
August 2026.

## Sent, 2026-08-28

### 1. truenas/truenas-proxmox-plugin issue #96 — root cause

https://github.com/truenas/truenas-proxmox-plugin/issues/96#issuecomment-5455179449

Both bugs: `nvmet-tcp` advertising `mdts=0` (so initiators merge to 32 MiB and the
target's order-5/6 SGL allocation fails silently under `__GFP_NOWARN`, with a *generic*
status multipath will not fail over), and `qemu-img convert` running with
`--target-cache unsafe` for every PVE block storage that is not `zfspool`, which turns a
lost write into `TASK OK`.

The maintainer (johntdavis84) replied the same day asking whether the other channels had
been opened, and routed the kernel fix to the nvme-cli repo — which is wrong, `.get_mdts`
lives in `drivers/nvme/target/tcp.c`. Answered at:

https://github.com/truenas/truenas-proxmox-plugin/issues/96#issuecomment-5458394213

### 2. Proxmox — `pve-devel@lists.proxmox.com`

Subject: *qemu-img convert runs with cache=unsafe for every block storage except zfspool*
Message-ID: `<178795574681.28052.11392785472014160013@idkmanager.com>`

Content as in `proxmox-qemu-img-cache-unsafe.md`, re-verified against `qemu-server 9.1.18`
before sending: `QemuImage.pm:149` still gates `-t none` on `zfspool` alone, and line 122
does the same for the source cache (`-T`). Offered to refile in Bugzilla if the list is the
wrong venue.

Worth remembering if this stalls: Proxmox patch their own kernel while waiting on upstream,
so this channel can bear fruit before the kernel patch does.

### 3. Kernel — `linux-nvme` + LKML

Subject: *[PATCH] nvmet-tcp: report a bounded MDTS instead of "no limit"*
Message-ID: `<20260828222356.1264-1-gerencia@idkmanager.com>`
To: hch@lst.de, sagi@grimberg.me, kch@nvidia.com — cc linux-nvme, linux-kernel.

`0001-nvmet-tcp-report-a-bounded-MDTS-instead-of-no-limit.patch`, kept here as sent.

- Base: mainline `548e7bcd0c5460ddcbca9600cea603ebeebf4da7`.
- `checkpatch.pl --strict`: 0 errors, 0 warnings, 0 checks.
- Compiles clean including `make W=1`; `nvmet_tcp_get_mdts` verified present in `tcp.o`.
- Signature checked against `nvmet.h:432`; `nvmet_ctrl_mdts()` combines the value with any
  port-configured mdts through `min_not_zero()` (`nvmet.h:783`), so an administrator's
  lower limit still wins.
- Sent with `git send-email`, `Content-Transfer-Encoding: 8bit`, `From` matching the
  `Signed-off-by` (DCO wants a real personal name, not a company handle).

A claim I got wrong, and had to retract publicly (issuecomment-5458913439): I said TCP was
the only transport without a `.get_mdts`. Checked properly against `548e7bcd0c54`, three
lack it -- `fc.c`, `loop.c` and `tcp.c` -- while `rdma.c` and `pci-epf.c` have it. I had
grepped only the transports I already had in mind and generalised from that sample. The
accurate framing is that the mechanism was added for RDMA in 2020 and never generalised,
not that TCP was singled out.

The patch as sent does not carry the claim -- it says the 2020 series "deliberately left
other transports untouched", which is correct -- so nothing needed correcting on the list.

## Still owed

- **iXsystems** — draft in `ixsystems-ticket.md`, not filed. Needs a support/JIRA account;
  the maintainer confirmed iX require a JIRA report even for issues raised on a repo they
  watch. When filing, cite the build the mitigation was measured on: **`2.1.24~alpha1+idk10`**
  — note the worktree and branch are still named `idk9`, the version is not.
