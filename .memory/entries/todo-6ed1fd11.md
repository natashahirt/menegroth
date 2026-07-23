---
id: todo-6ed1fd11
type: todo
project: menegroth
parent_id: plan-f933342a
title: 'P2b: exclude generated_at from the hashed/canonical DesignState export'
node_label: 'todo: P2b determinism'
tags: p2,determinism,export-seam,content-hash
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-1bf3bf92
created_at: '2026-07-23T17:52:16.918457+00:00'
updated_at: '2026-07-23T17:52:16.918457+00:00'
---
design_state.jl bakes generated_at=string(design.created) into the export whose purpose is a deterministic content hash. Move the timestamp out of the hashed portion (separate non-hashed envelope) or exclude it; add a test that two identical designs built at different times hash identically. Mark done by discarding with reason 'completed'.
