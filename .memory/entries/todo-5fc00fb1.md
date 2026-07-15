---
id: todo-5fc00fb1
type: todo
project: menegroth
parent_id: plan-77fbce0e
title: D6 — Steel shape-catalog expansion (channels, angles, WT, built-up/plate girders)
node_label: 'D6: Steel shapes'
tags: todo,steel,sections,channels,angles,wt,plate-girder,aisc,phase-d
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-92359b08
created_at: '2026-07-15T02:27:04.261265+00:00'
updated_at: '2026-07-15T02:27:04.261265+00:00'
has_child_rationale: Only W and HSS today; trusses, bracing, and lintels need the
  other AISC shapes
---
# D6 — Steel shape-catalog expansion

Section support is limited to `ISymmSection` (W/S) and HSS (rect/round). Channels, single/double angles, WT/structural tees, and built-up/plate girders are **explicitly not implemented** (`_steel_sections.jl`, `members/codes/aisc/README.md`). These are needed for **truss members (C4), bracing members (H1), and lintels/struts**.

**Build:** add section types + AISC Shapes Database catalogs for C/MC channels, L/2L angles, WT, and built-up plate girders; extend the AISC checks (incl. AISC 360-16 F4/F5 non-compact/slender-web I-shapes, currently erroring, and single-angle/flexure provisions). **Canon:** AISC 360-16 (in code). **Couples to:** C4 (trusses), H1 (braces), D5 (connection elements).
