---
id: todo-e903a5ae
type: todo
project: menegroth
parent_id: plan-93ed2402
title: 'Todo: Fix face-vertex topology bug during framing edge-splitting'
node_label: 'Todo: Fix face-vertex topology bug during framing '
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-8158ce81
created_at: '2026-07-17T09:45:49.952768+00:00'
updated_at: '2026-07-17T09:45:49.952768+00:00'
---
Fix a topological bug in `populate.jl` where `_split_host_edge!` subdivides host edges for framing landings but fails to update the skeleton's face-vertex and face-edge indices. This inconsistency causes a crash in `_compute_inward_normal` (used for column offsets) when a column is located at a vertex that is part of a subdivided boundary face.

The engineer will update `_split_host_edge!` to:
1. Identify all faces that contain the original edge.
2. Update the `face_vertex_indices` for those faces to insert the new midpoints in the correct CCW sequence.
3. Update the `face_edge_indices` to replace the single original edge index with the new sequence of sub-edge indices.

This fix will restore topological consistency and enable integration tests that currently crash.
