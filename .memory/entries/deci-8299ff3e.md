---
id: deci-8299ff3e
type: decision
project: menegroth
parent_id: todo-155dcab2
title: Threaded ACI 318-11 §10.10.4.1 cracking factors (beam_I_factor/column_I_factor)
  end-to-end; knobs now honored, byte-exact no-op at defaults
node_label: 'I_factor threading: knobs honored'
tags: aci-318-11,cracking-stiffness,I_factor,concrete,sizing,design-workflow,no-op-parity
status: active
open_threads: 3
success: 'null'
files: StructuralSynthesizer/src/core/size.jl@2a76281, StructuralSynthesizer/src/design_workflow.jl@2a76281,
  StructuralSynthesizer/src/analyze/members/utils.jl@2a76281, scripts/runners/verify_i_factor_threading.jl@2a76281
session_id: sess-1de607c4
created_at: '2026-10-21T23:03:04.529524+00:00'
updated_at: '2026-10-21T23:20:01.992730+00:00'
has_child_rationale: Records the resolved design/implementation outcome of the coordinated
  I_factor threading work
---
## Problem
`params.beam_I_factor` (default 0.35) and `params.column_I_factor` (default 0.70) were **dead knobs**: changing these `DesignParameters` fields had no effect because the concrete `to_asap_section` builders applied the cracking reduction from **hardcoded defaults** (0.35 beams / 0.70 columns) that happened to equal the param defaults. Default behavior was physically correct per ACI 318-11 §10.10.4.1 (0.70 Ig columns, 0.35 Ig beams), but the parameters were never forwarded.

## Resolution
Threaded the `I_factor` kwarg from `DesignParameters` down through every **concrete** mechanical sizing/reconcile path to the Asap section builders, concrete-only, leaving steel untouched.

### Edits (two engineer passes)
- **design_workflow.jl**: `_reconcile_columns!` :909 hardcoded 0.70 → `params.column_I_factor`; `size_columns!`/`size_beams!` calls thread `params.column_I_factor`/`params.beam_I_factor`; `_run_p_delta_if_needed!` gained `I_factor::Real = 0.70` kwarg forwarded to its internal P-Δ `size_columns!`, both call sites (columns-only branch + main path) pass `params.column_I_factor`.
- **analyze/members/utils.jl**: `_apply_beam_results!` gained `I_factor::Real = 0.35` kwarg applied only when `group_mat isa Concrete`; `_size_beams_impl!` forwards it into apply + concrete-NLP inline `to_asap_section`; `_apply_column_results!` rewritten to branch **per group** on `group_mat isa Concrete` (instead of the prior function-level `material_type === :concrete`), so a steel section in a multi-material result never receives `I_factor`.
- **core/size.jl**: exported `size!` API passes `I_factor = params.beam_I_factor`/`params.column_I_factor` (params = design.params in scope).

## Invariants held
1. **Byte-exact no-op at defaults** (0.35 beams / 0.70 columns) — the threaded values reduce to the prior hardcoded `to_asap_section` overload defaults.
2. **Steel safety** — `I_factor` is never passed to a `Metal` `to_asap_section` overload (no kwarg there; would MethodError). The per-group `isa Concrete` branch guarantees this.
3. **Single application** — reduction lives solely inside `to_asap_section`, invoked once per group per path; `reanalyze`/`_reanalyze_after_section_change!` only re-solve with already-set sections.

## Deliberately deferred (open design decisions, NOT changed)
- Flat-plate `FlatPlateOptions.col_I_factor` SSoT vs `params.column_I_factor` (two sources of truth).
- PixelFrame/FRC beam+column cracking behavior (PixelFrame overloads gained only an **inert** `I_factor` kwarg for uniform dispatch; FRC = `FiberReinforcedConcrete`, not `<: Concrete`, routes to the else-branch). Needs engineering sign-off before unifying.

## Citation
ACI 318-11 §10.10.4.1 — cracked-section stiffness for elastic second-order frame analysis: 0.70 Ig (columns), 0.35 Ig (beams), 0.25 Ig (flat plates/slabs).
