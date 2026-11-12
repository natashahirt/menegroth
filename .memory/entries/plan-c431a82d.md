---
id: plan-c431a82d
type: plan
project: menegroth
parent_id: todo-701f6fca
title: 'Special walls: composer, rest of §18.10, flanged section, then building wiring
  through SDC B and C'
node_label: Special wall integration plan
tags: walls,aci-318-19,18.10,special-wall,plan
status: active
open_threads: 7
success: 'null'
files: ''
session_id: sess-ad654b18
created_at: '2026-11-10T17:22:23.971942+00:00'
updated_at: '2026-11-12T02:08:54.267821+00:00'
has_child_rationale: The §18.10.6 checks are in and the two unclear expressions are
  resolved, so the composer and building integration can be sequenced.
---
Decisions (user, 2026-11-10): stage through SDC B and C first; build the §18.10.5.2 flanged section in this effort; when the user has not stated continuity and a single critical section, use the §18.10.6.3 stress route.

1. Finish the pure checks. §18.10.6.2(b)(ii) b ≥ √(0.025 ℓw c) as the shortcut for (iii) (deci-598f8d2b). §18.10.6.5(a) hooks unless Vu < λ√f′c Acv, and (b) ties per §18.7.5.2(a)–(e) over the §18.10.6.4(a) length when the boundary ratio exceeds 400/fy, at Table 18.10.6.5(b) spacing. One shared λ√f′c Acv function, called by detail_wall too.

2. Composer in StructuralSizer (walls/special_wall.jl). Input: one wall edge (section, materials, demands, route statements). Output: route, required, every governing term (length, width, vertical extent, (ii) or (iii), confinement amount, spacing), or the §18.10.6.5 result. Oracle: NEHRP 2020 Design Examples Vol. 1 (corpus: nehrp-2020-design-examples-v1, PDF pages 156–158): ℓw 164 in., hwcs 2811 in., δu 26.84 in., c 95 in., b 26 in., hu 158 in., Mu 24,976 kip·ft, Vu 576 kip. Check whether later pages carry the confinement amount too.

3. Rest of §18.10 as checks. Decode the garbled pages for §18.10.2–§18.10.5 first (PDF pages ~320–325). Then §18.10.2 reinforcement, §18.10.3 Ve = Ωv ωv Vu, §18.10.4 Vn and the 8√f′c / 10√f′c caps, §18.10.5 flexure.

4. Flanged section, §18.10.5.2. Effective flange width from effective_flange_overhang. Strain-compatibility c and gross-section σ for L and T assemblies, with each end in compression. The NEHRP wall (flanged end: c small, no element) is a test.

5. System vocabulary. Table 12.2-1 rows A1 and B4 (special reinforced concrete shear walls), R/Ω0/Cd/height limits read from the rendered table (PDF page 173). WallsSeismicSystem accepts them. A check-set trait picks ordinary or special per-pier checks and thickness proposals; mesh, solve, combinations, and drift stay shared. design_ordinary_walls! keeps its ordinary behavior.

6. Building inputs: δu at the top of the wall, c by strain compatibility at each earthquake combination per edge, σ from the gross (flanged) section, hwcs and hu from the stack and clear story height, Mu and Vu at the critical section. Route statements per wall line; absent → stress route.

7. Wire into the wall loop for SDC B and C: boundary and §18.10 checks become wall check records; width shortfalls (hu/16, 12 in., (ii)/(iii)) become thickness targets in the settle! loop.

8. Later: boundary hoops in detail_wall with special=true; then SDC D–F through ASCE 7 §12.12.4 and ACI §18.14. Coupling beams separate.
