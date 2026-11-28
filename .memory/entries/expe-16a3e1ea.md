---
id: expe-16a3e1ea
type: experiment
project: menegroth
parent_id: chec-f384e966
title: 'grillage_bays memo: 211.5s→5.9s (97%), grow_heads 159→43s — bit-exact. Was
  called 10,292× re-deriving the same bay arrangement'
node_label: grillage_bays memo
tags: grillage_bays,grow_heads,performance,cache,member_iteration,exactness
status: active
open_threads: 0
success: 'true'
files: StructuralSynthesizer/src/analyze/slabs/slabs/rib_grillage.jl@fb067c9, StructuralSynthesizer/src/analyze/framing/solid_head_split.jl@fb067c9,
  StructuralSynthesizer/src/analyze/slabs/slabs/arrangement_heads_frame.jl@fb067c9,
  scripts/runners/profile_waffle_stages.jl@fb067c9
session_id: sess-0b3bd5f6
created_at: '2026-11-22T15:56:17.961710+00:00'
updated_at: '2026-11-22T15:56:17.961710+00:00'
has_child_rationale: Next member-stage bottleneck after rib_demands; user chose grow_heads
  path
---
## Diagnosis first
Added behavior-neutral sub-timers (`:grillage_bays`, `:resolve_heads`, `:check_heads`) and ran once. grow_heads' 159s was NOT in the head-growth logic (resolve_heads 20s, check_heads 8s) but in **`grillage_bays`: 211.5s across 10,292 calls** (~20ms each). It is re-derived on every call by load assembly (`grillage_edge_profiles`/`grillage_tributary_loops`), head seeding (`slab_column_heads`), `_solid_head_area` (per screen stem), `undersized_rib_bays`, and grow_heads — all recomputing the SAME planar bay arrangement (O(n²) `node_at` + `planar_bays` + stitch).

## Fix
`grillage_bays` is pure geometry (skeleton node coords frozen for the whole design). Added a per-`struc` `WeakKeyDict` memo keyed by `hash((objectid(slab), objectid(fl), z, candidate_edges))`. The candidate-edge set is exactly what the build reads, so head growth (which splits beams / regroups ribs, changing those edges) invalidates it precisely. WeakKeyDict ⇒ entries die with the struc (no leak in the long-lived API server). `SS_GRILLAGE_BAYS_NOCACHE=1` bypasses it for A/B.

Gotcha: the function already had a local `key = (min(a,b),max(a,b))` in the node loop that clobbered my `key = hash(...)` (same function scope, not a let/comprehension) — first ON run crashed with MethodError (Tuple vs UInt). Renamed to `cache_key`.

## A/B (grid/x1y1 dense waffle, matched tree)
| | grillage_bays | grow_heads | iterate_members | EC |
|---|---|---|---|---|
| cache OFF (baseline) | 211.5s / 10292 | 159.2s | 647s | 211.449 |
| cache ON | **5.9s** / 10292 | **43.1s** | 512.3s | 211.449 |

Bit-identical: total_ec=101495.538, EC=211.449 kgCO2e/m², critical Beam 1144, all_checks_pass=false. **grillage_bays −97% (−205s), grow_heads −73% (−116s), iterate_members −135s.** The 10,292 call count is unchanged — nearly all are now cache hits.

Remaining member-stage: screen_rib_stems 750s, rib_demands 473s (irreducible per-stem pattern-load FE), rib_deflection 239s, size_beams 349s, rib_kernel 65s.
