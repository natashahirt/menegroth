---
id: anno-e513f9cf
type: annotation
project: menegroth
parent_id: deci-2c1bee70
title: 'Phase 6 entry criteria: diaphragm mode = ASCE trichotomy + a §12.3.1 classifier
  chooses it (both gated on Phase 2)'
node_label: P6 entry criteria
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-1f9c3597
created_at: '2026-10-23T00:50:28.204683+00:00'
updated_at: '2026-10-23T00:50:28.204683+00:00'
has_child_rationale: Pins the Phase 6 scope surfaced by the diaphragm-setting review
---
Reviewed the current diaphragm setting. `DesignParameters.diaphragm_mode::Symbol` (default :none) is validated in to_asap! to {:none, :rigid, :shell} — modeling MECHANISMS, not ASCE classifications. Mapping: :rigid=RigidLink in-plane (ASCE rigid §12.3.1.2); :shell=real-slab shells (ASCE semirigid §12.3.1/§12.3.1.3); NO :flexible mode (§12.3.1.1 tributary distribution is unmodeled); :none means 'off', not an ASCE category. Both :rigid and :shell engage only when slabs exist; wall nodes join only in :rigid via _join_wall_nodes_to_rigid_diaphragm!.

Two Phase 6 work items (do NOT start now; Phase 5 not finished and both are code-derived -> blocked on Phase 2 corpus promotion of §12.3.1/§12.3.2):
1. MODE VOCABULARY REWORK: align diaphragm_mode to the ASCE trichotomy — add a real flexible (tributary-area) mode; make :none explicitly 'no diaphragm'; and PRUNE the vestigial 1e15 Pa :rigid branches in _build_shell_props (utils.jl ~340) and _create_shell_diaphragms (~374), which are dead for the main path (line 228 :rigid uses _build_rigid_diaphragm_links/RigidLinks, never the stiff shell). Verify-dead with a grep, then remove in the same pass.
2. CLASSIFIER: a §12.3.1 classifier that CHOOSES the idealization from geometry — §12.3.1.2 permits rigid for concrete slabs/concrete-filled deck with span-to-depth <= 3 and no Type 2,3,4,5 Horizontal Structural Irregularity (§12.3.2); §12.3.1.3 calculated-flexible test delta_MDD > 2*Delta_ADVE (Eq 12.3-1); wind uses span-to-depth <= 2 (§26.2). Citations grounded in corpus asce-7-22, p.179 (§12.3.1.x) and p.324 (wind def). These clauses must be PROMOTED via scripts/runners/corpus_promote.jl before encoding.

Also resolve here which diaphragm governs reported drift (parent decision): the true in-plane rigid link, not the FEM evaluator's penalty stiff-shell. Recommendation: rigid-link is the drift authority for §12.3.1.2-qualifying cores; give FEMLateralEvaluator a matching in-plane-rigid mode; keep real-property :shell for genuine semirigid. No code now. Files: StructuralSynthesizer/src/analyze/asap/utils.jl, StructuralSynthesizer/src/design_types.jl.
