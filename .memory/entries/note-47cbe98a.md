---
id: note-47cbe98a
type: note
project: menegroth
parent_id: note-6c15b2bd
title: 'Sizing map broad re-audit: rebar-in-column-objective, rib/waffle sizing, verify-installed,
  speed caches, sway stages D/E'
node_label: 'Sizing map broad re-audit: rebar-in-column-objecti'
tags: sizing-map,WP2.5,rebar,ribbed,waffle,sway,story_stability_records,speed,docs
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/README.md@2ff8e12, docs/sizing-map/raw/building-pipeline.md@2ff8e12
session_id: sess-3b801976
created_at: '2026-11-23T17:09:59.667359+00:00'
updated_at: '2026-11-23T17:09:59.667359+00:00'
has_child_rationale: Second, broader pass over the whole sizing map against git log
  + code since 2026-11-11; extends the first audit note
---
Follow-up to note-6c15b2bd: widened the audit to the whole map using `git log --since=2026-11-11` + code reads, and updated README.md + raw/building-pipeline.md.

Verified landings since the 2026-11-11 snapshot:
- **Rank 11 PARTIAL (WP 2.5):** flat-plate column objective now counts rebar. `_column_cache_material` (`SY/workflow/flat_plate_column_check.jl:378-407`) wraps concrete+rebar in `ReinforcedConcreteMaterial` so obj_coeffs include rebar carbon under MinCarbon (default); picks are `sortperm(obj_coeffs)` in `_grow_/_stack_/_fit_flat_plate_columns!`. New `_fit_flat_plate_columns!` within-plan-size pass. P-M byte-identical. RC beams/walls/footings still gross. Empirical gate (commit 128ca951/921a87ba): carbon-ordered column shrinking NOT justified (≤0.5%; plan-area min ≈ carbon min) — grow-only footprint ratchet stands.
- **Sway staged build:** shared bridge Stages A–C (StoryStability + design_column_moments, commit 46aa882b/4d2f73ee); Stage D `story_stability_records` ELF→StoryStability adapter keyed (story,direction) in `SY/analyze/lateral/story_demands.jl:372-437` (commit f6a7ea6e); Stage E `seismic_design_category` (commit d2735339). Flat-plate sway k retired to 1.0, no alignment chart (commit edbdd341). STILL NOT WIRED: nothing calls design_column_moments with a populated story/lt during member sizing; compute_story_properties! not called in pipeline.
- **Ribbed/waffle now sized:** rib-depth owner `rib_story.jl`, rib-line sizing, cracked-story deflection + ρ′ lever (commits 3bf8e5f7/e7bce870/4e11f29e). Member stage gained `screen_rib_stems!` round loop (RIB_SCREEN_ROUNDS) + `report_rib_deflection!` (member_iteration.jl:356-378).
- **Member verify-installed fallback** (commit fe7c4071): `_verify_installed_design!` at the iteration cap accepts installed sections if every group passes a fresh final analysis; kills the floored-1.0 fake pass. Changes L9/L11/L13 budget-out (can now converge=true at cap).
- **Speed (exact):** P-M cache hoist + plan-groups memo (#10/#20, 42ec5fa9/21f8bd33/e7001b1c), single-section P-M memo (bd543b0e), T-beam cache −41% (990b87e2), grillage_bays/grow_heads memo −97%/−73% (fb067c91), RigidLinkFactorCache for lateral P-Δ (c63003c7/e55ee1d0).

Map edits: expanded the README '2026-11-23 audit' note with 5 new bullets; marked §4 rank 11 PARTIAL; updated the §3 Waffle→'Waffle/ribbed' decision-space row. In raw/building-pipeline.md added an addendum listing new loops L17 (two-way αfm recheck), L18 (rib-stem screen rounds), the verify-installed fallback, and the rebar-inclusive/_fit column objective, plus a note that many L4–L13 speed opportunities have landed. Did NOT rewrite the detailed L0–L16 records or raw/members.md / raw/slabs.md — flagged as follow-up.
