---
id: chec-b395e0ac
type: checkpoint
project: menegroth
parent_id: plan-c431a82d
title: 'Special walls through SDC B and C: composer, flange, rows A1 and B4'
node_label: B/C special walls
tags: aci-318-19,asce-7-22,special-walls,seismic
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-678147c4
created_at: '2026-11-11T04:24:59.643882+00:00'
updated_at: '2026-11-11T04:24:59.643882+00:00'
---
Composer, flanged section, and Table 12.2-1 rows A1 and B4 are in, with behavior tests. SDC D–F is still refused, and boundary hoops are still not placed.

Composer (`special_boundary_composer`): displacement route only when continuous AND a single critical section AND hwcs/ℓw ≥ 2. Otherwise the stress route. The two routes are not blended. On the stress band, required is nothing. §18.10.6.4 only when an element is required; §18.10.6.5 only when it is not. `boundary_minimum_thickness` is the greater of the zone width and, on the displacement route, the (ii) root. It is not called from `settle!` — the stage does not yet have per-pier c, hu, and δu.

Flanged L/T gross stress and strain-compat c are in `flanged_section.jl`. An L and a T with the same flange are the same in-plane section. bf == tw recovers the rectangle.

ASCE 7-22 Table 12.2-1, rendered PDF page 173: A1 R=5 Ω0=2.5 Cd=5, B4 R=6 Ω0=2.5 Cd=5, heights D 160 / E 160 / F 100 ft. `concrete_shear_wall_system` returns those rows for B and C. D, E, and F throw with the height and §12.12.4, and the message does not say NP. Ordinary A3 in D still says NP. Footnotes on A1/B4 are not applied. `design_ordinary_walls!` uses this lookup. Pier checks stay the ordinary checks. B4 over the 20% gravity share points at row A1; B6 still points at A3.

Sensitivity, one-story office, A1 vs A3: thicknesses match and no §18.10.6 check is recorded. Dead and wind shear match. Design drift matches because both rows have Cd/R = 1. Above the Eq. 12.8-6 floor (SDS = 0.20), in-plane shear in the loaded direction scales by 4/5; the other direction stays at the gravity combination. On the floor (SDS = 0.03) the loaded-direction shear matches too, because both rows sit at Cs = 0.01, while drift still matches.

Hoops: spacing given Ash is determined. §18.7.5.2(a)–(d) does not fix a crosstie arrangement, and §18.10.6.4 needs c, so `detail_wall(special=true)` places the web curtain and does not add a hoop group. A boundary ratio above 400/fy warns and still places no ties.

Tests: StructuralSizer walls/test_special_wall.jl + loads/test_seismic_elf.jl 353/353; detailing/test_member_detailing.jl 227/227; the A1/A3 stage testset 176/176. The ordinary-wall file's `design_building publishes ordinary-wall records` errors on `longer_axis_span(::FlatPlateSpanInput)` from a parallel span edit, not this work.

Still later: per-pier c, δu, hu, σ inside the wall loop; SDC D–F once §12.12.4 exists; coupling beams; crosstie arrangement.
