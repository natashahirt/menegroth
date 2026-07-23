---
id: chec-fbb97606
type: checkpoint
project: menegroth
parent_id: plan-1004cfac
title: 'Run 6 warm-state verify: ALL CHECKS PASS (12/12) bit-identical exact-first'
node_label: 'Run 6 warm-state verify: ALL CHECKS PASS (12/12) b'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-d01f807c
created_at: '2026-07-23T15:21:13.685159+00:00'
updated_at: '2026-07-23T15:21:13.685159+00:00'
---
Ran scripts/runners/verify_warm_state_incremental.jl against dirty working tree (peer session's uncommitted Run 6 implementation). 8m 9s runtime. Result: 12/12 checks pass.

[1] Warm-state reuse is bit-identical to the cold path (7 checks)
  - full run: warm design == cold design (byte-identical signature)
  - full run: warm last_recomputed == cold
  - loads-only (:load_combinations): warm design == cold design
  - loads-only (:load_combinations): warm last_recomputed == cold
  - members-only (:collinear_grouping): warm design == cold design
  - members-only (:collinear_grouping): warm last_recomputed == cold
  - members-only recomputes only :members (got [:members])

[2] sync_asap!(loads_only=true) is bit-identical to the full sync (Part A, 2 checks)
  - loads_only element forces bit-identical to full sync
  - loads_only global displacement u bit-identical to full sync

[3] MIP warm start preserves the optimum, OPTIMAL-gated (Part B, 3 checks)
  - warm start (correct prior) reaches OPTIMAL
  - warm start (correct prior) == cold sections
  - warm start (wrong prior) == cold sections when OPTIMAL

Runtime: 489,483 ms (~8m 9s), exit code 0. Log at logs/verify_warm_state_incremental.log.

Covers Parts A/B/C of plan-1004cfac scope. Run 6 warm-state is verified exact-first and ready to commit as a coherent unit.
