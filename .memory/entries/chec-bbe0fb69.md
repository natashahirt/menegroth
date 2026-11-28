---
id: chec-bbe0fb69
type: checkpoint
project: menegroth
parent_id: deci-7d2c3467
title: 'Dual increment (3) DONE: frame-only capability gate @25% base shear (steel)'
node_label: 25% capability gate
tags: dual-system,asce-7-22,12.2.5.1,12.8.7,seismic,moment-frame,capability-gate,frame-only,theta,done
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/dual_frame_checks.jl@3d833d1, StructuralSynthesizer/src/analyze/lateral/dual_system_stage.jl@3d833d1,
  StructuralSynthesizer/test/analyze/test_ordinary_wall_stage.jl@3d833d1, scripts/runners/dual_stage_smoke.jl@3d833d1
session_id: sess-ccd39378
created_at: '2026-11-24T01:46:35.398858+00:00'
updated_at: '2026-11-24T01:46:35.398858+00:00'
has_child_rationale: Implements the authoritative capability-gate tier of deci-7d2c3467
  (bare-frame solve; proxy was necessary-not-sufficient)
---
Increment (3) of the dual-system stage: the **authoritative** frame-only capability gate (deci-7d2c3467). Runs once (not in-loop).

## What it does
`dual_frame_capability_gate(struc, second, basic, elf, effects, inputs, seismic_system, mf, directions)` (new, dual_frame_checks.jl) clones the lateral model with the core removed (`Asap.solve(... exclude_shells=true)`) and applies 25% of each design seismic effect (reuses `_quarter_story_cases`, scale 0.25). Records:
- `capability_stability::Vector{FrameCapabilityStability}` (story, direction, θ, θmax, passed): the bare-frame story stability coefficient θ (ASCE 7-22 Eq. 12.8-18 via `stability_coefficient`, divided by (1+θ) per §12.8.7) vs θmax (Eq. 12.8-19 via `stability_coefficient_limit(inputs.β, seismic_system.Cd; Ω0)`). Governing (MAX) θ per (story,direction) over the earthquake-gravity keys. Drifts from `_master_story_drifts` on the no-torsion 25% stability case; Vx = 0.25·|elf.cases[strength_idx].Vx_kN|.
- `capability_members::Vector{FrameMemberCheck}`: each steel MF member under 25% frame-only demand via increment-(2) machinery (`_split_nt_lt` + `_steel_nt_lt_demand` + `_steel_member_report`). Gravity from the FULL-model second-order solve `second[key].u[1..3]`; lateral from the frame-only (exclude_shells) solve `solved[key][k]` (already 25%-scaled). Per-story B2 reuses `_dual_story_b2_records` (combined-system), same basis as increment 2. Non-steel skipped+counted.

## Wiring
`design_dual_system!` now builds `second = _build_second_order(struc, basic; wind, elf, effects)` (second-order Kg per earthquake gravity key) and calls the gate with `directions=[:x,:y]`, `seismic_system=sysx`. `DualSystemResult` gains `capability_stability` + `capability_members`; `pending` is now EMPTY (all three dual-specific checks wired; only RC frame-member path remains, noted in diagnostics). Gate recorded (NOT thrown), consistent with increments 1/2.

## Gate / observed behavior
StructuralSynthesizer analyze/test_ordinary_wall_stage.jl: **734/734 pass** (726 + 8 new capability asserts), fresh, 24m31s. Lints clean. Smoke (dual_stage_smoke.jl, _stage_office steel-MF+RC-core): frame carries only ~0.2-2.5% of story shear (proxy correctly flags all 6 story-dirs below 25%); bare frame unstable at 25% (θ=0.06-0.33 vs θmax=0.083, 5/6 over); 55 steel members all pass strength (tiny ratios). Confirms moment frames are drift/stability-governed, not strength — motivates increment (4) drift governor.

## NOT committed at record time. Steel-only (RC member path still skipped+counted). Capability gate requires rigid masters (`_build_second_order` with elf); dual+concrete-core is rigid-diaphragm by design.
