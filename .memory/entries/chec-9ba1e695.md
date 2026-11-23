---
id: chec-9ba1e695
type: checkpoint
project: menegroth
parent_id: chec-66c55e47
title: 'Dual-system stage backbone: design_dual_system! (validation + dual factors
  + ELF/wind/drift + designation)'
node_label: dual stage backbone
tags: dual-system,stage,design_dual_system,ELF,drift,asce-7-22,12.2.5.1,StructuralSynthesizer
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/dual_system_stage.jl@94ee0b0, StructuralSynthesizer/src/analyze/_analyze.jl@94ee0b0,
  StructuralSynthesizer/src/StructuralSynthesizer.jl@94ee0b0, StructuralSynthesizer/test/analyze/test_ordinary_wall_stage.jl@94ee0b0,
  scripts/runners/dual_stage_smoke.jl@94ee0b0
session_id: sess-3ee19ad6
created_at: '2026-11-23T21:44:30.933299+00:00'
updated_at: '2026-11-23T21:44:30.933299+00:00'
has_child_rationale: 'Stage B: the new dual analysis stage''s backbone, runner-verified
  end-to-end'
---
## What (new stage per deci-7a4e26c2)
`StructuralSynthesizer/src/analyze/lateral/dual_system_stage.jl`: `design_dual_system!(struc, params; tc)` + `DualSystemResult`. A dedicated dual stage (kept out of the concrete-wall stage, which refuses non-wall systems). Backbone:
- Validation: DualSystem on both axes, BuildingUnit, wall_inputs present, roof companion, pdelta flag false, model processed; no-walls returns nothing.
- Factors: `dual_seismic_system(table_12_2_1_row(sx/sy), sdc)` → R/Cd/Ω₀ (NP category refused).
- Reuses the shared plumbing: prepare_lateral_model!, moment_frame_members, diaphragm handling, solve_gravity_basic_cases, wind_story_analysis, elf_story_analysis, seismic_effect_cases, _story_drift_with_pdelta, _max_drift_theta.
- Returns drift + θ + pdelta multipliers + moment-frame designation + rows; sets struc.stage_diagnostics[:dual] listing the 3 pending dual-specific checks.
Included in _analyze.jl; exported design_dual_system!/DualSystemResult.

## Verification (runner: scripts/runners/dual_stage_smoke.jl)
Ran on a genuine steel moment frame + concrete-core fixture (_stage_office with park_wall_overlaps=FALSE — park=true collapses the frame to 3 columns; false keeps 27 columns + 28 girders + 12 core walls). Result: row D9, moment_frame source=override (28 girders), 27 columns, 18 drift entries, θ=0.0007, 3 pending, diagnostics set. SMOKE OK. Test added as the first testset in test_ordinary_wall_stage.jl mirroring this exactly (full-file gate running detached at commit time).

## Key modeling facts learned
- `:girder` = column-to-column beam (classify_beam_role). Only `default_release(:girder, StructuralSteel, :moment_frame)=(:fixed,:fixed)` is declared — so a steel moment-frame beam IS a girder. Auto-designation keying on :girder is correct; flagging :joist/:beam as moment_frame throws (no release). 
- park_wall_overlaps=true merges frame columns into claimed walls (good for pure-wall fixtures, bad for a moment-frame fixture).

## Still pending (stage B/C/D, each a safety-critical increment NOT to be guessed)
1. §12.2.5.1 share proxy: per-story frame/wall shear split (frame columns' shear vs total story shear).
2. Frame-member strength with B1/B2 (steel via unified _aisc_amplified_forces; story stability from ELF) — generalize RC interactive_checks to steel.
3. Separate frame-only capability gate at 25% base shear (reuse the row-F _check_frame_only_stability! pattern, generalized to steel).
4. Drift-governor wiring (core=background; δ_allow=Δa·Ie/Cd) + graph_builder node + 20–40 story proof.
