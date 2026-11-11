---
id: deci-67cf61cb
type: decision
project: menegroth
parent_id: deci-92382f3b
title: 'Default: grade core walls share a mat; an isolated wall gets a strip footing'
node_label: Core mat, wall strip
tags: foundations,walls,core,mat,strip,default
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-d931baa0
created_at: '2026-11-05T14:46:56.505209+00:00'
updated_at: '2026-11-07T15:41:01.232640+00:00'
has_child_rationale: User set the default wall-to-foundation assignment. Column spread
  footings and the optional-strategy framing stay as already decided.
---
Confirmed by the user 2026-11-05. Default assignment for walls, at grade only:
- Walls that form a core share one mat.
- An isolated wall gets its own strip footing.

Upper-story walls do not get a second foundation; the grade group decides. Column supports outside that footprint stay on spread footings, and this default does not replace the coverage check that picks those spreads. A support vertex inside the mat footprint still moves onto the mat.

The mesh can already tell an isolated wall (`WallAssembly.joined == false`) from walls that meet. It has no core tag. A joined group that is not a core (an exterior L or T) is not assigned by this sentence.

The existing strip designer sizes a rigid footing under two or more columns on a line and refuses a single load. A wall strip is a continuous footing under that wall's base reaction, so it is a new design path. The core mat can reuse the rigid mat once the base is restrained and the base cut is applied at the grade wall ends. Punching at a wall remains ungrounded.
