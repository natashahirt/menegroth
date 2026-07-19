---
id: 20260715-0553-spbeam-software-redistribution-behavior
title: spBeam software redistribution behavior (guide/software notes)
type: concept
source:
  page: '20'
tags:
- family:csa
- edition:csa-a23-3-14
- role:examples
- tier:3
- element:beam
- material:reinforced-concrete
- limit-state:moment-redistribution
- commentary
links:
- target: 20260714-2204-csa-a23-3-commentary
  relation: input-to
  direction: outgoing
  graph: csa-a23-3-canon
---

# spBeam software redistribution behavior (guide/software notes)

spBeam's redistribution feature reduces support negative moments by up to 20% (reductions only; code-permitted increases ignored), applies to one-way and beam systems, maintains static equilibrium, and iterates the redistribution factors until the change is ≤0.01% but no more than 10 iterations.
