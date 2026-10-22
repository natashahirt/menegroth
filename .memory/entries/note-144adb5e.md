---
id: note-144adb5e
type: note
project: menegroth
parent_id: plan-de3143e9
title: 'CORRECTION: 14 Synth design-graph DDM-3-span errors are AUDIT-INDUCED, not
  pre-existing (revises note-927ef5e7)'
node_label: 'CORRECTION: 14 Synth design-graph DDM-3-span error'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/ddm.jl@21e23a0,
  StructuralSynthesizer/test/design_graph/test_design_graph_incremental.jl@e0b7431,
  StructuralSynthesizer/test/design_graph/test_design_graph_equivalence.jl@341f4b8
session_id: sess-99dddff5
created_at: '2026-10-22T15:56:54.875244+00:00'
updated_at: '2026-10-22T15:56:54.875244+00:00'
---
Pre-audit baseline check (worktree @ eee02cdb vs HEAD source diff; empirical Julia run blocked by concurrent PID 77405 + Asap submodule pin fb5db64c unfetchable) overturns the earlier close-out classification for the Synthesizer design-graph error cluster.

ROOT CAUSE — commit cdcd6271 (2026-10-21 22:08, 'Cycle 13b: generalize the Eq. (13-7) under-centerline guard') reworked `check_ddm_applicability` in ddm.jl:
  • BASELINE (eee02cdb): 3-span rule counted TOTAL columns — `n_cols = length(columns); if n_cols < 2 ... elseif n_cols < 4` — and cited §8.10.2.1 (318-19 numbering). A 2×2-bay grid = 9 columns ≥ 4 ⇒ NO violation ⇒ DDM applies ⇒ design_building SUCCEEDS.
  • HEAD: counts CONTINUOUS SPANS per direction via `_ddm_continuous_span_counts` — `elseif counts[1] < 3 || counts[2] < 3` — and cites §13.6.1.1 (corpus aci-318-11, page 252). A 2×2-bay grid = 2 spans each way ⇒ violation ⇒ PreSizingValidationError thrown.

BOTH design-graph test files build 2×2-bay fixtures (gen_medium_office(…, 2, 2, 1) = 3×3 columns = 2 spans/dir): test_design_graph_incremental.jl `_build_flat_plate` (line 80) and test_design_graph_equivalence.jl (lines 48/69/85). They relied on the old under-restrictive flat column-count and now correctly get rejected by the DDM gate before the incremental-engine logic they test can run → the 14 DDM-3-span errors.

ASSESSMENT: the audit change is MORE code-correct, not a production regression — ACI 318-11 §13.6.1.1 genuinely requires ≥3 continuous spans in EACH direction; a 2×2-bay flat plate does not qualify for DDM. The audit also fixed the citation from §8.10.2.1 (318-19) to §13.6.1.1 (318-11), consistent with the pending citation-sweep. FALLOUT is stale test fixtures, not unsafe behavior.

FIX (fold into pre-ribbed run): bump the design-graph fixtures to ≥3 continuous spans/direction (e.g. 3×3 bays = 4×4 columns) so DDM applies and the incremental-engine equivalence/skip tests exercise what they're meant to. Keep the production code change. (The 2 'No feasible sections' Synth errors are separate fixture-demand issues, unchanged by this.)
