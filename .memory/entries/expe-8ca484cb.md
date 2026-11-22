---
id: expe-8ca484cb
type: experiment
project: menegroth
parent_id: chec-f384e966
title: 'rib_demands geometry cache: exact but time-neutral — the ~496s is irreducible
  per-stem pattern-load FE extraction, not redundant geometry'
node_label: rib_demands geom cache
tags: rib,demands,performance,screen_rib_stems,member_group_demands,exactness
status: active
open_threads: 0
success: 'true'
files: StructuralSynthesizer/src/analyze/members/members/rib_story.jl@0d0e34a
session_id: sess-a2c1d80e
created_at: '2026-11-22T05:12:10.251010+00:00'
updated_at: '2026-11-22T05:12:10.251010+00:00'
has_child_rationale: Follows the deflection field-cache work; same screen hot loop,
  next bottleneck attacked
---
## What
Hoisted the two stem-INVARIANT pieces of `:rib_demands` out of the per-trial-stem loop in `screen_rib_stems!`:
- `_rib_sets` (collinear grillage grouping) — pure geometry
- `_compute_flange_params` (ACI 318-11 §8.12 flange specs: span/slab/framing) — stem-independent

Added `_rib_geom_cached(f, cache, key)` + a per-screen `rib_geom_cache::Dict{Symbol,Any}` created once per story (geometry fixed across all trial stems) and threaded through `_size_story_stem!` → `size_rib_lines!`. Cold path (`size_beams.jl`, `cache===nothing`) and A/B switch `SS_RIB_GEOM_NOCACHE=1` always recompute. `_beam_group_demands` is NOT cached — it legitimately tracks the per-stem stale re-solve.

## A/B (grid/x1y1 dense waffle, 30in pans, matched binary)
| | rib_demands | calls | EC intensity |
|---|---|---|---|
| cache ON  | 496.1s | 172 | 211.449 |
| cache OFF (NOCACHE=1) | 495.2s | 360 | 211.449 |

Fingerprint bit-identical (total_ec=101495.538, EC=211.449 kgCO2e/m², critical Beam 1144). Call count halved (360→172) but **wall time unchanged**.

## Finding
`_rib_sets` + `_compute_flange_params` are essentially free. The entire ~496s of `:rib_demands` is `_beam_group_demands`→`member_group_demands`: genuine per-stem force extraction of ACI §13.7.6 pattern-live-load cases × resolution=200 × all beam groups, PLUS (this waffle has concrete joists) the `_pinned_joist` envelope which runs a SECOND full modified-model solve + extraction. All of that is load-path semantics that changes the design — not redundant work.

## Conclusion
The redundant geometry is now removed bit-exactly (helps building types where non-rib beams dominate), but on the waffle `rib_demands` is irreducible without a semantics decision: coarser SCREEN resolution, fewer trial stems, or restricting extraction to only the needed rib groups. Those are the user's call; the exact cache is kept as-is. Decision deferred to user.

Still-standing member-stage attribution (ON run): screen_rib_stems 835s / iterate_members 695s (size_beams 389, grow_heads 173) / rib_deflection 236s / rib_demands 496s / rib_kernel 66s.
