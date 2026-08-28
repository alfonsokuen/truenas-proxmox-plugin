# iXsystems: ship a bounded MDTS for NVMe/TCP, or document the mitigation

**Status:** not reported yet. Needs an iXsystems support/Jira account.

**Verified against:** TrueNAS SCALE 25.10.4, 2026-08-27.

## The report

TrueNAS SCALE exports NVMe/TCP through the Linux `nvmet-tcp` target, which does not
implement `.get_mdts` (`nvmet_rdma_ops` does; `nvmet_tcp_ops` does not). The controller
therefore advertises `mdts=0` — "no maximum transfer size" — and initiators take it
literally: `max_hw_sectors_kb` becomes `2147483647` and the Linux block layer merges
requests up to its generic 32 MiB ceiling.

The target cannot serve those. `nvmet_tcp_map_data()` allocates the command scatterlist with
`sgl_alloc(len, GFP_KERNEL | __GFP_NOWARN, ...)`; a 32 MiB command needs 8192 entries, an
order-5/6 `kmalloc`, which fails under memory fragmentation. `__GFP_NOWARN` means the array
logs nothing at all. The initiator receives `NVME_SC_INTERNAL`, a *generic* status, so NVMe
multipath does not fail the command over to the other path.

Full technical write-up, with measurements:
https://github.com/truenas/truenas-proxmox-plugin/issues/96#issuecomment-5455179449

## Asks, in order of preference

1. Carry a patch adding `.get_mdts` to `nvmet_tcp_ops` in the SCALE kernel, returning the
   same 1 MiB that `nvmet-rdma` has used since 2020. Draft patch in
   `nvmet-tcp-mdts.patch` in this directory (needs regenerating against a real tree).
2. Failing that, document the initiator-side mitigation: cap `max_sectors_kb` at 1024 on
   both the multipath head and the path devices (`nvmeXcYnZ`). Capping the head alone does
   nothing, because the bio-based head only splits and the path devices re-merge to their
   own limit.
3. Either way, this deserves a release note: any customer running NVMe/TCP against SCALE
   with a workload that issues large sequential I/O is exposed, and the failure is silent
   on the array side.

## Environment

- TrueNAS SCALE 25.10.4, NVMe/TCP, dual path.
- Three Proxmox VE 9.2.4 initiators, kernel 7.0.14-4-pve, ~26 guests.
- 980 of ~1040 failed commands were exactly 65536 blocks (32 MiB).
- Capping at 1 MiB removed them entirely; two full migrations (4 TiB and 2 TiB) verified by
  hash afterwards, 16/16 ranges identical.
