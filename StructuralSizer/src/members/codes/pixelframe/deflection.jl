# ==============================================================================
# PixelFrame Deflection Analysis
# ==============================================================================
# Serviceability deflection check for PixelFrame sections under unfactored
# (service) loads.
#
# Two methods are available, selected via the `method` keyword:
#
# 1. **PFSimplified** (default) — Non-iterative, fast.
#    Uses the modified Branson equation (Ng & Tan 2006):
#      Ie = k³ × Ig + (1 − k³) × Icr,  k = (Mcr − Mdec) / (Ma − Mdec)
#    Deflection: Δ = coeff × w × L⁴ / (Ec × Ie)  (uniform load only)
#
# 2. **PFThirdPointLoad / PFSinglePointLoad** — Full iterative Ng & Tan (2006).
#    Implements the 4-regime deflection model from the Wongsittikan (2024) thesis
#    and the original Pixelframe.jl, with nested convergence loops for:
#      - fps (tendon stress increase due to second-order effects)
#      - Icr (cracked moment of inertia via polygon clipping)
#      - e   (tendon eccentricity update)
#    Regimes: LinearElasticUncracked, LinearElasticCracked, NonlinearCracked
#
# Reference:
#   Wongsittikan (2024) §2.2.4
#   ACI 318-19 §24.2.3.5
#   Ng & Tan (2006) Part I — pseudo-section analysis for EPT beams
#   Original Pixelframe.jl: get_deflection, getΩc, getIe, Properties
# ==============================================================================

using Unitful
using Asap: CompoundSection, OffsetSection, depth_from_area

# ==============================================================================
# Deflection method types (toggle)
# ==============================================================================

"""Abstract supertype for PixelFrame deflection analysis methods."""
abstract type PFDeflectionMethod end

"""
    PFSimplified()

Non-iterative deflection using modified Branson equation + uniform load formula.
Fast and suitable for design-level serviceability checks.
"""
struct PFSimplified <: PFDeflectionMethod end

"""
    PFThirdPointLoad()

Full iterative Ng & Tan (2006) model for two-point (third-point) loading.
Load points at L/3 from each support. Implements all 4 deflection regimes
with nested convergence loops for fps, Icr, and eccentricity.

Reference: Ng & Tan (2006) Part I, Eqs. (2)–(28)
"""
struct PFThirdPointLoad <: PFDeflectionMethod end

"""
    PFSinglePointLoad()

Full iterative Ng & Tan (2006) model for single midspan point load.
Load point at L/2. Same nested convergence as ThirdPointLoad but with
simplified eccentricity (e = em, no update in uncracked regime).

Reference: Ng & Tan (2006) Part I
"""
struct PFSinglePointLoad <: PFDeflectionMethod end

# ==============================================================================
# Deflection regime classification
# ==============================================================================

"""Deflection regime for PixelFrame sections."""
@enum DeflectionRegime begin
    UNCRACKED       # Ma ≤ Mcr → use Ig
    CRACKED         # Ma > Mcr → use Ie (Branson) — simplified model
    LINEAR_ELASTIC_UNCRACKED   # Ng & Tan regime: Ma ≤ Mcr
    LINEAR_ELASTIC_CRACKED     # Ng & Tan regime: Mcr < Ma ≤ Mecl
    NONLINEAR_CRACKED          # Ng & Tan regime: Mecl < Ma ≤ My
end

# ==============================================================================
# Element properties for Ng & Tan model
# ==============================================================================

"""
    pf_element_properties(s, L_mm, Ls_mm, Ld_mm; E_s, f_py) -> NamedTuple

Compute all derived element properties needed by the Ng & Tan deflection model.
This is the equivalent of the original Pixelframe.jl `Properties` struct.

All inputs and outputs are in mm / MPa / N·mm units (bare Float64).

# Arguments
- `s`: PixelFrameSection
- `L_mm`: Element length [mm]
- `Ls_mm`: Distance from support to first load point [mm]
- `Ld_mm`: Distance from support to first deviator [mm]
- `E_s`: Tendon elastic modulus (default 200 GPa)
- `f_py`: Tendon yield strength (default 0.85 × 1900 MPa)

# Returns
NamedTuple with 27 properties matching the original Pixelframe.jl Properties struct.

# Reference
Ng & Tan (2006) Part I, Eqs. (3), (6), (15)
Original Pixelframe.jl: Properties struct
"""
function pf_element_properties(s::PixelFrameSection, L_mm::Real, Ls_mm::Real, Ld_mm::Real;
                                E_s::Pressure = 200.0u"GPa",
                                f_py::Pressure = (0.85 * 1900.0)u"MPa")
    cs = s.section
    fc′_MPa = ustrip(u"MPa", s.material.fc′)
    Ec_MPa  = ustrip(u"MPa", s.material.E)
    Eps_MPa = ustrip(u"MPa", E_s)
    fpy_MPa = ustrip(u"MPa", f_py)
    fr_MPa  = 0.62 * sqrt(fc′_MPa)  # ACI 318-19 §19.2.3.1

    A_s_mm2 = ustrip(u"mm^2", s.A_s)
    f_pe_MPa = ustrip(u"MPa", s.f_pe)
    d_ps_mm = ustrip(u"mm", s.d_ps)

    L  = Float64(L_mm)
    Ls = Float64(Ls_mm)
    Ld = Float64(Ld_mm)

    # em = tendon eccentricity from centroid at midspan [mm]
    # es = tendon eccentricity at support (0 for external PT with straight profile)
    em = max(d_ps_mm, 0.1)  # guard against zero, matching original
    es = 0.0
    em0 = em
    As = 0.0  # no nonprestressed steel in PixelFrame
    Aps = A_s_mm2
    fpe = f_pe_MPa

    # Transformed section properties
    # For PixelFrame: Atr = Ac + (Eps/Ec) × As_nonprestressed = Ac (since As=0)
    area_concrete = cs.area
    area_steel_transformed = Eps_MPa / Ec_MPa * As
    Atr = area_concrete + area_steel_transformed

    centroid_concrete = cs.centroid[2]
    centroid_steel = centroid_concrete - em
    centroid_composite = (area_concrete * centroid_concrete + area_steel_transformed * centroid_steel) / Atr

    # Itr = sum(I + A × d²)
    I_conc = cs.Ix
    d_conc = centroid_composite - centroid_concrete
    d_steel = centroid_composite - centroid_steel
    Itr = I_conc + area_concrete * d_conc^2 + area_steel_transformed * d_steel^2

    # Section moduli
    Zb = Itr / max(centroid_composite - cs.ymin, 1e-6)   # bottom (tension)
    Zt = Itr / max(cs.ymax - centroid_composite, 1e-6)   # top (compression)

    distance_centroid_to_top = Itr / Zt
    dps0 = em + distance_centroid_to_top
    r = sqrt(Itr / Atr)

    θ = atan(em / max(Ls, 1e-6))

    # Self-weight [N/mm]
    w = Atr * 2400.0 * 9.81 / 1e9

    # Moments
    moment_selfweight = w * L^2 / 8.0
    ps_force = Aps * fpe
    moment_decompression = ps_force * em0

    # Strains
    ϵpe = ps_force / Eps_MPa
    ϵce = (ps_force * em / Zb - ps_force * cos(θ) / Atr) / Ec_MPa

    # K1, K2 — Ng & Tan Part I Eqs. (15a), (15b)
    K1 = if Ld < Ls
        Ls / L - 1.0
    else  # Ld ≥ Ls
        Ld / L - 1.0
    end
    K2 = if Ld < Ls
        Ls / Ls * (Ld / L)^2 - (Ls / L)^2
    else
        0.0
    end

    # Ω — bond reduction factor, Ng & Tan Part I Eqs. (6a), (6b)
    Ω = if Ld < Ls
        1.0 - Ls / L + Ld^2 * (es - em) / (3.0 * L * Ls * em)
    else  # Ld ≥ Ls
        1.0 - es / em * Ls / L + (es - em) / em * (Ls^2 / (3.0 * L * Ld) + Ld / L)
    end

    # Cracking moment — Ng & Tan Part I Eq. (3)
    Mcre = Aps * fpe * (em + Zb / Atr) + fr_MPa * Zb
    ΔMcr = Aps * em * (em + Zb / Atr) * (Mcre - moment_selfweight) /
           (1.0 / Ω * Itr * Ec_MPa / Eps_MPa + Aps * (r^2 - em * Zb / Atr))
    Mcr = Mcre + ΔMcr

    # Linear elastic cracked limit
    ϵce_top = (ps_force * em / Zt - ps_force * cos(θ) / Atr) / Ec_MPa
    Mecl = 0.4 * (fc′_MPa + ϵce_top * Ec_MPa) * Zt

    # Yield moment
    My = fpy_MPa * Aps * em

    return (;
        em, es, em0, dps0, L, Ls, Ld, As, Aps, fpe,
        w, θ, Atr, Itr, r, Zb, Zt,
        moment_selfweight, moment_decompression,
        ϵpe, ϵce, Ω,
        Mcr, Mecl, My, K1, K2,
        # Material props needed by deflection routines
        fc′ = fc′_MPa, Ec = Ec_MPa, Eps = Eps_MPa, fpy = fpy_MPa, fr = fr_MPa,
    )
end

# ==============================================================================
# Ωc — cracked stress reduction factor
# ==============================================================================

"""
    _pf_Ωc(Ω, Icr, Lc, props) -> Float64

Cracked bond reduction factor Ωc. 4-branch formula from Ng & Tan (2006) Eq. (21).

# Arguments
- `Ω`: Uncracked bond reduction factor
- `Icr`: Cracked moment of inertia [mm⁴]
- `Lc`: Cracked zone length [mm]
- `props`: Element properties NamedTuple (from `pf_element_properties`)
"""
function _pf_Ωc(Ω::Real, Icr::Real, Lc::Real, props)
    (; em, es, L, Ld, Ls, Itr) = props

    ratio = Icr / Itr

    if Ld < Ls
        if (L - 2.0 * Ls) < Lc < (L - 2.0 * Ld)
            # Eq. (21) branch 1
            return Ω * ratio + (1.0 - ratio) *
                (1.0 - L / (4.0 * Ls) + Lc / (2.0 * Ls) - Lc^2 / (4.0 * L * Ls) - Ls / L)
        elseif Lc >= L - 2.0 * Ld
            # Eq. (21) branch 2
            return Ω * ratio + (1.0 - ratio) *
                (1.0 - Ls / L - Ld^2 / (L * Ls) +
                 (1.0 - es / em) * (L * Lc / (4.0 * Ld * Ls) - Lc^2 / (4.0 * Ld * Ls) +
                                    Lc^3 / (12.0 * L * Ld * Ls) - L^2 / (12.0 * Ld * Ls) +
                                    2.0 * Ld^2 / (3.0 * L * Ls)) +
                 es / em * (Lc / (2.0 * Ls) - L / (4.0 * Ls) - Lc^2 / (4.0 * L * Ls) +
                            Ld^2 / (L * Ls)))
        else
            # Fallback: use uncracked Ω
            return Ω * ratio
        end
    else  # Ld ≥ Ls
        return Ω * ratio + (1.0 - ratio) *
            (1.0 - 2.0 * Ls / L +
             (1.0 - es / em) * (L * Lc / (4.0 * Ld * Ls) - Lc^2 / (4.0 * Ld * Ls) +
                                Lc^3 / (12.0 * L * Ld * Ls) - L^2 / (12.0 * Ld * Ls) +
                                Ld / L - Ls^2 / (3.0 * L * Ld)) +
             es / em * (Lc^2 / (4.0 * L * Ls) - L / (4.0 * Ls) + 2.0 * Ld / L - Ls / L))
    end
end

# ==============================================================================
# Ωc for single-point loading — simplified formula
# ==============================================================================

"""
    _pf_Ωc_single(Ω, Icr, Lc, Itr, L) -> Float64

Simplified cracked bond reduction factor for single-point loading.
From original Pixelframe.jl `get_deflection` (SinglePointLoad + Cracked):
  Ωc = 1/3 × (Icr/Itr + (1 − Icr/Itr) × (Lc/L)³)
"""
function _pf_Ωc_single(Ω::Real, Icr::Real, Lc::Real, Itr::Real, L::Real)
    ratio = Icr / Itr
    return 1.0 / 3.0 * (ratio + (1.0 - ratio) * (Lc / L)^3)
end

# ==============================================================================
# Effective moment of inertia (Ng & Tan Eq. 26)
# ==============================================================================

"""
    _pf_getIe(Mcr, Mdec, M, Icr, Itr) -> Float64

Modified Branson equation for EPT beams (Ng & Tan 2006 Eq. 26).
  k = (Mcr − Mdec) / (M − Mdec)
  Ie = k³ × Itr + (1 − k³) × Icr

Matches original Pixelframe.jl `getIe` exactly.
"""
function _pf_getIe(Mcr::Real, Mdec::Real, M::Real, Icr::Real, Itr::Real)
    denom = M - Mdec
    denom ≤ 0.0 && return Itr
    k = (Mcr - Mdec) / denom
    k3 = k^3
    return clamp(abs(k3 * Itr + (1.0 - k3) * Icr), 0.0, Itr)
end

# ==============================================================================
# Compression depth for cracked regime
# ==============================================================================

"""
    _pf_compression_depth(cs, Aps, fps, fc′) -> Float64

Compute compression depth from force equilibrium (Whitney stress block).
Matches original Pixelframe.jl `get_compression_depth` for PixelFrame elements.
"""
function _pf_compression_depth(cs::CompoundSection, Aps::Real, fps::Real, fc′::Real)
    Ac = cs.area
    A_comp = clamp(Aps * fps / (0.85 * fc′), 0.01, 0.99 * Ac)
    return depth_from_area(cs, 0.99 * A_comp; show_stats=false)
end

# ==============================================================================
# Concrete strain from Hognestad parabola
# ==============================================================================

"""
    _pf_solve_concrete_strain(fc_stress, fc′) -> Float64

Solve the Hognestad parabolic stress-strain relationship for concrete strain ϵce:
  σ = fc′ × (2ϵ/ε₀ − (ϵ/ε₀)²)  with ε₀ = 0.002

This is equivalent to solving: −fc′/0.002² × ϵ² + fc′×2/0.002 × ϵ − fc = 0

The original Pixelframe.jl uses `PolynomialRoots.roots` for this quadratic.
We solve it analytically with the quadratic formula.

Reference: Ng & Tan (2006) Part I, concrete constitutive model
"""
function _pf_solve_concrete_strain(fc_stress::Real, fc′::Real)
    # Quadratic: a×ϵ² + b×ϵ + c = 0
    # Original: roots([-fc, fc′ * 2 / 0.002, -fc′ / 0.002^2])
    # PolynomialRoots uses ascending power order: [c₀, c₁, c₂]
    # So: c₀ = -fc, c₁ = fc′×2/0.002, c₂ = -fc′/0.002²
    # → -fc′/0.002² × ϵ² + fc′×2/0.002 × ϵ - fc = 0
    a = -fc′ / 0.002^2
    b = fc′ * 2.0 / 0.002
    c = -fc_stress

    discriminant = b^2 - 4.0 * a * c
    discriminant < 0.0 && return 0.0  # no real solution

    sqrt_disc = sqrt(discriminant)
    ϵ1 = (-b + sqrt_disc) / (2.0 * a)
    ϵ2 = (-b - sqrt_disc) / (2.0 * a)

    # Return the smaller positive root (ascending branch of Hognestad)
    if ϵ1 > 0.0 && ϵ2 > 0.0
        return min(ϵ1, ϵ2)
    elseif ϵ1 > 0.0
        return ϵ1
    elseif ϵ2 > 0.0
        return ϵ2
    else
        return 0.0
    end
end

# ==============================================================================
# Full Ng & Tan: LinearElasticUncracked + ThirdPointLoad
# ==============================================================================

"""
    _pf_defl_uncracked_third(props, moment) -> (δ, fps, I)

Linear elastic uncracked deflection for third-point loading.
Iterates on fps and eccentricity e until convergence.

Reference: Ng & Tan (2006) Part I, Section 2.1
Original Pixelframe.jl: `get_deflection(::LinearElasticUncracked, ::ThirdPointLoad)`
"""
function _pf_defl_uncracked_third(props, moment::Real)
    (; em, es, L, Ls, Ld, Aps, fpe, Itr, r, Ω, K1, K2) = props
    (; fpy, Ec, Eps) = props

    fps = fpe
    fps_old = fps
    e = 0.0
    max_iter = 100

    for _ in 1:max_iter
        # Eq. (14) — eccentricity update for third-point loading
        e = (em + moment * L^2 / (6.0 * Ec * Itr) * (3.0 * Ld / L * (-K1) - 3.0 / 4.0 - K2)) /
            (1.0 - fps * Aps / (Ec * Itr) * (L^2 / 8.0 - L * Ld / 2.0 + Ld^2 / 2.0))

        # Eq. (2) — tendon stress
        fps = fpe + (Ω * moment * e) / (Itr * Ec / Eps + Aps * (r^2 + e^2) * Ω)
        fps = min(fps, fpy)

        conv = abs(fps_old) > 1e-12 ? abs((fps - fps_old) / fps_old) : 0.0
        conv ≤ 1e-3 && break
        fps_old = fps
    end

    # Eq. (12) — midspan deflection
    δ_neg = fps * Aps / (Ec * Itr) * (e * L^2 / 8.0 - (e - es) * Ld^2 / 6.0)
    δ_pos = moment * L^2 / (6.0 * Ec * Itr) * (3.0 / 4.0 - (Ls / L)^2)
    δ = δ_pos - δ_neg

    return (δ = δ, fps = fps, I = Itr)
end

# ==============================================================================
# Full Ng & Tan: LinearElasticUncracked + SinglePointLoad
# ==============================================================================

"""
    _pf_defl_uncracked_single(props, moment) -> (δ, fps, I)

Linear elastic uncracked deflection for single midspan point load.
Eccentricity stays at em (no second-order update in uncracked regime).

Reference: Ng & Tan (2006) Part I
Original Pixelframe.jl: `get_deflection(::LinearElasticUncracked, ::SinglePointLoad)`
"""
function _pf_defl_uncracked_single(props, moment::Real)
    (; em, es, L, Ls, Ld, Aps, fpe, Itr, r, Ω, K1, K2) = props
    (; fpy, Ec, Eps) = props

    P = 4.0 * moment / L
    fps = fpe
    fps_old = fps
    e = em  # no eccentricity update for single-point uncracked
    max_iter = 100

    for _ in 1:max_iter
        # Eq. (2) — tendon stress (same formula, just e = em constant)
        fps = fpe + (Ω * moment * e) / (Itr * Ec / Eps + Aps * (r^2 + e^2) * Ω)
        fps = min(fps, fpy)

        conv = abs(fps_old) > 1e-12 ? abs((fps - fps_old) / fps_old) : 0.0
        conv ≤ 1e-3 && break
        fps_old = fps
    end

    # Deflection for single midspan point load
    δ = L^2 / (4.0 * Ec * Itr) * (fps * Aps * e / 3.0 - P * L / 4.0)

    return (δ = δ, fps = fps, I = Itr)
end

# ==============================================================================
# Full Ng & Tan: Cracked + ThirdPointLoad
# ==============================================================================

"""
    _pf_defl_cracked_third(s, props, moment) -> (δ, fps, I)

Cracked deflection for third-point loading with nested convergence loops.
Outer loop: fps convergence. Inner loop: Icr convergence.

Reference: Ng & Tan (2006) Part I, Section 2.2
Original Pixelframe.jl: `get_deflection(::Union{LinearElasticCracked, NonlinearCracked}, ::ThirdPointLoad)`
"""
function _pf_defl_cracked_third(s::PixelFrameSection, props, moment::Real)
    (; em, es, dps0, L, Ls, Ld, Aps, Atr, fpe, Itr, r, Zt,
       moment_decompression, Ω, K1, K2, Mcr) = props
    (; fc′, fpy, Ec, Eps) = props
    cs = s.section

    # Initial guesses
    c_old = cs.ymax - cs.centroid[2]
    cracked_section = _get_section_from_depth(cs, c_old)
    Icr_old = OffsetSection(cracked_section, [cracked_section.centroid[1], cracked_section.ymin]).Ix
    Ie = 0.0
    e = 0.0
    fps_old = fpe
    fps_new = fpe
    dps = dps0

    # Cracked zone length — Eq. (20)
    Lc = L - 2.0 * Ls * Mcr / moment
    Lc = min(Lc, L - 2.0 * Ls)  # limit to L − 2Ls

    max_outer = 100
    max_inner = 100
    Ωc = 0.0
    c_new = c_old

    for _ in 1:max_outer
        # Inner loop: Icr convergence
        convergence_Icr = 1.0
        for _ in 1:max_inner
            Ωc = _pf_Ωc(Ω, Icr_old, Lc, props)

            # Compression depth from force equilibrium
            c_new = _pf_compression_depth(cs, Aps, fps_new, fc′)
            cracked_section = _get_section_from_depth(cs, c_new)

            Icr_new = OffsetSection(cracked_section,
                                     [cracked_section.centroid[1], cracked_section.ymin]).Ix

            convergence_Icr = abs(Icr_old) > 1e-12 ? abs(Icr_new - Icr_old) / Icr_old : 0.0
            c_old = c_new
            Icr_old = Icr_new
            convergence_Icr ≤ 1e-3 && break
        end

        # Effective moment of inertia — Eq. (26)
        Ie = _pf_getIe(Mcr, moment_decompression, moment, Icr_old, Itr)

        # Eccentricity update — Eq. (14)
        e = (em + moment * L^2 / (6.0 * Ec * Ie) * (3.0 * Ld / L * (-K1) - 3.0 / 4.0 - K2)) /
            (1.0 - fps_old * Aps / (Ec * Ie) * (L^2 / 8.0 - L * Ld / 2.0 + Ld^2 / 2.0))

        # Tendon depth update — Eq. (28)
        dps = dps0 + moment * L^2 / (6.0 * Ec * Ie) * (3.0 * Ld / L * (-K1) - 3.0 / 4.0 - K2) +
              fps_old * Aps / (Ec * Ie) * e * (L^2 / 8.0 - L * Ld / 2.0 + Ld^2 / 2.0)

        # Concrete strain from Hognestad parabola — Eq. (23)
        ps_force = Aps * fps_old
        ϵpe = ps_force / Eps
        fc = ps_force * e / Zt - ps_force / Atr
        ϵce = _pf_solve_concrete_strain(fc, fc′)

        # Tendon stress update — Eq. (19)
        fps_new = Eps * (ϵpe + Ωc * ϵce) + Ωc * ϵce * Eps * (dps / max(c_new, 1e-6) - 1.0)
        fps_new = min(fps_new, fpy)

        convergence_fps = abs(fps_old) > 1e-12 ? abs(fps_new - fps_old) / fps_old : 0.0
        fps_old = fps_new
        convergence_fps ≤ 1e-3 && break
    end

    # Midspan deflection — Eq. (25)
    δ = moment * L^2 / (6.0 * Ec * Ie) * (3.0 / 4.0 - (Ls / L)^2) -
        fps_new * Aps / (Ec * Ie) * (e * L^2 / 8.0 - (e - es) * Ld^2 / 6.0)

    return (δ = δ, fps = fps_new, I = Ie)
end

# ==============================================================================
# Full Ng & Tan: Cracked + SinglePointLoad
# ==============================================================================

"""
    _pf_defl_cracked_single(s, props, moment) -> (δ, fps, I)

Cracked deflection for single midspan point load with nested convergence loops.

Reference: Ng & Tan (2006) Part I
Original Pixelframe.jl: `get_deflection(::Union{LinearElasticCracked, NonlinearCracked}, ::SinglePointLoad)`
"""
function _pf_defl_cracked_single(s::PixelFrameSection, props, moment::Real)
    (; em, es, dps0, L, Ls, Ld, Aps, Atr, fpe, Itr, r, Zt,
       moment_decompression, Ω, K1, K2, Mcr) = props
    (; fc′, fpy, Ec, Eps) = props
    cs = s.section

    P = 4.0 * moment / L

    # Initial guesses
    c_old = cs.ymax - cs.centroid[2]
    cracked_section = _get_section_from_depth(cs, c_old)
    Icr_old = OffsetSection(cracked_section, [cracked_section.centroid[1], cracked_section.ymin]).Ix
    Ie = 0.0
    e = 0.0
    fps_old = fpe
    fps_new = fpe
    dps = dps0

    # Cracked zone length — Eq. (20)
    Lc = L - 2.0 * Ls * Mcr / moment
    Lc = min(Lc, L - 2.0 * Ls)

    max_outer = 100
    max_inner = 100
    Ωc = 0.0
    c_new = c_old

    for _ in 1:max_outer
        # Inner loop: Icr convergence
        convergence_Icr = 1.0
        for _ in 1:max_inner
            # Simplified Ωc for single-point load
            Ωc = _pf_Ωc_single(Ω, Icr_old, Lc, Itr, L)

            c_new = _pf_compression_depth(cs, Aps, fps_new, fc′)
            cracked_section = _get_section_from_depth(cs, c_new)

            Icr_new = OffsetSection(cracked_section,
                                     [cracked_section.centroid[1], cracked_section.ymin]).Ix

            convergence_Icr = abs(Icr_old) > 1e-12 ? abs(Icr_new - Icr_old) / Icr_old : 0.0
            c_old = c_new
            Icr_old = Icr_new
            convergence_Icr ≤ 1e-3 && break
        end

        # Effective moment of inertia — Eq. (26)
        Ie = _pf_getIe(Mcr, moment_decompression, moment, Icr_old, Itr)

        # Eccentricity update
        e = (em + moment * L^2 / (6.0 * Ec * Ie) * (3.0 * Ld / L * (-K1) - 3.0 / 4.0 - K2)) /
            (1.0 - fps_old * Aps / (Ec * Ie) * (L^2 / 8.0 - L * Ld / 2.0 + Ld^2 / 2.0))

        # Tendon depth update
        dps = dps0 + moment * L^2 / (6.0 * Ec * Ie) * (3.0 * Ld / L * (-K1) - 3.0 / 4.0 - K2) +
              fps_old * Aps / (Ec * Ie) * e * (L^2 / 8.0 - L * Ld / 2.0 + Ld^2 / 2.0)

        # Concrete strain from Hognestad parabola
        ps_force = Aps * fps_old
        ϵpe = ps_force / Eps
        fc = ps_force * e / Zt - ps_force / Atr
        ϵce = _pf_solve_concrete_strain(fc, fc′)

        # Tendon stress update
        fps_new = Eps * (ϵpe + Ωc * ϵce) + Ωc * ϵce * Eps * (dps / max(c_new, 1e-6) - 1.0)
        fps_new = min(fps_new, fpy)

        convergence_fps = abs(fps_old) > 1e-12 ? abs(fps_new - fps_old) / fps_old : 0.0
        fps_old = fps_new
        convergence_fps ≤ 1e-3 && break
    end

    # Midspan deflection for single point load
    δ = L^2 / (4.0 * Ec * Ie) * (fps_new * Aps * e / 3.0 - P * L / 4.0)

    return (δ = δ, fps = fps_new, I = Ie)
end

# ==============================================================================
# Full Ng & Tan: top-level dispatcher
# ==============================================================================

"""
    _pf_ng_tan_deflection(s, props, moment, method) -> NamedTuple

Dispatch to the correct Ng & Tan deflection regime based on moment level.

Regimes (Ng & Tan 2006 Part I):
  1. LinearElasticUncracked: Ma ≤ Mcr  — iterate on fps only
  2. LinearElasticCracked:   Mcr < Ma ≤ Mecl — nested fps + Icr loops
  3. NonlinearCracked:       Mecl < Ma ≤ My  — same as (2)
  4. Beyond My:              Ma > My → returns Inf (failure)
"""
function _pf_ng_tan_deflection(s::PixelFrameSection, props, moment::Real,
                                method::PFThirdPointLoad)
    (; Mcr, Mecl, My) = props

    if moment ≤ 0.0
        return (δ = 0.0, fps = props.fpe, I = props.Itr,
                regime = LINEAR_ELASTIC_UNCRACKED)
    end

    if moment ≤ Mcr
        result = _pf_defl_uncracked_third(props, moment)
        return (result..., regime = LINEAR_ELASTIC_UNCRACKED)
    elseif moment ≤ My
        # Both LinearElasticCracked and NonlinearCracked use the same code
        result = _pf_defl_cracked_third(s, props, moment)
        regime = moment ≤ Mecl ? LINEAR_ELASTIC_CRACKED : NONLINEAR_CRACKED
        return (result..., regime = regime)
    else
        # Beyond yield — return Inf
        return (δ = Inf, fps = props.fpy, I = 0.0,
                regime = NONLINEAR_CRACKED)
    end
end

"""Ng & Tan regime dispatcher for single midspan point loading."""
function _pf_ng_tan_deflection(s::PixelFrameSection, props, moment::Real,
                                method::PFSinglePointLoad)
    (; Mcr, Mecl, My) = props

    if moment ≤ 0.0
        return (δ = 0.0, fps = props.fpe, I = props.Itr,
                regime = LINEAR_ELASTIC_UNCRACKED)
    end

    if moment ≤ Mcr
        result = _pf_defl_uncracked_single(props, moment)
        return (result..., regime = LINEAR_ELASTIC_UNCRACKED)
    elseif moment ≤ My
        result = _pf_defl_cracked_single(s, props, moment)
        regime = moment ≤ Mecl ? LINEAR_ELASTIC_CRACKED : NONLINEAR_CRACKED
        return (result..., regime = regime)
    else
        return (δ = Inf, fps = props.fpy, I = 0.0,
                regime = NONLINEAR_CRACKED)
    end
end

# ==============================================================================
# Deflection curve (research / validation)
# ==============================================================================

"""
    pf_deflection_curve(s, L, max_moment; method, n_samples, E_s, f_py) -> NamedTuple

Compute deflection at `n_samples` moment steps from 0 to `max_moment`.
Returns vectors of (moments, deflections, fps, I) for plotting moment-deflection curves.

This is the equivalent of the original Pixelframe.jl `get_deflection_curve`.

# Arguments
- `s`: PixelFrameSection
- `L`: Span length (Unitful)
- `max_moment`: Maximum applied moment (Unitful)
- `method`: `PFThirdPointLoad()` or `PFSinglePointLoad()` (default: `PFThirdPointLoad()`)
- `n_samples`: Number of sample points (default 100)
- `E_s`: Tendon elastic modulus (default 200 GPa)
- `f_py`: Tendon yield strength (default 0.85 × 1900 MPa)

# Returns
NamedTuple with:
- `moments_Nmm`: Vector of moments [N·mm]
- `deflections_mm`: Vector of midspan deflections [mm]
- `fps_MPa`: Vector of tendon stresses [MPa]
- `I_mm4`: Vector of effective moments of inertia [mm⁴]
- `regimes`: Vector of `DeflectionRegime`
"""
function pf_deflection_curve(s::PixelFrameSection, L, max_moment;
                              method::Union{PFThirdPointLoad, PFSinglePointLoad} = PFThirdPointLoad(),
                              n_samples::Int = 100,
                              E_s::Pressure = 200.0u"GPa",
                              f_py::Pressure = (0.85 * 1900.0)u"MPa")
    L_mm = ustrip(u"mm", L)
    M_max_Nmm = ustrip(u"N*mm", max_moment)

    # Load offsets depend on method
    Ls_mm, Ld_mm = if method isa PFThirdPointLoad
        L_mm / 3.0, L_mm / 3.0
    else
        L_mm / 2.0, L_mm / 2.0
    end

    props = pf_element_properties(s, L_mm, Ls_mm, Ld_mm; E_s, f_py)

    step = M_max_Nmm / (n_samples - 1)
    moments = [i * step for i in 0:(n_samples - 1)]

    deflections = Vector{Float64}(undef, n_samples)
    fps_vec = Vector{Float64}(undef, n_samples)
    I_vec = Vector{Float64}(undef, n_samples)
    regimes = Vector{DeflectionRegime}(undef, n_samples)

    for (i, M) in enumerate(moments)
        result = _pf_ng_tan_deflection(s, props, M, method)
        deflections[i] = result.δ
        fps_vec[i] = result.fps
        I_vec[i] = result.I
        regimes[i] = result.regime
    end

    return (;
        moments_Nmm = moments,
        deflections_mm = deflections,
        fps_MPa = fps_vec,
        I_mm4 = I_vec,
        regimes,
    )
end

# ==============================================================================
# Core simplified model (existing — unchanged)
# ==============================================================================

"""
    pf_cracking_moment(s::PixelFrameSection) -> NamedTuple

Cracking moment and decompression moment of a PixelFrame section.

# Returns
Named tuple with:
- `Mcr`: Cracking moment [N·mm → Unitful]
- `Mdec`: Decompression moment [N·mm → Unitful]
- `fr`: Modulus of rupture [MPa → Unitful]
- `σ_cp`: Average compressive prestress [MPa → Unitful]

# Decompression moment
For externally post-tensioned beams, the decompression moment is the applied
moment at which the bottom fiber stress reaches zero (prestress fully cancelled):
  Mdec = f_pe × A_ps × e_m
where e_m = d_ps (tendon eccentricity from centroid).

This is used in the modified Branson equation for EPT beams (Ng & Tan 2006):
  k = (Mcr − Mdec) / (Ma − Mdec)
  Ie = k³ × Ig + (1 − k³) × Icr

# Reference
ACI 318-19 §24.2.3.5 (prestressed members)
Ng & Tan (2006) — pseudo-section analysis for EPT beams
Original Pixelframe.jl: `getIe`, `moment_decompression`
"""
function pf_cracking_moment(s::PixelFrameSection)
    cs = s.section  # CompoundSection (mm units)
    fc′_MPa = ustrip(u"MPa", s.material.fc′)

    # Modulus of rupture — ACI 318-19 §19.2.3.1 (metric)
    fr_MPa = 0.62 * sqrt(fc′_MPa)

    # Average compressive prestress from external PT
    A_g_mm2 = cs.area
    A_s_mm2 = ustrip(u"mm^2", s.A_s)
    f_pe_MPa = ustrip(u"MPa", s.f_pe)
    σ_cp_MPa = f_pe_MPa * A_s_mm2 / A_g_mm2

    # Bottom section modulus: Sb = Ig / y_bot
    Ig_mm4 = cs.Ix  # mm⁴ (from polygon)
    y_bot = cs.centroid[2] - cs.ymin  # distance from centroid to bottom fiber
    y_bot = max(y_bot, 1e-6)  # guard against zero
    Sb_mm3 = Ig_mm4 / y_bot

    # Cracking moment: Mcr = Sb × (fr + σ_cp)
    Mcr_Nmm = Sb_mm3 * (fr_MPa + σ_cp_MPa)

    # Decompression moment: Mdec = f_pe × A_ps × e_m
    # where e_m = d_ps (tendon eccentricity from centroid), in mm
    d_ps_mm = ustrip(u"mm", s.d_ps)
    Mdec_Nmm = f_pe_MPa * A_s_mm2 * d_ps_mm  # [MPa × mm² × mm = N·mm]

    return (;
        Mcr = Mcr_Nmm * u"N*mm",
        Mdec = Mdec_Nmm * u"N*mm",
        fr = fr_MPa * u"MPa",
        σ_cp = σ_cp_MPa * u"MPa",
    )
end

"""
    pf_cracked_moment_of_inertia(s::PixelFrameSection; E_s, f_py) -> Float64

Cracked moment of inertia Icr for a PixelFrame section [mm⁴].

Uses the polygon-clipping + `OffsetSection` approach from the original
Pixelframe.jl to accurately handle the non-rectangular Y/X2/X4 geometry.

# Reference
Original Pixelframe.jl `get_I_crack`:
  `OffsetSection(cracked_section, [cracked_section.centroid[1], cracked_section.ymin]).Ix`
"""
function pf_cracked_moment_of_inertia(s::PixelFrameSection;
                                       E_s::Pressure = 200.0u"GPa",
                                       f_py::Pressure = (0.85 * 1900.0)u"MPa")
    cs = s.section
    fc′_MPa = ustrip(u"MPa", s.material.fc′)
    Ec_MPa = ustrip(u"MPa", s.material.E)
    Es_MPa = ustrip(u"MPa", E_s)
    A_s_mm2 = ustrip(u"mm^2", s.A_s)
    f_pe_MPa = ustrip(u"MPa", s.f_pe)
    f_py_MPa = ustrip(u"MPa", f_py)
    A_g_mm2 = cs.area

    # Modular ratio
    n_ps = Es_MPa / Ec_MPa

    # d_ps from top fiber
    centroid_to_top = cs.ymax - cs.centroid[2]
    d_ps_mm = ustrip(u"mm", s.d_ps)
    dps_from_top = centroid_to_top + d_ps_mm

    # Estimate tendon stress at cracking (ACI 318-19 Table 20.3.2.4.1)
    if f_pe_MPa ≈ 0.0 || A_s_mm2 ≈ 0.0
        return cs.Ix
    end
    ρ = A_s_mm2 / A_g_mm2
    f_ps_MPa = min(
        f_pe_MPa + 70.0 + fc′_MPa / (100.0 * ρ),
        f_pe_MPa + 420.0,
        f_py_MPa,
    )

    # Compression area from force equilibrium (Whitney stress block)
    A_comp = clamp(A_s_mm2 * f_ps_MPa / (0.85 * fc′_MPa), 0.01, 0.99 * A_g_mm2)

    # Find compression depth from polygon geometry
    compression_depth = depth_from_area(cs, A_comp; show_stats=false)

    # Clip the polygon at the compression depth → cracked section
    cracked_section = _get_section_from_depth(cs, compression_depth)

    # Icr of concrete about the neutral axis (bottom of compression zone)
    offset = OffsetSection(cracked_section,
                           [cracked_section.centroid[1], cracked_section.ymin])
    Icr_concrete = offset.Ix

    # Add transformed tendon contribution about the neutral axis
    d_tendon_from_NA = dps_from_top - compression_depth
    Icr_tendon = n_ps * A_s_mm2 * d_tendon_from_NA^2

    return Icr_concrete + Icr_tendon
end

"""
    pf_effective_Ie(s::PixelFrameSection, Ma; E_s) -> NamedTuple

Effective moment of inertia using the modified Branson equation for
externally post-tensioned beams (Ng & Tan 2006).

# Reference
Ng & Tan (2006) — pseudo-section analysis for EPT beams
Original Pixelframe.jl: `getIe`
"""
function pf_effective_Ie(s::PixelFrameSection, Ma;
                          E_s::Pressure = 200.0u"GPa")
    cr = pf_cracking_moment(s)
    Mcr = cr.Mcr
    Mdec = cr.Mdec

    Ma_Nmm = ustrip(u"N*mm", Ma)
    Mcr_Nmm = ustrip(u"N*mm", Mcr)
    Mdec_Nmm = ustrip(u"N*mm", Mdec)

    Ig = s.section.Ix  # mm⁴

    if Ma_Nmm ≤ Mcr_Nmm || Ma_Nmm ≤ 0.0
        return (;
            Ie = Ig * u"mm^4",
            Ig,
            Icr = Ig,
            Mcr,
            Mdec,
            regime = UNCRACKED,
        )
    end

    Icr = pf_cracked_moment_of_inertia(s; E_s)

    # Modified Branson equation for EPT beams (Ng & Tan 2006)
    denom = Ma_Nmm - Mdec_Nmm
    if denom ≤ 0.0
        return (;
            Ie = Ig * u"mm^4",
            Ig,
            Icr,
            Mcr,
            Mdec,
            regime = UNCRACKED,
        )
    end

    k = (Mcr_Nmm - Mdec_Nmm) / denom
    k = clamp(k, 0.0, 1.0)
    k3 = k^3
    Ie = k3 * Ig + (1.0 - k3) * Icr
    Ie = clamp(abs(Ie), 0.0, Ig)

    return (;
        Ie = Ie * u"mm^4",
        Ig,
        Icr,
        Mcr,
        Mdec,
        regime = CRACKED,
    )
end

# ==============================================================================
# Deflection computation — unified API with method toggle
# ==============================================================================

"""
    pf_deflection(s, L, w_or_M; method, E_s, f_py, support) -> NamedTuple

Compute midspan deflection of a PixelFrame beam under service loads.

# Method toggle
- `method = PFSimplified()` (default): Non-iterative, uniform load only.
  `w_or_M` is interpreted as **uniform load** (force/length, e.g. kN/m).
  Uses modified Branson equation + Δ = coeff × w × L⁴ / (Ec × Ie).

- `method = PFThirdPointLoad()`: Full Ng & Tan iterative model, third-point loading.
  `w_or_M` is interpreted as **midspan moment** (force×length, e.g. kN·m).
  Iterates on fps, Icr, and eccentricity. 4 deflection regimes.

- `method = PFSinglePointLoad()`: Full Ng & Tan iterative model, single midspan load.
  `w_or_M` is interpreted as **midspan moment** (force×length, e.g. kN·m).

# Returns
Named tuple with:
- `Δ`: Midspan deflection [mm → Unitful]
- `L_over_Δ`: Span-to-deflection ratio (dimensionless)
- `regime`: Deflection regime enum
- Additional fields depend on method (fps, Ie, etc.)

# Reference
ACI 318-19 §24.2.3.5
Ng & Tan (2006) Part I — pseudo-section analysis for EPT beams
"""
function pf_deflection(s::PixelFrameSection, L, w_or_M;
                        method::PFDeflectionMethod = PFSimplified(),
                        E_s::Pressure = 200.0u"GPa",
                        f_py::Pressure = (0.85 * 1900.0)u"MPa",
                        support::Symbol = :simply_supported)
    return _pf_deflection_dispatch(s, L, w_or_M, method; E_s, f_py, support)
end

# -- Simplified (existing behavior) --

"""Simplified deflection dispatch: uniform load → modified Branson Ie → Δ = coeff × w × L⁴ / (Ec × Ie)."""
function _pf_deflection_dispatch(s::PixelFrameSection, L, w_service, ::PFSimplified;
                                  E_s, f_py, support)
    L_mm = ustrip(u"mm", L)
    Ec_MPa = ustrip(u"MPa", s.material.E)

    Ma = _pf_service_moment(w_service, L, support)
    ie_result = pf_effective_Ie(s, Ma; E_s)
    Ie_mm4 = ustrip(u"mm^4", ie_result.Ie)

    coeff = _deflection_coefficient(support)
    w_Nmm = ustrip(u"N/mm", w_service)
    Δ_mm = coeff * w_Nmm * L_mm^4 / (Ec_MPa * Ie_mm4)
    L_over_Δ = Δ_mm > 1e-10 ? L_mm / Δ_mm : Inf

    return (;
        Δ = Δ_mm * u"mm",
        Ie = ie_result.Ie,
        Mcr = ie_result.Mcr,
        Ma,
        regime = ie_result.regime,
        L_over_Δ,
    )
end

# -- Ng & Tan (ThirdPointLoad / SinglePointLoad) --

"""Ng & Tan deflection dispatch: moment input → full iterative model with regime classification."""
function _pf_deflection_dispatch(s::PixelFrameSection, L, Ma_moment,
                                  method::Union{PFThirdPointLoad, PFSinglePointLoad};
                                  E_s, f_py, support)
    L_mm = ustrip(u"mm", L)
    Ma_Nmm = ustrip(u"N*mm", Ma_moment)

    # Load offsets depend on method
    Ls_mm, Ld_mm = if method isa PFThirdPointLoad
        L_mm / 3.0, L_mm / 3.0
    else
        L_mm / 2.0, L_mm / 2.0
    end

    props = pf_element_properties(s, L_mm, Ls_mm, Ld_mm; E_s, f_py)
    result = _pf_ng_tan_deflection(s, props, Ma_Nmm, method)

    Δ_mm = result.δ
    L_over_Δ = abs(Δ_mm) > 1e-10 ? L_mm / abs(Δ_mm) : Inf

    return (;
        Δ = Δ_mm * u"mm",
        fps = result.fps * u"MPa",
        Ie = result.I * u"mm^4",
        Ma = Ma_moment,
        regime = result.regime,
        L_over_Δ,
        # Ng & Tan properties for inspection
        Mcr = props.Mcr * u"N*mm",
        Mecl = props.Mecl * u"N*mm",
        My = props.My * u"N*mm",
        Ω = props.Ω,
    )
end

# ==============================================================================
# Serviceability check — unified API with method toggle
# ==============================================================================

"""
    pf_check_deflection(s, L, w_dead, w_live; method, E_s, f_py, support, ...) -> NamedTuple

Full deflection serviceability check for a PixelFrame beam.

# Method toggle
- `method = PFSimplified()` (default): Uses uniform load deflection formula.
- `method = PFThirdPointLoad()` or `PFSinglePointLoad()`: Uses full Ng & Tan model.
  For point-load methods, the uniform loads are converted to equivalent midspan moments:
    Ma = w × L² / 8  (simply supported)

# Reference
ACI 318-19 §24.2.3.5, Table 24.2.2
"""
function pf_check_deflection(s::PixelFrameSection, L, w_dead, w_live;
                              method::PFDeflectionMethod = PFSimplified(),
                              E_s::Pressure = 200.0u"GPa",
                              f_py::Pressure = (0.85 * 1900.0)u"MPa",
                              support::Symbol = :simply_supported,
                              limit_ll::Real = 360,
                              limit_total::Real = 240,
                              ξ::Real = 2.0)
    return _pf_check_dispatch(s, L, w_dead, w_live, method;
                               E_s, f_py, support, limit_ll, limit_total, ξ)
end

# -- Simplified --

"""Simplified serviceability check dispatch using uniform load deflection formula."""
function _pf_check_dispatch(s, L, w_dead, w_live, ::PFSimplified;
                             E_s, f_py, support, limit_ll, limit_total, ξ)
    result_D = pf_deflection(s, L, w_dead; method=PFSimplified(), E_s, support)
    w_total = w_dead + w_live
    result_DL = pf_deflection(s, L, w_total; method=PFSimplified(), E_s, support)

    Δ_D_mm = ustrip(u"mm", result_D.Δ)
    Δ_DL_mm = ustrip(u"mm", result_DL.Δ)
    Δ_LL_mm = max(Δ_DL_mm - Δ_D_mm, 0.0)

    λ_Δ = Float64(ξ)
    Δ_LT_mm = λ_Δ * Δ_D_mm
    Δ_total_mm = Δ_LT_mm + Δ_LL_mm

    L_mm = ustrip(u"mm", L)
    limit_ll_mm = L_mm / Float64(limit_ll)
    limit_total_mm = L_mm / Float64(limit_total)

    passes_ll = Δ_LL_mm ≤ limit_ll_mm
    passes_total = Δ_total_mm ≤ limit_total_mm

    return (;
        Δ_D = Δ_D_mm * u"mm",
        Δ_DL = Δ_DL_mm * u"mm",
        Δ_LL = Δ_LL_mm * u"mm",
        Δ_LT = Δ_LT_mm * u"mm",
        Δ_total = Δ_total_mm * u"mm",
        limit_ll_mm,
        limit_total_mm,
        passes_ll,
        passes_total,
        passes = passes_ll && passes_total,
        regime_D = result_D.regime,
        regime_DL = result_DL.regime,
    )
end

# -- Ng & Tan --

"""Ng & Tan serviceability check dispatch converting uniform loads to equivalent midspan moments."""
function _pf_check_dispatch(s, L, w_dead, w_live,
                             method::Union{PFThirdPointLoad, PFSinglePointLoad};
                             E_s, f_py, support, limit_ll, limit_total, ξ)
    # Convert uniform loads to equivalent midspan moments
    Ma_D = _pf_service_moment(w_dead, L, support)
    Ma_DL = _pf_service_moment(w_dead + w_live, L, support)

    result_D = pf_deflection(s, L, Ma_D; method, E_s, f_py, support)
    result_DL = pf_deflection(s, L, Ma_DL; method, E_s, f_py, support)

    Δ_D_mm = ustrip(u"mm", result_D.Δ)
    Δ_DL_mm = ustrip(u"mm", result_DL.Δ)
    Δ_LL_mm = max(abs(Δ_DL_mm) - abs(Δ_D_mm), 0.0)

    λ_Δ = Float64(ξ)
    Δ_LT_mm = λ_Δ * abs(Δ_D_mm)
    Δ_total_mm = Δ_LT_mm + Δ_LL_mm

    L_mm = ustrip(u"mm", L)
    limit_ll_mm = L_mm / Float64(limit_ll)
    limit_total_mm = L_mm / Float64(limit_total)

    passes_ll = Δ_LL_mm ≤ limit_ll_mm
    passes_total = Δ_total_mm ≤ limit_total_mm

    return (;
        Δ_D = abs(Δ_D_mm) * u"mm",
        Δ_DL = abs(Δ_DL_mm) * u"mm",
        Δ_LL = Δ_LL_mm * u"mm",
        Δ_LT = Δ_LT_mm * u"mm",
        Δ_total = Δ_total_mm * u"mm",
        limit_ll_mm,
        limit_total_mm,
        passes_ll,
        passes_total,
        passes = passes_ll && passes_total,
        regime_D = result_D.regime,
        regime_DL = result_DL.regime,
        fps_D = result_D.fps,
        fps_DL = result_DL.fps,
    )
end

# ==============================================================================
# Internal helpers
# ==============================================================================

"""Service moment at midspan for uniform load."""
function _pf_service_moment(w, L, support::Symbol)
    w_Nmm = ustrip(u"N/mm", w)
    L_mm = ustrip(u"mm", L)

    Ma_Nmm = if support === :simply_supported
        w_Nmm * L_mm^2 / 8.0
    elseif support === :cantilever
        w_Nmm * L_mm^2 / 2.0
    elseif support === :fixed_fixed
        w_Nmm * L_mm^2 / 24.0
    else
        error("Unknown support condition: $support. Use :simply_supported, :cantilever, or :fixed_fixed")
    end

    return Ma_Nmm * u"N*mm"
end

"""Deflection coefficient for Δ = coeff × w × L⁴ / (Ec × Ie)."""
function _deflection_coefficient(support::Symbol)
    if support === :simply_supported
        return 5.0 / 384.0
    elseif support === :cantilever
        return 1.0 / 8.0
    elseif support === :fixed_fixed
        return 1.0 / 384.0
    else
        error("Unknown support condition: $support")
    end
end
