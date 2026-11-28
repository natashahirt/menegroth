---
id: chec-ed3411bc
type: checkpoint
project: menegroth
parent_id: plan-fe5b383c
title: 'Phase 1 DONE: center-box core generator; + key architecture finding on sway
  classification'
node_label: P1 core gen done + arch
tags: slenderness,aci-10.10,core,walls,sway,medium_office,generator
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/generate/doe/medium_office.jl@0e96674, StructuralSynthesizer/src/StructuralSynthesizer.jl@0e96674,
  scripts/runners/core_generator_probe.jl@0e96674
session_id: sess-d1c50a9a
created_at: '2026-11-22T13:20:09.750529+00:00'
updated_at: '2026-11-22T13:20:09.750529+00:00'
---
## Phase 1 complete & validated

Added a package API for a closed-box shear-wall core on the DOE medium office:
- `gen_medium_office(...; core=:center_box)` kwarg + exported `add_center_core!(skel, get_pt, x_bays, y_bays, n_stories)` and internal `_claim_or_add_wall_edge!` in `generate/doe/medium_office.jl`.
- Claims the 4 central-bay plan edges into `:walls` on levels 0..n_stories-1 (grade through story below roof). A `:walls` plan edge at floor level k -> `Wall(story=k)` spanning z=k.h..(k+1).h (`_push_wall!`), so levels 0..n-1 brace physical stories 1..n (full height). Grade (level 0) edges are added fresh (no grade beams exist there); floors 1..n-1 claim the existing beams. Box corners are column lines that already reach the roof, so NO roof-vertex seeding needed (unlike shaft core in scripts/runners/core_office_geometry.jl).

Probe `scripts/runners/core_generator_probe.jl` (3x3x4, t=0.3m): 16 wall edges; walls per story [(0,4),(1,4),(2,4),(3,4)] -> ground story 0 braced (not off-by-one); 2048 :wall ShellTri3 after to_asap!; central-bay slabs flagged 'supported on walls on every side' (ACI 9.5.3.3(c)). PASS.

## KEY ARCHITECTURE FINDING (refines Phases 2-4)

1. `compute_story_properties!` is NEVER called in the production design pipeline (only inside `p_delta_iterate!`, which the pipeline does not call -- see story_properties.jl:407-411). So `col.story_properties === nothing` always in production.
2. Therefore `flat_plate_story_is_sway` (StructuralSizer column_bracing.jl) ALWAYS falls through to the wall-presence heuristic `isempty(supporting_wall_segments(struc,slab))`. The real Q-path (ACI 10.10.5.2, Eq 10-10) exists but is DORMANT. This wall-presence shortcut is exactly what the user rejected ('don't just check for a core').
3. Production philosophy today: columns are ALWAYS designed braced (k=1); lateral second-order effects are carried entirely by the wall stage `design_ordinary_walls!` via story geometric stiffness + ASCE 7-22 §12.8.7 1/(1-theta) multiplier. The `alignment_chart_k` sway path only fires for bare frames with NO walls; it THROWS for psi>=100 (6-story bare flat plate).
4. The lateral stage IS the real verdict: `_analyze_lateral_walls!` runs Ch.27 wind + ELF seismic, computes story drift (`drift::Vector{SeismicStoryDriftCheck}`), stability coeff theta (`max_story_stability`), second-order P-delta, pier strength; theta>theta_max is REFUSED (throws); drift failures trigger wall-thickness jumps (`propose_wall_thicknesses`). Requires `params.lateral` (LateralDesign w/ WallsSeismicSystem x+y) + `params.wall_inputs::OrdinaryWallInputs` + `params.diaphragm_mode=:rigid` + wall_thickness. With `params.lateral===nothing` and walls present it does gravity-only sizing (NO lateral check).

## Refined plan for 2-4
- With a core present, the building ALREADY avoids the crash (walls -> nonsway provisional) and the wall stage already provides real drift/theta/strength verification -> satisfies 'check the lateral system works first'.
- Phase 2 = WIRING (config, not code): build a 6-story flat-plate + core with LateralDesign+OrdinaryWallInputs (deci-46d9c7bc walls-only seismic pattern; test_ordinary_wall_stage.jl fixtures) and run design end-to-end to PROVE it designs cleanly with lateral verification.
- Phase 4 = graceful error: convert the opaque `alignment_chart_k` psi>=100 throw into a clean 'story laterally inadequate per ACI 318-11 §10.10 -- add a lateral system' design-level message for bare tall frames.
- Open question being resolved empirically next: whether to leave the wall-presence provisional as-is (core verified by wall stage) vs. force gravity-provisional-braced uniformly (would break test_wave2_sensitivity which expects sway k>1 for bare moderate frames -- that sway-chart feature is intentional for true moment frames).
