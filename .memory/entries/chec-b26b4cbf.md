---
id: chec-b26b4cbf
type: checkpoint
project: menegroth
parent_id: plan-7b305650
title: 'Sway crash fixed: flat-plate sway k retired to 1.0 (no alignment chart); real-Q
  + lateral verdict already in place'
node_label: 'Sway crash fixed: flat-plate sway k retired to 1.0'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/column_bracing.jl@edbdd34,
  StructuralSynthesizer/test/analyze/test_wave2_sensitivity.jl@edbdd34
session_id: sess-2b5219f8
created_at: '2026-11-22T16:38:15.445489+00:00'
updated_at: '2026-11-22T16:38:15.445489+00:00'
---
User chose 'inherit wall-stage Q, governing direction'. Deep recon showed the full generic §10.10.7 machinery collapses to a surgical crash-fix for this codebase, because flat-plate columns carry NO sway moment (Ms=0 — beam-lines keep placeholder sections; the shear-wall core takes sidesway; confirmed in flat_plate_column_check.jl header).

Key consequence: §10.10.7.3 Q-method gives M = Mns + δs·Ms = Mns, and the along-length P-δ check uses the braced k. So k = 1.0 EITHER WAY — braced (R10.10.6.3) when nonsway, the §10.10.7.2 minimum (k≥1.0) when sway. The sway classification's only distinct effects are (a) NOT calling the alignment chart (the crash: ψ→∞ on pinned footings → 'no finite k' ArgumentError) and (b) the instability verdict.

CHANGE (StructuralSizer/.../flat_plate/utils/column_bracing.jl): flat_plate_column_geometry sway branch no longer calls alignment_chart_k / _flat_plate_axis_k. Returns ConcreteMemberGeometry(L; kx=1.0, ky=1.0, braced=!sway). Removed now-dead chart helpers (_flat_plate_axis_k, _flat_plate_joint_ψ, _framing_span_count, _spans_along) and constants. General alignment_chart_k in slenderness.jl KEPT (still used/tested). flat_plate_story_is_sway unchanged — already uses real Q from col.story_properties when present, else wall-presence proxy.

WHY no new checker/Q-wiring code:
- Cored building → walls meet slab → supporting_wall_segments non-empty → proxy NONSWAY → braced k=1 → designs cleanly. Primary goal met by crash-fix alone.
- S6 clean lateral error ALREADY EXISTS: wall stage throws on θ>θmax (ASCE 7-22 §12.8.7) via _max_drift_theta/require_seismic_wall_demand_provisions/_check_frame_only_stability!; drift failures drive wall-thickness growth. That IS 'check the lateral system works, then error'.
- magnify_moment_sway_complete with Ms=0 returns identical strength to nonsway k=1; wiring it into the shared RC checker would add regression risk across ALL columns for zero numeric change → deliberately NOT done.

TEST MIGRATION: test_wave2_sensitivity.jl 'Sway k moves...' → 'Flat-plate k and the sway designation follow Q'. New contract: sway & nonsway both k=1.0; story only flips `braced`. Chart-sensitivity asserts removed. PASSES 15/15 (fresh). Header updated.

VERIFY: migrated testset 15/15 PASS. member-stage flat-plate suite (299 gate) running fresh. Pre-existing UNRELATED fail in same file: 'Pattern live...' norms ordering at L150 (checkerboard displacement; orthogonal to bracing).

SCOPED-OUT (per safety rule, not guessed): per-story real-Q repopulation into col.story_properties from the wall solve (S2). Blockers: OrdinaryWallResult exposes per-story seismic DESIGN drift (Cd-amplified) + max_story_stability θ, NOT per-story Vus; drift seismic-only (wind separate). Low marginal value for flat-plate. Follow-up only if lateral-moment-carrying columns are added.
