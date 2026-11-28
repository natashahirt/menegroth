---
id: deci-4ecaf63e
type: decision
project: menegroth
parent_id: deci-c216af1b
title: 'Moment-transfer review: per-direction bars, increase only where Eq. (13-1)
  fails, moments on their own column axes'
node_label: Moment-transfer review fixes
tags: flat-plate,moment-transfer,aci-318-11,13.5.3.3,punching
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/transfer_reinforcement.jl@0ed6b0e,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/design/checks/punching.jl@0ed6b0e,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/iteration.jl@0ed6b0e,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/thickness_jump.jl@0ed6b0e,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/design/rule_of_thumb.jl@0ed6b0e,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/model.jl@0ed6b0e,
  StructuralSizer/test/slabs/test_moment_transfer_13_5_3_3.jl@0ed6b0e, StructuralSizer/test/slabs/test_shear_studs.jl@0ed6b0e
session_id: sess-f7e3f2a7
created_at: '2026-11-09T00:55:21.390233+00:00'
updated_at: '2026-11-09T00:55:21.390233+00:00'
has_child_rationale: Walkthrough of the §13.5.3.3 pipeline for clarity and correctness.
---
Fixes from a review of the §13.5.3.3 pipeline:

1. Transfer results carry both directions: `(n_bars_additional, As_additional, c1, c2)`, totals are sums. Before, only the direction short by more steel was reported.
2. ACI 318-19 §8.6.1.2 top steel (across c2) competes only with the c1 transfer bars; it no longer replaces the c2 bars. A missing c1 strip design credits zero placed steel.
3. §13.5.3.3 is taken only where Eq. (13-1) fails at that column (`vu > φvc`). The clause permits, not requires; adopting it at passing columns added band steel and could trigger a needless thickness bump from the placed-steel εt check.
4. `_transfer_sections_adequate` (Phase A pre-check) maps moments to column axes and uses the inner-layer depth like the final pass (`_named_axis_demand`).
5. Older issue: the Eq. (13-1) check at interior and corner columns assumed `Mub` spans along c1. It now maps span/secondary moments with `span_axis` and `θ`. Callers pass `span_axis` via `punching_axis_kwargs(struc, slab, col)`. The `moment_transfer` tuple no longer carries `span_axis`.

Renames: `_span_moment_parallel_to_edge` -> `_span_moment_about_edge_axis`; `_placed_band_strain_ok` takes `design_c1, design_c2` and the per-direction transfer result.

`test_shear_studs.jl` "Transfer depth is settled before punching" had pinned the old one-sided edge band; moment raised to 62 kip·ft so 5 in fails and 5.5 in passes with the c2 + 3h band.

Tests: moment-transfer + shear transfer + studs + thickness jump 308/308; flat plate, size, punching reinforcement, Eq. 13-7, corner punching, flat slab, foundation 9.15: 1658 pass, 1 known broken. 3×3 DDM 24 ft: h 9.61 in both; increase off corners 24 in, edges 15, interiors 14; on: all 14 in, 2 iterations.
