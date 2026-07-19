---
id: deci-2ecc5d5e
type: decision
project: menegroth
parent_id: deci-b3488473
title: 'Cycle-7 critic FAIL: symmetric method=:nlp gap → cycle 8 inverts guard to
  positive honor-path allowlist'
node_label: 'Cycle-7 critic FAIL: symmetric method=:nlp gap → c'
tags: ''
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-06cfb857
created_at: '2026-07-18T01:43:48.165061+00:00'
updated_at: '2026-07-18T02:14:59.022178+00:00'
---
Cycle-7 re-review: reviewer PASS (351/351, all guard paths + numeric identity verified), critic FAIL.

Critic (edafab8b) finding:
[P1] The cycle-7 size_beams! guard keys ONLY on effective_opts.sizing_strategy != :discrete. But strategy = (method !== nothing) ? method : opts.sizing_strategy. A forced method=:nlp over DEFAULT :discrete steel opts + effective override: opts.sizing_strategy==:discrete → guard SKIPPED → strategy=:nlp → dispatch _size_beams_impl!(::SteelBeamOptions, ::Val{:nlp}) which does NOT exist → bare MethodError, not the pinned member_group_overrides ArgumentError. Same class as the original :nlp MethodError P2, reached via the method kwarg. NOTE: this is LOUD (crash), NOT a silent drop — so it is a contract-completeness gap (wrong error type), not a safety-critical unconservative-design bug like cycle-6's silent drop.
[P2] No test covers method=:nlp + default steel opts + effective override.
[P2] Refusal message hard-codes 'steel beam options set sizing_strategy=...' but ConcreteBeamOptions also has sizing_strategy (options.jl:217), so the message misfires (wrong material) on a concrete-nlp direct call.

CYCLE-8 FIX (invert to positive allowlist — fixes the class, all in utils.jl + tests):
1. Replace the enumerated-refusal size_beams! guard with a POSITIVE honor-path allowlist: when there is an EFFECTIVE member_group_override, PROCEED only if effective_opts isa StructuralSizer.SteelBeamOptions && strategy == :discrete (resolved var) && effective_opts.sizing_strategy == :discrete; OTHERWISE throw the pinned member_group_overrides ArgumentError. This is the ONLY path that honors overrides (steel-discrete batched size_beams! + size-time gid gate + union catalog/feasible). Covers BOTH method directions, pure :nlp, non-steel opts (closes latent concrete-direct silent-drop/methoderror), in one condition.
2. Generic refusal message including typeof(effective_opts), resolved strategy, and opts.sizing_strategy (if present) — fixes the steel-worded-message P2.
3. Keep the size-time gid gate (gid membership / multi-material / looseness / composite) unchanged; keep the (4b) defense-in-depth mirror.
4. Byte-identity: no/vacuous override → allowlist not triggered (any(_is_effective) short-circuits) → unchanged (pure :nlp no-override still MethodErrors as before); normal steel-discrete pipeline with effective override → allowlist passes → proceeds to gid gate, byte-identical.
5. Tests: add method=:nlp + default steel opts + effective override → pinned; concrete opts + effective override (direct) → pinned; keep method=:discrete-over-:nlp, pure-:nlp, vacuous-byte-identity, steel-discrete-honored, signed-zero/reduced-Ix. Pin all throws to occursin('member_group_overrides', sprint(showerror,e)).

Gates: Gate1 (>351 with new cases), Gate2 127+, Gate3 17/17.

NOTE ON STOPPING: this slipped past the 'cycle 7 is last' estimate. The allowlist closes the divergence CLASS (both nondeterministic inputs + material), so there is no remaining symmetric direction to exploit — intended to be the terminal cycle.
