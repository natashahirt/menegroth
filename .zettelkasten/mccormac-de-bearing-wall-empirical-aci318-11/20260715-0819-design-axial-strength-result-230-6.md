---
id: 20260715-0819-design-axial-strength-result-230-6
title: Design axial strength φPnw = 230.6 k (oracle result)
type: concept
source:
  page: '551'
tags:
- example
- family:aci
- edition:aci-318-11
- role:textbooks
- tier:2
links:
- target: 20260713-0610-aci-318-example
  relation: input-to
  direction: outgoing
  graph: aci-318-canon
---

# Design axial strength φPnw = 230.6 k (oracle result)

Applying Eq. 14-1 with φ=0.65, f'c=3 ksi, Ag=8×42=336 in², k=0.8, lc=192 in,
h=8 in:

$$\phi P_{nw} = (0.55)(0.65)(3)(8 \times 42)\left[1 - \left(\tfrac{0.80 \times 192}{32 \times 8}\right)^2\right]$$

The slenderness ratio `k·lc/(32h) = 153.6/256 = 0.60`, knock-down
`1 − 0.60² = 0.64`, giving **φPnw = 230.6 k > Pu = 64.8 k ⇒ OK**. This 230.6 k
is the primary numeric known-answer oracle for `wall_empirical_axial_capacity_si`
/ `check_wall_bearing_empirical` (reproduced to <0.1 kip in test/walls and the
walls validation report §3B.1).
