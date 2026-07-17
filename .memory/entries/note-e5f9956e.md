---
id: note-e5f9956e
type: note
project: menegroth
parent_id: deci-07d12e0e
title: 'Fresh baseline: DDM(Full)=85.0s, FEA(frame)=262.4s (peer-Cursor Asap edits
  still in tree)'
node_label: 'Fresh baseline: DDM(Full)=85.0s, FEA(frame)=262.4s'
tags: wave-2, baseline, external-asap-drift, joists-plan, note
status: active
open_threads: 0
success: 'null'
files: StructuralStudies/src/flat_plate_methods/results/speedup_baseline/baseline.csv@91f7e1d,
  logs/wave2_rebaseline.log@4214c7e
session_id: sess-37aa88cc
created_at: '2026-07-17T18:50:59.550310+00:00'
updated_at: '2026-07-17T18:50:59.550310+00:00'
---
Wave 2's rebaseline task ran the harness for 10:29 min against the current working tree (external/Asap has 73 uncommitted files from the joists-plan peer-Cursor session including K.jl/R.jl/force_displacement.jl). The regenerated baseline.csv is the invariant floor for future waves.

BASELINE (2026-07-17, StructuralStudies/src/flat_plate_methods/results/speedup_baseline/baseline.csv):
  DDM (Full)   — 85.0 s — h=12.5 in, punch_ratio=0.955, defl_ratio=0.044
  FEA (frame)  — 262.4 s — h=15.5 in, punch_ratio=0.997, defl_ratio=0.047

FEA(frame) dropped from Wave 1B's 544 s to 262 s. Not investigated in depth; hypothesized split: (a) real Asap improvements from peer-Cursor edits to Elements/K.jl (stiffness matrix assembly) and Analysis/force_displacement.jl, (b) warm-cache/JIT effect from repeated harness runs today. Any future wave measuring speedup MUST use THIS baseline, not the Wave 1B one.

PRECONDITION FOR FUTURE WAVES: The external/Asap dirty state (73 uncommitted files) should be resolved — either committed by the joists-plan owner or stashed — before running a rebaseline that expects a stable Asap SHA. Otherwise every future rebaseline potentially captures a different Asap state.
