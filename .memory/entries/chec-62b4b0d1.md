---
id: chec-62b4b0d1
type: checkpoint
project: menegroth
parent_id: plan-d0c5bff3
title: 'Phase 5 wall assembly test: zero section, free nodes, 1 mm share, stiffness
  token'
node_label: 'Phase 5 wall assembly test: zero section, free nod'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/test/analyze/test_wall_phase5_assembly.jl@d2fbbce, StructuralSynthesizer/test/runtests.jl@d2fbbce,
  StructuralSynthesizer/src/building_types/members.jl@d2fbbce
session_id: sess-4412100a
created_at: '2026-10-23T02:35:46.454866+00:00'
updated_at: '2026-10-23T02:35:46.454866+00:00'
has_child_rationale: Pin the Phase 5 assembly test and the Column constructor fix
  it required
---
Phase 5 whole-phase test, after critic PASS (run-2d04afbe). StructuralSynthesizer/test/analyze/test_wall_phase5_assembly.jl: 67/67. core/test_wall_data_model.jl still 84/84. Registered in test/runtests.jl.

Asserts: a :walls frame section has zero A, Ix, Iy, J, and density; a neighboring beam stays the placeholder; nodes the mesh creates are free; a reused frame joint keeps its dof; a reused support stays fixed; 0.9 mm shares a node and 1.1 mm does not; an equal nearest pair throws; the stiffness token changes when the wall moves, when κ changes (restore of 5/6 brings it back), and when two shell nodes are swapped; density does not change the token. The fixture is a supported office, so the test does not require an isolated wall to solve.

Also stores corner_kind and corner_angle on the Column convenience constructor. The struct already had the fields and initialize_members! was already passing them, which threw MethodError. No other constructor line changed.

Not a design pipeline. apply_wall_cache_class still throws. Diaphragm governance remains deci-2c1bee70.
