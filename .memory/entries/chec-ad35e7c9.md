---
id: chec-ad35e7c9
type: checkpoint
project: menegroth
parent_id: deci-0b378fd3
title: Story-shell walls are line supports
node_label: Story-shell walls are line supports
tags: story-shell,walls,aci-318
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0ef84d7b
created_at: '2026-11-08T01:57:28.024992+00:00'
updated_at: '2026-11-08T01:57:28.024992+00:00'
---
2026-11-07. A wall that meets the slab is a line the story shell follows. Support runs only along solid pier: an opening whose head reaches the soffit breaks the line. Nodes on the line are held per ACI 318-11 R13.6.3.3 (aci-318-11, page 254): uz fixed, and rotation fixed about the wall's own axis. A skewed wall gets that rotation from a spring. Stories with walls stay in the story-shell design levels.

Tests in analyze/test_story_shell_walls.jl: a full-height opening splits the line; a one-way slab between two walls matches fixed-strip deflection and the static moments qL^2/12 and qL^2/24; wall-plus-column vertical reactions equal the applied load.

The factored shell reaction is not yet written into wall dead and live. That scale is the next change.

The story-shell modules (panel analysis, bars, slab edge, and their includes) ride along because the wall mesh and these tests run through analyze_story_shell, and those files were not on the include list.
