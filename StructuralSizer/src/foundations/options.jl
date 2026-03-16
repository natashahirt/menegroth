# =============================================================================
# Foundation Design Options
# =============================================================================
#
# User-facing knobs for spread, strip, and mat footing design.
# Mirrors the pattern established by AbstractFloorOptions / FlatPlateOptions.
# =============================================================================

# =============================================================================
# Mat Analysis Method Types
# =============================================================================

"""Supertype for mat analysis method dispatch (rigid, Shukla AFM, Winkler FEA)."""
abstract type AbstractMatMethod end

"""Rigid mat: uniform/linear pressure, strip statics. No k_s required."""
struct RigidMat <: AbstractMatMethod end

"""
    ShuklaAFM

Analytical Flexible Method using Kelvin-Bessel function superposition.

Computes continuous moment, shear, and deflection fields from concentrated
column loads on a plate resting on an elastic (Winkler) foundation.

Subgrade modulus k_s is determined by one of:
  1. `soil.ks` provided directly (preferred), or
  2. Shukla (1984) chart lookup from unconfined compressive strength `q_u`,
     scaled to mat dimensions per ACI 336.2R-88 §3.3.2 Eq. 3-8.

# Fields
- `grain`: Soil grain type for Shukla k_v1 chart — `:fine` or `:coarse`.
  Only used when `q_u` is provided (chart lookup path).
- `q_u`: Unconfined compressive strength for k_v1 chart lookup.
  If `nothing`, `soil.ks` must be provided.
- `ks_exponent`: Exponent n in ACI 336.2R Eq. 3-8: k_s = k_v1·(1ft/B)^n.
  Range 0.5–0.7; default 0.6. Only used in chart lookup path.

# References
- Shukla, S.N. (1984). "A Simplified Method for Design of Mats on Elastic
  Foundations." ACI Journal, 81(5), 469–475.
- ACI 336.2R-88 §3.3.2 Eq. 3-8 (Sowers 1977 size scaling).
- ACI 336.2R-88 §6.1.2 Step 4.
"""
Base.@kwdef struct ShuklaAFM <: AbstractMatMethod
    grain::Symbol = :fine
    q_u::Union{Pressure, Nothing} = nothing
    ks_exponent::Float64 = 0.6
end

"""
    WinklerFEA

FEA plate on Winkler springs using Asap shell elements and grounded springs.

Discretizes the mat into triangular shell elements with vertical soil springs
at each node. Spring constants computed per ACI 336.2R-88 §6.7:
  K_node = tributary_area × k_s

Edge springs are doubled per ACI 336.2R §6.9 to approximate coupling effects.
Requires `soil.ks` to be provided.

# Fields
- `target_edge`: Target element edge length.  `nothing` (default) → adaptive
  sizing `clamp(min_span / 20, 0.15, 0.75) m`, giving ~20 elements per bay
  (same heuristic as the slab FEA).
- `double_edge_springs`: Apply ACI 336.2R §6.9 edge spring doubling (default true).

# References
- ACI 336.2R-88 §6.4 (FEM), §6.7 (Winkler springs), §6.9 (edge springs).
"""
Base.@kwdef struct WinklerFEA <: AbstractMatMethod
    target_edge::Union{Nothing, Unitful.Length} = nothing
    double_edge_springs::Bool = true
end

# =============================================================================
# Spread Footing Options
# =============================================================================

"""
    SpreadParams

Design parameters for ACI 318-11 spread (isolated) footing design.

All lengths stored as Unitful quantities — stripped to imperial at the
calculation boundary inside `design_footing(::SpreadFooting, ...)`.
"""
Base.@kwdef struct SpreadParams
    # Materials & Detailing
    material::ReinforcedConcreteMaterial = RC_4000_60
    cover::Length            = 3.0u"inch"       # ACI 7.7.1: ≥ 3" cast against soil
    bar_size::Int            = 8                 # Rebar designation (e.g. 8 → #8)

    # Column / pier interface (legacy: for spread footings use FoundationDemand.c1, c2, shape)
    pier_shape::Symbol       = :rectangular       # Ignored by ACI spread; use demand.shape
    pier_c1::Length           = 18.0u"inch"      # Ignored by ACI spread; use demand.c1
    pier_c2::Length           = 18.0u"inch"      # Ignored by ACI spread; use demand.c2
    footing_shape::Symbol    = :rectangular      # :rectangular (square when B==L)

    # Geometry bounds
    min_depth::Length         = 12.0u"inch"      # ACI 13.3.1.2: ≥ 6" above bottom rebar
    depth_increment::Length   = 1.0u"inch"       # Round-up increment for h
    size_increment::Length    = 3.0u"inch"        # Round B,L to nearest 3"

    # Strength reduction factors — ACI 318-11 §9.3.2
    ϕ_flexure::Float64       = 0.90
    ϕ_shear::Float64         = 0.75
    ϕ_bearing::Float64       = 0.65              # ACI Table 21.2.1 (bearing)

    # Lightweight concrete factor (nothing → pull from material.concrete.λ)
    λ::Union{Float64, Nothing} = nothing

    # Column concrete strength (may differ from footing concrete)
    # nothing → same as footing fc'
    fc_col::Union{Pressure, Nothing} = nothing

    # Checks to perform
    check_bearing::Bool      = true              # ACI 22.8 bearing at column-footing joint
    check_dowels::Bool       = true              # Design dowel reinforcement
    check_development::Bool  = true              # Verify Ld ≤ available anchorage

    # Objective for optimization
    objective::AbstractObjective = MinVolume()
end

# =============================================================================
# Strip Footing Options
# =============================================================================

"""
    StripParams

Design parameters for ACI 318-11 strip / combined footing design.
"""
Base.@kwdef struct StripParams
    # Materials & Detailing
    material::ReinforcedConcreteMaterial = RC_4000_60
    cover::Length            = 3.0u"inch"
    bar_size_long::Int       = 7                 # Longitudinal bars
    bar_size_trans::Int      = 5                 # Transverse bars

    # Column dimensions now live on FoundationDemand (c1, c2, shape) — per column.

    # Geometry
    min_depth::Length         = 12.0u"inch"
    depth_increment::Length   = 1.0u"inch"
    width_increment::Length   = 3.0u"inch"
    max_depth_ratio::Float64  = 0.5              # Widen B if h > ratio × B (typical h/B ≈ 0.3–0.5)

    # Analysis
    analysis::Symbol         = :rigid            # :rigid (K_r > 0.5) — only option for now

    # Strength reduction
    ϕ_flexure::Float64       = 0.90
    ϕ_shear::Float64         = 0.75
    ϕ_bearing::Float64       = 0.65
    λ::Union{Float64, Nothing} = nothing

    # Column concrete strength (may differ from footing concrete); nothing → same as footing
    fc_col::Union{Pressure, Nothing} = nothing

    # Checks to perform
    check_development::Bool  = true              # ACI 25.4.2 development length
    check_bearing::Bool      = true              # ACI 22.8 bearing at column-footing joint
    check_dowels::Bool       = true              # Design dowel reinforcement if bearing insufficient

    # Auto-merge thresholds (spread → strip)
    merge_gap_factor::Float64    = 2.5           # Merge when gap < factor × D_max
    eccentricity_limit::Float64  = 0.15          # Merge when e/L > limit

    # Objective
    objective::AbstractObjective = MinVolume()
end

# =============================================================================
# Mat Footing Options
# =============================================================================

"""
    MatParams

Design parameters for mat foundation design per ACI 336.2R.
"""
Base.@kwdef struct MatParams
    # Materials & Detailing
    material::ReinforcedConcreteMaterial = RC_4000_60
    cover::Length            = 3.0u"inch"
    bar_size_x::Int          = 8
    bar_size_y::Int          = 8

    # Geometry
    min_depth::Length         = 24.0u"inch"      # Mats typically thicker
    depth_increment::Length   = 1.0u"inch"
    edge_overhang::Union{Length, Nothing} = nothing  # nothing → auto (d or 0.5× avg span)

    # Analysis method
    analysis_method::AbstractMatMethod = RigidMat()

    # Strength reduction
    ϕ_flexure::Float64       = 0.90
    ϕ_shear::Float64         = 0.75
    λ::Union{Float64, Nothing} = nothing

    # Objective
    objective::AbstractObjective = MinVolume()
end

# =============================================================================
# Top-Level Foundation Options
# =============================================================================

"""
    FoundationOptions

Top-level container for all foundation design parameters.

# Fields
- `code`: Design code — `:aci` (default) or `:is` (IS 456 legacy).
- `strategy`: Auto-selection mode — `:auto`, `:auto_strip_spread`, `:all_spread`, `:all_strip`, `:mat`.
- `mat_coverage_threshold`: Switch to mat when coverage ratio exceeds this (default 0.50).
- `spread_params`, `strip_params`, `mat_params`: Option blocks for each foundation type;
  each can be overridden by API or param components.
"""
Base.@kwdef struct FoundationOptions
    # Design code dispatch (:aci default, :is legacy)
    code::Symbol = :aci

    # Sub-option blocks
    spread_params::SpreadParams   = SpreadParams()
    strip_params::StripParams     = StripParams()
    mat_params::MatParams         = MatParams()

    # Auto-selection strategy
    strategy::Symbol = :auto        # :auto, :auto_strip_spread, :all_spread, :all_strip, :mat

    # Mat heuristic thresholds (used when strategy = :auto)
    mat_coverage_threshold::Float64 = 0.50  # Switch to mat if coverage > 50%
end
