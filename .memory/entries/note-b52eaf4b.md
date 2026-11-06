---
id: note-b52eaf4b
type: note
project: menegroth
parent_id: plan-9768ec38
title: Flexible diaphragm keeps each wall's tributary complement
node_label: flexible wall tributary
tags: walls,diaphragm,tributary,aci
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-9931b996
created_at: '2026-11-06T05:04:51.952480+00:00'
updated_at: '2026-11-06T05:04:51.952480+00:00'
---
A `:flexible` diaphragm no longer refuses a building that has walls. The tributary requirement calls `compute_column_tributaries!`. Each wall keeps the complement already stored on `tributary_cell_areas`. A strut still throws: a brace is not given a column area, a zero share, or a guessed fraction. Columns that exist still need a positive area. A building with only walls must have at least one positive wall area.

On the 10×6 m ordinary-wall office, removing the columns leaves every wall with a positive complement. With the columns present, the ground-story wall along y=0 keeps 30 m² and the upper walls keep an empty complement, because each column keeps the larger of its corner Voronoi region and its curved region and that partition fills the cell. `to_asap!` with a flexible diaphragm does not throw and writes no rigid links.

A one-story office with one pierced wall and one solid wall connects through the ordinary-wall stage. The pierced wall's 0.4 m bands pass spandrel flexure and shear, and its vertical piers record in-plane shear. The solid wall keeps bearing and in-plane shear. The core shaft still refuses the direct design method under ACI 318-11 §13.6.1.1, and the message does not say the frame ends at a wall. The office runner header now cites §13.6.1.1 and §13.6.1.2.

A lintel under a solid story above is still merged into one deep band and recorded unchecked. That layout was not changed. Deep-beam strut-and-tie and the gravity-only sway magnifier stay out of scope.

Tests: ordinary-wall stage plus diaphragm idealization, 449 passed; core shaft, 1140 passed.
