---
id: plan-ba9ac0e8
type: plan
project: menegroth
parent_id: plan-04899673
title: Incremental walls see a thickness change; diagnose the two flat-plate test
  failures
node_label: Incremental walls and two plate failures
tags: design-graph,provenance,punching,incremental,ordinary-walls
status: active
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

1. Ordinary-wall provenance. The incremental scheduler reruns a stage only when a changed DesignParameters field is in that stage's param_slice, or when a dependency's output hash changes. Early cutoff then restores every later stage whose input hash did not change, from that stage's whole-structure snapshot (scheduler.jl). The ordinary-wall slice is lateral, wall_inputs, materials, and diaphragm_mode. The jump reads wall_thickness, jump_wall_thickness, and wall_thickness_grouping (parameters.jl, ordinary_wall_stage.jl), and none of the three is in the slice. The stage writes only ordinary_wall_result and diaphragm_layout. The jump changes wall thickness and re-solves; those writes do not include :walls or :asap_model, so a thickness change that leaves the two recorded results alone does not change the output hash. Foundations then keep their old snapshot, which puts the old thickness back.

Add the three fields to the ordinary-wall param_slice and bump code_version. Extend the output hash so a thickness change is visible to foundations. :asap_model is already fingerprinted from frame forces, displacements, and reactions, not from shell thickness (fingerprint.jl). Reactions move when the wall weight moves, but the hash should also see each wall's thickness directly. Do not hash the whole walls object through repr. A soil-only change must still recompute foundations only and restore the walls.

Test: an incremental edit of each of the three fields recomputes ordinary walls and then foundations, and the resulting mat matches a from-scratch design at the new thickness. The existing soil-change test still recomputes foundations only.

2. Shared-column punching. The test "shared-column slabs use propose, envelope, commit, lock" builds a one-story 3×3-bay plate, one FEA slab per panel, at 125 psf live load, so punching grows the shared columns. It sets max_iterations = 5. The production default is 20, and each flat-plate phase, including punching, loops that many times (iteration.jl). The run stopped with FLOOR_DESIGN_NOT_CONVERGED (punching_shear) inside the slab stage, before the envelope assertions. The column and the last ratio were not recorded. A previous plate (deci-202e97fd) sat at 1.000–1.001 after 3 punching passes and converged at 10.

Reproduce that testset only. Record the failing column, its ratio, and the pass count. If the ratio is at the limit and 5 passes are what stopped it, give this fixture the production budget of 20. Do not raise the production default. If a column is still over 1 after 20 passes, read that column's growth path (size cap, slab thickness, mesh) before changing a check. Do not loosen punching.

3. Column 36 interaction ratio. The test "multi-node-level" designs a three-story direct-design flat plate from scratch at 1.2D+1.6L, and again by editing a session that started at 1.4D. Both designs finish. The first differing field is col36.interaction_ratio, the stored axial-plus-moment utilization. The two numbers were not printed. load_combinations is already in the members param slice.

Reproduce that testset only. Print both ratios and which column 36 is (story and grid). If the sections match and only the stored ratio differs, make the incremental path record the same governing combination the from-scratch path records. If the section itself differs, trace whether members reran on the combination change and whether the column forces match. Do not drop interaction_ratio from the signature.

Order: step 1 is specified and can be written directly. Steps 2 and 3 start by printing the number the last run did not keep, and the fix follows that number. Do not change the foundation order, and do not treat a vault failure on _verify_tbeam_flanges as one of these three; that file is plan-12232ba0.
