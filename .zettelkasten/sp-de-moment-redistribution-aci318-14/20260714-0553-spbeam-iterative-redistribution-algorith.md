---
id: 20260714-0553-spbeam-iterative-redistribution-algorith
title: "spBeam iterative redistribution algorithm (0.01% tolerance, \u226410 iterations)"
type: concept
source:
  page: '23'
tags:
- commentary
- family:aci
- edition:aci-318-14
- role:examples
- tier:3
- limit-state:flexure
links:
- target: 20260713-0610-aci-318-commentary
  relation: input-to
  direction: outgoing
  graph: aci-318-canon
- target: 20260714-0549-redistribution-scope-in-spbeam-one-way-b
  relation: contrasts
  direction: outgoing
---

# spBeam iterative redistribution algorithm (0.01% tolerance, ≤10 iterations)

spBeam computes the maximum code-allowable adjustment from support-face moments (provided reinforcement in investigation mode, required reinforcement in design mode), limits reduction to 20% and to the user maximum, and iterates the reduce-then-recompute procedure until the change in distribution factor is ≤ 0.01% but no more than 10 times.
