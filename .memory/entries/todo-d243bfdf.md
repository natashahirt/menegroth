---
id: todo-d243bfdf
type: todo
project: menegroth
parent_id: plan-a2a6128f
title: Phase 12 — Inclined (leaning) walls
node_label: 'P12: inclined walls'
tags: walls,phase,inclined,leaning,wind,facade,todo
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-158720dd
created_at: '2026-10-26T15:42:10.105614+00:00'
updated_at: '2026-10-26T15:42:10.105614+00:00'
---
Walls that lean out of vertical (battered or tilted walls). Today a `Wall` is one plan line (x1, y1)-(x2, y2) used at every height in its story, wind loads each floor-outline edge as a vertical rectangle (edge length times story height, horizontal outward normal), and Figure 27.3-1's wall table has no angle. This phase lifts that.

When: after the Phase 7 vertical-slice gate (todo-3b10ee83). It is a topology change, so it does not ride inside Phase 8 openings or Phase 9 §18.10. It must land before Phase 11 production verification. Phase 10 layout candidates stay vertical unless this phase has landed.

Scope, in order:
1. Code reading first (STOP gate). Read ASCE 7-22 Chapter 27 / Chapter 26 definitions for where an inclined surface stops being a wall and starts being a roof, and whether Figure 27.3-1 covers a leaning wall at all. If Chapter 27 does not cover it, the routes are the §27.1.3 wind-tunnel procedure (Chapter 31) or a caller-supplied pressure field. Read ACI 318-19 Ch. 11 for whether the ordinary-wall provisions apply to an inclined wall and how the self-weight eccentricity enters out-of-plane design. Ask the user before encoding anything that is not printed.
2. Wall data. `Wall` gets the top line of the story separately from the base line (or an explicit tilt). Vertical walls keep top == base and do not change.
3. Facade geometry. The exposed surface between two levels becomes a 3D panel joining the lower outline to the upper outline, with a 3D outward normal. `story_floor_outline` stays the plan boundary at each level and does not change. The panel extends the `WindFacadeEdge` / `wind_forces_from_pressures` seam (the CFD stub) from a plan edge to a panel; the horizontal part of each panel force goes to the story.
4. Wind. Apply only what step 1 finds. A leaning wall that Chapter 27 does not cover throws, the same way sloped roofs do now.
5. Gravity thrust. A leaning wall carrying its own weight and floor loads pushes horizontally at each floor. That thrust goes to the rigid-diaphragm master as a story force in every combination, including gravity-only.
6. FEM. The wall mesher accepts a non-vertical panel. Shells are already 3D. The rigid-diaphragm tie at each story elevation is unchanged. Mesh vs isolated-evaluator equivalence on an inclined cantilever.
7. Wall checks. Phase 7 ordinary-wall checks are written for vertical walls. Add the self-weight out-of-plane moment only as step 1 grounds it, or refuse an inclined wall in the checks.
8. Tests: a vertical wall is bit-identical to today; a tilted wall's gravity thrust balances at the diaphragm; a tilted facade under a supplied pressure gives the hand-computed horizontal force; an uncovered inclination throws.

Out of scope here: curved or warped facades, sloped roofs (separate: Figure 27.3-1 roof Cp, still refused), flexible diaphragms.
