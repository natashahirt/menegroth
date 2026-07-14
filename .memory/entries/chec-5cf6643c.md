---
id: chec-5cf6643c
type: checkpoint
project: menegroth
parent_id: plan-cda23eb7
title: 'Run 4 COMPLETE: member_group_overrides Part-1 seam shipped with a choke-point
  fail-loud guard; per-group activation deferred to Phase B'
node_label: 'Run 4 COMPLETE: member_group_overrides Part-1 seam'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design_workflow.jl@be762cd, StructuralSynthesizer/src/design_types.jl@be762cd,
  StructuralSynthesizer/src/analyze/members/utils.jl@be762cd, StructuralSynthesizer/src/StructuralSynthesizer.jl@be762cd,
  StructuralSynthesizer/src/design_graph/session.jl@be762cd, StructuralSynthesizer/src/design_graph/scheduler.jl@be762cd,
  StructuralSynthesizer/test/design_graph/test_design_graph_incremental.jl@8a6aad6,
  scripts/runners/verify_design_graph_incremental.jl@be762cd
session_id: sess-dad658a4
created_at: '2026-07-14T20:44:05.780321+00:00'
updated_at: '2026-07-14T20:44:05.780321+00:00'
---
Run 4 (dag-run-4) is complete and verified. DELIVERED (Part 1): DesignParameters.member_group_overrides::Dict{UInt64,MemberGroupSizingOverride}(catalog/deflection_limit/max_depth), default empty => byte-identical; resolve_member_group_override accessor; an override kwarg on size_member_group! resolved via 3-level _first_set precedence (override entry -> MemberGroup.catalog_override -> global default). Exported MemberGroupSizingOverride + resolve_member_group_override.

LOAD-BEARING FINDING (independently confirmed by reviewer + critic): design_building does NOT route member sizing through size_member_group! — it uses batched size_beams! / global size_columns! MIP / flat-plate _reconcile_columns!. So member_group_overrides is NOT honored by a standard design; the explore's 'clean beam-group slice via size_member_group!' does not exist in the real pipeline. This correctly collapsed Run 4 to Part-1-only (the parameter + resolution SEAM), with per-group activation deferred as the coupled-sizer work (Phase B).

SAFETY SAGA (3 fix cycles): the critic caught that member_group_overrides was a public/exported knob silently ignored by design_building (silent mis-specification = unsafe). Remedy = fail LOUD: a shared _assert_member_group_overrides_unsupported(params) throwing ArgumentError when the dict is non-empty AND any override is EFFECTIVE (any of catalog/deflection_limit/max_depth non-nothing; an all-unset entry is a documented no-op). Guard cycles: (1) added at run_pre_sizing_validation (design_building x2 + prepare_engine + DesignSession); (2) path-completed to the variation/sweep API (redesign, vary->redesign, redesign_incremental!) after the critic found those bypassed it; (3) placed at the UNIVERSAL choke point capture_design after the critic found the primitive paths build_design_graph->execute_graph!->capture_design and run_target!+capture_incremental_design still bypassed the wrappers. capture_design verified as the sole BuildingDesign(struc,params) materialization; every exported pipeline/variation/API path routes through it. member_group_overrides stays NON-prepare-affecting (out of PREPARE_AFFECTING_FIELDS + all param_slices).

ACCEPTED RESIDUAL (P2, non-blocking): the guard is at the workflow layer (capture_design), not inside the exported BuildingDesign(struc,params) constructor, so universality is 'by convention' — one refactor away. Not raised to P1 because the bare constructor yields an empty/unsized/unusable design. Follow-up recorded to make it structural.

VERIFICATION: all four gates green under Julia 1.12.1 (target 1.12.4, not installed): verify_design_graph 15/15, verify_incremental_engine 17/17, verify_design_graph_incremental 68/68 (incl new section [12] + both primitive-path throw checks), in-suite test_design_graph_incremental 250/250. size_member_group! honoring is non-vacuous (free=W16X26 vs override=W21X44). Coordinator extensions used: 3/5 (all critic-driven, all closed).

DEFERRED: Phase B (wire overrides into the coupled sizers — per-column-group MIP split, flat-plate column overrides in the slab stage, a fixpoint node for the beam-column iteration so per-group nodes are exact-first); Phase C (per-slab independent variation + grow-then-size two-pass + P-M capacity comparison).
