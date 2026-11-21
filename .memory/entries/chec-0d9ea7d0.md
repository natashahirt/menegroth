---
id: chec-0d9ea7d0
type: checkpoint
project: menegroth
parent_id: deci-498f6f53
title: '#7 VERIFIED EXACT at building level: member-stage golden 299/299 bit-identical
  with #7+#18'
node_label: '#7 VERIFIED EXACT at building level: member-stage '
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-460af313
created_at: '2026-11-21T04:09:18.629779+00:00'
updated_at: '2026-11-21T04:09:18.629779+00:00'
---
core/test_flat_plate_member_stage.jl -> 299/299 PASS (24m33s fresh) against the new Asap carrying the #7 rigid-link reduced-factorization cache AND the #18 install-resolve skip. Golden values are bit-identical, proving both optimizations are exact at the full rigid-diaphragm building level (the member stage drives repeated solve!(model,links) value-only re-solves, now served by cholesky! symbolic reuse). Combined with the 239/239 Asap rigid-link/diaphragm/pdelta/factor-cache suites, #7 phase 1 is complete and verified. Net state of the overnight speed pass: #18 DONE+verified (chec-fd1e7734), #7 phase-1 DONE+verified (chec-bdc5fee3 + this). Remaining exact levers: #19 (unify member/slab P-M catalog caches), #20 (resolve installed section vs full-catalog cache), #7 phase-2 (non-mutating multi-case cross-call cache).
