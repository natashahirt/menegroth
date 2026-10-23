---
id: deci-2c1bee70
type: decision
project: menegroth
parent_id: todo-a398f5f2
title: 'Phase 6 open decision: which diaphragm model governs wall drift (true rigid
  link vs FEM stiff-shell)'
node_label: diaphragm governs drift
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a0e013ea
created_at: '2026-10-23T00:33:19.550450+00:00'
updated_at: '2026-10-23T00:33:19.550450+00:00'
has_child_rationale: Surfaced by Phase 5c; must be resolved before ASCE 7 drift checks
---
Surfaced by Phase 5c equivalence (chec-028f596c).

## The question
The production building lateral model uses a TRUE RIGID diaphragm (`_join_wall_nodes_to_rigid_diaphragm!`: RigidLink tying only u_x, u_y, theta_z; releasing u_z, theta_x, theta_y). The isolated StructuralSizer FEMLateralEvaluator uses a PENALTY STIFF-SHELL diaphragm (fan-triangulated ShellTri3, E~1e12 Pa) that additionally restrains wall-top out-of-plane warping. On a core of spatially separate walls (coupling only through the floor), these two idealizations differ by ~5% in interstory drift (story-1: 4.87%). Base shear is unaffected (global equilibrium).

## Analysis
- The true rigid-link diaphragm is the CODE-STANDARD assumption: rigid in its own plane, flexible out-of-plane (Bathe sec 4.4; it replaced an earlier 1e15 Pa stiff-shell workaround in to_asap! :rigid).
- The FEM evaluator's stiff-shell OVER-stiffens by coupling out-of-plane warping, and its 'oracle-validated' claim only ever covered base shear (diaphragm-independent) via the single-story base-shear test — its drift was never validated against a rigid-diaphragm truth.
- Tentative view: the production rigid-link is the more defensible model for drift; the stiff-shell reference is the approximation. NOT yet decided.

## Decision needed (Phase 6, before wiring ASCE 7-22 drift checks)
Decide which diaphragm governs reported interstory drift, and make the reference and production path consistent. Options: (a) give FEMLateralEvaluator a true in-plane-rigid diaphragm mode and re-baseline drift to it (src change to the safety-critical evaluator; guard existing tests); (b) keep production on the rigid link and treat the stiff-shell only as a mesh cross-check; (c) justify the stiff-shell if out-of-plane warping restraint is physically warranted for connected cores (where walls share corner nodes, warping is coupled through the shared nodes, not the diaphragm — a different regime than the separated-wall test). Tie to corpus: ASCE 7-22 drift provisions (Phase 2 promotion still open).

No code change made now. This is a flagged decision, not an implementation.
