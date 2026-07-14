---
id: deci-2d76e25f
type: decision
project: menegroth
parent_id: plan-cda23eb7
title: 'Run 4 re-scope: per-MemberGroup variation is only cleanly separable for beam
  groups on the size_member_group! path (coupling blocks the rest)'
node_label: 'Run 4 re-scope: per-MemberGroup variation is only '
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design_workflow.jl@8e34430, StructuralSynthesizer/src/analyze/members/utils.jl@68f9e53,
  StructuralSynthesizer/src/design_graph/provenance.jl@2f7c9fd, StructuralSynthesizer/src/design_graph/fingerprint.jl@2f7c9fd,
  StructuralSynthesizer/src/design_types.jl@d7a92cb, StructuralSynthesizer/src/building_types/members.jl@68f9e53
session_id: sess-a0606b76
created_at: '2026-07-14T17:24:32.639976+00:00'
updated_at: '2026-07-14T17:24:32.639976+00:00'
---
Run 4 explore answered the decisive separability question and NARROWED the safe scope. The going-in assumption (per-MemberGroup catalog/objective is cleanly downstream of slabs) is only partly true.

BLOCKERS found: (a) FLAT-PLATE :members is ONLY _reconcile_columns! (design_workflow.jl:817-957) — reads NO catalog/objective; column catalog/objective live in the SLAB stage via params.columns, which is PREPARE-AFFECTING. So there is no per-MemberGroup catalog knob at the flat-plate :members node. (b) Column sizing is a GLOBAL MIP (size_columns! over all groups, analyze/members/utils.jl:2840) — no per-column-group API. (c) The beam<->column iteration _size_beams_columns! (design_workflow.jl:1262-1307) COUPLES groups: one beam-group catalog change propagates to all column demands via the convergence loop, so a single-group skip there is UNCONSERVATIVE/WRONG.

CLEAN, exact-first-safe slice: fine per-BEAM-MemberGroup nodes on the size_member_group! path (framing/joist steel groups with MemberGroup.catalog_override, utils.jl:1968-2034), NOT the coupled _size_beams_columns! loop.

PARAM shape (non-prepare-affecting): member_group_overrides::Dict{UInt64, MemberGroupSizingOverride} with catalog/objective/deflection_limit/total_deflection_limit/max_depth; MUST exclude collinear_grouping (mutates group_id at sizing time) and global columns/beams/materials. Default empty => unchanged global behavior. KEY hash deviation from the slab whole-field fold: per-node input_hash must fold ONLY get(overrides, gid, default) for that node's gid, else changing group A false-dirties group B. Mixed member levels become REACHABLE (unlike slabs), so the partial-restore path (restore_member_group_writes!) must be correct + tested end-to-end, and coupled paths must fall back to the COARSE :members node (no false single-group skip) or be guarded.

COORDINATOR DECISION (autonomous, overnight mandate): proceed with the DE-RISKED Phase A — member_group_overrides param infrastructure + fine per-beam-group nodes where uncoupled, with coarse fallback+guard for _size_beams_columns! / global column MIP / flat-plate reconcile / harmonize / n_max_sections coupling. If no fixture exercises the clean size_member_group! beam-group path, add a minimal framing/joist fixture; if that is disproportionate, deliver JUST the param infrastructure (honored by the coarse node, exact-first verified) and defer the fine split, reporting the choice. DEFER to a future run (needs new sizer mechanics + a design decision): Phase B = per-column-group MIP split + flat-plate column overrides in the slab stage + a FIXPOINT node for the beam-column iteration; Phase C = per-slab independent variation + grow-then-size two-pass + real P-M capacity comparison. Surfaced to the user for morning redirect.
