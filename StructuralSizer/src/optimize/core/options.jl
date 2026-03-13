# ==============================================================================
# Member Sizing Options (Configuration Structs)
# ==============================================================================
# Material-specific configuration for column and beam sizing.
# Each type has sensible defaults — override only what you need.
#
# Steel uses a single struct (SteelMemberOptions) with aliases:
#   SteelColumnOptions = SteelMemberOptions
#   SteelBeamOptions   = SteelMemberOptions
# because AISC discrete sizing uses the same checker for both.
#
# Concrete has separate structs for columns vs beams because
# ACI design rules differ significantly (P-M interaction vs flexure/shear).

# ==============================================================================
# Steel Column Options
# ==============================================================================

"""
    SteelColumnOptions

Configuration for steel column sizing (AISC 360 P-M interaction).

Columns are governed by axial + flexural interaction — there is no member-level
deflection limit (story drift is checked at the system level, not here).

# Example
```julia
opts = SteelColumnOptions()
opts = SteelColumnOptions(section_type = :hss, max_depth = 0.4)
```

# Fields
- `material`: Steel grade (default: A992_Steel)
- `materials`: Vector of grades for multi-material MIP (default: nothing)
- `section_type`: `:w`, `:hss`, `:pipe`, `:w_and_hss` (default: `:w`)
- `catalog`: `:common`, `:preferred`, `:all` (default: `:preferred`)
- `custom_catalog`: Custom section vector (overrides catalog)
- `max_depth`: Maximum depth (default: Inf)
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `objective`: MinWeight(), MinVolume(), MinCost(), MinCarbon() (default: MinWeight())
- `solver`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
"""
Base.@kwdef struct SteelColumnOptions
    material::StructuralSteel = A992_Steel
    materials::Union{Nothing, Vector{<:StructuralSteel}} = nothing
    section_type::Symbol = :w
    catalog::Symbol = :preferred
    custom_catalog::Union{Nothing, Vector} = nothing
    max_depth::Length = Inf * u"mm"
    n_max_sections::Int = 0
    sizing_strategy::Symbol = :discrete
    objective::AbstractObjective = MinWeight()
    solver::Symbol = :auto
end

# ==============================================================================
# Steel Beam Options
# ==============================================================================

"""
    SteelBeamOptions

Configuration for steel beam sizing (AISC 360 flexure + shear + deflection).

Beams default to L/360 LL and L/240 total (DL+LL) deflection checks. The deflection
constraints are only enforced when `δ_max_LL`/`δ_max_total`/`I_ref` are provided
in the demand (from Asap FEM or via `size_beams` kwargs). Set the relevant limit
to `nothing` to opt out.

# Example
```julia
opts = SteelBeamOptions()                                # L/360 LL, L/240 total
opts = SteelBeamOptions(deflection_limit = nothing,      # strength only
                        total_deflection_limit = nothing)
opts = SteelBeamOptions(composite = true)                # composite beam sizing
```

# Fields
- `material`: Steel grade (default: A992_Steel)
- `materials`: Vector of grades for multi-material MIP (default: nothing)
- `section_type`: `:w`, `:hss`, `:pipe`, `:w_and_hss` (default: `:w`)
- `catalog`: `:common`, `:preferred`, `:all` (default: `:preferred`)
- `custom_catalog`: Custom section vector (overrides catalog)
- `max_depth`: Maximum depth (default: Inf mm)
- `deflection_limit`: LL L/δ ratio (default: `1/360`). `nothing` to disable.
- `total_deflection_limit`: DL+LL L/δ ratio (default: `1/240`). `nothing` to disable.
- `composite`: Enable composite beam sizing via AISC 360-16 Ch. I (default: false)
- `sizing_strategy`: `:discrete` (MIP catalog) or `:nlp` (continuous) (default: `:discrete`)
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `objective`: MinWeight(), MinVolume(), MinCost(), MinCarbon() (default: MinWeight())
- `solver`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
"""
Base.@kwdef struct SteelBeamOptions
    material::StructuralSteel = A992_Steel
    materials::Union{Nothing, Vector{<:StructuralSteel}} = nothing
    section_type::Symbol = :w
    catalog::Symbol = :preferred
    custom_catalog::Union{Nothing, Vector} = nothing
    max_depth::Length = Inf * u"mm"
    deflection_limit::Union{Nothing, Float64} = 1/360
    total_deflection_limit::Union{Nothing, Float64} = 1/240
    composite::Bool = false
    n_max_sections::Int = 0
    sizing_strategy::Symbol = :discrete
    objective::AbstractObjective = MinWeight()
    solver::Symbol = :auto
end

"""Union of steel column and beam options for shared dispatch paths."""
const SteelMemberOptions = Union{SteelColumnOptions, SteelBeamOptions}

"""Get LL deflection_limit: beams have it, columns return nothing."""
_deflection_limit(opts::SteelBeamOptions) = opts.deflection_limit
_deflection_limit(opts::SteelColumnOptions) = nothing

"""Get total deflection_limit: beams have it, columns return nothing."""
_total_deflection_limit(opts::SteelBeamOptions) = opts.total_deflection_limit
_total_deflection_limit(opts::SteelColumnOptions) = nothing

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
- `objective`: MinWeight(), MinVolume(), MinCost(), MinCarbon() (default: MinWeight())
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
    custom_catalog::Union{Nothing, Vector} = nothing
    max_depth::Length = Inf * u"mm"      # depth for rect, diameter for circular
    n_max_sections::Int = 0             # 0 = no limit
    include_slenderness::Bool = true
    include_biaxial::Bool = true
    βdns::Float64 = 0.6
    objective::AbstractObjective = MinWeight()
    solver::Symbol = :auto

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
- `include_flange`: If `true`, the building-level sizing dispatcher
  (`size_beams!`) auto-computes the effective T-beam flange width and slab
  thickness from adjacent slabs and routes to the T-beam sizing API.
  The ACI 318-11 §8.12.2 effective flange width limits are applied
  automatically, using beam tributary width as `sw` and `edge_face_counts`
  for interior/edge classification.  (default: `false`)
- `catalog_size_tbeam`: T-beam catalog density when `include_flange=true`
  and method=`:discrete`.  `:standard`, `:small`, `:large` (default: `:standard`)

## Optimization
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
    custom_catalog::Union{Nothing, Vector} = nothing

    max_depth::Length = Inf * u"mm"
    max_width::Length = Inf * u"mm"

    deflection_limit::Union{Nothing, Float64} = 1/360
    include_flange::Bool = false
    catalog_size_tbeam::Symbol = :standard

    sizing_strategy::Symbol = :discrete
    n_max_sections::Int = 0
    objective::AbstractObjective = MinWeight()
    solver::Symbol = :auto
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

# ==============================================================================
# PixelFrame Beam Options
# ==============================================================================

"""
    PixelFrameBeamOptions

Configuration for PixelFrame beam sizing (MIP discrete catalog optimization).

PixelFrame beams use fiber-reinforced concrete (FRC) with external post-tensioning.
The capacity checker uses ACI 318-19 for axial/flexural capacity and fib MC2010
for FRC shear capacity.

All physical quantities accept **Unitful values** — conversions to internal
units happen automatically at the catalog-generation and checker boundaries.
Bare `Real` values are still accepted and interpreted as mm / MPa / mm² / kg/m³
for backward compatibility, but Unitful is preferred for safety.

# Example
```julia
# Default: Y-section, fc′ swept 28–100 MPa
opts = PixelFrameBeamOptions()

# Custom: specific catalog (Unitful)
opts = PixelFrameBeamOptions(
    fc_values     = [40.0, 57.0, 80.0] .* u"MPa",
    λ_values      = [:Y],
    dosage_values = [20.0, 40.0] .* u"kg/m^3",
    L_px_values   = [125.0, 200.0] .* u"mm",
    A_s_values    = [157.0, 402.0] .* u"mm^2",
)

# With deflection check (service loads)
opts = PixelFrameBeamOptions(deflection_limit = 1/360)
```

# Fields
## Catalog Generation
- `L_px_values`: Pixel arm lengths (default: [125mm])
- `t_values`: Wall thicknesses (default: [30mm])
- `L_c_values`: Curve leg lengths (default: [30mm])
- `λ_values`: Layup types (default: [:Y])
- `fc_values`: Concrete strengths (default: 28:100 MPa)
- `dosage_values`: Fiber dosages (default: [20 kg/m³])
- `A_s_values`: Tendon areas (default: [157, 226, 402] mm²)
- `f_pe_values`: Effective prestress (default: [500 MPa])
- `d_ps_values`: Tendon eccentricities (default: 50:25:250 mm)
- `fiber_ecc`: Fiber embodied carbon [kgCO₂e/kg] — dimensionless (default: 1.4)
- `custom_catalog`: Custom catalog vector (overrides generation)

## Checker Settings
- `E_s`: Tendon elastic modulus (default: 200 GPa)
- `f_py`: Tendon yield strength (default: 1860 MPa)
- `γ_c`: fib partial safety factor for concrete — dimensionless (default: 1.0)

## Minimum Bounding Box
- `min_depth`: Minimum section bounding-box depth (default: 0mm = no constraint).
  Set by the flat plate pipeline when punching shear requires a larger section.
- `min_width`: Minimum section bounding-box width (default: 0mm = no constraint)

## Pixel Discretization
- `pixel_length`: Along-span length of each physical pixel piece (default: 500mm).
  Spans must be exact multiples of this value; an error is raised otherwise.

## Deflection (serviceability)
- `deflection_limit`: L/δ ratio for serviceability, e.g. `1/360`.
  `nothing` = no deflection check (default: `nothing`)

## Optimization
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `objective`: MinVolume(), MinWeight(), MinCost(), MinCarbon() (default: MinCarbon())
- `solver`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
"""
Base.@kwdef struct PixelFrameBeamOptions
    # Catalog generation — Unitful vectors
    L_px_values::Vector{<:Union{Real, Length}}       = [125.0u"mm"]
    t_values::Vector{<:Union{Real, Length}}           = [30.0u"mm"]
    L_c_values::Vector{<:Union{Real, Length}}         = [30.0u"mm"]
    λ_values::Vector{Symbol}                          = [:Y]
    fc_values::Vector{<:Union{Real, Unitful.Pressure}} = collect(28:100) .* u"MPa"
    dosage_values::Vector{<:Union{Real, Unitful.Density}} = [20.0u"kg/m^3"]
    A_s_values::Vector{<:Union{Real, Unitful.Area}}  = [157.0, 226.0, 402.0] .* u"mm^2"
    f_pe_values::Vector{<:Union{Real, Unitful.Pressure}} = [500.0u"MPa"]
    d_ps_values::Vector{<:Union{Real, Length}}        = collect(Float64, 50:25:250) .* u"mm"
    fiber_ecc::Float64                                = 1.4   # kgCO₂e/kg (dimensionless)
    custom_catalog::Union{Nothing, Vector}            = nothing

    # Checker settings — Unitful scalars
    E_s::Union{Real, Unitful.Pressure}   = 200.0u"GPa"
    f_py::Union{Real, Unitful.Pressure}  = 1860.0u"MPa"
    γ_c::Float64                         = 1.0

    # Minimum bounding box (0 = no constraint)
    min_depth::Union{Real, Length}  = 0.0u"mm"
    min_width::Union{Real, Length}  = 0.0u"mm"

    # Pixel discretization
    # Per Wongsittikan (2024) §2.3, the standard pixel length is 500 mm.
    pixel_length::Union{Real, Length} = 500.0u"mm"

    # Deflection (serviceability)
    deflection_limit::Union{Nothing, Float64} = nothing

    # Optimization
    n_max_sections::Int = 0
    objective::AbstractObjective = MinWeight()
    solver::Symbol = :auto
end

# ── Boundary helpers: strip Unitful to bare mm / MPa / mm² / kg/m³ ──

"""Strip a length value to mm (bare Float64). Bare Real is assumed mm."""
_to_mm(x::Real)              = Float64(x)
_to_mm(x::Unitful.Length)    = ustrip(u"mm", x)

"""Strip a pressure value to MPa (bare Float64). Bare Real is assumed MPa."""
_to_MPa(x::Real)                = Float64(x)
_to_MPa(x::Unitful.Pressure)   = ustrip(u"MPa", x)

"""Strip an area value to mm² (bare Float64). Bare Real is assumed mm²."""
_to_mm2(x::Real)             = Float64(x)
_to_mm2(x::Unitful.Area)    = ustrip(u"mm^2", x)

"""Strip a density value to kg/m³ (bare Float64). Bare Real is assumed kg/m³."""
_to_kgm3(x::Real)                = Float64(x)
_to_kgm3(x::Unitful.Density)    = ustrip(u"kg/m^3", x)

"""Extract bare catalog-generation vectors from PixelFrameBeamOptions."""
function _pf_catalog_kwargs(opts::PixelFrameBeamOptions)
    (;
        L_px_values   = _to_mm.(opts.L_px_values),
        t_values      = _to_mm.(opts.t_values),
        L_c_values    = _to_mm.(opts.L_c_values),
        λ_values      = opts.λ_values,
        fc_values     = _to_MPa.(opts.fc_values),
        dosage_values = _to_kgm3.(opts.dosage_values),
        A_s_values    = _to_mm2.(opts.A_s_values),
        f_pe_values   = _to_MPa.(opts.f_pe_values),
        d_ps_values   = _to_mm.(opts.d_ps_values),
        fiber_ecc     = opts.fiber_ecc,
    )
end

"""Extract bare checker kwargs from PixelFrameBeamOptions."""
function _pf_checker_kwargs(opts::PixelFrameBeamOptions)
    (;
        E_s_MPa      = _to_MPa(opts.E_s),
        f_py_MPa     = _to_MPa(opts.f_py),
        γ_c          = opts.γ_c,
        min_depth_mm = _to_mm(opts.min_depth),
        min_width_mm = _to_mm(opts.min_width),
    )
end

"""Pixel length in mm (bare Float64) from PixelFrameBeamOptions."""
_pf_pixel_mm(opts::PixelFrameBeamOptions) = _to_mm(opts.pixel_length)

"""Compact display for `PixelFrameBeamOptions`."""
function Base.show(io::IO, opts::PixelFrameBeamOptions)
    n_fc = length(opts.fc_values)
    λs = join(string.(opts.λ_values), ",")
    px_mm = _to_mm(opts.pixel_length)
    print(io, "PixelFrameBeamOptions(λ=[", λs, "], fc=", n_fc, " grades")
    print(io, ", px=", Int(px_mm), "mm")
    !isnothing(opts.deflection_limit) && print(io, ", L/", Int(round(1/opts.deflection_limit)))
    d_mm = _to_mm(opts.min_depth); w_mm = _to_mm(opts.min_width)
    (d_mm > 0 || w_mm > 0) && print(io, ", min_bbox=", d_mm, "×", w_mm, "mm")
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

# ==============================================================================
# PixelFrame Column Options
# ==============================================================================

"""
    PixelFrameColumnOptions

Configuration for PixelFrame column sizing (MIP discrete catalog optimization).

PixelFrame columns typically use the X4 (4-arm) layup for biaxial resistance.
The capacity checker uses ACI 318-19 for axial/flexural capacity and fib MC2010
for FRC shear capacity.

All physical quantities accept **Unitful values** — conversions to internal
units happen automatically at the catalog-generation and checker boundaries.
Bare `Real` values are still accepted and interpreted as mm / MPa / mm² / kg/m³
for backward compatibility, but Unitful is preferred for safety.

# Example
```julia
# Default: X4-section for columns
opts = PixelFrameColumnOptions()

# Custom catalog for specific strengths (Unitful)
opts = PixelFrameColumnOptions(
    fc_values = [57.0, 80.0] .* u"MPa",
    λ_values  = [:X4],
    d_ps_values = [100.0, 150.0, 200.0] .* u"mm",
)
```

# Fields
## Catalog Generation
- `L_px_values`: Pixel arm lengths (default: [125mm])
- `t_values`: Wall thicknesses (default: [30mm])
- `L_c_values`: Curve leg lengths (default: [30mm])
- `λ_values`: Layup types (default: [:X4])
- `fc_values`: Concrete strengths (default: 28:100 MPa)
- `dosage_values`: Fiber dosages (default: [20 kg/m³])
- `A_s_values`: Tendon areas (default: [157, 226, 402] mm²)
- `f_pe_values`: Effective prestress (default: [500 MPa])
- `d_ps_values`: Tendon eccentricities (default: 50:25:250 mm)
- `fiber_ecc`: Fiber embodied carbon [kgCO₂e/kg] — dimensionless (default: 1.4)
- `custom_catalog`: Custom catalog vector (overrides generation)

## Checker Settings
- `E_s`: Tendon elastic modulus (default: 200 GPa)
- `f_py`: Tendon yield strength (default: 1860 MPa)
- `γ_c`: fib partial safety factor for concrete — dimensionless (default: 1.0)

## Minimum Bounding Box
- `min_depth`: Minimum section bounding-box depth (default: 0mm = no constraint).
  Set by the flat plate pipeline when punching shear requires a larger section.
  After a punching failure, set `min_depth` / `min_width` to the failed
  section's bounding box + increment, then re-run `size_columns`.
- `min_width`: Minimum section bounding-box width (default: 0mm = no constraint)

## Pixel Discretization
- `pixel_length`: Along-span length of each physical pixel piece (default: 500mm).
  Column heights must be exact multiples of this value; an error is raised otherwise.

## Optimization
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `objective`: MinVolume(), MinWeight(), MinCost(), MinCarbon() (default: MinCarbon())
- `solver`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
"""
Base.@kwdef struct PixelFrameColumnOptions
    # Catalog generation — Unitful vectors
    L_px_values::Vector{<:Union{Real, Length}}       = [125.0u"mm"]
    t_values::Vector{<:Union{Real, Length}}           = [30.0u"mm"]
    L_c_values::Vector{<:Union{Real, Length}}         = [30.0u"mm"]
    λ_values::Vector{Symbol}                          = [:X4]
    fc_values::Vector{<:Union{Real, Unitful.Pressure}} = collect(28:100) .* u"MPa"
    dosage_values::Vector{<:Union{Real, Unitful.Density}} = [20.0u"kg/m^3"]
    A_s_values::Vector{<:Union{Real, Unitful.Area}}  = [157.0, 226.0, 402.0] .* u"mm^2"
    f_pe_values::Vector{<:Union{Real, Unitful.Pressure}} = [500.0u"MPa"]
    d_ps_values::Vector{<:Union{Real, Length}}        = collect(Float64, 50:25:250) .* u"mm"
    fiber_ecc::Float64                                = 1.4   # kgCO₂e/kg (dimensionless)
    custom_catalog::Union{Nothing, Vector}            = nothing

    # Checker settings — Unitful scalars
    E_s::Union{Real, Unitful.Pressure}   = 200.0u"GPa"
    f_py::Union{Real, Unitful.Pressure}  = 1860.0u"MPa"
    γ_c::Float64                         = 1.0

    # Minimum bounding box (0 = no constraint)
    min_depth::Union{Real, Length}  = 0.0u"mm"
    min_width::Union{Real, Length}  = 0.0u"mm"

    # Pixel discretization
    pixel_length::Union{Real, Length} = 500.0u"mm"

    # Optimization
    n_max_sections::Int = 0
    objective::AbstractObjective = MinWeight()
    solver::Symbol = :auto
end

"""Extract bare catalog-generation vectors from PixelFrameColumnOptions."""
function _pf_catalog_kwargs(opts::PixelFrameColumnOptions)
    (;
        L_px_values   = _to_mm.(opts.L_px_values),
        t_values      = _to_mm.(opts.t_values),
        L_c_values    = _to_mm.(opts.L_c_values),
        λ_values      = opts.λ_values,
        fc_values     = _to_MPa.(opts.fc_values),
        dosage_values = _to_kgm3.(opts.dosage_values),
        A_s_values    = _to_mm2.(opts.A_s_values),
        f_pe_values   = _to_MPa.(opts.f_pe_values),
        d_ps_values   = _to_mm.(opts.d_ps_values),
        fiber_ecc     = opts.fiber_ecc,
    )
end

"""Extract bare checker kwargs from PixelFrameColumnOptions."""
function _pf_checker_kwargs(opts::PixelFrameColumnOptions)
    (;
        E_s_MPa      = _to_MPa(opts.E_s),
        f_py_MPa     = _to_MPa(opts.f_py),
        γ_c          = opts.γ_c,
        min_depth_mm = _to_mm(opts.min_depth),
        min_width_mm = _to_mm(opts.min_width),
    )
end

"""Pixel length in mm (bare Float64) from PixelFrameColumnOptions."""
_pf_pixel_mm(opts::PixelFrameColumnOptions) = _to_mm(opts.pixel_length)

"""Compact display for `PixelFrameColumnOptions`."""
function Base.show(io::IO, opts::PixelFrameColumnOptions)
    n_fc = length(opts.fc_values)
    λs = join(string.(opts.λ_values), ",")
    px_mm = _to_mm(opts.pixel_length)
    print(io, "PixelFrameColumnOptions(λ=[", λs, "], fc=", n_fc, " grades")
    print(io, ", px=", Int(px_mm), "mm")
    d_mm = _to_mm(opts.min_depth); w_mm = _to_mm(opts.min_width)
    (d_mm > 0 || w_mm > 0) && print(io, ", min_bbox=", d_mm, "×", w_mm, "mm")
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

# ==============================================================================
# Union Types for Dispatch
# ==============================================================================

"""Column sizing options (steel, concrete, or PixelFrame)."""
const ColumnOptions = Union{SteelColumnOptions, ConcreteColumnOptions, PixelFrameColumnOptions}

"""Beam sizing options (steel, concrete, or PixelFrame)."""
const BeamOptions = Union{SteelBeamOptions, ConcreteBeamOptions, PixelFrameBeamOptions}

"""Any member sizing options."""
const MemberOptions = Union{SteelColumnOptions, SteelBeamOptions, ConcreteColumnOptions,
                            ConcreteBeamOptions, PixelFrameBeamOptions, PixelFrameColumnOptions}

# ==============================================================================
# Display
# ==============================================================================

"""Compact display for `SteelColumnOptions`."""
function Base.show(io::IO, opts::SteelColumnOptions)
    mat_str = material_name(opts.material)
    sec_type = uppercase(string(opts.section_type))
    strat_str = opts.sizing_strategy == :nlp ? " NLP" : ""
    print(io, "SteelColumnOptions(", mat_str, " ", sec_type, strat_str)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

"""Compact display for `SteelBeamOptions`."""
function Base.show(io::IO, opts::SteelBeamOptions)
    mat_str = material_name(opts.material)
    sec_type = uppercase(string(opts.section_type))
    strat_str = opts.sizing_strategy == :nlp ? " NLP" : ""
    print(io, "SteelBeamOptions(", mat_str, " ", sec_type, strat_str)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    dl = _deflection_limit(opts)
    !isnothing(dl) && print(io, ", L/", Int(round(1/dl)))
    tdl = _total_deflection_limit(opts)
    !isnothing(tdl) && print(io, ", L_total/", Int(round(1/tdl)))
    opts.composite && print(io, ", composite")
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

"""Compact display for `ConcreteColumnOptions`."""
function Base.show(io::IO, opts::ConcreteColumnOptions)
    mat_str = material_name(opts.material)
    shape_str = opts.section_shape == :circular ? "CIRCULAR" : "RECT"
    strat_str = opts.sizing_strategy == :nlp ? " NLP" : ""
    print(io, "ConcreteColumnOptions(", mat_str, " ", shape_str, strat_str)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    !opts.include_slenderness && print(io, ", no_slenderness")
    !opts.include_biaxial && print(io, ", no_biaxial")
    print(io, ")")
end

"""Compact display for `ConcreteBeamOptions`."""
function Base.show(io::IO, opts::ConcreteBeamOptions)
    mat_str = material_name(opts.material)
    strat_str = opts.sizing_strategy == :nlp ? " NLP" : ""
    print(io, "ConcreteBeamOptions(", mat_str, strat_str)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    isfinite(opts.max_width) && print(io, ", max_width=", opts.max_width)
    if !isnothing(opts.deflection_limit)
        print(io, ", L/", Int(round(1/opts.deflection_limit)))
    end
    opts.include_flange && print(io, ", T-beam")
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

# ==============================================================================
# NLP Column Options (Continuous Optimization)
# ==============================================================================

"""
    NLPColumnOptions

Configuration for continuous (NLP) RC column sizing using interior point optimization.

Unlike `ConcreteColumnOptions` which selects from a discrete catalog,
this optimizes column dimensions (b, h) and reinforcement ratio (ρg) continuously
to find the minimum-volume section that satisfies ACI 318 requirements.

# Example
```julia
opts = NLPColumnOptions()

opts = NLPColumnOptions(
    material = NWC_5000,
    min_dim = 14.0u"inch",
    max_dim = 36.0u"inch",
    prefer_square = 0.1,
)

opts = NLPColumnOptions(
    aspect_limit = 1.5,
    dim_increment = 2.0u"inch",
)
```

# Fields
## Materials
- `material`: Concrete material (default: NWC_4000)
- `rebar_material`: RebarSteel for longitudinal bars (default: Rebar_60)
- `cover`: Clear cover to ties (default: 1.5" or 38mm)
- `tie_type`: :tied or :spiral (default: :tied)

## Dimension Bounds
- `min_dim`: Minimum column dimension (default: 8" — no ACI code minimum; practical floor from cover+ties+bars)
- `max_dim`: Maximum column dimension (default: 48")
- `dim_increment`: Round final dimensions to this increment (default: 2")
- `aspect_limit`: Maximum aspect ratio max(b,h)/min(b,h) (default: 3.0)
- `prefer_square`: Penalty factor for non-square sections, 0 = no penalty (default: 0.0)

## Design Settings
- `include_slenderness`: Consider moment magnification (default: true)
- `βdns`: Sustained load ratio for slenderness (default: 0.6)
- `bar_size`: Default bar size for reinforcement (default: 8 = #8 bars)

## Solver Settings
- `solver`: Optimization backend :ipopt, :grid, :nlopt (default: :ipopt)
- `objective`: MinVolume(), MinWeight(), MinCost(), MinCarbon() (default: MinVolume())
- `maxiter`: Maximum solver iterations (default: 200)
- `tol`: Convergence tolerance (default: 1e-4)
- `verbose`: Print solver progress (default: false)
"""
Base.@kwdef struct NLPColumnOptions
    # Materials
    material::Concrete = NWC_4000
    rebar_material::RebarSteel = Rebar_60
    cover::Length = 38.1u"mm"           # ≈ 1.5"
    tie_type::Symbol = :tied
    
    # Dimension bounds (no ACI code minimum; 8" is practical floor from cover+ties+bars)
    min_dim::Length = 8.0u"inch"
    max_dim::Length = 48.0u"inch"
    dim_increment::Length = 2.0u"inch"
    aspect_limit::Float64 = 3.0
    prefer_square::Float64 = 0.0
    
    # Design settings
    include_slenderness::Bool = true
    βdns::Float64 = 0.6
    bar_size::Int = 8
    ρ_max::Float64 = 0.06          # Practical max ρg for NLP (ACI allows 0.08, practical ≤ 0.06)
    
    # Solver settings
    solver::Symbol = :ipopt
    objective::AbstractObjective = MinWeight()
    maxiter::Int = 200
    tol::Float64 = 1e-4
    verbose::Bool = false
    n_multistart::Int = 1  # >1 enables multi-start for non-smooth P-M problems

    # Post-processing
    snap::Bool = true   # Round final dimensions to dim_increment
end

"""Compact display for `NLPColumnOptions`."""
function Base.show(io::IO, opts::NLPColumnOptions)
    mat_str = material_name(opts.material)
    min_in = round(Int, ustrip(u"inch", opts.min_dim))
    max_in = round(Int, ustrip(u"inch", opts.max_dim))
    print(io, "NLPColumnOptions(", mat_str)
    print(io, ", dims=", min_in, "\"-", max_in, "\"")
    opts.aspect_limit < 3.0 && print(io, ", aspect≤", opts.aspect_limit)
    opts.prefer_square > 0 && print(io, ", prefer_square")
    !opts.include_slenderness && print(io, ", no_slenderness")
    print(io, ", solver=:", opts.solver, ")")
end

# ==============================================================================
# NLP HSS Column Options (Continuous Steel Optimization)
# ==============================================================================

"""
    NLPHSSOptions

Configuration for continuous (NLP) HSS column sizing using interior point optimization.

Optimizes rectangular HSS dimensions (B, H, t) continuously to find the 
minimum-weight section that satisfies AISC 360 requirements. Uses smooth
approximations of AISC functions for compatibility with automatic differentiation.

# Example
```julia
opts = NLPHSSOptions()

opts = NLPHSSOptions(
    min_outer = 4.0u"inch",
    max_outer = 20.0u"inch",
    min_thickness = 0.125u"inch",
    max_thickness = 0.625u"inch",
)

opts = NLPHSSOptions(prefer_square = 0.2)

opts = NLPHSSOptions(use_ad = true)
```

# Fields
## Material
- `material`: Steel grade (default: A992_Steel)

## Dimension Bounds (for rectangular HSS: B × H × t)
- `min_outer`: Minimum outer dimension B or H (default: 4")
- `max_outer`: Maximum outer dimension B or H (default: 20")
- `min_thickness`: Minimum wall thickness t (default: 1/8" = 0.125")
- `max_thickness`: Maximum wall thickness t (default: 5/8" = 0.625")
- `thickness_increment`: Round thickness to standard sizes (default: 1/16")
- `outer_increment`: Round outer dims to standard sizes (default: 1")

## Design Constraints
- `aspect_limit`: Maximum aspect ratio max(B,H)/min(B,H) (default: 3.0)
- `prefer_square`: Penalty factor for non-square sections (default: 0.0)
- `min_b_t`: Minimum width-to-thickness ratio (default: 5.0)

## Solver Settings
- `solver`: Optimization backend :ipopt, :nlopt (default: :ipopt)
- `use_ad`: Use automatic differentiation for gradients (default: false, uses finite diff)
- `objective`: MinVolume(), MinWeight(), etc. (default: MinWeight())
- `maxiter`: Maximum solver iterations (default: 200)
- `tol`: Convergence tolerance (default: 1e-4)
- `verbose`: Print solver progress (default: false)
- `smooth_k`: Smoothing parameter for differentiable AISC functions (default: 20.0)
"""
Base.@kwdef struct NLPHSSOptions
    # Material
    material::StructuralSteel = A992_Steel
    
    # Dimension bounds (inches internally)
    min_outer::Length = 4.0u"inch"
    max_outer::Length = 20.0u"inch"
    min_thickness::Length = 0.125u"inch"   # 1/8"
    max_thickness::Length = 0.625u"inch"   # 5/8"
    thickness_increment::Length = 0.0625u"inch"  # 1/16"
    outer_increment::Length = 1.0u"inch"
    
    # Design constraints
    aspect_limit::Float64 = 3.0
    prefer_square::Float64 = 0.0
    min_b_t::Float64 = 5.0  # Practical minimum for fabrication
    
    # Solver settings
    solver::Symbol = :ipopt
    use_ad::Bool = false  # Use ForwardDiff for gradients
    objective::AbstractObjective = MinWeight()
    maxiter::Int = 200
    tol::Float64 = 1e-4
    verbose::Bool = false
    smooth_k::Float64 = 20.0  # Smoothing parameter for AISC functions

    # Post-processing
    snap::Bool = true   # Round final dimensions to outer_increment / thickness_increment
end

"""Compact display for `NLPHSSOptions`."""
function Base.show(io::IO, opts::NLPHSSOptions)
    mat_str = material_name(opts.material)
    min_in = round(ustrip(u"inch", opts.min_outer), digits=1)
    max_in = round(ustrip(u"inch", opts.max_outer), digits=1)
    print(io, "NLPHSSOptions(", mat_str)
    print(io, ", outer=", min_in, "\"-", max_in, "\"")
    opts.aspect_limit < 3.0 && print(io, ", aspect≤", opts.aspect_limit)
    opts.prefer_square > 0 && print(io, ", prefer_square")
    opts.use_ad && print(io, ", AD")
    print(io, ", solver=:", opts.solver, ")")
end

# ==============================================================================
# NLP W Section Column Options (Continuous Steel Optimization)
# ==============================================================================

"""
    NLPWOptions

Configuration for continuous (NLP) W section column sizing using interior point optimization.

Optimizes W section dimensions (d, bf, tf, tw) continuously to find the 
minimum-weight section that satisfies AISC 360 requirements. Treats the
section as a parameterized I-shape (similar to a built-up or welded section).

**Note**: Unlike catalog W sections which have fixed proportions, this optimizer
finds optimal dimensions that may not match standard rolled shapes. The result
is a custom continuous section, not a catalog section.

# Example
```julia
opts = NLPWOptions()

opts = NLPWOptions(
    min_depth = 10.0u"inch",
    max_depth = 24.0u"inch",
)

opts = NLPWOptions(max_flange_width = 12.0u"inch")
```

# Design Variables
The optimizer treats the W section as having 4 independent dimensions:
- `d`: Overall depth
- `bf`: Flange width
- `tf`: Flange thickness
- `tw`: Web thickness

# Fields
## Material
- `material`: Steel grade (default: A992_Steel)

## Dimension Bounds
- `min_depth`: Minimum overall depth (default: 8")
- `max_depth`: Maximum overall depth (default: 36")
- `min_flange_width`: Minimum flange width (default: 4")
- `max_flange_width`: Maximum flange width (default: 18")
- `min_flange_thickness`: Minimum flange thickness (default: 0.25")
- `max_flange_thickness`: Maximum flange thickness (default: 2.0")
- `min_web_thickness`: Minimum web thickness (default: 0.25")
- `max_web_thickness`: Maximum web thickness (default: 1.0")

## Proportioning Constraints (typical for rolled shapes)
- `bf_d_min`: Minimum bf/d ratio (default: 0.3)
- `bf_d_max`: Maximum bf/d ratio (default: 1.0)
- `tf_tw_min`: Minimum tf/tw ratio (default: 1.0)
- `tf_tw_max`: Maximum tf/tw ratio (default: 3.0)

## Design Settings
- `require_compact`: Require compact flanges/web for plastic capacity (default: true)

## Solver Settings
- `solver`: Optimization backend :ipopt, :nlopt (default: :ipopt)
- `objective`: MinVolume(), MinWeight(), etc. (default: MinWeight())
- `maxiter`: Maximum solver iterations (default: 200)
- `tol`: Convergence tolerance (default: 1e-4)
- `verbose`: Print solver progress (default: false)
- `smooth_k`: Smoothing parameter for differentiable AISC functions (default: 20.0)
"""
Base.@kwdef struct NLPWOptions
    # Material
    material::StructuralSteel = A992_Steel
    
    # Dimension bounds (inches internally)
    min_depth::Length = 8.0u"inch"
    max_depth::Length = 36.0u"inch"
    min_flange_width::Length = 4.0u"inch"
    max_flange_width::Length = 18.0u"inch"
    min_flange_thickness::Length = 0.25u"inch"
    max_flange_thickness::Length = 2.0u"inch"
    min_web_thickness::Length = 0.25u"inch"
    max_web_thickness::Length = 1.0u"inch"
    
    # Proportioning constraints (typical ranges for rolled W shapes)
    bf_d_min::Float64 = 0.3    # Narrow flange limit
    bf_d_max::Float64 = 1.0    # Wide flange limit
    tf_tw_min::Float64 = 1.0   # Minimum tf/tw
    tf_tw_max::Float64 = 3.0   # Maximum tf/tw
    
    # Design settings
    require_compact::Bool = true    # Require compact for full plastic capacity
    
    # Solver settings
    solver::Symbol = :ipopt
    objective::AbstractObjective = MinWeight()
    maxiter::Int = 200
    tol::Float64 = 1e-4
    verbose::Bool = false
    smooth_k::Float64 = 20.0

    # Post-processing
    snap::Bool = true   # Round final dimensions to 1/16" increments
end

"""
    NLPBeamOptions

Configuration for continuous (NLP) RC beam sizing.

Optimizes beam width (b), depth (h), and reinforcement ratio (ρ) to find the
minimum-area section satisfying ACI 318 flexure and shear requirements.

# Fields
## Materials
- `material`: Concrete material (default: NWC_4000)
- `rebar_material`: RebarSteel for longitudinal bars (default: Rebar_60)
- `cover`: Clear cover to stirrups (default: 1.5")
- `stirrup_size`: Stirrup bar size (default: 3)
- `bar_size`: Longitudinal bar size (default: 8)

## Dimension Bounds
- `min_width`: Minimum beam width (default: 10")
- `max_width`: Maximum beam width (default: 24")
- `min_depth`: Minimum beam depth (default: 12")
- `max_depth`: Maximum beam depth (default: 36")
- `dim_increment`: Round final dimensions to this increment (default: 2")

## Solver Settings
- `solver`: Optimization backend :ipopt, :grid (default: :ipopt)
- `objective`: Optimization objective (default: MinVolume())
- `maxiter`: Maximum solver iterations (default: 200)
- `tol`: Convergence tolerance (default: 1e-4)
- `verbose`: Print solver progress (default: false)

## Post-processing
- `snap`: Round final dimensions to dim_increment (default: true)
"""
Base.@kwdef struct NLPBeamOptions
    # Materials
    material::Concrete = NWC_4000
    rebar_material::RebarSteel = Rebar_60
    cover::Length = 38.1u"mm"           # ≈ 1.5"
    stirrup_size::Int = 3
    bar_size::Int = 8

    # Dimension bounds
    min_width::Length = 10.0u"inch"
    max_width::Length = 24.0u"inch"
    min_depth::Length = 12.0u"inch"
    max_depth::Length = 36.0u"inch"
    dim_increment::Length = 2.0u"inch"

    # Solver settings
    solver::Symbol = :ipopt
    objective::AbstractObjective = MinWeight()
    maxiter::Int = 200
    tol::Float64 = 1e-4
    verbose::Bool = false

    # Post-processing
    snap::Bool = true
end

"""Compact display for `NLPBeamOptions`."""
function Base.show(io::IO, opts::NLPBeamOptions)
    mat_str = material_name(opts.material)
    bmin = round(Int, ustrip(u"inch", opts.min_width))
    bmax = round(Int, ustrip(u"inch", opts.max_width))
    hmin = round(Int, ustrip(u"inch", opts.min_depth))
    hmax = round(Int, ustrip(u"inch", opts.max_depth))
    print(io, "NLPBeamOptions(", mat_str,
          ", b=", bmin, "\"-", bmax, "\"",
          ", h=", hmin, "\"-", hmax, "\"",
          ", solver=:", opts.solver, ")")
end

"""Compact display for `NLPWOptions`."""
function Base.show(io::IO, opts::NLPWOptions)
    mat_str = material_name(opts.material)
    d_min = round(Int, ustrip(u"inch", opts.min_depth))
    d_max = round(Int, ustrip(u"inch", opts.max_depth))
    print(io, "NLPWOptions(", mat_str)
    print(io, ", d=", d_min, "\"-", d_max, "\"")
    !opts.require_compact && print(io, ", allow_noncompact")
    print(io, ", solver=:", opts.solver, ")")
end
