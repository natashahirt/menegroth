---
id: chec-54cc1e0f
type: checkpoint
project: menegroth
parent_id: deci-5da95787
title: Story cuts count -K_G u; ordinary-wall stage takes member forces from per-gravity
  story stiffness
node_label: P-delta steps 3-4
tags: walls,phase-7,p-delta,wilson-habibullah,story-cut,second-order
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/story_pdelta.jl@b2383a2, StructuralSynthesizer/src/analyze/lateral/wall_cuts.jl@b2383a2,
  StructuralSynthesizer/test/analyze/test_story_pdelta.jl@b2383a2, StructuralSynthesizer/src/analyze/lateral/elf_story_cases.jl@b2383a2
session_id: sess-31f3207f
created_at: '2026-10-31T13:01:03.781600+00:00'
updated_at: '2026-10-31T13:01:03.781600+00:00'
---
Steps 3 and 4 of deci-5da95787.

Committed here (tracked files):
- check_story_cut_equilibrium(; geometric_stiffness) adds -K_G u at nodes strictly above the cut (Wilson & Habibullah 1987 Eqs. 1-2, PDF p. 5). Four-column test: without K_G the Fx residual is 4P*Delta/h; with it the cut closes.
- story_pdelta.jl: GravityStiffnessKey, scale_story_loads (copies; zero factor returns empty), require_second_order_moment (ACI 318-19 6.2.5.3, PDF p. 72), base_master keyword on story_axial_profiles. The fixed-base check now requires frame members crossing the base to be fixed in plan; free wall mesh nodes between fixed frame joints are allowed (the wall mesh adds no supports).
- elf_story_cases.jl comment: ELF stays first-order; drift uses 1/(1-theta); member forces come from the stage's story stiffness.

NOT committed (untracked, with untracked dependencies design/, approaches/, ordinary_wall_inputs.jl): ordinary_wall_stage.jl and test_ordinary_wall_stage.jl. The stage builds one K_G per distinct factored gravity (D, L, roof) from first-order factored gravity, solves unfactored D, L, roof, all wind and strength QE cases on it, superposes through combine_wall_action (rho and Ev unchanged), checks factored-gravity story cuts with K_G, stops multiplying QE by 1/(1-theta), and records a failing 'second-order moment' WallCheckRecord (ACI 318-19 6.2.5.3) instead of throwing.

Tests: test_story_pdelta + test_ordinary_wall_stage 145 passed; ordinary wall stage alone 122 passed.

Open: both office fixtures show M2/M1 about 1.51 on combination 3's 0.5W reading even where story theta <= 0.10 (expected about 1.1). Unexplained; to investigate before trusting the 6.2.5.3 failures.
