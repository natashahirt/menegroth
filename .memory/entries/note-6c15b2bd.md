---
id: note-6c15b2bd
type: note
project: menegroth
parent_id: chec-4c32c360
title: Sizing map re-audited (two-way αfm resolved, lateral sway bridge built-not-wired);
  README/plan updated
node_label: Sizing map re-audited (two-way αfm resolved, later
tags: sizing-map,two-way,alpha_fm,lateral,sway,StoryStability,design_column_moments,docs
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/README.md@e486e76, docs/sizing-map/plan.md@e486e76
session_id: sess-9f489e9d
created_at: '2026-11-23T17:06:23.445037+00:00'
updated_at: '2026-11-23T17:06:23.445037+00:00'
has_child_rationale: Follow-up audit of the two-way αfm landing and the lateral sway
  work; records what changed in the sizing-map docs
---
Re-audited `docs/sizing-map/` (snapshot was 2026-11-11) against the working tree on 2026-11-23 for two-way slabs and lateral sway, then updated the map.

**Two-way with beams — RESOLVED (rank 2 / sign-off item 2).** `_size_beams_columns!` now runs up to two `_recheck_two_way_thickness!` + `_resize_beams_after_thickness!` rounds after beams exist (`SY/workflow/member_iteration.jl:385-392`, helpers `:744-784`). `_recheck_two_way_thickness!` computes each panel's αfm from the sized edge beams (`_panel_alpha` → `StructuralSizer.panel_alpha_fm`) and re-runs `min_thickness(TwoWay(), ln; αfm=…)` with Eq. (9-12)/(9-13), writing the newly computed h (can thin). The `alpha_fm = nothing` bound in `SS/slabs/codes/concrete/min_thickness.jl` is now only the pre-beam seed / no-full-beams fallback. Matches checkpoint chec-4c32c360 (landed 2026-11-14).

**Lateral sway — built and unit-tested, NOT wired into design_building.** `StoryStability` (`SS/members/codes/shared/story_stability.jl`) bridges ACI §10.10.7 δs and AISC App.8 B2; `design_column_moments` (`SS/members/codes/shared/column_moments.jl`) returns Mns+δs·Ms (RC Eq.10-18) or B1·Mnt+B2·Mlt (steel Eq.A-8-1). But `design_column_moments` and the `LateralTranslation` split are NOT called anywhere in production src (only defined + tested in test_shared_column_moments.jl); `demand.lt` is always nothing. `compute_story_properties!` is not called in the pipeline (only inside `p_delta_iterate!`, which the pipeline does not call), so flat-plate columns take their sway designation from the wall-presence proxy (`SS/.../utils/column_bracing.jl` flat_plate_story_is_sway), not a real Q. Flat-plate columns use k=1 both ways (core takes sidesway). Steel array path still warns 'B2 amplification not implemented' for braced=false (`steel_feasibility.jl:52-59`).

**Map edits (README.md):** added a dated '2026-11-23 audit updates' note after the intro; marked §4 rank 2 and §6 sign-off item 2 RESOLVED (kept rank number for plan.md cross-refs); updated the §3 decision-space row and §1 stage flowchart; fixed the §7 stand-in bullet. **plan.md:** annotated 6.1 that the αfm recheck landed (remaining: credit wall edges in mixed panels + verified B4). architecture.md left as-is (its two-way αfm entry is a future cluster target, distinct from today's round loop).
