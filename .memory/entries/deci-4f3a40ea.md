---
id: deci-4f3a40ea
type: decision
project: menegroth
parent_id: plan-c431a82d
title: Wind eccentricity and the flexible-floor P-delta factor
node_label: Eq 27.3-4 and 1/(1-theta)
tags: wind,ASCE 7-22,P-delta,flexible diaphragm,walls
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-5852749d
created_at: '2026-11-14T22:49:14.699163+00:00'
updated_at: '2026-11-14T22:49:14.699163+00:00'
---
ASCE 7-22 Eq. 27.3-4 is wind_flexible_eccentricity. Case 2 evaluates it at each sign of e_Q = ±0.15 B; the two results are not opposites because the square-root term does not change sign. The ordinary-wall stage does not pass flexible=true: it does not have I_z, Q, R, g_R, or e_R, and §26.11.2 permits a low-rise building to be treated as rigid. A flexible diaphragm is not a flexible building. Its wind moment, including the rigid 0.15 B eccentricity, is a couple on the two wall lines with the longest arm, sized so the story loads' moment about the exterior centroid equals the case moment. One line throws. ELF still ignores Mz on a flexible diaphragm (§12.8.4.2.1).

On a first-order floor (flexible or semirigid), seismic member forces on solid piers, opening segments, and joined corners are multiplied by the drift-case 1/(1−θ) of ASCE 7-22 §12.8.7, per effect term and per story matched by elevation. Gravity, wind, Ev, and the drift solve are not scaled again. A rigid diaphragm still takes member forces from the story stiffness. θ > θmax still refuses. Provenance is :ordinary_walls_v12.

Tests: StructuralSizer Chapter 27, 130 passed. Wind story cases, 82 passed, including the flexible-diaphragm couple. Ordinary wall stage and seismic gates, 707 passed.
