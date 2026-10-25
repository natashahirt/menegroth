---
id: chec-6e06a1aa
type: checkpoint
project: menegroth
parent_id: plan-02c6d260
title: 'Commit: ASCE 7-22 diaphragm idealizations and FEM rigid-link mode'
node_label: diaphragms committed
tags: asce-7-22,phase-6,diaphragm,commit
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/diaphragm.jl@4de643d, StructuralSynthesizer/src/analyze/_analyze.jl@4de643d,
  StructuralSynthesizer/src/analyze/asap/utils.jl@4de643d, StructuralSynthesizer/src/design_types.jl@4de643d,
  StructuralSynthesizer/src/StructuralSynthesizer.jl@4de643d, StructuralSynthesizer/test/analyze/test_diaphragm_idealization.jl@4de643d,
  StructuralSynthesizer/test/runtests.jl@4de643d, StructuralSizer/src/walls/fem_evaluator.jl@4de643d,
  StructuralSizer/test/walls/test_fem_rigid_diaphragm.jl@4de643d, StructuralSizer/test/runtests.jl@4de643d,
  scripts/runners/run_phase8_diaphragm_smoke.jl@4de643d, scripts/runners/run_phase9_diaphragm_wiring_smoke.jl@4de643d
session_id: sess-5e98e520
created_at: '2026-10-25T13:32:33.191982+00:00'
updated_at: '2026-10-25T13:32:33.191982+00:00'
---
Commits Phase 6b. classify_diaphragm_idealization returns :rigid, :flexible, or :shell from caller inputs: seismic per ASCE 7-22 §12.3.1.1–§12.3.1.3, wind per §26.2. It fails closed on missing inputs. The two concrete-filled deck names share one permission (chec-f147f576).

to_asap! accepts :flexible, which adds no link or shell and requires column tributaries. The unused 1e15 Pa :rigid shell branch is removed; :rigid is the in-plane rigid link (u_x, u_y, θ_z), which is the drift authority (deci-046f92d6). FEMLateralEvaluator gains diaphragm_mode=:rigid; :penalty_shell stays the default. Phase 5 tolerances unchanged.

Tests: diaphragm idealization 49/49, FEM rigid diaphragm 9/9, walls 509/509.

Open, reported not fixed (chec-6012f742): to_asap! does not call the classifier, so an explicit :rigid is still built; an explicit diaphragm_E still overrides the shell modulus.
