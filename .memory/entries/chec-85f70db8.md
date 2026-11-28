---
id: chec-85f70db8
type: checkpoint
project: menegroth
parent_id: todo-8e6b87f4
title: Ipopt Jacobian cache and discrete beam caller alignment
node_label: Jacobian cache and beam caller
tags: nlp,ipopt,beams,deflection,memoization
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-10593559
created_at: '2026-11-12T00:49:08.554917+00:00'
updated_at: '2026-11-12T01:44:12.366037+00:00'
has_child_rationale: 'The constraint-vector cache is already recorded in chec-03a1299d.
  This entry is the uncommitted follow-up: objective and Jacobian reuse, plus the
  discrete beam API the building caller already uses.'
---
Worktree /tmp/menegroth-rowf, branch row-f-nlp, after fb369295 and the shell stopgap 97021930. Not file-pinned: the memory server commits in the main checkout.

Ipopt: _memo_points caches the objective and the full constraint vector. _memo_jacobian builds one central-difference Jacobian per point (2*n_vars full-vector evals) and every constraint gradient reads its row. let-bindings keep each JuMP operator on its own row. Rectangular and circular column NLP compute cover, Ec, and lu once per evaluation.

Failures closed: placeable-steel tests follow _rc_column_nlp_fit_bars (20x20 #8 holds 24 bars, rho_g about 0.0474). size_rc_tbeam_nlp returns :infeasible when the built section has epsilon_t < 0.004 (ACI 318-11 §10.3.5, PDF p. 142). ACIBeamChecker.defl_sustained_live and design_tbeam_deflection apply ACI 318-11 §9.5.2.5 Eq. (9-11) to dead plus psi*live; psi=0 matches the old dead-only total.

Discrete caller: size_beams and size_tbeams take shell_spans. size_tbeams takes sustained_live_fraction, joist_spacing (accepted, ordinary Vc; §8.13.8 not applied), and flange_width as a length or a function of web width (caller applies §8.12.2, PDF p. 119). ConcreteBeamOptions gained sustained_live_fraction, uniform_geometry, rib_form. Discrete size_beams! Nu is envelope tension or zero, so Eq. (11-4) does not credit non-concurrent compression.

Tests: column NLP 1152/1152; T-beam catalog plus deflection 103/103. T-beam optimization 69/69 and signed demands 68/68 passed in the run before the comment-only edits. StructuralSynthesizer was not re-run after the discrete keyword changes. Left: rectangular and T-beam-NLP sustained live, joist Vc §8.13.8, per-case shear on the discrete MIP, and the shell-deflection stopgap until the other checker lands.
