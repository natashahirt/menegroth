---
id: chec-03c4c9d2
type: checkpoint
project: menegroth
parent_id: plan-882e912b
title: Floor concrete and opening-edge stress are on the decision
node_label: floor concrete and opening edges
tags: special-walls,aci-318,18.10.6.4,18.10.6.3
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-db6c4a6c
created_at: '2026-11-11T17:37:18.355655+00:00'
updated_at: '2026-11-11T17:37:18.355655+00:00'
---
Two more clauses are on the pier decision. Ordinary rows are unchanged.

§18.10.6.4(h) (corpus: aci-318-19, page 328): when an element is required and params.floor states a concrete strength, the decision records whether that strength is at least 0.7 f′c of the wall. Equality meets it. A design that does not state a floor strength records nothing; resolve_floor_options is not used, because it would substitute a flat plate. A floor below 0.7 fails the check and does not move the fiber stress, c, or the thickness shortfall. The check is not run when no element is required.

§18.10.6.3 edges around openings: each vertical segment of a pierced wall on A1 or B4 gets its own stress decision. The section is that segment's rectangle, so a flange on the gross wall is not used. hu is the segment height. Continuity still comes from the wall line, so an opening keeps the line off §18.10.6.2. The decisions are on OrdinaryWallResult.opening_edges. The largest web shortfall among them thickens that wall only.

Tests: analyze/test_wall_thickness_jump.jl 314/314, logs/test_StructuralSynthesizer_20261111_122935.log. analyze/test_special_boundary_stage.jl 108/108, logs/test_StructuralSynthesizer_20261111_123034.log. Halving the section length doubles the fiber stress. A segment of a flanged wall is not flanged and has the higher rectangular stress. Raising hu moves only the shortfall.

Still ahead on plan-882e912b: the §18.10.6.4(k) end gap from the placed bars, decoding §18.10.2.3 from the rendered page before §18.10.6.4(j), the displacement route (deci-629eec79), and boundary bars (deci-3aa2a20b).
