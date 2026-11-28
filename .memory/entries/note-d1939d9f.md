---
id: note-d1939d9f
type: note
project: menegroth
parent_id: todo-8ccd78cf
title: Strips and mats check every footing combination
node_label: Strips and mats check every footing combination
tags: foundations,strip,mat,lateral
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-6a204f33
created_at: '2026-11-25T21:32:03.764688+00:00'
updated_at: '2026-11-25T21:32:03.764688+00:00'
---
Column strips stay centered on the gravity (D+L) resultant. Each service combination must satisfy ACI 336.2R §3.2.1 Eq. (3-1) with q_max ≤ qa and q_min ≥ 0, and each strength combination is designed from its own column forces. Partial contact is not used.

Column mats keep equal overhang, so the centroid stays the center of the column box. The overhang grows until every combination is in the kern. The rigid section also envelopes each strength combination. The collapsed single demand is still passed in, so the section is not smaller than before.

Grade-wall and grade-mat footings still see the gravity line load only. Their base nodes are not in the stored support cases, and an L or a T cannot be lengthened without moving the centroid.

Tests: StructuralSizer foundations/test_strip_aci.jl 13/13; foundations/test_mat_rigid_statics.jl 8/8.
