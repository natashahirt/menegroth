# =============================================================================
# Load Distribution Interface
# =============================================================================

"""
    LoadDistributionType

How a floor system transfers gravity loads to its boundary.

# Values
- `DISTRIBUTION_ONE_WAY`  — to edges perpendicular to span axis
- `DISTRIBUTION_TWO_WAY`  — to all surrounding edges
- `DISTRIBUTION_POINT`    — to specific support points (columns)
- `DISTRIBUTION_CUSTOM`   — user-defined distribution
"""
@enum LoadDistributionType begin
    DISTRIBUTION_ONE_WAY
    DISTRIBUTION_TWO_WAY
    DISTRIBUTION_POINT
    DISTRIBUTION_CUSTOM
end

"""
    load_distribution(ft::AbstractFloorSystem) -> LoadDistributionType

Get the load distribution behavior of the floor system.
Dispatches on the spanning behavior trait.
"""
load_distribution(ft::AbstractFloorSystem) = load_distribution(spanning_behavior(ft))

# Trait-based dispatch
load_distribution(::OneWaySpanning) = DISTRIBUTION_ONE_WAY
load_distribution(::TwoWaySpanning) = DISTRIBUTION_TWO_WAY
load_distribution(::BeamlessSpanning) = DISTRIBUTION_POINT

# Override for custom types
load_distribution(::ShapedSlab) = DISTRIBUTION_CUSTOM

"""
Get the gravity load magnitude (pressure) from the result.
Returns (dead_pressure, live_pressure)
"""
function get_gravity_loads(result::AbstractFloorResult, sdl, live)
    sw = self_weight(result)
    # Ensure units are consistent (converting sw to sdl units if possible)
    # For now, assuming callers handle unit consistency or Unitful handles it.
    return (sdl + sw, live)
end

# =============================================================================
# Tributary Axis (Analysis Direction)
# =============================================================================

"""
    default_tributary_axis(ft, spans) -> Union{NTuple{2,Float64}, Nothing}

Default tributary axis for a floor type, based on its spanning behavior trait.

Returns:
- `(x, y)` tuple for one-way systems: directed partitioning along span axis
- `nothing` for two-way/beamless: isotropic straight skeleton
"""
default_tributary_axis(ft::AbstractFloorSystem, spans) = default_tributary_axis(spanning_behavior(ft), spans)

# Trait-based dispatch
default_tributary_axis(::OneWaySpanning, spans) = spans.axis     # Use span direction
default_tributary_axis(::TwoWaySpanning, spans) = nothing        # Isotropic
default_tributary_axis(::BeamlessSpanning, spans) = nothing      # Isotropic (for edge tribs)

"""Resolve tributary axis (convenience: no options → floor type default)."""
resolve_tributary_axis(ft::AbstractFloorSystem, spans) = default_tributary_axis(ft, spans)

