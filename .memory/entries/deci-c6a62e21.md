---
id: deci-c6a62e21
type: decision
project: menegroth
parent_id: plan-f6511c0b
title: 'Phase B build scope refined by recon2: minimal StructuralSizer feasible kwarg
  + steel-beam-only + conditional guard'
node_label: 'Phase B build scope refined by recon2: minimal Str'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-86aa5f77
created_at: '2026-07-15T10:26:53.349771+00:00'
updated_at: '2026-07-15T10:26:53.349771+00:00'
---
recon2 (task-01b6cf6e) verdict:
1. Phase B MUST touch StructuralSizer (not StructuralSynthesizer-only). Public size_beams/size_columns/optimize_discrete take ONE global catalog + ONE checker. Minimal exact-first-safe extension: optional feasible::Vector{Vector{Int}} kwarg on optimize_discrete (both overloads) + thread catalog/feasible through size_columns & size_beams; feasible===nothing reproduces existing behavior byte-identically. Safe because n_max_sections==0 (default) decouples groups -> narrowing one group's feasible set cannot change others. StructuralSynthesizer _size_beams_impl! builds union catalog + per-group AISCChecker + per-group feasible[i] via _first_set precedence.
2. Oracle = design_building-from-scratch-with-override == incremental-with-override (both batched), + direct single-section catalog assertion. Fixture: _build_beam_column/build_beam_column vault (~24 beam groups).
3. Conditional guard: throw iff effective override AND (floor in (:flat_plate,:flat_slab) OR gid kind != :beams). Classify gid by rebuild-then-membership; floor by _infer_floor_type(resolve_floor_options(params)). Params-only sites do floor refusal only; defer gid-kind to prepared-struc choke point.

SCOPE: STEEL beams only this increment (concrete/PixelFrame/T-beam variants deferred; guard refuses them + columns/struts + flat-plate + n_max_sections>0). Update ALL guard call sites (design_types.jl, design_workflow.jl, session.jl, scheduler.jl). Engineer authorized to implement the minimal StructuralSizer feasible-kwarg extension.
