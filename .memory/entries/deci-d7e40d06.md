---
id: deci-d7e40d06
type: decision
project: menegroth
parent_id: note-cc000005
title: 'kgCO₂e init.jl: deferred critic fixes (guard, import, naming, asserts)'
node_label: 'kgCO₂e init.jl: deferred critic fixes (guard, impo'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralStudies/src/init.jl@ce07cb9
session_id: sess-d919e328
created_at: '2026-07-13T02:01:48.556354+00:00'
updated_at: '2026-07-13T02:01:48.556354+00:00'
---
Addressed coordinator critic CONCERN items in StructuralStudies init.jl: versioned init guard (v2) replaces boolean @isdefined to fix stale REPL constants; `import Asap` instead of `using`; renamed CARBON_* constants to *_KGCO2E_*; added dimension assertions on calc_embodied_carbon return.
