---
id: deci-bb66c7e5
type: decision
project: menegroth
parent_id: plan-33507d8a
title: ACI 318-11 §8.13 joist limits and the 10 percent Vc increase
node_label: §8.13 joist limits
tags: aci-318-11,joists,shear,waffle
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-e28f7ab7
created_at: '2026-11-06T02:27:35.013372+00:00'
updated_at: '2026-11-06T02:27:35.013372+00:00'
has_child_rationale: Joist geometry and the shear increase are now code checks, separate
  from the sizing-pass architecture.
---
ACI 318-11 §8.13 is implemented in StructuralSizer as JoistConstruction, check_joist_construction, and Vc_joist (corpus: aci-318-11, PDF pages 120–121). design_beam_shear takes an optional joist; the default path is unchanged.

Limits: rib width at least 4 in (§8.13.2); overall depth not more than 3.5 times the minimum rib width (§8.13.2); clear spacing not more than 30 in (§8.13.3); slab thickness at least clear/12 and at least 2 in for removable forms (§8.13.6.1) or 1.5 in when the caller asserts a permanent filler meeting §8.13.5 (§8.13.5.2). Equality is permitted.

Vc is 1.10 times Chapter 11 (§8.13.8) only when width, depth, and spacing pass. A failing slab thickness is reported and does not remove the increase. Failing §8.13.2 or §8.13.3 means design as an ordinary beam (§8.13.4): no exception, no increase.

ACI 318-11 §8.13.2 says "depth". The stored depth is overall depth, bottom of rib to top of slab, because ACI 318-19 §9.8.1.3 states the same 3.5 limit on overall depth (corpus: aci-318-19, PDF page 153). That cross-edition reading is flagged in the source comment.

Not in this step: §8.13.5.1 filler shells in strength, §8.13.6.2 / §7.12 panel bars, §8.13.7 conduits, and an SJI catalog. Recommended catalog when that work starts: SJI 100-2020 45th Edition already in the corpus as sji-100-2020 (K, LH, DLH, and Joist Girders; CJ later). Tests: StructuralSizer concrete_beam/test_joist_construction.jl, 22 passed.
