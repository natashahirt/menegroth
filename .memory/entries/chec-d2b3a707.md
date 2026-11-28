---
id: chec-d2b3a707
type: checkpoint
project: menegroth
parent_id: plan-267f93b4
title: Row F floors relax to any section that passes the stored rows
node_label: Row F floors relax
tags: row-f,section-floor,ratchet,columns,beams
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-4d21baf3
created_at: '2026-11-13T16:52:07.151743+00:00'
updated_at: '2026-11-13T16:52:07.151743+00:00'
has_child_rationale: Commit of Phase 1 Row F half; a memory record must precede the
  commit.
---
Phase 1, Row F half (branch row-f-nlp).

- _raise_frame_floors! walks the whole catalog lightest-first, not from the current section. Each member must pass this round's rows plus rows stored for it in earlier rounds (_rows_with_stored). Discrete rows now accumulate like NLP rows, so the floor's objective never falls between rounds.
- _frame_floor_mask(struc, kind, group_ids, catalog, frame) keeps every catalog section that passes the group's stored rows per member (_floor_rows_by_member, _passes_floor_rows). It used to keep only the floor and heavier sections. Refuses when the floor is not in the passing set.
- _nlp_section_or_floor(struc, kind, gid, section, opts) keeps the NLP section when it passes the stored rows, else the floor.
- Tests: test_frame_section_floors.jl (mask equals passing set; heavy stale floor admits lighter passing sections; rows accumulate; below-balance floor is the lightest passing section, can be lighter than installed), test_row_f_resize.jl. 218/218 then 176/176 passing.

Not committed: story-shell trim on continuing rounds (size_beams_story_shell.jl trim_continuing kwarg; member_iteration.jl _size_with_story_shell! one trim round after the rounds settle, with its own max_rounds budget) and scripts/runners/compare_sizes.jl. Both untestable on this branch, see the blocker note.
