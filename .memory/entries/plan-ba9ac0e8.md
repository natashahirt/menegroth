---
id: plan-ba9ac0e8
type: plan
project: menegroth
parent_id: plan-04899673
title: Incremental walls see a thickness change; diagnose the two flat-plate test
  failures
node_label: Incremental walls and two plate failures
tags: design-graph,provenance,punching,incremental,ordinary-walls
status: done
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design_graph/provenance.jl@bd99342, StructuralSynthesizer/src/design_graph/fingerprint.jl@bd99342,
  StructuralSynthesizer/src/design/parameters.jl@bd99342, StructuralSynthesizer/test/design_graph/test_design_graph_incremental.jl@bd99342,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/iteration.jl@bd99342
session_id: sess-c8598d3d
created_at: '2026-11-08T12:37:55.916761+00:00'
updated_at: '2026-11-08T12:37:55.916761+00:00'
has_child_rationale: The three incremental gaps named, and then left out of, the mat-development
  plan.
---
Follow-up to the three items plan-12232ba0 left out. None of them changes the from-scratch v4 office. Do not overwrite logs/core_office_v2, v3, or v4, and do not rerun that building for this plan.

1. Ordinary-wall provenance. The incremental scheduler reruns a stage only when a changed DesignParameters field is in that stage's param_slice, or when a dependency's output hash changes. Early cutoff then restores every later stage whose input hash did not change, from that stage's whole-structure snapshot (scheduler.jl). The ordinary-wall slice is lateral, wall_inputs, materials, and diaphragm_mode. The jump reads jump_wall_thickness and wall_thickness_grouping (ordinary_wall_stage.jl), and neither is in the slice. wall_thickness is the pier thickness initialize_members! bakes during prepare! (prepare.jl); the jump writes that field after it grows a wall, it does not read it as the starting thickness. The stage writes only ordinary_wall_result and diaphragm_layout. The jump changes wall thickness and re-solves; those writes do not include :walls or :asap_model, so a thickness change that leaves the two recorded results alone does not change the output hash. Foundations then keep their old snapshot, which puts the old thickness back.

Add jump_wall_thickness and wall_thickness_grouping to the ordinary-wall param_slice and bump code_version. Put wall_thickness on PREPARE_AFFECTING_FIELDS so an incremental edit cannot keep walls that were meshed at the old thickness; that edit builds a new engine. Extend the output hash so a thickness change is visible to foundations. :asap_model is already fingerprinted from frame forces, displacements, and reactions, not from shell thickness (fingerprint.jl). Reactions move when the wall weight moves, but the hash should also see each wall's thickness directly. Do not hash the whole walls object through repr. A soil-only change must still recompute foundations only and restore the walls.

Test: wall_thickness requires a new engine. An incremental edit of each jump field recomputes ordinary walls, and the mat matches a from-scratch design. The fixture is one 8 m bay, one 6 m story, four base walls at 150 mm. Those walls pass by raising reinforcement, so the jump does not change the thickness and foundations may stay clean (early cutoff). When a wall thickness does change, the ordinary-wall output hash changes; that is what makes foundations recompute. A soil-only change must still recompute foundations only.

2. Shared-column punching. The test "shared-column slabs use propose, envelope, commit, lock" builds a one-story 3×3-bay plate, one FEA slab per panel, at 125 psf live load, so punching grows the shared columns. It sets max_iterations = 5. The production default is 20. The old run stopped with a non-installable floor (punching_shear) inside the slab stage, before the envelope assertions. The column and the last ratio were not recorded.

Reproduced at max_iterations = 5 (log logs/punching_diagnose.log). The design now finishes: 9 slabs, DESIGN_OK. Corner columns reach the 30 inch cap with punching ratios 1.056 to 1.070 (columns 1, 2, 3, and 4, position :corner). The resolver then thickens the slab (10.0 inch, then 10.5 inch). At 10.0 inch one corner was 1.0002; the later corners at 10.5 inch were 1.011 to 1.017, and the design still installed. Phase B did not stop on the iteration budget. monotone_budget already lets a still-growing column use its remaining size steps, so raising this fixture from 5 to 20 is not what made it finish. Do not loosen punching. Do not raise the production default. Run the testset to confirm the envelope assertions. If a column is still over 1 after the installed design, that is a separate check failure and the test will say so.

3. Column interaction ratio. The test "multi-node-level" designs a three-story direct-design flat plate from scratch at 1.2D+1.6L, and again by editing a session that started at 1.4D. Both designs finish. Every column's axial_ratio and interaction_ratio differs, and every footing's bearing_ratio differs. Sections, slab results, and footing plans match. The first pair is col1, story 1, corner, at the origin: axial_ratio 0.08272 from scratch against 0.05449 incremental. That ratio is the 1.2D+1.6L demand over the 1.4D demand. Capture reads the frame element forces. The incremental path still holds the session's 1.4D solve.

The slab level does refresh the tributary pressures and re-solves (sync_asap!, and the member node writes :asap_model). Foundations do not see that hash. They depend only on the ordinary-wall node, whose output hash is the thickness list. A gravity building has no walls, so the hash does not move. Foundations stay clean. The all-clean restore then puts the base snapshot back, including the 1.4D forces and the 1.4D bearing. Slab thickness and rebar can still match, because this plate is not combination-governed in those fields.

Foundations now depend on the member node as well as the wall node. The member output hash moves with the frame forces, so foundations recompute on the refreshed reactions instead of restoring the base snapshot. The wall node still runs first. Do not drop interaction_ratio from the signature. Do not change the interaction equation.

Done. The incremental suite and the ordinary-wall stage passed together, 905 tests, on 2026-11-08 (logs/test_StructuralSynthesizer_20261108_163143.log). Foundations still run after the wall stage. Do not treat a vault failure on _verify_tbeam_flanges as one of these three; that file is plan-12232ba0.
