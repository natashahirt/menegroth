---
id: expe-fc2f89b4
type: experiment
project: menegroth
parent_id: deci-38f83e80
title: 'Sensitivity matrix: seven cases pass after the column re-check'
node_label: 'Sensitivity matrix: seven cases pass after the col'
tags: sensitivity,columns,walls,sdc
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-3505d0e2
created_at: '2026-11-14T17:18:11.804519+00:00'
updated_at: '2026-11-14T17:18:11.804519+00:00'
---
Full sensitivity matrix after frame columns are re-sized on the wall solution. Seven cases finish with every check at or under 1.00. The f′c 3000 building, which had Column 4 at a P–M ratio of 1.10, now governs on the wall minimum longitudinal steel at 1.00. Base and B/A1 govern on column shear at 1.00. Live load 160 psf now designs (30×30 columns, 42 in beams) where it used to abort on the beam catalog. The 12 m bay still stops: no RC column section covers Pu = 3368 kip with essentially no moment (group 24, Lu = 4 m). Category D / A1 is unchanged at 30 in walls, ρℓ = 0.0065. Comparisons were skipped because the 12 m case failed. Log: logs/sdc_design_sensitivity.txt. Previous table: logs/sdc_design_sensitivity_before_column_recheck.txt.
