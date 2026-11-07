---
id: deci-d04a388c
type: decision
project: menegroth
parent_id: plan-c8115994
title: Interior shaft walls in the core office
node_label: Interior shaft walls in the core office
tags: core,walls,lobby,shaft,diaphragm
status: active
open_threads: 0
success: 'null'
files: scripts/runners/core_office_geometry.jl@3213776, StructuralSynthesizer/test/core/test_core_shaft.jl@3213776
session_id: sess-622bfee6
created_at: '2026-11-07T01:06:13.969934+00:00'
updated_at: '2026-11-07T01:06:13.969934+00:00'
has_child_rationale: The demo core needs interior walls that the analysis actually
  includes, which requires a lobby slab so the shaft wall is a slab edge and tee joints
  so the dividers share nodes.
---
The core office (`core_office_skeleton`) now has a lobby and three shafts inside the 8 m center bay, on every story below the roof. The roof face stays the full bay.

Lobby slab: y = 8 m to 10.5 m, the full 8 m width, kept in the floor group. North of y = 10.5 m there is no slab. That void is one hole of 44 m² (the union of the shafts), because the outline walks slab faces only. Elevator shafts are x = 8 to 10.4 and 10.4 to 12.8; the stair is x = 12.8 to 16. These sizes are demo geometry.

Interior walls, each ending on another wall so `split_tee_junctions!` shares the corner nodes:
- y = 10.5, from x = 8 to 16, between the lobby and the shafts. This edge is a slab boundary.
- x = 10.4 and x = 12.8, from y = 10.5 to 16, standing in the hole.
The west and east core walls are split at y = 10.5 so the lobby face and the office face each own their piece.

Analysis inclusion, confirmed by `test_core_shaft.jl` (1338 checks):
- Every `:walls` edge becomes a pier. After the tee split, each story is one joined assembly, and the divider ends lie on the lobby wall and the north wall.
- The lobby/shaft wall is on the floor-outline hole. Slab-shell nodes on it are held (vertical displacement and rotation about the wall). A semirigid diaphragm keeps a wall node on that edge and at the tee, and drops a node on the divider out in the hole.
- The dividers are in the shell model through those tees. They are not slab edges, so they do not hold the office slab.
- A rigid diaphragm ties every wall node that sits on a story elevation into the rigid link, including nodes inside the hole. That is stiffer than the void.

Doors, clear of the tees: two 1.1 m elevator doors and one 1.0 m stair door on the lobby/shaft wall, and a 1.8 m entrance centered on the south core wall. Sill at the story, height 2.1 m.

Direct design on the open floor is refused by ACI 318-11 §13.6.1.2 (a 24 m panel after the core-corner columns are dropped) and §13.6.1.3 (successive spans on the shaft wall differ by more than one-third). `gen_medium_office` is unchanged.
