---
id: deci-46d9c7bc
type: decision
project: menegroth
parent_id: deci-977ff251
title: 'Phase 7 seismic system: walls are the seismic system, frame is gravity-only
  (option a)'
node_label: 'P7: walls-only seismic system'
tags: walls,phase-7,seismic-system,frame,deformation-compatibility,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a81d5f89
created_at: '2026-10-29T11:54:55.324292+00:00'
updated_at: '2026-10-29T11:54:55.324292+00:00'
has_child_rationale: User chose option (a) for Phase 7
---
Phase 7 declares the walls as the seismic force-resisting system. Beams framing into columns are modeled pinned for this system, so the walls take essentially all lateral force. The frame is still checked for the drift it is forced to follow (ASCE 7-22 §12.12.5 for SDC D-F; corpus lookup required before implementing). Frame members are still checked for wind and seismic combinations with the forces the analysis assigns. Dual system (fixed beams, moment-frame factors and detailing, §12.2.5.1 25% check) is later work.
