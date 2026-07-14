---
id: todo-d5cc801d
type: todo
project: menegroth
parent_id: plan-68155c81
title: A4 — Diaphragm design & lateral distribution (rigid/semi-rigid/flexible)
node_label: 'A4: Diaphragm design'
tags: todo,diaphragm,chord,collector,rigid,flexible,lateral,phase-a
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-71279841
created_at: '2026-07-14T01:35:05.609518+00:00'
updated_at: '2026-07-14T01:35:05.609518+00:00'
has_child_rationale: Lateral forces must be distributed through a designed diaphragm
  to the LFRS
---
# A4 — Diaphragm design & distribution

Once lateral demands exist (A3), they must flow through a **diaphragm** to the vertical LFRS. Today `to_asap!` supports diaphragm modes `:none/:rigid/:shell` for stiffness but there is **no diaphragm design** (shear, chord tension/compression, collectors/drag struts) and no rigid-vs-flexible classification.

**Build:** diaphragm classification (rigid/semi-rigid/flexible per ASCE 7 / material code), in-plane shear & chord/collector force recovery, and material-specific diaphragm checks (concrete-on-deck, bare metal deck per SDI, wood per SDPWS). Distribution to walls/frames by relative rigidity + torsion is the wall program's S2 (`plan-w0000001`); this todo is the diaphragm element itself.

**Depends on:** A3 (demands), and material canon (SDI/SDPWS) from Phase E.
