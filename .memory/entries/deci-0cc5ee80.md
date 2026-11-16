---
id: deci-0cc5ee80
type: decision
project: menegroth
parent_id: plan-c431a82d
title: A slab edge is joined to the wall, not fixed in space
node_label: slab joined to wall
tags: story-shell,walls,boundary,aci-318-11
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f4ccda61
created_at: '2026-11-16T03:43:11.735696+00:00'
updated_at: '2026-11-16T03:43:11.735696+00:00'
has_child_rationale: Fixing a slab edge in space is not a wall support.
---
ACI 318-11 R13.6.3.3 (aci-318-11, page 254) chooses a direct-design moment coefficient for an edge cast integrally with a stiff wall. It is not a support. The story shell and the flat-plate shell no longer fix uz or rotation of slab nodes on a wall line, and the grounded wall-axis spring is gone. Those nodes are the top of a wall shell. The wall base, one pier below the slab, has its translations held and its rotations free. The wall uses Wall.concrete when set, otherwise the concrete already on that analysis. FlatPlateFloorInput carries wall_piers (thickness and drop) so the design kernel can build the same wall after the wall objects are dropped. Story-shell wall tests passed (614 in the one-way case, plus reactions). The fixed-strip deflection and edge moment are comparisons only: the finite wall rotates, so the slab deflects more and the edge moment is smaller. Flat-plate wall-support tests passed 83/83. The core-shaft test still dies in core_office_skeleton because story 0 has no beam edges; that is the grade-grid omission, not this boundary condition. The existing D/A1 scene file was not regenerated.
