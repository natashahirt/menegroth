---
id: note-692cddfc
type: note
project: menegroth
parent_id: plan-9768ec38
title: Wall checks the slab moment out of plane
node_label: out-of-plane wall moment
tags: walls,out-of-plane,ACI 318-19,slenderness
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-cffaad28
created_at: '2026-11-05T22:19:21.858920+00:00'
updated_at: '2026-11-05T22:19:21.858920+00:00'
---
The slab's factored wall moment is stored on FlatPlatePanelResult as M_wall and M_wall_secondary (the envelope of |M_wall_ext| and |M_wall_int| in each span direction). The ordinary-wall stage assigns a pier the moment for its direction: perpendicular to the primary span takes M_wall, parallel takes M_wall_secondary, and a wall between those takes the larger. The pier's share is its clear length over the wall centerline.

Eccentricity is that moment divided by the pier's axial force. While it stays inside the middle third of the thickness, ACI 318-19 §11.5.3.1 still uses the empirical bearing method (corpus aci-318-19, PDF p. 170) with the real eccentricity. Outside the middle third the empirical result is not recorded as a failure. Strength is the magnified weak-axis moment: nonsway §6.6.4.5 (PDF p. 82) with k = 1 (§6.6.4.4.3, p. 81), (EI)eff = 0.25 Ec Ig from βdns = 0.6 (§6.6.4.4.4(a) and the commentary on p. 82), and Cm = 0.6 because the far-end moment is not in the action (M1/M2 = 0, §6.6.4.5.3(a)). Tension is not magnified. Pu ≥ 0.75 Pc is an unstable failure. The section is bent through its thickness with the existing smeared-layer P–M check (§22.2 / §22.4.2.1). That smear is a lower bound on the two face layers §11.7.2.3 requires above 10 in. §11.8 is not the check: its design section is midheight and would cut the joint moment in half.

Vertical reinforcement is raised on the ordinary-wall grid until the magnified moment passes. A moment of zero leaves the empirical check unchanged. Tests: StructuralSizer walls/test_walls.jl 526/526; StructuralSynthesizer analyze/test_wall_ordinary.jl 35/35.
