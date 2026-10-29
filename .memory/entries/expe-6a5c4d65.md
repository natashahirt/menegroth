---
id: expe-6a5c4d65
type: experiment
project: menegroth
parent_id: plan-fa69916a
title: Equilibrated drilling penalty passes shell oracles and wall story cuts
node_label: Equilibrated drilling penalty passes shell oracles
tags: asap, shell, drilling, equilibrium
status: active
open_threads: 0
success: 'true'
files: external/Asap/src/Elements/shell/shell.jl@1b4665a, external/Asap/src/Elements/shell/composite.jl@1b4665a,
  external/Asap/test/elements/shell/test_shell_tri3.jl@1b4665a
session_id: sess-ce884bc0
created_at: '2026-10-29T20:18:25.938436+00:00'
updated_at: '2026-10-29T20:18:25.938436+00:00'
---
Done. ShellTri3 and CompositeShellTri3 now penalize (θz − ω) at each node, with ω = ½(∂v/∂x − ∂u/∂y), instead of a ground-anchored spring on θz. A rigid in-plane rotation stores no energy and the element force is self-equilibrated.

Tests: Asap shell element 21/21 (new equilibrium test included), composite shell 35/35, analytical plates, mesh convergence, benchmarks, and FinEtools reference all passed. Wall story cuts: test_wall_phase5_assembly and test_wall_story_cuts, 130/130. The 146.94 N·m leak is gone.
