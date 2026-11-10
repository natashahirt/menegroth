---
id: plan-b231dcef
type: plan
project: menegroth
parent_id: plan-cb717409
title: Row F reporting, per-level beam floors, uniform-group floors, and per-case
  NLP columns
node_label: Row F ratios and per-case NLP
tags: row-f,frame-section-floors,nlp,columns,beams,asce-7-22,plan
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-2274119a
created_at: '2026-11-10T20:33:49.366248+00:00'
updated_at: '2026-11-10T20:33:49.366248+00:00'
has_child_rationale: User confirmed the pipeline-audit plan and asked to build it.
---
Confirmed plan (2026-11-10). No new code equations; reuse existing ACI and ASCE checks.

1. Row F results report a real governing check and ratio from explain_feasibility on each frame member, stored on ColumnDesignResult and BeamDesignResult. Drop the placeholder wall record. Catalog walk stays on is_feasible.
2. Beam floors and checkers use each framing level's beam_options, from the same pass split as sizing.
3. With uniform_column_sizing on, the floor walk covers the whole uniformity group (story or building).
4. RC column NLP constrains every load case (separate rows, no smooth max over cases). As-built check uses the demand set. Synthesizer stops sending NLP the envelope only. NLP still refuses Row F floors.
5. End-to-end dual-system test: a failing frame member is resized and passes; a capped catalog stays failing and not converged.
6. Commit only this session's files. prepare.jl rib_bays stays with the other session unless confirmed.

Order: 1, 2, 3, 4, 5, then commit. Beam NLP keeps its envelope. NLP still cannot honor section floors.
