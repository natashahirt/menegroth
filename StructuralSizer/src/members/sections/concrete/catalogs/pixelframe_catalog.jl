# ==============================================================================
# PixelFrame Section Catalog Generator
# ==============================================================================
# Generates a catalog of PixelFrame sections by Cartesian product of the
# design variables, then filters out sections that violate stress/strain
# limits per ACI 318-19.
#
# Supports all three layup types: :Y (3-arm), :X2 (2-arm), :X4 (4-arm).
#
# fR1/fR3 can be supplied explicitly or computed from the regression
# functions fc′_dosage2fR1 / fc′_dosage2fR3 when set to `nothing`.
#
# Reference: Wongsittikan (2024), Table 3.1 and §2.3.1
# ==============================================================================

using Unitful

"""
    generate_pixelframe_catalog(;
        λ_values, L_px_values, t_values, L_c_values,
        fc_values, dosage_values, fR1_values, fR3_values,
        A_s_values, f_pe_values, d_ps_values,
        E_s, f_py, fiber_ecc,
    ) -> Vector{PixelFrameSection}

Generate a catalog of feasible PixelFrame sections.

Creates the Cartesian product of all parameter values, computes capacities,
and filters out sections that violate stress/strain limits (ε_c > 0.003
after convergence).

# Arguments (all vectors of values to sweep)
- `λ_values`: Layup types (default: `[:Y]`). Use `[:Y, :X2, :X4]` for all.
- `L_px_values`: Pixel lengths [mm] (default: [125.0])
- `t_values`: Pixel thicknesses [mm] (default: [30.0])
- `L_c_values`: Curve leg lengths [mm] (default: [30.0])
- `fc_values`: Concrete strengths [MPa] (default: 28:100)
- `dosage_values`: Fiber dosages [kg/m³] (default: [20.0])
- `fR1_values`: Residual fR1 values [MPa]. `nothing` → use regression.
- `fR3_values`: Residual fR3 values [MPa]. `nothing` → use regression.
- `A_s_values`: Tendon areas [mm²] (default: standard strand areas)
- `f_pe_values`: Effective prestress values [MPa] (default: [500.0])
- `d_ps_values`: Tendon eccentricity from centroid [mm] (default: 50:25:250)
- `E_s`: Tendon modulus [MPa] (default: 200_000)
- `f_py`: Tendon yield strength [MPa] (default
  `ustrip(u"MPa", ASTM_A416_GR270_LR_FPY) = 1674`, Grade 270 low-relaxation
  strand per ACI 318-11 R18.7.2). Used **only** as the filter threshold —
  the catalog itself is `f_py`-agnostic, so this controls which sections
  are excluded for failing the ε_c convergence check, not the capacity
  later computed by the checker. Keep it aligned with
  [`PixelFrameChecker`](@ref) `f_py_MPa` to avoid drift between
  "sections in the catalog" and "sections the checker can size".
- `fiber_ecc`: Fiber embodied carbon [kgCO₂e/kg] (default: 1.4)

# Returns
Vector of `PixelFrameSection` that pass all feasibility filters.

# Example
```julia
# Default catalog (thesis Table 3.1 ranges)
catalog = generate_pixelframe_catalog()

# All layup types with regression-based fR values
catalog = generate_pixelframe_catalog(
    λ_values = [:Y, :X2, :X4],
    fc_values = [28.0, 35.0, 42.0, 50.0],
    d_ps_values = [100.0, 150.0, 200.0, 250.0],
    fR1_values = nothing,
    fR3_values = nothing,
)
```
"""
function generate_pixelframe_catalog(;
    λ_values::AbstractVector{Symbol} = [:Y],
    L_px_values::AbstractVector{<:Real} = [125.0],
    t_values::AbstractVector{<:Real} = [30.0],
    L_c_values::AbstractVector{<:Real} = [30.0],
    fc_values::AbstractVector{<:Real} = collect(Float64, 28:100),
    dosage_values::AbstractVector{<:Real} = [20.0],
    fR1_values::Union{Nothing, AbstractVector{<:Real}} = nothing,
    fR3_values::Union{Nothing, AbstractVector{<:Real}} = nothing,
    A_s_values::AbstractVector{<:Real} = [157.0, 226.0, 402.0],  # 2×10mm, 2×12mm, 2×16mm dia
    f_pe_values::AbstractVector{<:Real} = [500.0],
    d_ps_values::AbstractVector{<:Real} = collect(Float64, 50:25:250),
    E_s::Real = 200_000.0,
    # f_py default = ASTM A416 Gr 270 low-relaxation minimum yield, kept in
    # sync with the PixelFrameChecker default (ACI 318-11 R18.7.2).
    f_py::Real = ustrip(u"MPa", ASTM_A416_GR270_LR_FPY),
    fiber_ecc::Real = 1.4,       # kgCO₂e/kg-steel (original Pixelframe.jl value)
)
    catalog = PixelFrameSection[]

    E_s_u = E_s * u"MPa"
    f_py_u = f_py * u"MPa"

    # Whether to use regression for fR1/fR3
    use_regression_fR1 = fR1_values === nothing
    use_regression_fR3 = fR3_values === nothing

    # If explicit fR values are provided, iterate over them;
    # otherwise use a single placeholder that will be replaced by regression
    _fR1_iter = use_regression_fR1 ? [NaN] : fR1_values
    _fR3_iter = use_regression_fR3 ? [NaN] : fR3_values

    for λ in λ_values,
        L_px in L_px_values,
        t in t_values,
        L_c in L_c_values,
        fc in fc_values,
        dosage in dosage_values,
        fR1_val in _fR1_iter,
        fR3_val in _fR3_iter,
        A_s in A_s_values,
        f_pe in f_pe_values,
        d_ps in d_ps_values

        # Compute fR1/fR3 from regression if not supplied
        fR1 = use_regression_fR1 ? fc′_dosage2fR1(fc, dosage) : Float64(fR1_val)
        fR3 = use_regression_fR3 ? fc′_dosage2fR3(fc, dosage) : Float64(fR3_val)

        # Build FRC material
        fc_pa = fc * u"MPa"
        # ACI Ec = 4700√fc′ (MPa) for metric concrete
        E_concrete = 4700.0 * sqrt(fc) * u"MPa"
        ρ = 2400.0u"kg/m^3"
        # ECC from thesis linear fit (Eq. 2.17): ec [kgCO₂e/m³] = 4.57fc′ + 217
        # Convert to per-kg: ec_per_kg = ec_per_m3 / ρ
        ecc_per_kg = (4.57 * fc + 217.0) / 2400.0

        conc = Concrete(E_concrete, fc_pa, ρ, 0.20, ecc_per_kg)
        frc = FiberReinforcedConcrete(conc, Float64(dosage), fR1, fR3;
                                       fiber_ecc=Float64(fiber_ecc))

        sec = PixelFrameSection(;
            λ = λ,
            L_px = Float64(L_px) * u"mm",
            t = Float64(t) * u"mm",
            L_c = Float64(L_c) * u"mm",
            material = frc,
            A_s = Float64(A_s) * u"mm^2",
            f_pe = Float64(f_pe) * u"MPa",
            d_ps = Float64(d_ps) * u"mm",
        )

        # Filter: check flexural convergence (ε_c must converge ≤ 0.003)
        fl = pf_flexural_capacity(sec; E_s=E_s_u, f_py=f_py_u)
        fl.converged || continue

        push!(catalog, sec)
    end

    return catalog
end
