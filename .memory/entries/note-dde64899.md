---
id: note-dde64899
type: note
project: menegroth
parent_id: plan-1d645a44
title: Slab openings are in the model and bars route around them
node_label: Bars around slab openings
tags: rebar,slabs,openings
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-d5a5e5cf
created_at: '2026-11-06T23:07:09.567425+00:00'
updated_at: '2026-11-06T23:07:09.567425+00:00'
has_child_rationale: The detailing plan wrongly said slab openings are not modeled.
  They are unframed plan loops on a story.
---
SlabOpening is a story plus a plan loop (skeleton.jl). A stair, duct, or shaft with free edges. An opening framed by beams on every side is a missing skeleton face instead. Openings already cut cell spans, net area, composite effective width, and punching perimeter.

Phase 1 places bars around them: bars stop short of the opening edge by the cover, and the code's extra bars along the opening edges are added. That rule is read from the corpus before it is written. Embedded plates, sleeves, and conduits are not in the model and stay out.
