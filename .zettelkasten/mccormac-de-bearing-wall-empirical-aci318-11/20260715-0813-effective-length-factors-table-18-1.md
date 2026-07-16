---
id: 20260715-0813-effective-length-factors-table-18-1
title: Effective length factors k for load-bearing walls (Table 18.1)
type: concept
source:
  page: '550'
tags:
- parameters
- family:aci
- edition:aci-318-11
- role:textbooks
- tier:2
links:
- target: 20260713-0610-aci-318-parameters
  relation: input-to
  direction: outgoing
  graph: aci-318-canon
---

# Effective length factors k for load-bearing walls (Table 18.1)

Effective length factor `k` for Eq. 14-1 (code §14.5.2), from Table 18.1:

| Condition | k |
| --- | --- |
| Braced top & bottom, restrained against rotation at one or both ends | 0.80 |
| Braced top & bottom, not restrained against rotation at either end | 1.0 |
| Not braced against lateral translation | 2.0 |

Matches `wall_empirical_k(:restrained)=0.8`, `:pinned=1.0`, `:cantilever=2.0`
(ACI 318-19 Table 11.5.3.2).
