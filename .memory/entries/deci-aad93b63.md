---
id: deci-aad93b63
type: decision
project: menegroth
parent_id: expe-f8742a3d
title: 12 m dense-waffle non-convergence was max_iterations=4; raised to 12 -> all_checks_pass=true
node_label: 12 m dense-waffle non-convergence was max_iteratio
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/sdf_rib_design.jl@de4113c
session_id: sess-9f91bcb7
created_at: '2026-11-21T06:03:40.963150+00:00'
updated_at: '2026-11-21T06:03:40.963150+00:00'
---
After the Beam-138 stale-check fix, grid/x1y1 dense_waffle still reported pass=false. Root cause is NOT a strength/serviceability failure and NOT a limit cycle: the member loop just ran out of iterations.

Diagnostic (scripts/runners/sdf_dense_waffle_converge_diag.jl, run with SS_TRACE_SHELL_PASSES=1 and max_iterations=12) showed the coupled columns<->ribs<->growing-solid-head system converges to a fixed point, but needs ~9 passes per screen round: beam section flips per pass decayed 764 -> 318 -> 130 -> 59 -> ... -> 0 by about pass 9, with no flips at pass 9+. The qualification runner (scripts/runners/sdf_rib_design.jl rib_parameters) capped params.max_iterations = 4 (production DesignParameters default is 20). With only 4 passes _iterate_beams_columns! hit max_iter without `held`, set stage_diagnostics[:members], marked every beam ok=false, and the summary floored the fail ratio to 1.0 (summary.jl:150) -> spurious 'Beam 1144 (flexure) 1.0'. _check_settle! never helped: it only runs on an exact state repeat within the <=4-pass history, and it bails for option sets not checked section-by-section.

Result at max_iterations=12: all_checks_pass = true; stage_diagnostics[:members] cleared (converged); worst element Column 3 (column_shear) at exactly 1.0 = passing/at-capacity. All 1623 beams pass (max FlxRat 0.999, max ShrRat 0.832), deflection long-term 0.97, heads punching 0.36 / hogging 0.79, EC intensity 225.2 kgCO2e/m^2.

Fix: rib_parameters sets params.max_iterations = 12 (comment explains the slow coupled settle; 12 has margin over the observed ~9). This is a test-harness/runner setting; production (20) already converges. The dense_waffle job inherits it (it only overrides module_spacing + name). The diagnostic ran the identical configuration, so it doubles as validation. NOTE: the steel-joist job in the same file still sets max_iterations = 4 separately (left as-is; out of scope for the waffle question).

Bottom line for the user's requirement: a 12 m bay DOES span with the catalogue and the design now passes cleanly.
