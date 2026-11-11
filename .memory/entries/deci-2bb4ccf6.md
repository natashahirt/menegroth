---
id: deci-2bb4ccf6
type: decision
project: menegroth
parent_id: plan-3986c866
title: Slab picture stays on the solver mid-plane
node_label: Mid-plane slab picture
tags: viewer,slab,mid-plane,shell,deck,ribs
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-67f85c6c
created_at: '2026-11-06T23:18:23.591782+00:00'
updated_at: '2026-11-06T23:23:30.046618+00:00'
has_child_rationale: User chose the picture that matches the shell node rather than
  a floor drawn down from story elevation.
---
User decision 2026-11-06. The viewer keeps the slab centered on the shell node. Asap integrates the shell about that node (thickness and thickness³/12), and a column on the story shares the node, so the joint is the mid-plane.

The walking surface is half a thickness above the story elevation and the soffit is half a thickness below it. Concrete stems hang from that soffit only when the solved element carries web_below_slab_eccentricity. Steel stays on the node. A deck or rib section, when drawn, uses this same plane: the recorded depth is centered on the node, and the analysis view remains the plate that was solved.

Drawing the top of concrete at the story elevation, with the structure below it, is deferred. That picture would drop the mid-plane by h/2 relative to the columns and change the end moments the story shell keeps. It is a solver change, not a drawing change.
