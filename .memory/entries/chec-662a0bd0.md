---
id: chec-662a0bd0
type: checkpoint
project: menegroth
parent_id: deci-62d877ec
title: 'Asap drift-participation query built + tested (19/19): per-element c_e = u_vᵀ
  K_e u_r via cached-factor virtual solve, Σ c_e = δ'
node_label: Asap drift-participation query built + tested (19/
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-69780ed3
created_at: '2026-11-23T18:59:33.877085+00:00'
updated_at: '2026-11-23T18:59:33.877085+00:00'
---
First step of the virtual-work drift-sizing plan (deci-62d877ec) is in Asap.

NEW: `external/Asap/src/Model/analysis/drift_participation.jl` — `drift_participation(model, dof)` (and a `(model, node, direction)` overload) returns `DriftParticipation(dof, δ, element_ids, c, nonframe)`. Applies a unit virtual load at the free DOF, solves on the CACHED Cholesky factor (`_get_factorization` — one extra RHS, no refactorization), and decomposes the drift as c_e = u_vᵀ K_e u_r over each frame element's GCS stiffness `element.K`. By Maxwell–Betti Σ c_e = u_vᵀ S u_r = u_r[dof] = δ; `nonframe = δ − Σ c_e` is ~0 for a frame-only model (correctness check) or the shell/core share for a dual system. Sign-convention-free (reuses assembled K, no M(x) recovery).

Wired: include in `src/Model/analysis.jl` (after factorization_cache); export `drift_participation, DriftParticipation` in `src/Asap.jl`; test registered in `test/runtests.jl`.

TEST `test/integration_and_api/test_drift_participation.jl` — 19/19 pass: (1) axial bar c_1 = δ = PL/EA exact; (2) 5-element cantilever Σ c = δ = model.u[dof] exact + δ ≈ PL³/3EI (rtol 2e-2, slender); (3) portal sway, columns carry >50% of participation vs girder; (4) two virtual solves do NOT increment `_N_FACTORIZATIONS` (validates the compute claim) + restrained-DOF errors.

Asap is a submodule (own repo, branch integration/2026-11-18). Changes are additive (new fn + include + exports + test); pre-existing dirty `head.exe.stackdump` left untouched.

NEXT: single-constraint optimality-criteria resizer (s_e* = sqrt(λ c_e I_e / w_e), snap-to-catalog, strength floor, active set) consuming this c_e; per-DOF split (I_y/I_z/A) is a later refinement over the lumped c_e.
