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
    time_limit_sec::Real = 30.0  # MIP solver time limit
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
    time_limit_sec::Real = 30.0  # MIP solver time limit
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

