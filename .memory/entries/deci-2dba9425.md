---
id: deci-2dba9425
type: decision
project: menegroth
parent_id: deci-498f6f53
title: '#7 phase-2a implemented: non-mutating solve(model,cases,links) reuses the
  model''s reduced factor read-only (kills the 2nd factorization on every pattern/full-load
  solve)'
node_label: '#7 phase-2a implemented: non-mutating solve(model,'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-5ec02b4e
created_at: '2026-11-21T05:44:42.571828+00:00'
updated_at: '2026-11-21T05:44:42.571828+00:00'
---
FINDING: _solve_with_patterns! (pattern_cases.jl) calls _solve_struc_model! (mutating solve!, now caches the reduced factor in model._factorization via phase-1) and IMMEDIATELY calls Asap.solve(model, cases, links) (non-mutating multi-case) which built Krr and factorized FRESH again. The plain multi-case Krr (geometric_stiffness===nothing && !exclude_shells) is byte-identical to solve!'s (same retained_free = setdiff(freeDOFs, dependent), same Sc). So the second factorization was pure duplicate on EVERY pattern-based building re-solve (member hot path) and full-load lateral solves (gravity_basic_cases, foundation_reactions, wind/elf full-load).

FIX (external/Asap/src/Elements/rigidlink.jl, solve(model,cases,links)): for the plain reduced system, if model._factorization is a current CHOLMOD.Factor (not stale, _factor_key == _reduced_factor_pattern_key(model,Krr,retained_free), key!=0), REUSE it read-only (Ur = fact \ Fr) instead of factoring. Honors the non-mutating contract: reads model._factorization, never writes model.u/P/_factorization; CHOLMOD \ does not mutate the factor; building model solved sequentially => no aliasing. geometric_stiffness (P-delta) and exclude_shells variants build a different matrix and still factor fresh.

PHASE 2b (deferred): cross-call cache for the Kg/exclude_shells wall solves needs an external RigidLinkFactorCache handle on BuildingStructure; within a call they already reuse one factor across the RHS fan.

VERIFY: Asap rigidlink/diaphragm/pdelta/mixed/factor-cache suites; member-stage golden 299 bit-identical with phase-2a. (#19 golden proof running separately.)
