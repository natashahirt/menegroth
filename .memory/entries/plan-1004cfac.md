---
id: plan-1004cfac
type: plan
project: menegroth
parent_id: plan-5d8af001
title: 'Run 6: warm-state & factorization-aware reuse (the speed payoff)'
node_label: 'Run 6: warm-state & factorization-aware reuse (the'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-8394b7bd
created_at: '2026-07-19T18:43:33.887645+00:00'
updated_at: '2026-07-19T18:43:33.887645+00:00'
---
Goal: make DIRTY nodes cheap, not just skip clean ones. Today every dirty node replays its solver cold and the CHOLMOD factorization is nulled on every snapshot.

Approved scope (user recommendation accepted):
- EXACT-FIRST DEFAULT PATH only for provably bit-identical reuse:
  (1) factorization-aware Asap reuse for loads-only variations (reuse CHOLMOD factor, re-solve RHS) — to the extent Asap supports it WITHOUT modifying the peer-owned external/Asap submodule;
  (2) MIP warm-start (prior solution as start) in StructuralSizer optimize_discrete — changes time not optimum;
  (3) route read-only caches (ACIColumnCapacityCache, EFMModelCache, AISC capacity) into node warm-state so incremental reruns reuse them.
- Result-changing iterative warm-starts (EFM / punching P-M / beam<->column reconcile) are OPT-IN behind a separate relaxed-tolerance gate, NOT on the exact-first default path.

Execution: autonomous chained coordinator run, high rigor. Wave 1 = recon + exact-first classification (which reuse paths are provably bit-identical + disjoint engineer file scopes) BEFORE any code. Then engineer -> reviewer/critic/tester -> memory. Critic is the load-bearing checker (per Run 2 note: it caught the cache-invalidation bugs).

Hard constraints: do not edit external/Asap; every default-path reuse must pass the existing exact-first verify gates bit-identically; add a new warm-vs-cold bit-identity gate.
