---
id: deci-95eba26f
type: decision
project: menegroth
parent_id: plan-3c17cdf6
title: Rigid wind rebuild stores centroids; NLP floors will be the Row F demand rows
node_label: Rigid centroids, NLP rows
tags: row-f,wind,centroids,nlp,section-floors,beams,columns
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-74c6c0a8
created_at: '2026-11-11T17:26:09.142513+00:00'
updated_at: '2026-11-11T17:26:09.142513+00:00'
has_child_rationale: User confirmed the rigid-path fix first, then NLP floors as stored
  demand rows and full per-case beam shear.
---
Confirmed 2026-11-11. Do the rigid path on row-f-land, then the NLP work on a new branch.

Rigid path, in the Row F worktree only. WindStoryAnalysis gains displacements and centroids, matching the other session's struct, plus the two-argument constructor that leaves both empty. wind_story_analysis stores each level's first-resultant centroid and the solved displacements. A six-argument _wind_loads accepts the structure and the centroids and places the force and the already-transferred moment on the rigid master. It does not use the centroid to move the moment, and it throws when asap_rigid_links is empty. The four-argument master placement is unchanged. This does not bring over the flexible or semirigid story-load rewrite.

NLP, after that commit. A Row F floor stores the demand rows the frame check already builds (RCColumnDemand and RCBeamDemand), not just the catalog section. Column NLP appends those rows as extra cases. Magnification must stay off on them, because the Row F forces already include story P-delta; confirm that before writing the constraint. Beam NLP gets one shear (and torsion) row per load case, and the Row F beam rows join those cases. Flexure keeps the positive and negative moment envelopes. After rounding, the section is checked against the stored rows and an infeasible floored group throws. The user chose the demand rows over lower bounds on b, h, and rho, and chose full per-case beam shear over an interim Nu = 0 compression fix.

Open when the NLP branch starts: whether the column NLP's slenderness magnification can be turned off per case, and that a group's stored rows are the union of its members' rows.
