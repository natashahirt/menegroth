---
id: deci-dac5351b
type: decision
project: menegroth
parent_id: plan-1d645a44
title: Rebar coating is a property of the rebar material, set once per project
node_label: Rebar coating is a property of the rebar material,
tags: rebar,coating,development-length,aci-318-19,project-options,column-layout
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/materials/types.jl@6cd9b21, StructuralSizer/src/materials/steel.jl@6cd9b21,
  StructuralSizer/src/codes/aci/detailing.jl@6cd9b21, StructuralSizer/src/members/sections/concrete/rc_rect_column_section.jl@6cd9b21,
  StructuralSizer/src/members/optimize/problems/rc_column.jl@3f4332b, StructuralSynthesizer/src/api/deserialize/materials.jl@6cd9b21,
  StructuralSynthesizer/src/api/schema/input_types.jl@6cd9b21, StructuralSynthesizer/src/api/validation.jl@6cd9b21
session_id: sess-abd810eb
created_at: '2026-11-07T00:16:43.930681+00:00'
updated_at: '2026-11-07T00:16:43.930681+00:00'
---
User decision (Nov 6 2026).

- `Metal` (so `RebarSteel`) has a `coating::Symbol` field, one of `REBAR_COATINGS = (:uncoated, :galvanized, :epoxy, :zinc_epoxy)`, matching the rows of ACI 318-19 Table 25.4.2.5 (printed p. 474). Structural steel is always `:uncoated`. `with_coating(Rebar_60, :epoxy)` makes a coated grade; mass and carbon do not change.
- Project option: `MaterialOptions(rebar = with_coating(...))` in Julia, `materials.rebar_coating` (default "uncoated") in the API, validated against the same list.
- Detailing functions take `coating` (the material's symbol) plus `epoxy_close::Bool` for the 1.5 row (clear cover < 3db or clear spacing < 6db). Hooked bars use 1.2 for any epoxy.
- Not done: no f'c floor of 4000-5000 psi for Grade 75. That is practice advice, not a code limit, so it stays out of the solver.

Also in this change: `RCColumnSection` perimeter layout now moves interior bars off a face that cannot hold them at the 25.2.3 clear spacing (`_face_capacity`), so 8x14 with 8 #8 builds with all interior bars on the 14 in faces. The NLP smooth P-M uses the real bar area, `opts.cover`, and the tie diameter.
