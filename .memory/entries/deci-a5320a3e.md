---
id: deci-a5320a3e
type: decision
project: menegroth
parent_id: deci-25a744e3
title: Rectangular concrete beams ratchet up after the story shell settles
node_label: Rectangular concrete beams ratchet up after the st
tags: story-shell,beams,section-floor,convergence
status: active
open_threads: 1
success: 'null'
files: StructuralSynthesizer/src/analyze/members/members/size_beams.jl@9ef3863, StructuralSynthesizer/src/analyze/members/members/size_beams_story_shell.jl@9ef3863,
  StructuralSynthesizer/src/workflow/member_iteration.jl@e61b36c, StructuralSizer/src/members/optimize/api/beams.jl@9ef3863
session_id: sess-6735df56
created_at: '2026-11-13T21:25:20.152502+00:00'
updated_at: '2026-11-13T21:53:48.699529+00:00'
---
After the story shell settles, a rectangular concrete beam group keeps its section or takes a strictly heavier one, the same rule discrete steel beams already use. The frame loop was re-solving and taking max(frame, shell), so a beam could trade back to a lighter section and the three shell rounds never closed. T-beams, NLP, a shared-section cap, and a multi-material catalog stay free. A named catalog still grows one tier when nothing at or above the floor passes. Columns are not ratcheted.
