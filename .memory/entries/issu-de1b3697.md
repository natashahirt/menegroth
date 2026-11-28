---
id: issu-de1b3697
type: issue
project: menegroth
parent_id: plan-267f93b4
title: 'Committed tree cannot run design_building: memory auto-commits landed part
  of uncommitted work'
node_label: Committed tree broken end to end
tags: blocker,auto-commit,flat-plate,story-shell,floor-contracts
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-4d21baf3
created_at: '2026-11-13T16:52:13.268721+00:00'
updated_at: '2026-11-13T16:52:13.268721+00:00'
has_child_rationale: Blocks Phase 0 comparison and story-shell verification; user
  needs to know.
---
Found 2026-11-13 while building the size-comparison baseline at 787670c5 (row-f-nlp; main has the same commits).

- 04500456 ([memory] Design kernel carries the wall lines...) added StructuralSizer flat_plate/input.jl but no include. main has include("input.jl") only as an uncommitted edit in the user's checkout (plus include("utils/column_bracing.jl")).
- Committed flat_plate pipeline (iteration.jl:180, rule_of_thumb.jl:134) calls _initialize_unsized_columns!, defined only in main's uncommitted pipeline/column_updates.jl.
- floor_design_contracts.jl dispatch has no OneWay implementation committed: design_building on OneWayOptions throws 'no floor-design implementation for OneWay'.
- test_story_shell_beams.jl uses SteelShellSpan, StoryPanelDesign, a newer Slab constructor, CompositeContext.d_rebar: none in committed source.

Effect: flat_plate, rc_beams, steel_beams, and core_office all fail in design_building on committed code. The user's main checkout has a large uncommitted change set (StructuralSizer/src, StructuralSynthesizer/src) that presumably completes it. Whole-building comparisons and story-shell tests are blocked until that lands and row-f-nlp is rebased.
