---
id: note-335a8cee
type: note
project: menegroth
parent_id: note-7de9d402
title: 'OPEN DESIGN Q: edge-column punching uses governing max(|Mux|,|Muy|), not additive
  biaxial — less conservative'
node_label: 'OPEN DESIGN Q: edge-column punching uses governing'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/codes/aci/punching.jl@8484f17, StructuralSizer/test/slabs/test_corner_punching.jl@8b97d6d
session_id: sess-c53f8d5d
created_at: '2026-10-22T16:12:10.828078+00:00'
updated_at: '2026-10-22T16:12:10.828078+00:00'
---
During the pre-ribbed run's explore pass (run-9091881e), confirmed the Defect 4 biaxial punching fix is already implemented in HEAD (a2469fcd). In the process, surfaced a genuine ACI 318-11 ambiguity worth a user decision:

In StructuralSizer/src/codes/aci/punching.jl `punching_check` (edge branch ~lines 578-589, with _orient_edge_column/_governing_edge_moment ~lines 410-428): for EDGE columns the two unbalanced moments are collapsed to the GOVERNING moment M_edge = max(|Mux|,|Muy|) applied on the 3-sided critical section, Muy then zeroed. Interior and corner branches, by contrast, ADD both axes (vu = v_direct + gamma_v,x term + gamma_v,y term).

WHY IT MATTERS: additive biaxial would give a HIGHER vu than governing-max, so the edge treatment is LESS conservative. ACI 318-11 §11.11.7 does not explicitly rank/sum the two unbalanced moments at an edge column, so the current choice is flagged in-code as ENGINEERING JUDGMENT (not a code citation), and test_corner_punching.jl's edge testset ASSERTS the governing-max behavior (r_new ~= Muy-only). So the code is self-consistent and test-sanctioned — but if the intended spec is additive biaxial at edges (more conservative), that is a safety-relevant change to both the code and the edge oracle, and must be decided by the user, not an agent (per code-accuracy.mdc). Pre-existing; not introduced by this run.
