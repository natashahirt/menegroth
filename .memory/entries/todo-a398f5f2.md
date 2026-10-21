---
id: todo-a398f5f2
type: todo
project: menegroth
parent_id: plan-a2a6128f
title: Phase 6 — ASCE 7-22 lateral demand
node_label: 'P6: ASCE demand'
tags: walls,phase,asce,wind,seismic,loads,todo
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-388b4911
created_at: '2026-10-21T02:13:11.211297+00:00'
updated_at: '2026-10-21T02:13:11.211297+00:00'
---
Wind + ELF seismic demand under StructuralSizer/src/loads/ and a new StructuralSynthesizer/src/analyze/lateral/; directional story loads + strength/service combos + accidental torsion + drift. Fail explicit on missing site/seismic inputs (no inferred risk category, coefficients, R, or wind params). Published known-answer tests for base shear, vertical distribution, wind story force, torsion, drift BEFORE wiring to checks. Note the seismic-mass->sizing->mass coupling loop.
