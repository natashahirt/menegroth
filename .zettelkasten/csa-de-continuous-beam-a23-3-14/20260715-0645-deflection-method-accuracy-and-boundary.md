---
id: 20260715-0645-deflection-method-accuracy-and-boundary
title: Deflection-method accuracy and boundary-condition effects
type: concept
source:
  page: 36-40
tags:
- family:csa
- edition:csa-a23-3-14
- role:examples
- tier:3
- element:beam
- material:reinforced-concrete
- limit-state:serviceability-deflection
- clause:9.1-Table
- commentary
links:
- target: 20260714-2204-csa-a23-3-commentary
  relation: input-to
  direction: outgoing
  graph: csa-a23-3-canon
---

# Deflection-method accuracy and boundary-condition effects

Approximate deflection methods are accurate only to within 20–40%; spBeam uses stiffness-method frame analysis discretizing the span into 110 elements, and boundary conditions materially change deflections (e.g., Grid 3 columns vs transverse-beam supports, where CSA approximates transverse-beam-end moment as 2/3 the column-end moment per Table 9.1).
