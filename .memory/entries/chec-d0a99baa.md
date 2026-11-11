---
id: chec-d0a99baa
type: checkpoint
project: menegroth
parent_id: plan-882e912b
title: Special-wall end gap and base development length
node_label: (k) gap and (j) development
tags: aci-318, special-walls, 18.10.6.4, 18.10.2.3
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-d005c4e1
created_at: '2026-11-11T18:18:07.759807+00:00'
updated_at: '2026-11-11T18:18:07.759807+00:00'
---
§18.10.6.4(k) and §18.10.6.4(j) are recorded on the wall detail. The displacement route is still closed.

(k) The horizontal web bars have to end within 6 in. of the wall end (ACI 318-19 §18.10.6.4(k), page 329). Equality reaches. A meter length that lands a fraction of a nanometer past 6 in. still reaches; that tolerance is binary rounding, and a hundredth of an inch past 6 in. does not. The hook is not chosen: the boundary transverse reinforcement is not placed.

(j) At the base of a continuous wall line, where the critical section is, the placed vertical bars are developed at 1.25 times their §25.4.2.1 tension length, including that section's 12 in. minimum (ACI 318-19 §18.10.2.3(b), page 320). A No. 3 bar whose equation is under 12 in. stays at 12 in., and the factor makes 15 in. Changing f′c while the floor still governs does not move it. A larger bar moves only that length. §18.10.6.4(j) wants the development length of the largest bar in the special boundary element. Those bars are not placed, so the recorded length is not the extension. The support is not stated as a footing, mat, or pile cap, so the 12 in. extension is not applied. §18.13.2.4 is not built. The 12 ft flexural extension of §18.10.2.3(a) is not placed.

A story above the base, a line that is not continuous, and an element that is not required do not record (j).

Tests: StructuralSizer walls/test_special_boundary.jl 320/320 (logs/test_StructuralSizer_20261111_130308.log). StructuralSynthesizer analyze/test_wall_detailing.jl 42/42 (logs/test_StructuralSynthesizer_20261111_131025.log).

Next is the displacement route, §18.10.6.2, using the design displacement at the center of mass of the line's top floor. Which ELF cases supply that displacement is not settled. Boundary bars wait on §25.7.2.2 and §25.7.2.3. SDC D–F and coupling beams stay out.
