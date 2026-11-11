---
id: chec-8ae5b8ac
type: checkpoint
project: menegroth
parent_id: plan-3c17cdf6
title: Row F landed on row-f-land from the worktree
node_label: Row F commit
tags: row-f,commit,worktree,wind,centroids,nlp
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-4b0ac35c
created_at: '2026-11-11T18:29:46.597998+00:00'
updated_at: '2026-11-11T18:29:46.597998+00:00'
has_child_rationale: The rigid-path rebuild and the Row F suites passed, so the worktree
  commit can land.
---
Committed on branch row-f-land from /tmp/menegroth-rowf. The main checkout was left untouched.

What the commit contains. Frame members report a governing check and ratio. A failing group gets a section floor from that level's beam options, or from the whole uniformity group. Discrete concrete sizing stays at or above the floor. Concrete column NLP constrains every load case. WindStoryAnalysis stores each level's outline centroid and the solved displacements. The six-argument wind load and the three-argument seismic effect load place those forces on the rigid masters and throw when there are no rigid links. Bearing checks use the slab moment as eccentricity; outside the middle third the simplified method records a failure (ACI 318-19 §11.5.3.1, corpus aci-318-19, PDF page 170). self_weight_area is the member area that is not already in the slab.

Asap is pinned to 48e3fcd, which is origin/main. The previous pin, 2033e458, includes Elements/parametricelements.jl and does not contain that file, so the package does not load.

Tests on that pin: wind story cases 76/76, frame section floors 148/148, Row F resize 35/35. The column NLP adapter was 130/130 earlier on this worktree and was not re-run after the self-weight area helper.

Left out: the scene module, and the other session's uncommitted split of the NLP files. NLP floors as stored demand rows, and per-case beam shear, stay on todo-8e6b87f4 for a later branch. Decision deci-95eba26f.
