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
    MaterialOptions(; concrete, rebar, steel, timber, slab, column)

Material specifications for building design.  Set building-level defaults
that cascade to all members, or override per-member type. Beam material is
set on the beam sizing options (`DesignParameters.beams`), which also set the
beam end releases.

# Cascade Priority
1. Per-member override (`slab`, `column`) — highest
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

"""Building structural steel from the material cascade (default A992)."""
resolve_beam_steel(m::MaterialOptions) = something(m.steel, StructuralSizer.A992_Steel)

"""
    beam_sizing_material(params) -> Union{AbstractMaterial, Nothing}

Material the beams are sized in: `params.beams.material`, or A992 steel when
`params.beams` is unset (the sizing default, `SteelBeamOptions()`).
PixelFrame beams have no single material and return `nothing`, which the
release dispatch resolves to fixed ends.
"""
beam_sizing_material(params) =
    _beam_sizing_material(something(params.beams, StructuralSizer.SteelBeamOptions()))
_beam_sizing_material(o::Union{StructuralSizer.SteelBeamOptions, StructuralSizer.ConcreteBeamOptions}) = o.material
_beam_sizing_material(::StructuralSizer.PixelFrameBeamOptions) = nothing

"""
    check_material_compatibility(mat::MaterialOptions, floor::AbstractFloorOptions)

Warn if material choices are incompatible with the selected floor type.
"""
function check_material_compatibility(mat::MaterialOptions, floor::StructuralSizer.AbstractFloorOptions)
    fs = StructuralSizer.floor_symbol(floor)
    if fs in (:flat_plate, :flat_slab, :one_way, :two_way, :waffle, :pt_banded)
        if !isnothing(mat.steel)
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

