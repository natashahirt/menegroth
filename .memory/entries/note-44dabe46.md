---
id: note-44dabe46
type: note
project: menegroth
parent_id: chec-9b29a05a
title: 'Deferred P2 follow-ups (morning review): silent no-op fallback footgun, untested
  FlatSlabOptions nested-set, dead deflection_limit::Symbol'
node_label: 'Deferred P2 follow-ups (morning review): silent no'
tags: flat-plate,col-i-factor,julia-dispatch,p2,follow-up,change-1
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-44f9458b
created_at: '2026-10-22T05:16:47.957715+00:00'
updated_at: '2026-10-22T05:16:47.957715+00:00'
---
Deferred P2 items from the adversarial critic (crit4 CONCERN, no P0/P1) — for morning review:

**P2-1 — Silent no-op fallback is a latent silent-drop footgun.** The `_apply_col_I_factor` fallback `(AbstractFloorOptions, ::Real)` silently does nothing. Any FUTURE field-bearing floor-options type that forgets to define a specific method would silently IGNORE `column_I_factor` rather than error. Consider either a louder fallback (warn/error for types that should carry the factor) or a dispatch-completeness test that asserts every field-bearing floor-options type has a specific method.

**P2-2 — FlatSlabOptions nested-set not unit-tested in isolation.** The nested set via custom `getproperty` (`@set opts.base.col_I_factor`) is exercised end-to-end by the gate but has no standalone unit test. Worth a focused unit test so a regression there surfaces without running the full gate.

**Separate open question (raised earlier, unrelated to dispatch):** `deflection_limit::Symbol` appears to be consumed NOWHERE in sizing — either dead or an unaudited reader. Worth an audit to confirm it's wired up or remove it.

File touched by the fallback (UNCOMMITTED, not pinned): StructuralSynthesizer/src/design_types.jl
