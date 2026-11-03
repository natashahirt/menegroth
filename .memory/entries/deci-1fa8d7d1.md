---
id: deci-1fa8d7d1
type: decision
project: menegroth
parent_id: menegroth
title: 'Story shell: each part designs for its own shell forces (no slab moment on
  the beam)'
node_label: 'Story shell: each part designs for its own shell f'
tags: story-shell,beams,demand-envelope
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7eb56c20
created_at: '2026-11-03T22:43:06.653038+00:00'
updated_at: '2026-11-03T22:43:06.653038+00:00'
---
Supersedes the slab-cut part of deci-25a744e3. ShellBeamDemand is now (Mu_pos, Mu_neg, Vu) from the frame forces only; Asap reports them at the shell node so the hung web's N*e is included. The slab's own bending stays with the slab bars. Basis: lower-bound / equilibrium design from elastic analysis (ACI 318-11 §8.3.1 p.112, §13.5.1 p.248). Removes the double count and takes the §8.12 flange width out of the demand (it stays in beam capacity). story_shell_beam_demands(model, frames, beam_index::Dict{Symbol,Int}, cases). Test: frames + full-width slab cut = W*L/8 within 3% for every combination; beam demand = frame moment. Next: composite steel proposal (shell field into PerStationComposite).
