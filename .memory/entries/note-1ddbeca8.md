---
id: note-1ddbeca8
type: note
project: menegroth
parent_id: deci-f691b344
title: Accepted residual P2s after endpoint-aware enclosure fix
node_label: Residual P2s (accepted)
tags: walls, enclosure, crit7, residual, FEM-survivor
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/lateral_evaluator.jl@2de0398, StructuralSizer/test/walls/test_walls.jl@2de0398
session_id: sess-685c1d79
created_at: '2026-10-22T15:11:51.470017+00:00'
updated_at: '2026-10-22T15:11:51.470017+00:00'
---
Residuals the critic flagged that are ACCEPTABLE with no further fix:

(a) **Endpoint-test origin-variance** is self-documented and fails in the SAFE/closed direction -- it bites only at |coord|/plate ~ 4e6.

(b) **Degenerate-axis angled-wall x-overhang on a thin plate** is the pre-existing crit7 walls-subset-plate-subset-occupants residual. It is STRICTLY NOT NEW: the old baseline was centroid-only and the fix is a pure tightening. Delegated to the Phase-10 FEM survivor.

(c) The focused **thin-plate regression unit test** the critic recommended was ALREADY added (crit8 E6, a solver-free per-axis thin-plate regression testset).
