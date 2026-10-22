---
id: deci-fe873f83
type: decision
project: menegroth
parent_id: plan-b6ff71fd
title: Wall storage, :walls initialization, and nearest-elevation story matching
node_label: Wall storage, :walls initialization, and nearest-e
tags: walls,phase-3,story-matching,initialize
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-34fc8cff
created_at: '2026-10-22T17:54:54.559137+00:00'
updated_at: '2026-10-22T17:54:54.559137+00:00'
---
## Wall storage

`BuildingStructure.walls::Vector{Wall{T}}` is stored after struts. `all_members` flattens walls too.

`BuildingDesign.walls::Dict{Int,Vector{WallCheckRecord}}` is schema only (story 0-based, direction, combination). No utilization, capacity, demand, or ACI factors.

## :walls initialization

`APIEdgeGroups.walls` defaults empty. Deserialize shatters `input.edges.walls` into `:walls`.

`:walls` edges become `Wall`, never `Beam`. An edge also in `:beams` / `:columns` / `:braces` throws.

`Wall.story` is 0-based. `to_wall_line` keeps `story+1` because `WallLine.story` is 1-based. Do not flip that +1.

## Pier height

Pier height is the next story ABOVE with non-empty `Story.faces`, not plan length and not the next vertex Z. A missing higher floor throws. No invented height.

## Story matching

Wall story is the story whose elevation is nearest the plan-line Z, within 1e-4 m. Farther throws. Ties throw. The global `edge_story` map (0.1 m first-hit) is unchanged because columns use it. A faced floor at -0.05 m must not steal a wall at z=0: story elevation stays 0 m and `base.L` stays 4 m up to the 4 m floor.

## Thickness

`wall_thickness` is a required keyword when `:walls` is non-empty. `nothing` throws. No default thickness. Thickness must already be the structure length type `T`.

## Enclosure

Enclosure at the end of `initialize!` is the existing axis-aligned plate box (`assert_story_walls_enclosed!`). An L-notch center inside the box and outside the face is the pre-existing contract.

## Residual (not a code change)

Critic leftover, not fixed: the tie guard uses exact Float64 equality. A 1-ulp midpoint of two elevations both inside 1e-4 m can be accepted. `rebuild_stories!` rounds elevations to 0.01 m, so two stories on that grid cannot both lie within 1e-4 m of one wall. Record this as a residual, not as a decision to change the code now.

## Session path (run-89a27049)

Model PASS (structure, design types, schema, `all_members` includes walls). Wire PASS (`:walls` become `Wall`), later corrected by two critic fix cycles. First reviewer PASS, then missed the stray-vertex height bug. First critic FAIL P0: next story key included a faceless vertex at 0.05 m, so pier height became 0.05 m; fixed by skipping stories with empty faces. First tester 42/42. Second reviewer PASS on the face-skip. Second critic FAIL P0: `edge_story` 0.1 m first-hit let a faced floor at -0.05 m steal a wall at z=0; fixed by nearest elevation within 1e-4 m. Global `edge_story` not changed. Second tester 64/64 (cases H and I). Third reviewer PASS: z=0 wall stays on the 0 m floor, `base.L` = 4 m; a wall 5 cm off every elevation throws; `edge_story` still returns -0.05 m and is unused by walls. Third critic CONCERN P2 only (the 1-ulp tie above). The -0.05 m case, exact ties, and a mezzanine at 2 m (L = 2 m) are closed. No third fix cycle. Third tester PASS 84/84, case J added.

## Paths (intentionally uncommitted; files parameter omitted so this record does not auto-commit)

- StructuralSynthesizer/src/building_types/structure.jl
- StructuralSynthesizer/src/design_types.jl
- StructuralSynthesizer/src/api/schema.jl
- StructuralSynthesizer/src/analyze/members/utils.jl
- StructuralSynthesizer/src/core/initialize.jl
- StructuralSynthesizer/src/api/deserialize.jl
- StructuralSynthesizer/src/walls_bridge.jl
- StructuralSynthesizer/test/core/test_wall_data_model.jl
