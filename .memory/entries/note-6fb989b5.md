---
id: note-6fb989b5
type: note
project: menegroth
parent_id: plan-1d645a44
title: Nominal bar diameter rejects the 8x14 NLP overshoot; Grade 75 has no development
  factor
node_label: nominal db and Grade 75 gap
tags: aci,detailing,columns,rebar
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-9f108bef
created_at: '2026-11-06T23:38:14.958560+00:00'
updated_at: '2026-11-06T23:38:14.958560+00:00'
---
The column constructor now checks ACI 318-19 §25.2.3 with the nominal bar diameter. An 8×14 in section cannot hold the even bar count for ρ=0.06: 8 or 10 #8 bars leave about 0.5 in clear on the 8 in face, so the builder stops at 6 bars (ρg≈0.042, already under ρ_max). The repair test that assumed a buildable 10-bar overshoot now uses 10×10 with 8 #8 (ρg=0.0632, clear spacing 1.5 in). Repair grows that start to 12×12 instead of skipping to the 32-bar cap.

ACI 318-19 Table 25.4.2.5 (printed p. 474) has ψg for Grade 40, 60, 80, and 100 only. Rebar_75 (fy=75 ksi) has no row. straight_development_length throws rather than borrowing 1.0 or 1.15.

Detailing lengths added in codes/aci/detailing.jl are ACI 318-19 §25.4 and §25.5. The slab module's tension_development_length and hooked_development_length are still ACI 318-11 §12.2 and §12.5. §25.5.1.4 forbids the §25.4.10.1 excess-steel reduction inside a lap. §25.4.10.2 also forbids it at noncontinuous supports, where development for fy is required, for bars required to be continuous, for hooks, and in SDC C–F seismic systems. The new functions default that ratio to 1. A No. 14 or No. 18 compression lap to a smaller bar is §25.5.5.4 and is not implemented. Embedded items stay out of scope.
