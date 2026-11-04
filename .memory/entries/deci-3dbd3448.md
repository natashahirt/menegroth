---
id: deci-3dbd3448
type: decision
project: menegroth
parent_id: deci-d8524cd1
title: Simple-connection steel beams size on the frame model's simple-span state,
  not the shell's hogging
node_label: Simple-connection steel beams size on the frame mo
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/slabs/slabs/story_shell_beams.jl@4af4553,
  StructuralSynthesizer/src/analyze/slabs/slabs/story_shell.jl@4af4553, StructuralSynthesizer/src/analyze/members/members/demands.jl@4af4553,
  StructuralSynthesizer/src/analyze/members/members/size_beams.jl@4af4553, StructuralSynthesizer/src/analyze/members/members/size_beams_story_shell.jl@4af4553,
  StructuralSynthesizer/test/analyze/test_story_shell_beams.jl@4af4553, scripts/runners/diag_shell_steel_hogging.jl@4af4553
session_id: sess-e3fee51d
created_at: '2026-11-04T21:36:03.897889+00:00'
updated_at: '2026-11-04T21:36:03.897889+00:00'
---
Finding (2x2 office, 40x40 ft, composite steel): beams released at both ends still carry shell hogging (12-19 kN·m on W16X26) within ~1 m of interior columns where the slab is continuous. Not P·e (bare steel eccentricity 0, P=0) and not mesh-dependent (1.0 m vs 0.5 m mesh). Cause: the release frees the beam only at the column node; at every other node the beam rotates with the slab and follows its hogging.

Decision (user-selected): a steel beam with shell release :freefree/:joist is marked `ShellBeamDemand.simple`. Its shell Mu_neg and moment fields are reported only: member_group_demands takes no shell hogging (`_design_Mu_neg`), stud fields come from the frame model (`_design_moment_fields`), and `_region_mismatches` skips it. Basis: AISC 360-16 §B3.4a (aisc-360-16 p.69) plus engineering judgment that the frame state (simple beam + slab carrying its own hogging) is also in equilibrium.

Open: the slab top-bar check over the support (the slab must carry that hogging) is not yet implemented; its effective width and demand definition need a user decision. Diagnostic: scripts/runners/diag_shell_steel_hogging.jl [mesh_m].
