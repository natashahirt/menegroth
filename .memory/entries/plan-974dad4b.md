---
id: plan-974dad4b
type: plan
project: menegroth
parent_id: plan-92558dc9
title: Reconcile the story shell with the sections the frame kept
node_label: Close shell on frame sections
tags: story-shell,check-settle,one-way-joists
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/workflow/member_iteration.jl@5102047, StructuralSynthesizer/src/workflow/check_settle.jl@5102047
session_id: sess-17b0aa64
created_at: '2026-11-17T03:11:25.167429+00:00'
updated_at: '2026-11-17T03:11:25.167429+00:00'
---
After the first story-shell round, do not free-pick every beam again. Solve the shell once on the sections the frame left, check beams against that shell (enveloped with the frame and the pinned joists) and columns against the frame. Keep any group that passes. Resize only groups that fail, then re-solve and re-check, a few times, and stop if a section vector repeats. Accept the round when the shell of these sections and the frame of these sections both pass. The 10-pass free shell stays the first round, so steel ratchet tests are unchanged.
