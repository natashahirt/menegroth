---
id: deci-d8524cd1
type: decision
project: menegroth
parent_id: deci-25a744e3
title: 'Composite steel beams on the story shell: per-combination strength fields
  and per-station I_LB with no slab subtraction'
node_label: composite on story shell
tags: story-shell,composite,AISC-I3,I8.2c,I_LB,stiffness
status: active
open_threads: 2
success: 'null'
files: StructuralSizer/src/members/codes/aisc/composite/per_station.jl@b3090e3, StructuralSizer/src/members/codes/aisc/checker/composite_feasibility.jl@b3090e3,
  StructuralSizer/src/members/codes/aisc/checker/explanations.jl@b3090e3, StructuralSizer/src/slabs/codes/concrete/panel_shell_beams.jl@b3090e3,
  StructuralSynthesizer/src/analyze/slabs/slabs/story_shell_beams.jl@b3090e3, StructuralSynthesizer/src/analyze/slabs/slabs/story_shell.jl@59e0a7a,
  StructuralSynthesizer/src/analyze/members/composite/stiffness.jl@b3090e3, StructuralSynthesizer/src/analyze/members/composite/subdivision.jl@b3090e3,
  StructuralSynthesizer/src/analyze/members/composite/payloads.jl@b3090e3, StructuralSynthesizer/src/analyze/members/members/size_beams.jl@b3090e3,
  StructuralSynthesizer/src/analyze/members/members/size_beams_story_shell.jl@b3090e3,
  StructuralSynthesizer/test/analyze/test_story_shell_beams.jl@b3090e3
session_id: sess-86fd7170
created_at: '2026-11-03T23:47:10.234954+00:00'
updated_at: '2026-11-04T23:27:53.043976+00:00'
---
Composite steel beams now run through size_beams_with_story_shell!.

**Demand.** Each story-shell beam keeps one ShellMomentField per load combination (StoryLoadCases), oriented to the beam_signed_moment_field origin. They enter PerStationComposite as `strength_fields` (new field in StructuralSizer): every sagging region is checked with _region_strength (strength + anchors on that case's own zeros, AISC 360-22 §I8.2c / C-I3-1). No service, construction, or hogging check on them; they never set analysis stiffness, so `fields[bi]` indexing in the install/refresh code is untouched. Per-combination rather than an envelope, because an envelope widens the sagging regions, lengthens the shear spans, and under-designs anchors. One uniform stud layout at the tightest spacing satisfies every case.

**Stiffness.** _write_beam_composite_ix! records a stiffness profile (regions, ΣQn per region, section, slab, origin) per beam. analyze_story_shell gives each composite piece composite_inertia_at_station via section_at: I_LB in sagging regions, cracked I_neg in hogging regions. NO subtraction of b_eff t^3/(12n): Eq. C-I3-1 (aisc-360-22 PDF p. 501) carries the concrete only as the force ΣQn/Fy at its centroid, with no slab self-bending, so the shell's own slab bending adds without overlap. With no studs this gives the bare steel beside the slab. The old composite_beam_inertia subtraction was inconsistent (its docstring said C-I3-1 omits the term and then subtracted it) and was removed along with the constant I_service path of shell_beam_properties and analyze_story_shell's composite_service kwarg. Judgment: over hogging regions the shell slab is gross, so it is slightly stiff there.
