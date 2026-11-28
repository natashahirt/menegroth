---
id: deci-359e22af
type: decision
project: menegroth
parent_id: todo-701f6fca
title: Special-wall slice is the §18.10.6.2(a) displacement trigger only
node_label: Displacement BE trigger
tags: walls,aci-318-19,18.10,boundary-element,special-wall
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-34a7f10d
created_at: '2026-11-09T20:38:30.884777+00:00'
updated_at: '2026-11-09T20:38:30.884777+00:00'
has_child_rationale: Phase 9 special walls were tabled on missing c and missing §18.10
  text. c now exists, and Eq. (18.10.6.2a) is readable, so that check can land without
  confinement or a building hookup.
---
displacement_boundary_element (StructuralSizer/src/walls/special_boundary.jl) evaluates ACI 318-19 §18.10.6.2(a), Eq. (18.10.6.2a) (corpus: aci-318-19, page 326): a special boundary element is required when 1.5 δu/hwcs ≥ ℓw/(600 c), and δu/hwcs is not taken less than 0.005. The section applies only when hwcs/ℓw ≥ 2 and the caller states that the wall has a single critical section for flexure and axial load. The words between "that are" and "from the base of structure" are not readable in the text extract, so continuity from the base is not inferred. When the section does not apply, required is nothing, because §18.10.6.3 is the other evaluation and its clause body is garbled.

c is an argument. It is the largest neutral-axis depth at nominal moment strength for the factored axial force consistent with δu (§22.2, as §18.10.6.2 states it). The function does not substitute the Cardenas closed form.

Not in this slice: §18.10.6.2(b) vertical extent, the stress trigger §18.10.6.3, confinement §18.10.6.4, coupling beams §18.10.7, and turning special=true on in building detailing. Bars are still not placed. The older formula c ≥ ℓw/(600·(δu/hw)) in todo-w0000010 drops the 1.5 and the 0.005 floor; do not use it.

Hand checks in test_special_boundary.jl, 15/15 fresh (logs/test_StructuralSizer_20261109_153533.log). ℓw = 20 ft, hwcs = 60 ft, δu = 6 in, c = 40 in: 1.5×(6/720) = 0.0125 ≥ 240/(600×40) = 0.010, required. The same wall with δu/hwcs below 0.005 uses the floor, 0.0075 < 0.010, not required. hwcs/ℓw = 1.5 returns required = nothing.
