---
id: plan-58b37e3e
type: plan
project: menegroth
parent_id: chec-2dea3888
title: Footing reactions use ASCE 7-22 §2.3 and §2.4
node_label: Footing combination plan
tags: foundations,asce,load-combinations
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-12b82aff
created_at: '2026-11-12T11:36:07.558636+00:00'
updated_at: '2026-11-12T11:52:31.189424+00:00'
---
Isolated footings will be designed from the basic load combinations, not from the last gravity solve.

Soil pressure against the allowable pressure uses ASCE 7-22 §2.4.1 and §2.4.5 (corpus: asce-7-22, PDF pages 69–70) and §12.13.6 (PDF page 196). Concrete strength uses §2.3.1 and §2.3.6 (PDF pages 68–69). Each combination keeps its own axial force and moment. Wind and earthquake are not applied together. Eh = ρ QE (Eq. 12.4-3, PDF page 183). Ev = 0.2 SDS D on the vertical dead effect only (Eq. 12.4-4a, PDF page 183), the same axial-only reading the wall combinations already use.

Permissions that are not taken: the 25% ELF overturning reduction (§12.13.4), Ev = 0 at the soil interface (Eq. 12.4-2 exception 2(b)), the 0.5 live-load factor, and any increase in allowable pressure (§2.4.1 forbids that increase unless it is justified). A resultant outside the kern still fails the footing. ACI 336.2R §3.2.2 partial contact is not in the implemented equation. Sliding friction is not checked: §12.13.5.1 gives the form (dead-load factor times D times a friction coefficient) and the coefficient is a soil input this model does not have.

Direction: the ordinary-wall stage already chooses independent or 100/30 from §12.5. Those effects are the QE cases the footing sees.

Worktree /tmp/menegroth-rowf, branch row-f-nlp. Not pinned to files because the memory server tracks the main checkout.
