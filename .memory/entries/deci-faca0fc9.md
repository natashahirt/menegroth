---
id: deci-faca0fc9
type: decision
project: menegroth
parent_id: plan-c431a82d
title: Flanged special-wall Mpr includes the return's bars inside the effective flange
node_label: Flanged special-wall Mpr includes the return's bar
tags: walls,aci-318-19,18.10,special-shear,flange,Mpr
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-71c92665
created_at: '2026-11-14T12:08:34.681885+00:00'
updated_at: '2026-11-14T12:08:34.681885+00:00'
---
A flanged special wall with hwcs/ℓw > 1.5 now computes Mpr with the return's vertical bars inside the ACI 318-19 §18.10.5.2 effective flange (page 325, source aci-318-19). The area is ρℓ of the return times its thickness times the centerline length from the joint out to the nearer of the return's end and the effective-flange end (half the web plus the overhang). Two returns on one side keep the longer reach. Web bars stay in the smeared web steel. The same bars are in the nominal moment used for φ under §21.2.4.1 (page 398): each earthquake axial is taken with that combination's moment sign, and φ is 0.60 below the shear at that maximum Mn. A flanged pier is no longer frozen at φ = 0.60, and it is no longer refused. Added end bars stay the same group at each end, and the flanged section includes them together with the return steel, so the end-bar loop can run. A pierced segment still throws when it is flanged and hwcs/ℓw > 1.5, because that path is not given the return. Two flanges, one at each end, still throw. As_flange = 0 leaves the previous concrete-only flange.

Tests: StructuralSizer walls/test_flanged_section.jl and walls/test_boundary_bars.jl, 82/82. StructuralSynthesizer analyze/test_special_shear_stage.jl and analyze/test_special_boundary_stage.jl, 1572/1572. The symmetric Category D office has not been redesigned yet.
