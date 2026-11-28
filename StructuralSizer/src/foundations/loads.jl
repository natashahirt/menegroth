# =============================================================================
# Unified footing load container
# =============================================================================
#
# Every shallow footing — spread, column strip, rigid/flexible mat, and the
# grade-wall strip and wall-line mat — is designed from the same information:
#
#   * a gravity reference per support (the service and factored axial that
#     centers the plan and floors the section), and
#   * one concurrent load state per ASCE 7 combination, aligned by label.
#
# Historically each footing took that information through its own differently
# named keyword pairs (`service_actions`/`strength_actions`,
# `column_service`/`column_strength`, `service_cases`/`strength_cases`,
# `wall_service`/`wall_strength`). `FootingLoads` collects all of it in one
# object, validated once, so the design entry is a single call.
#
# Two element kinds keep their own statics (a column is a point load, a wall
# is a line load), so they stay in separate fields rather than being forced
# into one polymorphic list. Only construction and validation are unified.
#
# Axis conventions (kept as the individual designers expect them):
#   * `column_service[c][k]` — column `c`, combination `k`  (FootingAction)
#   * `wall_service[k][leg]` — combination `k`, wall leg    (WallLineDemand)

"""
    FootingLoads

All of the loads one shallow footing is designed from.

# Fields
- `demands`: gravity reference, one [`FoundationDemand`](@ref) per column.
- `positions`: column locations — `(x, y)` tuples for a spread or mat, or
  along-axis coordinates for a strip. Length matches `demands`.
- `column_service`, `column_strength`: `[column][combination]` vectors of
  [`FootingAction`](@ref). Both empty, or both filled; aligned by label
  across columns.
- `walls`: gravity reference, one [`WallLineDemand`](@ref) per wall leg.
- `wall_service`, `wall_strength`: `[combination][leg]` vectors of
  [`WallLineDemand`](@ref). Both empty, or both filled; a combination in net
  uplift is an empty leg vector at that index.

Build one with [`footing_loads`](@ref), which runs every alignment check.
"""
struct FootingLoads
    demands::Vector{FoundationDemand}
    positions::Vector
    column_service::Vector{Vector{FootingAction}}
    column_strength::Vector{Vector{FootingAction}}
    walls::Vector{WallLineDemand}
    wall_service::Vector{Vector{WallLineDemand}}
    wall_strength::Vector{Vector{WallLineDemand}}
end

"""
    footing_loads(; demands, positions, column_service, column_strength,
                    walls, wall_service, wall_strength) -> FootingLoads

Validated constructor. Enforces every alignment invariant in one place:

- `demands` and `positions` have the same length.
- `column_service`/`column_strength` are both empty or both filled, with one
  entry per column and matching combination labels across columns
  (ACI 336.2R §3.2.1; ASCE 7-22 §2.3 and §2.4).
- `wall_service`/`wall_strength` are both empty or both filled, with the same
  number of combinations.
- When both columns and walls carry combinations, they share the combination
  count so a mat can add a column action and a wall line of the same state.
"""
function footing_loads(;
    demands::Vector{<:FoundationDemand} = FoundationDemand[],
    positions::AbstractVector = Any[],
    column_service::Vector{Vector{FootingAction}} = Vector{FootingAction}[],
    column_strength::Vector{Vector{FootingAction}} = Vector{FootingAction}[],
    walls::Vector{<:WallLineDemand} = WallLineDemand[],
    wall_service::Vector{Vector{WallLineDemand}} = Vector{WallLineDemand}[],
    wall_strength::Vector{Vector{WallLineDemand}} = Vector{WallLineDemand}[],
)
    length(positions) == length(demands) || throw(DimensionMismatch(
        "footing_loads: $(length(positions)) positions and $(length(demands)) demands."))
    _strip_validate_actions(column_service, column_strength, length(demands))
    _validate_wall_cases(wall_service, wall_strength)
    if !isempty(column_service) && !isempty(wall_service)
        length(wall_service) == length(first(column_service)) || throw(ArgumentError(
            "footing_loads: $(length(wall_service)) wall service combinations and " *
            "$(length(first(column_service))) column service combinations."))
        length(wall_strength) == length(first(column_strength)) || throw(ArgumentError(
            "footing_loads: wall and column strength combinations are not the same length."))
    end
    return FootingLoads(
        collect(FoundationDemand, demands), collect(positions),
        column_service, column_strength,
        collect(WallLineDemand, walls), wall_service, wall_strength)
end

"""Both wall-case lists empty or both filled, and the same number of combinations."""
function _validate_wall_cases(wall_service, wall_strength)
    se = isempty(wall_service)
    st = isempty(wall_strength)
    se == st || throw(ArgumentError(
        "footing_loads: pass both the service and the strength wall cases, or neither."))
    se && return 0
    return length(wall_service)
end

"""The single column's per-combination service actions, or `[]` when none."""
_column_service_of(loads::FootingLoads, c::Int) =
    isempty(loads.column_service) ? FootingAction[] : loads.column_service[c]
_column_strength_of(loads::FootingLoads, c::Int) =
    isempty(loads.column_strength) ? FootingAction[] : loads.column_strength[c]

"""True when the loads describe column point supports."""
has_columns(loads::FootingLoads) = !isempty(loads.demands)
"""True when the loads describe wall line supports."""
has_walls(loads::FootingLoads) = !isempty(loads.walls)

"""Re-type an abstract position vector to its element type for dispatch."""
_narrow_positions(v::AbstractVector) =
    isempty(v) ? v : collect(mapreduce(typeof, typejoin, v), v)

# =============================================================================
# Unified design entry
# =============================================================================
#
# One public call over the ACI shallow family. It unpacks `FootingLoads` and
# routes to the proven per-type designer. The individual positional methods
# stay the implementation; this is the single surface the Synthesizer uses.

"""
    design_footing(ftype, loads::FootingLoads, soil; opts, kwargs...)

Design one shallow ACI footing from a [`FootingLoads`](@ref). Dispatches on
`ftype`:

- `SpreadFooting()` — one column, no walls.
- `StripFooting()`  — a column strip (≥ 2 columns) or a wall strip (walls,
  no columns).
- `MatFoundation()` — columns, walls, or both.

`opts` is the matching parameter struct. A spread or strip also forwards
`tc` and `strip_axis`.
"""
function design_footing(::SpreadFooting, loads::FootingLoads, soil::Soil;
                        opts::SpreadParams = SpreadParams(),
                        tc::Union{Nothing, TraceCollector} = nothing)
    length(loads.demands) == 1 || throw(ArgumentError(
        "A spread footing takes exactly one column (got $(length(loads.demands)))."))
    isempty(loads.walls) || throw(ArgumentError("A spread footing takes no wall line."))
    return design_footing(SpreadFooting(), loads.demands[1], soil; opts = opts, tc = tc,
                          service_actions = _column_service_of(loads, 1),
                          strength_actions = _column_strength_of(loads, 1))
end

function design_footing(::StripFooting, loads::FootingLoads, soil::Soil;
                        opts = nothing,
                        strip_opts::StripParams = StripParams(),
                        tc::Union{Nothing, TraceCollector} = nothing,
                        strip_axis::Symbol = :x)
    sp = opts === nothing ? strip_opts : opts
    if has_walls(loads)
        isempty(loads.demands) || throw(ArgumentError(
            "A wall strip takes wall legs, not columns; put columns on a mat."))
        return design_footing(StripFooting(), loads.walls, soil; opts = sp, tc = tc,
                              service_cases = loads.wall_service,
                              strength_cases = loads.wall_strength)
    end
    return design_footing(StripFooting(), loads.demands, _narrow_positions(loads.positions), soil;
                          opts = sp, tc = tc, strip_axis = strip_axis,
                          column_service = loads.column_service,
                          column_strength = loads.column_strength)
end

function design_footing(::MatFoundation, loads::FootingLoads, soil::Soil;
                        opts::MatParams = MatParams(),
                        tc::Union{Nothing, TraceCollector} = nothing,
                        framed_I_B = 0.0u"m^4",
                        framed_I_L = 0.0u"m^4")
    return design_footing(MatFoundation(), loads.demands, _narrow_positions(loads.positions), soil;
                          opts = opts, tc = tc, walls = loads.walls,
                          framed_I_B = framed_I_B, framed_I_L = framed_I_L,
                          column_service = loads.column_service,
                          column_strength = loads.column_strength,
                          wall_service = loads.wall_service,
                          wall_strength = loads.wall_strength)
end
