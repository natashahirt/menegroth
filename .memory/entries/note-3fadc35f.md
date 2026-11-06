---
id: note-3fadc35f
type: note
project: menegroth
parent_id: deci-94541642
title: Column clear spacing uses the nominal bar diameter
node_label: Nominal db for spacing
tags: columns,rebar,spacing
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-b24b26c6
created_at: '2026-11-06T23:13:36.226428+00:00'
updated_at: '2026-11-06T23:13:36.226428+00:00'
has_child_rationale: The spacing check rejected layouts the constructor had placed
  exactly on the code limit.
---
ACI 318-19 §25.2.3 uses the nominal bar diameter. The check was using sqrt(4 As/π). For a #8, As is 0.79 in², so that diameter is about 1.003 in against the nominal 1.000 in, and a 20×20 with 24 bars (clear spacing exactly 1.5 in on the nominal diameter) was rejected. The check now uses the catalog diameter when the bar area matches a catalog bar, and the equivalent-area diameter only for a non-catalog area. A 1e-6 in comparison allowance covers floating-point placement; it does not reduce the code limit.
