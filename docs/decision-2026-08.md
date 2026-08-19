# Adoption decision — August 2026

**Not adopted for the fleet.** The fixes in this fork are real and they stay; the
plugin is not going into production here. This file records why, so the question
does not get re-litigated from memory in six months.

Read `validation-2026-08.md` first for what was actually exercised. This file is
only about the decision.

## The three reasons, none of which is a bug

A bug gets fixed by testing more. None of these do.

1. **We become the maintainer.** Upstream is alpha and slow. Every fix in
   `idk6` is ours and has been reviewed by nobody else. Each Proxmox VE and each
   TrueNAS upgrade obliges us to re-validate, and we are the ones who re-validate.

2. **It depends on a patch to vendor code.** NAS-140266 is fixed by editing
   `middlewared/plugins/nvmet/kernel.py` on the array. Any TrueNAS update reverts
   it and the plugin stops publishing namespaces. That is not a plugin defect we
   can fix in the plugin. The surface it depends on is also moving: the REST v2.0
   API is **gone** in 25.10.4 — a probe with a valid key returns an empty body.

3. **It puts an HTTP API on the critical path of the management plane.** `pvesm
   status` computes every storage before filtering, so one slow storage darkens
   the node. Today, asking whether the existing storage is alive is a question for
   the kernel. With the plugin it becomes a question for the array's API. The
   budgets added in `idk6` bound this; they do not remove it, and F4 still fails
   2 of 4 assertions.

## What the existing stack was actually missing

The plugin was attractive because of what it appeared to add. Measured against the
production cluster — PVE 9.2.4, `lvm:` over a single 13.3 TiB namespace with
`snapshot-as-volume-chain 1` — most of it was already there or was not the problem:

| Assumed gap | What the measurement said |
|---|---|
| Per-VM snapshots | Already present. Not a gap. |
| Thin provisioning | Broken in two independent layers (LVM never discards on `lvremove`; 19 disks lack `discard=on`) — fixable in place. |
| Per-VM replication | Served by PBS. |
| Provisioning via API | Marginal at 36 guests. |

The real gap was different, and no plugin addresses it: **13 snapshot LVs holding
1600 GiB**, four months old, on a VG that is 85 % full — kept because deleting an
intermediate snapshot had broken a chain before, so nobody dared. That is 45 % of
the remaining free space.

## What the plugin genuinely does better

Stated plainly, because the decision is a trade and not a free lunch:

- Deleting an intermediate snapshot works (ZFS snapshots, not backing chains).
- A disk returns from another storage without silently losing its snapshots.
- A namespace per volume, i.e. blast radius per VM instead of per cluster.

That last one is the real cost of this decision. The alternative worth evaluating
is **not** plugin-vs-status-quo: it is splitting the single namespace into several
zvols/namespaces/VGs created by hand. No alpha code, no vendor patch, no HTTP on
the critical path, and a VG can be evacuated one at a time.

## What would flip this

- Upstream leaves alpha and absorbs these fixes → reason 1 goes away.
- iXsystems ships NAS-140266 in a release → reason 2 goes away.
- F4 passes 4 of 4 → reason 3 is bounded, not removed.

None of the three depends on us. That is the point.

## Status of this fork

`idk6` is deployed on all three nodes and passes the full functional suite with no
regression against the `idk4`/`idk5` baseline (lifecycle 25/25, deep 23/23,
livevm 17/17). It is kept installed and working so the decision stays reversible
and so the pilot storage remains usable. It carries no production guest.
