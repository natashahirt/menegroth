# ==============================================================================
# Concrete Column Options
# ==============================================================================

"""
    ConcreteColumnOptions

Configuration for reinforced concrete column sizing.

The `size_columns` API accepts **any Unitful quantity** for demands — conversions to
ACI units (kip, kip·ft) happen automatically via `Asap.to_kip`/`Asap.to_kipft`.
Bare `Real` values are treated as already in kip / kip·ft.

# Sizing Strategy
- `:discrete` (default) — MIP discrete selection from an RC column catalog.
  Uses `solver` to pick the lightest feasible section from the catalog.
- `:nlp` — Continuous NLP optimization (Ipopt) for column dimensions (b, h)
  and reinforcement ratio (ρg).  Produces the minimum-weight section that
  satisfies ACI 318 P-M interaction, then snaps to practical increments.

Both strategies share the same material, slenderness, and shape-control
fields.  Catalog-specific fields (`catalog`, `custom_catalog`, `n_max_sections`,
`solver`) are ignored when `sizing_strategy == :nlp`.  NLP-specific fields
(`nlp_*`) are ignored when `sizing_strategy == :discrete`.

# Example
```julia
opts = ConcreteColumnOptions()
opts = ConcreteColumnOptions(sizing_strategy = :nlp)
opts = ConcreteColumnOptions(section_shape = :circular)

opts = ConcreteColumnOptions(
    material = NWC_6000,
    sizing_strategy = :nlp,
    nlp_prefer_square = 0.1,
)

opts = ConcreteColumnOptions(
    material = NWC_5000,
    rebar_material = Rebar_75,
    cover = 50.8u"mm",
    transverse_bar_size = :no4,
)
```

# Fields
- `material`: Concrete material (default: NWC_4000)
- `section_shape`: `:rect` or `:circular` (default: `:rect`)
- `rebar_material`: RebarSteel for longitudinal bars (default: Rebar_60)
- `transverse_rebar_material`: RebarSteel for ties/spirals (default: same as rebar_material)
- `cover`: Clear cover to transverse reinforcement (default: 1.5" or 38mm)
- `transverse_bar_size`: Tie/spiral bar size, :no3, :no4, :no5 (default: :no4)
- `sizing_strategy`: `:discrete` (MIP) or `:nlp` (continuous Ipopt) (default: `:discrete`)
- `catalog`: `:standard`, `:low_capacity`, `:high_capacity`, `:all` (default: `:standard`)
- `custom_catalog`: Custom section vector (overrides catalog)
- `max_depth`: Maximum depth/diameter (default: Inf mm)
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `include_slenderness`: Consider slenderness effects (default: true)
- `include_biaxial`: Consider biaxial bending (default: true)
- `βdns`: Sustained load ratio for slenderness (default: 0.6)
- `objective`: MinWeight(), MinVolume(), MinCost(), MinCarbon() (default: MinCarbon())
- `solver`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
- `shape_constraint`: `:square`, `:bounded`, `:free` (default: `:square`)
  - `:square` — force c1 = c2 at every growth step (current behavior)
  - `:bounded` — allow rectangular columns, capped by `max_aspect_ratio`
  - `:free` — no aspect ratio constraint (research use only)
- `max_aspect_ratio`: Maximum c1/c2 or c2/c1 when `shape_constraint == :bounded` (default: 2.0)
- `size_increment`: Rounding increment for column dimensions (default: 0.5")

## NLP-Specific Fields (ignored when `sizing_strategy == :discrete`)
- `nlp_dim_increment`: Round NLP solution to this increment (default: 2")
- `nlp_aspect_limit`: Maximum aspect ratio max(b,h)/min(b,h) (default: 3.0)
- `nlp_prefer_square`: Penalty for non-square sections, 0 = none (default: 0.0)
- `nlp_ρ_max`: Practical max ρg (ACI allows 0.08, practical ≤ 0.06) (default: 0.06)
- `nlp_solver`: NLP backend :ipopt, :grid, :nlopt (default: :ipopt)
- `nlp_maxiter`: Maximum NLP solver iterations (default: 200)
- `nlp_tol`: NLP convergence tolerance (default: 1e-4)
- `nlp_n_multistart`: Multi-start count, >1 for non-smooth problems (default: 1)

# Material Presets
- Concrete: NWC_3000, NWC_4000, NWC_5000, NWC_6000, NWC_GGBS, NWC_PFA
- Rebar: Rebar_40, Rebar_60, Rebar_75, Rebar_80

"""
Base.@kwdef struct ConcreteColumnOptions
    material::Concrete = NWC_4000
    materials::Union{Nothing, Vector{<:Concrete}} = nothing  # multi-material MIP
    section_shape::Symbol = :rect       # :rect or :circular
    rebar_material::RebarSteel = Rebar_60
    transverse_rebar_material::Union{Nothing, RebarSteel} = nothing  # defaults to rebar_material
    cover::Length = 38.1u"mm"                    # Clear cover to ties (≈1.5")
    transverse_bar_size::Symbol = :no4         # :no3, :no4, :no5

    # ─── Sizing Strategy ───
    sizing_strategy::Symbol = :discrete

    catalog::Symbol = :standard         # :standard, :low_capacity, :high_capacity, :all
    # `:soft` starts in `catalog` and, when nothing passes, merges the next
    # named catalog and warns. `:hard` uses that catalog only and errors.
    # A custom catalog is the range either way: it has no next tier.
    catalog_constraint::Symbol = :soft
    custom_catalog::Union{Nothing, Vector} = nothing
    max_depth::Length = Inf * u"mm"      # depth for rect, diameter for circular
    n_max_sections::Int = 0             # 0 = no limit
    include_slenderness::Bool = true
    include_biaxial::Bool = true
    βdns::Float64 = 0.6
    # MinCarbon (not MinWeight): rank sections by true embodied carbon, counting
    # rebar — see `_column_cache_material` (StructuralSynthesizer, WP 2.5). The
    # flat-plate cache is built from a `ReinforcedConcreteMaterial`, so this is
    # rebar-inclusive; P-M capacity is unchanged (only `obj_coeffs` move).
    objective::AbstractObjective = MinCarbon()
    solver::Symbol = :auto
    time_limit_sec::Real = 30.0  # MIP solver time limit (discrete only)

    # ─── NLP-Specific Settings (ignored when sizing_strategy == :discrete) ───
    nlp_dim_increment::Length = 2.0u"inch"
    nlp_aspect_limit::Float64 = 3.0
    nlp_prefer_square::Float64 = 0.0
    nlp_ρ_max::Float64 = 0.06
    nlp_solver::Symbol = :ipopt
    nlp_maxiter::Int = 200
    nlp_tol::Float64 = 1e-4
    nlp_n_multistart::Int = 1

    # ─── Column Shape / Growth Control ───
    shape_constraint::Symbol = :square
    max_aspect_ratio::Float64 = 2.0
    size_increment::Length = 0.5u"inch"
end

using Asap: ksi

"""
    get_rebar_fy(opts::ConcreteColumnOptions) -> Unitful.Pressure

Return longitudinal rebar yield strength in ksi.
"""
function get_rebar_fy(opts::ConcreteColumnOptions)
    uconvert(ksi, opts.rebar_material.Fy)
end

"""
    get_transverse_rebar(opts::ConcreteColumnOptions) -> RebarSteel

Return the transverse rebar material, defaulting to the longitudinal rebar material.
"""
function get_transverse_rebar(opts::ConcreteColumnOptions)
    isnothing(opts.transverse_rebar_material) ? opts.rebar_material : opts.transverse_rebar_material
end

"""Transverse bar diameters in inches, keyed by ASTM bar size symbol."""
const TRANSVERSE_BAR_DIAMETERS = Dict(
    :no3 => 0.375,  # 3/8"
    :no4 => 0.500,  # 1/2"
    :no5 => 0.625,  # 5/8"
)

"""
    get_transverse_bar_diameter(opts::ConcreteColumnOptions) -> Float64

Return transverse bar diameter [inches] for the selected bar size.
"""
function get_transverse_bar_diameter(opts::ConcreteColumnOptions)
    haskey(TRANSVERSE_BAR_DIAMETERS, opts.transverse_bar_size) ||
        throw(ArgumentError("Unknown transverse bar size: $(opts.transverse_bar_size). Use :no3, :no4, or :no5."))
    TRANSVERSE_BAR_DIAMETERS[opts.transverse_bar_size]
end

# ==============================================================================
# Concrete Beam Options
# ==============================================================================

"""
    ConcreteBeamOptions

Configuration for reinforced concrete beam sizing (ACI 318 flexure + shear).

The `size_beams` API accepts **any Unitful quantity** for demands — conversions to
ACI units (kip, kip·ft) happen automatically via `Asap.to_kip`/`Asap.to_kipft`.
Bare `Real` values are treated as already in kip / kip·ft.

# Example
```julia
opts = ConcreteBeamOptions()

# Unitful demands — units converted automatically
size_beams([60.0u"kN*m"], [40.0u"kN"], geoms, opts)

# Bare floats — assumed kip·ft / kip
size_beams([120.0], [25.0], geoms, opts)

opts = ConcreteBeamOptions(
    material = NWC_5000,
    rebar_material = Rebar_75,
    deflection_limit = 1/480,
)

opts = ConcreteBeamOptions(
    cover = 50.8u"mm",
    transverse_bar_size = :no4,
    max_depth = 600.0u"mm",
)
```

# Fields
## Materials
- `material`: Concrete material (default: NWC_4000)
- `rebar_material`: RebarSteel for longitudinal bars (default: Rebar_60)
- `transverse_rebar_material`: RebarSteel for stirrups (default: same as rebar_material)
- `cover`: Clear cover to stirrups (default: 1.5" or 38mm)
- `transverse_bar_size`: Stirrup bar size :no3, :no4, :no5 (default: :no3)

## Catalog (discrete sizing)
- `catalog`: `:standard`, `:all` (default: `:standard`)
- `custom_catalog`: Custom section vector (overrides catalog)

## Dimension Constraints
- `max_depth`: Maximum overall depth (default: Inf mm)
- `max_width`: Maximum width (default: Inf mm)

## Design Settings
- `deflection_limit`: L/δ ratio, e.g. `1/360`.
  `nothing` = no check (default: `1/360`)
- `sustained_live_fraction`: Share of service live load counted as sustained
  for the long-term deflection multiplier (ACI 318-11 R9.5.2.5). `0` sustains
  dead load only (default: `0`)
- `include_flange`: If `true`, the building-level sizing dispatcher
  (`size_beams!`) auto-computes the effective T-beam flange width and slab
  thickness from adjacent slabs and routes to the T-beam sizing API.
  The ACI 318-11 §8.12.2 effective flange width limits are applied
  automatically, using beam tributary width as `sw` and `edge_face_counts`
  for interior/edge classification.  (default: `false`)
- `catalog_size_tbeam`: T-beam catalog density when `include_flange=true`
  and method=`:discrete`.  `:standard`, `:small`, `:large` (default: `:standard`)

## Optimization
- `sizing_strategy`: `:discrete` only for the unified `size_beams` /
  `size_tbeams` APIs. Use the standalone `size_rc_beam_nlp` function for the
  experimental continuous formulation.
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `objective`: MinWeight(), MinVolume(), MinCost(), MinCarbon() (default: MinWeight())
- `solver`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
"""
Base.@kwdef struct ConcreteBeamOptions
    material::Concrete = NWC_4000
    materials::Union{Nothing, Vector{<:Concrete}} = nothing  # multi-material MIP
    rebar_material::RebarSteel = Rebar_60
    transverse_rebar_material::Union{Nothing, RebarSteel} = nothing
    cover::Length = 38.1u"mm"            # ≈ 1.5" to stirrups
    transverse_bar_size::Symbol = :no3   # Stirrup bar size

    catalog::Symbol = :standard
    # `:soft` grows a named catalog one tier at a time. `:hard` errors when
    # nothing in the named catalog passes. A custom catalog is not grown.
    catalog_constraint::Symbol = :soft
    custom_catalog::Union{Nothing, Vector} = nothing

    max_depth::Length = Inf * u"mm"
    max_width::Length = Inf * u"mm"

    deflection_limit::Union{Nothing, Float64} = 1/360
    # R9.5.2.5: fraction of live load sustained with dead load. 0 = dead only.
    sustained_live_fraction::Float64 = 0.0
    include_flange::Bool = false
    catalog_size_tbeam::Symbol = :standard
    # One section for every rib in the floor. The default sizes each group
    # on its own flange.
    uniform_geometry::Bool = false
    # `:mip` is the discrete catalog. `:standard_pan` is reserved until a pan
    # list within the joist clear-spacing limit is in the corpus.
    rib_form::Symbol = :mip

    sizing_strategy::Symbol = :discrete
    n_max_sections::Int = 0
    objective::AbstractObjective = MinWeight()
    solver::Symbol = :auto
    time_limit_sec::Real = 30.0  # MIP solver time limit (discrete only)
end

"""
    get_rebar_fy(opts::ConcreteBeamOptions) -> Unitful.Pressure

Return longitudinal rebar yield strength in ksi.
"""
function get_rebar_fy(opts::ConcreteBeamOptions)
    uconvert(ksi, opts.rebar_material.Fy)
end

"""
    get_transverse_rebar(opts::ConcreteBeamOptions) -> RebarSteel

Return the transverse rebar material, defaulting to the longitudinal rebar material.
"""
function get_transverse_rebar(opts::ConcreteBeamOptions)
    isnothing(opts.transverse_rebar_material) ? opts.rebar_material : opts.transverse_rebar_material
end

"""
    get_transverse_bar_diameter(opts::ConcreteBeamOptions) -> Float64

Return transverse bar diameter [inches] for the selected bar size.
"""
function get_transverse_bar_diameter(opts::ConcreteBeamOptions)
    haskey(TRANSVERSE_BAR_DIAMETERS, opts.transverse_bar_size) ||
        throw(ArgumentError("Unknown transverse bar size: $(opts.transverse_bar_size). Use :no3, :no4, or :no5."))
    TRANSVERSE_BAR_DIAMETERS[opts.transverse_bar_size]
end

