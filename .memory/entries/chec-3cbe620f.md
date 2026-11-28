---
id: chec-3cbe620f
type: checkpoint
project: menegroth
parent_id: plan-402ca9e9
title: 'Sizing probe instrumentation built + validated (Asap AnalysisLog + SY stage
  labels); speed.md measurement #1 plumbing done, awaiting a quiet machine for the
  real run'
node_label: instrumentation built
tags: instrumentation,speed,measurement,asap,analysislog,sizing_probe,profiling
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f0597650
created_at: '2026-11-20T00:15:43.612970+00:00'
updated_at: '2026-11-20T00:15:43.612970+00:00'
---
Implemented the opt-in instrumentation from phase1-benchmarks.md §4 for speed.md measurement #1 (stage-split the ~699s core-office pipeline).

ASAP (external/Asap, uncommitted on integration/2026-11-18 submodule):
- NEW src/Model/analysis/analysis_log.jl: AnalysisEvent, AnalysisLog, ScopedValues ANALYSIS_LOG/ANALYSIS_LABEL, log_analysis!, with_analysis_log, with_analysis_label. Opt-in; one ScopedValue read when off (zero prod cost).
- analysis.jl: include analysis_log.jl first.
- factorization_cache.jl: log :refactor (in-place cholesky! branch) and :factor (full) in _get_factorization; :factor in factorize!.
- rigidlink.jl: log :factor with n_rhs in solve!(model,links) (n_rhs=1) and solve(model,cases,links) (n_rhs=ncases) — these rigid-diaphragm factorizations were previously invisible to _N_FACTORIZATIONS.

SY (StructuralSynthesizer/src, uncommitted):
- NEW workflow/sizing_probe.jl: SizingProbe, SIZING_PROBE ScopedValue, probe_stage (labels+times a design-graph stage), probe_register_building_model!, with_sizing_probe, probe_report (per-stage table: time + factor/refactor/rhs split building vs other models). NOTE: import 'with' from Base.ScopedValues conflicts with a re-exported identifier in SY — imported as _scoped_with and used qualified.
- StructuralSynthesizer.jl: include workflow/sizing_probe.jl before design_graph.
- design_graph/node.jl: run!(StageNode,...) wrapped in probe_stage(string(node.key)).
- analyze/asap/asap/model_builder.jl: probe_register_building_model!(struc.asap_model) after model creation (covers wall rebuilds automatically).

NEW runner scripts/runners/profile_design_building_stages.jl: core office under with_sizing_probe, prints phase_timings + probe_report.

VALIDATED: Pkg.precompile() clean (Asap+Sizer+Synth), no lints. Smoke test (small 1x1x1 flat plate) produced a correct report: stages foundations/members/ordinary_walls/slab_sizing_s1 labeled, factorizations attributed and split building(3 ids) vs other, slab_sizing dominated (~57%). Absolute times meaningless (ran under heavy CPU contention). Smoke/diag runners deleted.

NOT DONE / BLOCKERS:
- RHS hooks (linear_static.jl, load_case_solves.jl) not added yet (factor/refactor counts are the headline; rhs columns read 0). Also 4c/4d loop+size probes and finer sub-stage labels (fp_column_check, story_shell, wall_jump) deferred.
- The REAL core-office measurement run needs a QUIET machine: during this work the live rib session was running sdf_grid_qualification.jl (pid 13425, 124% CPU) + a test server, so timings are corrupted and running a 15-min profiler steals the user's CPU.
- Full regression on the instrumented tree NOT yet run (concurrent --fresh suites collided on precompile race; killed). Instrumentation is additive/opt-in so behavior-neutrality is expected but unconfirmed.
- Instrumentation is UNCOMMITTED and shares the checkout with the rib session's WIP; committing needs an Asap submodule commit + parent pointer bump on the shared integration branch — flagged to user for coordination.
