---
id: deci-563ebb36
type: decision
project: menegroth
parent_id: plan-d3b886cf
title: 'Cracked service shell scales ratchet: a cracked plate stays cracked within
  a load level'
node_label: 'Cracked service shell scales ratchet: a cracked pl'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/slabs/slabs/story_shell_service.jl@33f9794,
  StructuralSynthesizer/test/analyze/test_story_shell_beams.jl@33f9794, scripts/runners/diag_shell_service_settle.jl@33f9794
session_id: sess-95378989
created_at: '2026-11-05T00:06:36.736201+00:00'
updated_at: '2026-11-05T00:06:36.736201+00:00'
---
Finding (2x2 steel office, 40 ft bays): the service shell never settled because of a period-2 flip at 4 plates around the center column (ends of beams 15/16). The gross dead+live solve cracked them (k about 0.65); the softened re-solve shed enough moment that they read uncracked (k=1); the next solve cracked them again, until the 6-iteration cap. Live-load spans came from whichever half of the flip came last.

Decision (user-selected): `_ratchet_scales(k, reading) = min.(k, reading)` for both plate and frame scales, so within one service level a scale only goes down. Flagged as engineering judgment: ACI 318-11 defines Ma as the maximum service moment at the stage deflection is computed (notation, aci-318-11 p.27) and is silent on before or after redistribution. Result: the same floor settles in 2 iterations with the 4 plates held cracked. Tests: test_story_shell_beams.jl 153/153. Diagnostic: scripts/runners/diag_shell_service_settle.jl.
