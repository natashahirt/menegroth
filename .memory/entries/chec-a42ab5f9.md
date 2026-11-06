---
id: chec-a42ab5f9
type: checkpoint
project: menegroth
parent_id: deci-d259f689
title: Two-level floor ran; preparation, columns, and ribs followed
node_label: Floor follow-ons
tags: slabs,columns,joists
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-73c5670b
created_at: '2026-11-06T12:22:16.779796+00:00'
updated_at: '2026-11-06T12:22:16.779796+00:00'
---
The 2×2 individual flat plate (FEA, 125 psf) designed through propose, envelope, commit, and lock. 42 checks passed. Shared columns grew and none shrank. A one-slab-per-story floor stayed on the single level.

Preparation of a flat plate now keeps the code minimum thickness and its self-weight. The design graph is the sizing pass.

A wall-supported two-way floor with no beams sizes concrete columns in the floor concrete. The 24 ft wall building produced RC sections. The support pipeline passed 20 checks.

A planned joist spacing keeps a beamless one-way or two-way floor from being rejected or turned into a flat plate, and the topping is sized on that spacing. Each rib group keeps its own flange unless uniform_geometry is set. rib_form defaults to :mip; :standard_pan has no pan list yet.
