# Floor options: user-facing configuration for floor/slab sizing
#
# Architecture:
#   AbstractFloorOptions           → abstract parent for all floor option types
#     ├── FlatPlateOptions         → flat plate / beamless two-way slab
#     ├── FlatSlabOptions          → flat plate with drop panels
#     ├── OneWayOptions            → one-way CIP slab
#     ├── VaultOptions             → unreinforced parabolic vault
#     ├── CompositeDeckOptions     → steel deck + concrete fill
#     └── TimberOptions            → CLT / DLT / NLT panels
#
# Usage:
#   DesignParameters(floor = FlatPlateOptions(method = EFM(solver=:asap)))

# =============================================================================
# Abstract parent
# =============================================================================

"""
    AbstractFloorOptions

Abstract parent for all floor system option types.

Each subtype is self-describing — the type itself identifies the floor system,
eliminating the need for a `floor_type::Symbol` discriminator.

# Subtypes
- `FlatPlateOptions` — beamless two-way slab (ACI 318 Ch 8)
- `FlatSlabOptions` — flat plate with drop panels
- `OneWayOptions` — one-way CIP slab (ACI 318 Table 7.3.1.1)
- `VaultOptions` — unreinforced parabolic vault
- `CompositeDeckOptions` — steel deck + concrete fill
- `TimberOptions` — CLT / DLT / NLT panels

# Example
```julia
# Direct usage (recommended):
params = DesignParameters(floor = FlatPlateOptions(method = EFM(solver=:asap)))

# The type carries the floor system identity:
opts = FlatSlabOptions()
floor_symbol(opts)  # → :flat_slab
```
"""
abstract type AbstractFloorOptions end

# floor_symbol(::AbstractFloorOptions) methods defined below each struct.
# The generic floor_symbol(::AbstractFloorSystem) is in types.jl.

# =============================================================================
# Option structs
# =============================================================================

"""
    OneWayOptions

Options for one-way slab sizing per ACI 318 Table 7.3.1.1.

# Fields
- `material`: Reinforced concrete material (default: `RC_4000_60`)
- `cover`: Clear cover to reinforcement (default: 0.75")
- `bar_size`: Typical rebar size #3-#11 (default: 5)
- `support`: Support condition (default: `BOTH_ENDS_CONT`)
  - `SIMPLE` - Simply supported (h = l/20)
  - `ONE_END_CONT` - One end continuous (h = l/24)
  - `BOTH_ENDS_CONT` - Both ends continuous (h = l/28)
  - `CANTILEVER` - Cantilever (h = l/10)

# Example
```julia
opts = OneWayOptions(support=ONE_END_CONT)
```
"""
Base.@kwdef struct OneWayOptions <: AbstractFloorOptions
    material::ReinforcedConcreteMaterial = RC_4000_60
    cover::Length = 19.05u"mm"
    bar_size::Int = 5
    support::SupportCondition = BOTH_ENDS_CONT
end

"""Return the canonical floor system symbol for `OneWayOptions`."""
floor_symbol(::OneWayOptions) = :one_way

"""
    FlatPlateOptions <: AbstractFloorOptions

Options for flat plate / flat slab / waffle / PT slab sizing per ACI 318 Chapter 8.

# Materials & Detailing
- `material`: Reinforced concrete material (default: `RC_4000_60`)
- `cover`: Clear cover to reinforcement (default: 0.75")
- `bar_size`: Typical rebar size #3-#11 (default: 5)

# Analysis Method
- `method`: Typed analysis method object (default: `DDM()`)
  - `DDM()` — Direct Design Method (full ACI tables)
  - `DDM(:simplified)` — Modified DDM (simplified 0.65/0.35 coefficients)
  - `EFM()` — Equivalent Frame Method (default: ASAP solver, Kec, gross Ig)
  - `EFM(solver=:hardy_cross)` — EFM with Hardy Cross moment distribution
  - `EFM(column_stiffness=:Kc)` — EFM with raw column stiffness (no torsion)
  - `EFM(cracked_columns=true)` — EFM with 0.70 Ig column stubs
  - `FEA()` — Finite Element Analysis (shell model, no geometry restrictions)

# Edge Conditions
- `has_edge_beam`: Spandrel beam at exterior (affects DDM moment distribution)
- `edge_beam_βt`: Explicit torsional stiffness ratio override (`nothing` → auto-compute
  from column geometry when `has_edge_beam=true`; set to a Float64 to skip auto-compute)

# Slab Grouping
- `grouping`: How to group slabs for envelope sizing
  - `:individual`, `:by_floor`, `:building_wide`

# Strength Reduction (ACI 318-11 §9.3.2)
- `φ_flexure`: Flexure (default: 0.90)
- `φ_shear`: Shear (default: 0.75)
- `λ`: Lightweight concrete factor override (default: `nothing` → uses `material.concrete.λ`)

# Deflection
- `deflection_limit`: `:L_240`, `:L_360`, `:L_480`

# Punching Shear Resolution (ACI 318-11 §11.11)
- `punching_strategy`: *When* to apply punching reinforcement
  - `:grow_columns` — Only grow columns; error if maxed (default)
  - `:reinforce_last` — Try columns first, reinforce if columns max out
  - `:reinforce_first` — Try reinforcement first, grow columns if reinf. fails
- `punching_reinforcement`: *What type* of reinforcement to use
  - `:headed_studs_generic` — Generic headed studs (π d²/4 area, §11.11.5)
  - `:headed_studs_incon` — INCON ISS catalog dimensions (§11.11.5)
  - `:headed_studs_ancon` — Ancon Shearfix catalog dimensions (§11.11.5)
  - `:closed_stirrups` — Closed stirrup reinforcement (§11.11.3)
  - `:shear_caps` — Localized slab thickening at columns (§13.2.6)
  - `:column_capitals` — Flared column head enlargement (§13.1.2)
- `max_column_size`: Maximum column size before considering reinforcement (default: 30")
- `stud_material`: Shear stud / stirrup steel material (default: `Stud_51`)
- `stud_diameter`: Stud diameter (default: 1/2"; ignored for non-stud types)
- `stirrup_bar_size`: Stirrup bar size (default: 4; only used for `:closed_stirrups`)
- `shear_studs`: **Deprecated** — backward compat alias for punching_strategy

# Optimization
- `objective`: Objective for `size_flat_plate_optimized` grid search
  - `MinVolume()` (default), `MinWeight()`, `MinCost()`, `MinCarbon()`

# Column Cracking (FEA)
- `col_I_factor`: Cracking reduction for FEA column stubs (default: 0.70 per ACI 318-11 §10.10.4.1).
  Set to 1.0 to recover gross (uncracked) column stiffness.
  For EFM, column cracking is controlled by `EFM(cracked_columns=true/false)` — see [`EFM`](@ref).

# Example
```julia
# Recommended: use typed method objects
params = DesignParameters(floor = FlatPlateOptions(method = EFM(solver=:asap)))

# Enable studs if columns can't resolve punching
opts = FlatPlateOptions(punching_strategy = :reinforce_last)

# Use INCON ISS catalog studs as first resort
opts = FlatPlateOptions(
    punching_strategy = :reinforce_first,
    punching_reinforcement = :headed_studs_incon)

# Use closed stirrups for punching shear
opts = FlatPlateOptions(
    punching_strategy = :reinforce_last,
    punching_reinforcement = :closed_stirrups,
    stirrup_bar_size = 4)

# Use shear caps
opts = FlatPlateOptions(
    punching_strategy = :reinforce_first,
    punching_reinforcement = :shear_caps)

# Use column capitals
opts = FlatPlateOptions(
    punching_strategy = :reinforce_first,
    punching_reinforcement = :column_capitals)

# Minimize embodied carbon
opts = FlatPlateOptions(objective = MinCarbon())
```
"""
struct FlatPlateOptions <: AbstractFloorOptions
    material::ReinforcedConcreteMaterial
    cover::Length
    bar_size::Int
    has_edge_beam::Bool
    edge_beam_βt::Union{Float64, Nothing}
    method::FlatPlateAnalysisMethod
    grouping::Symbol
    φ_flexure::Float64
    φ_shear::Float64
    λ::Union{Float64, Nothing}
    deflection_limit::Symbol
    # Punching shear resolution
    punching_strategy::Symbol
    punching_reinforcement::Symbol
    max_column_size::Length
    stud_material::RebarSteel
    stud_diameter::Length
    stirrup_bar_size::Int
    # Override ACI minimum thickness (nothing = use ACI Table 8.3.1.1)
    min_h::Union{Length, Nothing}
    # Optimization objective (used by size_flat_plate_optimized)
    objective::AbstractObjective
    # Column cracking factor for FEA stub stiffness (ACI 318-11 §10.10.4.1)
    col_I_factor::Float64
end

"""Return the canonical floor system symbol for `FlatPlateOptions`."""
floor_symbol(::FlatPlateOptions) = :flat_plate

# ── Backward-compatible constructor: accept legacy `shear_studs` kwarg ──
# Maps :never → :grow_columns, :if_needed → :reinforce_last, :always → :reinforce_first
"""Map deprecated `shear_studs` symbols to current `punching_strategy` symbols."""
function _shear_studs_to_strategy(s::Symbol)
    s === :never     && return :grow_columns
    s === :if_needed && return :reinforce_last
    s === :always    && return :reinforce_first
    error("Unknown shear_studs value :$s. Use :never, :if_needed, or :always.")
end

"""
    _build_flat_plate_options(; kwargs...) -> FlatPlateOptions

Internal helper: construct `FlatPlateOptions` via its positional (inner) constructor
so that the backward-compat keyword wrapper can delegate without recursion.

The positional constructor is always available (generated by Julia for every struct)
and is never overridden by the keyword wrapper.
"""
function _build_flat_plate_options(;
    material::ReinforcedConcreteMaterial = RC_4000_60,
    cover::Length = 19.05u"mm",
    bar_size::Int = 5,
    has_edge_beam::Bool = false,
    edge_beam_βt::Union{Float64, Nothing} = nothing,
    method::FlatPlateAnalysisMethod = DDM(),
    grouping::Symbol = :by_floor,
    φ_flexure::Float64 = 0.90,
    φ_shear::Float64 = 0.75,
    λ::Union{Float64, Nothing} = nothing,
    deflection_limit::Symbol = :L_360,
    punching_strategy::Symbol = :grow_columns,
    punching_reinforcement::Symbol = :headed_studs_generic,
    max_column_size::Length = 30.0u"inch",
    stud_material::RebarSteel = Stud_51,
    stud_diameter::Length = 0.5u"inch",
    stirrup_bar_size::Int = 4,
    min_h::Union{Length, Nothing} = nothing,
    objective::AbstractObjective = MinVolume(),
    col_I_factor::Float64 = 0.70,
)
    # Call the positional (inner) constructor — field order must match struct definition
    FlatPlateOptions(material, cover, bar_size, has_edge_beam, edge_beam_βt,
                     method, grouping, φ_flexure, φ_shear, λ, deflection_limit,
                     punching_strategy, punching_reinforcement, max_column_size,
                     stud_material, stud_diameter, stirrup_bar_size,
                     min_h, objective, col_I_factor)
end

"""
    FlatPlateOptions(; shear_studs=nothing, kwargs...)

Backward-compatible constructor that accepts the deprecated `shear_studs` keyword
and maps it to `punching_strategy`.

- `:never`     → `punching_strategy = :grow_columns`
- `:if_needed` → `punching_strategy = :reinforce_last`
- `:always`    → `punching_strategy = :reinforce_first`

If both `shear_studs` and `punching_strategy` are provided, `punching_strategy` wins.
"""
function FlatPlateOptions(;
    shear_studs::Union{Symbol, Nothing} = nothing,
    punching_strategy::Symbol = isnothing(shear_studs) ? :grow_columns : _shear_studs_to_strategy(shear_studs),
    kw...
)
    _build_flat_plate_options(; punching_strategy=punching_strategy, kw...)
end

"""Backward-compat property access: `.analysis_method` and `.shear_studs` virtual fields."""
function Base.getproperty(opts::FlatPlateOptions, name::Symbol)
    if name === :analysis_method
        m = getfield(opts, :method)
        return _method_to_symbol(m)
    elseif name === :shear_studs
        # Map new punching_strategy back to legacy :never / :if_needed / :always
        strat = getfield(opts, :punching_strategy)
        strat === :grow_columns    && return :never
        strat === :reinforce_last  && return :if_needed
        strat === :reinforce_first && return :always
        return :never
    end
    return getfield(opts, name)
end

"""Convert a typed FlatPlateAnalysisMethod to the legacy Symbol representation."""
function _method_to_symbol(m::FlatPlateAnalysisMethod)
    m isa DDM && m.variant == :simplified && return :mddm
    m isa DDM && return :ddm
    m isa EFM && m.solver == :hardy_cross && return :efm_hc
    m isa EFM && m.column_stiffness == :Kc && return :efm_kc
    m isa EFM && return :efm
    if m isa FEA
        # New knob-based symbols
        m.design_approach == :frame && return :fea
        m.design_approach == :area  && return :fea_area
        # :strip — further differentiate by sub-knobs
        m.moment_transform == :wood_armer && return :fea_wa
        m.field_smoothing == :nodal && m.cut_method == :isoparametric && return :fea_nod
        m.field_smoothing == :element && m.cut_method == :delta_band && return :fea_cut
        # Fallback for other strip combos
        return :fea_strip
    end
    return :ddm
end

"""Convert a legacy analysis_method Symbol to a typed FlatPlateAnalysisMethod."""
function _symbol_to_method(s::Symbol)::FlatPlateAnalysisMethod
    s == :ddm        ? DDM() :
    s == :mddm       ? DDM(:simplified) :
    s == :efm        ? EFM() :
    s == :efm_hc     ? EFM(solver=:hardy_cross) :
    s == :efm_asap   ? EFM(solver=:asap) :
    s == :efm_kc     ? EFM(column_stiffness=:Kc) :
    # New knob-based FEA symbols
    s == :fea        ? FEA() :
    s == :fea_frame  ? FEA(design_approach=:frame) :
    s == :fea_strip  ? FEA(design_approach=:strip) :
    s == :fea_area   ? FEA(design_approach=:area, moment_transform=:wood_armer) :
    # Legacy aliases (still work via strip_design mapping in FEA constructor)
    s == :fea_direct ? FEA(strip_design=:fea_integration) :
    s == :fea_cut    ? FEA(strip_design=:fea_integration) :
    s == :fea_nod    ? FEA(strip_design=:nodal_cuts) :
    s == :fea_wa     ? FEA(strip_design=:wood_armer) :
    s == :fea_pk     ? FEA(strip_design=:peak_nodal) :
    throw(ArgumentError("Unknown analysis_method :$s. Valid: :ddm, :mddm, :efm, :efm_hc, " *
          ":efm_asap, :efm_kc, :fea, :fea_frame, :fea_strip, :fea_area, " *
          ":fea_cut, :fea_nod, :fea_wa."))
end


"""
    FlatSlabOptions <: AbstractFloorOptions

Options for flat slab (with drop panels) sizing per ACI 318 Chapter 8.

Flat slabs are structurally identical to flat plates except they have thickened
drop panels around columns (ACI 318-11 §13.2.5). This provides:
- Increased punching shear capacity at columns
- Reduced minimum slab thickness (ln/33 and ln/36 vs ln/30 and ln/33)
- Non-prismatic section effects handled by ASAP elastic solver

The shared analysis/design pipeline (`size_flat_plate!`) is used for both
flat plates and flat slabs, with drop panel geometry injected via the
`drop_panel` keyword.

# Fields
- `h_drop`: Drop panel depth projection below slab. `nothing` = auto-size
  to the smallest standard lumber depth satisfying ACI 8.2.4(a).
  Standard depths: 2.25", 4.25", 6.25", 8.0" (from lumber + plyform).
- `a_drop_ratio`: Drop panel half-extent as fraction of span length.
  Default `1/6` = ACI minimum. Use `nothing` for ACI minimum (l/6).
- `base`: All shared flat plate options (materials, analysis method,
  strength reduction factors, punching shear strategy, etc.).

# Example
```julia
# Auto-size drop panels (ACI minimum extent, smallest standard depth)
opts = FlatSlabOptions()

# Specify drop panel depth (4× lumber = 4.25")
opts = FlatSlabOptions(h_drop = 4.25u"inch")

# EFM analysis with drop panels
opts = FlatSlabOptions(base = FlatPlateOptions(method = EFM()))
```

# Convenience Constructor
Pass flat plate keyword arguments directly — they forward to `base`:
```julia
flat_slab(method = EFM(solver=:asap), punching_strategy = :reinforce_last)
flat_slab(method = EFM(solver=:asap), shear_studs = :if_needed)  # backward compat
```

# Reference
- ACI 318-11 §13.2.5, Table 9.5(c), §11.11.1.2
- StructurePoint DE-Two-Way-Flat-Slab-Concrete-Floor-with-Drop-Panels
"""
Base.@kwdef struct FlatSlabOptions <: AbstractFloorOptions
    # ─── Drop Panel Configuration ───
    h_drop::Union{Length, Nothing} = nothing        # nothing = auto-size
    a_drop_ratio::Union{Float64, Nothing} = nothing # nothing = ACI minimum (l/6)

    # ─── Shared flat plate options (composition, not duplication) ───
    base::FlatPlateOptions = FlatPlateOptions()
end

"""Return the canonical floor system symbol for `FlatSlabOptions`."""
floor_symbol(::FlatSlabOptions) = :flat_slab

"""Convert FlatSlabOptions to FlatPlateOptions for the shared pipeline."""
as_flat_plate_options(opts::FlatSlabOptions) = opts.base

"""Property forwarding: transparently delegate non-drop-panel fields to `base`."""
function Base.getproperty(opts::FlatSlabOptions, name::Symbol)
    if name in (:h_drop, :a_drop_ratio, :base)
        return getfield(opts, name)
    else
        return getproperty(getfield(opts, :base), name)
    end
end

"""
    flat_slab(; h_drop=nothing, a_drop_ratio=nothing, kwargs...) -> FlatSlabOptions

Convenience constructor: forward flat plate kwargs through `base`.

# Example
```julia
flat_slab(method = EFM(solver=:asap), punching_strategy = :reinforce_last)
flat_slab(method = EFM(solver=:asap), shear_studs = :if_needed)  # backward compat
```
"""
function flat_slab(; h_drop = nothing, a_drop_ratio = nothing, base_kw...)
    base = FlatPlateOptions(; base_kw...)
    FlatSlabOptions(; h_drop, a_drop_ratio, base)
end

"""
    VaultOptions

Sizing options for unreinforced parabolic vaults.

Supports two modes:
1. **Analytical mode**: Fix both rise AND thickness → evaluate constraints at that point
2. **Optimization mode**: Fix zero or one variable → optimize to minimize volume/weight/carbon

# Rise Specification (choose ONE, or use default)

**For optimization** (search over a range):
- `lambda_bounds`: `(λ_min, λ_max)` where λ = span/rise. Higher λ = shallower vault.
- `rise_bounds`: `(min, max)` absolute rise bounds [length]
- Default if none: `lambda_bounds = (10, 20)` → rise ∈ (span/20, span/10)

**For fixed geometry** (analytical mode):
- `lambda`: Fixed span/rise ratio (e.g., 15.0 → rise = span/15)
- `rise`: Fixed rise [length]

Note: Provide at most ONE of: `lambda_bounds`, `rise_bounds`, `lambda`, or `rise`

# Thickness Specification
- `thickness_bounds`: `(min, max)` for optimization (default: 2"–4")
- `thickness`: Fixed thickness for analytical mode

# Other Geometry
- `trib_depth`: Tributary depth / rib spacing (default: 1.0m)
- `rib_depth`: Rib width in span direction (default: 0 = no ribs)
- `rib_apex_rise`: Rib height above extrados (default: 0)

# Loading
- `finishing_load`: Topping/screed load (default: 0)

# Design Checks
- `allowable_stress`: Max stress in MPa (default: 0.45 fc')
- `deflection_limit`: Max rise reduction (default: span/240)
- `check_asymmetric`: Check half-span live load (default: true)

# Optimization
- `objective`: MinVolume(), MinWeight(), MinCarbon(), MinCost()
- `solver`: `:grid` (default) or `:ipopt`
- `n_grid`, `n_refine`: Grid search parameters

# Material
- `material`: Concrete for density, E, fc' (default: NWC_4000)

# Examples
```julia
# OPTIMIZATION: Use defaults (λ ∈ (10,20), t ∈ (2",4"))
opts = VaultOptions()

# OPTIMIZATION: Custom lambda bounds
opts = VaultOptions(lambda_bounds=(8.0, 15.0))

# OPTIMIZATION: Absolute rise bounds instead of lambda
opts = VaultOptions(rise_bounds=(0.5u"m", 1.5u"m"))

# PARTIAL: Fix lambda, optimize thickness
opts = VaultOptions(lambda=12.0)

# PARTIAL: Fix thickness, optimize rise (uses default lambda_bounds)
opts = VaultOptions(thickness=75u"mm")

# ANALYTICAL: Fixed geometry → constraint evaluation
opts = VaultOptions(lambda=15.0, thickness=50u"mm")
opts = VaultOptions(rise=0.5u"m", thickness=50u"mm")

# Minimize carbon with custom material
opts = VaultOptions(
    lambda_bounds = (10.0, 15.0),
    objective = MinCarbon(),
    material = NWC_GGBS
)
```
"""
Base.@kwdef struct VaultOptions <: AbstractFloorOptions
    # ─── Rise Bounds (optimization mode) ───
    # Provide ONE of: lambda_bounds, rise_bounds, lambda, or rise
    # If none provided, defaults to lambda_bounds = (10, 20)
    lambda_bounds::Union{Tuple{Float64, Float64}, Nothing} = nothing
    rise_bounds::Union{Tuple{<:Length, <:Length}, Nothing} = nothing
    
    # ─── Thickness Bounds ───
    thickness_bounds::Tuple{<:Length, <:Length} = (2.0u"inch", 4.0u"inch")
    
    # ─── Fixed Values (analytical mode or partial optimization) ───
    rise::Union{Length, Nothing} = nothing       # fixed rise → optimize thickness only
    lambda::Union{Real, Nothing} = nothing       # fixed λ=span/rise (alternative to rise)
    thickness::Union{Length, Nothing} = nothing  # fixed thickness → optimize rise only
    
    # ─── Geometry ───
    trib_depth::Length = 1.0u"m"                 # tributary depth / rib spacing
    rib_depth::Length = 0.0u"m"                  # rib width (0 = no ribs)
    rib_apex_rise::Length = 0.0u"m"              # rib height above extrados

    # ─── Loading ───
    finishing_load::Pressure = 0.0u"kN/m^2"      # topping/screed load

    # ─── Design Checks ───
    allowable_stress::Union{Real, Nothing} = nothing  # MPa (computed: 0.45 fc')
    deflection_limit::Union{Length, Nothing} = nothing  # (computed: span/240)
    check_asymmetric::Bool = true                # check half-span live load case
    
    # ─── Optimization ───
    objective::AbstractObjective = MinVolume()
    solver::Symbol = :grid                       # :grid or :ipopt
    n_grid::Int = 20                             # grid points per dimension
    n_refine::Int = 2                            # refinement iterations
    
    # ─── Analysis Method ───
    method::VaultAnalysisMethod = HaileAnalytical()
    
    # ─── Material ───
    material::Concrete = NWC_4000                # concrete for density, E, fc'
end

"""Return the canonical floor system symbol for `VaultOptions`."""
floor_symbol(::VaultOptions) = :vault

"""Composite deck options (steel deck + concrete fill)."""
Base.@kwdef struct CompositeDeckOptions <: AbstractFloorOptions
    deck_material::Metal = A992_Steel
    fill_material::Union{Concrete, Nothing} = nothing  # Uses primary if nothing
    deck_profile::String = "2VLI"
end

"""Return the canonical floor system symbol for `CompositeDeckOptions`."""
floor_symbol(::CompositeDeckOptions) = :composite_deck

"""Timber panel options (CLT, DLT, NLT)."""
Base.@kwdef struct TimberOptions <: AbstractFloorOptions
    timber_material::Union{AbstractMaterial, Nothing} = nothing  # Uses primary if nothing
end

"""Return the canonical floor system symbol for `TimberOptions`."""
floor_symbol(::TimberOptions) = :clt  # default timber type

# =============================================================================
# Tributary Axis Resolution
# =============================================================================

"""
    resolve_tributary_axis(ft, spans, tax) -> Union{NTuple{2,Float64}, Nothing}

Resolve the tributary axis for a floor type, respecting a user override.

## Arguments
- `ft`: Floor system type (e.g., `OneWay()`, `FlatPlate()`)
- `spans`: `SpanInfo` for the cell
- `tax`: Override value — `nothing` (use default), `:isotropic` (force 2-way),
  or `(x, y)` tuple (force direction)

## Returns
- `nothing`: Use isotropic straight skeleton (two-way tributary areas)
- `(x, y)` tuple: Use directed partitioning along this axis

## Examples
```julia
resolve_tributary_axis(OneWay(), spans, nothing)            # → default axis
resolve_tributary_axis(FlatPlate(), spans, :isotropic)      # → nothing
resolve_tributary_axis(FlatPlate(), spans, (0.707, 0.707))  # → (0.707, 0.707)
```
"""
function resolve_tributary_axis(ft::AbstractFloorSystem, spans, tax)
    tax === :isotropic && return nothing
    tax isa NTuple{2, <:Real} && return (Float64(tax[1]), Float64(tax[2]))
    return default_tributary_axis(ft, spans)
end

# =============================================================================
# Material Resolution (for EC calculation)
# =============================================================================

"""
    result_materials(result, primary_mat, opts::AbstractFloorOptions) -> Dict{Symbol, AbstractMaterial}

Get material dict for a floor result, mapping material symbols to actual
material objects.  The `opts` type carries the floor system identity, so no
separate `floor_type` argument is needed.

## Example
```julia
result = CIPSlabResult(...)
mats = result_materials(result, NWC_4000, FlatPlateOptions())
# → Dict(:concrete => NWC_4000, :steel => Rebar_60)
```
"""
function result_materials end

# ─── RC floor results dispatch on options type ───

"""Return concrete + rebar materials for a CIP slab result with flat plate options."""
function result_materials(::CIPSlabResult, primary_mat, opts::FlatPlateOptions)
    Dict{Symbol, AbstractMaterial}(:concrete => opts.material.concrete, :steel => opts.material.rebar)
end

"""Return concrete + rebar materials for a panel-level flat plate result."""
function result_materials(::FlatPlatePanelResult, primary_mat, opts::FlatPlateOptions)
    Dict{Symbol, AbstractMaterial}(:concrete => opts.material.concrete, :steel => opts.material.rebar)
end

"""Delegate flat slab CIP result materials to the base `FlatPlateOptions`."""
result_materials(r::CIPSlabResult, pm, opts::FlatSlabOptions) = result_materials(r, pm, opts.base)

"""Delegate flat slab panel result materials to the base `FlatPlateOptions`."""
result_materials(r::FlatPlatePanelResult, pm, opts::FlatSlabOptions) = result_materials(r, pm, opts.base)

"""Return concrete + rebar materials for a one-way CIP slab result."""
function result_materials(::CIPSlabResult, primary_mat, opts::OneWayOptions)
    Dict{Symbol, AbstractMaterial}(:concrete => opts.material.concrete, :steel => opts.material.rebar)
end

"""Return concrete material for a vault result (unreinforced)."""
result_materials(::VaultResult, primary_mat, opts::VaultOptions) =
    Dict{Symbol, AbstractMaterial}(:concrete => opts.material)

"""Return steel + concrete materials for a composite deck result."""
function result_materials(::CompositeDeckResult, primary_mat, opts::CompositeDeckOptions)
    Dict{Symbol, AbstractMaterial}(
        :steel => opts.deck_material,
        :concrete => something(opts.fill_material, primary_mat)
    )
end

"""Return steel material for a joist deck result (no concrete fill)."""
result_materials(::JoistDeckResult, primary_mat, opts::CompositeDeckOptions) =
    Dict{Symbol, AbstractMaterial}(:steel => opts.deck_material)

"""Return timber material for a timber panel result (CLT/DLT/NLT)."""
result_materials(::TimberPanelResult, primary_mat, opts::TimberOptions) =
    Dict{Symbol, AbstractMaterial}(:timber => something(opts.timber_material, primary_mat))

"""Return timber material for a timber joist result."""
result_materials(::TimberJoistResult, primary_mat, opts::TimberOptions) =
    Dict{Symbol, AbstractMaterial}(:timber => something(opts.timber_material, primary_mat))

"""Return concrete material for a profile-based slab result (fallback)."""
result_materials(::ProfileResult, primary_mat, ::AbstractFloorOptions) =
    Dict{Symbol, AbstractMaterial}(:concrete => primary_mat)

"""Return concrete material for a shaped slab result (fallback)."""
result_materials(::ShapedSlabResult, primary_mat, ::AbstractFloorOptions) =
    Dict{Symbol, AbstractMaterial}(:concrete => primary_mat)

"""Generic fallback: assume concrete as the primary material."""
result_materials(::AbstractFloorResult, primary_mat, ::AbstractFloorOptions) =
    Dict{Symbol, AbstractMaterial}(:concrete => primary_mat)
