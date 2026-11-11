---
id: deci-ddb40441
type: decision
project: menegroth
parent_id: plan-bff9aa9f
title: 'Building solve speed: mesh owner, restore-solve skip, catalog identity, stiffness
  deferral'
node_label: Speed follow-ups
tags: speed,fea,memo,asap,tier2
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-9ad5191a
created_at: '2026-10-26T15:54:21.414610+00:00'
updated_at: '2026-11-02T22:45:01.601437+00:00'
has_child_rationale: User chose which open plan items to build now and which to keep
  for later.
---
Decisions after the Phase 0 / Tier 1 implementation (plan-bff9aa9f).

Build now:
- FEA mesh owner with an explicit geometry key, plus a gate that a mesh built for one geometry is not reused for another. Column-size changes that would remesh only the zone around the column stay Tier 2; the key must still refuse a mesh whose topology inputs differ (slab polygon, openings, drop panel, edge beams, target edge).
- Skip the extra FEA restore solve on the update path once the saved solution is the factored envelope.
- Discrete-catalog memo keys on the catalog object's identity, not on section name and a few dimensions. A rebuilt catalog misses. In-place mutation of a cached catalog is not detected.
- Deferred per-slab Asap.process! must be safe for every caller, not only the design-graph sync. Standalone size_slab! must not leave stiffness stale.
- Pin the Asap submodule (seeded mesher, typed stiffness scatter, area-load barrier) so the parent can point at that commit.

Skipped:
- Steel MIP warm start from the previous section. A time limit or the 1e-4 gap can stop on a different section. The identity memo already covers exact repeats.

Tier 2, do not start until a later session:
- Zoned remesh around columns (fixes the stale footprint; not byte-identical).
- Replace the unlimited-section column MIP with a per-group lowest-objective pick. Tie-break is still undecided (lowest objective, then catalog order was the proposal).
- Two-pass order-independent column design, then typical-floor dedupe. Dedupe is unsafe before the two-pass.
- Warm-starting slab thickness above the code minimum. Can lock in a thicker slab.

Still required before any speed claim: run_all_gates and a fresh profile, one Julia process. Steel diffs from the binary-search fix must be checked as lighter sections that pass, not as noise.
