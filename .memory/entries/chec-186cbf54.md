---
id: chec-186cbf54
type: checkpoint
project: menegroth
parent_id: plan-d0c5bff3
title: Phase 5b shells in, stopped on an upper-floor fixity P1
node_label: Phase 5b shells in, stopped on an upper-floor fixi
tags: walls,phase5,checkpoint
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-040b3b6c
created_at: '2026-10-22T21:18:55.220250+00:00'
updated_at: '2026-10-22T21:18:55.220250+00:00'
---
run-4c69735b. Wall shells are in to_asap!. A rectangular two-story core solves, corners within 1 mm share a node, nodes 1.1 mm apart stay separate, the wall frame slot stays zero area, and a building with no walls is unchanged. Critic P0 on millimetre-bin rounding was fixed by a new engineer (distance check, tie throws). Stopped at the soft cap on a P1: wall_node! fully fixes a reused frame joint when that joint is at the lowest wall base, so a wall that starts on an upper floor can pin a free frame joint there. P2 left: a wall 2 mm or shorter can snap both top corners onto one node. 5c and 5d have not started. The whole-phase test has not been run. Code uncommitted.
