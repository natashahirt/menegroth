# ==============================================================================
# ACI 318-11 T-Beam Capacity Extensions
# ==============================================================================
# Extends ACIBeamChecker to handle RCTBeamSection alongside RCBeamSection.
# The existing ACIBeamChecker, ACIBeamCapacityCache, and precompute_capacities!
# work for both section types via multiple dispatch on _compute_φMn etc.
#
# Key differences from rectangular:
#   - Flexure: two-case Whitney block (flange vs web)
#   - Shear: uses bw (web width), not bf
#   - Min reinforcement: uses bw
# ==============================================================================

using Asap: kip, ksi, to_ksi, to_kip, to_kipft

# ==============================================================================
# φMn for T-beam sections
# ==============================================================================

"""
Compute φMn (kip·ft) for a singly-reinforced T-beam section.

Two cases:
1. Stress block in flange (a ≤ hf): rectangular behavior with width bf
2. Stress block in web (a > hf): T-beam decomposition
   - Flange overhang: Cf = 0.85 f'c (bf − bw) hf
   - Web rectangle:   Cw = As fy − Cf
   - Mn = Cf(d − hf/2) + Cw(d − a/2)
"""
function _compute_φMn(section::RCTBeamSection, fc_psi::Float64, fy_psi::Float64)
    bw_in = ustrip(u"inch", section.bw)
    bf_in = ustrip(u"inch", section.bf)
    hf_in = ustrip(u"inch", section.hf)
    d_in  = ustrip(u"inch", section.d)
    As_in = ustrip(u"inch^2", section.As)

    As_in > 0 || return 0.0

    # Trial: rectangular with flange width
    a_trial = As_in * fy_psi / (0.85 * fc_psi * bf_in)

    εcu = 0.003  # ACI 318-11 §10.2.3
    if a_trial ≤ hf_in
        # Case 1: stress block in flange
        a_in = a_trial
        β1 = _beta1_from_fc_psi(fc_psi)
        c_in = a_in / β1
        εt = c_in > 0 ? εcu * (d_in - c_in) / c_in : 0.0
        φ = flexure_phi(εt)

        Mn_lbin = As_in * fy_psi * (d_in - a_in / 2)
        return φ * Mn_lbin / 12_000.0   # kip·ft
    else
        # Case 2: stress block extends into web
        Cf_lb = 0.85 * fc_psi * (bf_in - bw_in) * hf_in
        Cw_lb = As_in * fy_psi - Cf_lb
        a_in  = Cw_lb / (0.85 * fc_psi * bw_in)

        β1 = _beta1_from_fc_psi(fc_psi)
        c_in = a_in / β1
        εt = c_in > 0 ? εcu * (d_in - c_in) / c_in : 0.0
        φ = flexure_phi(εt)

        Mn_lbin = Cf_lb * (d_in - hf_in / 2) + Cw_lb * (d_in - a_in / 2)
        return φ * Mn_lbin / 12_000.0   # kip·ft
    end
end

# ==============================================================================
# φVn_max for T-beam (uses bw, not bf)
# ==============================================================================

"""
Maximum design shear capacity for T-beam section geometry.
Shear is resisted by the web only (bw × d), per ACI 318-11 §11.2.1.1.
"""
function _compute_φVn_max(section::RCTBeamSection, fc_psi::Float64, λ::Float64)
    bw_in = ustrip(u"inch", section.bw)
    d_in  = ustrip(u"inch", section.d)

    sqrt_fc = sqrt(fc_psi)
    Vc_lb     = 2 * λ * sqrt_fc * bw_in * d_in
    Vs_max_lb = 8 * sqrt_fc * bw_in * d_in

    return 0.75 * (Vc_lb + Vs_max_lb) / 1000.0  # kip
end

# ==============================================================================
# εt for T-beam
# ==============================================================================

"""
Net tensile strain εt for a singly-reinforced T-beam section.
Accounts for T-beam stress block depth in both flange and web cases.
"""
function _compute_εt(section::RCTBeamSection, fc_psi::Float64, fy_psi::Float64)
    bw_in = ustrip(u"inch", section.bw)
    bf_in = ustrip(u"inch", section.bf)
    hf_in = ustrip(u"inch", section.hf)
    d_in  = ustrip(u"inch", section.d)
    As_in = ustrip(u"inch^2", section.As)

    As_in > 0 || return Inf

    a_trial = As_in * fy_psi / (0.85 * fc_psi * bf_in)

    if a_trial ≤ hf_in
        a_in = a_trial
    else
        Cf_lb = 0.85 * fc_psi * (bf_in - bw_in) * hf_in
        Cw_lb = As_in * fy_psi - Cf_lb
        a_in  = Cw_lb / (0.85 * fc_psi * bw_in)
    end

    εcu = 0.003  # ACI 318-11 §10.2.3
    β1 = _beta1_from_fc_psi(fc_psi)
    c_in = a_in / β1
    return c_in > 0 ? εcu * (d_in - c_in) / c_in : Inf
end

# ==============================================================================
# is_feasible for T-beam
# ==============================================================================

function is_feasible(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    j::Int,
    section::RCTBeamSection,
    material::Concrete,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)::Bool
    Mu = to_kipft(demand.Mu)
    Vu = to_kip(demand.Vu)

    # 1. Depth check
    cache.depths[j] ≤ checker.max_depth || return false

    # 2. Flexural check — φMn ≥ Mu
    cache.φMn[j] ≥ Mu || return false

    # 3. Shear adequacy — with axial modifier when Nu > 0 (ACI §22.5.6.1)
    Nu_kip = _get_Nu_kip(demand)
    if Nu_kip > 0
        fc_psi_s = cache.fc_ksi * 1000.0
        bw_in_s  = ustrip(u"inch", section.bw)
        d_in_s   = ustrip(u"inch", section.d)
        h_in_s   = ustrip(u"inch", section.h)
        Ag_in2   = bw_in_s * h_in_s  # conservative: web area only
        axial_factor = 1 + (Nu_kip * 1000) / (2000 * Ag_in2)
        sqrt_fc  = sqrt(fc_psi_s)
        Vc_lb     = 2 * checker.λ * axial_factor * sqrt_fc * bw_in_s * d_in_s
        Vs_max_lb = 8 * sqrt_fc * bw_in_s * d_in_s
        φVn_kip   = 0.75 * (Vc_lb + Vs_max_lb) / 1000.0
        φVn_kip ≥ Vu || return false
    else
        cache.φVn_max[j] ≥ Vu || return false
    end

    # 4. Net tensile strain (ACI 318-11 §10.3.5) — εt ≥ 0.004 for beams
    cache.εt[j] ≥ 0.004 || return false

    # 5. Minimum reinforcement (ACI 318-11 §10.5.1) — uses bw for T-beams
    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    bw_in  = ustrip(u"inch", section.bw)
    d_in   = ustrip(u"inch", section.d)
    As_in  = ustrip(u"inch^2", section.As)
    As_min = max(3.0 * sqrt(fc_psi) * bw_in * d_in / fy_psi,
                 200.0 * bw_in * d_in / fy_psi)
    As_in ≥ As_min || return false

    # 6. Deflection check (ACI §24.2) — only when service loads are provided
    if checker.w_dead_kplf > 0
        L_span = geometry.L  # Unitful Length (meters)
        defl_result = design_tbeam_deflection(
            section.bw, section.bf, section.hf, section.h, section.d,
            section.As,
            fc_psi * u"psi", fy_psi * u"psi", checker.Es_ksi * ksi,
            L_span,
            checker.w_dead_kplf * kip / u"ft",
            checker.w_live_kplf * kip / u"ft";
            support = checker.defl_support,
            ξ = checker.defl_ξ,
        )
        defl_result.ok || return false
    end

    # 7. Torsion section adequacy (§11.5.3.1) — when Tu > 0
    Tu_val = _get_Tu_kipin(demand)
    if Tu_val > 0.0
        d_stir = ustrip(u"inch", rebar(section.stirrup_size).diameter)
        cov_in = ustrip(u"inch", section.cover)
        c_ctr  = cov_in + d_stir / 2

        props = torsion_section_properties_tbeam(
            section.bw, section.h, section.bf, section.hf, c_ctr * u"inch")
        Tth = threshold_torsion(props.Acp, props.pcp, fc_psi; λ=checker.λ)
        if Tu_val > Tth
            torsion_section_adequate(Vu, Tu_val, bw_in, d_in,
                                     props.Aoh, props.ph, fc_psi;
                                     λ=checker.λ) || return false
        end
    end

    return true
end

# ==============================================================================
# Objective Values for RCTBeamSection
# ==============================================================================
# Beam volume/weight uses bw × h (web rectangle only).
# The flange concrete is already counted as slab material.

"""Objective value: web concrete volume (bw × h) of the T-beam per unit length."""
function objective_value(
    ::MinVolume,
    section::RCTBeamSection,
    material::Concrete,
    length::Length,
)
    Ag = section.bw * section.h
    uconvert(u"m^3", Ag * length)
end

"""Objective value: self-weight (web only) of the T-beam per unit length."""
function objective_value(
    ::MinWeight,
    section::RCTBeamSection,
    material::Concrete,
    length::Length,
)
    Ag = section.bw * section.h
    uconvert(u"kN", Ag * length * material.ρ * 1u"gn")
end

"""Objective value: cost proxy (web volume) for the T-beam per unit length."""
function objective_value(
    ::MinCost,
    section::RCTBeamSection,
    material::Concrete,
    length::Length,
)
    Ag = section.bw * section.h
    uconvert(u"m^3", Ag * length)
end

"""Objective value: embodied carbon (kgCO₂e, web only) of the T-beam per unit length."""
function objective_value(
    ::MinCarbon,
    section::RCTBeamSection,
    material::Concrete,
    length::Length,
)
    Ag = section.bw * section.h
    volume = uconvert(u"m^3", Ag * length)
    mass_kg = ustrip(volume) * ustrip(u"kg/m^3", material.ρ)
    mass_kg * material.ecc
end
