---
id: note-bc0b3d32
type: note
project: menegroth
parent_id: plan-9768ec38
title: Pierced walls are checked as segments
node_label: Opening segment checks
tags: walls,openings,aci-318-19
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-98b6ac67
created_at: '2026-11-06T03:48:11.099675+00:00'
updated_at: '2026-11-06T03:48:11.099675+00:00'
---
A wall with openings is no longer refused by the ordinary-wall stage. Solid walls stay on the gross-pier check. Vertical segments use check_pier_segment on the same strength combinations. A column segment (length/thickness ≤ 3) is checked only when its end moments satisfy ACI 318-19 §6.6.4.3(a) (aci-318-19, PDF p. 81): the second-order moment is not more than 5% above the first-order moment, with a 1 N·m noise floor, in plane and out of plane. Then k = 1.0 (§6.6.4.4.3, PDF p. 81) and M1/M2 uses the §6.2.5.1 sign (PDF p. 70): same pier-base sign is single curvature (negative). Clear cover is 1½ in, Table 20.5.1.3.1 column row, not exposed (PDF p. 384). If the story stiffness was not built, or the 5% test fails, the column check is a recorded failure and is not run. A :wall segment uses the ordinary-wall check, including the slab out-of-plane moment scaled by segment length. Horizontal segments are recorded unchecked (ACI 318-19 §9.9) and are not passed. Struts and the flexible diaphragm are unchanged. Tests: StructuralSynthesizer analyze/test_wall_pier_checks.jl and analyze/test_wall_openings.jl, 177/177, log logs/test_StructuralSynthesizer_20261105_223507.log.
