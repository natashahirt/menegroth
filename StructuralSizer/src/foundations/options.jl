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
- `no_tension_springs`: Compression-only soil springs (default `true`).
  Iteratively deactivates springs whose nodes lift (w > 0) and reactivates
  springs whose nodes are pushed back into contact (w < 0).  This matches
  the standard production-tool convention (e.g. spMats) and the physical
  reality that soil cannot pull a mat downward.  Set to `false` to recover
  the legacy two-way (tension+compression) Winkler model — useful for
  diagnostic comparisons but generally non-physical for cohesionless soils.
- `max_no_tension_iters`: Iteration cap for the deactivate/reactivate loop
  (default `20`).  Exceeding this raises an error per the strict policy:
  no silent fallback to a non-converged solution.
- `no_tension_tol`: Relative residual tolerance |ΣF_applied − ΣF_react|/
  ΣF_applied at convergence (default `5e-3`, i.e. 0.5 %).  Independent of
  the active-set fixed point; both must hold.

# References
- ACI 336.2R-88 §6.4 (FEM), §6.7 (Winkler springs), §6.9 (edge springs).
- StructurePoint *spMats Engineering Software Program Manual* v8.12 (2016)
  §3.4 — soil-pressure springs are taken as compression-only by default.
"""
Base.@kwdef struct WinklerFEA <: AbstractMatMethod
    target_edge::Union{Nothing, Unitful.Length} = nothing
    double_edge_springs::Bool = true
    no_tension_springs::Bool   = true
    max_no_tension_iters::Int  = 20
    no_tension_tol::Float64    = 5e-3
end

# =============================================================================
# Global Stability Options (sliding / overturning / uplift)
# =============================================================================

"""
    StabilityParams

Knobs for the ASCE 7-22 global-stability checks (sliding, overturning, net
uplift) of a shallow footing. Supplying one to a footing param block turns
the checks on; leaving the footing param block's `stability` field `nothing`
(the default) reproduces the pre-stability behaviour exactly.

# Demand basis
The checks run over the **allowable-stress (service)** combinations, which
include the counteracting combinations that govern stability:
ASCE 7-22 §2.4.1 comb. 7a `0.6D + 0.6(W or WT)` and §2.4.5 comb. 10
`0.6D − 0.7Ev + 0.7Eh` (corpus: asce-7-22, PDF pages 69–70). No separate
factor of safety is applied — the `0.6D` dead-load reduction is the margin.
The worst combination governs each check. IBC 1807.2.3 (the 1.5-factor
basis) is intentionally not used: it is not in the corpus.

# Resistance basis (Bowles 5e Eq. (4-3) and Table 4-5; corpus:
# textbook-bowles-foundation-analysis-design-5e, PDF pages 252–253, 268)
Sliding resistance = `V·tanδ + cₐ·A + Pp`, where `δ` is the base–soil
friction angle and `cₐ` the base adhesion. Uplift is resisted by the
factored footing self-weight.

# Fields
- `delta_ratio`: `δ = delta_ratio · φ`. Bowles Table 4-5 gives the range
  `0.5φ ≤ δ ≤ φ`; the default `0.5` is the conservative low end of that
  cited range (ENGINEERING JUDGMENT — a defensible default, not a code value).
- `ca_ratio`: `cₐ = ca_ratio · c`. Bowles Table 4-5 Note 3 gives
  `cₐ ≈ 0.6c … 1.0c`; the default `0.6` is the conservative low end
  (ENGINEERING JUDGMENT).
- `include_passive`: include the passive-pressure term `Pp` on the embedded
  face (Bowles Eq. (4-3)). Requires intimate base–soil contact (Bowles p.269).
  Default `true` (the user-selected resistance set).
- `concrete_unit_weight`: unit weight of the footing concrete for the uplift
  self-weight resistance. Default `23.6 kN/m³` (≈150 pcf, standard normal-
  weight reinforced concrete — ENGINEERING JUDGMENT, not a code value).
- `dead_counteracting_factor`: factor applied to the stabilizing footing
  self-weight, matching the `0.6D` of ASCE 7-22 comb. 7a. Default `0.6`.
"""
Base.@kwdef struct StabilityParams
    delta_ratio::Float64 = 0.5
    ca_ratio::Float64    = 0.6
    include_passive::Bool = true
    concrete_unit_weight::Union{Unitful.Quantity, Nothing} = 23.6u"kN/m^3"
    dead_counteracting_factor::Float64 = 0.6
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
    check_development::Bool  = true              # ACI 318-11 §12.2 / §15.6.3

    # Global stability (sliding/overturning/uplift). `nothing` → skip (legacy).
    stability::Union{Nothing, StabilityParams} = nothing

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

    # Analysis method — typed, shared with MatParams for one consistent surface.
    #   RigidMat()   — linear soil pressure, rigid statics. Column strips use
    #                  this; a wall uses it when Kr ≥ 0.5 (ACI 336.2R §5.2).
    #   WinklerFEA() — force a straight wall onto the §5.4 beam-on-elastic-
    #                  foundation model regardless of Kr (needs Soil.ks). Not
    #                  supported for column strips or corners.
    #   ShuklaAFM()  — a 2-D mat plate method; rejected for 1-D strips/walls.
    analysis_method::AbstractMatMethod = RigidMat()
    # With analysis_method = RigidMat(), a wall whose relative stiffness is
    # below 0.5 (ACI 336.2R §5.2) is redesigned as a beam on elastic foundation
    # (§5.4) when this is `:fallback`, matching slab `on_inapplicable`; `:error`
    # refuses.
    on_inapplicable::Symbol  = :fallback

    # Strength reduction
    ϕ_flexure::Float64       = 0.90
    ϕ_shear::Float64         = 0.75
    ϕ_bearing::Float64       = 0.65
    λ::Union{Float64, Nothing} = nothing

    # Column concrete strength (may differ from footing concrete); nothing → same as footing
    fc_col::Union{Pressure, Nothing} = nothing

    # Checks to perform
    check_development::Bool  = true              # ACI 318-11 §12.2 / §15.6.3
    check_bearing::Bool      = true              # ACI 22.8 bearing at column-footing joint
    check_dowels::Bool       = true              # Design dowel reinforcement if bearing insufficient

    # Auto-merge thresholds (spread → strip)
    merge_gap_factor::Float64    = 2.5           # Merge when gap < factor × D_max
    eccentricity_limit::Float64  = 0.15          # Merge when e/L > limit

    # Global stability (sliding/overturning/uplift). `nothing` → skip (legacy).
    stability::Union{Nothing, StabilityParams} = nothing

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
    size_increment::Length    = 3.0u"inch"      # Grow the overhang when bars do not develop
    edge_overhang::Union{Length, Nothing} = nothing  # nothing → auto (d or 0.5× avg span)
    # Flexural bars, ACI 318-11 §12.2 and §15.6.3. Dowel embedment is separate.
    check_development::Bool   = true

    # Analysis method
    analysis_method::AbstractMatMethod = RigidMat()
    # Rigid mat outside ACI 336.2R §6.1.2 Step 3: `:fallback` redesigns with
    # `WinklerFEA` and records it, `:error` refuses. Same choice as slabs.
    on_inapplicable::Symbol  = :fallback

    # Strength reduction
    ϕ_flexure::Float64       = 0.90
    ϕ_shear::Float64         = 0.75
    λ::Union{Float64, Nothing} = nothing

    # Global stability (sliding/overturning/uplift). `nothing` → skip (legacy).
    stability::Union{Nothing, StabilityParams} = nothing

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
