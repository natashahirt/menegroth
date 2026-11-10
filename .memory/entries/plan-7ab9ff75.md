---
id: plan-7ab9ff75
type: plan
project: menegroth
parent_id: menegroth
title: Orient seat eccentricity so local y means up
node_label: Orient up eccentricity
tags: asap,eccentricity,sign,joist-seat,safety
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-679f45f9
created_at: '2026-11-10T20:35:01.568550+00:00'
updated_at: '2026-11-10T20:35:01.568550+00:00'
---
Option A only. Do not change Asap eccentricity into global coordinates.

Add `orient_up_eccentricity(ecc, nodeStart, nodeEnd; roll=π/2)`. Slot 3 (`e_f2`) is local y, from `eccentricity_transformation!` (θ × e with e = (e_f1, e_f2, e_f3)). Callers pass a physical offset where positive slot 3 is global up. The helper multiplies that slot by sign(local_y · global Z), using `lcs` of the chord at the element roll, before `process!`. A near-zero dot (vertical member) leaves slot 3 unchanged and does not throw.

Apply at the element write sites that have the two nodes and the roll: model_builder (after column roll), model_sync, visualization_model (after copying Ψ), and story_shell `_set_story_beams!`. Do not flip inside `default_seat_eccentricity`. Do not edit subdivision.jl, StructuralSizer/src/slabs/**, or the axial/foundation files already fixed. Do not commit.
