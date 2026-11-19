---
id: chec-d82a108d
type: checkpoint
project: menegroth
parent_id: deci-6241f871
title: Steel shell spans follow the framing line
node_label: Steel shell spans follow the framing line
tags: deflection,framing-level,story-shell,2024-plans
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-bdbdfe08
created_at: '2026-11-18T20:25:48.284638+00:00'
updated_at: '2026-11-18T20:25:48.284638+00:00'
---
Steel story-shell live-load spans are measured on the framing line, not on each member polyline. Supports are columns, walls, :support vertices, and crossings with a strictly lower framing level. L is the support-to-support length, or twice the cantilever length (IBC 2021 Table 1604.3 footnote i). The offset is sampled from the element deflection profile (21 stations), so a single element between two supports still reports its bow. Reinforced-concrete spans stay on the column points, because those also set the flange width and cracked inertia.

grid/x1y1 steel two-way finished in 1528 s. The previous stop was shell_deflection_ll at 1.18 on W36×652. Filler joists landed at W12×40 to W18×60. Column-line pieces are mostly W21 to W30, with four W44×290 whose frame L/360 need is about 2500 in^4. The story shell warned that beam sections were still changing after 10 passes.

Hierarchy on the drawn 2024 lines (before filler joists): office and tan_121_seaport reach level 2 (2 fallback lines each). grid/x1y1 and star/e0c0 are level 0 and 1 with no fallback. nova/e3c4 has 148 lines, 12 seeded, and 136 left at level 0 because their ends never both became known. topology/r2c1, rhombus_8x12, and star_8x12 also collapse to level 0 for the same reason. star/e10c2 is entirely level 0 and almost entirely seeded.

Tests: framing-level file 36/36, story-shell beams 197/197, hierarchy 1359/1359. Not committed.
