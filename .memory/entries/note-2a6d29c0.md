---
id: note-2a6d29c0
type: note
project: menegroth
parent_id: find-be4cf63c
title: 'De-staled sizing-map README: marked sign-off 1/3/5 RESOLVED, 4 PARTIAL (spread
  only), rank 7 resolved, rank 11 beams now count rebar'
node_label: 'De-staled sizing-map README: marked sign-off 1/3/5'
tags: ''
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/README.md@a472450
session_id: sess-c23e927c
created_at: '2026-11-26T17:36:33.210836+00:00'
updated_at: '2026-11-26T17:36:33.210836+00:00'
---
Updated docs/sizing-map/README.md to reflect the plan-9633da9d / row-f-nlp merge on integration/2026-11-18 (per finding find-be4cf63c). Added a dated '2026-11-26' audit block at the top of the code-audit section and prefixed the individual §6 items:

- Sign-off 1 (cladding DL): RESOLVED — wall_SDL consumed as :cladding line loads; enters dead/service-foundation/W/Px (chec-dbb027b0, note-e9a2f8ae).
- Sign-off 3 (steel Cm): RESOLVED — size_columns.jl:219-222 forwards signed M1/M2 (AISC 360-16 App.8 Eq.A-8-4).
- Sign-off 4 (lateral->foundations): PARTIALLY RESOLVED — spread footings check every ASCE 7-22 §2.3/§2.4 combo; strip/mat still collapse combos in _lateral_column_demand, grade walls still gravity-only. This is the next work item.
- Sign-off 5 (rigid-mat statics): RESOLVED — mat_footing.jl implements ACI 336.2R §6.1.2 Steps 3-4.
- Ranked item 7 (mat reinforcement): resolved alongside sign-off 5.
- Ranked item 11 (rebar in RC objectives): beams now wrap ReinforcedConcreteMaterial (beams.jl:176) in addition to flat-plate columns; walls/footings still gross.

Next: close the strip/mat per-combination gap (sign-off 4 remainder).
