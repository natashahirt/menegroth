---
id: deci-da15b75d
type: decision
project: menegroth
parent_id: plan-d9fb1410
title: A2 is the per-face 1:2 frustum wholly inside the support
node_label: per-face A2 frustum
tags: foundations,bearing,aci-318-11,A2,sqA,flush
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/foundations/codes/aci/spread_footing.jl@82ec946, StructuralSizer/src/foundations/codes/aci/strip_footing.jl@82ec946,
  StructuralSizer/src/foundations/types.jl@82ec946, StructuralSizer/test/foundations/test_foundation_safety_9_15.jl@82ec946
session_id: sess-92e8afa1
created_at: '2026-09-24T02:21:13.243426+00:00'
updated_at: '2026-09-24T02:21:13.243426+00:00'
has_child_rationale: Landing mechanics for flush-bearing Bn under this plan
---
ACI 318-11 §10.14.1 (aci-318-11 p.162) and A2 notation (p.24) require the largest 1:2 frustum wholly inside the support — not a boolean “wider on all sides” that unlocks a centered min(c+4h, L) frustum.

Fix-cycle 1 (critic P1): an end-flush 2-col strip with L ≫ c_along still took sqA=2 under the overall B>c2 && L>c1 gate. Fix: per-face col_pos_local.

Fix-cycle 2 (critic P1): 18×18 with 3 in overhang still unlocked the full centered frustum (sqA=2); A2 was not clipped. Fix: A2 = min(2h, overhang) per face; circular columns use an inscribed cone; Bn and sqA are stored on StripFootingResult.

Do not restore a binary unlock of the centered frustum.
