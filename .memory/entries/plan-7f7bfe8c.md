---
id: plan-7f7bfe8c
type: plan
project: menegroth
parent_id: plan-1b964170
title: 'Walls as slab supports: open core gap, support list, FEA wall supports, DDM
  spans/moments, load split, punching at wall ends'
node_label: Walls as slab supports
tags: slabs,walls,ddm,fea,core,supports,aci318-11
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7cfe7560
created_at: '2026-11-05T01:17:55.067673+00:00'
updated_at: '2026-11-05T01:17:55.067673+00:00'
has_child_rationale: Flat-plate design sees only columns; the core office fails §13.6.1.2
  after core-corner columns were dropped.
---
Trigger (2026-11-04): core office dropped 16 core-corner columns; DDM rejects a 23.5 m x 8 m panel (§13.6.1.2) because the span runs column-to-column across the core. Slab sizing never sees walls.

Grounding (ACI 318-11, corpus aci-318-11):
- §13.5.1.1 p.249: frames are slab + 'supporting columns or walls'.
- §13.2.3 p.244: panel bounded by column, beam, or wall centerlines.
- R13.1 p.243: wall treated as beam of infinite stiffness; wall should support entire panel edge; wall-like columns shorter than a panel length can be treated as columns.
- §13.6.1.2/§13.6.1.3 p.252: spans center-to-center of supports. §13.6.1.4 is the only column-only rule.
- §13.6.2.5 p.253: ln face to face of columns ... or walls; >= 0.65 l1.
- §13.6.4.3 p.256: support walls >= 3/4 l2 -> negative moment uniform across l2.
- §13.6.3.3 table + R13.6.3.3 p.254: unrestrained (0.75/0.63/0) vs fully restrained (0.65/0.35/0.65); no stiffness threshold in code.
- Table 9.5(c) p.134: ln face-to-face of supports; edge beam footnote alpha_f >= 0.8 (wall-as-edge-beam is an open reading).
- §11.11.1.2 p.200: punching critical section d/2 from edges/corners of columns, concentrated loads, or reaction areas (wall ends/core corners). ACI 421.1R has general-shape section properties.

Decisions locked with the user:
- Core office: open core gap on every floor below the roof; roof stays closed. Model by removing the core faces from floor groups (not a full-bay SlabOpening, which leaves a zero-area cell).
- §13.6.1.1 checked per frame (any frame with < 3 continuous spans refuses DDM for that slab), not longest run in the slab.
- A DDM span ending at a wall refuses DDM and goes to FEA (no stiffness assumption) until a stated, overridable stiffness rule is chosen.

Order:
1. Core gap + test that slab and wall share nodes along the gap edge (_slab_wall_nodes skips slab-boundary nodes; with a gap the core walls lie on the slab boundary).
2. One support list per slab (columns + walls at that slab level; full-edge wall = line support, shorter wall = wall-like column per R13.1).
3. FEA sizing holds the slab on walls; pre-sizing validation counts wall supports.
4. DDM: spans/continuity to wall centerlines, ln to wall face, §13.6.4.3, R13.1 infinite-stiffness wall beam; end span at wall refuses.
5. Load split column/wall (columns shrink only when wall supports are modeled).
6. Punching at wall ends / core corners (ground before code).
7. Table 9.5(c) at walls.
EFM keeps refusing walls until §13.7 is read.
