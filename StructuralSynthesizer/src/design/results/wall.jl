"""
    WallCheckRecord

One ordinary-wall check on one pier, one basic case, and one strength
combination. Several records share a wall, story, direction, and combination:
shear, axial-flexure, bearing, and each minimum-reinforcement limit.

# Fields
- `wall_index::Int`: index into `BuildingStructure.walls`.
- `story::Int`: 0-based story index, matching `Wall.story` (ground = 0).
  `WallLine.story` is 1-based and is not this field.
- `direction::Symbol`: plan direction of the pier, `:X` or `:Y` along the
  lateral design's plan axes, or `:skew` for a pier on neither axis.
- `case::Symbol`: basic case the combination was built from (`:D`, `:wind`, `:QE`, ...).
- `combination::Symbol`: strength combination.
- `alternative::Symbol`: `:only`, or `:L` / `:W` when combination 3 is split.
- `check::String`: check name from the existing wall checker.
- `passed::Bool`: whether that check passed. A failure is reported; the section is not changed.
- `ratio::Float64`: demand / capacity.
- `demand::Float64`: demand in the checker's units (newtons, N·m, or a reinforcement ratio).
- `capacity::Float64`: capacity in those same units.
- `clause::String`: governing clause reported by the checker.
"""
struct WallCheckRecord
    wall_index::Int
    story::Int
    direction::Symbol
    case::Symbol
    combination::Symbol
    alternative::Symbol
    check::String
    passed::Bool
    ratio::Float64
    demand::Float64
    capacity::Float64
    clause::String
end
