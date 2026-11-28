---
id: plan-adfe2e3a
type: plan
project: menegroth
parent_id: deci-639b8726
title: Wall corners are walls, and the plan shows the solve's reactions
node_label: Wall corners and solve plan
tags: walls,columns,tributary,scene,punching,story-shell
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-35033ef5
created_at: '2026-11-08T13:12:20.466504+00:00'
updated_at: '2026-11-08T21:12:02.075888+00:00'
has_child_rationale: The user wants wall corners designed as walls, and the plan colored
  from the solve rather than the geometric catchment.
---
Two changes, in this order. Do not rerun the office design until asked. v4 keeps its columns until then.

1. A column whose plan point lies on a wall segment is not a member. The four core-corner stacks leave the column group. The story shell already holds the wall line through the corner (vertical displacement and rotation about the wall axis). Punching at that corner is the existing wall section: re-entrant (`reentrant_wall_corner_section`, αs = 40), outside corner (`convex_wall_corner_section`, αs = 20), or the shaft loop. Its demand is qu times the two walls' tributary areas, so the walls must receive the catchment the columns currently keep or the check stays empty. Direct design will again see the 24 m panel (ACI 318-11 §13.6.1.2); the office already refuses §13.6.1.3, and the FEA path is the one that runs. The mat keeps the wall-line nodes. Tests first on a small model: catchment goes to the walls, corner punching runs, no spread footing appears at the corner.

2. The plan overlay stops painting `split_cell_supports` polygons as if they were the solve. The solve stores vertical reactions on support nodes, summed per wall from the story shell (`node.reaction[3]`, 1.2D+1.6L). It does not store an area. The scene gains those node reactions (position, wall or column, vertical force). The plan draws the wall line and the real columns from that force. A support with no reaction is absent. The geometric polygons stay a separate catchment sheet, labeled as the design input. A per-element map of which restrained node took the panel force would be a new analysis product, written by the solver, not inferred in the viewer.
