---
id: expe-fe549dc3
type: experiment
project: menegroth
parent_id: plan-7073d97e
title: Wall stage loops share one tolerance, one story lookup, one second-order builder,
  and one pier steel step
node_label: wall loop consolidation
tags: walls,refactor,ordinary-wall
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-b73c029a
created_at: '2026-11-06T19:01:19.916595+00:00'
updated_at: '2026-11-06T19:01:19.916595+00:00'
has_child_rationale: The duplicated wall-stage loops were the next item on plan-7073d97e.
---
Consolidation only. Numbers are unchanged.

- `WALL_CUT_ZTOL_M` (0.1 mm) is defined once in the wall mesh and used for story cuts, vertex elevation, and flexible-floor receivers. The 1e-6 m above-base split stays separate.
- Wind story levels use the ELF master map plus shared faced-story, above-base, master, and story-height helpers. Error prefixes stay `wind_story_analysis:` and `elf_story_analysis:`.
- Gravity-only and lateral second-order stiffness share `_build_second_order`. Gravity still uses every skeleton elevation and the gravity readings. Lateral still appends wind and earthquake and uses `elf.levels`.
- Solid piers and steel selection share `_solid_piers` and `_select_pier_steel!`. Interactive shear still runs before the lateral checks are recorded.
- Drift helpers live in `story_demands.jl` (included after `WallAction`). Opening-segment checks live in `wall_opening_checks.jl`.

A fresh process passed 1216 tests across ELF, wind, the ordinary-wall stage, openings, diaphragms, cuts, skew plans, and combinations, with one assertion still expecting the old `diaphragm_mode` error. An unmeshed building now stops on the empty wall mesh. After that assertion update, `test_ordinary_wall_stage.jl` passed 406 tests.

Flexible-floor drift measurement and the area-versus-seismic-weight split were not changed.
