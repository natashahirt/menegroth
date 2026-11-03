---
id: deci-9d0e38ed
type: decision
project: menegroth
parent_id: menegroth
title: Shell drop patch is the clipped drop outline
node_label: clipped drop patch
tags: punching,drop-panel,fea,aci-318-11
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/model.jl@39b4e55,
  StructuralSizer/src/codes/aci/punching/openings.jl@39b4e55, StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/cache.jl@39b4e55
session_id: sess-5b3fd89f
created_at: '2026-11-03T12:49:51.496770+00:00'
updated_at: '2026-11-03T12:49:51.496770+00:00'
---
The FEA and visualization shell thickens the same drop polygon the punching check uses: ±a1 along the slab span axis and ±a2 along its left normal, clipped at a free edge through the column face. An interior column stays the full rectangle. The patch centroid is the centroid of that clipped outline.

The previous patch was a full 2·a1 by 2·a2 rectangle centred on the column, so an edge drop extended past the slab. ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200) places the critical section d/2 outside the actual drop edge. The mesh key now includes column position, orientation, and the span axis, because those change the outline.
