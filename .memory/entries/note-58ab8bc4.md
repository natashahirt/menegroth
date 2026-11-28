---
id: note-58ab8bc4
type: note
project: menegroth
parent_id: plan-4caf2683
title: DesignSession footings are heavier; the cold graph matches the stage loop
node_label: DesignSession footings are heavier; the cold graph
tags: foundations,design-session,equivalence
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-fa42a4c1
created_at: '2026-11-25T05:19:27.758642+00:00'
updated_at: '2026-11-25T05:19:27.758642+00:00'
has_child_rationale: The heavy footings come from DesignSession, not the column trim
---
The footing gap is between `DesignSession` and the stage loop. `design_building` with the default `restore=true` builds a `DesignSession` and returns `session.base_design`. That session sized the ordinary flat plate's footings at 21.365 m³ of concrete.

`design_building(..., restore=false)` runs `execute_graph!` on the caller's structure. Its footings are 14.519463090048 m³, the same figure the legacy `build_pipeline` loop printed. Support reactions on that cold graph: four 11.75 kip, four 22.2 kip, four 22.93 kip, four 46.17 kip (412.2 kip total). Slab self-weight 4.271 kPa. 5502 shells.

Columns stayed 10x10 with 4#5 on both, slab thickness 7.205 in, and the flat-plate trim was unchanged. The session is what the equivalence test is failing on.
