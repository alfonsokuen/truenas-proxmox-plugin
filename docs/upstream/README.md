# Upstream reports

What was sent outside this repository about the NVMe/TCP corruption investigated in
August 2026, and what is still pending.

## Sent

- **truenas/truenas-proxmox-plugin issue #96** — root-cause write-up, posted 2026-08-28:
  https://github.com/truenas/truenas-proxmox-plugin/issues/96#issuecomment-5455179449

  Covers both bugs: `nvmet-tcp` advertising `mdts=0` (so initiators merge to 32 MiB and the
  target's order-5/6 SGL allocation fails silently under `__GFP_NOWARN`, with a *generic*
  status multipath will not fail over), and `qemu-img convert` running with
  `--target-cache unsafe` for every PVE block storage that is not `zfspool`, which turns a
  lost write into `TASK OK`.

## Not sent yet

- **`nvmet-tcp-mdts.patch`** — adds `.get_mdts` to `nvmet_tcp_ops`, returning the same
  1 MiB (`2^8 * 4KB`) that `nvmet-rdma` has advertised since 2020.

  **This patch is not sendable as it stands.** The hunk offsets are indicative: it was
  written by reading the mainline source, not by editing a kernel tree. Before it goes to
  `linux-nvme@lists.infradead.org` it needs to be regenerated against a real checkout:

  ```
  git clone git://git.infradead.org/nvme.git && cd nvme
  # apply the change to drivers/nvme/target/tcp.c, then:
  git commit -s
  ./scripts/checkpatch.pl --strict <the patch>
  git send-email --to=linux-nvme@lists.infradead.org \
                 --cc=linux-kernel@vger.kernel.org <the patch>
  ```

  Keep the commit message: the measurement in it (980 of ~1040 failed commands at exactly
  32 MiB, ~98 GiB lost from a 2 TiB copy) is the part a maintainer cannot reproduce on their
  own, and it is what distinguishes this from a theoretical cleanup.

- **iXsystems ticket** — draft in `ixsystems-ticket.md`. Issue #96 already carries the
  technical content; this is the vendor channel, asking them to carry the kernel patch or
  document the mitigation in a release note. Needs an iXsystems support/Jira account;
  not filed.

- **Proxmox** — draft in `proxmox-qemu-img-cache-unsafe.md`, re-verified 2026-08-28 against
  `qemu-server 9.1.18`: the gap is still there, and line 122 has the same problem for the
  *source* cache. Highest impact of the three. Needs a Bugzilla account or a pve-devel post;
  not filed.
