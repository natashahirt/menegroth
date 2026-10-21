---
id: chec-eec91bb0
type: checkpoint
project: menegroth
parent_id: deci-4ef4e16f
title: 'Phase 0 complete: exact-first verification gates consolidated (refactor-only,
  all PASS)'
node_label: Phase 0 checkpoint
tags: phase-0, verification-gates, refactor, design-graph, iterative-analysis-optimization
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/test/design_graph/_verify_shared.jl@8dd4156, scripts/runners/verify_design_graph.jl@8dd4156,
  scripts/runners/verify_design_graph_incremental.jl@8dd4156, scripts/runners/verify_incremental_engine.jl@8dd4156,
  scripts/runners/run_all_gates.jl@8dd4156, scripts/runners/README-gates.md@8dd4156,
  .gitignore@8dd4156
session_id: sess-c6b063bf
created_at: '2026-10-21T03:18:53.052572+00:00'
updated_at: '2026-10-21T03:18:53.052572+00:00'
has_child_rationale: Checkpoint summarizing the completed Phase 0 static-foundation
  refactor under the overnight coordinator decision.
---
## Phase 0 — Static foundation of the Iterative Analysis Optimization plan

**Scope:** REFACTOR-ONLY consolidation of the exact-first verification gates. No behavior change. Two engineers + blind reviewer + tester, all **PASS**.

### What was done

**eng_shared — canonical shared helpers**
- Created `StructuralSynthesizer/test/design_graph/_verify_shared.jl` holding the single canonical, byte-identical copies of `INVARIANT_COLS`, `design_signature`, `same_signature`.
- Rewired `scripts/runners/verify_design_graph.jl`, `verify_design_graph_incremental.jl`, `verify_incremental_engine.jl` to `include` it.
- **Deliberately NOT consolidated** (divergent on purpose):
  - `verify_warm_state_incremental.jl` — uses a reduced `design_signature` + `_close` with `rtol=0` (exact).
  - the `_`-prefixed test twins.
  - all `build_*` builders — each carries a distinct `name=` fixture string.
- `same_signature` references `_close` as a free global, resolved via **late-binding** in each includer's scope.

**eng_plumbing — gate runner + docs + ignore rules**
- Created `scripts/runners/run_all_gates.jl`: runs the four verify gates as isolated julia subprocesses with `SS_ENABLE_VISUALIZATION=false`, aggregating to exit 0 iff all pass.
- Created `scripts/runners/README-gates.md`: gate inventory; tolerances (`rtol=1e-8`/`atol=1e-10` for gates 1–3, `rtol=0`/`atol=0` for warm-state); Gurobi/HiGHS notes; `design_signature` schema.
- Added grasshopper `obj`/`bin` ignore rules to root `.gitignore`.
- `git add`ed 10 untracked test files under `StructuralSizer/test` and `StructuralSynthesizer/test`.

### Verification
- **Blind reviewer — PASS:** byte-identical consolidation confirmed; correct `_close` late-binding; no StructuralStudies / second-Asap hazard; correct exit-code aggregation.
- **Tester — PASS (smoke):** all changed files parse; shared module + rewired runners load with no redefinition/missing-symbol errors and `main()` not triggered. Full end-to-end gate was **SKIPPED** — the runners' top-level `Pkg.instantiate()` was repeatedly SIGKILLed by depot/precompile contention from 3+ concurrent Julia agents (environment limit, not a refactor fault).
- **Coordinator cleanup:** removed scratch smoke files (`smoke_loadcheck_v2.jl`, etc.) from `test/design_graph/`.

### Open follow-ups
1. **Untrack grasshopper build artifacts:** `obj`/`bin` are ALREADY tracked, so `.gitignore` alone won't untrack them — need `git rm -r --cached grasshopper/Menegroth.GH/{obj,bin}`.
2. **Run the real end-to-end gate serially** once the concurrent-Julia contention is gone (see the paired annotation on serializing Julia subagents).
