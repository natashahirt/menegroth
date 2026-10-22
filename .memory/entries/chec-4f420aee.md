---
id: chec-4f420aee
type: checkpoint
project: menegroth
parent_id: plan-d0c5bff3
title: 'Phase 5a closed: zero wall frame, consistent mass finite'
node_label: 'Phase 5a closed: zero wall frame, consistent mass '
tags: walls,phase5,checkpoint
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0a9a4893
created_at: '2026-10-22T19:59:09.068820+00:00'
updated_at: '2026-10-22T19:59:09.068820+00:00'
---
run-4dba4925 closed. to_asap! keeps model.elements[edge_idx] aligned with the skeleton edge. A :walls edge gets zero area, zero inertias, and zero density (utils.jl _zero_wall_frame_section). A building with no walls is unchanged. Asap consistent mass divided by area and produced NaN on that zero section. A new engineer rewrote only the torsion rotary terms in external/Asap/src/Dynamics/mass.jl to rho*L*I1/3 and rho*L*I1/6. Nonzero sections match the old formula within 3 ulps; a W10x22-like section matched bit for bit; a zero-area wall mass is exactly zero. Leftover P2: local_mass_consistent! is still NaN at L=0 because of rho/L in the bending terms. length! already rejects a zero-length element. Not fixed. 5b has not started. Code uncommitted.
