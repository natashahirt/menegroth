---
id: expe-f8742a3d
type: experiment
project: menegroth
parent_id: expe-007fc1db
title: '12 m dense-waffle: Beam 138''s 1.51 was a stale bare-rib check on a solid-head
  piece; cleared it'
node_label: '12 m dense-waffle: Beam 138''s 1.51 was a stale bar'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/framing/solid_head_split.jl@813b516
session_id: sess-5fbc0023
created_at: '2026-11-21T04:09:04.899635+00:00'
updated_at: '2026-11-21T04:09:04.899635+00:00'
---
Diagnosis (grid/x1y1, 30-in dense waffle). The reported critical "Beam 138 is_feasible = 1.514" was NOT a real overstress. Probe (scripts/runners/sdf_beam138_probe.jl) showed B-138 = el 192, a 0.71 m (2.34 ft) piece from (12.0,10.6)->(12.71,10.6), claimed into the solid head of column (12.0,10.0): role=solid-head, group_id=level.solid_group_id. Its end node frames into other solid-head pieces; its start node into the first bare ribs outside the head (which pass hogging at 0.79 under pattern loading). The 504 kip*ft in the stale check is the pattern-enveloped support hogging (254 is the single full-load case my probe first read from model.u).

Root cause: assign_solid_head_sections! sets the gross-rectangle solid section on the piece's FE *elements* but never updates the *member*, so section(beam) kept the thin rib (T8x29-bf14-3#8) and member_check(beam) kept returning the stale failing bare-rib verdict. member_check auto-invalidates when c.section !== section(m), but the member section field only accepts StructuralSizer section types (Asap.Section is NOT <: that AbstractSection -> set_section! with the solid Asap.Section throws a convert MethodError), so swapping the member section is not viable.

Fix (StructuralSynthesizer/src/analyze/framing/solid_head_split.jl, in assign_solid_head_sections!): when a piece is claimed into the head, clear its cached check: struc.beams[bi].base.check = nothing. The head's own punching/one-way/hogging checks govern a solid-head piece. Carbon is untouched (volumes is stored on m.base.volumes, not derived from the section). 194/194 targeted solid-head tests pass (solid_head_story + solid_head_check + arrangement_heads).

Result after re-run (logs/sdf_rib_design/grid_x1y1_qualification/dense_waffle.txt): critical dropped from Beam 138 (1.514) to the non-convergence sentinel. ALL 1623 beams now pass their actual checks: max FlxRat = 0.999 (B-1264), max ShrRat = 0.832 (B-8); deflection ok, long-term 0.97; heads punching 0.36 / hogging 0.79. EC intensity 225.2 kgCO2e/m^2. So the 12 m bay DOES span with the catalogue.

REMAINING (pre-existing, not caused by this fix): pass=false because the member loop does not register convergence within max_iterations -> stage_diagnostics[:members] set -> every beam marked ok=false and the summary floors the fail ratio to 1.0 (summary.jl:150 r_fail = r<1.0 ? 1.0 : r), reported as "Beam 1144 (flexure) ratio=1.0" (actual FlxRat 0.823). Same all-beams-marked-fail pattern existed in the prior 1.514 run (e.g. B-122 at 0.067 was already shown as failing). Likely section hunting at the margin (max flex 0.999). Fixing a clean pass=true needs convergence stabilization (hysteresis / raise max_iterations / accept near-converged), tracked separately.
