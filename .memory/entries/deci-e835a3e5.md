---
id: deci-e835a3e5
type: decision
project: menegroth
parent_id: plan-b0095736
title: 'Beam end releases default by material: steel/timber pinned, concrete fixed;
  lateral system comes from connections'
node_label: Material release defaults
tags: releases,lateral,walls,steel,timber,concrete,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-fd45019b
created_at: '2026-10-29T13:07:08.277893+00:00'
updated_at: '2026-10-29T13:07:08.277893+00:00'
has_child_rationale: User wants smart defaults so users make few granular decisions
---
User decision (2026-10-29): defaults should be smart so the user rarely sets releases.

- Steel `:girder`/`:beam` with `lateral_role = :gravity` -> (:pinned, :pinned) (simple shear connections, AISC 360-16 §B3.4a p.69, §J1.2 p.169). `:moment_frame` girder stays (:fixed, :fixed) (Cmt. §B3.4 p.331).
- Timber `:girder`/`:beam` -> pinned (engineering judgment, NDS not in corpus).
- Concrete stays fixed (monolithic, ACI 318-11 §8.9.3). In the whole-building analysis the concrete frame shares lateral load with walls; walls should be sized for 100% (IsolatedWallShare(1.0)) and the frame checked for deformation compatibility (ASCE 7-22 §12.12.4 / ACI §18.14, SDC D-F). Whether ASCE 7 requires 100% on walls is not yet confirmed in the corpus.
- The steel/timber lateral system is therefore defined by where moment connections (`:moment_frame`) or bracing are placed.
- Explicit Segment `:fixed`/`:pinned` overrides are always respected.
- The `:gravity_frame` lateral role is removed; `WallsSeismicSystem.prepare_lateral_model!` no longer touches releases (only refuses a building with no walls).

Open finding: `_create_offset_nodes` (asap/utils.jl:16) locks all three rotations at every non-support node (dof = [true,true,true,false,false,false], since commit 02cdb7ccd). Element end releases still change beam moments, but columns are rotationally fixed at every floor, so frame sway stiffness and column moments from beam end moments are not captured. Raised with user.
