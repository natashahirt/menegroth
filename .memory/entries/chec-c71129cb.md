---
id: chec-c71129cb
type: checkpoint
project: menegroth
parent_id: deci-0b378fd3
title: Story-shell wall reaction raises pier dead and live axial
node_label: Shell reaction raises wall axial
tags: story-shell,walls,gravity,tributary
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-e912802f
created_at: '2026-11-08T02:42:50.479344+00:00'
updated_at: '2026-11-08T02:42:50.479344+00:00'
---
2026-11-07. The story shell's factored vertical reaction is stored per wall after sizing. Wall design keeps the building-model pier cut (dead, live, roof, shear, and moment, including wall self-weight). When the shell reaction exceeds 1.2D+1.6L of that cut, dead and live axial are scaled by the same ratio so that combination matches the shell and the tributary split is unchanged. A smaller shell leaves the cut alone. A cut with essentially no dead-plus-live axial is not scaled. The roof companion, shear, and moment stay. Shared shell nodes count on the first wall. Tests: raise_wall_axial_to_shell and one-node-one-wall assignment, 67 passed in test_wall_combinations.jl.
