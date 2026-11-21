---
id: chec-acc65e54
type: checkpoint
project: menegroth
parent_id: plan-bff9aa9f
title: 'Waffle member-stage time attribution: rib sizing KERNEL is only 21.5s/786s
  — real cost is deflection re-analyses (197s) + demand/flange extraction (134s),
  NOT capacity math'
node_label: 'Waffle member-stage time attribution: rib sizing K'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/workflow/member_iteration.jl@639b04e, StructuralSynthesizer/src/analyze/members/members/rib_story.jl@639b04e,
  scripts/runners/profile_waffle_stages.jl@639b04e
session_id: sess-c77c7c25
created_at: '2026-11-21T21:11:30.700205+00:00'
updated_at: '2026-11-21T21:11:30.700205+00:00'
---
Added ENV-gated (SS_MEMBER_TIMING=1) wall-time attribution to the member stage (member_iteration.jl _member_timed/_MEMBER_PHASE_TIMERS, wrapped screen/reanalyze/iterate/verify/report + size_beams/grow_heads/size_columns/update_stiffness; rib_story.jl wrapped _rib_sets+_beam_group_demands+_compute_flange_params as :rib_demands, size_rib_set as :rib_kernel, story_rib_deflection as :rib_deflection). Inert when off (one closure call), so production sizing stays bit-identical. Re-ran grid/x1y1 dense waffle (still 225.1749 kgCO2e/m2, Column 3 shear 1.0 — exact).

MEMBER STAGE 786.8s PARTITION: screen_rib_stems 346.5s (2 calls) + iterate_members 287.4s (1) + report_rib_deflection 19.0s + reanalyze_fe 0.4s. iterate internals: size_beams 164.9s (9), grow_heads 80.9s (9), size_columns 16.5s, update_stiffness 10.3s. CROSS-CUTTING: rib_deflection 196.7s (36 cracked-service Ie-ratchet FE analyses, one per (stem,rho) combo), rib_demands 133.9s (108 calls = 36 sizing sweeps x 3 extraction calls), rib_kernel (size_rib_set) ONLY 21.5s (1822 calls).

KEY: the rib sizing kernel — exactly where Tier 1 memo lives and where Tier 2 catalog/vectorized-matching would act — is 21.5s of 786s (2.7%). That is why Tier 1 was a ~noise-level end-to-end gain. CAPACITY CACHING IS THE WRONG TARGET FOR THE WAFFLE; drop Tier 2. Real levers: (1) deflection screening 196.7s — 36 full story_rib_deflection re-analyses across the (stem,rho') search; cache/prune (ratchet reuse, skip dominated combos, reuse factor). (2) demand/flange extraction 133.9s — _rib_sets/_collinear_rib_groups + _compute_flange_params are topology/geometry-stable (only change when grow_heads adds beams) yet recomputed every one of ~36 sweeps; memoize keyed on topology version. (3) grow_heads 80.9s. Tier 1 kept (exact, harmless, trims kernel allocations).
