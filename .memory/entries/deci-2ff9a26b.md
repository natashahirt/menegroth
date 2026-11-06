---
id: deci-2ff9a26b
type: decision
project: menegroth
parent_id: plan-c8115994
title: 'Lateral systems: the declaration names the SFRS, the model sends the force,
  the checks follow from both'
node_label: declaration / model / checks
tags: lateral,sfrs,diaphragm,flexible,semirigid,architecture,asce7
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-34dfab9e
created_at: '2026-11-06T19:27:57.821688+00:00'
updated_at: '2026-11-06T19:27:57.821688+00:00'
has_child_rationale: The user worried that picking 'gravity columns' by hand would
  be reductive once holistic lateral systems arrive.
---
Agreed with the user 2026-11-06.

1. Declaration. Per direction, the Table 12.2-1 row sets R, Cd, Ω0, limits, detailing, and which vertical elements are the SFRS (ASCE 7-22 §12.2.1). One membership function answers 'which elements resist this direction under the declared system'. Walls rows: walls in plane. Row F: walls plus moment-frame lines. Dual, braced, and outrigger systems add rules later. An unsupported system is refused, never silently treated as gravity-only.

2. Model. One building model; force goes by stiffness. Gravity framing is modeled as built (pinned beam ends, real columns). Floor per §12.3.1 (p. 118): rigid (§12.3.1.2), flexible (§12.3.1.1 or calculated §12.3.1.3), otherwise semirigid with in-plane stiffness. Only the flexible idealization needs the declaration in the force path, because it spans between lines of SFRS vertical elements (§12.3.1.1 item 3(b); §12.8.4 p. 187 distributes Vx to SFRS vertical elements).

3. Checks. SFRS elements get the seismic strength checks. Non-SFRS elements get §12.12.4 deformation compatibility at δDE and strength for the force the model gives them. Report the share of story shear non-SFRS elements carry; only the dual system has a code limit (§12.2.5.1, 25%), no invented thresholds elsewhere.

Order: finish the flexible floor first (membership from the system row, lines of SFRS walls parallel to the load, simple spans between lines by tributary seismic weight, split within a line by relative in-plane stiffness with the floor along the line acting as a collector, centre-of-mass drift per deci-767f83e0). Then semirigid shell floors become a new step, since concrete-slab buildings that are not rigid are semirigid and that path currently throws.

This replaces the earlier flexible split that used gravity tributary areas over all columns and walls in both directions (gravity columns took story shear and perpendicular walls took out-of-plane shares).
