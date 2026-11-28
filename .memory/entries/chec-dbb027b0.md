---
id: chec-dbb027b0
type: checkpoint
project: menegroth
parent_id: chec-9510ac77
title: Curtain-wall dead load is on the perimeter beams and in W
node_label: cladding dead load
tags: cladding,wall_SDL,seismic-weight,asce-7
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-31f938f1
created_at: '2026-11-12T02:25:36.291129+00:00'
updated_at: '2026-11-19T14:55:55.828071+00:00'
---
wall_SDL (default 10 psf) is now a factored :cladding line load on perimeter beams, the unfactored dead case, and the service case, and the same weight is in seismic W and Px. Half of each façade band goes to the floor at each end, matching the wall self-weight split (ENGINEERING JUDGMENT; ASCE 7-22 §3.1.1 p.72 and §12.7.2 p.184 do not assign the band). Edges covered by a structural wall are omitted. wall_SDL=0 leaves the façade off. ELF tests 68/68 and pattern-loading tests 101/101 on row-f-nlp. Provenance members_v5 and ordinary_walls_v5. Recorded without file pins because memory serves the main checkout, not the /tmp/menegroth-rowf worktree.
