---
id: note-a73ae662
type: note
project: menegroth
parent_id: chec-90775d0b
title: Steel section-floor test was pre-existing red on integration (stiffness-staleness
  error); merge fixed it; assertion corrected to shape+objective
node_label: section-floor test fix
tags: test,section_floor,steel,merge,rib,_sections_identical
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-31f93de7
created_at: '2026-11-19T22:30:02.994671+00:00'
updated_at: '2026-11-19T22:30:02.994671+00:00'
---
While verifying the row-f-nlp merge, the targeted run showed 4 failures in 'Steel columns keep a section floor' (test_section_floor.jl:112). Investigated rather than assumed:

1. Pre-merge integration logs (test_StructuralSynthesizer_20261119_133827.log etc.) show this testset was ALREADY RED on integration: 'Error During Test ... ArgumentError: member demands: N frame elements carry stiffness from an earlier section. Rebuild the model (update_analysis!(struc,:stiffness)) before reading forces.' i.e. the rib session committed it erroring (1 error). NOT a merge regression.
2. My merge (restoring Row F end moments alongside section_floor) actually IMPROVED it: the stiffness-staleness error is gone, the feature runs, and a diagnostic (scripts/runners/diag_steel_section_floor.jl, since deleted) showed the floor is RESPECTED EXACTLY: free=W6X8.5, floor=W8X10, selected=W8X10, identical objective, for all 4 groups.
3. Root cause of the 4 assertion fails: _sections_identical (size_beams.jl:1397) compares ALL fields incl. material; catalog floor templates carry material=nothing while any sized/installed section carries a populated StructuralSteel, so _field_identical mismatches on material for the same W-shape regardless of correctness.

Fix: test_section_floor.jl 'Steel columns keep a section floor' loop now asserts the real invariant (floor respected = never sized below it): installed.name == floor.name AND _section_objective(installed) >= _section_objective(floor)*(1-1e-9), with a comment on the catalog-template material caveat. Verified: 38/38 pass.

This is the rib session's feature/test; flag for their awareness. The merged size_columns steel path now applies BOTH AISC App.8 end moments and the section-floor catalog narrowing.
