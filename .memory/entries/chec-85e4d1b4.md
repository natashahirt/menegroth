---
id: chec-85e4d1b4
type: checkpoint
project: menegroth
parent_id: plan-267f93b4
title: Story-shell trim runs once after later rounds settle
node_label: Story-shell trim on later rounds
tags: story-shell,beams,ratchet,phase-1
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-e366e1e7
created_at: '2026-11-13T18:48:41.630058+00:00'
updated_at: '2026-11-13T18:48:41.630058+00:00'
has_child_rationale: User asked to commit the held-back story-shell trim and comparison
  runner.
---
Committed on row-f-nlp with the size-comparison runner.

size_beams_with_story_shell! gains trim_continuing (default false). A continuing call still starts upward-only and skips the trim unless trim_continuing is true. _size_with_story_shell! runs that trim once after steel-discrete rounds settle, then allows up to max_rounds more rounds. A lighter design is kept only when the existing trim converges lighter.

scripts/runners/compare_sizes.jl writes per-element sizes and carbon totals for flat_plate, rc_beams, steel_beams, and core_office. It does not produce sizes on this branch: design_building fails (issu-de1b3697).

The new story-shell assertions were not run. test_story_shell_beams.jl errors earlier on types the committed source does not have (SteelShellSpan, StoryPanelDesign). Files were not passed to this record: the same two paths are dirty with other edits on the main checkout, and a pin would commit those.
