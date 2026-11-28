---
id: chec-bdc5fee3
type: checkpoint
project: menegroth
parent_id: deci-498f6f53
title: '#7 phase-1 implemented; Asap rigid-link/diaphragm/pdelta/factor-cache suites
  green (239/239)'
node_label: '#7 phase-1 implemented; Asap rigid-link/diaphragm/'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-465a2ef3
created_at: '2026-11-21T03:46:10.358327+00:00'
updated_at: '2026-11-21T03:46:10.358327+00:00'
---
Implemented #7 phase 1 (mutating solve! path):
- external/Asap/src/Model/analysis/factorization_cache.jl: added _reduced_factor_pattern_key(model, Krr, retained_free) = hash((objectid(model.S), nnz(model.S), retained_free, Krr.data.colptr, Krr.data.rowval)) and _get_reduced_factorization!(model, Krr, retained_free). The helper does cholesky!(old, Krr) in-place (reuse symbolic) when the reduced pattern key matches, else a fresh cholesky -> ldlt -> lu(Krr.data) ladder. DELIBERATELY NO blind fast-path: it always recomputes numerics from the CURRENT Krr, so the returned factor is exact regardless of why Krr changed; reuse is of symbolic (pattern) work only. Caches in the model's existing _factorization/_factorization_stale/_factor_key slots (the link path owns them; no Model struct change).
- external/Asap/src/Elements/rigidlink.jl: solve!(model, links) now calls _get_reduced_factorization! instead of a raw fresh cholesky, and KEEPS the reduced factor (no longer nulls model._factorization). Lifecycle driven by existing update!(values_only) -> stale and full update!/process! -> null.

PHASE 2 (non-mutating solve(model,cases,links)) left unchanged (already reuses one factor across cases per call; cross-call cache deferred).

VERIFICATION so far:
- scripts/runners/test_rigidlink_factor_cache.jl (external/Asap project): rigidlink closed-form + factorization_cache + diaphragm + nonlinear/pdelta + mixed_model = 239/239 PASS. Closed-form cantilever displacement checks and update!(values_only) re-solve cycle validate exactness; diaphragm + iterative pdelta validate the building rigid-link path.
- PENDING: StructuralSynthesizer core/test_flat_plate_member_stage.jl (299 golden, bit-identical) running fresh against the new Asap -- the building-level exactness proof for #7 + #18 together.
