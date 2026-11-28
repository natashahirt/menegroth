---
id: chec-43fff097
type: checkpoint
project: menegroth
parent_id: plan-347b59e9
title: Special-boundary geometry, drift, stress, and confinement amount, with behavior
  tests
node_label: Boundary checks tested
tags: walls,aci-318-19,18.10,boundary-element,checkpoint
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f21322f7
created_at: '2026-11-10T14:47:04.073815+00:00'
updated_at: '2026-11-10T14:47:04.073815+00:00'
has_child_rationale: Slices 1–4 of the special-boundary plan are pure checks, and
  the tests lock the edges the clauses actually turn on.
---
Slices 1–4 of plan-347b59e9 are in StructuralSizer as pure functions. Nothing is placed, design_ordinary_walls! is unchanged, and special=true stays off.

Functions, each cited to corpus aci-318-19:
- boundary_transverse_extension: §18.10.6.2(b)(i), page 326. Greater of ℓw and Mu/4Vu. Mu must be non-negative and Vu positive.
- boundary_element_horizontal_length: §18.10.6.4(a), page 327. Greater of c − 0.1ℓw and c/2. A negative offset does not set the length.
- compression_zone_width: §18.10.6.4(b) and (c), page 327. hu/16 always; 12 in. only when hw/ℓw ≥ 2, c/ℓw ≥ 3/8, continuous, and one critical section.
- boundary_drift_capacity: Eq. (18.10.6.2b) and (iii), page 326. Ratio is not taken below 0.015, and the comparison uses that floored value. The 0.005 floor from (a) is not reapplied. (ii) is still uncoded.
- stress_boundary_element: §18.10.6.3, page 327. Exceeds 0.2f′c starts one; less than 0.15f′c may end one. Equality does neither.
- boundary_transverse_amount: Table 18.10.6.4(g), page 328. Rectilinear crossover at Ag/Ach = 1.3; spiral at 19/15. Ag < Ach does not throw; the constant term governs.

Tests in StructuralSizer/test/walls/test_special_boundary.jl are written to show which term governs and where each gate opens. Fresh run: 97/97, logs/test_StructuralSizer_20261110_094207.log.

Still later: §18.10.6.2(b)(ii) until the stacked expression is confirmed; §18.10.6.4(e)–(k); §18.10.6.5 (the λ√f′c radical is missing in the text layer); coupling beams; deformation compatibility.

Files not pinned: the working tree holds other sessions' uncommitted work, and this checkpoint was not asked to commit.
