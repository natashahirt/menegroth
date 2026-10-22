---
id: deci-8ec247a3
type: decision
project: menegroth
parent_id: plan-ba7625fb
title: Punching centroid shift includes the half-depth past the column face
node_label: Punching centroid shift includes the half-depth pa
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-6d5378e3
created_at: '2026-10-22T20:22:38.023129+00:00'
updated_at: '2026-10-22T20:22:38.023129+00:00'
---
Edge and corner punching now shift the unbalanced moment to the critical-section centroid with e = (b_section − cAB) − c_col/2. cAB stays the distance from the inner face of the critical section (PCA EB712 Fig. 16-13, page 484). That face is d/2 outside the column face (ACI 318-11 §11.11.1.2), and R11.11.7.2 (page 210) takes Mu at centroidal axis c-c. The previous e = c_col/2 − cAB dropped that half-depth. On the spSlab exterior column (sp-de-two-way-flat-plate-aci318-14, page 42) the arm is 4.89 in and vu is 137.20 psi; the old arm was 2.01 in and left about 147 psi. The larger arm reduces the moment left in the shear stress, so the check is less conservative than before and matches the worked example. PCA page 483 still says a centroid adjustment of a DDM face or centerline moment is approximate enough to skip; this change applies the geometric distance when the shift is made, which the code already did. Interior columns are unchanged (centroid at the centerline). The max(|M| − Vu·e, 0) clamp is unchanged; for the standard edge and corner sections the corrected e stays positive.
