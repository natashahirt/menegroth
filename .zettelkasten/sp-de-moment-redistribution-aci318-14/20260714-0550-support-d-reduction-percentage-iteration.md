---
id: 20260714-0550-support-d-reduction-percentage-iteration
title: Support D reduction-percentage iteration (test oracle)
type: finding
source:
  page: '14'
tags:
- example
- family:aci
- edition:aci-318-14
- role:examples
- tier:3
- limit-state:flexure
- clause:6.6.5.3
links:
- target: 20260713-0610-aci-318-example
  relation: input-to
  direction: outgoing
  graph: aci-318-canon
- target: 20260714-0542-redistribution-adjustment-percentage-rel
  relation: example-of
  direction: outgoing
---

# Support D reduction-percentage iteration (test oracle)

GIVEN support-D column-face negative moment (M_u)₁ = 49.30 kip-ft with d=14 in., the computed adjustment exceeds the 20% cap on iteration 1 (26.72% → 20%). SOLUTION OUTPUT: second-iteration moment (M_u)₂ = 49.30 − 49.30·0.20 = 39.44 kip-ft, adjustment again capped (34.52% → 20%); iterations converge at 20%.
