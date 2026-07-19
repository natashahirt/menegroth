---
id: 20260715-2159-effective-moment-of-inertia-ie-eq-24-2-3
title: Effective moment of inertia Ie (Eq. 24.2.3.5a)
type: equation
source: {}
tags:
- equation
- family:aci
- edition:aci-318-14
- role:examples
- tier:3
- element:beam
- material:reinforced-concrete
- limit-state:serviceability-deflection
- clause:24.2.3.5a
links:
- target: 20260713-0610-aci-318-equation
  relation: input-to
  direction: outgoing
  graph: aci-318-canon
aliases:
- sp-de-continuous-beam-aci318-14#24.2.3.5a
grounding:
  verified: true
  method: render-validity
  valid: true
  locator: none
---

# Effective moment of inertia Ie (Eq. 24.2.3.5a)

Effective moment of inertia for a cracked section (Ma > Mcr). LaTeX: \( I_e = \left(\dfrac{M_{cr}}{M_a}\right)^3 I_g + \left[1 - \left(\dfrac{M_{cr}}{M_a}\right)^3\right] I_{cr} \le I_g \). Symbols: \(M_{cr}\) = cracking moment, \(M_a\) = max service moment at the stage deflection is computed, \(I_g\) = gross inertia, \(I_{cr}\) = cracked transformed inertia. Clause ACI 318-14 Eq. 24.2.3.5a, page 16. (For uncracked sections, Ma ≤ Mcr, Ie = Ig.)
