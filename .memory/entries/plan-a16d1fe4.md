---
id: plan-a16d1fe4
type: plan
project: menegroth
parent_id: plan-267f93b4
title: 'Overnight: design_building, joint search default, two-way αfm, mat framed
  stiffness'
node_label: Overnight four segments
tags: design-building,joint-search,two-way,mat,aci-318-11,aci-336
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-20a447a5
created_at: '2026-11-14T04:08:49.418892+00:00'
updated_at: '2026-11-14T04:08:49.418892+00:00'
has_child_rationale: User approved the overnight run of the four-segment sketch.
---
User said to run the four-segment sketch autonomously on row-f-nlp (worktree /tmp/menegroth-rowf). Order: (1) design_building, so compare_sizes.jl can run — port _initialize_unsized_columns! into the worktree column_updates.jl, and a design_floor method for OneWay that installs the existing span sizer; (2) flat-plate joint search as the default (punching_strategy = :joint_search, plan-a7b938a9 / chec-ac48f14e) and reset columns when slab h restarts, plus call check_flat_plate_columns! from reconciliation so §13.6.9.2 moments are applied; (3) two-way αfm loop using ACI 318-11 §9.5.3.3 Eqs. (9-12)/(9-13) and Eq. (13-3), with Ib taken only from a readable corpus sentence; (4) mat Kr gains Σ E' I_b per the signed-off reading of ACI 336.2R §5.2 Eq. (5-2): beams and columns framing into the mat, gross I, same E' as the footing, sum divided by the building width perpendicular to the strip. Eq. (5-1) stays as already implemented until the page image is readable. Each segment: unit test, then commit. No files passed, because the memory server watches the main checkout.
