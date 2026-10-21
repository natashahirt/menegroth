---
id: chec-6aedbd7e
type: checkpoint
project: menegroth
parent_id: deci-8299ff3e
title: 'Checkpoint: I_factor threading complete + verified; pending full exact-first
  suite rerun and 2 deferred design decisions'
node_label: 'Checkpoint: I_factor threading done'
tags: checkpoint,I_factor,done,pending-suite,deferred-decisions
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/core/size.jl@2a76281, StructuralSynthesizer/src/design_workflow.jl@2a76281,
  StructuralSynthesizer/src/analyze/members/utils.jl@2a76281, scripts/runners/verify_i_factor_threading.jl@2a76281
session_id: sess-1de607c4
created_at: '2026-10-21T23:04:08.313956+00:00'
updated_at: '2026-10-21T23:04:08.313956+00:00'
has_child_rationale: Concluding state summary for the coordinated I_factor threading
  run
---
## Done
Coordinated run (run-ef624ef2) threaded ACI 318-11 §10.10.4.1 cracking factors (`beam_I_factor`/`column_I_factor`) through all concrete mechanical sizing/reconcile paths + the exported `size!` API. Two engineer passes (initial + fix-cycle for `size!`, columns-only branch, P-Δ re-size, per-group column apply). Verified: dedicated gate 22/22 PASS, blind reviewer PASS. Byte-exact no-op at defaults; steel untouched; single application.

## Changed files
- `StructuralSynthesizer/src/core/size.jl`
- `StructuralSynthesizer/src/design_workflow.jl`
- `StructuralSynthesizer/src/analyze/members/utils.jl`
- `scripts/runners/verify_i_factor_threading.jl` (new gate)

## Next / pending
1. **Rerun the full exact-first gate suite** (`run_all_gates.jl`) to confirm no regression across the broader suite — the earlier `verify_design_graph_incremental.jl` exit-1 was a stale run (pre-`05fd814a`), needs a clean rerun.
2. **Not yet committed** — these edits are interleaved with large pre-existing uncommitted work (pattern-case demands, `_reanalyze_after_section_change!` refactor, steel φMn) in the same three files. A commit should record memory first (per protocol) and scope carefully.
3. **Two deferred design decisions for user sign-off:**
   - Flat-plate `FlatPlateOptions.col_I_factor` SSoT vs `params.column_I_factor` (two sources of truth for the same ACI knob).
   - PixelFrame/FRC beam+column cracking behavior (currently inert kwarg; FRC not `<: Concrete`).
