---
id: todo-8e4db977
type: todo
project: menegroth
parent_id: plan-de3143e9
title: Add design_parameters field to BuildingStructure (post-Phase-B, harness-gated)
node_label: Add design_parameters field to BuildingStructure (
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/building_types/structure.jl@083fd81, StructuralSynthesizer/src/analyze/members/utils.jl@c9e39c2,
  StructuralSynthesizer/src/design_graph/provenance.jl@083fd81, StructuralSynthesizer/src/core/size.jl@083fd81
session_id: sess-86ca292c
created_at: '2026-07-17T17:59:19.069385+00:00'
updated_at: '2026-07-17T17:59:19.069385+00:00'
---
DEFERRED per user (chose defer + cleanup). BuildingStructure (building_types/structure.jl:28-70) has NO design_parameters field, yet size_beams! (collinear_grouping @utils.jl:2388, beams-opts fallback, optimize_for), size_columns! (columns-opts fallback @utils.jl:3269), and the cycle-4 member_group_overrides backstop all READ struc.design_parameters under hasproperty guards => currently DEAD branches (never fire). provenance.jl:159-163 documents this; a docstring @utils.jl:3251 even instructs users to set the phantom field.

WHY DEFER (not a Phase B bug): adding+populating the field ACTIVATES all those dead fallbacks at once => an exact-first behavior change for every bare size_beams!/size_columns!/size_members!(struc) caller, which must be re-proven byte-identical against the differential harness. Also needs a decision on WHO populates it and WHEN (BuildingDesign ctor? design_building? prepare!?) + fingerprint/provenance handling to avoid stale-cache/spurious invalidation. Timing: concurrent auto-framing run edits structure.jl. Phase B does not need it (size! explicit thread from design.params is authoritative).

PAYOFF WHEN DONE: single source of truth; bare size_*(struc) honor collinear_grouping/optimize_for/opts/overrides; the cycle-4 backstop + size_members! P1 become REAL coverage (not 'inert/not constructible'); docstrings become honest.

SCOPE WHEN PICKED UP: (1) add field to BuildingStructure + both constructors; (2) populate at the right choke point; (3) wire the dead fallbacks live; (4) provenance/fingerprint slice for the new field; (5) re-prove byte-identity via verify_incremental_engine + verify_design_graph_incremental + the in-suite test; (6) update docstrings.

IMMEDIATE (this session, after cycle-4 review wave lands): small honest cleanup only — fix the phantom-field docstrings and clearly mark the dead hasproperty(struc,:design_parameters) fallbacks so nothing advertises a nonexistent field. NO field addition now.
