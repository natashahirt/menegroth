---
id: deci-d62ed9c1
type: decision
project: menegroth
parent_id: menegroth
title: Footings draw on their support nodes; the base stays fixed
node_label: Footing follows support node
tags: scene,footing,viewer,analysis
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/scene/build.jl@f56c933, StructuralSynthesizer/src/scene/components.jl@f56c933,
  viewer/src/building.ts@7552f38, viewer/src/main.ts@f56c933, docs/src/reference/scene_format.md@7552f38
session_id: sess-d449819c
created_at: '2026-11-05T03:00:37.562789+00:00'
updated_at: '2026-11-05T03:00:37.562789+00:00'
---
A spread footing is the designed concrete on a support node that the solved model already contains. The analysis stays fixed-base: no soil spring and no footing mesh. The scene binds each footing to those support nodes (skeleton vertex index, which is the analysis-model node because _merge_shell_nodes keeps skeleton nodes first). The viewer colors the footing with the same deflection scale as the building, using that node's displacement, and draws it in the column concrete in geometry mode. A scene written before the bind buffer matches fully fixed supports by plan footprint.
