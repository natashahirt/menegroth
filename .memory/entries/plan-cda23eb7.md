---
id: plan-cda23eb7
type: plan
project: menegroth
parent_id: plan-5d8af001
title: 'Run 4 (Option A): per-MemberGroup override parameters for independent per-group
  variation'
node_label: 'Run 4 (Option A): per-MemberGroup override paramet'
tags: ''
status: active
open_threads: 3
success: 'null'
files: StructuralSynthesizer/src/design_workflow.jl@8e34430, StructuralSynthesizer/src/design_graph/provenance.jl@2f7c9fd,
  StructuralSynthesizer/src/design_graph/fingerprint.jl@2f7c9fd
session_id: sess-a0606b76
created_at: '2026-07-14T17:17:59.426491+00:00'
updated_at: '2026-07-14T20:44:17.583357+00:00'
---
User-approved Option A, building on Run 3's fine-node + barrier-sync + exact-first-guard foundation. GOAL: add NON-prepare-affecting per-MemberGroup override parameters — primary dimension per user = per-MemberGroup catalog / objective / utilization overrides (e.g. member_catalog_objective) — and split the coarse :members node into FINE per-MemberGroup nodes so changing ONE member group's catalog/objective/utilization recomputes ONLY that group's node (+ genuinely dependent downstream) and is output-equivalent to from-scratch.

WHY THIS SCOPE (defer per-slab): members are a DOWNSTREAM stage (:members depends on all slab keys; :foundations on :members), so per-MemberGroup catalog/objective/utilization variation is expected to be cleanly separable and NOT require the slab grow-then-size two-pass. Per-SLAB independent variation (which DOES need the two-pass + a real P-M capacity comparison to replace the As_total proxy) is DEFERRED to a later run; Run 3's guard safely REJECTS partial-slab targets until then. Explore must CONFIRM this separability (watch the slab<->column reconcile / harmonize coupling — if a member-group change feeds back into columns shared with slabs, the coupled set must be correctly invalidated).

HARD (exact-first spine, unchanged): design_building BYTE-IDENTICAL; every incremental path OUTPUT-EQUIVALENT (per-member design_signature, rtol=1e-8) to from-scratch. The new override params MUST be non-prepare-affecting (do not alter the prepared model structure) — explore/eng must verify they belong in a param slice, NOT PREPARE_AFFECTING_FIELDS, and that per-MemberGroup provenance folds the group-specific override so a change dirties only that group.

GRAPH: explore (map param threading + fine per-MemberGroup node decomposition + separability/coupling) -> eng (implement, opus, exact-first gated) -> reviewer + critic + tester (critic load-bearing per note-d764db1d) -> memory. Chained coordinator run, autonomous per the overnight mandate.
