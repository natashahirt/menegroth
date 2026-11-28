---
id: plan-3c17cdf6
type: plan
project: menegroth
parent_id: plan-b231dcef
title: Land the Row F commit without the other session's split
node_label: Land Row F commit
tags: row-f,commit,worktree,provenance,nlp
status: active
open_threads: 3
success: 'null'
files: ''
session_id: sess-1d752b4c
created_at: '2026-11-11T11:23:09.658170+00:00'
updated_at: '2026-11-11T18:29:46.597998+00:00'
has_child_rationale: The sensitivity suite passed. The commit is blocked by another
  session's uncommitted file split, rib-bay prepare edits, and mixed provenance.
---
Plan only. Do not start until the user says to build it.

The suites are already green on the mixed working tree: StructuralSynthesizer floors + row F resize 162/162, StructuralSizer NLP adapter 130/130. This plan is how to commit that work without the other session's unfinished edits. Those files were still dirty on the morning of 2026-11-11: problems.jl, api.jl, prepare.jl, provenance.jl, structure.jl, runtests.jl.

1. Commit from a worktree at HEAD. Leave the main checkout untouched, so the other session's include-stub split of problems.jl and api.jl stays in their tree.
2. In the worktree, replay Row F onto HEAD's monolithic problems.jl, problems_circular.jl, and api.jl. Add RCColumnDemandSet. Do not add the untracked problems/ or api/ directories.
3. Take synthesizer files whose diffs are only this work: interactive checks and the per-element station loads, the ordinary-wall stage call, size_columns sending a demand set, beam floors from each framing level's beam options, uniform-group floors, member results, snapshots, and the seismic_frame API fields. Include test_frame_section_floors.jl and test_row_f_resize.jl.
4. Mixed files get hunks only. prepare.jl: the frame_section_floors clear, not rib_bays. structure.jl: frame_section_floors and stage_diagnostics, not diaphragm_layout. provenance.jl: a version that describes per-case NLP and the station-load filter, without slab_sizing_v3 or the member-loop versions that are not in this commit. runtests.jl: only the two new test files.
5. Run the same two suites in the worktree. If the per-case NLP will not build without a helper that exists only in the split, stop and wait for that session to commit the split, then commit Row F on top. Do not merge the two by hand.
6. One small addition in the same commit: the resize test should also show that a seismic demand (story shear, or a seismic-case moment) rises with SDS even when the governing ratio stays put. At SDS 0.5 and 1.0 the gravity moment governs and the ratio is identical (0.365). That is expected. No equation change.

Out of this plan: beam NLP still uses the envelope, the column NLP still refuses a section floor, and there is no full redesign_incremental! of the office.
