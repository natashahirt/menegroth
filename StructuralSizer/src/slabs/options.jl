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
#   DesignParameters(floor = FlatPlateOptions(method = EFM(:asap)))

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
params = DesignParameters(floor = FlatPlateOptions(method = EFM(:asap)))

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
  - `EFM()` — Equivalent Frame Method (default solver: ASAP)
  - `EFM(:moment_distribution)` — EFM with Hardy Cross
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

# Punching Shear Resolution (ACI 318-11 §11.11.5)
- `shear_studs`: Strategy for punching shear reinforcement
  - `:never` — Only grow columns; error if maxed (default)
  - `:if_needed` — Try columns first, use studs if columns max out
  - `:always` — Use studs first, grow columns only if studs insufficient
- `max_column_size`: Maximum column size before considering studs (default: 30")
- `stud_material`: Shear stud steel material (default: `Stud_51`)
- `stud_diameter`: Stud diameter (default: 1/2")

# Optimization
- `objective`: Objective for `size_flat_plate_optimized` grid search
  - `MinVolume()` (default), `MinWeight()`, `MinCost()`, `MinCarbon()`

# Column Cracking (FEA only)
- `col_I_factor`: Cracking reduction for FEA column stubs (default: 0.70 per ACI 318-11 §10.10.4.1).
  Set to 1.0 to recover gross (uncracked) column stiffness.

# Example
```julia
# Recommended: use typed method objects
params = DesignParameters(floor = FlatPlateOptions(method = EFM(:asap)))

# Enable shear studs if columns can't resolve punching
opts = FlatPlateOptions(shear_studs = :if_needed)

# Minimize embodied carbon
opts = FlatPlateOptions(objective = MinCarbon())
```
"""
Base.@kwdef struct FlatPlateOptions <: AbstractFloorOptions
    material::ReinforcedConcreteMaterial = RC_4000_60
    cover::Length = 19.05u"mm"
    bar_size::Int = 5
    has_edge_beam::Bool = false
    edge_beam_βt::Union{Float64, Nothing} = nothing  # nothing → auto-compute if has_edge_beam
    method::FlatPlateAnalysisMethod = DDM()
    grouping::Symbol = :by_floor
    φ_flexure::Float64 = 0.90
    φ_shear::Float64 = 0.75
    λ::Union{Float64, Nothing} = nothing  # nothing → use material.concrete.λ
    deflection_limit::Symbol = :L_360
    # Punching shear resolution
    shear_studs::Symbol = :never
    max_column_size::Length = 30.0u"inch"
    stud_material::RebarSteel = Stud_51
    stud_diameter::Length = 0.5u"inch"
    # Override ACI minimum thickness (nothing = use ACI Table 8.3.1.1)
    min_h::Union{Length, Nothing} = nothing
    # Optimization objective (used by size_flat_plate_optimized)
    objective::AbstractObjective = MinVolume()
    # Column cracking factor for FEA stub stiffness (ACI 318-11 §10.10.4.1)
    col_I_factor::Float64 = 0.70
end

floor_symbol(::FlatPlateOptions) = :flat_plate

# Backward-compat: .analysis_method returns a Symbol derived from the typed method
function Base.getproperty(opts::FlatPlateOptions, name::Symbol)
    if name === :analysis_method
        m = getfield(opts, :method)
        return _method_to_symbol(m)
    end
    return getfield(opts, name)
end

"""Convert a typed FlatPlateAnalysisMethod to the legacy Symbol representation."""
function _method_to_symbol(m::FlatPlateAnalysisMethod)
    m isa DDM && m.variant == :simplified && return :mddm
    m isa DDM && return :ddm
    m isa EFM && m.solver == :moment_distribution && return :efm_hc
    m isa EFM && return :efm
    m isa FEA && return :fea
    return :ddm
end

"""Convert a legacy analysis_method Symbol to a typed FlatPlateAnalysisMethod."""
function _symbol_to_method(s::Symbol)::FlatPlateAnalysisMethod
    s == :ddm      ? DDM() :
    s == :mddm     ? DDM(:simplified) :
    s == :efm      ? EFM() :
    s == :efm_hc   ? EFM(:moment_distribution) :
    s == :efm_asap ? EFM(:asap) :
    s == :fea      ? FEA() :
    throw(ArgumentError("Unknown analysis_method :$s. Use :ddm, :mddm, :efm, :efm_hc, :efm_asap, or :fea."))
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
flat_slab(method = EFM(:asap), shear_studs = :if_needed)
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

floor_symbol(::FlatSlabOptions) = :flat_slab

"""Convert FlatSlabOptions to FlatPlateOptions for the shared pipeline."""
as_flat_plate_options(opts::FlatSlabOptions) = opts.base

# Property forwarding: allow opts.method instead of opts.base.method
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
flat_slab(method = EFM(:asap), shear_studs = :if_needed)
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

floor_symbol(::VaultOptions) = :vault

"""Composite deck options (steel deck + concrete fill)."""
Base.@kwdef struct CompositeDeckOptions <: AbstractFloorOptions
    deck_material::Metal = A992_Steel
    fill_material::Union{Concrete, Nothing} = nothing  # Uses primary if nothing
    deck_profile::String = "2VLI"
end

floor_symbol(::CompositeDeckOptions) = :composite_deck

"""Timber panel options (CLT, DLT, NLT)."""
Base.@kwdef struct TimberOptions <: AbstractFloorOptions
    timber_material::Union{AbstractMaterial, Nothing} = nothing  # Uses primary if nothing
end

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

# FlatPlateOptions covers flat_plate, two_way, waffle, pt_banded
function result_materials(::CIPSlabResult, primary_mat, opts::FlatPlateOptions)
    Dict{Symbol, AbstractMaterial}(:concrete => opts.material.concrete, :steel => opts.material.rebar)
end

function result_materials(::FlatPlatePanelResult, primary_mat, opts::FlatPlateOptions)
    Dict{Symbol, AbstractMaterial}(:concrete => opts.material.concrete, :steel => opts.material.rebar)
end

# FlatSlabOptions delegates to base FlatPlateOptions
result_materials(r::CIPSlabResult, pm, opts::FlatSlabOptions) = result_materials(r, pm, opts.base)
result_materials(r::FlatPlatePanelResult, pm, opts::FlatSlabOptions) = result_materials(r, pm, opts.base)

# OneWayOptions
function result_materials(::CIPSlabResult, primary_mat, opts::OneWayOptions)
    Dict{Symbol, AbstractMaterial}(:concrete => opts.material.concrete, :steel => opts.material.rebar)
end

# VaultOptions
result_materials(::VaultResult, primary_mat, opts::VaultOptions) =
    Dict{Symbol, AbstractMaterial}(:concrete => opts.material)

# CompositeDeckOptions
function result_materials(::CompositeDeckResult, primary_mat, opts::CompositeDeckOptions)
    Dict{Symbol, AbstractMaterial}(
        :steel => opts.deck_material,
        :concrete => something(opts.fill_material, primary_mat)
    )
end

result_materials(::JoistDeckResult, primary_mat, opts::CompositeDeckOptions) =
    Dict{Symbol, AbstractMaterial}(:steel => opts.deck_material)

# TimberOptions
result_materials(::TimberPanelResult, primary_mat, opts::TimberOptions) =
    Dict{Symbol, AbstractMaterial}(:timber => something(opts.timber_material, primary_mat))

result_materials(::TimberJoistResult, primary_mat, opts::TimberOptions) =
    Dict{Symbol, AbstractMaterial}(:timber => something(opts.timber_material, primary_mat))

# Simple fallbacks (ProfileResult, ShapedSlabResult, etc.)
result_materials(::ProfileResult, primary_mat, ::AbstractFloorOptions) =
    Dict{Symbol, AbstractMaterial}(:concrete => primary_mat)

result_materials(::ShapedSlabResult, primary_mat, ::AbstractFloorOptions) =
    Dict{Symbol, AbstractMaterial}(:concrete => primary_mat)

# Generic fallback for any result × any options
result_materials(::AbstractFloorResult, primary_mat, ::AbstractFloorOptions) =
    Dict{Symbol, AbstractMaterial}(:concrete => primary_mat)
