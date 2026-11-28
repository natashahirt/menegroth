---
id: deci-2ec5aaf6
type: decision
project: menegroth
parent_id: plan-ad399e86
title: Waffle and Nervi are a standard slab plus frame ribs, not new floor types
node_label: Waffle and Nervi are a standard slab plus frame ri
tags: waffle,nervi,ribs,framing,story-shell,one-way,two-way
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-c9a28dc0
created_at: '2026-11-07T15:37:31.453405+00:00'
updated_at: '2026-11-07T15:37:31.453405+00:00'
---
2026-11-07. Waffle and Nervi rib networks are not their own floor types in design_building. The topping is sized with the existing one-way or two-way slab. Ribs are frame members, so the centerline can be a one-way joist line, an orthogonal waffle grid, or a curved rib network. ACI 318-11 §8.13 joist permissions (the 10 percent Vc increase, the topping minimum) apply only when the resulting ribs meet §8.13.1–§8.13.3; §8.13.4 otherwise requires slabs and beams, which is this path. A regular bay uses the one-way sizer on the rib spacing or the two-way sizer on the panel between an orthogonal grid. A curved or irregular panel has no strip those coefficients apply to, so its topping demand stays on the story shell, which already holds the slab on frame ribs. Remaining geometry work is in the framing patterns: IsoparametricPattern draws straight bounding-box lines, and CustomPattern keeps only the polyline endpoints.
