# FloorOptions: user-facing configuration for floor/slab sizing
#
# Motivation:
# - Many sizing methods accept impactful keyword args (e.g. ACI support conditions),
#   but those keywords are hard to discover through higher-level APIs that forward kwargs.
# - A single structured `FloorOptions` object makes defaults explicit, composable, and
#   easier to document and introspect.

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
opts = FloorOptions(one_way=OneWayOptions(support=ONE_END_CONT))
```
"""
Base.@kwdef struct OneWayOptions
    material::ReinforcedConcreteMaterial = RC_4000_60
    cover::Length = 19.05u"mm"
    bar_size::Int = 5
    support::SupportCondition = BOTH_ENDS_CONT
end

"""
    FlatPlateOptions

Options for flat plate / flat slab / waffle / PT slab sizing per ACI 318 Chapter 8.

# Materials & Detailing
- `material`: Reinforced concrete material (default: `RC_4000_60`)
- `cover`: Clear cover to reinforcement (default: 0.75")
- `bar_size`: Typical rebar size #3-#11 (default: 5)

# Analysis Method
- `analysis_method`: Two-way slab analysis method
  - `:mddm` - Modified Direct Design Method (simplified)
  - `:ddm` - Direct Design Method (full ACI tables)
  - `:efm` - Equivalent Frame Method (most accurate)

# Edge Conditions
- `has_edge_beam`: Spandrel beam at exterior (affects DDM moment distribution)
- `has_drop_panels`: Drop panels at columns (affects PT thickness)

# Slab Grouping
- `grouping`: How to group slabs for envelope sizing
  - `:individual`, `:by_floor`, `:building_wide`

# Strength Reduction (ACI 318-14 Table 21.2.1)
- `φ_flexure`: Flexure (default: 0.90)
- `φ_shear`: Shear (default: 0.75)
- `λ`: Lightweight concrete factor (default: 1.0)

# Deflection
- `deflection_limit`: `:L_240`, `:L_360`, `:L_480`

# Punching Shear Resolution (ACI 318-19 §22.6.8)
- `shear_studs`: Strategy for punching shear reinforcement
  - `:never` - Only grow columns; error if maxed (default)
  - `:if_needed` - Try columns first, use studs if columns max out
  - `:always` - Use studs first, grow columns only if studs insufficient
- `max_column_size`: Maximum column size before considering studs (default: 30")
- `stud_material`: Shear stud steel material (default: `Stud_51`)
- `stud_diameter`: Stud diameter (default: 1/2")

# Example
```julia
opts = FloorOptions(flat_plate=FlatPlateOptions(analysis_method=:efm))

# Enable shear studs if columns can't resolve punching
opts = FloorOptions(flat_plate=FlatPlateOptions(shear_studs=:if_needed))
```
"""
Base.@kwdef struct FlatPlateOptions
    material::ReinforcedConcreteMaterial = RC_4000_60
    cover::Length = 19.05u"mm"
    bar_size::Int = 5
    has_edge_beam::Bool = false
    has_drop_panels::Bool = false
    analysis_method::Symbol = :ddm
    grouping::Symbol = :by_floor
    φ_flexure::Float64 = 0.90
    φ_shear::Float64 = 0.75
    λ::Float64 = 1.0
    deflection_limit::Symbol = :L_360
    # Punching shear resolution
    shear_studs::Symbol = :never
    max_column_size::Length = 30.0u"inch"
    stud_material::RebarSteel = Stud_51
    stud_diameter::Length = 0.5u"inch"
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
opts = FloorOptions(vault=VaultOptions())

# OPTIMIZATION: Custom lambda bounds
opts = FloorOptions(vault=VaultOptions(lambda_bounds=(8.0, 15.0)))

# OPTIMIZATION: Absolute rise bounds instead of lambda
opts = FloorOptions(vault=VaultOptions(rise_bounds=(0.5u"m", 1.5u"m")))

# PARTIAL: Fix lambda, optimize thickness
opts = FloorOptions(vault=VaultOptions(lambda=12.0))

# PARTIAL: Fix thickness, optimize rise (uses default lambda_bounds)
opts = FloorOptions(vault=VaultOptions(thickness=75u"mm"))

# ANALYTICAL: Fixed geometry → constraint evaluation
opts = FloorOptions(vault=VaultOptions(lambda=15.0, thickness=50u"mm"))
opts = FloorOptions(vault=VaultOptions(rise=0.5u"m", thickness=50u"mm"))

# Minimize carbon with custom material
opts = FloorOptions(vault=VaultOptions(
    lambda_bounds = (10.0, 15.0),
    objective = MinCarbon(),
    material = NWC_GGBS
))
```
"""
Base.@kwdef struct VaultOptions
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

"""Composite deck options (steel deck + concrete fill)."""
Base.@kwdef struct CompositeDeckOptions
    deck_material::Metal = A992_Steel
    fill_material::Union{Concrete, Nothing} = nothing  # Uses primary if nothing
    deck_profile::String = "2VLI"
end

"""Timber panel options (CLT, DLT, NLT)."""
Base.@kwdef struct TimberOptions
    timber_material::Union{AbstractMaterial, Nothing} = nothing  # Uses primary if nothing
end

"""
    FloorOptions(; flat_plate, one_way, vault, composite, timber, tributary_axis)

Unified options container for floor sizing and analysis.

Each floor type uses its corresponding options:
- Flat plate / flat slab / waffle / PT → `flat_plate::FlatPlateOptions`
- One-way slabs → `one_way::OneWayOptions`
- Vaults → `vault::VaultOptions`
- Composite deck → `composite::CompositeDeckOptions`
- Timber → `timber::TimberOptions`

## Examples

```julia
# Flat plate with EFM analysis
opts = FloorOptions(flat_plate=FlatPlateOptions(analysis_method=:efm))

# One-way slab with exterior support condition
opts = FloorOptions(one_way=OneWayOptions(support=ONE_END_CONT))

# Vault optimization
opts = FloorOptions(vault=VaultOptions(lambda_bounds=(10.0, 15.0)))
```
"""
Base.@kwdef struct FloorOptions
    flat_plate::FlatPlateOptions = FlatPlateOptions()
    one_way::OneWayOptions = OneWayOptions()
    vault::VaultOptions = VaultOptions()
    composite::CompositeDeckOptions = CompositeDeckOptions()
    timber::TimberOptions = TimberOptions()
    tributary_axis::Union{Nothing, Symbol, NTuple{2, Float64}} = nothing
end

# =============================================================================
# Tributary Axis Resolution
# =============================================================================

"""
    resolve_tributary_axis(ft, spans, opts) -> Union{NTuple{2,Float64}, Nothing}

Resolve the tributary axis for a floor type, respecting user override in FloorOptions.

## Returns
- `nothing`: Use isotropic straight skeleton (two-way tributary areas)
- `(x, y)` tuple: Use directed partitioning along this axis (one-way tributary areas)

## Resolution Priority
1. `opts.tributary_axis === :isotropic` → `nothing` (force isotropic)
2. `opts.tributary_axis isa NTuple{2,Float64}` → use that custom axis
3. Otherwise → `default_tributary_axis(ft, spans)` (floor type default)

## Examples

```julia
ft = OneWay()
spans = SpanInfo(verts)  # e.g., axis = (1.0, 0.0)

# Default: one-way uses span axis
resolve_tributary_axis(ft, spans, FloorOptions())  # → (1.0, 0.0)

# Override to isotropic
resolve_tributary_axis(ft, spans, FloorOptions(tributary_axis=:isotropic))  # → nothing

# Override to custom 45° axis
resolve_tributary_axis(ft, spans, FloorOptions(tributary_axis=(0.707, 0.707)))  # → (0.707, 0.707)
```
"""
function resolve_tributary_axis(ft::AbstractFloorSystem, spans, opts::FloorOptions)
    tax = opts.tributary_axis
    
    # Explicit override: force isotropic
    if tax === :isotropic
        return nothing
    end
    
    # Explicit override: custom axis (accept any Real tuple, convert to Float64)
    if tax isa NTuple{2, <:Real}
        return (Float64(tax[1]), Float64(tax[2]))
    end
    
    # Use floor type default
    return default_tributary_axis(ft, spans)
end

# =============================================================================
# Material Resolution (for EC calculation)
# =============================================================================

"""
    result_materials(result, primary_mat, opts, floor_type) -> Dict{Symbol, AbstractMaterial}

Get material dict for a floor result, mapping material symbols to actual material objects.
Uses type-specific options for secondary materials, falling back to primary for unspecified.

The `floor_type` argument is needed for `CIPSlabResult` since it's shared by both 
one-way slabs (which use `OneWayOptions`) and flat plates (which use `FlatPlateOptions`).

## Example
```julia
result = CIPSlabResult(...)
mats = result_materials(result, NWC_4000, FloorOptions(), FlatPlate())
# → Dict(:concrete => NWC_4000, :steel => Rebar_60)
```
"""
function result_materials end

# CIP slabs: dispatch on floor type to get correct options
function result_materials(::CIPSlabResult, primary_mat, opts::FloorOptions, ::OneWay)
    Dict{Symbol, AbstractMaterial}(
        :concrete => opts.one_way.material.concrete,
        :steel => opts.one_way.material.rebar
    )
end

function result_materials(::CIPSlabResult, primary_mat, opts::FloorOptions, ::FlatPlate)
    Dict{Symbol, AbstractMaterial}(
        :concrete => opts.flat_plate.material.concrete,
        :steel => opts.flat_plate.material.rebar
    )
end

function result_materials(::CIPSlabResult, primary_mat, opts::FloorOptions, ::FlatSlab)
    Dict{Symbol, AbstractMaterial}(
        :concrete => opts.flat_plate.material.concrete,
        :steel => opts.flat_plate.material.rebar
    )
end

function result_materials(::CIPSlabResult, primary_mat, opts::FloorOptions, ::TwoWay)
    Dict{Symbol, AbstractMaterial}(
        :concrete => opts.flat_plate.material.concrete,
        :steel => opts.flat_plate.material.rebar
    )
end

function result_materials(::CIPSlabResult, primary_mat, opts::FloorOptions, ::Waffle)
    Dict{Symbol, AbstractMaterial}(
        :concrete => opts.flat_plate.material.concrete,
        :steel => opts.flat_plate.material.rebar
    )
end

function result_materials(::CIPSlabResult, primary_mat, opts::FloorOptions, ::PTBanded)
    Dict{Symbol, AbstractMaterial}(
        :concrete => opts.flat_plate.material.concrete,
        :steel => opts.flat_plate.material.rebar
    )
end

# Fallback for CIP without floor type (defaults to flat_plate for backwards compat)
function result_materials(r::CIPSlabResult, primary_mat, opts::FloorOptions)
    result_materials(r, primary_mat, opts, FlatPlate())
end

# Other result types (floor_type optional, ignored)
result_materials(r::ProfileResult, pm, opts::FloorOptions, ::AbstractFloorSystem) = result_materials(r, pm, opts)
result_materials(::ProfileResult, primary_mat, opts::FloorOptions) = Dict{Symbol, AbstractMaterial}(:concrete => primary_mat)

result_materials(r::CompositeDeckResult, pm, opts::FloorOptions, ::AbstractFloorSystem) = result_materials(r, pm, opts)
function result_materials(::CompositeDeckResult, primary_mat, opts::FloorOptions)
    Dict{Symbol, AbstractMaterial}(
        :steel => opts.composite.deck_material,
        :concrete => something(opts.composite.fill_material, primary_mat)
    )
end

result_materials(r::JoistDeckResult, pm, opts::FloorOptions, ::AbstractFloorSystem) = result_materials(r, pm, opts)
result_materials(::JoistDeckResult, primary_mat, opts::FloorOptions) = Dict{Symbol, AbstractMaterial}(:steel => opts.composite.deck_material)

result_materials(r::TimberPanelResult, pm, opts::FloorOptions, ::AbstractFloorSystem) = result_materials(r, pm, opts)
function result_materials(::TimberPanelResult, primary_mat, opts::FloorOptions)
    Dict{Symbol, AbstractMaterial}(:timber => something(opts.timber.timber_material, primary_mat))
end

result_materials(r::TimberJoistResult, pm, opts::FloorOptions, ::AbstractFloorSystem) = result_materials(r, pm, opts)
function result_materials(::TimberJoistResult, primary_mat, opts::FloorOptions)
    Dict{Symbol, AbstractMaterial}(:timber => something(opts.timber.timber_material, primary_mat))
end

result_materials(r::VaultResult, pm, opts::FloorOptions, ::AbstractFloorSystem) = result_materials(r, pm, opts)
result_materials(::VaultResult, primary_mat, opts::FloorOptions) = Dict{Symbol, AbstractMaterial}(:concrete => opts.vault.material)

result_materials(r::ShapedSlabResult, pm, opts::FloorOptions, ::AbstractFloorSystem) = result_materials(r, pm, opts)
result_materials(::ShapedSlabResult, primary_mat, opts::FloorOptions) = Dict{Symbol, AbstractMaterial}(:concrete => primary_mat)
