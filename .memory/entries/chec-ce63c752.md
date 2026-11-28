---
id: chec-ce63c752
type: checkpoint
project: menegroth
parent_id: plan-c431a82d
title: Commit special walls through coupling beams
node_label: commit special walls
tags: special-walls,commit,coupling-beams
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-721446b4
created_at: '2026-11-12T11:36:33.400640+00:00'
updated_at: '2026-11-12T11:36:33.400640+00:00'
---
Committing the special-wall slice only. The working tree also holds unrelated slab, joist, foundation, and viewer edits, and StructuralSizer.jl mixes those exports with the special-wall exports, so the commit takes the special-wall files and adds only the special-wall exports and includes.

In the commit: special boundary, shear, end bars, flanged section, coupling beams (§18.6 and §18.10.7.4), pierced-pier segment shear, the thickness jump for Ve, and the first deformation-compatibility checks (§18.14.5, column ℓo, column Ve). SDC D–F still throws because gravity columns and joints are not detailed to §18.7 and §18.4.4.1. That detailing is the next change and is not in this commit.
