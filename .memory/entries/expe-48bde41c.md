---
id: expe-48bde41c
type: experiment
project: menegroth
parent_id: plan-8fcebf0f
title: design_ordinary_walls! on a joined L and a 6 m square core
node_label: Joined stage ran
tags: walls,joined,shear-friction,stage
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-86d09e9d
created_at: '2026-11-04T19:37:41.853002+00:00'
updated_at: '2026-11-04T19:37:41.853002+00:00'
has_child_rationale: The corner record had only been unit-tested. This run is the
  stage path.
---
Runner `scripts/runners/joined_wall_stage.jl`. Three-story 12 m office, row A.3, SDC B, SDS 0.05, cracked wall E, rigid diaphragms. Walls claimed on grid edges that already meet, so the T-split had nothing to cut.

L: two 6 m legs per story, one 90° corner. Clear length 5.850 m (one end, t/2 = 0.15 m). Box: four 6 m legs, four 90° corners. Clear length 5.700 m (both ends). Each story is one joined assembly. Stacked stories stay separate.

Both calls returned. No record failed. ρl and ρt stayed at 0.0025. θ was 0.0047 on the L and 0.00048 on the box, so the §12.8.7 factor is 1.

Shear friction was written once per corner, on the lower wall index. φVn = 1.303 MN on every corner (Ac = 0.3 m × 4 m, Avf = 0.0025 Ac, μ = 1.4, φ = 0.75, fy capped at 60 ksi). Governing case was wind, 1.2D+1.0W. L demand 81–95 kN (ratio 0.062–0.073). Box demand 37–164 kN (ratio 0.028–0.126). Out-of-plane shear and moment were reported at ratio 0.

Not covered: a corner that fails, and a T whose stem lands on a wall interior inside this stage.
