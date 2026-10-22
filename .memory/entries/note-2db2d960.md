---
id: note-2db2d960
type: note
project: menegroth
parent_id: deci-bad8d293
title: Guard F2 residual P2s to address in follow-up cycle
node_label: Guard F2 residual P2s to address in follow-up cycl
tags: guard-f2, walls, p2, follow-up, deferred
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/lateral_evaluator.jl@7847655, StructuralSizer/src/walls/layout_problem.jl@7847655
session_id: sess-fdd3423a
created_at: '2026-10-22T14:29:12.913735+00:00'
updated_at: '2026-10-22T14:29:12.913735+00:00'
---
Three residual P2 fragile-assumption findings from the critic, deferred to a FOLLOW-UP cycle. All are backstopped by the eigenstructure floors + FEM survivor re-validation (critic could NOT weaponize any into a fail-open):

1. DIMENSIONLESS fraction, not absolute stiffness: activity masks on the dimensionless rho^penal fraction, not absolute rho^penal*k_max. A pathological large-k_max masked wall could inject stiffness yet skip the gate. (Critic could not weaponize into a fail-open.)

2. PRE-EXISTING crit8 compounded (centroids vs endpoints): the enclosure gate checks wall CENTROIDS not ENDPOINTS, so a long wall body can overhang the plate while its centroid stays inside.

3. Misleading empty-after-mask comment: the empty-after-mask comment leads with the scale-invariant rcond singular guard, but the real backstop for a LOADED all-masked story is the load-dependent util_trans.
