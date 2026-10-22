---
id: note-b5c41a67
type: note
project: menegroth
parent_id: deci-f7b346a9
title: Swept remaining DDM verify fixtures 2×2→3×3 (suite green under §13.6.1.1)
node_label: Swept remaining DDM verify fixtures 2×2→3×3 (suite
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/verify_design_graph.jl@a99bf6b, scripts/runners/verify_incremental_engine.jl@a99bf6b,
  scripts/runners/verify_warm_state_incremental.jl@a99bf6b
session_id: sess-c5505a30
created_at: '2026-10-22T16:12:29.592609+00:00'
updated_at: '2026-10-22T16:12:29.592609+00:00'
---
Follow-on to the Step A fixture fix: the same 2×2+DDM collision (ACI 318-11 §13.6.1.1 requires ≥3 continuous spans each direction) existed in three more gate runners. Bumped the five DDM-routed fixtures from 2×2 to 3×3 bays (total plan dims unchanged), refreshed stale '2×2 bays / 9 columns' comments to '3×3 / 16 columns', and left the vault/beam-column fixtures untouched:
- verify_design_graph.jl: build_verify_building, build_per_story_building (skipped vault build_beam_column_building)
- verify_incremental_engine.jl: build_building
- verify_warm_state_incremental.jl: build_building

All three gates pass: verify_design_graph ALL CASES PASS (graph==legacy, 15 invariants), verify_incremental_engine 17/17, verify_warm_state_incremental 12/12, all exit 0. Combined with the incremental gate (127/127), the full exact-first gate suite is green again under the new DDM presize validation.
