---
id: deci-569db0d0
type: decision
project: menegroth
parent_id: plan-1e34d0a9
title: Symmetry falls out of a symmetric solve
node_label: No imposed symmetry
tags: waffle,solid-head,symmetry,solver
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-65440cc3
created_at: '2026-11-14T15:02:03.038193+00:00'
updated_at: '2026-11-14T15:02:03.038193+00:00'
has_child_rationale: A symmetric waffle should match across its centerlines because
  the checks tie, not because a mirror constraint copies one side onto the other.
---
Do not add a symmetry constraint to sizing, head growth, or bar sharing. On a symmetric building the same answer should come out of the solver on both sides.

What breaks that here is a named growth direction. Column punching names a face when one corner is the peak (ACI 318-11 R11.11.7.2). The center column carries 556 kip and 1 kip·ft, and any moment above 1e-6 kip·ft is treated as a side. That one face adds a single bay instead of a ring. The four slabs that meet at the column each grow their own corner, so one extra bay becomes the step in the center head. Later passes then see a building that is no longer symmetric, which is why a mirror pair can leave sizing with the same stem and different flanges.

The rib-side band (ribs within 2% do not name a side) is the same idea: a near tie names no direction. It does not copy one rib's section onto another.
