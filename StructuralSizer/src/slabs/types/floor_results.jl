# =============================================================================
# Result Types (parametric for unit flexibility)
# =============================================================================

"""
    AbstractFloorResult

Abstract type for floor sizing results. Every concrete subtype stores at least
`self_weight` and provides `total_depth`, `volume_per_area`, and `materials`.
"""
abstract type AbstractFloorResult end

"""CIP concrete slab result."""
struct CIPSlabResult{L, F} <: AbstractFloorResult
    thickness::L        # length
    volume_per_area::L  # length (m³/m² = m)
    self_weight::F      # force/area
end

"""Precast/catalog-based result."""
struct ProfileResult{L, F} <: AbstractFloorResult
    profile_id::String
    depth::L
    volume_per_area::L  # accounts for voids
    self_weight::F
end

"""
Composite deck result. `deck_depth` is the rib height, `fill_depth` the
concrete above the deck, and `checks` the record from `deck_slab_candidate`.
"""
struct CompositeDeckResult{L, F, C<:NamedTuple} <: AbstractFloorResult
    deck_profile::String
    deck_depth::L
    deck_gauge::Int
    fill_depth::L
    total_depth::L
    steel_vol_per_area::L
    concrete_vol_per_area::L
    self_weight::F
    checks::C
end

"""Fill concrete a composite deck was sized with, or `nothing` when the record lacks it."""
fill_concrete(r::CompositeDeckResult) = get(r.checks, :concrete, nothing)

"""Steel joist + deck result."""
struct JoistDeckResult{L, F} <: AbstractFloorResult
    joist_designation::String
    joist_depth::L
    joist_spacing::L
    deck_profile::String
    deck_depth::L
    total_depth::L
    steel_vol_per_area::L
    self_weight::F
end

"""Timber panel result (CLT, DLT, NLT)."""
struct TimberPanelResult{L, F} <: AbstractFloorResult
    panel_id::String
    depth::L
    ply_count::Int
    volume_per_area::L
    self_weight::F
end

"""Mass timber joist result."""
struct TimberJoistResult{L, F} <: AbstractFloorResult
    joist_size::String
    joist_depth::L
    joist_spacing::L
    deck_type::String
    total_depth::L
    volume_per_area::L
    self_weight::F
end

"""
    VaultResult{L, P, F}

Vault sizing result with geometry, thrust, and design checks.

# Geometry
- `thickness`: Shell thickness
- `rise`: Crown rise (final, after elastic shortening)
- `arc_length`: Parabolic arc length (for material takeoff)

# Thrust (line loads at supports, perpendicular to span)
- `thrust_dead`: Horizontal thrust from dead load
- `thrust_live`: Horizontal thrust from live load

# Material
- `volume_per_area`: Concrete volume per plan area [L³/L² = L]
- `self_weight`: Self-weight pressure [F/L²]

# Analysis
- `σ_max`: Maximum compressive stress [MPa]
- `governing_case`: Which load case governs (`:symmetric` or `:asymmetric`)

# Design Checks
- `stress_check`: Named tuple with `(σ, σ_allow, ratio, ok)`
- `deflection_check`: Named tuple with `(δ, limit, ratio, ok)`
- `convergence_check`: Named tuple with `(converged, iterations)`
- `kern_check`: Named tuple with `(e, limit, ratio, ok)`, `e` and `limit` in
  mm: half-span thrust-line eccentricity against the middle third
  ([`vault_kern_check`](@ref)). Always evaluated; the vault is unreinforced.
"""
struct VaultResult{L, P, F} <: AbstractFloorResult
    # Geometry
    thickness::L
    rise::L
    arc_length::L
    
    # Thrust (line loads at supports)
    thrust_dead::P
    thrust_live::P
    
    # Material
    volume_per_area::L
    self_weight::F
    
    # Analysis outputs
    σ_max::Float64
    governing_case::Symbol
    
    # Design checks (structured like FlatPlatePanelResult)
    stress_check::NamedTuple{(:σ, :σ_allow, :ratio, :ok), Tuple{Float64, Float64, Float64, Bool}}
    deflection_check::NamedTuple{(:δ, :limit, :ratio, :ok), Tuple{Float64, Float64, Float64, Bool}}
    convergence_check::NamedTuple{(:converged, :iterations), Tuple{Bool, Int}}
    kern_check::NamedTuple{(:e, :limit, :ratio, :ok), Tuple{Float64, Float64, Float64, Bool}}
end

"""Total horizontal thrust at supports (dead + live)."""
total_thrust(r::VaultResult) = r.thrust_dead + r.thrust_live

"""Check if vault design passes all checks."""
is_adequate(r::VaultResult) = r.stress_check.ok && r.kern_check.ok &&
                              r.deflection_check.ok && r.convergence_check.converged

"""Custom/shaped slab result."""
struct ShapedSlabResult{L, F} <: AbstractFloorResult
    volume_per_area::L
    self_weight::F
    thickness_fn::Union{Function, Nothing}  # (x,y) → h(x,y) for visualization
    custom::Dict{Symbol, Any}
end

ShapedSlabResult(vol::L, sw::F) where {L, F} = ShapedSlabResult{L, F}(vol, sw, nothing, Dict{Symbol,Any}())

