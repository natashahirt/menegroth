---
id: plan-2dcf41ac
type: plan
project: menegroth
parent_id: plan-68155c81
title: 'Wiring cleanup: story-shell convergence, SPD warning, placed-bar takeoff,
  rib frames'
node_label: 'Wiring cleanup: story-shell convergence, SPD warni'
tags: wiring,efficiency,story-shell,detailing,ribs,waffle,nervi,asap
status: active
open_threads: 4
success: 'null'
files: ''
session_id: sess-f5dfe580
created_at: '2026-11-07T15:45:29.795387+00:00'
updated_at: '2026-11-08T21:30:40.129353+00:00'
---
2026-11-07. Order: (1) story-shell sizing that settles, (2) the not-SPD stiffness warning, (3) placed-bar takeoff in the design output, (4) rib geometry as polylines, (5) rib API and options, (6) rib deflection without a story shell.

User decisions:
- Convergence: diagnose the oscillation before choosing a rule (grow-only vs keep-larger-on-cycle).
- Detailing: on by default in design_building, with a flag to turn it off, and run only on the final building (not on intermediate design-graph or incremental states). The scene reuses the stored result.
- NLP: extend the NLP T-beam sizer to ribs (ACI 318-11 §8.13.2-8.13.3 limits as constraints, the §8.13.8 Vc increase when met).
- Curved rib networks: explained shell-only vs polygon tributaries; awaiting choice.

Efficiency targets: resize only groups whose shell demand or stiffness changed; skip slab panel reinforcement on strength-only passes; restore Asap's cached in-place Cholesky refactor by removing the mechanism behind the not-SPD warning; remove O(n^2) loops in detail_building (_beam_continues, _column_top_depth, wall scans) with vertex maps built once; detail once per unique member key; isoparametric quad ribs as exact straight segments; curved ribs cut at the story-shell mesh spacing.
