---
id: deci-525bb8d3
type: decision
project: menegroth
parent_id: deci-592222ad
title: Column :corner means two non-collinear free edges, not two graph edges
node_label: Column :corner means two non-collinear free edges,
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/utils.jl@7ed3107, StructuralSizer/test/slabs/test_corner_punching.jl@7ed3107
session_id: sess-54d3f6a7
created_at: '2026-10-22T19:55:04.193907+00:00'
updated_at: '2026-10-22T19:55:04.193907+00:00'
---
classify_column_position counted graph edges, so a straight perimeter (two collinear segments) was tagged :corner. Eight edge columns on a 3x3 grid were then punched with the two-sided corner section. The tag is now :edge when every boundary direction is collinear (abs(dot) >= 0.99) and :corner only when two free edges are not parallel. A re-entrant corner stays :corner. Cell classification is unchanged. test_corner_punching.jl drops the |dot|<0.5 filter and asserts 4 corner / 8 edge / 4 interior on the 3x3 grid. That file passed 89/89, including the pipeline biaxial oracles (35/35).
