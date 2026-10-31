---
id: chec-db1218c3
type: checkpoint
project: menegroth
parent_id: plan-3c70ba75
title: Half-story wall and frame self-weight is in ELF W and Px
node_label: self-weight in W and Px
tags: walls,phase-7,elf,p-delta,seismic-weight,px,asce-7-22
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/elf_story_cases.jl@0cd0f9b, StructuralSynthesizer/test/analyze/test_elf_story_cases.jl@0cd0f9b,
  StructuralSynthesizer/src/analyze/lateral/ordinary_wall_stage.jl@0cd0f9b, StructuralSynthesizer/src/analyze/lateral/ordinary_wall_inputs.jl@0cd0f9b,
  StructuralSynthesizer/src/analyze/lateral/approaches/_approaches.jl@0cd0f9b, StructuralSynthesizer/src/analyze/lateral/approaches/types.jl@0cd0f9b,
  StructuralSynthesizer/src/analyze/lateral/approaches/interface.jl@0cd0f9b, StructuralSynthesizer/src/analyze/lateral/approaches/systems/walls_seismic_system.jl@0cd0f9b,
  StructuralSynthesizer/src/analyze/lateral/approaches/systems/outrigger_system.jl@0cd0f9b,
  StructuralSynthesizer/src/analyze/lateral/approaches/assignment/building_unit.jl@0cd0f9b,
  StructuralSynthesizer/src/analyze/lateral/approaches/assignment/isolated_wall_share.jl@0cd0f9b,
  StructuralSynthesizer/src/design/display_units.jl@0cd0f9b, StructuralSynthesizer/src/design/material_options.jl@0cd0f9b,
  StructuralSynthesizer/src/design/parameters.jl@0cd0f9b, StructuralSynthesizer/src/design/overrides.jl@0cd0f9b,
  StructuralSynthesizer/src/design/context.jl@0cd0f9b, StructuralSynthesizer/src/design/summary.jl@0cd0f9b,
  StructuralSynthesizer/src/design/building_design.jl@0cd0f9b, StructuralSynthesizer/src/design/results/slab.jl@0cd0f9b,
  StructuralSynthesizer/src/design/results/column.jl@0cd0f9b, StructuralSynthesizer/src/design/results/beam.jl@0cd0f9b,
  StructuralSynthesizer/src/design/results/foundation.jl@0cd0f9b, StructuralSynthesizer/src/design/results/wall.jl@0cd0f9b,
  StructuralSynthesizer/src/design_types.jl@0cd0f9b, StructuralSynthesizer/test/analyze/test_ordinary_wall_stage.jl@0cd0f9b,
  scripts/runners/pdelta_ratio_probe.jl@0cd0f9b
session_id: sess-c86634db
created_at: '2026-10-31T14:34:05.963160+00:00'
updated_at: '2026-10-31T14:34:05.963160+00:00'
has_child_rationale: Implements the half-story lumping plan and records the probe
  result
---
Implemented the 2026-10-31 half-story lumping in _elf_levels. Each wall pier (meshed shell weight ρ t g × area, the same shells as the unfactored dead case) and each existing Asap.GravityLoad (ρ A g L) is split half to the story elevation at each end. A share that lands on the base is omitted from W and from Px. Beams with both ends at one elevation contribute their full weight there. The split is engineering judgment; ASCE 7-22 does not assign a story-spanning member.

Citations in elf_story_cases.jl, corpus asce-7-22: §12.7.2 PDF p. 184 (W includes the dead load above the base); §12.8.6.1 PDF p. 187 (expected gravity is no less than 1.0D + 0.5L; self-weight is dead, so it adds the same kN to weight_kN and gravity_kN); §12.8.7 PDF pp. 187–188. A :grade or :unknown cell above the base throws, because it would be in W and absent from the dead case. Grade at the base is in neither.

Cross-check: the sum of level weights equals above-base cell dead plus the above-base share of wall and frame self-weight. The ELF test also checks that the unfactored dead-case downward resultant equals cells above the base plus the full wall weight. A column GravityLoad increases the level at the column top by half its weight.

Fixtures in test_ordinary_wall_stage.jl:
- Stiff 12 m office, four isolated pier lines: θ ≤ 0.0008 both ways, so the §12.8.7 multiplier is 1.
- Flexible 10×6 office. After the 0.35 crack, Y-pier E is multiplied by an extra 0.001. That factor is a fixture knob, not an ACI cracked-section factor. θ_Y = 0.115, inside (0.10, θmax = 0.125]. Wind in-plane M2/M1 is about 1.18, near 1/(1−θ) ≈ 1.13. The gap is multi-story θ, and K_G is built on 1.2D+1.6Lr rather than ELF's 1.0D+0.5L. Pier 1's net factored ratio is 1.408 because factored dead and wind oppose. The stage records a failing ACI 318-19 §6.2.5.3 WallCheckRecord. That is a real check failure.
- Y-weak one-wall office: θ = 0.247 > θmax. design_ordinary_walls! throws ArgumentError (the structure shall be redesigned).

An X wall's in-plane moment under Y wind is diaphragm torsion. The asymmetric pier layout offsets the center of rigidity, floor rotation produces in-plane Fx on the X walls, and wall_action_from_global reports that moment about the pier normal. On the flexible office the story-0 X wall carries about 343 kN·m in-plane under the Y wind case, comparable to the Y pier.

Story-cut axial under 1.0D is larger than ELF Px (about 1.06, 1.14, and 1.53 by level on the flexible office) because the cut sums the load path and Px uses the half-story lump. Not a dropped load.

Frame self-weight is included only when a GravityLoad is already on the model. The stage fixtures call to_asap! without member sizing, so their columns and beams add no GravityLoad. That matches the dead case. After sizing, ELF has to be re-run to pick up new GravityLoads.

Tests: analyze/test_ordinary_wall_stage.jl and analyze/test_elf_story_cases.jl, 237 passed, 0 failed (logs/test_StructuralSynthesizer_20261031_100656.log). This commit also adds the ordinary-wall stage, its test, the design/ split of design_types.jl, approaches/, ordinary_wall_inputs.jl, and scripts/runners/pdelta_ratio_probe.jl. The walls/ split of walls_bridge.jl is left uncommitted. The tuning script elf_theta_probe.jl was deleted and is not in the commit.
