---
id: chec-dcc7e774
type: checkpoint
project: menegroth
parent_id: note-cc000005
title: T2.4 + T3 kgCO₂e Unitful refactor complete — 828/828 tests pass
node_label: T2.4 + T3 kgCO₂e Unitful refactor complete — 828/8
tags: kgco2e, unitful, embodied-carbon, checkpoint, refactor, structural-studies,
  synthesizer
status: active
open_threads: 0
success: 'null'
files: StructuralStudies/src/init.jl@6694321, StructuralStudies/src/column_properties/column_parametric_study.jl@6694321,
  StructuralStudies/Project.toml@6694321, StructuralSynthesizer/test/core/test_postprocess_ec.jl@5109398
session_id: sess-302ce237
created_at: '2026-07-13T00:31:13.443493+00:00'
updated_at: '2026-07-13T00:31:13.443493+00:00'
---
## kgCO₂e Unitful Refactor — T2.4 + T3 Complete

Run run-900be755 finished 4/5 tasks (1 cancelled), 0 failures, 0 extensions.

### What's done
- **T2.4 validation:** EC serialization tests (34/34) pass; `test_postprocess_ec.jl` fixed to add `using Asap`
- **T3 StructuralStudies sweep:** `CARBON_*` constants typed as `Quantity{Float64, kgCO2e}`, `calc_embodied_carbon` returns typed quantities, strip at DataFrame boundary in `column_parametric_study.jl`
- **Full test suite:** 828/828 kgCO2e tests pass, smoke suites (ecc distributions, sweep, section 2 figs) all green
- **Workspace blocker resolved:** Stalled run-be6982c4 (AISC extraction scribe) workspace lease finalized

### Deferred (not blocking)
- P1: `@isdefined` REPL guard can expose stale Float64 constants in long-running sessions
- P1: `using Asap` namespace breadth in `init.jl`
- P2: No dimension assertion on `CARBON_*` at load time

### Files changed
- `StructuralStudies/src/init.jl`
- `StructuralStudies/src/column_properties/column_parametric_study.jl`
- `StructuralStudies/Project.toml`
- `StructuralSynthesizer/test/core/test_postprocess_ec.jl`
