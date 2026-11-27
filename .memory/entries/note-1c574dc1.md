---
id: note-1c574dc1
type: note
project: menegroth
parent_id: menegroth
title: 'Fix bare_steel stale-stiffness crash: rebuild K in _resize_beams_after_thickness!'
node_label: 'Fix bare_steel stale-stiffness crash: rebuild K in'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-475a2366
created_at: '2026-11-27T22:55:53.110213+00:00'
updated_at: '2026-11-27T22:55:53.110213+00:00'
---
BUG (sweep failure 'B'): bare_steel (steel members under a two-way RC slab -> story shell) failed on all 3 plans with ArgumentError: 'N frame elements carry stiffness from an earlier section. Rebuild the model after installing sections (update_analysis!(struc,:stiffness)) before reading its forces.'

ROOT CAUSE (trace via scripts/runners/diag_bare_steel_trace.jl): the error is thrown by member_group_demands (size_beams.jl:474) from the initial frame-demand read (shell_demands=nothing) inside _size_story_beams! (size_beams_story_shell.jl:272), invoked by size_beams_with_story_shell! line 188, reached from _resize_beams_after_thickness! (member_iteration.jl). That function applied update_analysis!(struc,:loads) which keeps the factorization and leaves stale element K. The discrete-steel story-shell column trim (_trim_story_shell_columns!, gated on upward_only && _column_floor_supported) installs trimmed column sections WITHOUT rebuilding K, so the next frame read sees stale stiffness. Concrete T-beams skip that trim (not floored), which is why concrete_rib solved and bare_steel did not.

FIX: StructuralSynthesizer/src/workflow/member_iteration.jl _resize_beams_after_thickness! now, after update_analysis!(:loads), rebuilds stiffness when stale:
    isempty(Asap.stale_frame_elements(struc.asap_model)) || update_analysis!(struc, :stiffness; params, tc)
This mirrors the existing idiom at member_iteration.jl:213 and the error message's own prescription.

VERIFIED on topology/r7c1 bare_steel (SS_TRACE_SHELL_PASSES=1): grep 'carry stiffness' = 0; both _resize_beams_after_thickness! story-shell passes now run and converge (round 1 each, no pathological loop); installed-design verify shows 44/44 beam groups pass, 2 of 13 column groups mildly overstressed (pm_interaction ~0.96-1.0 on 12 ft columns) = a separate long-member design matter, not the bug. Runtime note: editing StructuralSynthesizer forces its ~57s precompile; a full bare_steel design ~15-20 min.

Note: explicitly backgrounded (&) julia jobs get killed when the wrapper shell exits; run foreground + tee and let the tool background it. Julia block-buffers file stdout; pty (script) is sandbox-blocked.
