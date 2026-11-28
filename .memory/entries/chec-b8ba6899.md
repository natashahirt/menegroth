---
id: chec-b8ba6899
type: checkpoint
project: menegroth
parent_id: plan-382ddd12
title: 'Stage D step 1: StoryStability-from-ELF adapter (story_stability_records)
  — resolves the chec-2363aad1 decision via case-u, green'
node_label: 'Stage D step 1: StoryStability-from-ELF adapter (s'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/story_demands.jl@f6a7ea6, StructuralSynthesizer/test/analyze/test_story_stability_records.jl@f6a7ea6,
  StructuralSynthesizer/test/runtests.jl@f6a7ea6
session_id: sess-3506aa6c
created_at: '2026-11-23T12:00:21.121091+00:00'
updated_at: '2026-11-23T12:00:21.121091+00:00'
---
Resolves the chec-2363aad1 decision point. Instead of decomposing the combined BuildingUnit envelope, the Mnt/Mlt split and story stability are read from the separately-solved lateral cases (the pattern interactive_checks.jl already uses for RC row F: per-case D/L/C gravity + eh lateral via _element_forces_from_u).

This step adds `story_stability_records(analysis::ElfStoryAnalysis; pmf_fraction=0.0) -> Dict{(story,direction), StructuralSizer.StoryStability}` in StructuralSynthesizer/src/analyze/lateral/story_demands.jl. Per (story,direction) it picks the governing (max θ) `:drift` case and builds StoryStability from ΣPu=px_kN (Eq.12.8-18), V=Vx_kN, Δ=elastic_drift_m (first-order), L=story_height_m. Pmf = pmf_fraction·px (AISC RM, Eq.A-8-8; 0 for walls-only).

Key identity (ASCE 7-22 §12.8.7, corpus asce-7-22 p.188): stability_index(record)=Q=Px·Δxe/(hsx·Vx)=θ, i.e. the ACI sway index reproduces the ELF seismic θ. That equality is the regression hook in the new test. First-order (un-amplified) Vx/Δxe used so we never stack on the §12.8.7 1/(1−θ) drift factor.

Pure additive helper; nothing consumes it yet (no production behavior change). Test: analyze/test_story_stability_records.jl (15/15 pass, registered in runtests.jl). Alternative to generalizing row F's rigorous P-Δ to steel — the amplifier path for cases without a full frame second-order solve. Prior-session WIP left untouched and OUT of this commit.
