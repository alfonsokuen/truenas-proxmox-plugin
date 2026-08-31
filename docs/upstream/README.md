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

Subject: *nvmet-tcp: report a bounded MDTS instead of "no limit"*
To: hch@lst.de, sagi@grimberg.me, kch@nvidia.com — cc linux-nvme, linux-kernel.

Three revisions. The diff never changed: it is byte-identical across all three
(md5 of the hunk `40d4971c6c42`). Only the commit message moved.

| rev | sent | Message-ID |
|---|---|---|
| v1 | 2026-08-28 17:23 -05 | `<20260828222356.1264-1-gerencia@idkmanager.com>` |
| v2 | 2026-08-28 20:39 -05 | `<20260829013900.10392-1-gerencia@idkmanager.com>` |
| v3 | 2026-08-30 19:51 -05 | `<20260831005117.142713-1-gerencia@idkmanager.com>` |

- Base: mainline `548e7bcd0c5460ddcbca9600cea603ebeebf4da7`.
- Compiles clean including `make W=1`; `nvmet_tcp_get_mdts` verified present in
  `tcp.o`. Checked on v1; unchanged since, as the diff is identical.
- Signature checked against `nvmet.h:432`; `nvmet_ctrl_mdts()` combines the value with any
  port-configured mdts through `min_not_zero()` (`nvmet.h:783`), so an administrator's
  lower limit still wins.
- Sent with `git send-email`, `Content-Transfer-Encoding: 8bit`, `From` matching the
  `Signed-off-by` (DCO wants a real personal name, not a company handle).

**v3 carries `Reviewed-by: Sagi Grimberg <sagi@grimberg.me>`**, given on 2026-08-30 in
reply to v2. His only request was a wording one: cite the RDMA change as
`commit ec6d20e16c2d ("nvmet-rdma: Implement get_mdts controller op")` rather than by
patch title. Both hashes cited in the message were verified against mainline before
sending — `ec6d20e16c2d2bef8df2d82d63dcee51caa4ac27` (Max Gurtovoy, 2020-03-08) and
`4a3f00262a044e8e15064b1a6860968bf0500bf4`.

**A checkpatch error that rode out in v2 unnoticed.** v1 was `checkpatch --strict` clean
and that result was recorded here — but v2 rewrote the rationale and introduced a new
commit citation, `Since 4a3f00262a04 ("...")`, missing the literal word `commit`. That is
an ERROR under `--strict`, and v2 was never re-checked: the clean result from v1 was
carried forward as if it still applied. Caught while preparing v3 and fixed there.
**Re-run checkpatch on every revision — a quality measurement does not survive an edit to
the artifact it measured.**

Two `Unknown commit id` warnings remain when running `checkpatch --no-tree`; they are an
artifact of having no kernel tree locally to resolve the shas against, not defects in the
patch. Both were resolved by hand against mainline (above).

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
