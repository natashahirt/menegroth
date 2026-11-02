---
id: deci-ee890c91
type: decision
project: menegroth
parent_id: plan-cb717409
title: How the 12.2.5.8 interactive-system checks and the A.3/B.6 gate work
node_label: How the 12.2.5.8 interactive-system checks and the
tags: walls,phase-7,12.2.5.8,seismic-system,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-8c698d00
created_at: '2026-11-02T16:11:18.217640+00:00'
updated_at: '2026-11-02T16:11:18.217640+00:00'
---
User choices (2026-11-02):
- 75% check: sum the design strength (phi Vn) of the walls in each story and direction. Compare with the design story shear Vx.
- Design story shear: strength-level ELF Vx times the story's 1/(1-theta) factor (ASCE 7-22 12.8.7, PDF p. 188: P-delta effects on story shears must be considered where theta > 0.10). The frame-only check uses its own theta and is refused if theta > theta_max.
- If the walls fall short of 75%: raise rho_t along the existing grid, and record a failure if the shear cap blocks it.
- 25% check: a frame-only model (no wall shells) under 0.25 x the ELF story forces, including the accidental-torsion cases, combined with gravity through 2.3.6 combinations 6 and 7. Check the existing beams and columns with the ACI checkers. Flat plates are refused for now because no slab-column frame is modeled.
- A.3/B.6: the caller states the row. The stage measures and reports the wall share of each story's vertical load, and refuses B.6 above 20%. The 20% is a project judgment, not a code number; annotate it as such (C12.2.1, PDF p. 708: 'a relatively small percentage').
