---
id: chec-d202efb4
type: checkpoint
project: menegroth
parent_id: plan-267f93b4
title: RC column groups sized on concurrent case rows, not the group envelope
node_label: Column sets drop the envelope
tags: columns,envelope,concurrent,pattern-loading,phase-2
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-4d21baf3
created_at: '2026-11-13T17:03:46.789178+00:00'
updated_at: '2026-11-13T17:03:46.789178+00:00'
has_child_rationale: Commit of Phase 2 envelope change; a memory record must precede
  the commit.
---
Phase 2, group-envelope half (branch row-f-nlp).

_rc_column_demand_sets(demands, case_rows, opts) in size_columns.jl builds each group's RCColumnDemandSet from the ColumnCaseRows only: one per member per pattern case, that member's P, Mx, My, and signed end moments together. The group envelope row (largest P of any member/case with largest M of any) was always in the set and always governed; it is now used only when a group has no case rows. Applies to discrete and NLP RC columns. Steel columns still size on the envelope (single-demand steel path).

Safety reasoning: every real (member, case) state is a row; the envelope is not a load state, and below balance it is not a bound (ACI 318-19 §22.4), which is why the case rows were added originally.

Test: test/analyze/test_column_case_sets.jl (set equals case rows; no-rows fallback to envelope; sizer never heavier and strictly lighter in at least one of three P-M pairs). 230/230 with the Row F tests. Whole-building effect not measured: committed tree cannot run design_building (issu-de1b3697).
