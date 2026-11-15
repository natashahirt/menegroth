---
id: expe-e71fc3d9
type: experiment
project: menegroth
parent_id: expe-fc2f89b4
title: D/A1 five-story design passes with δDE gravity-frame checks
node_label: D/A1 five-story design passes with δDE gravity-fra
tags: sensitivity,sdc-d,delta-de,ordinary-walls
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-9eebafb6
created_at: '2026-11-15T23:58:17.583930+00:00'
updated_at: '2026-11-15T23:58:17.583930+00:00'
---
Five-story category D, Table 12.2-1 row A1 office (9 m bay, 4 m story, 80 psf live, f'c 4000 psi, rigid diaphragm, Chapter 27 wind). Height gate still stops a 20-story building in D at 160 ft.

Result after 1264 s: passes. Column 24×24 in, ρg 0.0542. Beam depth 36 in, Vu 192 kip. Slab 15 in. Walls 30 in, ρl 0.0065 (same wall size as the earlier D/A1 pass). Drift 0.21 of allowable. Governing reported check is Column 33 column_shear, clamped to 1.00.

δDE on the gravity frame (ASCE 7-22 §12.12.4): 88 members within strength (§18.14.3.2), 9 over (§18.14.3.3), 0 unchecked. Three beam notes carry §18.6.5. Two walls received boundary hoops.

The first attempt threw inside the new check. The gravity axial used maximum(0.0, −minimum(P)), and maximum treats its first argument as a function. The column demand also left M1 as a bare 0.0, which does not promote with a Unitful Mux. Both are fixed in gravity_induced.jl. No files pinned.
