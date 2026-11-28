---
id: plan-440fc73d
type: plan
project: menegroth
parent_id: plan-3986c866
title: Shell beams are frames on the shell nodes, checked against hand solutions
node_label: frame beams on shell nodes
tags: slabs,shell,beams,fea,composite
status: active
open_threads: 2
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/panel_shell_beams.jl@7521f0b
session_id: sess-c44f0c35
created_at: '2026-11-03T16:05:37.447756+00:00'
updated_at: '2026-11-06T22:35:57.127487+00:00'
---
Locked 2026-11-03. Beams are frame elements, not shells. Each beam is a chain of frame elements between the shell nodes that lie on its line, so the beam and the slab share those nodes.

Concrete: the frame is the web only, offset below the slab mid-plane by h_slab/2 + h_web/2 on the local f3 axis (upward at pitch 0). The shell is the flange.

Steel composite: no offset. The frame carries the AISC service inertia on the shell nodes. Sagging elements use I_LB (Commentary C-I3-1, aisc-360-22 pages 501-502) minus the slab's own bending b_eff*t^3/(12n), which the shell already provides. Hogging elements use the cracked section. A continuous member's constant 0.6/0.4 form (C-I3-5) is the coarser alternative; the shell uses the same per-element split as the steel frame path. The first run, before studs exist, uses bare I_s. The re-run after sizing uses the stud layout.

Steel non-composite: bare I_s, no offset.

ENGINEERING JUDGMENT: the steel beam is slip-reduced and the shell is uncracked. ACI 318-11 §8.7 asks that stiffness assumptions be reasonable and consistent. The mismatch sends some load to the slab. Beam design still uses tributary loads.

Checks against known results, before the story is wired in:
1. A one-way strip with ν near 0 deflects as a beam, 5wL^4/384EI.
2. The same strip plus an offset web deflects as the transformed T-section.
3. Support reactions equal the load on the panel.

Still to wire: one model per story, the re-run after beam sizing, and reporting the shell's beam forces beside the tributary design.
