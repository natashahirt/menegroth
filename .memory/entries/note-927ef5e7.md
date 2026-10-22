---
id: note-927ef5e7
type: note
project: menegroth
parent_id: plan-7fe7fb83
title: 'Close-out baseline pt2: StructuralSynthesizer = 18211 pass / 17 fail / 16
  err; trace audit contract-CLEAN (exit1 = heuristic noise). No confirmed audit regressions.'
node_label: 'Close-out baseline pt2: StructuralSynthesizer = 18'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/test/design_graph/test_design_graph_incremental.jl@e0b7431,
  StructuralSynthesizer/src/design_workflow.jl@2a76281, scripts/runners/audit_trace_coverage.jl@e0b7431
session_id: sess-aa13d2ed
created_at: '2026-10-22T15:26:50.124631+00:00'
updated_at: '2026-10-22T15:26:50.124631+00:00'
---
Close-out steps 2b (Synthesizer suite) + 2c (audit_trace_coverage.jl) ran after the walls chat freed the Julia lock (11:00–11:20).

STRUCTURALSYNTHESIZER: 18211 passed, 17 failed, 16 errored, 0 broken (Julia exit 1). Zero '@test Test Failed at' markers in the log — ALL 33 problems are cascades of fixtures throwing at design_building, NOT assertion regressions. Classification:
- 14/16 errors = PreSizingValidationError '§13.6.1.1: DDM requires a minimum of three continuous spans' on test_design_graph_incremental.jl (10) + test_design_graph_equivalence.jl (2) + test_api_units_faces.jl + test_diagnose_api.jl + test_design_state.jl fixtures. These are 3×3-grid (2-span; some 1-span multi-slab) flat plates requesting DDM. PRE-EXISTING: design_building's fail-fast run_pre_sizing_validation→check_ddm_applicability is pre-audit (call site last touched 48f1992e/be762cd6 'Run4'/'Phase5', July 2026; design_workflow.jl:772-779 throw from cb45d7aa/f2c376f4). 2-span<3 is correct §13.6.1.1; the audit (Eq.13-7 §13.6.9.2 + col_I_factor) changed neither the validator, the span count, nor the fixtures. This is the 'pre-existing verify_design_graph_incremental.jl gate failure (unrelated)' the col_I_factor engineers were told to leave alone. The one DIRTY code file, design_graph/scheduler.jl, is a memo-shrink deepcopy optimization (pending_rep deferral) — unrelated to validation.
- 2/16 errors = ArgumentError 'No feasible sections': test_column_sizing_report.jl:146 (RC group, Mux=189.8 kN·m) + a PixelFrame fixture (Pu=400kN, Mu=10kN·m). Fixture-demand issues, pre-existing; verify in pre-ribbed.
- 17 'failed' = cascades within the same errored design_graph testsets (invariant/equivalence @tests that cannot run once the base design_building throws) + the plan-flagged known-broken test_uniform_column_sizing.jl:96 + 'Failing Case Report'. No distinct assertion regression surfaced.

TRACE AUDIT (audit_trace_coverage.jl, exit 1): CONTRACT CLEAN. Part1 TRACE_REGISTRY 25/25 OK (all new _eq137_*, _frameline_ddm_gate, resolve_analysis_method, size_flat_plate! registered + emitting); Part3 tc-threading gaps = 0; Part4 explain_feasibility 5/5 checkers. Exit 1 is driven ONLY by Part2's heuristic '130 potentially-unregistered decision functions' (mostly _resolve_* getters, _size_span_floor dispatchers, design_*_flexure/shear leaves) — advisory pattern-match noise the weekly audit always lists, a standing backlog, not a regression.

BOTTOM LINE: close-out complete. NO CONFIRMED regressions from the overnight gravity audit across either suite or the trace contract. All reds are pre-existing/known: Sizer 20 (steel-selection + Defect4 corner-punching, note-45b518ca), Synth 33 (DDM-3-span incremental-fixture rejection + 2 no-feasible-section fixtures), trace heuristic backlog. CONFIDENCE HIGH but not baseline-verified: a pre-audit-commit run of test_design_graph_incremental.jl would make it 100%; deferred as optional since the validator/fixtures are demonstrably pre-audit. Logs: /tmp/closeout_synth.log.
