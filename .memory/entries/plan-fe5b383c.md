---
id: plan-fe5b383c
type: plan
project: menegroth
parent_id: todo-d50bda2c
title: 'H4 build: shear-wall core generator for tall flat-plate buildings (fixes the
  §10.10 slenderness crash by bracing columns)'
node_label: 'H4 build: shear-wall core generator for tall flat-'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/generate/doe/medium_office.jl@66bbf28, StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/column_bracing.jl@66bbf28,
  StructuralSizer/src/members/codes/aci/columns/slenderness.jl@66bbf28
session_id: sess-c81aa90c
created_at: '2026-11-22T12:48:46.428455+00:00'
updated_at: '2026-11-22T12:48:46.428455+00:00'
---
Confirmed scope (user): central closed box core around the middle bay; low-moderate seismic defaults (SDC B/C, Risk Cat II, ordinary wind), flagged engineering-judgment; Phases 1-4 including graceful fallback.

WHY IT WORKS: the flat-plate pipeline does NOT call compute_story_properties!, so `col.story_properties == nothing` and `flat_plate_story_is_sway` (column_bracing.jl) falls to the `supporting_wall_segments` branch. A core wall meeting each slab elevation marks every story nonsway 'by inspection' (ACI 318-11 R10.10.5) -> columns braced, k=1 -> the Jackson-Moreland sway chart (alignment_chart_k) is never called -> the `no finite k on Fig. R10.10.1.1` ArgumentError (slenderness.jl) disappears. The heavy lifting (Wall{T} shells, design_ordinary_walls! = NODE_ORDINARY_WALLS, ASCE 7 wind+ELF seismic, drift/theta, pier+boundary sizing) ALREADY EXISTS and is tested (test_core_shaft.jl, test_ordinary_wall_stage.jl, test_rigid_office_piers.jl). Only NEW code is the core generator + parameter wiring.

Root cause: gen_medium_office (generate/doe/medium_office.jl) emits only :beams/:columns/:support/:roof — no :walls. A 6-story bare flat-plate frame is a laterally-inadequate sway frame (psi~130 both joints, k>40 bracket -> throw). <=3 stories design fine.

PHASE 1 — core generator: promote the test-only pattern in scripts/runners/core_office_geometry.jl (_add_wall!/_claim_as_wall!) into a package API under src/generate/ (e.g. gen_medium_office(...; core=:center_box, core_thickness) or add_core!). Tag center-bay plan edges into skel.groups_edges[:walls] per story (closed box). initialize_members!->_push_wall! makes Wall{T}; to_asap! meshes ShellTri3.
PHASE 2 — lateral wiring: DesignParameters.lateral = LateralDesign(system=WallsSeismicSystem(...)) [matches deci-46d9c7bc walls-only seismic, gravity frame], params.wall_inputs::OrdinaryWallInputs (wind+ELF+SDC low-mod defaults), wall thickness for :walls.
PHASE 3 — verify: 6-story medium office w/ core designs cleanly (no crash, columns braced, OrdinaryWallResult drift/theta within limits, all_checks_pass); member-stage 299/299 green; 3-story no-core regression unchanged; add a test.
PHASE 4 — graceful fallback: replace the opaque alignment_chart_k throw with a clear design-level 'story N laterally inadequate per §10.10.2.1 — add a lateral system' result for no-core tall buildings.

GATES per phase: member-stage 299/299 + relevant wall/equiv tests; surgical commits (exclude rib agent files); memory record before each commit.
