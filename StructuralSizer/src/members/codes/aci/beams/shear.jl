# ==============================================================================
# ACI 318 Beam Shear Design
# ==============================================================================
#
# Beam shear design per ACI 318-11 Chapters 10–11.
#
# Reference: DE-Simply-Supported-Reinforced-Concrete-Beam-Analysis-and-Design-
#            ACI-318-11-spBeam-v1000 (StructurePoint)
#
# Key ACI sections:
#   §11.2.1.1 (Eq. 11-3) - Concrete shear capacity Vc (shear and flexure only)
#   §11.2.1.2 (Eq. 11-4) - Vc with axial compression
#   §11.4.7.9            - Maximum shear capacity Vs,max
#   §11.4.5.1, .3        - Maximum stirrup spacing (and half-reduction at high Vs)
#   §11.4.6.3 (Eq. 11-13)- Minimum shear reinforcement
#   §9.3.2.3             - Strength reduction factor φ = 0.75
# ==============================================================================

using Unitful
using Asap: kip, ksi, psf, ksf, pcf

# ==============================================================================
# Concrete Shear Capacity
# ==============================================================================

"""
    Vc_beam(bw, d, fc; λ=1.0, Nu=nothing, Ag=nothing) -> Force

Nominal concrete shear capacity per ACI 318.

When `Nu` and `Ag` are omitted (pure flexural members), uses the
simplified formula (ACI 318-11 §11.2.1.1, Eq. (11-3)):

    Vc = 2 λ √f'c bw d

When `Nu > 0` and `Ag > 0` (members under axial compression), uses
the simplified axial-compression formula (ACI 318-11 §11.2.1.2, Eq. (11-4)):

    Vc = 2 λ (1 + Nu / (2000 Ag)) √f'c bw d

(The more detailed Vc per ACI 318-11 §11.2.2.1, Eq. (11-5) — which uses
ρw and Vu·d/Mu — is not implemented here.)

where `Nu` is in lbf and `Ag` is in in² (or Unitful equivalents).

# Arguments
- `bw`: Beam web width
- `d`: Effective depth
- `fc`: Concrete compressive strength
- `λ`: Lightweight concrete factor (1.0 for normal weight)
- `Nu`: Factored axial compression (positive). Unitful `Force` or raw lbf.
- `Ag`: Gross cross-section area (`bw × h`). Unitful `Area` or raw in².

# Reference
- Simplified: StructurePoint Example Vc = 2×1×√4350×12×17.56/1000 = 27.80 kips
- With axial: VCmaster pg 19–21, Vc = 21.4 kips (Nu=10 kips, Ag=192 in²)
"""
function Vc_beam(bw::Length, d::Length, fc::Pressure;
                 λ::Real=1.0, Nu=nothing, Ag=nothing)
    fc_psi = ustrip(u"psi", fc)
    bw_in  = ustrip(u"inch", bw)
    d_in   = ustrip(u"inch", d)

    # Axial compression modifier (ACI 318-11 §11.2.1.2, Eq. (11-4))
    axial_factor = 1.0
    if !isnothing(Nu) && !isnothing(Ag)
        Nu_lb  = Nu isa Unitful.Quantity ? ustrip(u"lbf", Nu) : Float64(Nu)
        Ag_in2 = Ag isa Unitful.Quantity ? ustrip(u"inch^2", Ag) : Float64(Ag)
        if Nu_lb > 0 && Ag_in2 > 0
            axial_factor = 1 + Nu_lb / (2000 * Ag_in2)
        end
    end

    Vc_lb = 2 * λ * axial_factor * sqrt(fc_psi) * bw_in * d_in
    return Vc_lb * u"lbf"
end

# ==============================================================================
# Maximum Shear Reinforcement
# ==============================================================================

"""
    Vs_max_beam(bw, d, fc) -> Force

Maximum nominal shear strength from steel reinforcement per ACI 318-11 §11.4.7.9:

    Vs,max = 8 × √f'c × bw × d

If Vs > Vs,max, the section must be enlarged.

# Reference
- StructurePoint Example: Vs_max = 8×√4350×12×17.56/1000 = 111.19 kips
"""
function Vs_max_beam(bw::Length, d::Length, fc::Pressure)
    fc_psi = ustrip(u"psi", fc)
    bw_in  = ustrip(u"inch", bw)
    d_in   = ustrip(u"inch", d)
    Vs_lb  = 8 * sqrt(fc_psi) * bw_in * d_in
    return Vs_lb * u"lbf"
end

# ==============================================================================
# Required Shear Reinforcement
# ==============================================================================

"""
    Vs_required(Vu, Vc; φ=0.75) -> Force

Required nominal shear reinforcement capacity:

    Vs = Vu/φ - Vc

Returns 0 if concrete alone is adequate.

# Reference
- StructurePoint Example: Vs = 28.52/0.75 - 27.80 = 10.23 kips
"""
function Vs_required(Vu::Force, Vc::Force; φ::Real=0.75)
    Vs = Vu / φ - Vc
    return max(Vs, 0.0 * unit(Vc))
end

# ==============================================================================
# Minimum Shear Reinforcement (ACI 318-11 §11.4.6.3)
# ==============================================================================

"""
    min_shear_reinforcement(bw, fc, fyt) -> typeof(1.0u"inch^2"/u"inch")

Minimum Av/s per ACI 318-11 §11.4.6.3:

    Av/s_min = max(0.75√f'c × bw / fyt,  50 × bw / fyt)

Returns value in in²/in.

# Reference
- StructurePoint Example: max(0.0099, 0.0100) = 0.0100 in²/in
"""
function min_shear_reinforcement(bw::Length, fc::Pressure, fyt::Pressure)
    fc_psi  = ustrip(u"psi", fc)
    fyt_psi = ustrip(u"psi", fyt)
    bw_in   = ustrip(u"inch", bw)

    # Eq. (a): 0.75√f'c × bw / fyt
    Avs_a = 0.75 * sqrt(fc_psi) * bw_in / fyt_psi

    # Eq. (b): 50 × bw / fyt
    Avs_b = 50 * bw_in / fyt_psi

    return max(Avs_a, Avs_b) * u"inch^2/inch"
end

# ==============================================================================
# Maximum Stirrup Spacing (ACI 318-11 §11.4.5)
# ==============================================================================

"""
    max_stirrup_spacing(d, Vs, bw, fc) -> Length

Maximum stirrup spacing for non-prestressed members per ACI 318-11
§11.4.5.1 (base limit) and §11.4.5.3 (one-half reduction at high `Vs`):

- If Vs ≤ 4√f'c × bw × d:  s_max = min(d/2, 24 in)   (§11.4.5.1)
- If Vs >  4√f'c × bw × d:  s_max = min(d/4, 12 in)   (§11.4.5.1 reduced by §11.4.5.3)

# Reference
- ACI 318-11 §11.4.5.1, §11.4.5.3 (PDF p. 174)
- StructurePoint Example: Vs < 4√f'c×bw×d → s_max = min(17.56/2, 24) = 8.78 in
"""
function max_stirrup_spacing(d::Length, Vs::Force, bw::Length, fc::Pressure)
    fc_psi = ustrip(u"psi", fc)
    bw_in  = ustrip(u"inch", bw)
    d_in   = ustrip(u"inch", d)
    Vs_lb  = ustrip(u"lbf", Vs)

    threshold = 4 * sqrt(fc_psi) * bw_in * d_in  # lbs

    if Vs_lb ≤ threshold
        return min(d / 2, 24.0u"inch")
    else
        return min(d / 4, 12.0u"inch")
    end
end

# ==============================================================================
# Stirrup Design
# ==============================================================================

"""
    design_stirrups(Vs, d, fyt; bar_size=3) -> NamedTuple

Design transverse reinforcement (stirrups) to provide the required Vs.

Uses standard two-leg stirrups. Spacing from:
    s = Av × fyt × d / Vs

# Arguments
- `Vs`: Required nominal shear capacity from steel
- `d`: Effective depth
- `fyt`: Stirrup yield strength
- `bar_size`: Bar number for stirrups (default #3)

# Returns
Named tuple: (Av, bar_size, s_required, s_provided)

# Reference
- StructurePoint Example: #3 @ 8.3" provides Av/s = 0.22/8.3 = 0.0265 in²/in
"""
function design_stirrups(Vs::Force, d::Length, fyt::Pressure; bar_size::Int=3)
    Av = 2 * bar_area(bar_size)  # two legs

    Vs_lb  = ustrip(u"lbf", Vs)
    fyt_psi = ustrip(u"psi", fyt)
    d_in   = ustrip(u"inch", d)
    Av_in  = ustrip(u"inch^2", Av)

    if Vs_lb ≤ 0
        return (
            Av = Av,
            bar_size = bar_size,
            s_required = Inf * u"inch",
            s_provided = 0.0u"inch",
        )
    end

    # s = Av × fyt × d / Vs
    s_req = Av_in * fyt_psi * d_in / Vs_lb

    return (
        Av = Av,
        bar_size = bar_size,
        s_required = s_req * u"inch",
        s_provided = 0.0u"inch",  # caller rounds down
    )
end

# ==============================================================================
# Full Shear Design
# ==============================================================================

"""
    design_beam_shear(Vu, bw, d, fc, fyt; λ=1.0, stirrup_bar=3, Nu=nothing, Ag=nothing) -> NamedTuple

Complete beam shear design per ACI 318.

# Arguments
- `Vu`: Factored shear demand (typically at d from support face)
- `bw`: Beam web width
- `d`: Effective depth
- `fc`: Concrete compressive strength
- `fyt`: Stirrup yield strength
- `λ`: Lightweight factor (1.0 normal weight)
- `stirrup_bar`: Bar number for stirrups (default #3)
- `Nu`: Factored axial compression (positive). Increases Vc per ACI 318-11 §11.2.1.2.
- `Ag`: Gross cross-section area (bw × h). Required when Nu is provided.

# Returns
Named tuple:
- `Vc`: Nominal concrete shear capacity (with axial modifier if applicable)
- `φVc`: Design concrete shear capacity
- `Vs_req`: Required steel shear contribution
- `Vs_max`: Maximum allowable Vs (section adequacy)
- `section_adequate`: Bool — Vs_req ≤ Vs_max
- `Avs_min`: Minimum Av/s (ACI 318-11 §11.4.6.3)
- `stirrups`: Stirrup design (Av, bar_size, s_required)
- `s_max`: Maximum stirrup spacing
- `s_design`: Governing spacing min(s_required, s_max, s_from_Avs_min)
- `φVn`: Design shear capacity with provided stirrups

# Reference
- StructurePoint Simply Supported Beam Example §5
- VCmaster pg 19–21: Shear with axial compression (Nu=10 kips)
"""
function design_beam_shear(Vu::Force, bw::Length, d::Length,
                           fc::Pressure, fyt::Pressure;
                           λ::Real=1.0, stirrup_bar::Int=3,
                           Nu=nothing, Ag=nothing)
    φ = 0.75

    # Concrete capacity (with optional axial compression modifier)
    Vc = Vc_beam(bw, d, fc; λ=λ, Nu=Nu, Ag=Ag)
    φVc = φ * Vc

    # Required steel shear
    Vs_req = Vs_required(Vu, Vc; φ=φ)

    # Section adequacy check
    Vs_max = Vs_max_beam(bw, d, fc)
    adequate = ustrip(u"lbf", Vs_req) ≤ ustrip(u"lbf", Vs_max)

    # Minimum Av/s
    Avs_min = min_shear_reinforcement(bw, fc, fyt)

    # Stirrup design from demand
    stir = design_stirrups(Vs_req, d, fyt; bar_size=stirrup_bar)
    Av = stir.Av

    # Maximum spacing
    s_max = max_stirrup_spacing(d, Vs_req, bw, fc)

    # Spacing from minimum Av/s requirement
    Av_in = ustrip(u"inch^2", Av)
    Avs_min_val = ustrip(u"inch^2/inch", Avs_min)
    s_from_min = (Avs_min_val > 0) ? (Av_in / Avs_min_val) * u"inch" : Inf * u"inch"

    # Governing spacing (rounded down to nearest 0.5 in for practical detailing)
    s_candidates = [stir.s_required, s_max, s_from_min]
    s_gov_raw = minimum(s -> ustrip(u"inch", s), s_candidates) * u"inch"
    s_design = floor(ustrip(u"inch", s_gov_raw) * 2) / 2 * u"inch"  # round to 0.5"

    # Final capacity with design spacing
    s_in = ustrip(u"inch", s_design)
    d_in = ustrip(u"inch", d)
    fyt_psi = ustrip(u"psi", fyt)
    Vc_lb = ustrip(u"lbf", Vc)
    Vs_provided_lb = (s_in > 0) ? Av_in * fyt_psi * d_in / s_in : 0.0
    φVn = φ * (Vs_provided_lb + Vc_lb) * u"lbf"

    return (
        Vc = Vc,
        φVc = φVc,
        Vs_req = Vs_req,
        Vs_max = Vs_max,
        section_adequate = adequate,
        Avs_min = Avs_min,
        stirrups = (Av=Av, bar_size=stirrup_bar, s_required=stir.s_required),
        s_max = s_max,
        s_design = s_design,
        φVn = φVn,
    )
end

# ==============================================================================
# (exports centralized in StructuralSizer.jl)
# ==============================================================================
