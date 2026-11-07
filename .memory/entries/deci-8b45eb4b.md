---
id: deci-8b45eb4b
type: decision
project: menegroth
parent_id: deci-63970067
title: 'ACI 336.2R Eq. (5-3): K_s = k_s · B and I = footing section B·h³/12'
node_label: Eq 5-3 symbols
tags: foundations,aci-336,lambda,rigid,winkler
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-895a4da4
created_at: '2026-11-07T15:42:29.844436+00:00'
updated_at: '2026-11-07T15:42:29.844436+00:00'
has_child_rationale: Resolves the symbols the guide leaves undefined
---
User ruling 2026-11-07. ACI 336.2R Eq. (5-3), p. 9: lambda = (K_s / (4 E_c I))^(1/4).
- K_s = k_s x B (subgrade modulus x footing width, force/length^2). The notation list (p. 2) defines only lowercase k_s and nodal K, so this is a user decision, not a guide definition.
- I = footing cross-section moment of inertia B*h^3/12 about its bending axis, NOT the plan moment of inertia that p. 2 lists under I.
Used for the 1.75/lambda rigid spacing gate (§5.3 strips, §6.1.2 Step 3 rigid mat). Eq. (5-1) uses B = foundation width and E_s = Soil.Es per p. 2 notation; no ambiguity there.
