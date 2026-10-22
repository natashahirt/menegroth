---
id: note-bc81fb18
type: note
project: menegroth
parent_id: plan-a2a6128f
title: 'check_wall_inplane_shear: material-driven fyt (remove hardcoded Grade-60),
  fail closed if missing — committed to restore HEAD consistency'
node_label: 'check_wall_inplane_shear: material-driven fyt (rem'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/checker.jl@62de2f2
session_id: sess-c4e1eb1f
created_at: '2026-10-22T13:28:09.638898+00:00'
updated_at: '2026-10-22T13:28:09.638898+00:00'
---
Completes the Phase 1 hardening item from todo-a8b3ef17 / deci-5f0925b2 ('material-driven fy/λ in check_wall_inplane_shear, currently hardcoded Grade-60'). StructuralSizer/src/walls/checker.jl:
- New _wall_shear_materials(material; fyt=nothing) -> (fc, fyt, λ): resolves f'c/λ from the concrete and fyt (TRANSVERSE/tie reinforcement yield, ACI 318-19 §11.5.4.3 Eq. 11.5.4.3, Vn=(αc·λ·√f'c + ρt·fyt)·Acv; corpus aci-318-19 p.172). ReinforcedConcreteMaterial supplies fyt from its dedicated `transverse` grade; a plain Concrete requires explicit fyt= (Unitful).
- check_wall_inplane_shear signature changed (ws, concrete, Vu, hw) -> (ws, material, Vu, hw; fyt=nothing). Removes the old fy_psi=60_000 hardcoded Grade-60 default. FAILS CLOSED: missing fyt for a plain Concrete throws (no silent Grade-60); a bare-number fyt is rejected (must be Unitful) to prevent a ksi/Pa mismatch that would scale steel ~7e6x.

WHY COMMITTED NOW: the matching tests were already committed in test_walls.jl (lines 54, 87, 688-709: fyt= kwarg, chk60/chk75 grade sensitivity, @test_throws for missing fyt and bare-number fyt) via the earlier enclosure-guard memory pin, but checker.jl itself was NOT pinned — leaving HEAD INCONSISTENT (committed tests exercising an uncommitted API). Committing checker.jl restores HEAD = the verified working tree. Full wall suite re-run green: 428/428.
