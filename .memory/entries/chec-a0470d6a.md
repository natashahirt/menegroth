---
id: chec-a0470d6a
type: checkpoint
project: menegroth
parent_id: deci-d1850cbb
title: Composite Phase 6b committed (47f988f7)
node_label: Phase 6b committed
tags: composite,phase-6,checkpoint
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-17184d82
created_at: '2026-10-27T15:16:43.267273+00:00'
updated_at: '2026-10-27T15:16:43.267273+00:00'
---
Commit 47f988f7: Vulcraft composite deck geometry (1.5VL, 2VLI, 3VLI and side-lap aliases) and DeckAttachment. Pattern defaults to 36/4. Side-lap count and diaphragm strength are optional and unset. Vbr is reported beside them and not compared. 11 files. b5deaff1 removes a doubled carriage return on the stud export line introduced while staging. Left unstaged: vertical_seismic_load_effect export in StructuralSizer.jl. Tests: StructuralSizer test_composite_beam.jl 258/258. StructuralSynthesizer composite-context tests were not re-run. Memory decision: deci-d1850cbb (auto-committed as 9e5205c5). Next planned composite phase is Phase 9 in deci-3a2bf98e: snap a continuous section to the catalog, then run the discrete checker. Plate girders stay out.
