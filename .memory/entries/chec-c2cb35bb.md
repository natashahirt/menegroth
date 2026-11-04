---
id: chec-c2cb35bb
type: checkpoint
project: menegroth
parent_id: plan-ec9a5d12
title: 'Commit audit correctness fixes: tension-controlled flexure and fail-closed
  checks'
node_label: 'Commit audit correctness fixes: tension-controlled'
tags: audit,commit,flexure,tributary,ddm
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-dce08e3a
created_at: '2026-11-04T16:28:39.808667+00:00'
updated_at: '2026-11-04T16:28:39.808667+00:00'
---
Committed the correctness fixes from the audit follow-through. A faced floor with no tributary cache throws instead of dropping its load (grade and unloaded unknown faces are still omitted). A DDM §13.6.1.4 offset lookup that throws is a violation. Slab and footing depth checks require εt ≥ 0.005 (ACI 318-11 §10.3.4). The FEA mesh key includes column shape. The checkerboard partition is recomputed each call. Voronoi area errors propagate.

The flat-plate DDM, EFM, and design-check modules, and the Winkler mat, are included as the file splits those corrections live in. The rest of the other session's working tree is not in this commit.
