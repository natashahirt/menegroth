---
id: expe-ceeb677f
type: experiment
project: menegroth
parent_id: plan-c431a82d
title: Design sensitivity after the live-load and category fix
node_label: sensitivity rerun
tags: sdc,sensitivity,18.14,18.6.5
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-12e610dc
created_at: '2026-11-13T04:24:32.250108+00:00'
updated_at: '2026-11-13T04:24:32.250108+00:00'
---
Reran scripts/runners/sdc_design_sensitivity.jl on a 5-story one-way office, two 9 m bays, live load through GravityLoads. Category B at SDS 0.20, category D at SDS 1.0. A 20-story building in D still stops at the 160 ft Table 12.2-1 limit.

Live load now sticks (cells read 80 psf). Doubling it to 160 psf, and widening the bay to 12 m, both exceed the largest RC beam section (negative flexure 1473 vs 1445 kip-ft; 12 m flexure 1173 vs 1052 kip-ft).

Columns leave the 14x14 minimum: 24x24 at five stories, 28x28 at six stories and at f'c = 3000 psi. Drift ratio moves 0.06 (base) to 0.09 (six stories), 0.11 (6 m stories), 0.17 (D at SDS 1.0). Wall thickness moves 10 in to 15 in for the taller story and to 30 in in category D, where rho_l rises from 0.0025 to 0.0065. The same A1 row in category B at SDS 0.20 stays near 10 in and rho_l 0.0025, with no 18.7.6 or 18.6.5 notes.

Category D places section 18.7.6 on 42 column notes and section 18.6.5 on 52 stirrup notes. The first summary counted member notes only and reported 18.6.5 as zero. Three columns (5, 23, 14) throw while placing crossties: 8 crosstie groups and 2 supported faces. Gravity cases stay just over 1.0 on column P-M after 8 iterations. Category D passes, governed by the wall minimum rho_l at 1.00.

Story shear is stored only when it fails, so the printed base shear is 0. One-way slabs do not fill a punching ratio.
