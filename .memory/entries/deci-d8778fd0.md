---
id: deci-d8778fd0
type: decision
project: menegroth
parent_id: plan-b0095736
title: Lateral approaches split into LateralSystem and DemandAssignment behind hooks
node_label: Lateral approach layout
tags: walls,lateral,analysis-approach,architecture,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-3493e545
created_at: '2026-10-29T12:43:01.099801+00:00'
updated_at: '2026-10-29T12:43:01.099801+00:00'
---
Lateral approaches are two independent choices, paired by `LateralDesign(system, assignment)` on `DesignParameters.lateral` (default `nothing` = no lateral design; no default system). `lateral` is prepare-affecting because the system sets beam releases before `to_asap!`.

- `LateralSystem`: what resists (`WallsSeismicSystem`, `OutriggerSystem`; dual later).
- `DemandAssignment`: how force reaches members (`BuildingUnit`, `IsolatedWallShare(share)`).

Layout: `analyze/lateral/approaches/types.jl` (types only, included before design_types.jl), `interface.jl` (hooks `prepare_lateral_model!`, `seismic_members`, `system_checks`, `assign_lateral_demands`; defaults refuse naming the hook), one file per type under `systems/` and `assignment/`. Approaches call the wall building blocks; building blocks never call approaches. A third stiffness-assumption choice is deferred to the outrigger work.

Implemented: WallsSeismicSystem (girders -> `:gravity_frame`, pinned bending ends, also when no beam material is set; refuses no walls and explicitly fixed girder ends; §12.12.4 refuses for SDC D-F, nothing for A-C) and BuildingUnit (pier cut action from the unified solve). Known gap: non-girder `:beam` members that frame into a column keep fixed ends and can still give some frame action.
