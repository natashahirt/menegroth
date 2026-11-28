---
id: chec-4dd4001f
type: checkpoint
project: menegroth
parent_id: plan-b10cde0c
title: FEA :frame split warning fires only where the §13.6.4 tables do not reach
node_label: Split warning narrowed
tags: warning,fea,ddm,aci-318-11,13.7.7.5
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f2c3db2f
created_at: '2026-11-09T01:51:28.338694+00:00'
updated_at: '2026-11-09T01:51:28.338694+00:00'
has_child_rationale: Step 5 of the revised plan (deci-44674e99), implementing deci-d7e4064a
---
Implements deci-d7e4064a. No files pinned (working tree holds other sessions' uncommitted work).

Sources read: aci-318-11 §13.7.7.5 (page 262), §13.6.1.6 and §13.6.1.2 (page 252), §13.6.4.1-§13.6.4.2 tables (page 255).

Change: `_check_fea_approach_applicability` no longer warns on a failed `check_ddm_applicability`. New `_frame_fraction_stretches(struc, slab, columns)` (helpers.jl) lists (1) a non-rectangular panel by `_panel_rectangularity_violations` or `is_rectangular = false`, and (2) in each span direction, the αf1·ℓ2/ℓ1 ≥ 1 row (wall parallel to the span) at ℓ2/ℓ1 outside 0.5-2.0, where `_aci_table_l2_l1` clamps. The αf1 = 0 row is constant in ℓ2/ℓ1, so a flat plate with no parallel wall never warns on aspect. §13.6.1.6 is not evaluated: it governs panels with beams on all sides and these slabs have none. Row selection moved to `_column_strip_row` (ddm_coefficients.jl), which `slab_column_strip_fractions` now calls, so the warning tests the row the split uses. API params_schema.jl guidance text updated to match.

Test: slabs/test_wall_supports.jl new testset; with slabs/test_flat_plate.jl 198/198 --fresh (logs/test_StructuralSizer_20261108_204528.log).

Not decided by the code: an aspect ratio above 2 on the flat-plate row (R13.6.1.2 says such a panel acts one-way) no longer warns under :frame, per the user's trigger list.
