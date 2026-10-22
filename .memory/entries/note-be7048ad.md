---
id: note-be7048ad
type: note
project: menegroth
parent_id: deci-dc24c1ed
title: 'crit8 (P1): enclosure guard checks wall CENTROID, not body — endpoint overhang
  flips solve_wall_layout to feasible=TRUE at 1.18·DL'
node_label: 'crit8 (P1): enclosure guard checks wall CENTROID, '
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/crit8_wall_endpoint_overhang_attack.jl@5fb4f40
session_id: sess-5e3ba6f9
created_at: '2026-10-22T02:07:53.561282+00:00'
updated_at: '2026-10-22T02:07:53.561282+00:00'
---
Adversarial red-team of the crit7 enclosure fix (_plate_encloses_walls). NEW, distinct hole from the conceded walls⊆plate⊂occupants residual.

The guard's docstring claims it 'enforces WALLS ⊆ plate', but it keys only on WallLine.(x,y) = the pier CENTROID. A WallLine/WallCandidate is a pier with length lw + orientation θ. A wall whose centroid is strictly inside the plate can have its BODY/END protrude outside. The guard passes, the exact four-corner drift/torsion metrics (evaluated only over plate_center±(hx,hy)) under-state, and the far wall end — a real structural point — exceeds the drift limit.

CONFIRMED END-TO-END via real solve_wall_layout (reproducer scripts/runners/crit8_wall_endpoint_overhang_attack.jl): plate center (0,0) halfwidth (5,5); long X pier id1 (lw=20, θ=0, centroid (0,0)) with ends at x=±10 (5 m outside plate) placed at y=0 so it carries ~0 shear (shear gate can't mask it); two slender Y piers carry base shear. At ex=0.5, Fy=3.435e6 N: _plate_encloses_walls=true, declared corner_drift/DL=0.980, tors/TL=0.899, util_trans=0.726, util_tors=0.161 → solve_wall_layout returns feasible=TRUE, status=:optimal, worst_util=0.980 — while the true drift at wall end (10,0) is 1.180·DL (18% OVER ASCE 7-22 §12.12.1).

FIX (cheap): the guard should also bound wall ENDPOINTS centroid±(lw/2)(cosθ,sinθ) against the plate, not just the centroid — lw/θ are already carried by WallCandidate. This is exactly the 'WALLS ⊆ plate' invariant crit7 claims.

Sub-probes: (a) TOLERANCE abuse negligible (~1e-10 of drift/DL, NOT the hole). (e) ZERO half-extent relaxation is a special case of the same centroid-vs-body gap, not independently flipped. (c) single plan_halfwidth/plate_center cannot represent setbacks/podiums. (d) no Inf→feasible or NaN consumer bypass found.
