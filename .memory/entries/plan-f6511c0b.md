---
id: plan-f6511c0b
type: plan
project: menegroth
parent_id: plan-5d8af001
title: 'Run 5 / Phase B: activate per-group overrides in the real pipeline (de-risk
  first)'
node_label: 'Run 5 / Phase B: activate per-group overrides in t'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-71f1208d
created_at: '2026-07-15T01:38:19.369475+00:00'
updated_at: '2026-07-15T01:38:19.369475+00:00'
---
Follows Run 4 (parameter infrastructure only; member_group_overrides currently guarded fail-loud at capture_design). Phase B makes overrides actually fork a real design_building, under the same exact-first posture. Three architectural forks must be resolved by a recon explore before building:

1. Beam↔column fixpoint node — model the _size_beams_columns! convergence loop as a warm-started fixpoint node so per-group beam nodes can be exact-first. Design choice: what converged state to checkpoint.
2. Per-column-group nodes — can the GLOBAL size_columns! MIP be split per group WITHOUT changing results? The n_max_sections cross-group shared-section constraint may make this impossible exact-first. Fallback: column sizing stays atomic, only beam groups go fine.
3. Flat-plate column overrides — params.columns is prepare-affecting, so a per-group column override at the slab stage is a different mechanism; may be out of scope.

Approach: de-risk-then-gate. Graph 1 = recon explore + P2 structural-guard hardening (move member_group_overrides guard into the BuildingDesign constructor) with full checker/gate coverage. After explore lands, auto-proceed via extend_graph on whatever it certifies exact-first-safe; surface any genuinely non-exact-first fork for user decision. Rigor: high. Correctness gate: the differential verify harness (four gates) must stay byte-identical for all non-override paths.
