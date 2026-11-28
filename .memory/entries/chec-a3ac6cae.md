---
id: chec-a3ac6cae
type: checkpoint
project: menegroth
parent_id: plan-a8387ad9
title: Flange overhang, 12 in. web extension, and hoop spacing limits
node_label: Flange and hoop spacing
tags: walls,aci-318-19,18.10,boundary-element,checkpoint
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f21322f7
created_at: '2026-11-10T15:15:31.900068+00:00'
updated_at: '2026-11-10T15:15:31.900068+00:00'
has_child_rationale: The flange width and the hoop-spacing limits are readable, so
  they are in as checks before the clauses that still depend on garbled text.
---
Implemented the next readable limits in StructuralSizer/src/walls/special_boundary.jl. Fresh tests: 141/141, logs/test_StructuralSizer_20261110_100507.log. No bars, and design_ordinary_walls! is unchanged.

- effective_flange_overhang, ACI 318-19 §18.10.5.2 (corpus: aci-318-19, page 325). From the face of the web, the lesser of half the distance to an adjacent web and 25 percent of the wall height above the section. With no adjacent web, only the height limit exists. A detailed analysis replaces the overhang and the code value stays visible.
- flanged_boundary_element, §18.10.6.4(d) (page 327). A compression flange is included at its effective width and the element extends 12 in. into the web. The two lengths are not added. A tension edge does not open the clause.
- boundary_transverse_spacing, §18.10.6.4(f) (page 328). hx is the lesser of 14 in. and two-thirds of the thickness (they meet at 21 in.). A hoop leg is at most twice the thickness. Adjacent hoops overlap the lesser of 6 in. and two-thirds of the thickness (they meet at 9 in.).

§18.10.6.4(e) is not coded. It points at §18.7.5.2 and §18.7.5.3, and those pages are still CID-garbled. Continuity limits (h)–(k) and the composer are still ahead.

Files not pinned: the working tree holds other sessions' uncommitted work.
