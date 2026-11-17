---
id: deci-b5e461d3
type: decision
project: menegroth
parent_id: deci-20346596
title: ACI 318-11 §8.13.2 uses the rib's least width; a depth step stays prismatic
node_label: ACI 318-11 §8.13.2 uses the rib's least width; a d
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-c91e4357
created_at: '2026-11-17T23:40:52.083354+00:00'
updated_at: '2026-11-17T23:40:52.083354+00:00'
---
ACI 318-11 reading used for variable-thickness ribs (corpus: aci-318-11).

§8.13.1 (PDF page 120): joist construction is regularly spaced ribs and a top slab spanning in one direction or two orthogonal directions. A triangular or parallelogram bay is not that, so §8.13.4 designs it as slabs and beams and §8.13.8's 10 percent Vc increase does not apply.

§8.13.2 (page 120): ribs are at least 4 in wide, and the depth is not more than 3-1/2 times the minimum width of the rib. For prismatic pieces of one rib, that minimum is the least width along the rib, and the depth is the stem below the slab (the same stem the existing joist check uses). Each piece is still checked on its own width; the line check is the extra coupling.

§8.13.3 (page 120): clear spacing not more than 30 in, or §8.13.4 applies.

§11.1.1 permits Vn = Vc + Vs. Withholding Vs at a solid-head face is engineering judgment (the setting rib_head_stirrups, default false), matching the existing one-way head check, which uses Vu ≤ φVc. It is not a code prohibition.

§12.10.6 (PDF page 224) and R12.10.6 (page 224): a member whose tension reinforcement is not parallel to the compression face, including a stepped member, needs adequate anchorage, and the commentary gives no development length for a stepped soffit. Each rib piece stays prismatic, so its bars are parallel to its own soffit. No extra anchorage equation is introduced. The depth change between pieces is limited by rib_depth_step (default 6 in), which is engineering judgment.

min_rib_void (default 12 in) and solid_fraction_max (default 0.35) are engineering judgment: a bay whose least centerline width, minus the ribs, is below the void minimum joins the nearest head, and growth stops at the solid-area cap.
