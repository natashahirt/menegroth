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
`vc_factor` scales `Vc` only (1.10 for qualifying joists, §8.13.8).
"""
function _compute_φVn_max(section::RCTBeamSection, fc_psi::Float64, λ::Float64;
                          vc_factor::Float64 = 1.0, vs_factor::Float64 = 1.0)
    bw_in = ustrip(u"inch", section.bw)
    d_in  = ustrip(u"inch", section.d)

    sqrt_fc = sqrt(fc_psi)
    # §8.13.8 raises Vc only. Vs,max stays the Chapter 11 limit.
    Vc_lb     = vc_factor * 2 * λ * sqrt_fc * bw_in * d_in
    # vs_factor is 0 when stirrups are not credited. §11.4.7.9 still defines Vs,max.
    Vs_max_lb = vs_factor * 8 * sqrt_fc * bw_in * d_in

    return 0.75 * (Vc_lb + Vs_max_lb) / 1000.0  # kip
end

"""
`Vc` factor for `section` under `checker`: 1.10 when the checker sizes joist
ribs and the section meets ACI 318-11 §8.13.2 and §8.13.3 at the checker's
spacing (§8.13.8, corpus: aci-318-11, PDF page 121), 1.0 otherwise.
"""
_checker_vc_factor(::ACIBeamChecker, ::AbstractSection) = 1.0
function _checker_vc_factor(checker::ACIBeamChecker, section::RCTBeamSection)
    checker.joist_spacing_in > 0 || return 1.0
    checker.joist_spacing_in > ustrip(u"inch", section.bw) || return 1.0
    joist = JoistConstruction(section, checker.joist_spacing_in * u"inch",
                              checker.joist_direction)
    return _joist_vc_factor(joist)
end

"""
φVn (kip) of one T-beam at one signed axial force, including a joist Vc increase.

ENGINEERING JUDGMENT: use the larger gross area (section_area =
bf·hf + bw·(h−hf)) for the compression modifier so the boost is not
overstated, and bw·h for the tension reduction (smaller Ag → larger
|Nu/Ag| reduction). Each is the conservative choice for that sign.
"""
function _section_φVn(checker::ACIBeamChecker, cache::ACIBeamCapacityCache,
                      j::Int, section::RCTBeamSection, Nu_kip::Float64)
    Nu_kip == 0 && return cache.φVn_max[j]
    fc_psi = cache.fc_ksi * 1000.0
    bw_in = ustrip(u"inch", section.bw)
    d_in = ustrip(u"inch", section.d)
    h_in = ustrip(u"inch", section.h)
    Ag_comp = ustrip(u"inch^2", section_area(section))
    Ag_tens = bw_in * h_in
    return _φVn_with_axial(bw_in, d_in, Ag_comp, Ag_tens, fc_psi, checker.λ, Nu_kip;
                           vc_factor = _checker_vc_factor(checker, section),
                           vs_factor = _checker_vs_factor(checker))
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
    Mu_neg = to_kipft(demand.Mu_neg)

    # 1. Depth check
    cache.depths[j] ≤ checker.max_depth || return false

    # 2. Sagging flexural check — φMn ≥ Mu (flange in compression)
    cache.φMn[j] ≥ Mu || return false

    # 3. Hogging section adequacy — φMn_neg ≥ Mu_neg
    #    ACI 318-11 §10.6.6 (corpus: aci-318-11, page 146) requires part of the
    #    flange-tension steel to be distributed over the effective flange width
    #    or ℓn/10; that detailing rule is not modeled in this capacity check.
    cache.φMn_neg[j] ≥ Mu_neg || return false

    # 4. Shear, one row per concurrent case. Ag for compression is the full
    #    T-section; Ag for tension is bw·h. Each is the smaller Vc for that sign.
    #    §8.13.8, when the rib qualifies, is inside `_section_φVn`.
    for row in _demand_shear_rows(checker, demand)
        _section_φVn(checker, cache, j, section, row.Nu_kip) >= row.Vu_kip || return false
    end

    # 4. Net tensile strain (ACI 318-11 §10.3.5) — εt ≥ 0.004 for beams
    cache.εt[j] ≥ 0.004 || return false

    # 5. Minimum reinforcement (ACI 318-11 §10.5.1) — uses bw for T-beams
    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    bw_in  = ustrip(u"inch", section.bw)
    d_in   = ustrip(u"inch", section.d)
    As_in  = ustrip(u"inch^2", section.As)
    As_min = _as_min_aci_1051(bw_in, d_in, fc_psi, fy_psi)
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
            λ = checker.λ,
            ξ = checker.defl_ξ,
            sustained_live_fraction = checker.defl_sustained_live,
        )
        defl_result.ok || return false
    end

    # 7. Torsion, each concurrent row above the threshold (§11.5.3.1)
    for row in _demand_shear_rows(checker, demand)
        row.Tu_kipin > 0 || continue
        d_stir = ustrip(u"inch", rebar(section.stirrup_size).diameter)
        cov_in = ustrip(u"inch", section.cover)
        props = torsion_section_properties_tbeam(
            section.bw, section.h, section.bf, section.hf,
            (cov_in + d_stir / 2) * u"inch")
        Tth = threshold_torsion(props.Acp, props.pcp, fc_psi; λ=checker.λ)
        if row.Tu_kipin > Tth
            torsion_section_adequate(row.Vu_kip, row.Tu_kipin, bw_in, d_in,
                                     props.Aoh, props.ph, fc_psi;
                                     λ=checker.λ) || return false
        end
    end

    # 8. Story-shell deflection (ACI 318-11 §9.5.2) — when the shell gave spans
    _shell_deflection_ratio(checker, demand.member_idx, section) <= 1 || return false

    return true
end

"""Strength checks use the concrete. The rebar on a reinforced-concrete material is for the objective."""
function is_feasible(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    j::Int,
    section::RCTBeamSection,
    material::ReinforcedConcreteMaterial,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)
    is_feasible(checker, cache, j, section, material.concrete, demand, geometry)
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
    length::Length;
    rebar=nothing,
    transverse=nothing,
)
    Ag = section.bw * section.h
    uconvert(u"m^3", Ag * length)
end

"""Self-weight of the T-beam web, in kilograms. Flange concrete stays with the slab. Longitudinal steel and stirrups are included when `rebar` is passed."""
function objective_value(
    ::MinWeight,
    section::RCTBeamSection,
    material::Concrete,
    length::Length;
    rebar=nothing,
    transverse=nothing,
)
    Ag = section.bw * section.h
    rebar === nothing && return uconvert(u"kg", Ag * length * material.ρ)
    trans = transverse === nothing ? rebar : transverse
    return _rc_objective(MinWeight(), Ag, section.As + section.As_prime, material, rebar, trans, length, section)
end

"""Cost of the T-beam web: web volume (m³)."""
function objective_value(
    ::MinCost,
    section::RCTBeamSection,
    material::Concrete,
    length::Length;
    rebar=nothing,
    transverse=nothing,
)
    return uconvert(u"m^3", section.bw * section.h * length)
end

"""Embodied carbon of the T-beam web, a typed `kgCO₂e` quantity."""
function objective_value(
    ::MinCarbon,
    section::RCTBeamSection,
    material::Concrete,
    length::Length;
    rebar=nothing,
    transverse=nothing,
)
    Ag = section.bw * section.h
    rebar === nothing && return uconvert(u"kgCO2e",
        uconvert(u"m^3", Ag * length) * material.ρ * material.ecc)
    trans = transverse === nothing ? rebar : transverse
    return _rc_objective(MinCarbon(), Ag, section.As + section.As_prime, material, rebar, trans, length, section)
end

function diagnose_infeasibility(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    catalog::AbstractVector{<:RCTBeamSection},
    material::Concrete,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)::String
    n = length(catalog)
    n == 0 && return "Catalog is empty"
    best_j = argmax(cache.φMn)
    sec = catalog[best_j]
    Mu = to_kipft(demand.Mu)
    Mu_neg = to_kipft(demand.Mu_neg)
    if cache.depths[best_j] > checker.max_depth
        return "Depth: h=$(cache.depths[best_j])m > max_depth=$(checker.max_depth)m"
    end
    if cache.φMn[best_j] < Mu
        return "Flexure: φMn=$(round(cache.φMn[best_j], digits=1)) < Mu=$(round(Mu, digits=1)) kip·ft"
    end
    if cache.φMn_neg[best_j] < Mu_neg
        return "Neg. flexure: φMn_neg=$(round(cache.φMn_neg[best_j], digits=1)) < Mu_neg=$(round(Mu_neg, digits=1)) kip·ft"
    end
    for row in _demand_shear_rows(checker, demand)
        φVn_kip = _section_φVn(checker, cache, best_j, sec, row.Nu_kip)
        φVn_kip >= row.Vu_kip && continue
        tag = row.Nu_kip < 0 ? "Nu<0" : (row.Nu_kip > 0 ? "Nu>0" : "Nu=0")
        return "Shear ($tag): φVn=$(round(φVn_kip, digits=1)) < Vu=$(round(row.Vu_kip, digits=1)) kip"
    end
    msg = _shell_deflection_message(checker, demand.member_idx, sec)
    msg === nothing || return msg
    return "All checks passed for best T-beam section — possible threading/cache inconsistency"
end

function explain_feasibility(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    j::Int,
    section::RCTBeamSection,
    material::Concrete,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)::FeasibilityExplanation
    checks = CheckResult[]
    Mu = to_kipft(demand.Mu)
    Mu_neg = to_kipft(demand.Mu_neg)

    d_section = cache.depths[j]
    d_limit = checker.max_depth
    push!(checks, CheckResult("depth", d_section <= d_limit,
          d_limit > 0 ? d_section / d_limit : 0.0, d_section, d_limit, ""))

    φMn = cache.φMn[j]
    push!(checks, CheckResult("flexure", φMn >= Mu,
          φMn > 0 ? Mu / φMn : (Mu > 0 ? Inf : 0.0), Mu, φMn, "ACI 318-11 10.2"))

    φMn_neg = cache.φMn_neg[j]
    push!(checks, CheckResult("flexure_neg", φMn_neg >= Mu_neg,
          φMn_neg > 0 ? Mu_neg / φMn_neg : (Mu_neg > 0 ? Inf : 0.0),
          Mu_neg, φMn_neg, "ACI 318-11 10.2"))

    gov = nothing
    for row in _demand_shear_rows(checker, demand)
        φVn_row = _section_φVn(checker, cache, j, section, row.Nu_kip)
        ratio = φVn_row > 0 ? row.Vu_kip / φVn_row : (row.Vu_kip > 0 ? Inf : 0.0)
        if gov === nothing || ratio > gov.ratio
            gov = (; row, φVn=φVn_row, ratio)
        end
    end
    shear_clause = gov.row.Nu_kip < 0 ? "ACI 318-11 11.2.2.3" :
                   (gov.row.Nu_kip > 0 ? "ACI 318-11 11.2.1.2" : "ACI 318-11 11.2.1.1")
    push!(checks, CheckResult("shear", gov.φVn >= gov.row.Vu_kip,
          gov.ratio, gov.row.Vu_kip, gov.φVn, shear_clause))

    # Same two checks as `is_feasible`. Bar rounding can pass flexure and
    # still land below εt = 0.004.
    εt = cache.εt[j]
    push!(checks, CheckResult("net_tensile_strain", εt >= 0.004,
          0.004 / max(εt, 1e-10), 0.004, εt, "ACI 318-11 10.3.5"))

    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    bw_in = ustrip(u"inch", section.bw)
    d_in = ustrip(u"inch", section.d)
    As_in = ustrip(u"inch^2", section.As)
    As_min = _as_min_aci_1051(bw_in, d_in, fc_psi, fy_psi)
    push!(checks, CheckResult("min_reinforcement", As_in >= As_min,
          As_min / max(As_in, 1e-10), As_min, As_in, "ACI 318-11 10.5.1"))

    _push_shell_deflection_check!(checks, checker, demand.member_idx, section)

    all_pass = all(c -> c.passed, checks)
    gov_idx = argmax([c.ratio for c in checks])
    gov = checks[gov_idx]
    FeasibilityExplanation(all_pass, checks, gov.name, gov.ratio)
end
