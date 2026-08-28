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

## Ready to send, not sent

### `0001-nvmet-tcp-report-a-bounded-MDTS-instead-of-no-limit.patch`

Adds `.get_mdts` to `nvmet_tcp_ops`, returning the same 1 MiB (`2^8 * 4KB`) that
`nvmet-rdma` has advertised since 2020. **This one is genuinely submittable**: generated
with `git format-patch` against a real tree, not hand-written.

- Base: mainline `548e7bcd0c5460ddcbca9600cea603ebeebf4da7`.
- `checkpatch.pl --strict`: **0 errors, 0 warnings, 0 checks**.
- Compiles clean, including `make W=1`; `nvmet_tcp_get_mdts` verified present in
  `tcp.o`.
- The bug was re-confirmed in that tree: `nvmet_tcp_ops` has no `.get_mdts`, while both
  `nvmet_rdma_ops` and `nvmet_pci_epf_ops` do — TCP is the only transport left without one.
- Signature checked against `nvmet.h:432`; the value is combined with any port-configured
  mdts through `min_not_zero()` (`nvmet.h:783`), so an administrator's lower limit still
  wins.

Recipients, from `scripts/get_maintainer.pl`:

```
git send-email \
  --to=hch@lst.de \
  --to=sagi@grimberg.me \
  --to=kch@nvidia.com \
  --cc=linux-nvme@lists.infradead.org \
  --cc=linux-kernel@vger.kernel.org \
  0001-nvmet-tcp-report-a-bounded-MDTS-instead-of-no-limit.patch
```

Note the `Signed-off-by` uses a real personal name, which the DCO requires — a company
handle would get the patch bounced. Rebase onto current mainline (or the `nvme` tree) and
re-run `checkpatch.pl` if it sits here for more than a few weeks.

## Not sent, needs an account

- **Proxmox** — draft in `proxmox-qemu-img-cache-unsafe.md`, re-verified 2026-08-28 against
  `qemu-server 9.1.18`: the gap is still there, and line 122 has the same problem for the
  *source* cache. **Highest impact of the three** — it affects every block destination, not
  just this plugin's — and the only one nobody has been told about. Needs a Bugzilla
  account (https://bugzilla.proxmox.com) or a post to `pve-devel@lists.proxmox.com`.

- **iXsystems** — draft in `ixsystems-ticket.md`. Issue #96 already carries the technical
  content; this is the vendor channel, asking them to carry the kernel patch or document
  the mitigation in a release note. Needs an iXsystems support/Jira account.
