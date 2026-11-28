---
id: expe-d7ec85aa
type: experiment
project: menegroth
parent_id: expe-48ab4ba1
title: 'Slice 2 kernel: FE self-weight influence coefficients reproduce full re-solve
  column axial to 1e-11 on an indeterminate frame'
node_label: 'Slice 2 kernel: FE self-weight influence coefficie'
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/selfweight_influence_proving_slice.jl@e142eca
session_id: sess-278ee43a
created_at: '2026-11-26T03:53:38.612326+00:00'
updated_at: '2026-11-26T03:53:38.612326+00:00'
---
Slice 2 (productionize self-weight coupling into the REAL member stage) chosen scope = Option B, the GENERAL FE-influence version (user picked it over the determinate-stack approximation and the StructuralSizer-API-only boundary).

KEY INSIGHT: in the real pipeline column axial demand (Pu_c) is an FE REACTION read off the solved Asap model by member_group_demands -> ElementForceAndDisplacement, NOT an explicit accumulation. For a linear-elastic model the internal axial at column i is a linear functional of the load vector: P_i = base_i + sum_j phi_ij * W_j(section_j), where W_j = rho*g*L*A(s) and phi_ij is a constant of the frozen-stiffness model. The self-weight SHAPE is section-independent, so f_j^unit = -Pf_j (negated fixed-end contribution, built via Asap.populate_load!) scaled by W_j(s) is exact for any candidate section.

COMPUTE: phi via the FORWARD method -- Asap.linear_response(model, f_j^unit) is ONE back-substitution per source on the cached factorization (no refactorization, reuses the drift_participation infra), and each target's axial is read with the production recovery path (mirrors _element_forces_from_u). No Asap submodule change needed; no hand-derived sensitivity row.

PROVING SLICE (scripts/runners/selfweight_influence_proving_slice.jl): on an INDETERMINATE 4-story x 2-bay fixed-base moment frame, the influence-predicted delta column axial under a +40kN self-weight change matches an independent fresh full re-solve to max relative error 6.7e-11 across all 144 (source,target) pairs. A column's own +40000 N shows as 39983 N on itself -- the ~17 N that redistributes through the indeterminate frame is captured EXACTLY, which a determinate-stack accumulation (Slices 0/1) would miss. Because a load change leaves K unchanged, linear_response gives the EXACT delta-u (not first order), so phi is exact; the only approximation left is freezing K across a SECTION change, guarded by the member loop's existing verify-installed re-solve.

GOTCHA fixed during the slice: ElementProps(e).L is 0/garbage PRE-process, so dividing a unit load by it gave Inf -> NaN solve. Use the known geometric length (H for columns) when building loads before FrameModel/solve!.

NEXT (remaining Slice 2): (1) SS-level helper to assemble a LinearCapacityCoupling from the live struc -- phi matrix, base_i = Pu_c_cur - sum_j phi_ij W_j_cur, P_cap_i(s) under frozen frame moment via bisection on the AISC H1 checker; put it in a NEW file to avoid the still-dirty demands.jl. (2) Wire into _iterate_beams_columns! behind a DEFAULT-OFF flag (byte-identical when off), verify-installed as the safety fallback. (3) Tests: flag-off byte-identical, influence correctness, single-pass column sizing on a multi-story benchmark.
