---
id: expe-4e48ad26
type: experiment
project: menegroth
parent_id: deci-144e5b48
title: '3/4 in ply: sag ~0.21 / 0.29 in, poker wood+Al 78 lb'
node_label: '3/4 in ply: sag ~0.21 / 0.29 in, poker wood+Al 78 '
tags: pokertable,thickness
status: active
open_threads: 0
success: 'true'
files: StructuralStudies/src/pokertable/materials.jl@179e0da
session_id: sess-f5f04477
created_at: '2026-09-20T20:18:07.301848+00:00'
updated_at: '2026-09-20T20:18:07.301848+00:00'
has_child_rationale: thickness bump test
results: '[{"metric": "poker_max_uz", "value": -0.213, "unit": "in", "split": "poker
  DL_edge 0.75in ply"}, {"metric": "dining_max_uz", "value": -0.293, "unit": "in",
  "split": "dining DL_edge 0.75in ply"}, {"metric": "poker_wood_mass", "value": 61.04,
  "unit": "lb", "split": "poker plan"}, {"metric": "dining_wood_mass", "value": 41.49,
  "unit": "lb", "split": "dining plan"}, {"metric": "poker_al_mass", "value": 17.32,
  "unit": "lb", "split": "deployed"}, {"metric": "dining_far_foot_mu", "value": 2.02,
  "unit": "1", "split": "dining DL_edge"}]'
---
3/4 in ply rerun vs 1/2 in seed. Sag dropped ~×0.3 as t³ predicted. Poker wood+Al = 78 lb, over the 70 lb target. Dining far-foot μ improved 4.0 → 2.0 from extra self-weight.
