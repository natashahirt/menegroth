# =============================================================================
# Design Result Types
# =============================================================================
#
# Separates building geometry/loads (BuildingStructure) from design results
# (BuildingDesign). This enables:
#   - Multiple designs for the same building (different materials)
#   - Parametric studies (sweep f'c, thickness, etc.)
#   - Design comparison and optimization
#
# Architecture:
#   BuildingStructure          → geometry, loads, tributaries (see building_types.jl)
#   BuildingDesign             → design results for a specific parameter set
#   DesignParameters           → material choices, optimization targets
#
# Unit Convention:
#   All design results are stored in coherent SI:
#     m, m², m³, kN, kN·m, kPa, kg
#   Analysis modules work in whatever units are natural internally,
#   then normalize at their return boundary.
#   DisplayUnits controls how values are presented to the user.
# =============================================================================

using Dates
using Unitful
using Accessors: setproperties, @set

# =============================================================================
# Display Unit Preferences
# =============================================================================

"""
    DisplayUnits(system::Symbol=:imperial)

Unit preferences for design output display. All design data is stored in
coherent SI (m, m², m³, kN, kN·m, kPa, kg). `DisplayUnits` controls what
units are shown to the user in summaries, reports, and visualization labels.

Use presets `imperial` or `metric`, or customize individual categories.

# Categories
`:length`, `:thickness`, `:span`, `:area`, `:volume`, `:force`, `:moment`,
`:pressure`, `:stress`, `:weight`, `:mass`, `:deflection`, `:spacing`,
`:rebar_dia`, `:rebar_area`

# Example
```julia
# Use presets
params = DesignParameters(display_units = imperial)
params = DesignParameters(display_units = metric)

# Customize: imperial but volume in m³
du = DisplayUnits(:imperial)
du.units[:volume] = u"m^3"
params = DesignParameters(display_units = du)
```
"""
mutable struct DisplayUnits
    units::Dict{Symbol, Any}
end

"""Construct `DisplayUnits` from a system preset (`:imperial` or `:metric`)."""
function DisplayUnits(system::Symbol)
    system === :imperial ? DisplayUnits(_imperial_units()) :
    system === :metric   ? DisplayUnits(_metric_units()) :
    error("Unknown unit system :$system. Use :imperial or :metric.")
end

"""Build the imperial unit lookup table."""
function _imperial_units()
    Dict{Symbol, Any}(
        :length      => u"ft",
        :thickness   => u"inch",
        :span        => u"ft",
        :area        => u"ft^2",
        :volume      => u"ft^3",
        :force       => kip,
        :moment      => kip * u"ft",
        :pressure    => psf,
        :stress      => ksi,
        :weight      => u"lbf",
        :mass        => u"lb",
        :deflection  => u"inch",
        :spacing     => u"inch",
        :rebar_dia   => u"inch",
        :rebar_area  => u"inch^2",
    )
end

"""Build the metric unit lookup table."""
function _metric_units()
    Dict{Symbol, Any}(
        :length      => u"m",
        :thickness   => u"mm",
        :span        => u"m",
        :area        => u"m^2",
        :volume      => u"m^3",
        :force       => u"kN",
        :moment      => u"kN*m",
        :pressure    => u"kPa",
        :stress      => u"MPa",
        :weight      => u"kN",
        :mass        => u"kg",
        :deflection  => u"mm",
        :spacing     => u"mm",
        :rebar_dia   => u"mm",
        :rebar_area  => u"mm^2",
    )
end

const imperial = DisplayUnits(:imperial)
const metric   = DisplayUnits(:metric)

"""
    fmt(du::DisplayUnits, category::Symbol, value; digits=2)

Convert a Unitful value to display units and round.

# Example
```julia
fmt(imperial, :span, 12.192u"m")       # → 40.0 ft
fmt(imperial, :thickness, 0.2032u"m")  # → 8.0 inch
fmt(metric, :force, 100.0u"kN")        # → 100.0 kN
```
"""
fmt(du::DisplayUnits, cat::Symbol, val; digits=2) = round(du.units[cat], val; digits=digits)

# =============================================================================
# Foundation Parameters
# =============================================================================

"""
Foundation sizing parameters.

# Fields
- `soil`: Soil profile (bearing capacity, settlement params)
- `options`: Design options (`FoundationOptions` from StructuralSizer).
  Controls strategy (`:auto`, `:auto_strip_spread`, `:all_spread`, `:all_strip`, `:mat`) and per-type
  knobs (`options.spread_params`, `options.strip_params`, `options.mat_params`).
- `concrete`: Concrete grade for footings (IS path only; ACI uses `options.spread_params.material`)
- `rebar`: Rebar grade for footings (IS path only)
- `pier_width`: Column/pier width (IS path only; ACI uses `options.spread_params.pier_c1`)
- `min_depth`: Minimum footing depth (IS path only; ACI uses `options.spread_params.min_depth`)
- `group_tolerance`: Tolerance for grouping similar foundations (default 0.15 = 15%)

# Example
```julia
# ACI (default) — material/detailing in options
fp = FoundationParameters(soil = medium_sand)

# With strategy override
fp = FoundationParameters(
    soil = medium_sand,
    options = FoundationOptions(strategy = :all_spread),
)
```
"""
Base.@kwdef struct FoundationParameters
    soil::StructuralSizer.Soil = StructuralSizer.medium_sand
    options::StructuralSizer.FoundationOptions = StructuralSizer.FoundationOptions()
    concrete::StructuralSizer.Concrete = StructuralSizer.NWC_3000  # Default 3 ksi for footings
    rebar::StructuralSizer.RebarSteel = StructuralSizer.Rebar_60
    pier_width::typeof(1.0u"m") = 0.35u"m"
    min_depth::typeof(1.0u"m") = 0.4u"m"
    group_tolerance::Float64 = 0.15
end

# =============================================================================
# Material Options (cascading material specification)
# =============================================================================

"""
    MaterialOptions(; concrete, rebar, steel, timber, slab, column, beam)

Material specifications for building design.  Set building-level defaults
that cascade to all members, or override per-member type.

# Cascade Priority
1. Per-member override (`slab`, `column`, `beam`) — highest
2. Component materials (`concrete`, `rebar`, `steel`, `timber`)
3. Package defaults (NWC_4000, Rebar_60, A992_Steel)

# Example
```julia
# Set all concrete to 5 ksi
params = DesignParameters(materials = MaterialOptions(concrete = NWC_5000))

# Different concrete for slabs vs columns
params = DesignParameters(materials = MaterialOptions(
    slab   = RC_5000_60,   # 5 ksi slab
    column = RC_6000_75,   # 6 ksi columns, Grade 75 rebar
))

# Quick: just set everything at once
params = DesignParameters(materials = MaterialOptions(
    concrete = NWC_5000,
    rebar    = Rebar_75,
))
```
"""
Base.@kwdef struct MaterialOptions
    # ─── Component materials (building-level defaults) ───
    concrete::Union{StructuralSizer.Concrete, Nothing} = nothing
    rebar::Union{StructuralSizer.RebarSteel, Nothing} = nothing
    steel::Union{StructuralSizer.StructuralSteel, Nothing} = nothing
    timber::Union{StructuralSizer.Timber, Nothing} = nothing

    # ─── Per-member overrides (take priority over components) ───
    slab::Union{StructuralSizer.ReinforcedConcreteMaterial, Nothing} = nothing
    column::Union{StructuralSizer.ReinforcedConcreteMaterial, Nothing} = nothing
    beam::Union{StructuralSizer.StructuralSteel, Nothing} = nothing
end

"""Resolve the effective slab concrete from the material cascade."""
resolve_slab_concrete(m::MaterialOptions) = something(
    isnothing(m.slab) ? nothing : m.slab.concrete,
    m.concrete, StructuralSizer.NWC_4000)

"""Resolve the effective slab rebar from the material cascade."""
resolve_slab_rebar(m::MaterialOptions) = something(
    isnothing(m.slab) ? nothing : m.slab.rebar,
    m.rebar, StructuralSizer.Rebar_60)

"""Resolve the effective slab RC material (concrete + rebar) from the cascade."""
resolve_slab_rc(m::MaterialOptions) = isnothing(m.slab) ?
    StructuralSizer.ReinforcedConcreteMaterial(resolve_slab_concrete(m), resolve_slab_rebar(m)) :
    m.slab

"""Resolve the effective column concrete from the material cascade (default 6 ksi)."""
resolve_column_concrete(m::MaterialOptions) = something(
    isnothing(m.column) ? nothing : m.column.concrete,
    m.concrete, StructuralSizer.NWC_6000)

"""Resolve the effective column rebar from the material cascade."""
resolve_column_rebar(m::MaterialOptions) = something(
    isnothing(m.column) ? nothing : m.column.rebar,
    m.rebar, StructuralSizer.Rebar_60)

"""Resolve the effective column RC material (concrete + rebar) from the cascade."""
resolve_column_rc(m::MaterialOptions) = isnothing(m.column) ?
    StructuralSizer.ReinforcedConcreteMaterial(resolve_column_concrete(m), resolve_column_rebar(m)) :
    m.column

"""Resolve the effective beam steel from the material cascade."""
resolve_beam_steel(m::MaterialOptions) = something(m.beam, m.steel, StructuralSizer.A992_Steel)

"""
    check_material_compatibility(mat::MaterialOptions, floor::AbstractFloorOptions)

Warn if material choices are incompatible with the selected floor type.
"""
function check_material_compatibility(mat::MaterialOptions, floor::StructuralSizer.AbstractFloorOptions)
    fs = StructuralSizer.floor_symbol(floor)
    if fs in (:flat_plate, :flat_slab, :one_way, :two_way, :waffle, :pt_banded)
        if !isnothing(mat.steel) && isnothing(mat.beam)
            @warn "StructuralSteel set in materials but floor type :$fs uses concrete. steel applies to beams only."
        end
    elseif fs == :vault
        if !isnothing(mat.rebar) && isnothing(mat.slab) && isnothing(mat.column)
            @info "RebarSteel set but vaults are unreinforced. rebar applies to columns only."
        end
    end
end

# =============================================================================
# Default Frame Properties (precomputed SI to avoid runtime ksi→Pa conversion)
# =============================================================================
# A992 Steel: E = 29000 ksi, G = 11200 ksi, ρ = 490 pcf.
# Converted at compile time so DesignParameters defaults never trigger
# Unitful basefactor lookups that may fail on cold-start deployments.
const _DEFAULT_FRAME_E = uconvert(u"Pa",      A992_Steel.E)
const _DEFAULT_FRAME_G = uconvert(u"Pa",      A992_Steel.G)
const _DEFAULT_FRAME_ρ = uconvert(u"kg/m^3",  A992_Steel.ρ)

# =============================================================================
# Design Parameters
# =============================================================================

"""
Face-scoped floor override from API/client input.

- `floor_type`: Target floor system (currently supports `:vault` in scoped mode).
- `vault_lambda`: Optional vault span/rise ratio override.
- `faces`: Selector polygons in meters, each as `[(x,y,z), ...]`.
"""
Base.@kwdef struct ScopedFloorOverride
    floor_type::Symbol = :vault
    method::String = "DDM"
    deflection_limit::String = "L_360"
    punching_strategy::String = "grow_columns"
    target_edge_m::Union{Float64, Nothing} = nothing
    concrete::Union{Concrete, Nothing} = nothing
    vault_lambda::Union{Float64, Nothing} = nothing
    faces::Vector{Vector{NTuple{3, Float64}}} = Vector{NTuple{3, Float64}}[]
end

"""
Parameters that define a design configuration.

Different `DesignParameters` on the same `BuildingStructure` produce
different `BuildingDesign` results, enabling parametric studies.

# Materials
Use `MaterialOptions` for cascading material specification:
```julia
params = DesignParameters(materials = MaterialOptions(concrete = NWC_5000))
```

# Floor System
Pass a typed `AbstractFloorOptions` via `floor`:
```julia
params = DesignParameters(floor = FlatPlateOptions(method = EFM(solver=:asap)))
```

# Example
```julia
# Full control: materials, loads, sizing, and analysis
params = DesignParameters(
    name = "High-Rise Office",
    loads = office_loads,
    load_combinations = [strength_1_2D_1_6L, service],
    materials = MaterialOptions(concrete = NWC_5000, rebar = Rebar_75),
    columns = ConcreteColumnOptions(material = NWC_5000),
    beams = SteelBeamOptions(deflection_limit = 1/480),
    floor = FlatPlateOptions(method = EFM(), shear_studs = :if_needed),
    diaphragm_mode = :rigid,
    optimize_for = :carbon,
)

# Parametric sweep
base = DesignParameters(floor = FlatPlateOptions(), max_iterations = 3)
for m in [DDM(), EFM(), FEA()]
    d = design_building(struc, with(base; floor = FlatPlateOptions(method = m)))
end
```
"""
Base.@kwdef mutable struct DesignParameters
    # Identifiers
    name::String = "default"
    description::String = ""
    
    # ─── Gravity Loads (unfactored service level) ───
    loads::GravityLoads = GravityLoads()
    
    # ─── Materials (cascading) ───
    materials::MaterialOptions = MaterialOptions()
    
    # ─── Fire Rating ───
    # Building-level fire resistance requirement in hours.
    # Valid values: 0, 1, 1.5, 2, 3, 4  (0 = no fire design)
    # Concrete: controls min thickness, cover, dimensions (ACI 216.1)
    # Steel: controls coating thickness via fire_protection type
    fire_rating::Float64 = 0.0
    
    # ─── Fire Protection (steel members only) ───
    # Controls the type of fire protection coating applied to steel members.
    # Ignored for concrete elements (fire resistance is intrinsic via cover/thickness).
    # Override per-member via SteelBeamOptions/SteelColumnOptions fire_protection.
    fire_protection::StructuralSizer.FireProtection = StructuralSizer.SFRM()
    
    # ─── Member Sizing Options ───
    columns::Union{StructuralSizer.ColumnOptions, Nothing} = nothing
    beams::Union{StructuralSizer.BeamOptions, Nothing} = nothing
    
    # ─── Floor Specification ───
    # The type IS the floor system:
    #   DesignParameters(floor = FlatPlateOptions(method = EFM(solver=:asap)))
    #   DesignParameters(floor = VaultOptions(lambda = 8.0))
    floor::Union{StructuralSizer.AbstractFloorOptions, Nothing} = nothing
    
    # ─── Tributary Axis ───
    # Override tributary area partitioning (default: auto from floor type).
    # :isotropic → force straight skeleton; (x,y) tuple → directed partition.
    tributary_axis::Union{Nothing, Symbol, NTuple{2, Float64}} = nothing
    
    # ─── Foundation Options ───
    foundation_options::Union{FoundationParameters, Nothing} = nothing

    # ─── Face-scoped Floor Overrides ───
    # Optional geometry-scoped floor overrides (e.g., vault-only regions).
    # Coordinates are stored in meters as plain Float64 triplets.
    scoped_floor_overrides::Vector{ScopedFloorOverride} = ScopedFloorOverride[]
    
    # ─── Member Grouping ───
    # When true, detect collinear beams (sharing a node with aligned direction)
    # and assign them the same group_id before sizing. Forces the optimizer to
    # assign the same section to all members along a continuous line.
    # NOTE: This is orthogonal to `uniform_column_sizing` — collinear_grouping
    # operates on beam-line continuity in plan, not column uniformity per story.
    collinear_grouping::Bool = false
    
    # ─── Uniform Column Sizing ───
    # :off      — each column sized independently (default). Minimises material
    #             and embodied carbon by right-sizing each column to its own demand.
    # :per_story — all columns on the same story get the governing (largest) size.
    #              Common for constructability / formwork reuse, but adds material
    #              to lightly-loaded columns.
    # :building  — every column in the structure gets the governing size. Simplest
    #              to construct but highest material use.
    # Harmonization is conservative: the largest required section in each group
    # is promoted to all siblings (safe because a bigger column only improves
    # axial/punching capacity vs what was already checked).
    # Not supported for PixelFrame columns (rejected at API validation).
    uniform_column_sizing::Symbol = :off
    
    # ─── Design Targets ───
    deflection_limit::Symbol = :L_360        # :L_240, :L_360, :L_480
    optimize_for::Symbol = :weight           # :weight, :carbon, :cost
    
    # ─── Load Combinations (factored) ───
    load_combinations::Vector{LoadCombination} = [default_combo]
    
    # ─── Pattern Loading (ACI 318-11 §13.7.6) ───
    pattern_loading::Symbol = :none
    
    # Diaphragm modeling for lateral analysis
    diaphragm_mode::Symbol = :none
    diaphragm_E::Union{typeof(1.0u"Pa"), Nothing} = nothing
    diaphragm_ν::Float64 = 0.2
    
    # Default frame element properties (before member sizing).
    # Use precomputed SI constants to avoid runtime Unitful conversion of ksi → Pa,
    # which can fail if Asap custom-unit basefactors are not yet registered.
    default_frame_E::typeof(1.0u"Pa") = _DEFAULT_FRAME_E
    default_frame_G::typeof(1.0u"Pa") = _DEFAULT_FRAME_G
    default_frame_ρ::typeof(1.0u"kg/m^3") = _DEFAULT_FRAME_ρ
    
    # ─── ACI Cracking Factors ───
    column_I_factor::Float64 = 0.70
    beam_I_factor::Float64 = 0.35
    
    # ─── Iteration Control ───
    max_iterations::Int = 20
    
    # ─── Geometry Interpretation ───
    # When false (default), input vertex coordinates are architectural reference
    # points (panel corners / facade line).  Edge and corner columns are offset
    # inward by half the column dimension to their structural centerlines.
    # When true, vertices are already structural centerlines — no offset is applied.
    geometry_is_centerline::Bool = false
    
    # ─── Display Preferences ───
    display_units::DisplayUnits = imperial

    # ─── Visualization ───
    # Target edge length for the visualization shell mesh (meters, plain Float64).
    # nothing → inherit from FEA target_edge or use adaptive default.
    visualization_target_edge_m::Union{Float64, Nothing} = nothing
    # When true, skip shell mesh build and visualization serialization entirely.
    skip_visualization::Bool = false
    # "minimal" → frame + slab boundaries only; "full" → deflected meshes, analytical.
    visualization_detail::String = "full"
end

# =============================================================================
# Material Resolution (convenience accessors from DesignParameters)
# =============================================================================

"""Resolve slab concrete from design parameters."""
resolve_concrete(params::DesignParameters, override=nothing) =
    something(override, resolve_slab_concrete(params.materials))

"""Resolve slab rebar from design parameters."""
resolve_rebar(params::DesignParameters, override=nothing) =
    something(override, resolve_slab_rebar(params.materials))

"""Resolve slab RC material from design parameters."""
function resolve_rc_material(params::DesignParameters, override=nothing)
    !isnothing(override) && return override
    resolve_slab_rc(params.materials)
end

"""
    resolve_floor_options(params::DesignParameters) -> AbstractFloorOptions

Resolve the effective floor options from `params`.  Returns a typed
`AbstractFloorOptions`.  Applies the
material cascade from `params.materials` into the floor options.
"""
function resolve_floor_options(params::DesignParameters)
    floor = something(params.floor, StructuralSizer.FlatPlateOptions())
    check_material_compatibility(params.materials, floor)
    return _apply_material_cascade(params.materials, floor)
end

# --- Material cascade into floor options (using Accessors @set) ---

"""Cascade user-specified materials into `FlatPlateOptions`."""
function _apply_material_cascade(mat::MaterialOptions, opts::StructuralSizer.FlatPlateOptions)
    _has_material(mat) || return opts
    @set opts.material = resolve_slab_rc(mat)
end

"""Cascade user-specified materials into `FlatSlabOptions` (delegates to the base options)."""
function _apply_material_cascade(mat::MaterialOptions, opts::StructuralSizer.FlatSlabOptions)
    _has_material(mat) || return opts
    new_base = _apply_material_cascade(mat, opts.base)
    @set opts.base = new_base
end

"""Cascade user-specified materials into `OneWayOptions`."""
function _apply_material_cascade(mat::MaterialOptions, opts::StructuralSizer.OneWayOptions)
    _has_material(mat) || return opts
    @set opts.material = resolve_slab_rc(mat)
end

"""Cascade user-specified materials into `VaultOptions`."""
function _apply_material_cascade(mat::MaterialOptions, opts::StructuralSizer.VaultOptions)
    _has_material(mat) || return opts
    @set opts.material = resolve_slab_concrete(mat)
end

# Fallback: no material fields to cascade into
"""Fallback: no material fields to cascade into; return options unchanged."""
_apply_material_cascade(::MaterialOptions, opts::StructuralSizer.AbstractFloorOptions) = opts

"""True if any material is set on `mat`."""
_has_material(m::MaterialOptions) =
    !isnothing(m.slab) || !isnothing(m.column) || !isnothing(m.concrete) || !isnothing(m.rebar)

# =============================================================================
# `with` helper (Accessors-based, replaces _with)
# =============================================================================

"""
    with(params::DesignParameters; kwargs...) -> DesignParameters

Create a modified copy of `DesignParameters`.

# Example
```julia
base = DesignParameters(materials = MaterialOptions(concrete = NWC_5000))
v1 = with(base; floor = FlatPlateOptions(method = EFM(solver=:asap)))
v2 = with(base; floor = FlatSlabOptions(), loads = GravityLoads(floor_LL = 80.0psf))
```
"""
with(params::DesignParameters; kwargs...) = setproperties(params, (; kwargs...))

"""Primary (governing) strength combination from a DesignParameters."""
governing_combo(p::DesignParameters) = first(p.load_combinations)

"""
    resolve_objective(sym::Symbol) -> AbstractObjective

Map a DesignParameters `optimize_for` symbol to its StructuralSizer objective type.
"""
function resolve_objective(sym::Symbol)
    sym === :weight && return StructuralSizer.MinWeight()
    sym === :carbon && return StructuralSizer.MinCarbon()
    sym === :cost   && return StructuralSizer.MinCost(1.0)
    sym === :volume && return StructuralSizer.MinVolume()
    return StructuralSizer.MinWeight()
end

# ─── Fire rating validation ───
const VALID_FIRE_RATINGS = (0.0, 1.0, 1.5, 2.0, 3.0, 4.0)

"""
    validate_fire_rating(rating::Real) -> Float64

Validate fire resistance rating. Must be one of: 0, 1, 1.5, 2, 3, 4 hours.
Throws `ArgumentError` for invalid values.
"""
function validate_fire_rating(rating::Real)
    r = Float64(rating)
    r in VALID_FIRE_RATINGS && return r
    throw(ArgumentError(
        "Invalid fire_rating = $r. Must be one of $(VALID_FIRE_RATINGS) hours."
    ))
end

"""True if the design requires fire protection (fire_rating > 0)."""
has_fire_rating(p::DesignParameters) = p.fire_rating > 0.0

# =============================================================================
# Design Results
# =============================================================================

"""
Strip reinforcement design at a moment location.
All values stored in coherent SI (m, m², kN·m).
"""
struct StripReinforcementDesign
    Mu::typeof(1.0u"kN*m")           # Factored moment
    As_required::typeof(1.0u"m^2")   # Required steel area
    As_minimum::typeof(1.0u"m^2")    # Minimum steel area
    As_provided::typeof(1.0u"m^2")   # Provided steel area
    bar_size::String                  # e.g., "#5", "16M"
    spacing::typeof(1.0u"m")          # Bar spacing
    n_bars::Int                       # Number of bars
end

"""
Design result for a slab panel.
All values stored in coherent SI (m, kPa, kN·m).
"""
Base.@kwdef mutable struct SlabDesignResult
    # ── Convergence & iteration tracking ──────────────────────────────
    converged::Bool = true
    failure_reason::String = ""               # e.g. "non_convergence"
    failing_check::String = ""                # last check that failed
    iterations::Int = 0                       # design iterations used
    pattern_loading::Bool = false             # ACI 13.7.6 pattern loading applied
    
    # Sizing
    thickness::typeof(1.0u"m")
    self_weight::typeof(1.0u"kPa")
    
    # Analysis
    M0::Union{typeof(1.0u"kN*m"), Nothing} = nothing  # Total static moment
    qu::Union{typeof(1.0u"kPa"), Nothing} = nothing    # Factored uniform load
    
    # Reinforcement (by location)
    column_strip::Dict{Symbol, StripReinforcementDesign} = Dict()  # :ext_neg, :pos, :int_neg
    middle_strip::Dict{Symbol, StripReinforcementDesign} = Dict()
    
    # Checks
    deflection_ok::Bool = true
    deflection_ratio::Float64 = 0.0           # actual / limit
    deflection_in::Float64 = 0.0              # actual deflection (inches)
    deflection_limit_in::Float64 = 0.0        # allowable deflection (inches)
    
    # Punching shear summary
    punching_max_ratio::Float64 = 0.0
    punching_ok::Bool = true
    punching_vu_max_psi::Float64 = 0.0        # max demand (psi)
    
    # Shear stud details
    has_studs::Bool = false
    n_stud_cols::Int = 0
    stud_rails_max::Int = 0
    stud_per_rail_max::Int = 0
    
    # Integrity & transfer (ACI 8.7.4.2 / 8.4.2.3)
    integrity_ok::Bool = true
    n_transfer_bars_additional::Int = 0
    
    # Column P-M reinforcement ratio (max ρg from slab-design column check)
    col_rho_max::Float64 = 0.0
    
    # Compression rebar ratio for long-term deflection
    ρ_prime::Float64 = 0.0
    
    # Drop panel geometry (flat slab only)
    h_drop_in::Float64 = 0.0
    a_drop1_ft::Float64 = 0.0
    a_drop2_ft::Float64 = 0.0

    # Captured from slab.drop_panel before restore! (survives snapshot round-trip)
    drop_panel::Union{Nothing, StructuralSizer.DropPanelGeometry} = nothing

    # Floor result type flags (survive restore! — slab.result gets reverted to initial estimate)
    is_vault::Bool = false
    vault_rise::Union{Nothing, typeof(1.0u"m")} = nothing

    # Full StructuralSizer result captured before restore! wipes slab.result.
    # Used by engineering_report and any downstream that needs the rich sizing detail.
    sizer_result::Union{Nothing, StructuralSizer.AbstractFloorResult} = nothing
end

"""
    slab_diagnostic_governing_check(sr::SlabDesignResult) -> String

Canonical limit-state key for `/diagnose` and design summaries. When the slab passes API-style
`ok` (`converged && deflection_ok && punching_ok`), returns whichever of deflection vs slab
punching has the higher ratio. When it fails, prefers the sizer's `failing_check` and
`failure_reason` (e.g. Whitney / rebar inadequacy reports `section_inadequate` and
`reinforcement_design`) so diagnostics are not mislabeled as deflection or punching alone.
"""
function slab_diagnostic_governing_check(sr::SlabDesignResult)::String
    if sr.converged && sr.deflection_ok && sr.punching_ok
        return sr.deflection_ratio >= sr.punching_max_ratio ? "deflection" : "punching_shear_slab"
    end
    fc = strip(sr.failing_check)
    if !isempty(fc)
        fc == "reinforcement_design" && return "reinforcement_design"
        fc == "reinforcement_design_secondary" && return "reinforcement_design_secondary"
        fc == "transfer_reinforcement" && return "transfer_reinforcement"
        occursin("punching", fc) && return "punching_shear_slab"
        occursin("deflection", fc) && return "deflection"
    end
    fr = strip(sr.failure_reason)
    if fr == "section_inadequate"
        return "reinforcement_design"
    end
    if !sr.converged
        return "non_convergence"
    end
    if !sr.punching_ok
        return "punching_shear_slab"
    end
    if !sr.deflection_ok
        return "deflection"
    end
    return sr.deflection_ratio >= sr.punching_max_ratio ? "deflection" : "punching_shear_slab"
end

"""
Punching shear check result for a column.
All values stored in coherent SI (kN, kN·m, m, m²).

`Mub` is the slab-column unbalanced moment from the moment analysis (DDM/EFM/FEA),
**not** the column frame bending demand `Mu_x`. Micro-experiments must use this
value for `check_punching_for_column` so results match the full design.
"""
Base.@kwdef mutable struct PunchingDesignResult
    Vu::typeof(1.0u"kN")             # Punching shear force demand
    φVc::typeof(1.0u"kN")            # Capacity (factored)
    ratio::Float64                    # vu_stress / φvc_stress
    ok::Bool                          # ratio ≤ 1.0
    critical_perimeter::typeof(1.0u"m")
    tributary_area::typeof(1.0u"m^2")
    Mub::typeof(1.0u"kN*m") = 0.0u"kN*m"  # Slab-column unbalanced moment (ACI 318-19 §8.4.4.2)
end

"""
Design result for a column.
"""
Base.@kwdef mutable struct ColumnDesignResult
    # Sizing
    section_size::String = ""         # e.g., "W14x90", "16x16"
    section_obj::Union{StructuralSizer.AbstractSection, Nothing} = nothing

    # Column geometry (populated from Column.c1, .c2, .shape)
    c1::typeof(1.0u"m") = 0.0u"m"
    c2::typeof(1.0u"m") = 0.0u"m"
    shape::Symbol = :rectangular      # :rectangular or :circular
    
    # Member dimensions for material takeoff
    height::typeof(1.0u"m") = 0.0u"m"        # full column height
    Ag::typeof(1.0u"m^2") = 0.0u"m^2"        # gross section area
    As_total::typeof(1.0u"m^2") = 0.0u"m^2"  # total rebar area
    rho_g::Float64 = 0.0                       # reinforcement ratio
    
    # Demands
    Pu::typeof(1.0u"kN") = 0.0u"kN"
    Mu_x::typeof(1.0u"kN*m") = 0.0u"kN*m"
    Mu_y::typeof(1.0u"kN*m") = 0.0u"kN*m"
    
    # Capacity ratios
    axial_ratio::Float64 = 0.0
    interaction_ratio::Float64 = 0.0
    ok::Bool = true
    
    # Punching (if supporting flat slab)
    punching::Union{PunchingDesignResult, Nothing} = nothing
end

"""
Design result for a beam.
"""
Base.@kwdef mutable struct BeamDesignResult
    section_size::String = ""
    section_obj::Union{StructuralSizer.AbstractSection, Nothing} = nothing
    Mu::typeof(1.0u"kN*m") = 0.0u"kN*m"
    Vu::typeof(1.0u"kN") = 0.0u"kN"
    flexure_ratio::Float64 = 0.0
    shear_ratio::Float64 = 0.0
    ok::Bool = true
    # Material takeoff
    member_length::typeof(1.0u"m") = 0.0u"m"
    weight::typeof(1.0u"kg") = 0.0u"kg"
end

"""
    column_diagnostic_governing_check(cr::ColumnDesignResult) -> String

When `cr.ok`, returns the limit state with the highest demand/capacity ratio. When the column
fails, returns the check that actually drives failure: ratios above 1.0, or punching with
`punching.ok == false`, rather than whichever ratio is largest among still-passing checks.
"""
function column_diagnostic_governing_check(cr::ColumnDesignResult)::String
    punch_r = isnothing(cr.punching) ? 0.0 : cr.punching.ratio
    if cr.ok
        if cr.axial_ratio >= cr.interaction_ratio && cr.axial_ratio >= punch_r
            return "axial_compression"
        elseif cr.interaction_ratio >= punch_r
            return "pm_interaction"
        else
            return "punching_shear_col"
        end
    end
    candidates = Tuple{String, Float64}[]
    if cr.axial_ratio > 1.0
        push!(candidates, ("axial_compression", cr.axial_ratio))
    end
    if cr.interaction_ratio > 1.0
        push!(candidates, ("pm_interaction", cr.interaction_ratio))
    end
    if !isnothing(cr.punching) && (!cr.punching.ok || punch_r > 1.0)
        push!(candidates, ("punching_shear_col", punch_r))
    end
    if !isempty(candidates)
        _, j = findmax([c[2] for c in candidates])
        return candidates[j][1]
    end
    if cr.axial_ratio >= cr.interaction_ratio && cr.axial_ratio >= punch_r
        return "axial_compression"
    elseif cr.interaction_ratio >= punch_r
        return "pm_interaction"
    else
        return "punching_shear_col"
    end
end

"""
    beam_diagnostic_governing_check(br::BeamDesignResult) -> String

When `br.ok`, flexure vs shear by larger ratio. When `br.ok` is false, attributes failure to
checks with demand/capacity above 1.0 (worst among them), not merely the larger of two passing ratios.
"""
function beam_diagnostic_governing_check(br::BeamDesignResult)::String
    if br.ok
        return br.flexure_ratio >= br.shear_ratio ? "flexure" : "shear"
    end
    candidates = Tuple{String, Float64}[]
    if br.flexure_ratio > 1.0
        push!(candidates, ("flexure", br.flexure_ratio))
    end
    if br.shear_ratio > 1.0
        push!(candidates, ("shear", br.shear_ratio))
    end
    if !isempty(candidates)
        _, j = findmax([c[2] for c in candidates])
        return candidates[j][1]
    end
    return br.flexure_ratio >= br.shear_ratio ? "flexure" : "shear"
end

"""
Design result for a foundation.
"""
Base.@kwdef mutable struct FoundationDesignResult
    # Geometry
    length::typeof(1.0u"m") = 0.0u"m"
    width::typeof(1.0u"m") = 0.0u"m"
    depth::typeof(1.0u"m") = 0.0u"m"
    
    # Demands
    reaction::typeof(1.0u"kN") = 0.0u"kN"
    
    # Checks
    bearing_ratio::Float64 = 0.0      # actual / allowable bearing pressure
    punching_ratio::Float64 = 0.0     # punching shear check
    flexure_ratio::Float64 = 0.0      # flexure check
    ok::Bool = true
    
    # Material quantities (propagated from Sizer-level result)
    concrete_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    steel_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    
    # Group assignment
    group_id::Int = 0
end

"""
    foundation_diagnostic_governing_check(fr::FoundationDesignResult) -> String

When `fr.ok`, highest utilization among bearing, punching, and flexure. When the footing fails,
picks the limit state(s) over capacity (ratio > 1) with the worst ratio, not the largest ratio
among checks that still pass.
"""
function foundation_diagnostic_governing_check(fr::FoundationDesignResult)::String
    rb = fr.bearing_ratio
    rp = fr.punching_ratio
    rf = fr.flexure_ratio
    if fr.ok
        if rb >= rp && rb >= rf
            return "bearing"
        elseif rp >= rf
            return "punching_shear_fdn"
        else
            return "flexure_fdn"
        end
    end
    candidates = Tuple{String, Float64}[]
    rb > 1.0 && push!(candidates, ("bearing", rb))
    rp > 1.0 && push!(candidates, ("punching_shear_fdn", rp))
    rf > 1.0 && push!(candidates, ("flexure_fdn", rf))
    if !isempty(candidates)
        _, j = findmax([c[2] for c in candidates])
        return candidates[j][1]
    end
    if rb >= rp && rb >= rf
        return "bearing"
    elseif rp >= rf
        return "punching_shear_fdn"
    else
        return "flexure_fdn"
    end
end

"""
Design summary with aggregate metrics.
"""
Base.@kwdef mutable struct DesignSummary
    # Volumes/weights
    concrete_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    steel_weight::typeof(1.0u"kg") = 0.0u"kg"
    rebar_weight::typeof(1.0u"kg") = 0.0u"kg"
    timber_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    
    # Derived metrics
    embodied_carbon::Float64 = 0.0    # kgCO₂e
    # Populated with `embodied_carbon` in `_compute_design_summary!` (same `compute_building_ec` call).
    embodied_carbon_slabs::Float64 = 0.0
    embodied_carbon_columns::Float64 = 0.0
    embodied_carbon_beams::Float64 = 0.0
    embodied_carbon_struts::Float64 = 0.0
    embodied_carbon_foundations::Float64 = 0.0
    embodied_carbon_fireproofing::Float64 = 0.0
    cost_estimate::Float64 = 0.0      # $
    
    # Status
    all_checks_pass::Bool = true
    # When any element fails API-style `ok`, this names the worst failing element and its governing ratio.
    # When all pass, this is the highest utilization anywhere (demand/limit style ratios).
    critical_element::String = ""
    critical_ratio::Float64 = 0.0
end

"""
A complete design solution for a BuildingStructure.

Holds a reference to the source `BuildingStructure` for geometry access,
enabling a clean API: `visualize(design)` works without passing structure separately.

Multiple BuildingDesign instances can reference the same BuildingStructure,
enabling comparison of different material choices or optimization targets.

# Example
```julia
building = BuildingStructure(skeleton)
# ... initialize cells, members ...

design1 = BuildingDesign(building, DesignParameters(
    name = "Concrete 4ksi",
    materials = MaterialOptions(concrete = NWC_4000),
))

design2 = BuildingDesign(building, DesignParameters(
    name = "Concrete 6ksi",
    materials = MaterialOptions(concrete = NWC_6000),
))

visualize(design1)  # Self-contained: accesses geometry via design.structure
compare_designs(design1, design2)
```
"""
mutable struct BuildingDesign{T, A, P}
    # Reference to source building (pointer, not copy)
    structure::BuildingStructure{T, A, P}
    
    # Design configuration
    params::DesignParameters
    
    # Design results (keyed by member index)
    slabs::Dict{Int, SlabDesignResult}
    columns::Dict{Int, ColumnDesignResult}
    beams::Dict{Int, BeamDesignResult}
    foundations::Dict{Int, FoundationDesignResult}
    
    # Summary
    summary::DesignSummary
    
    # ─── Analysis Model ───
    # Frame+shell model for global deflection analysis (built after design)
    # Separate from struc.asap_model to preserve the design-phase frame model
    asap_model::Union{Asap.Model, Nothing}
    # Skeleton edge index for each frame element in asap_model (when built via build_analysis_model!).
    # Enables correct element→design mapping for visualization; empty when using struc.asap_model.
    asap_model_frame_edge_indices::Vector{Int}
    
    # Structural offsets captured at design time (vertex_idx → (dx_m, dy_m)).
    # Persists edge/corner column offsets so serialization can reconstruct
    # centerline positions after restore! wipes them from the structure.
    structural_offsets::Dict{Int, NTuple{2, Float64}}
    
    # Wall-clock time for each design phase (prepare, pipeline, capture, etc.)
    phase_timings::Dict{String, Float64}

    # Solver decision trace (populated when TraceCollector is passed to design_building)
    solver_trace::Vector{StructuralSizer.TraceEvent}
    
    # Metadata
    created::DateTime
    compute_time_s::Float64
end

"""
    BuildingDesign(struc, params=DesignParameters()) -> BuildingDesign

Construct an empty `BuildingDesign` with empty result dictionaries and a fresh timestamp.
"""
function BuildingDesign(struc::BuildingStructure{T, A, P}, params::DesignParameters=DesignParameters()) where {T, A, P}
    BuildingDesign{T, A, P}(
        struc,
        params,
        Dict{Int, SlabDesignResult}(),
        Dict{Int, ColumnDesignResult}(),
        Dict{Int, BeamDesignResult}(),
        Dict{Int, FoundationDesignResult}(),
        DesignSummary(),
        nothing,  # asap_model (built via build_analysis_model!)
        Int[],    # asap_model_frame_edge_indices (populated by build_analysis_model!)
        Dict{Int, NTuple{2, Float64}}(),  # structural_offsets (captured by capture_design)
        Dict{String, Float64}(),          # phase_timings (populated by design_building)
        StructuralSizer.TraceEvent[],     # solver_trace (populated when tc is passed)
        now(),
        0.0
    )
end

# =============================================================================
# BuildingDesign Accessors
# =============================================================================

"""Get the source BuildingStructure."""
structure(d::BuildingDesign) = d.structure

"""Get the source BuildingSkeleton (shorthand for d.structure.skeleton)."""
skeleton(d::BuildingDesign) = d.structure.skeleton

"""Get slab design result by index."""
slab_design(d::BuildingDesign, idx::Int) = get(d.slabs, idx, nothing)

"""Get column design result by index."""
column_design(d::BuildingDesign, idx::Int) = get(d.columns, idx, nothing)

"""Get beam design result by index."""
beam_design(d::BuildingDesign, idx::Int) = get(d.beams, idx, nothing)

"""Get foundation design result by index."""
foundation_design(d::BuildingDesign, idx::Int) = get(d.foundations, idx, nothing)

"""Check if all design checks pass."""
all_ok(d::BuildingDesign) = d.summary.all_checks_pass

"""Get the governing (critical) design ratio."""
critical_ratio(d::BuildingDesign) = d.summary.critical_ratio

"""Check if the analysis model (frame+shell) has been built."""
has_analysis_model(d::BuildingDesign) = !isnothing(d.asap_model)
