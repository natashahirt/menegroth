---
id: chec-2363aad1
type: checkpoint
project: menegroth
parent_id: plan-382ddd12
title: 'Stage D reconnaissance + DECISION POINT: BuildingUnit gives envelope column
  demands, not Mnt/Mlt-separated — per-column Mlt extraction needs a design choice'
node_label: 'Stage D reconnaissance + DECISION POINT: BuildingU'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-d553f493
created_at: '2026-11-23T04:27:22.440342+00:00'
updated_at: '2026-11-23T04:27:22.440342+00:00'
---
Mapped Stage D's integration surface in the W2 recheck (`_walls_with_member_recheck!`, pipeline_spec.jl): design_ordinary_walls! -> _floor_overstressed_frame_columns! -> column_force_envelopes(struc,params) -> frame_column_demand(env) -> rc_frame_column_check / the steel equivalent. That is where demand.lt would be populated and design_column_moments wired in (behind the off-by-default flag).

UNAMBIGUOUS part (safe to build): the per-story StoryStability inputs (ΣPu, story shear V, first-order drift Δ, story height L) are directly available from the solved ElfStoryAnalysis (cases[].design_drift_m per level, story shear, level story_height_m) and the wind story analysis. A `story_stability_from_analysis(...)` builder feeding StructuralSizer.StoryStability is clean and testable.

AMBIGUOUS part (DO NOT GUESS — safety-critical): per-column Mlt. flat_plate_column_check.jl `flat_plate_column_demands`/`column_force_envelopes`/`frame_column_demand` assemble column end moments as a COMBINED ENVELOPE from the single solved model (moments from 'different load patterns', single curvature assumed). They are NOT separated into gravity (Mnt) vs lateral-translation (Mlt). To populate demand.lt I must either (a) add a dedicated lateral-only solve pass that records each column's end moments under the ELF/wind cases alone (Mnt from gravity-only cases, Mlt from lateral-only), or (b) extend the existing separate case solves (gravity_basic_cases / elf_story_cases / wind_story_cases) to retain per-column member end moments, then combine per ASCE 7 §2.3 / ACI 318-11 §9.2 strength combos. Choice (a) vs (b) and the exact Mnt/Mlt load-combination definition is a design decision with direct safety impact — left for user per the code-accuracy rule.

STATUS: Stages A–C committed+pushed (46aa882 + 4d2f73ee). Stage D paused at this decision rather than writing an unverified extraction. Stage E (dual steel-frame + concrete-core LateralSystem + Table 12.2-1 dual rows) remains the second stop-point. Note: InteractiveShearWallFrameSystem (row F) is RC-frame+RC-wall; a steel-frame+concrete-core dual system is a NEW LateralSystem type needing its own R/Cd/Ω0 rows.

MORNING ASK: (1) Stage D extraction approach (a dedicated lateral-only solve vs extending the existing case solves) and the Mnt/Mlt combo definition; (2) Stage E target Table 12.2-1 dual-system row(s) for steel-frame + concrete-core.
