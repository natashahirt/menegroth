---
id: note-f1a7f0dd
type: note
project: menegroth
parent_id: deci-77318f68
title: Deferred critic concerns from T3 kgCO₂e refactor (run-900be755)
node_label: Deferred critic concerns from T3 kgCO₂e refactor (
tags: kgco2e, unitful, technical-debt, deferred, critic
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-302ce237
created_at: '2026-07-13T00:30:50.816653+00:00'
updated_at: '2026-07-13T00:30:50.816653+00:00'
---
The critic raised two P1 and one P2 concern — deferred, not blocking. Track for a future cleanup pass:

**P1 — Stale `@isdefined` REPL guard:** If an older session has Float64 versions of the `CARBON_*` constants loaded in a running REPL, the guard will silently skip re-definition of the typed Quantity versions, leaving stale Float64 values active. Risk surfaces only in interactive use, not in fresh `using StructuralStudies` loads.

**P1 — Broad `using Asap` namespace:** Adding `using Asap` to `StructuralStudies/src/init.jl` pulls the entire Asap namespace into scope to access `u"kgCO2e"`. Consider scoping to `using Asap: @u_str` or the specific unit macro once the API is stable.

**P2 — No dimension assertion on CARBON constants:** Constants are typed but not validated against a unit dimension guard at definition time. A future `@assert dimension(CARBON_CONCRETE) == dimension(u"kgCO2e")` or equivalent would catch unit-kind regressions at load time.
