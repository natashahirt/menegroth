# ==============================================================================
# ACI 318-11 Beam Torsion Design (§11.5)
# ==============================================================================
#
# Design philosophy (thin-walled tube / space truss analogy):
#   - After cracking, torsional resistance is modeled as a thin-walled tube
#   - Concrete tensile strength is neglected for design (post-cracking)
#   - Closed stirrups resist torsional shear
#   - Longitudinal bars resist the diagonal tension component
#
# Key ACI sections:
#   11.5.1   - Threshold torsion (can be neglected)
#   11.5.2   - Cracking torsion (compatibility cap)
#   11.5.3.1 - Cross-section adequacy (shear-torsion interaction)
#   11.5.3   - Transverse reinforcement for torsion
#   11.5.3.7 - Longitudinal reinforcement for torsion
#   11.5.3.8 - Combined shear + torsion transverse reinforcement
#   11.5.5   - Minimum torsion reinforcement
#
# Torsion modes:
#   :compatibility — Torque can be capped at φ·Tcr with redistribution
#                    (typical for floor beams, spandrels)
#   :equilibrium   — Full factored Tu must be resisted (no redistribution)
#                    (required when torsion is needed for static equilibrium)
#
# Reference: ACI 445.1R-12, Design Example 1 (rectangular beam, pure torsion)
# ==============================================================================

using Unitful
using Asap: kip, ksi, psf, ksf, pcf

# ==============================================================================
# Section Properties for Torsion
# ==============================================================================

"""
    torsion_section_properties(b, h, cover_to_stirrup_ctr) -> NamedTuple

Compute torsion-related section properties for a rectangular beam.

# Arguments
- `b`: Beam width (or web width bw)
- `h`: Total depth
- `cover_to_stirrup_ctr`: Distance from exterior face to stirrup centerline

# Returns
Named tuple with:
- `Acp`: Area enclosed by outside perimeter [in²]
- `pcp`: Outside perimeter [in]
- `Aoh`: Area enclosed by stirrup centerline [in²]
- `ph`: Perimeter of stirrup centerline [in]
- `Ao`: Gross area enclosed by shear flow path (= 0.85 Aoh) [in²]

# Reference
- ACI 318-11 §11.5.1, §11.5.3
- ACI 445.1R-12 Example 1: b=12", h=20", c_ℓ=1.5" → Aoh=153 in², ph=50.4 in
"""
function torsion_section_properties(b::Length, h::Length, cover_to_stirrup_ctr::Length)
    b_in = ustrip(u"inch", b)
    h_in = ustrip(u"inch", h)
    c_in = ustrip(u"inch", cover_to_stirrup_ctr)

    Acp = b_in * h_in
    pcp = 2 * (b_in + h_in)

    xo = b_in - 2 * c_in
    yo = h_in - 2 * c_in
    Aoh = xo * yo
    ph  = 2 * (xo + yo)
    Ao  = 0.85 * Aoh

    return (Acp=Acp, pcp=pcp, Aoh=Aoh, ph=ph, Ao=Ao)
end

"""
    torsion_section_properties_tbeam(bw, h, bf, hf, cover_to_stirrup_ctr) -> NamedTuple

Compute torsion-related section properties for a T-beam.

Per ACI 318-11 §11.5.1.1(a), the overhanging flange width used in computing
Acp and pcp shall not exceed the projection of the beam above or below the slab.

# Arguments
- `bw`: Web width
- `h`: Total depth
- `bf`: Effective flange width (for flexure; may be reduced for torsion)
- `hf`: Flange (slab) thickness
- `cover_to_stirrup_ctr`: Distance from exterior face to stirrup centerline

# Notes
- Aoh, ph are based on the web rectangle only (closed stirrups in web)
- Acp, pcp include the limited flange overhang per ACI 318-11 §11.5.1.1
"""
function torsion_section_properties_tbeam(
    bw::Length, h::Length, bf::Length, hf::Length,
    cover_to_stirrup_ctr::Length,
)
    bw_in = ustrip(u"inch", bw)
    h_in  = ustrip(u"inch", h)
    bf_in = ustrip(u"inch", bf)
    hf_in = ustrip(u"inch", hf)
    c_in  = ustrip(u"inch", cover_to_stirrup_ctr)

    # Beam projection below slab (or above, whichever is greater)
    hw = h_in - hf_in  # web height below flange
    max_overhang = hw   # ACI 318-11 §11.5.1.1(a)

    # Effective flange overhang on each side for torsion
    raw_overhang = (bf_in - bw_in) / 2
    eff_overhang = min(raw_overhang, max_overhang)
    bf_torsion = bw_in + 2 * eff_overhang

    # Acp = effective T-shape area
    Acp = bf_torsion * hf_in + bw_in * hw
    # pcp = perimeter of effective T-shape
    # (full perimeter around the T-shaped outline)
    pcp = 2 * bw_in + 2 * h_in + 2 * (bf_torsion - bw_in)

    # Aoh, ph based on web rectangle (closed stirrups are in the web)
    xo = bw_in - 2 * c_in
    yo = h_in - 2 * c_in
    Aoh = xo * yo
    ph  = 2 * (xo + yo)
    Ao  = 0.85 * Aoh

    return (Acp=Acp, pcp=pcp, Aoh=Aoh, ph=ph, Ao=Ao)
end

# ==============================================================================
# Threshold Torsion (§11.5.1)
# ==============================================================================

"""
    threshold_torsion(Acp, pcp, fc; λ=1.0, φ=0.75) -> Float64

Threshold torsion below which torsion effects can be neglected (ACI 318-11 §11.5.1).

    Tth = φ · λ · √f'c · Acp² / pcp

All inputs in psi / inch units. Returns kip·in.

# Reference
- ACI 445.1R-12 Example 1: Tth = 3.93 kN·m = 36.3 in.-kip
  (b=12", h=20", f'c=2900 psi, λ=1.0)
"""
function threshold_torsion(Acp::Real, pcp::Real, fc_psi::Real; λ::Real=1.0, φ::Real=0.75)
    pcp > 0 || throw(ArgumentError("pcp must be positive (got $pcp)"))
    fc_psi > 0 || throw(ArgumentError("fc_psi must be positive (got $fc_psi)"))
    Tth_lbin = φ * λ * sqrt(fc_psi) * Acp^2 / pcp
    return Tth_lbin / 1000.0  # kip·in
end

# ==============================================================================
# Cracking Torsion (§11.5.2.4)
# ==============================================================================

"""
    cracking_torsion(Acp, pcp, fc_psi; λ=1.0) -> Float64

Cracking torsion per ACI 318-11 §11.5.2.4:

    Tcr = 4 · λ · √f'c · Acp² / pcp

Used to compute the compatibility torsion cap: φ·Tcr.
All inputs in psi / inch units. Returns kip·in.
"""
function cracking_torsion(Acp::Real, pcp::Real, fc_psi::Real; λ::Real=1.0)
    pcp > 0 || throw(ArgumentError("pcp must be positive (got $pcp)"))
    fc_psi > 0 || throw(ArgumentError("fc_psi must be positive (got $fc_psi)"))
    Tcr_lbin = 4.0 * λ * sqrt(fc_psi) * Acp^2 / pcp
    return Tcr_lbin / 1000.0  # kip·in
end

# ==============================================================================
# Cross-Section Adequacy Check (§11.5.3.1)
# ==============================================================================

"""
    torsion_section_adequate(Vu_kip, Tu_kipin, bw_in, d_in, Aoh, ph, fc_psi;
                             λ=1.0, φ=0.75) -> Bool

Check cross-section adequacy per ACI 318-11 §11.5.3.1.

For solid sections:
    √[(Vu/(bw·d))² + (Tu·ph/(1.7·Aoh²))²] ≤ φ·(Vc/(bw·d) + 8·√f'c)

Returns true if adequate.

# Reference
- ACI 445.1R-12 Example 1: 2.65 MPa ≤ 2.80 MPa → adequate
"""
function torsion_section_adequate(
    Vu_kip::Real, Tu_kipin::Real,
    bw_in::Real, d_in::Real, Aoh::Real, ph::Real, fc_psi::Real;
    λ::Real=1.0, φ::Real=0.75,
)
    bw_in > 0 || throw(ArgumentError("bw_in must be positive (got $bw_in)"))
    d_in > 0 || throw(ArgumentError("d_in must be positive (got $d_in)"))
    Aoh > 0 || throw(ArgumentError("Aoh must be positive (got $Aoh)"))
    fc_psi > 0 || throw(ArgumentError("fc_psi must be positive (got $fc_psi)"))

    Vu_lb  = Vu_kip * 1000.0
    Tu_lbin = Tu_kipin * 1000.0

    τv = Vu_lb / (bw_in * d_in)
    τt = Tu_lbin * ph / (1.7 * Aoh^2)

    # Combined stress (interaction)
    lhs = sqrt(τv^2 + τt^2)

    # Limit: φ(Vc/(bw·d) + 8√f'c)
    Vc_stress = 2 * λ * sqrt(fc_psi)  # Vc/(bw·d) per unit area
    rhs = φ * (Vc_stress + 8 * sqrt(fc_psi))

    return lhs ≤ rhs
end

"""
    torsion_adequacy_ratio(Vu_kip, Tu_kipin, bw_in, d_in, Aoh, ph, fc_psi;
                           λ=1.0, φ=0.75) -> Float64

Returns the demand/capacity ratio for cross-section adequacy. ≤ 1.0 means adequate.
"""
function torsion_adequacy_ratio(
    Vu_kip::Real, Tu_kipin::Real,
    bw_in::Real, d_in::Real, Aoh::Real, ph::Real, fc_psi::Real;
    λ::Real=1.0, φ::Real=0.75,
)
    bw_in > 0 || throw(ArgumentError("bw_in must be positive (got $bw_in)"))
    d_in > 0 || throw(ArgumentError("d_in must be positive (got $d_in)"))
    Aoh > 0 || throw(ArgumentError("Aoh must be positive (got $Aoh)"))
    fc_psi > 0 || throw(ArgumentError("fc_psi must be positive (got $fc_psi)"))

    Vu_lb   = Vu_kip * 1000.0
    Tu_lbin = Tu_kipin * 1000.0

    τv = Vu_lb / (bw_in * d_in)
    τt = Tu_lbin * ph / (1.7 * Aoh^2)
    lhs = sqrt(τv^2 + τt^2)

    Vc_stress = 2 * λ * sqrt(fc_psi)
    rhs = φ * (Vc_stress + 8 * sqrt(fc_psi))

    return lhs / rhs
end

# ==============================================================================
# Required Torsion Reinforcement (§11.5.3)
# ==============================================================================

"""
    torsion_transverse_reinforcement(Tu_kipin, Ao, fyt_psi; θ=45.0, φ=0.75) -> Float64

Required transverse reinforcement for torsion (At/s) derived from ACI 318-11
§11.5.3.6, Eq. (11-21):

    Tn = 2·Ao·At·fyt·cot(θ) / s    ⇒    At/s = Tu / (φ · 2 · fyt · Ao · cot(θ))

Returns At/s in in²/in (area of ONE leg of a closed stirrup per unit spacing).

# Arguments
- `Tu_kipin`: Design torsional moment (kip·in) — may be capped for compatibility
- `Ao`: Gross area enclosed by shear flow path (in²), typically 0.85·Aoh
- `fyt_psi`: Stirrup yield strength (psi)
- `θ`: Angle of compression diagonals (degrees). Per §11.5.3.6 must satisfy
       30° ≤ θ ≤ 60°. Default 45° (non-prestressed members, §11.5.3.6(a));
       use 37.5° for prestressed members satisfying §11.5.3.6(b).
- `φ`: Strength reduction factor (0.75 per ACI 318-11 §9.3.2.3)

# Reference
- ACI 318-11 §11.5.3.6, Eq. (11-21) (PDF p. 184)
- ACI 445.1R-12 Example 1 cross-check: At/s = 0.61 mm²/mm = 0.0227 in²/in
"""
function torsion_transverse_reinforcement(
    Tu_kipin::Real, Ao::Real, fyt_psi::Real;
    θ::Real=45.0, φ::Real=0.75,
)
    Ao > 0      || throw(ArgumentError("Ao must be positive (got $Ao)"))
    fyt_psi > 0 || throw(ArgumentError("fyt_psi must be positive (got $fyt_psi)"))
    # ACI 318-11 §11.5.3.6: θ shall not be smaller than 30° nor larger than 60°.
    (30.0 ≤ θ ≤ 60.0) || throw(ArgumentError(
        "θ must be in [30°, 60°] per ACI 318-11 §11.5.3.6 (got $θ)"))
    Tu_lbin = Tu_kipin * 1000.0
    cot_θ = 1.0 / tand(θ)
    At_s = Tu_lbin / (φ * 2 * fyt_psi * Ao * cot_θ)
    return At_s  # in²/in (one leg)
end

"""
    torsion_longitudinal_reinforcement(At_s, ph, fyt_psi, fy_psi; θ=45.0) -> Float64

Required longitudinal reinforcement for torsion (Al) per ACI 318-11 §11.5.3.7,
Eq. (11-22):

    Al = (At/s) · ph · (fyt/fy) · cot²(θ)

Per §11.5.3.7, the same θ used in Eq. (11-21) (and therefore in
`torsion_transverse_reinforcement`) must be used here.

Returns Al in in².

# Arguments
- `At_s`: Transverse torsion reinforcement per unit length (in²/in)
- `ph`: Perimeter of the stirrup centerline (in)
- `fyt_psi`: Stirrup yield strength (psi)
- `fy_psi`: Longitudinal reinforcement yield strength (psi)
- `θ`: Compression diagonal angle (degrees). Must satisfy 30° ≤ θ ≤ 60° per
       §11.5.3.6 (default 45°).

# Reference
- ACI 318-11 §11.5.3.7, Eq. (11-22) (PDF p. 185)
- ACI 445.1R-12 Example 1 cross-check: Al = 780.8 mm² = 1.18 in²
"""
function torsion_longitudinal_reinforcement(
    At_s::Real, ph::Real, fyt_psi::Real, fy_psi::Real; θ::Real=45.0,
)
    fy_psi > 0  || throw(ArgumentError("fy_psi must be positive (got $fy_psi)"))
    (30.0 ≤ θ ≤ 60.0) || throw(ArgumentError(
        "θ must be in [30°, 60°] per ACI 318-11 §11.5.3.6 (got $θ)"))
    cot_θ = 1.0 / tand(θ)
    Al = At_s * ph * (fyt_psi / fy_psi) * cot_θ^2
    return Al  # in²
end

# ==============================================================================
# Minimum Torsion Reinforcement (§11.5.5)
# ==============================================================================

"""
    min_torsion_transverse(bw_in, fc_psi, fyt_psi) -> Float64

Minimum transverse reinforcement for torsion per ACI 318-11 §11.5.5.2,
Eq. (11-23). Conservatively assumes shear is carried by other reinforcement
(Av = 0), so the entire minimum (Av + 2At) is supplied by closed torsion
stirrups:

    (At/s)_min = max(0.75·√f'c · bw / (2·fyt),  25·bw / fyt)         (psi)

This is At/s for ONE LEG of a closed stirrup. The factor of 2 in the first
term and the `25` in the second term come from re-arranging Eq. (11-23)
`(Av + 2At) ≥ max(0.75·√f'c · bw·s / fyt,  50·bw·s / fyt)` for `Av = 0`.

Returns At/s_min in in²/in.

# Reference
- ACI 318-11 §11.5.5.2, Eq. (11-23) (PDF p. 188)
- ACI 445.1R-12 Example 1 cross-check: At/s_min = 0.125 mm²/mm = 0.005 in²/in
"""
function min_torsion_transverse(bw_in::Real, fc_psi::Real, fyt_psi::Real)
    fyt_psi > 0 || throw(ArgumentError("fyt_psi must be positive (got $fyt_psi)"))
    fc_psi  > 0 || throw(ArgumentError("fc_psi must be positive (got $fc_psi)"))
    bw_in   > 0 || throw(ArgumentError("bw_in must be positive (got $bw_in)"))
    a = 0.75 * sqrt(fc_psi) * bw_in / (2 * fyt_psi)
    b = 25.0 * bw_in / fyt_psi
    return max(a, b)
end

"""
    min_torsion_longitudinal(Acp, At_s, ph, bw_in, fc_psi, fy_psi, fyt_psi) -> Float64

Minimum longitudinal reinforcement for torsion per ACI 318-11 §11.5.5.3, Eq. (11-24):

    Al,min = 5·√f'c · Acp / fy − (At/s) · ph · (fyt/fy)

Per §11.5.5.3, in this equation `At/s` shall not be taken less than `25·bw/fyt`;
this floor is applied internally so that callers can pass the demand-based
`At/s` from Eq. (11-21) directly.

Returns Al,min in in² (clamped at 0).

# Reference
- ACI 318-11 §11.5.5.3, Eq. (11-24) (PDF p. 185)
- PCA EB712 (PCA Notes on ACI 318), Example 13.1, p. 426 — verifies
  `Al,min = 5·√5000·896/60000 − (0.025)(132) = 1.98 in²`
"""
function min_torsion_longitudinal(
    Acp::Real, At_s::Real, ph::Real, bw_in::Real,
    fc_psi::Real, fy_psi::Real, fyt_psi::Real,
)
    fy_psi  > 0 || throw(ArgumentError("fy_psi must be positive (got $fy_psi)"))
    fyt_psi > 0 || throw(ArgumentError("fyt_psi must be positive (got $fyt_psi)"))
    fc_psi  > 0 || throw(ArgumentError("fc_psi must be positive (got $fc_psi)"))
    bw_in   > 0 || throw(ArgumentError("bw_in must be positive (got $bw_in)"))
    # ACI 318-11 §11.5.5.3 caveat: At/s shall not be taken less than 25·bw/fyt
    At_s_eff = max(At_s, 25.0 * bw_in / fyt_psi)
    Al_min = 5 * sqrt(fc_psi) * Acp / fy_psi - At_s_eff * ph * (fyt_psi / fy_psi)
    return max(Al_min, 0.0)
end

# ==============================================================================
# Maximum Stirrup Spacing for Torsion (§11.5.6.1)
# ==============================================================================

"""
    max_torsion_stirrup_spacing(ph) -> Float64

Maximum stirrup spacing for torsion per ACI 318-11 §11.5.6.1:

    s_max = min(ph/8, 12 in.)

Returns s_max in inches.
"""
function max_torsion_stirrup_spacing(ph::Real)
    return min(ph / 8.0, 12.0)
end

# ==============================================================================
# Full Torsion Design
# ==============================================================================

"""
    design_beam_torsion(Tu, Vu, bw, h, d, fc, fy, fyt;
                        cover=1.5u"inch", stirrup_size=3,
                        bf=nothing, hf=nothing,
                        λ=1.0, θ=45.0, φ=0.75,
                        torsion_mode=:compatibility) -> NamedTuple

Complete torsion design for an RC beam per ACI 318-11 §11.5.

# Arguments
- `Tu`: Factored torsion demand
- `Vu`: Factored shear demand (for interaction checks)
- `bw`: Web width
- `h`: Total depth
- `d`: Effective depth
- `fc`: Concrete compressive strength
- `fy`: Longitudinal rebar yield strength
- `fyt`: Transverse (stirrup) rebar yield strength

## Keyword Arguments
- `cover`: Clear cover to stirrups (default 1.5")
- `stirrup_size`: Stirrup bar size (default #3)
- `bf`: Effective flange width (nothing → rectangular beam)
- `hf`: Flange thickness (nothing → rectangular beam)
- `λ`: Lightweight concrete factor (1.0 for NWC)
- `θ`: Compression diagonal angle in degrees (45° for non-prestressed)
- `φ`: Strength reduction factor (0.75 per ACI 318-11 §9.3.2.3)
- `torsion_mode`: `:compatibility` or `:equilibrium`

# Returns
Named tuple with comprehensive design results.

# Torsion Modes
- `:compatibility`: Tu is capped at φ·Tcr — excess redistributes to adjacent members.
  Appropriate when torque results from compatibility (e.g., spandrel beams,
  edge beams supporting one-way slabs).
- `:equilibrium`: Full factored Tu must be resisted — no redistribution allowed.
  Required when torsional moment is necessary for equilibrium (e.g., a cantilevered
  slab supported by a single beam where the slab's load path requires torsion).

# Reference
- ACI 318-11 §11.5
- ACI 445.1R-12, Chapter 9 (Design Examples)
"""
function design_beam_torsion(
    Tu::Moment, Vu::Force,
    bw::Length, h::Length, d::Length,
    fc::Pressure, fy::Pressure, fyt::Pressure;
    cover::Length = 1.5u"inch",
    stirrup_size::Int = 3,
    bf::Union{Length, Nothing} = nothing,
    hf::Union{Length, Nothing} = nothing,
    λ::Real = 1.0,
    θ::Real = 45.0,
    φ::Real = 0.75,
    torsion_mode::Symbol = :compatibility,
)
    # ---- Convert to psi / inch ----
    fc_psi  = ustrip(u"psi", fc)
    fy_psi  = ustrip(u"psi", fy)
    fyt_psi = ustrip(u"psi", fyt)
    bw_in   = ustrip(u"inch", bw)
    h_in    = ustrip(u"inch", h)
    d_in    = ustrip(u"inch", d)
    Tu_lbin = abs(ustrip(u"lbf*inch", Tu))
    Vu_lb   = abs(ustrip(u"lbf", Vu))
    Tu_kipin = Tu_lbin / 1000.0
    Vu_kip   = Vu_lb / 1000.0

    d_stir = ustrip(u"inch", rebar(stirrup_size).diameter)
    cov_in = ustrip(u"inch", cover)
    c_ctr  = cov_in + d_stir / 2  # distance from face to stirrup centerline

    # ---- Section properties ----
    is_tbeam = !isnothing(bf) && !isnothing(hf)

    if is_tbeam
        props = torsion_section_properties_tbeam(bw, h, bf, hf, c_ctr * u"inch")
    else
        props = torsion_section_properties(bw, h, c_ctr * u"inch")
    end
    Acp, pcp, Aoh, ph, Ao = props

    # ---- Step 1: Check threshold torsion ----
    Tth = threshold_torsion(Acp, pcp, fc_psi; λ=λ, φ=φ)
    if Tu_kipin ≤ Tth
        return (
            Tu_design_kipin = 0.0,
            Tu_demand_kipin = Tu_kipin,
            Tth_kipin = Tth,
            Tcr_kipin = cracking_torsion(Acp, pcp, fc_psi; λ=λ),
            torsion_required = false,
            section_adequate = true,
            At_s_required = 0.0,
            At_s_min = 0.0,
            Al_required = 0.0,
            Al_min = 0.0,
            s_max_torsion = max_torsion_stirrup_spacing(ph),
            adequacy_ratio = 0.0,
            torsion_mode = torsion_mode,
            Acp = Acp, pcp = pcp, Aoh = Aoh, ph = ph, Ao = Ao,
        )
    end

    # ---- Step 2: Compute cracking torsion ----
    Tcr = cracking_torsion(Acp, pcp, fc_psi; λ=λ)
    φTcr = φ * Tcr

    # ---- Step 3: Apply compatibility cap if appropriate ----
    if torsion_mode == :compatibility && Tu_kipin > φTcr
        Tu_design = φTcr
    else
        Tu_design = Tu_kipin
    end

    # ---- Step 4: Cross-section adequacy ----
    adequate = torsion_section_adequate(
        Vu_kip, Tu_design, bw_in, d_in, Aoh, ph, fc_psi; λ=λ, φ=φ,
    )
    ratio = torsion_adequacy_ratio(
        Vu_kip, Tu_design, bw_in, d_in, Aoh, ph, fc_psi; λ=λ, φ=φ,
    )

    # ---- Step 5: Required transverse reinforcement (At/s) ----
    At_s_req = torsion_transverse_reinforcement(Tu_design, Ao, fyt_psi; θ=θ, φ=φ)
    At_s_min = min_torsion_transverse(bw_in, fc_psi, fyt_psi)
    At_s = max(At_s_req, At_s_min)

    # ---- Step 6: Required longitudinal reinforcement (Al) ----
    Al_req = torsion_longitudinal_reinforcement(At_s_req, ph, fyt_psi, fy_psi; θ=θ)
    Al_min = min_torsion_longitudinal(Acp, At_s_req, ph, bw_in, fc_psi, fy_psi, fyt_psi)
    Al = max(Al_req, Al_min)

    # ---- Step 7: Maximum torsion stirrup spacing ----
    s_max = max_torsion_stirrup_spacing(ph)

    return (
        Tu_design_kipin = Tu_design,
        Tu_demand_kipin = Tu_kipin,
        Tth_kipin = Tth,
        Tcr_kipin = Tcr,
        φTcr_kipin = φTcr,
        torsion_required = true,
        section_adequate = adequate,
        At_s_required = At_s,        # in²/in (one leg, governs of required vs min)
        At_s_demand = At_s_req,      # in²/in (from demand only)
        At_s_min = At_s_min,         # in²/in (minimum)
        Al_required = Al,            # in² (governs of required vs min)
        Al_demand = Al_req,          # in² (from demand only)
        Al_min = Al_min,             # in² (minimum)
        s_max_torsion = s_max,       # in (max stirrup spacing)
        adequacy_ratio = ratio,      # ≤ 1.0 means section adequate
        torsion_mode = torsion_mode,
        was_capped = (torsion_mode == :compatibility && Tu_kipin > φTcr),
        Acp = Acp, pcp = pcp, Aoh = Aoh, ph = ph, Ao = Ao,
    )
end

