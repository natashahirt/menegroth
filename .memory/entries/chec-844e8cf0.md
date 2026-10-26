---
id: chec-844e8cf0
type: checkpoint
project: menegroth
parent_id: deci-6f08250c
title: Commit the NLP column bar cap and install guards
node_label: Commit the NLP column bar cap and install guards
tags: column-nlp,commit,placeable-steel
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/optimize/problems.jl@3a25803, StructuralSizer/test/optimize/test_column_nlp_adapter.jl@3a25803,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/design/results.jl@3a25803, StructuralSynthesizer/src/analyze/members/utils.jl@3a25803
session_id: sess-cbffa12d
created_at: '2026-10-26T13:50:54.637586+00:00'
updated_at: '2026-10-26T13:50:54.637586+00:00'
has_child_rationale: These four files complete the as-built NLP column work already
  referenced by the committed checker.
---
Commit the remaining RC column NLP pieces that the as-built checker already depends on: the shared 32-bar cap and placeable-steel constraint in problems.jl, the adapter tests, the flat-plate column-results omit, and the building install guard in _apply_column_results!. The smooth P-M flat-spot that refuses a valid 12x36 for 1000 kip / 500 kip-ft is the next fix, not part of this commit.
