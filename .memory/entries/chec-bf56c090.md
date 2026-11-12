---
id: chec-bf56c090
type: checkpoint
project: menegroth
parent_id: chec-f5183ccc
title: Two-way slab thickness follows ACI 318-11 §9.5.3.3
node_label: Two-way αfm thickness
tags: aci,two-way,slab,thickness,alpha-fm
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-d9205b69
created_at: '2026-11-12T02:39:55.063457+00:00'
updated_at: '2026-11-12T02:39:55.063457+00:00'
---
Two-way slabs with beams no longer use a simplified Eq. (9-13) divided by 36. That form assumes αfm > 2 and drops the 9β term, and no caller was checking αfm.

ACI 318-11 §9.5.3.3 (corpus: aci-318-11, PDF pages 134–135):
- αfm omitted or ≤ 0.2: §9.5.3.3(a) uses Table 9.5(c) through §9.5.3.2. The exterior panel without an edge beam is the thickest column (fy 40/60/75 ksi → ln/33, ln/30, ln/28, interpolated, not extrapolated). Not less than 5 in. The table applies only when the long-to-short ratio is at most 2; a larger β throws.
- 0.2 < αfm ≤ 2: Eq. (9-12), denominator 36 + 5β(αfm − 0.2), not less than 5 in. β is required and must be ≥ 1.
- αfm > 2: Eq. (9-13), denominator 36 + 9β, not less than 3.5 in.
- §9.5.3.3(d): a discontinuous edge multiplies the equation value by 1.10. The inch floor is applied after that.

Span sizing still has no beam sections, so `_size_span_floor(::TwoWay)` passes αfm as unknown and uses the table on the long panel dimension. `infer_floor_type` already sends a ratio above 2 to one-way (ACI 318-19 R8.3.1.2). The second pass that computes αfm from sized beams and resizes the slab is not built: slab stiffness depends on h, so that loop is circular and was not guessed.

Tests: StructuralSizer slabs/test_flat_slab.jl, 113 passed. Includes the 30 ft, fy = 60 ksi cases: table 12 in, Eq. (9-12) at αfm = 1 and β = 1 is 9.9 in, Eq. (9-13) at αfm = 3 is 8.8 in, and the discontinuous-edge case is 9.68 in.

Worktree /tmp/menegroth-rowf, branch row-f-nlp. Not pinned to files because the memory server tracks the main checkout.
