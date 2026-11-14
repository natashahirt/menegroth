---
id: deci-ecbfefc8
type: decision
project: menegroth
parent_id: plan-c431a82d
title: Per-wall thickness and reinforcement re-picked from the code floor
node_label: Per-pier thickness, reset rho
tags: walls,thickness,reinforcement,ACI 318-19
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-cad7e800
created_at: '2026-11-14T21:07:39.711666+00:00'
updated_at: '2026-11-14T21:07:39.711666+00:00'
---
DesignParameters.wall_thickness_grouping now defaults to :pier. A local strength failure thickens that wall only. :all remains available and still moves every wall together. Drift and interactive story shear are still handed to every group.

select_ordinary_wall_reinforcement! ignores the ratios already on the wall. ρt is the lightest grid ratio at or above 0.0025 that covers the largest |V| (ACI 318-19 Eq. 11.5.4.3). ρl walks up from Eq. 11.6.2 and stops at the first value that passes. A demand above the §11.5.4.2 cap leaves ρt at the top of the grid (0.0200), not at a carried ratio above it. Special shear and the row F story-shear bump still only raise, because they run after that selection.

The out-of-plane moment is still the maximum slab envelope paired with every axial. That pairing was not changed.

Ordinary-walls provenance is :ordinary_walls_v11. Wall-stage and thickness-jump tests: 998 passed.

Not done: multiplying flexible-floor member forces by 1/(1−θ) (ASCE 7-22 §12.8.7), and ASCE 7-22 Eq. 27.3-4.
