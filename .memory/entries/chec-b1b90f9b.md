---
id: chec-b1b90f9b
type: checkpoint
project: menegroth
parent_id: plan-882e912b
title: Boundary hoops, coupling beams, and the D–F refusal
node_label: Hoops, beams, D–F
tags: aci-318, special-walls, coupling-beams, sdc
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-62ae10e8
created_at: '2026-11-11T22:12:32.744063+00:00'
updated_at: '2026-11-11T22:12:32.744063+00:00'
---
Boundary transverse reinforcement is specified, not placed. `boundary_tie_bar_size` is §25.7.2.2: No. 3 for No. 10 and smaller, No. 4 for No. 11 and larger or a bundled bar; the crosstie matches. `boundary_hoop_arrangement` uses §18.10.6.4(f). Overlapping hoops start when the element is longer than twice its thickness. A crosstie at every bar that is not a hoop corner is the accepted arrangement (deci-3aa2a20b), stricter than the 6 in. clear of §25.7.2.3(b). The wall detail records that arrangement when a required element has a known length, and says the tie size is not chosen because the boundary longitudinal bars are not placed.

Coupling beams are classified, not detailed into the opening model. `coupling_beam_route`: ℓn/h ≥ 4 is §18.10.7.1 (the §18.6.2.1(b) and (c) waiver is not taken); ℓn/h < 2 and Vu at or above 4λ√f′c·Acw is §18.10.7.2 (the loss-of-stiffness waiver is not taken); otherwise §18.10.7.3 returns `:either` and does not choose. `coupling_beam_diagonal_strength` is Eq. (18.10.7.4): Vn = 2·Avd·fy·sinα, not above 10√f′c·Acw, with no λ on the cap. Both radicals were read from the rendered pages (PDF 332–333). The existing opening-segment split (beam when longer than four times its depth, otherwise a strut and a tie) is unchanged. §18.10.7.4(c) and (d) confinement is not implemented.

SDC D, E, and F still refuse building design. Table 12.2-1 still permits A1 and B4 up to 160 / 160 / 100 ft, and the message still says that rather than NP. The throw now names ASCE 7-22 §12.12.4 and ACI 318-19 §18.14.3.3: induced moments from δu are not calculated, so §18.14.3.1 requires §18.14.3.3, and that member design is not applied. `gravity_frame_seismic_section` is the path selector. `gravity_beam_transverse_limit` is the numeric part of §18.14.3.2(a): spacing ≤ d/2, and hoops only when Pu exceeds Ag·f′c/10. §18.6.5, §18.7.4 through §18.7.6, and §18.2.5 through §18.2.8 are not in the library, so D–F design stays closed. §18.14.5 was not implemented; its drift formula was not confirmed from a rendered page.

Tests: StructuralSizer walls/test_special_boundary.jl 366/366; loads/test_seismic_elf.jl 144/144; StructuralSynthesizer analyze/test_wall_detailing.jl 50/50 on a restarted test server (port 18400). The first detailing run failed on the old server, which had not loaded the new sizer method.
