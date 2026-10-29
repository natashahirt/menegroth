---
id: chec-9f5b3c46
type: checkpoint
project: menegroth
parent_id: deci-1366cc5c
title: Building composite deflection uses Eq. C-I3-5
node_label: C-I3-5 on the beam
tags: composite,deflection,C-I3-5
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-e11c7f1d
created_at: '2026-10-29T03:26:13.907549+00:00'
updated_at: '2026-10-29T03:26:13.907549+00:00'
has_child_rationale: The building check now uses the commentary's constant service
  inertia.
---
check_composite_beam returns I_service. A beam whose sagging-positive moment is negative anywhere (the existing 1 N·m zero) uses AISC 360-22 Commentary Eq. C-I3-5: 0.6 I_pos + 0.4 Ix. I_pos is I_LB at the peak sagging station. A beam with no such sample keeps I_pos. composite_deflection_scale is Ix / I_service. The sizer already did this. Composite-context tests: 221 passed, including the hand check and the two-bay frame.
