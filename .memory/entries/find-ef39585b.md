---
id: find-ef39585b
type: finding
project: menegroth
parent_id: menegroth
title: 'integration/2026-11-18: flat-plate member stage does not settle (48-round
  cap) — blocks core-office measurement, 85 Synth failures, 71-min slab regression'
node_label: 'integration/2026-11-18: flat-plate member stage do'
tags: flat-plate,member-stage,non-convergence,s2-floor,s2-commit,regression,speed-audit,measurement-blocked
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-37cec815
created_at: '2026-11-20T13:36:42.758970+00:00'
updated_at: '2026-11-20T13:36:42.758970+00:00'
---
**Symptom** (thrown from `graph_builder.jl:413` `_design_flat_plate_members!`):
```
flat-plate member stage did not settle: after 48 rounds,
slabs [1,2,3] were still checked at smaller columns than are installed
```

**Impact on current integration (HEAD e52336c7, instrumented tree):**
- **Core-office measurement blocked**: `profile_design_building_stages.jl` installs the probe correctly (ScopedValues fire — visible in the stacktrace) but `design_building` throws this error before any stage report is produced. No timings obtained.
- **Full StructuralSynthesizer regression: 26262 passed, 32 failed, 53 errored** (18100s; the `Slab system regression` testset alone = 71m). Dominant cause is this same 'did not settle' error cascading through `test_design_graph_equivalence.jl:228` (flat-plate DDM reconcile columns / per-story harmonize), `test_design_graph_incremental.jl` (base session == design_building; shared-column slabs propose/envelope/commit/lock), `test_member_hierarchy.jl:56`, `test_design_state.jl`, plus rib/vault (`test_api_units_faces.jl` vault scoped override).

**Root cause = the open s2 work, not instrumentation.** This is exactly the PENDING `s2-floor` (stored per-column floor; search may shrink below installed) and `s2-commit` (shared-column commit pass must hold columns fixed) items: the member stage oscillates because slabs are re-checked at columns smaller than what is installed, never reaching a fixed point, so the 48-round guard trips.

**Instrumentation cleared**: `probe_stage` is `p === nothing && return f()` (pass-through when no probe installed, i.e. the whole test suite). Behavior-neutral; the Sizer run (16370 pass) corroborates. The 85 failures are independent of the sizing-probe commit.

**Consequence for speed.md #1**: cannot stage-split the flat-plate core office until the s2 member-stage settling is fixed. To get a measurement now, profile a converging configuration (steel / composite core office) instead, or land s2 first. Logs: `logs/profile_stages.txt`, `logs/test_StructuralSynthesizer_20261119_230346.log`.
