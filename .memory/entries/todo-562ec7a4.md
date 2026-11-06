---
id: todo-562ec7a4
type: todo
project: menegroth
parent_id: todo-5fc00fb1
title: Write AISC 360-16 §F4; the long-span fire-rating beam stays failing
node_label: Write AISC 360-16 §F4; the long-span fire-rating b
tags: aisc,F4,flexure,fire-rating
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-63d63824
created_at: '2026-11-06T11:13:08.920602+00:00'
updated_at: '2026-11-06T11:13:08.920602+00:00'
---
Implement AISC 360-16 §F4 for strong-axis flexure of an I-section with a noncompact web (compression-flange yielding, LTB, compression-flange local buckling, and tension-flange yielding). §F5, a slender web, stays unimplemented until a separate decision.

The reminder is the failing fire-rating case, not a compactness cap. Case C in the fire-rating report sizes a continuous 40 ft beam (tributary 12 ft, DL 75 psf, LL 80 psf, L/360) and the optimizer reaches h/tw = 112, past the compact-web limit 3.76√(E/Fy) in Table B4.1b. get_Mn throws rather than using §F2. Leave that test failing. Do not add a minimum web thickness or an h/tw cap to make it pass.
