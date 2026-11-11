---
id: plan-9633da9d
type: plan
project: menegroth
parent_id: plan-a79eb74f
title: 'Handoff for implementing agent: sizing Phase 0-1 work packages (read docs/sizing-map/handoff-phase0-1.md)'
node_label: Phase 0-1 handoff
tags: sizing,handoff,phase-0,phase-1,delegated,safety,carbon,instrumentation,benchmarks,plan
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/handoff-phase0-1.md@2be2c47
session_id: sess-4672ff25
created_at: '2026-11-11T21:55:44.984927+00:00'
updated_at: '2026-11-11T21:55:44.984927+00:00'
has_child_rationale: Delegated implementation of the first two phases
---
Implementing agent: read docs/sizing-map/handoff-phase0-1.md in full, then plan.md, architecture.md and phase1-benchmarks.md. Do one work package at a time on branch sizing/wp-<id>, write docs/sizing-map/reports/wp-<id>.md, and stop for audit.

Order:
- Wave A (parallel): 0.1 steel Cm (column end moments, unknown curvature Cm = 1.0, beams transverse_load interim Cm = 1.0); 0.3 cladding wall_SDL; 0.5 rigid mat strip statics; 0.6+0.7 wall carbon and drop-panel/stud split; 1.1+1.2 analysis log + SizingProbe; 1.3 benchmark fixtures B1-B5, B7.
- Wave B: 0.4a per-case support reactions (no behaviour change), then 0.4b foundation load combinations.
- Wave C: 1.4 baseline runner, then 1.5 O2/O4 metrics.

Each WP lists 'Ask before deciding' items: these go to the user, never defaulted. Code-derived work needs corpus citations and hand-calc tests (code-accuracy.mdc, corpus.mdc).

Not delegated (lead agent): 0.2 Cm by analysis, 0.8 vertical-floor safety-gap triage, 1.6 baseline freeze, Phase 2 interface spec, B6 fixture proposal. Phase 7 briefed after the baseline.
