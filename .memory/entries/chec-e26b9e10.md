---
id: chec-e26b9e10
type: checkpoint
project: menegroth
parent_id: deci-bad8d293
title: 'Guard F2 closed: enclosure mask shipped, P0 fail-open fixed, 468/468 wall
  tests'
node_label: 'Guard F2 closed: enclosure mask shipped, P0 fail-o'
tags: guard-f2, walls, checkpoint, tests-pass
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/lateral_evaluator.jl@7847655, StructuralSizer/src/walls/layout_problem.jl@7847655,
  StructuralSizer/test/walls/test_walls.jl@7847655
session_id: sess-fdd3423a
created_at: '2026-10-22T14:29:28.578532+00:00'
updated_at: '2026-10-22T14:29:28.578532+00:00'
---
Guard F2 CLOSED. The active-wall-ID mask + per-wall absolute penalized-stiffness activity test is shipped in lateral_evaluator.jl / layout_problem.jl, so the reduced-tier enclosure proxy no longer over-rejects a sound layout when a density-removed candidate sits outside the plate.

DONE:
- P0 fail-open (linear-density threshold -> empty active set at rho_min=1.0 -> enclosure guard self-disables) caught by the critic mid-session and FIXED with the absolute rho^penal > 1e-6 test.
- Reviewer PASS; Critic CONCERN with the P0 confirmed CLOSED (verified by running the real functions); Tester PASS 468/468 wall tests (baseline 428; +23 P0 regression assertions at rho_min in {0.5,1.0,1e-3}; one stale testset-D assertion corrected).
- Added constructor validation (0<rho_min<=1, penal>=1, candidate-id uniqueness) and restored the inverted-plate fail-closed before the mask skip.

NEXT: 3 residual P2s deferred to a FOLLOW-UP cycle (see sibling note) — dimensionless vs absolute stiffness masking, pre-existing crit8 centroid-vs-endpoint overhang, misleading empty-after-mask comment. All backstopped by eigenstructure floors + FEM survivor re-validation; none weaponizable into a fail-open.
