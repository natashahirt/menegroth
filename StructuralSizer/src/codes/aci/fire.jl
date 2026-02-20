# =============================================================================
# ACI 216.1-14 Fire Resistance Provisions for Concrete
# =============================================================================
#
# Prescriptive minimum thickness, cover, and dimension requirements for
# concrete elements to achieve a specified fire-resistance rating.
#
# Reference: ACI/TMS 216.1-14, "Code Requirements for Determining Fire
#            Resistance of Concrete and Masonry Construction Assemblies"
#
# Tables implemented:
#   Table 4.2     — Min equivalent thickness for floors/roofs/walls
#   Table 4.3.1.1 — Min cover for slab reinforcement (nonprestressed)
#   Table 4.3.1.2 — Min cover for beam reinforcement (nonprestressed)
#   Table 4.5.1a  — Min column dimension (4-sided exposure)
#   Section 4.5.3 — Min cover for column reinforcement
#
# =============================================================================

using Unitful: inch

# =============================================================================
# Table 4.2 — Minimum slab/wall thickness for fire resistance
# =============================================================================

# Rows: [1 hr, 1.5 hr, 2 hr, 3 hr, 4 hr] — values in inches
const _FIRE_THICKNESS_TABLE = Dict{AggregateType, NTuple{5, Float64}}(
    siliceous        => (3.5, 4.3, 5.0, 6.2, 7.0),
    carbonate        => (3.2, 4.0, 4.6, 5.7, 6.6),
    sand_lightweight => (2.7, 3.3, 3.8, 4.6, 5.4),
    lightweight      => (2.5, 3.1, 3.6, 4.4, 5.1),
)

# Map fire rating → column index (1-based)
const _FIRE_RATING_INDEX = Dict{Float64, Int}(
    1.0 => 1, 1.5 => 2, 2.0 => 3, 3.0 => 4, 4.0 => 5
)

"""
    min_thickness_fire(fire_rating, aggregate_type) -> Length

Minimum equivalent thickness for concrete floors, roofs, and walls to
achieve the specified fire-resistance rating.

ACI 216.1-14 Table 4.2.

# Arguments
- `fire_rating::Real`: Fire resistance in hours (1, 1.5, 2, 3, or 4)
- `aggregate_type::AggregateType`: Concrete aggregate classification

# Returns
Minimum thickness as a `Length` (inches).

# Example
```julia
min_thickness_fire(2.0, siliceous)   # → 5.0 inch
min_thickness_fire(2.0, carbonate)   # → 4.6 inch
```
"""
function min_thickness_fire(fire_rating::Real, agg::AggregateType)
    r = Float64(fire_rating)
    r <= 0 && return 0.0u"inch"
    idx = get(_FIRE_RATING_INDEX, r, nothing)
    isnothing(idx) && throw(ArgumentError(
        "Invalid fire_rating = $r. Must be one of: 1, 1.5, 2, 3, 4 hours."))
    return _FIRE_THICKNESS_TABLE[agg][idx] * u"inch"
end


# =============================================================================
# Table 4.3.1.1 — Minimum cover for slab reinforcement
# =============================================================================

# Nonprestressed slabs (restrained: all ratings use ¾"; unrestrained varies)
# Format: [1 hr, 1.5 hr, 2 hr, 3 hr, 4 hr] in inches
# Restrained: ≤4 hr → ¾" for all aggregate types
const _FIRE_SLAB_COVER_RESTRAINED = 0.75  # inches, all ratings ≤ 4 hr

# Unrestrained nonprestressed slab cover
const _FIRE_SLAB_COVER_UNRESTRAINED = Dict{AggregateType, NTuple{5, Float64}}(
    siliceous        => (0.75, 0.75, 1.00, 1.25, 1.625),
    carbonate        => (0.75, 0.75, 0.75, 1.25, 1.25),
    sand_lightweight => (0.75, 0.75, 0.75, 1.25, 1.25),
    lightweight      => (0.75, 0.75, 0.75, 1.25, 1.25),
)

"""
    min_cover_fire_slab(fire_rating, aggregate_type; restrained=true) -> Length

Minimum concrete cover to reinforcement in floor/roof slabs for fire
resistance (nonprestressed).

ACI 216.1-14 Table 4.3.1.1.

Cover shall not be less than that required by ACI 318.

# Arguments
- `fire_rating::Real`: Fire resistance in hours (1, 1.5, 2, 3, or 4)
- `aggregate_type::AggregateType`: Concrete aggregate classification
- `restrained::Bool`: Restrained construction (default `true`; see ACI 216.1 Table 4.3.1)

# Returns
Minimum cover as a `Length` (inches).
"""
function min_cover_fire_slab(fire_rating::Real, agg::AggregateType; restrained::Bool=true)
    r = Float64(fire_rating)
    r <= 0 && return 0.0u"inch"
    idx = get(_FIRE_RATING_INDEX, r, nothing)
    isnothing(idx) && throw(ArgumentError(
        "Invalid fire_rating = $r. Must be one of: 1, 1.5, 2, 3, 4 hours."))
    if restrained
        return _FIRE_SLAB_COVER_RESTRAINED * u"inch"
    else
        return _FIRE_SLAB_COVER_UNRESTRAINED[agg][idx] * u"inch"
    end
end


# =============================================================================
# Table 4.3.1.2 — Minimum cover for beam reinforcement (nonprestressed)
# =============================================================================

# Format: Dict of (restraint, width_category) => [1 hr, 1.5 hr, 2 hr, 3 hr, 4 hr]
# Width categories: 5", 7", ≥10" (interpolation between these)
# NP (not permitted) encoded as Inf

const _FIRE_BEAM_COVER = Dict{Tuple{Bool, Int}, NTuple{5, Float64}}(
    # Restrained beams
    (true, 5)   => (0.75, 0.75, 0.75, 1.00, 1.25),
    (true, 7)   => (0.75, 0.75, 0.75, 0.75, 0.75),
    (true, 10)  => (0.75, 0.75, 0.75, 0.75, 0.75),
    # Unrestrained beams
    (false, 5)  => (0.75, 1.00, 1.25, Inf,  Inf),    # 3 hr, 4 hr NP at 5"
    (false, 7)  => (0.75, 0.75, 0.75, 1.75, 3.00),
    (false, 10) => (0.75, 0.75, 0.75, 1.00, 1.75),
)

"""
    min_cover_fire_beam(fire_rating, beam_width_in; restrained=true) -> Length

Minimum concrete cover to reinforcement in nonprestressed beams for fire
resistance.

ACI 216.1-14 Table 4.3.1.2.

For restrained beams spaced ≤4 ft on center, ¾" cover is permitted for all ratings.

# Arguments
- `fire_rating::Real`: Fire resistance in hours (1, 1.5, 2, 3, or 4)
- `beam_width_in::Real`: Beam width in inches
- `restrained::Bool`: Restrained construction (default `true`)

# Returns
Minimum cover as a `Length` (inches). Returns `Inf × inch` if the width is
not permitted for the given rating (NP in the table).
"""
function min_cover_fire_beam(fire_rating::Real, beam_width_in::Real; restrained::Bool=true)
    r = Float64(fire_rating)
    r <= 0 && return 0.0u"inch"
    idx = get(_FIRE_RATING_INDEX, r, nothing)
    isnothing(idx) && throw(ArgumentError(
        "Invalid fire_rating = $r. Must be one of: 1, 1.5, 2, 3, 4 hours."))

    bw = Float64(beam_width_in)

    # Select width category (interpolate between table entries)
    if bw < 5.0
        @warn "Beam width $(bw)\" < 5\": using 5\" fire cover values (conservative)"
        cat = 5
    elseif bw < 7.0
        # Interpolate between 5" and 7" entries
        c5 = _FIRE_BEAM_COVER[(restrained, 5)][idx]
        c7 = _FIRE_BEAM_COVER[(restrained, 7)][idx]
        isinf(c5) && return Inf * u"inch"
        frac = (bw - 5.0) / 2.0
        return (c5 + frac * (c7 - c5)) * u"inch"
    elseif bw < 10.0
        # Interpolate between 7" and 10" entries
        c7  = _FIRE_BEAM_COVER[(restrained, 7)][idx]
        c10 = _FIRE_BEAM_COVER[(restrained, 10)][idx]
        frac = (bw - 7.0) / 3.0
        return (c7 + frac * (c10 - c7)) * u"inch"
    else
        cat = 10
    end

    return _FIRE_BEAM_COVER[(restrained, cat)][idx] * u"inch"
end


# =============================================================================
# Table 4.5.1a — Minimum column dimension (4-sided exposure)
# =============================================================================

# [1 hr, 1.5 hr, 2 hr, 3 hr, 4 hr] in inches
const _FIRE_COLUMN_DIM = Dict{AggregateType, NTuple{5, Float64}}(
    siliceous        => (8.0, 9.0, 10.0, 12.0, 14.0),
    carbonate        => (8.0, 9.0, 10.0, 11.0, 12.0),
    sand_lightweight => (8.0, 8.5,  9.0, 10.5, 12.0),
    lightweight      => (8.0, 8.5,  9.0, 10.5, 12.0),  # same as sand-LW
)

"""
    min_dimension_fire_column(fire_rating, aggregate_type) -> Length

Minimum concrete column dimension for fire resistance (4-sided exposure).

ACI 216.1-14 Table 4.5.1a.

# Arguments
- `fire_rating::Real`: Fire resistance in hours (1, 1.5, 2, 3, or 4)
- `aggregate_type::AggregateType`: Concrete aggregate classification

# Returns
Minimum column dimension as a `Length` (inches).
"""
function min_dimension_fire_column(fire_rating::Real, agg::AggregateType)
    r = Float64(fire_rating)
    r <= 0 && return 0.0u"inch"
    idx = get(_FIRE_RATING_INDEX, r, nothing)
    isnothing(idx) && throw(ArgumentError(
        "Invalid fire_rating = $r. Must be one of: 1, 1.5, 2, 3, 4 hours."))
    return _FIRE_COLUMN_DIM[agg][idx] * u"inch"
end


# =============================================================================
# Section 4.5.3 — Minimum cover for column reinforcement
# =============================================================================

"""
    min_cover_fire_column(fire_rating) -> Length

Minimum concrete cover to main longitudinal reinforcement in columns.

ACI 216.1-14 Section 4.5.3: Cover ≥ 1 in. × hours of fire resistance,
but not less than ACI 318 minimums. Applies regardless of aggregate type.

# Arguments
- `fire_rating::Real`: Fire resistance in hours (1, 1.5, 2, 3, or 4)

# Returns
Minimum cover as a `Length` (inches).
"""
function min_cover_fire_column(fire_rating::Real)
    r = Float64(fire_rating)
    r <= 0 && return 0.0u"inch"
    return r * u"inch"
end
