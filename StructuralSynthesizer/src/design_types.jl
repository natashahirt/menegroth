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
    MemberGroupSizingOverride(; catalog=nothing, deflection_limit=nothing, max_depth=nothing)

Per-member-group sizing override carried on `DesignParameters.member_group_overrides`
(keyed by the group's stable `UInt64` `group_id`). Each field is `nothing` by
default, meaning "fall through to the next resolution level" — so an override with
all fields unset is a no-op.

These are ENGINEERING sizing KNOBS (not published-code factors): a per-group section
`catalog`, an L/δ `deflection_limit` (e.g. `1/360`), and a `max_depth` cap. They are
honored on the per-group [`size_member_group!`](@ref) path AND (Phase B) on the
batched steel-beam stage ([`size_beams!`](@ref) → `_size_beams_impl!` →
`_beam_override_union_and_feasible`) used by `design_building`.

Per-knob precedence DIFFERS by path ([A-revert]):

- `size_member_group!` (highest first): this override's field
  (`member_group_overrides[gid]`) > `MemberGroup.catalog_override` (for `catalog`) >
  the caller's global default kwarg.
- batched `size_beams!` (Phase B): this override's field > the caller's global
  default kwarg. `MemberGroup.catalog_override` is a documented NO-OP on the batched
  `design_building` / incremental path — it is honored ONLY by `size_member_group!`.

Field types are validated at construction: `deflection_limit` must be a
dimensionless `Real` L/δ ratio and `max_depth` a Unitful length, else the
constructor throws a `member_group_overrides` `ArgumentError` (so an ill-typed /
unit-mismatched value fails loud at the API boundary rather than surfacing as a
Unitful `DimensionError` deep inside the batched sizing mask).

!!! note "Scope (Run 4 / Phase B)"
    Only the fields a per-group sizer can honor are represented: `catalog`,
    `deflection_limit`, `max_depth`. Objective / total-deflection overrides have no
    per-group honoring path and are deliberately omitted rather than carried as
    silently-ignored knobs. Phase B threads these overrides into the batched STEEL
    beam stage as a per-group *narrowing* mask (see
    `_beam_override_union_and_feasible`): each knob can only tighten a group's
    candidate set relative to the global default. Effective overrides on
    column/strut groups, on flat-plate/flat-slab floors, on non-steel-beam sizing,
    or combined with `n_max_sections > 0` are still refused fail-loud by
    [`_assert_member_group_overrides_unsupported`](@ref).
"""
struct MemberGroupSizingOverride
    catalog::Any                                 # per-group section catalog, or nothing
    deflection_limit::Union{Nothing, Real}       # L/δ ratio (e.g. 1/360), or nothing
    max_depth::Union{Nothing, Unitful.Length}    # max section depth cap, or nothing

    # [P2-4] Validating constructor: reject an ill-typed / unit-mismatched knob with
    # a `member_group_overrides` ArgumentError at the API boundary, rather than
    # letting a bare-number `max_depth` (or a dimensioned `deflection_limit`) surface
    # as a Unitful DimensionError deep in the batched mask (`ovr.max_depth >
    # global_depth`, `section_depth(s) <= resolved_depth`). `catalog` is untouched.
    function MemberGroupSizingOverride(catalog, deflection_limit, max_depth)
        (deflection_limit === nothing || deflection_limit isa Real) ||
            throw(ArgumentError("member_group_overrides: deflection_limit must be a " *
                "dimensionless Real L/δ ratio (e.g. 1/360), got a " *
                "$(typeof(deflection_limit))"))
        (max_depth === nothing || max_depth isa Unitful.Length) ||
            throw(ArgumentError("member_group_overrides: max_depth must be a Unitful " *
                "length (e.g. 18.0u\"inch\"), got a $(typeof(max_depth))"))
        return new(catalog, deflection_limit, max_depth)
    end
end
MemberGroupSizingOverride(; catalog=nothing, deflection_limit=nothing, max_depth=nothing) =
    MemberGroupSizingOverride(catalog, deflection_limit, max_depth)

"""
    _is_effective(o::MemberGroupSizingOverride) -> Bool

Whether `o` sets ANY sizing knob (`catalog`, `deflection_limit`, or `max_depth`).
An override with all fields `nothing` is a documented no-op (see the
`MemberGroupSizingOverride` docstring), so `_is_effective` is `false` for it. Used
by the fail-loud member-group-override guard to refuse ONLY overrides that would
actually change a design (an all-unset entry must not throw — guard/docstring
consistency).
"""
_is_effective(o::MemberGroupSizingOverride) =
    o.catalog !== nothing || o.deflection_limit !== nothing || o.max_depth !== nothing

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

    # ─── Per-Member-Group Sizing Overrides (Run 4 / Phase B) ───
    # Optional per-group sizing knobs keyed by the group's stable UInt64 group_id.
    # DEFAULTS to empty ⇒ byte-identical to today for every existing caller.
    #
    # Phase B: `member_group_overrides` is a LIVE `:members` node-slice input. It is
    # honored for ELIGIBLE STEEL BEAM groups by the BATCHED `design_building` /
    # incremental member stage (`_size_beams_columns!` → batched `size_beams!` →
    # `_size_beams_impl!` → `_beam_override_union_and_feasible`), threaded as a
    # per-group feasible-narrowing mask, AND on the isolated per-group
    # `size_member_group!` path. Because it feeds the `:members` param slice, a
    # change DIRTIES the member frontier — but it is NOT prepare-affecting (it never
    # alters the prepared model), so the incremental engine is reused, not rebuilt.
    #
    # `MemberGroup.catalog_override` (the Phase 6 seam) is honored ONLY by the
    # `size_member_group!` path, NOT by the batched path ([A-revert]). Un-honorable
    # effective targets (column/strut groups, flat-plate/flat-slab floors, non-steel
    # beam sizing, `n_max_sections > 0`, or a LOOSER-than-global knob) are refused
    # fail-loud by [`_assert_member_group_overrides_unsupported`](@ref). See
    # `MemberGroupSizingOverride`.
    member_group_overrides::Dict{UInt64, MemberGroupSizingOverride} =
        Dict{UInt64, MemberGroupSizingOverride}()

    # ─── Framing Auto-Generation (Phase 5, plan `joists-roles-materials`) ───
    # Options driving `populate_levels!`, which auto-generates the framing
    # hierarchy (girders, secondary beams, joists) above each slab during
    # `prepare!` (the `:populate_framing` prepare sub-step, before `to_asap!`).
    #
    # An empty NamedTuple (the default) is a STRICT no-op — flat-plate /
    # flat-slab / beam-supported flows are byte-identical unless a caller opts
    # in. Recognized keys (all optional): `:materials` (NamedTuple of member
    # materials by key `:steel`/`:timber`/`:concrete`/`:beam`), `:spacing`
    # (center-to-center joist spacing), and `:level_N` (NamedTuple schema for
    # framing level N ≥ 2). See `populate_levels!` for the full contract.
    #
    # `prepare!`/`design_building` honor this field when no explicit
    # `framing_opts` kwarg is supplied, so the REST API (`json_to_params`) can
    # drive framing auto-generation through a single design call.
    #
    # NOTE (incremental engine): this field is PREPARE-affecting and IS listed in
    # `PREPARE_AFFECTING_FIELDS` (scheduler.jl). Because `populate_levels!` mutates
    # the skeleton (appends joist edges, subdivides host edges), the stateful
    # `IncrementalEngine` cannot safely re-`prepare!` a reused baseline to change
    # framing — so `run_target!` rejects a `framing_opts` change on a reused engine
    # and a fresh `prepare_engine` (which prepares on an independent copy) is
    # required. The per-call `design_building` path (used by the REST API) re-runs
    # `prepare!` from a pristine structure every call and is unaffected.
    framing_opts::NamedTuple = NamedTuple()

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

"""
    _mgo_refusal_message(reason::AbstractString) -> String

Compose the fail-loud refusal message for an un-honorable `member_group_overrides`
target. The substring `'member_group_overrides'` is always present so callers /
tests can message-pin on it.
"""
_mgo_refusal_message(reason::AbstractString) =
    "member_group_overrides cannot be honored here: " * reason * ". " *
    "Refusing rather than silently ignoring the per-group override — a dropped " *
    "catalog / deflection / depth restriction is a silent safety hazard. Phase B " *
    "honors EFFECTIVE overrides only for STEEL BEAM member groups on beam/column " *
    "floors sized via the batched size_beams! path with n_max_sections == 0 and a " *
    "single material."

# ─── [P1-2] redirect: per-gid beam/column classification REMOVED ─────────────
# The former `_honorable_member_gids` / `_member_group_kinds` / `_member_group_kind`
# helpers reproduced the sizer's collinear + par_has grouping at the PRE-SIZING door
# so the guard could classify each override target as :beams / :columns / :struts.
# That reproduction is UNRELIABLE: collinear grouping runs at SIZE time on the
# analysis structure (`group_collinear_members!` inside `size_beams!` / `size_columns!`,
# utils.jl), NOT in `prepare!`, so a door-side reproduction disagreed with the real
# size-time gids (e.g. 12 groups at the door vs 24 at size time) and false-refused
# honorable collinear beam overrides ([P1-2]). The DEFINITIVE per-gid honor/refuse
# decision now lives at the size-time choke point inside `_size_beams_impl!`
# (utils.jl), where the REAL par_has-filtered, collinear-merged beam `group_ids` are
# in scope: a column / strut / unknown / par_has-absent gid is refused fail-loud there
# ([P2-3]) BEFORE any BuildingDesign is produced. The door below refuses only what is
# decidable WITHOUT per-gid classification (floor type / non-steel / coupling /
# material, plus the looseness check).

"""
    _assert_member_group_overrides_unsupported(params::DesignParameters)
    _assert_member_group_overrides_unsupported(params::DesignParameters, struc::BuildingStructure)

Fail-loud guard (Run 4). Phase B makes `member_group_overrides` LIVE for the
HONORABLE case — an EFFECTIVE override targeting a STEEL BEAM member group on a
beam/column floor, sized via the batched `size_beams!` → `optimize_discrete` path
with `n_max_sections == 0` and a single material (see `_size_beams_impl!`). Such
overrides are threaded into that group's feasible set and DO change its result.

This guard refuses only the UN-HONORABLE effective targets that no threaded path
can honor and that would therefore be SILENTLY IGNORED:

  1. the floor system is flat-plate / flat-slab (members are sized via
     `size_flat_plate!` / `_reconcile_columns!`, never per beam group);
  2. beam sizing is NOT steel (`params.beams` is a concrete / PixelFrame / T-beam
     option) — those `_size_beams_impl!` variants are not threaded this increment;
  3. `n_max_sections > 0` on the steel beam options — that couples groups, so
     per-group narrowing is no longer exact-first-safe;
  4. the steel beam options carry a multi-material catalog (`opts.materials`) —
     per-group narrowing over the expanded catalog is out of scope this increment;
  4b. the steel beam options set `sizing_strategy != :discrete` (e.g. `:nlp`) — the
     honor-or-throw gid gate lives only in the steel-`Val{:discrete}`
     `_size_beams_impl!`, so a non-:discrete strategy has no honoring path;
  5. the override's resolved `deflection_limit` is LOOSER (numerically larger L/δ
     ratio) than the global, or its `max_depth` EXCEEDS the global `max_depth` —
     such a loosening is a silent no-op in the batched path (the global AISCChecker
     screening always intersects the per-group mask, so a per-group knob can only
     tighten), and is refused fail-loud. Tightening stays honored via the mask.

Checks 1–4b are decidable from `params` alone and run in BOTH overloads. Check 5
(looseness) compares the override knobs to the global steel-beam knobs — it needs no
per-gid geometry, so it also runs in the `struc`-aware overload (called from the
`BuildingDesign(struc, params)` constructor, `capture_design`,
`run_pre_sizing_validation`, and the incremental variation doors).

NOTE ([P1-2] redirect): this guard NO LONGER classifies each target as
:beams / :columns / :struts. Reproducing the sizer's collinear + par_has grouping
BEFORE sizing is UNRELIABLE — collinear grouping runs at SIZE time on the analysis
structure (`group_collinear_members!` inside `size_beams!` / `size_columns!`), not in
`prepare!` — so a column / strut / unknown / par_has-absent gid is now refused
fail-loud at the DEFINITIVE size-time choke point inside `_size_beams_impl!`
(utils.jl), where the REAL beam `group_ids` are in scope, NOT here. An honorable
beam-floor override therefore PASSES this door and is honored (or definitively
refused) at size time. An override whose fields are ALL unset (`_is_effective ==
false`) is a documented no-op and never throws, so the happy path stays
byte-identical. (catalog / deflection_limit / max_depth are engineering sizing
knobs — no code citation.)
"""
function _assert_member_group_overrides_unsupported(params::DesignParameters)
    (isempty(params.member_group_overrides) ||
        !any(_is_effective, values(params.member_group_overrides))) && return nothing

    # (1) Floor system that never sizes beams per-group.
    floor_type = _infer_floor_type(resolve_floor_options(params))
    if floor_type in (:flat_plate, :flat_slab)
        throw(ArgumentError(_mgo_refusal_message(
            "the floor system is :$(floor_type), which sizes members via " *
            "size_flat_plate! / _reconcile_columns! and never sizes beam groups " *
            "per-group")))
    end

    beam_opts = params.beams
    if beam_opts !== nothing
        # (2) Non-steel beam sizing (concrete / PixelFrame / T-beam paths are not
        #     threaded in this increment).
        if !(beam_opts isa StructuralSizer.SteelBeamOptions)
            throw(ArgumentError(_mgo_refusal_message(
                "beam sizing uses $(typeof(beam_opts)); per-group overrides are only " *
                "threaded for steel beam groups (SteelBeamOptions) this increment")))
        end
        # (3) n_max_sections coupling hazard. Size-time mirror (for direct callers that
        #     bypass this front door) lives beside the multi-material mirror in
        #     `_size_beams_impl!(::SteelBeamOptions, ::Val{:discrete})` (analyze/members/utils.jl,
        #     cycle-9 coupling mirror); see the MIRROR-PARITY INVARIANT there.
        if beam_opts.n_max_sections > 0
            throw(ArgumentError(_mgo_refusal_message(
                "steel beam options set n_max_sections=$(beam_opts.n_max_sections) > 0, " *
                "which couples member groups so per-group feasible narrowing is not " *
                "exact-first-safe")))
        end
        # (4) Multi-material catalog.
        if beam_opts.materials !== nothing
            throw(ArgumentError(_mgo_refusal_message(
                "steel beam options set a multi-material catalog (opts.materials); " *
                "per-group narrowing over the expanded catalog is out of scope this " *
                "increment")))
        end
        # (4b) Non-discrete sizing strategy. The honor-or-throw size-time gid gate
        #      lives ONLY in the steel-`Val{:discrete}` `_size_beams_impl!`
        #      (utils.jl); there is no steel-`:nlp` overload. `SteelBeamOptions`
        #      exposes `sizing_strategy::Symbol` (StructuralSizer options.jl:106,
        #      default `:discrete`, may be `:nlp`). A `:nlp` steel beam option with an
        #      effective override would bypass the gid gate and dispatch to
        #      `_size_beams_impl!(..., ::SteelBeamOptions, ::Val{:nlp})` — a MethodError
        #      today, and a SILENT DROP the instant an accept-and-drop `:nlp` overload
        #      is added. Refuse fail-loud so only the steel-discrete batched path (the
        #      one that carries the honor-or-throw gate this increment) accepts an
        #      effective override. Runs in BOTH overloads (params-only), so it fires on
        #      design_building AND size! AND the direct / variation doors.
        if beam_opts.sizing_strategy != :discrete
            throw(ArgumentError(_mgo_refusal_message(
                "steel beam options set sizing_strategy=:$(beam_opts.sizing_strategy); " *
                "per-group overrides are honored only on the steel-discrete batched " *
                "size_beams! path (the honor-or-throw gate lives solely in the " *
                ":discrete _size_beams_impl!), so a non-:discrete strategy would bypass " *
                "it")))
        end
    end
    return nothing
end

function _assert_member_group_overrides_unsupported(params::DesignParameters,
                                                    struc::BuildingStructure)
    # Params-only refusals first (floor type / non-steel / coupling / material).
    _assert_member_group_overrides_unsupported(params)
    isempty(params.member_group_overrides) && return nothing
    # Global steel-beam knobs actually used by the batched size_beams! path
    # (`something(params.beams, SteelBeamOptions())` mirrors `_size_beams_columns!`).
    # By the time we get here the params-only guard has already refused any non-steel
    # beam options, so a non-nothing `params.beams` is a SteelBeamOptions.
    global_opts = params.beams isa StructuralSizer.SteelBeamOptions ?
        params.beams : StructuralSizer.SteelBeamOptions()
    global_defl  = global_opts.deflection_limit    # Union{Nothing, Float64}, L/δ ratio
    global_depth = global_opts.max_depth            # Length depth cap
    # NOTE ([P1-2] redirect): per-gid classification was REMOVED from this door — a
    # column / strut / unknown / par_has-absent target is refused fail-loud at the
    # size-time gate inside `_size_beams_impl!` (utils.jl), where the real collinear-
    # merged, par_has-filtered beam `group_ids` are in scope. This door still refuses a
    # LOOSER knob (a silent no-op hazard, decidable from params alone).
    for (gid, ovr) in params.member_group_overrides
        _is_effective(ovr) || continue
        # (5) LOOSER deflection_limit / max_depth is a SILENT NO-OP hazard. The
        # batched size_beams! path always intersects the per-group feasible mask with
        # the GLOBAL AISCChecker screening, so a per-group knob can only ever TIGHTEN
        # a group relative to the global default; a knob set LOOSER than the global is
        # clamped by the global screening and silently ignored. Refuse it fail-loud
        # rather than let a per-group loosening quietly have no effect. TIGHTENING
        # stays honored via the mask. `deflection_limit` is an L/δ RATIO, so LOOSER
        # means a numerically LARGER ratio; a `nothing` global limit is the loosest
        # possible, so any finite per-group ratio is a (honored) tightening.
        if ovr.deflection_limit !== nothing && global_defl !== nothing &&
                ovr.deflection_limit > global_defl
            throw(ArgumentError(_mgo_refusal_message(
                "override on beam group $(gid) sets deflection_limit=$(ovr.deflection_limit), " *
                "LOOSER than the global deflection_limit=$(global_defl) (larger L/δ ratio); " *
                "the batched size_beams! mask can only tighten, so a looser per-group limit " *
                "would be silently ignored")))
        end
        if ovr.max_depth !== nothing && ovr.max_depth > global_depth
            throw(ArgumentError(_mgo_refusal_message(
                "override on beam group $(gid) sets max_depth=$(ovr.max_depth), LOOSER than " *
                "the global max_depth=$(global_depth); the batched size_beams! mask can only " *
                "tighten, so a looser per-group cap would be silently ignored")))
        end
    end
    return nothing
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
    cascaded = _apply_material_cascade(params.materials, floor)
    # ACI 318-11 §10.10.4.1 — `params.column_I_factor` is the single source of truth
    # for flat-plate COLUMN cracked stiffness. Thread it into the floor options so the
    # FEA path (which reads `opts.col_I_factor`) uses the param rather than the field
    # default. At the default `column_I_factor = 0.70` this matches the field default
    # → byte-exact no-op.
    return _apply_col_I_factor(cascaded, params.column_I_factor)
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

# --- Column cracking factor into floor options (using Accessors @set) ---
# ACI 318-11 §10.10.4.1 — reduced (cracked) column moment of inertia (0.70·Ig).
# `params.column_I_factor` is the single source of truth; mirror the
# `_apply_material_cascade` multiple-dispatch pattern so option types that have no
# column cracking factor fall through unchanged (must not crash).

"""Warn when a floor-option column factor disagrees with the param, then return the param.

`params.column_I_factor` stays the value that runs. The warning records both
numbers and which one ran. Equal values stay silent (default 0.70 is a no-op).
"""
function _warn_col_I_conflict(options_value::Real, column_I_factor::Real, options_label::AbstractString)
    ran = Float64(column_I_factor)
    opts_val = Float64(options_value)
    if opts_val != ran
        @warn string(options_label, ".col_I_factor differs from params.column_I_factor; ",
                     "params.column_I_factor ran") options_col_I_factor=opts_val params_column_I_factor=ran
    end
    return ran
end

"""Set the FEA column cracking factor on `FlatPlateOptions` (ACI 318-11 §10.10.4.1)."""
function _apply_col_I_factor(opts::StructuralSizer.FlatPlateOptions, column_I_factor::Real)
    ran = _warn_col_I_conflict(opts.col_I_factor, column_I_factor, "FlatPlateOptions")
    @set opts.col_I_factor = ran  # ACI 318-11 §10.10.4.1
end

"""Set the FEA column cracking factor on `FlatSlabOptions` (delegates to the wrapped `base`)."""
function _apply_col_I_factor(opts::StructuralSizer.FlatSlabOptions, column_I_factor::Real)
    ran = _warn_col_I_conflict(opts.base.col_I_factor, column_I_factor, "FlatSlabOptions.base")
    @set opts.base.col_I_factor = ran  # ACI 318-11 §10.10.4.1
end

# Fallback: option types without a column cracking factor (OneWayOptions, VaultOptions, …)
"""Fallback: floor options with no column cracking factor; return options unchanged."""
_apply_col_I_factor(opts::StructuralSizer.AbstractFloorOptions, ::Real) = opts

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
    resolve_member_group_override(params::DesignParameters, gid::UInt64)
        -> Union{MemberGroupSizingOverride, Nothing}

The per-group sizing override for `gid` from `params.member_group_overrides`, or
`nothing` when the group has no override. Pass the result as the `override` kwarg
to [`size_member_group!`](@ref). Returns `nothing` (a no-op) for every group when
`member_group_overrides` is empty (the default), keeping all existing callers
byte-identical.
"""
resolve_member_group_override(params::DesignParameters, gid::UInt64) =
    get(params.member_group_overrides, gid, nothing)

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

    # USER DECISION: when the requested DDM or EFM is not permitted, the
    # design falls back to FEA and the caller must be able to see that.
    # Copied from the `size_flat_plate!` NamedTuple (`slab.design_details`)
    # by `_populate_slab_results!`.  `restore!` writes that NamedTuple back
    # onto the slab, so the same three fields survive a snapshot round-trip.
    # `method_fallback_reasons` is empty when the requested method was used.
    method_requested::Union{Nothing, StructuralSizer.FlatPlateAnalysisMethod} = nothing
    method_used::Union{Nothing, StructuralSizer.FlatPlateAnalysisMethod} = nothing
    method_fallback_reasons::Vector{String} = String[]
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

An UNVERIFIED column — one whose §E3/§E4 steel-buckling axial capacity could not be evaluated,
carrying the `NaN` axial/interaction sentinel set in `_populate_column_results!` — is detected
FIRST and labeled `"axial_compression_unverified"`. Without this guard every `NaN` comparison
below is `false`, so the function would fall through to the else and MISLABEL the column
`"punching_shear_col"`. The returned label matches the summary path in `_compute_design_summary!`
exactly, so `/diagnose` and the summary agree on the unverified state.
"""
function column_diagnostic_governing_check(cr::ColumnDesignResult)::String
    # UNVERIFIED sentinel takes priority over every ratio comparison: NaN ≥/≤ anything is
    # `false`, so a fall-through would silently mis-attribute the failure to punching.
    if isnan(cr.axial_ratio) || isnan(cr.interaction_ratio)
        return "axial_compression_unverified"
    end
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

    # Derived metrics. All `embodied_carbon_*` fields carry typed
    # `kgCO₂e` quantities (Asap `𝐗` dimension); serialize / report /
    # narrate / agent-tool paths strip via `ustrip(u"kgCO2e", …)` at the
    # JSON / Printf boundary. Populated by `_compute_design_summary!` from
    # the single `compute_building_ec` call so the per-element parts sum
    # exactly to `embodied_carbon`.
    embodied_carbon::CarbonMassQuantity              = 0.0u"kgCO2e"
    embodied_carbon_slabs::CarbonMassQuantity        = 0.0u"kgCO2e"
    embodied_carbon_columns::CarbonMassQuantity      = 0.0u"kgCO2e"
    embodied_carbon_beams::CarbonMassQuantity        = 0.0u"kgCO2e"
    embodied_carbon_struts::CarbonMassQuantity       = 0.0u"kgCO2e"
    embodied_carbon_foundations::CarbonMassQuantity  = 0.0u"kgCO2e"
    embodied_carbon_fireproofing::CarbonMassQuantity = 0.0u"kgCO2e"
    cost_estimate::Float64 = 0.0      # $

    # Status
    all_checks_pass::Bool = true
    # When any element fails API-style `ok`, this names the worst failing element and its governing ratio.
    # When all pass, this is the highest utilization anywhere (demand/limit style ratios).
    critical_element::String = ""
    critical_ratio::Float64 = 0.0
end

"""
    WallCheckRecord

Identity of one wall check. Later phases store one record per wall, story,
direction, and load combination. This is intentionally not a utilization,
capacity, or demand.

# Fields
- `story::Int`: 0-based story index, matching `Wall.story` (ground = 0).
  `WallLine.story` is 1-based and is not this field.
- `direction::Symbol`: plan direction, `:X` or `:Y`.
- `combination::Symbol`: load combination this record belongs to.
"""
struct WallCheckRecord
    story::Int          # 0-based, matching Wall.story
    direction::Symbol   # :X or :Y
    combination::Symbol
end

"""
A complete design solution for a BuildingStructure.

Holds a reference to the source `BuildingStructure` for geometry access,
enabling a clean API: `visualize(design)` works without passing structure separately.

Multiple BuildingDesign instances can reference the same BuildingStructure,
enabling comparison of different material choices or optimization targets.

`walls` is keyed by index into `structure.walls`. The dict exists so later
phases can store one [`WallCheckRecord`](@ref) per wall, story, direction, and
combination. It is intentionally not a single utilization.

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
    # Sidecar keyed by index into `structure.walls`. One record per
    # wall / story / direction / combination — not a single utilization.
    walls::Dict{Int, Vector{WallCheckRecord}}
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
    # Fail-loud guard (Run 4) — STRUCTURAL choke point. This constructor is the
    # single universal path through which every BuildingDesign is materialized
    # (design_building, redesign, vary, redesign_incremental!, and the primitive
    # build_design_graph -> execute_graph! -> capture_design and run_target! +
    # capture_incremental_design paths all route here). Phase B HONORS effective
    # steel-beam-group overrides; this struc-aware guard is the backstop that
    # refuses the un-honorable targets (flat-plate/flat-slab floors, non-steel or
    # coupled beam sizing, and column/strut groups — the last decidable only with
    # prepared members) so no materialization path silently drops one. Empty /
    # all-unset (vacuous) overrides pass unchanged (byte-identical happy path).
    # See _assert_member_group_overrides_unsupported.
    _assert_member_group_overrides_unsupported(params, struc)
    BuildingDesign{T, A, P}(
        struc,
        params,
        Dict{Int, SlabDesignResult}(),
        Dict{Int, ColumnDesignResult}(),
        Dict{Int, BeamDesignResult}(),
        Dict{Int, Vector{WallCheckRecord}}(),
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
