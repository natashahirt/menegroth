---
id: chec-59d11ef6
type: checkpoint
project: menegroth
parent_id: deci-5da95787
title: Asap rigid-link solve accepts a story geometric stiffness
node_label: Asap rigid-link solve accepts a story geometric st
tags: ''
status: active
open_threads: 0
success: 'null'
files: external/Asap@b1c7432
session_id: sess-d72d7591
created_at: '2026-10-30T19:57:35.565763+00:00'
updated_at: '2026-10-30T19:57:35.565763+00:00'
---
Committed in the Asap submodule as b4b16ab (Solve rigid-link models on an added story geometric stiffness). `solve(model, cases, links; geometric_stiffness=K_G)` adds a signed story matrix before the rigid-floor reduction and refuses terms on tied slave DOFs. The rigid-link tests, including the 1/(1-θ) sway and twist check, are in that commit. The parent records the submodule pointer. Synthesizer story_pdelta.jl was already pinned at 8e79a9d3. Steps 3 and 4 (per-combination K_G, story-cut fictitious shears, wall-stage wiring) are not in this commit.
