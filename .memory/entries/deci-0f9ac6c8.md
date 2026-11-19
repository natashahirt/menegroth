---
id: deci-0f9ac6c8
type: decision
project: menegroth
parent_id: plan-00ace284
title: Flat-plate columns take the lightest catalog section that passes
node_label: lightest passing column
tags: flat-plate,columns,section-search,punching,aci-318-11
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-833261e5
created_at: '2026-11-17T16:26:43.385355+00:00'
updated_at: '2026-11-19T18:06:52.185907+00:00'
has_child_rationale: The corner columns were far under their punching and P-M checks
  because sizing only grew. The smallest section that passes is the section to install.
---
A flat-plate column is the lightest catalog section that passes full-load strength, the ACI 318-11 §10.12 joint sections, and punching (`check_punching_for_column` at the trial plan size, using the shear and unbalanced moment already stored). Plan sizes are binary-searched. A failing size ends the search: the stored demand does not get heavier as the section gets smaller, so a smaller size would fail it too. The frame is solved again after a change. If that slab analysis grows a column, the grown plan size is a floor and the search does not go under it.

A lower column is not required to be at least as large as the column above it. That stack comparison is no longer a design diagnostic. `uniform_column_sizing` other than `:off` does not shrink; harmonize still matches the group.

`core/test_flat_plate_member_stage.jl` passed 299/299. The saved core-office scene still has the previous 30 in corners; only a new design run installs the searched sections.
