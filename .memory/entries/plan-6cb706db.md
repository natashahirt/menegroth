---
id: plan-6cb706db
type: plan
project: menegroth
parent_id: plan-a7ebaacc
title: Name the punching face, then grow the solid head one bay and re-solve
node_label: Punching face then bay growth
tags: solid-head,punching,direction,aci-318
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-d8fc1d99
created_at: '2026-11-11T22:21:43.051912+00:00'
updated_at: '2026-11-11T22:21:43.051912+00:00'
---
Confirmed sequence. Column punching returns the vertex where the signed eccentric stress peaks, and vu stays the absolute-moment value already reported. A tie or a zero moment names no face. The frame passes the signed joint moment. The head grows one bay only in that direction, then the frame is solved again, and it stops when the check passes, the next bay is blocked, or the governing ratio does not fall. The rectangle corner fraction stays the design size until that bay-set loop agrees with it on a rectangle. Rib-web eccentric shear is not given a face. Hogging outside the head is not part of this.
