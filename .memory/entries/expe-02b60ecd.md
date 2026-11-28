---
id: expe-02b60ecd
type: experiment
project: menegroth
parent_id: expe-fc2f89b4
title: 12 m bay passes at a 36 in column after the soft catalog
node_label: 12 m bay passes
tags: columns,12 m,wind,catalog,sensitivity
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-8bbe7155
created_at: '2026-11-14T23:30:56.250203+00:00'
updated_at: '2026-11-14T23:30:56.250203+00:00'
---
The 12 m bay office (5 stories, category B, row A3, rigid diaphragm, Chapter 27 wind at qz=1.0 and qh=2.0) now passes. Last run stopped at column Pu=3368 kip. This run: column 36×36 in at ρg=0.0617, beam depth 54 in, slab 20 in, walls stayed 9.8 in at ρl=0.0025, drift ratio 0.05. Reported critical check is Column 30 column_shear at the clamped passing ratio 1.00. Runtime 1120 s.

The uncommitted medium-office change leaves story 0 without a beam grid, so the sensitivity runner adds the four grade bays itself before claiming the ground-story piers. Wind at these pressures did not thicken the walls.
