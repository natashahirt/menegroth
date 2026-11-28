---
id: deci-cd3ba6b6
type: decision
project: menegroth
parent_id: plan-b45b0d7f
title: Gravity-only buildings size ordinary walls from the axial combinations
node_label: Gravity axial sizes walls
tags: walls,ordinary-walls,gravity,reinforcement
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-8cb63db2
created_at: '2026-11-05T20:20:57.141134+00:00'
updated_at: '2026-11-05T20:20:57.141134+00:00'
---
A building with walls and no lateral system still runs the ordinary-wall stage. The demands are the ASCE 7 gravity strength combinations on the pier cuts. Wind and earthquake are not added. ρl and ρt are raised on the existing grid when the given ratios fail. Thickness is not changed. A building with no walls still returns without a result.

The roof pressure already stored on the building is the :Lr companion, the same default the unfactored gravity solve uses. The empirical bearing factor is ACI 318-19 Table 11.5.3.2 restrained, k = 0.8: a floor-to-floor wall, braced against translation, rotation restrained. That matches the monolithic wall-to-slab joint. Concrete comes from the wall when it has one, otherwise the column material cascade. Rebar is that cascade.

When rigid-diaphragm masters exist, the combinations include the story geometric stiffness of each factored gravity. Without those masters the combinations stay first-order. The pier cut is the shell and frame solution. Tributary area assigned to a column is not added again.

This narrows the earlier statement that a gravity-only design omits the stage. Lateral design is unchanged.

A column whose every span in one direction lies on a parallel wall has no equivalent-frame span in that direction. Its moment there is written as zero. A column removed by an opening is still an error.

The FEA secondary strip result now carries qu, which the transverse short-wall moments read.

Checked by analyze/test_ordinary_wall_stage.jl: 372 passed, including a gravity-only pier sizing test and design_building publishing gravity wall records with no seismic drift.
