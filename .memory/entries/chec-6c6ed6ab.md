---
id: chec-6c6ed6ab
type: checkpoint
project: menegroth
parent_id: plan-a8387ad9
title: Boundary spacing, floor strength, embedment, and web-bar termination
node_label: Spacing and continuity checks
tags: walls,aci-318-19,18.10,boundary-element,checkpoint
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7909dbac
created_at: '2026-11-10T15:51:03.586315+00:00'
updated_at: '2026-11-10T15:51:03.586315+00:00'
has_child_rationale: §18.7.5 is readable, so the wall spacing limit and the continuity
  checks that do not place bars can be evaluated.
---
Pages 309–311 of ACI 318-19 were re-decoded and spliced into the corpus text. The one new glyph is Times cid 148 = ≤, read off the §18.7.4.3 line. Eq. (18.7.5.3) and §18.7.5.2(d)–(f) are readable. §18.10.6.5(a) still has no radical on λ√f′c.

Checks added in StructuralSizer, fresh tests 210/210, logs/test_StructuralSizer_20261110_104258.log:
- transverse_spacing_so: so = 4 + (14 − hx)/3 inches, not above 6 in. and not taken below 4 in. (corpus: aci-318-19, pages 310–311).
- wall_boundary_tie_spacing: Table 18.10.6.5(b), page 332. Grade 60 is 6db/6 in. inside the critical reach and 8db/8 in. outside. Grade 80 is 5db/6 in. inside and 6db/6 in. outside. Grade 100 is 4db/6 in. inside and 6db/6 in. outside.
- boundary_element_vertical_spacing: §18.10.6.4(e), page 328. Least of one-third of the least boundary dimension (not the column one-fourth), 6db or 5db for Grades 60 and 80, so, and the table. Grade 100 has no §18.7.5.3 bar term.
- floor_concrete_at_boundary: §18.10.6.4(h). At least 0.7 f′c; equality meets.
- web_vertical_support_spacing: the 12 in. sentence of §18.10.6.4(i). §25.7.2.2 diameter is not evaluated.
- boundary_support_extension: §18.10.6.4(j). ℓd into the support, and at least 12 in. into a footing, mat, or pile cap unless the caller passes a longer §18.13.2.4 length. ℓd itself is the caller's.
- horizontal_web_termination: §18.10.6.4(k). Within 6 in. of the wall end. A straight bar is permitted when the boundary can develop it and As·fy/s does not exceed As·fyt/s.

§18.7.5.2(a)–(d) stay configuration and are not checked. Item (ii) and §18.10.6.5 stay uncoded. The composer is still ahead. Files not pinned.
