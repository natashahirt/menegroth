---
id: chec-f1f4517a
type: checkpoint
project: menegroth
parent_id: plan-c431a82d
title: SDC D–F gravity frame is detailed to §18.14.3.3
node_label: D–F detailing applied
tags: aci-318, asce-7, 18.14.3.3, gravity-beam, materials, sdc
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-667f3c95
created_at: '2026-11-12T14:55:07.196003+00:00'
updated_at: '2026-11-12T14:55:07.196003+00:00'
---
Seismic Design Categories D, E, and F no longer stop the special-wall lookup or WallsSeismicSystem. Induced moments from δu are still not calculated, so the building details the gravity frame to §18.14.3.3.

(a) special_moment_frame_materials: f′c at least 3000 psi (Table 19.2.1.1), lightweight not above 5000 psi (§19.2.1.1(d)), longitudinal steel Grade 60 or Grade 80 only (§20.2.2.5). A miss is a warning on the detail. Mill tests for A615 Grade 60 are not stored, so they are noted and not treated as passed. Mechanical and welded splices are not drawn; the notes cite §18.2.7.2, §18.2.8.1, and §18.2.8.2.

(b) A gravity beam gets §18.14.3.2(a) spacing and §18.6.5 probable-moment shear. Ve uses the larger face area at both d and d′. Vc is omitted through design_beam_shear only when coupling_beam_concrete_omitted says so. §18.6.2 is not applied.

Columns in D–F are detailed with gravity_seismic, the column material, the stored Pu, and Vu_x / Vu_y. SiteConditions.sdc is set by the ordinary wall stage and read by detailing. concrete_shear_wall_system still throws when a passed hn exceeds Table 12.2-1 (160 / 160 / 100 ft). The stage does not pass a building height, so that limit is not enforced on a design. Row F stays NP in D/E/F.

Tests: StructuralSizer special-boundary and seismic-elf 551/551; StructuralSynthesizer lateral approaches 39/39. Not committed.
