---
id: todo-bfbc2fb4
type: todo
project: menegroth
parent_id: deci-d066667a
title: '[crit15 P2] DDM applicability should reject interior-hole/notched slabs (appl.ok=FALSE),
  not design them as §13.6.2.4 edges'
node_label: '[crit15 P2] DDM applicability should reject interi'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/ddm.jl@21e23a0
session_id: sess-8efefa71
created_at: '2026-10-22T03:05:10.181595+00:00'
updated_at: '2026-10-22T03:05:10.181595+00:00'
---
crit15 north_deleted_hole probe: a 3×3 grid with an interior bay deleted computes north run≈0 → width 0 → Mub=84.028 with appl.ok=TRUE and no :failure. The Eq.(13-7) value 84.028 is the CORRECT §13.6.2.4 edge-to-centerline substitution, so the moment itself is not unconservative — but DDM applicability passing TRUE on a slab with an interior hole arguably violates §13.6.1.1/§13.6.1.2. Add an applicability check that an interior hole / notched layout fails §13.6.1 → FEA fallback. For the pre-ribbed fixes run.
