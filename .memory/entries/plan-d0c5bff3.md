---
id: plan-d0c5bff3
type: plan
project: menegroth
parent_id: todo-6a3aad1a
title: 'Phase 5 layout: four runs from frame placeholders to one frame-shell model'
node_label: 'Phase 5 layout: four runs from frame placeholders '
tags: walls,phase5,unified-model,asap,plan
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a42c0dff
created_at: '2026-10-22T18:55:00.368643+00:00'
updated_at: '2026-10-22T18:55:00.368643+00:00'
---
Layout for todo-6a3aad1a. Four small runs, in order. Do not start 5b until 5a passes. No new ACI or ASCE factors (Phase 2 is still open). No wind or seismic magnitudes (Phase 6). No wall sizing (Phase 7). No openings or coupling beams (Phase 8). The Phase 4 stub keeps throwing until a later slice calls it on purpose.

Current code: to_asap! in StructuralSynthesizer/src/analyze/asap/utils.jl builds one Asap.Element for every skeleton edge, including :walls, with a placeholder section and :fixedfixed release. Diaphragms are either slab shells or rigid links, and only when slabs exist. The isolated wall model is FEMLateralEvaluator in StructuralSizer/src/walls/fem_evaluator.jl: ShellTri3 panels, nodes shared by rounding coordinates to 1 mm, base nodes fixed, one stiff diaphragm per floor. A core corner is continuous only in that isolated model.

5a — no double-counting. A :walls edge must not also be a frame element. Omit those edges from the frame map. A building with an empty :walls group must stay bit-identical to today, including gravity results. This run does not mesh shells yet. Gate: an existing gravity fixture with no walls is unchanged.

5b — wall shells in the same model. Mesh each Wall with the Phase 3 geometry (plan endpoints, thickness, pier height to the next faced story). Share nodes at 1 mm so a core corner is one node. Fix the base. Join wall nodes to the story diaphragm that already exists (rigid links or slab shells). Do not build a second diaphragm. Self-weight is counted once. Fail if the assembled stiffness is not positive definite. Gate: the same gravity-only building is still unchanged, and a small core model assembles and solves.

5c — equivalence. One four-wall, two-story symmetric core, same geometry in FEMLateralEvaluator and in the building model. Compare interstory drift and per-wall shear. State the tolerance before looking at the numbers. The isolated evaluator stays. Per-wall force recovery (membrane Nxy versus base reactions, and gravity-frame contamination) is the known open risk; if the two models disagree, stop and report, do not retune the tolerance.

5d — solve split. Separate topology construction from numeric updates and from load solves. Batch linear cases as multiple right-hand sides on one factorization (Asap.solve(model, cases)). P-delta and accidental torsion are their own solves, not a loads_only reuse. loads_only may be passed only when _loads_only_sync reports the stiffness token unchanged, and that token must include wall E, thickness, and eccentricity. Name that guard next to the Phase 4 primitive string.

Each run: low rigor, one engineer then one critic, one fix cycle only for a P0. Worst case four spawns per run. Inherit the parent model. Do not commit unless asked.
