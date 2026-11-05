---
id: deci-bfa4c684
type: decision
project: menegroth
parent_id: plan-7f7bfe8c
title: Wall supports in direct design and the equivalent frame
node_label: Walls as DDM and EFM supports
tags: aci-318-11,ddm,efm,walls,13.6.3.3,R13.1
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-61436f59
created_at: '2026-11-05T15:54:07.474411+00:00'
updated_at: '2026-11-05T15:54:07.474411+00:00'
---
A concrete wall cast with the slab is a support in both direct design and the equivalent frame.

ACI 318-11 R13.1 (page 243): a wall that supports the whole panel edge is a beam of infinite stiffness; a shorter wall-like column is a column. R13.6.3.3 (page 254): a slab cast integrally with a concrete wall, with little rotation, uses §13.6.3.3 Column (5) — interior negative 0.65 M0, positive 0.35 M0, exterior negative 0.65 M0. Column (3) stays 0.26 / 0.52 / 0.70 for a column edge. Column (1), 0 / 0.63 / 0.75, is the simply-supported wall and is not the default.

A wall longer than half the panel edge (the boundary edge it lies on, otherwise the median column spacing) is fully restrained. At that length, feeding the wall length into §13.7.3.3 as c2 makes (1 − c2/l2) singular, so the joint is fixed instead. The face dimension is the wall thickness. A shorter wall is a column of thickness by length in the equivalent frame. Direct design does not place that short wall, because its supports are the column list; it reports that and leaves the frame to EFM or FEA.

On the single-panel direct-design path there is one exterior negative. Slab steel takes the larger of Column (3) and Column (5). Column flexural demand stays on Column (3). Punching stays on §13.6.3.6, 0.3 M0. A frame-line span that ends on a fully restrained wall uses Column (5) for that span.

The equivalent-frame joint on a full-edge wall has no column stub. uz and the in-plane rotation are fixed (ry in the XZ frame). Hardy Cross gives that joint infinite Kec so the slab distribution factors go to zero. The shell model matches: uz fixed, and rotation about the wall axis fixed. A span whose midpoint is off the slab, including a shaft, is not one frame.

This replaces the earlier refusal of any wall in DDM and EFM. §13.6.1.1 still requires three continuous spans on the shortest frame, so the open core floors stay out of direct design.

Parallel walls (αf infinite, §13.6.4 redistribution) and one-way shear along the wall (§11.11.1.1) are not in this slice.
