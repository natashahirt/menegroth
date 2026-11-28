---
id: chec-b7f819eb
type: checkpoint
project: menegroth
parent_id: plan-0e3e4710
title: Solved rectangle grillage runs the solid-head checks and grows the head
node_label: Grillage head check and grow
tags: ribs,solid-head,punching,grillage,aci-318-11
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f8449a62
created_at: '2026-11-09T00:45:42.567097+00:00'
updated_at: '2026-11-09T00:45:42.567097+00:00'
---
2026-11-08. check_rectangle_grillage_heads reads a solved analyze_rectangle_grillage. Vu is the upward corner reaction, with the factored pressure inside the outer section deducted. The outer perimeter is punching geometry at d/2 outside the head (the waffle example's 89.94 in and 159.88 in). Equivalent thickness is one rib web per module the head covers, and the thinner of the two directions is the one the stress uses. One-way shear is the frame shear at d_rib from the head face. Mub is zero because the corner rotation is released. The head is classified when a topping thickness is passed.

grow_rectangle_grillage_heads rebuilds that mesh at each larger module and solves again. A head that already passes is left alone. If the next module would make opposite heads meet, the error names the governing check and the failing fraction; that size is not reported as adequate.

On this uniform rectangle, one-way shear at the ribs leaving the head rose as the head grew (0.125 → 0.375 of an 8×8 bay, 4.5 kPa, ratio 1.01 → 1.49, governing rib_one_way) while the rib-web ratio fell (0.61 → 0.10). Enlarging the head moved the one-way section onto ribs that carry more of the bay. The loop tried every legal module and then stopped.

Tests: StructuralSizer slabs/test_solid_head_punching.jl plus the joist scan, 82 pass. StructuralSynthesizer analyze/test_solid_head_check.jl, 101 pass. The building skeleton is not rewritten by this loop.
