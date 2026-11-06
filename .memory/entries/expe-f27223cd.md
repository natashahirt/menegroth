---
id: expe-f27223cd
type: experiment
project: menegroth
parent_id: plan-dc2e3168
title: Rigid office withholds no solid pier
node_label: Rigid office withholds no solid pier
tags: walls,rigid-diaphragm,slenderness,gravity
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-4269ff05
created_at: '2026-11-06T12:03:18.225964+00:00'
updated_at: '2026-11-06T12:03:18.225964+00:00'
---
The rigid office is twelve walls, each 6 m long and 0.3 m thick, three stories, gravity only, rigid-diaphragm masters present. Every pier is a wall (length/thickness = 20). The gravity stage checks all twelve. None is withheld. In-plane shear, axial-flexure, and bearing all passed, and reinforcement stayed at 0.0025.

A door cut into the south ground wall leaves two 0.8 m piers (length/thickness = 2.67), which §2.3 routes as columns. With the rigid diaphragm, §6.6.4.3(a) passes, so the column check runs. In-plane kℓu/r = 15 and is inside the neglect limit. Out-of-plane kℓu/r = 40 (r = 0.3b, b = 0.3 m, ℓu = 3.6 m, k = 1) and the §6.2.5.1 limit is below 40, so the column strength check is not run. The door head is a beam and its flexure and shear pass. §6.6.4.6 is not applied.

The same door with no rigid diaphragm records "column segment withheld" on both piers, clause ACI 318-19 6.6.4.3, and does not run the slenderness or strength checks. The wide piers stay on the first-order cut.

analyze/test_rigid_office_piers.jl passed 116/116 (log test rerun after the two-record assertion). The ground-story lintel split passed in the stage suite, 406/406. The deep-beam unit suite passed 112/112.
