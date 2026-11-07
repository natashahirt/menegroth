---
id: deci-091eb8b3
type: decision
project: menegroth
parent_id: plan-1d645a44
title: Wall bars follow Chapter 11; special boundary elements wait on c
node_label: Wall bar placement
tags: rebar,walls,detailing,aci-318-19
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-348ed0d9
created_at: '2026-11-07T14:39:20.384218+00:00'
updated_at: '2026-11-07T14:39:20.384218+00:00'
has_child_rationale: The wall plan's proposed readings were adopted so placement could
  be implemented and tested without a special-wall design.
---
detail_wall places ordinary cast-in-place wall bars from ρl and ρt (ACI 318-19 §11.7, corpus aci-318-19 pp. 173–174). Two layers when h > 10 in.; spacing floored to 0.5 in. and capped at min(3h, 18 in.), plus ℓw/3 vertical and ℓw/5 horizontal when Vu exceeds φ αc λ √f′c Acv. Bar menu is #4–#6. Vertical laps are the longer of the compression lap and the Class B tension lap, because the bar force is unknown. Free horizontal ends get ordinary 90° hooks, noted as practice rather than a Chapter 11 requirement. Joined ends lap Class B into the intersecting wall and are not hooked. Openings get No. 5 trim on four sides, developed for fy, and do not replace interrupted distributed bars; the wall over an opening is warned, not designed as a lintel. Foundation dowels are placed at max(ℓdh, ℓdc) and warned unchecked when the foundation depth is unknown.

Special walls (§18.10.2) raise both ratios to 0.0025, force two curtains when hw/ℓw ≥ 2 or Vu > 2λ√f′c Acv, and omit free-end hooks only when Vu < λ√f′c Acv. The 12 ft flexural extension and §18.10.6.4 boundary bars are not placed: the uniform ratio has no cutoff, and the neutral-axis depth c does not exist. Building detailing passes special=false.

Hand checks: 12 in. × 20 ft × 12 ft at ρ = 0.0025 is two curtains of #4 at 13 in. (108/108 member detailing). An L-shaped pair on a building details both piers, the door trim, the dowels, and the corner lap, and the scene record carries z stations, voids, and plan dots (12/12). Viewer typecheck passed; the wall sheet was not clicked in a browser.
