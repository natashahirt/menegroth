---
id: chec-63a9c0fb
type: checkpoint
project: menegroth
parent_id: plan-6fa91d7d
title: 'Phase 7 demand slice: extra wind directions, combination factors, seismic
  drift check'
node_label: P7 demand slice
tags: walls,phase-7,wind,drift,combinations,checkpoint
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/loads/wind.jl@49480a5, StructuralSizer/src/loads/seismic.jl@49480a5,
  StructuralSizer/src/loads/combinations.jl@49480a5, StructuralSizer/src/StructuralSizer.jl@49480a5,
  StructuralSizer/test/loads/test_wind_chapter27.jl@49480a5, StructuralSizer/test/loads/test_seismic_elf.jl@49480a5,
  StructuralSynthesizer/src/analyze/lateral/wind_story_cases.jl@49480a5, StructuralSynthesizer/src/analyze/lateral/story_demands.jl@49480a5,
  StructuralSynthesizer/src/analyze/_analyze.jl@49480a5, StructuralSynthesizer/src/StructuralSynthesizer.jl@49480a5,
  StructuralSynthesizer/test/analyze/test_wind_story_cases.jl@49480a5, StructuralSynthesizer/test/analyze/test_elf_story_cases.jl@49480a5
session_id: sess-e35a9db8
created_at: '2026-10-26T17:49:57.025630+00:00'
updated_at: '2026-10-26T17:49:57.025630+00:00'
---
Phase 7's demand slice is in place, before any wall sizing.

Extra wind directions: the two Figure 27.3-8 principal axes stay perpendicular unless `perpendicular=false`. A repeated or opposite principal pair still throws. `extra_directions` adds Case 1, both signs of Case 2, and a §27.1.5 minimum for each added direction, including the opposite of a principal axis. Those directions are not folded into Cases 3 and 4.

Strength combinations scale the story forces that already exist. Wind cases use the combination's W factor (§2.3.1 4a and 5a, PDF page 68). Strength ELF cases use the E factor (§2.3.6, PDF page 69). Drift ELF cases are not scaled into a strength combination. Gravity factors are not applied to these forces.

Seismic design story drift is compared with Table 12.12-1 through `story_drift_is_allowed`. The comparison uses the magnitude of the signed center-of-mass drift. Wind interstory master displacement is reported and is not judged against that table.

The existing seismic combination constants still carry a single E and a 0.2 snow companion. §2.3.6 writes `1.2D + Ev + Eh + L + 0.15S` and `0.9D − Ev + Eh`. Those constants were not changed.

Tests: StructuralSizer wind 123, seismic ELF 91; StructuralSynthesizer wind story 73, ELF story 51.

Not in this slice: per-wall force recovery from the unified shell model, and the ordinary-wall stage in `design_building`.
