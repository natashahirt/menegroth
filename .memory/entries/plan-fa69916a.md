---
id: plan-fa69916a
type: plan
project: menegroth
parent_id: plan-4b6f6344
title: Equilibrated drilling penalty for ShellTri3 so wall story cuts do not leak
  moment
node_label: Equilibrated drilling penalty for ShellTri3 so wal
tags: asap, shell, drilling, equilibrium, walls
status: active
open_threads: 0
success: 'null'
files: external/Asap/src/Elements/shell/shell.jl@34c7bd9, external/Asap/src/Elements/shell/composite.jl@34c7bd9,
  external/Asap/test/elements/shell/test_shell_tri3.jl@34c7bd9
session_id: sess-553b5c83
created_at: '2026-10-29T20:03:14.261574+00:00'
updated_at: '2026-10-29T20:03:14.261574+00:00'
---
ShellTri3 and CompositeShellTri3 drilling stabilization is a diagonal spring on θz. That spring is anchored to the ground, so a wall in in-plane bending leaks moment out of the element (146.94 N·m of 50,000 N·m on the 1×1 office wall fixture). Story-cut equilibrium in test_wall_phase5_assembly and test_wall_story_cuts fails on that residual.

Replace it with a penalty on (θz_i − ω) at each node, where ω = ½(∂v/∂x − ∂u/∂y) is the constant in-plane rotation of the triangle. A rigid rotation has θz = ω, so the penalty vanishes on all six rigid modes, and the nodal forces are self-equilibrated. Penalty magnitude stays the mean bending-rotation diagonal times drilling_scale, so a pure drilling mode is as stiff as before. Then re-run the Asap shell tests and the two wall story-cut files.

Citation: penalty form of Hughes & Brezzi, CMAME 72 (1989) 105–121.
