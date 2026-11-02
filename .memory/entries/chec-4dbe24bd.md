---
id: chec-4dbe24bd
type: checkpoint
project: menegroth
parent_id: plan-b45b0d7f
title: asap/utils.jl split committed with the node-rotation fix and wall mesh on offset
  frame nodes
node_label: asap split + offset wall mesh
tags: walls,phase-7,asap,refactor,offsets,cracked-stiffness,rotations
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/asap/utils.jl@d5b33fb, StructuralSynthesizer/src/analyze/asap/asap/model_builder.jl@d5b33fb,
  StructuralSynthesizer/src/analyze/asap/asap/wall_mesh.jl@d5b33fb
session_id: sess-f5ec2eb0
created_at: '2026-11-02T14:58:09.716308+00:00'
updated_at: '2026-11-02T14:58:09.716308+00:00'
---
Commit f869236c. `analyze/asap/utils.jl` is now eight includes under `asap/asap/` (the pure-move split from plan-70e16a07, which had been left uncommitted). The same files carry:

- `_free_restrained_node_rotations!` in model_builder.jl: frees frame-node rotations that elements couple to a translation or a support, so beam end moments reach the columns and the frame sways (note-fe941551). This was not written in this session; it was in the tree and every wall test ran with it.
- Wall mesh follows offset frame nodes: when both base ends of a pier sit on architectural vertices, the pier is a bilinear quad through the frame-node plan positions at bottom and top. Ends moved off a vertex keep the stated line and the 1 mm snap. Before this, centerline offsets left wall and frame nodes separate and the rigid-diaphragm stiffness was not SPD (max |u| about 1.27e10 m).
- `_apply_stated_cracked_wall_stiffness!`: wall-shell E *= 0.35 inside to_asap!, before the first process, when wall_inputs states cracked stiffness (ACI 318-19 Table 6.6.3.1.1(a), PDF p. 78). One shell modulus also scales axial and shear; (1+beta_ds) is not applied.
