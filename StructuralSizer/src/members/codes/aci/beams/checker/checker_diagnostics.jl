# ==============================================================================
# Interface: error message
# ==============================================================================

"""Generate descriptive error message for infeasible ACI beam groups."""
function get_feasibility_error_msg(
    checker::ACIBeamChecker,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)
    Mu = to_kipft(demand.Mu)
    Mu_neg = to_kipft(demand.Mu_neg)
    Vu = to_kip(demand.Vu)
    Nu = _get_Nu_kip(demand)
    Tu = _get_Tu_kipin(demand)
    base = "No feasible RC beam section: Mu=$(round(Mu, digits=1)) kip·ft, " *
           "Mu_neg=$(round(Mu_neg, digits=1)) kip·ft, " *
           "Vu=$(round(Vu, digits=1)) kip, L=$(geometry.L)"
    if Nu != 0 || Tu > 0
        base *= " (Nu=$(round(Nu, digits=1)) kip, Tu=$(round(Tu, digits=1)) kip·in)"
    end
    base
end

"""
    diagnose_infeasibility(checker, cache, catalog, material, demand, geometry) -> String

Run feasibility checks on the highest-capacity section and return which check failed.
Useful for debugging when no section passes.
"""
function diagnose_infeasibility(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    catalog::AbstractVector,
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
    Vu = to_kip(demand.Vu)
    Nu_kip = _get_Nu_kip(demand)
    Tu_val = _get_Tu_kipin(demand)

    if cache.depths[best_j] > checker.max_depth
        return "Depth: h=$(cache.depths[best_j])m > max_depth=$(checker.max_depth)m"
    end
    if cache.φMn[best_j] < Mu
        return "Flexure: φMn=$(round(cache.φMn[best_j], digits=1)) < Mu=$(round(Mu, digits=1)) kip·ft"
    end
    if cache.φMn_neg[best_j] < Mu_neg
        return "Neg. flexure: φMn_neg=$(round(cache.φMn_neg[best_j], digits=1)) < Mu_neg=$(round(Mu_neg, digits=1)) kip·ft"
    end
    if Nu_kip != 0
        fc_psi = cache.fc_ksi * 1000.0
        b_in = ustrip(u"inch", sec.b)
        d_in = ustrip(u"inch", sec.d)
        h_in = ustrip(u"inch", sec.h)
        Ag_in2 = b_in * h_in
        φVn_kip = _φVn_with_axial(b_in, d_in, Ag_in2, Ag_in2, fc_psi, checker.λ, Nu_kip;
                                  vs_factor = _checker_vs_factor(checker))
        if φVn_kip < Vu
            tag = Nu_kip < 0 ? "Nu<0" : "Nu>0"
            return "Shear ($tag): φVn=$(round(φVn_kip, digits=1)) < Vu=$(round(Vu, digits=1)) kip"
        end
    else
        if cache.φVn_max[best_j] < Vu
            return "Shear: φVn_max=$(round(cache.φVn_max[best_j], digits=1)) < Vu=$(round(Vu, digits=1)) kip"
        end
    end
    if cache.εt[best_j] < 0.004
        return "εt: $(round(cache.εt[best_j], digits=4)) < 0.004 (ACI §10.3.5)"
    end
    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    b_in = ustrip(u"inch", sec.b)
    d_in = ustrip(u"inch", sec.d)
    As_in = ustrip(u"inch^2", sec.As)
    As_min = _as_min_aci_1051(b_in, d_in, fc_psi, fy_psi)
    As_req = _rect_as_required_in2(Mu, sec.b, sec.d, fc_psi, fy_psi)
    if !_min_steel_check(As_in, As_min, As_req).passed
        return "As_min: As=$(round(As_in, digits=2)) < As_min=$(round(As_min, digits=2)) in²"
    end
    if Tu_val > 0.0
        h_in = ustrip(u"inch", sec.h)
        d_stir = ustrip(u"inch", rebar(sec.stirrup_size).diameter)
        cov_in = ustrip(u"inch", sec.cover)
        c_ctr = cov_in + d_stir / 2
        props = torsion_section_properties(sec.b, sec.h, c_ctr * u"inch")
        Tth = threshold_torsion(props.Acp, props.pcp, fc_psi; λ=checker.λ)
        if Tu_val > Tth && !torsion_section_adequate(Vu, Tu_val, b_in, d_in, props.Aoh, props.ph, fc_psi; λ=checker.λ)
            return "Torsion: section inadequate for Tu=$(round(Tu_val, digits=1)) kip·in"
        end
    end
    msg = _shell_deflection_message(checker, demand.member_idx, sec)
    msg === nothing || return msg
    return "All checks passed for best section — possible threading/cache inconsistency"
end
# ==============================================================================
# Feasibility Explanation (Solver Trace)
# ==============================================================================

"""
    explain_feasibility(checker::ACIBeamChecker, cache, j, section, material, demand, geometry)

Evaluate ALL ACI 318 beam checks without short-circuiting and return per-check
demand/capacity ratios. Mirrors `is_feasible` for ACIBeamChecker exactly but
collects every intermediate result.
"""
function explain_feasibility(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    j::Int,
    section::RCBeamSection,
    material::Concrete,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)::FeasibilityExplanation
    checks = CheckResult[]

    Mu = to_kipft(demand.Mu)
    Mu_neg = to_kipft(demand.Mu_neg)
    Vu = to_kip(demand.Vu)

    # --- 1. Depth Check ---
    d_section = cache.depths[j]
    d_limit = checker.max_depth
    d_ratio = d_limit > 0 ? d_section / d_limit : 0.0
    push!(checks, CheckResult("depth", d_section <= d_limit,
          d_ratio, d_section, d_limit, ""))

    # --- 2. Sagging flexure — ACI 318-11 §10.2 / §9.3.2 ---
    φMn = cache.φMn[j]
    flex_ratio = φMn > 0 ? Mu / φMn : (Mu > 0 ? Inf : 0.0)
    push!(checks, CheckResult("flexure", φMn >= Mu,
          flex_ratio, Mu, φMn, "ACI 318-11 10.2"))

    # --- 2b. Hogging section adequacy ---
    φMn_neg = cache.φMn_neg[j]
    neg_ratio = φMn_neg > 0 ? Mu_neg / φMn_neg : (Mu_neg > 0 ? Inf : 0.0)
    push!(checks, CheckResult("flexure_neg", φMn_neg >= Mu_neg,
          neg_ratio, Mu_neg, φMn_neg, "ACI 318-11 10.2"))

    # --- 3. Shear Adequacy — ACI 318-11 §11.2 ---
    Nu_kip = _get_Nu_kip(demand)
    if Nu_kip != 0
        fc_psi_s = cache.fc_ksi * 1000.0
        b_in_s   = ustrip(u"inch", section.b)
        d_in_s   = ustrip(u"inch", section.d)
        h_in_s   = ustrip(u"inch", section.h)
        Ag_in2   = b_in_s * h_in_s
        φVn_kip = _φVn_with_axial(b_in_s, d_in_s, Ag_in2, Ag_in2, fc_psi_s, checker.λ, Nu_kip;
                                  vs_factor = _checker_vs_factor(checker))
    else
        φVn_kip = cache.φVn_max[j]
    end
    shear_ratio = φVn_kip > 0 ? Vu / φVn_kip : (Vu > 0 ? Inf : 0.0)
    shear_clause = Nu_kip < 0 ? "ACI 318-11 11.2.2.3" : (Nu_kip > 0 ? "ACI 318-11 11.2.1.2" : "ACI 318-11 11.2.1.1")
    push!(checks, CheckResult("shear", φVn_kip >= Vu,
          shear_ratio, Vu, φVn_kip, shear_clause))

    # --- 4. Net Tensile Strain — ACI 318-11 §10.3.5 ---
    εt = cache.εt[j]
    εt_limit = 0.004
    εt_ratio = εt_limit > 0 ? εt_limit / max(εt, 1e-10) : 0.0
    push!(checks, CheckResult("net_tensile_strain", εt >= εt_limit,
          εt_ratio, εt_limit, εt, "ACI 318-11 10.3.5"))

    # --- 5. Minimum Reinforcement — ACI 318-11 §10.5.1 and §10.5.3 ---
    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    b_in   = ustrip(u"inch", section.b)
    d_in   = ustrip(u"inch", section.d)
    As_in  = ustrip(u"inch^2", section.As)
    As_min = _as_min_aci_1051(b_in, d_in, fc_psi, fy_psi)
    As_req = _rect_as_required_in2(Mu, section.b, section.d, fc_psi, fy_psi)
    steel = _min_steel_check(As_in, As_min, As_req)
    push!(checks, CheckResult("min_reinforcement", steel.passed,
          steel.ratio, As_min, As_in, steel.clause))

    # --- 6. Torsion Section Adequacy — ACI 318-19 §22.7 ---
    Tu_val = _get_Tu_kipin(demand)
    if Tu_val > 0.0
        h_in = ustrip(u"inch", section.h)
        d_stir = ustrip(u"inch", rebar(section.stirrup_size).diameter)
        cov_in = ustrip(u"inch", section.cover)
        c_ctr  = cov_in + d_stir / 2

        props = torsion_section_properties(section.b, section.h, c_ctr * u"inch")
        Tth = threshold_torsion(props.Acp, props.pcp, fc_psi; λ=checker.λ)

        if Tu_val > Tth
            torsion_ok = torsion_section_adequate(Vu, Tu_val, b_in, d_in,
                                                   props.Aoh, props.ph, fc_psi;
                                                   λ=checker.λ)
            torsion_ratio = torsion_ok ? 0.9 : 1.1  # approximate — exact ratio is internal
            push!(checks, CheckResult("torsion_adequacy", torsion_ok,
                  torsion_ratio, Tu_val, Tth, "ACI 318-19 22.7"))
        end
    end

    # --- 7. Story-shell deflection — ACI 318-11 §9.5.2 ---
    _push_shell_deflection_check!(checks, checker, demand.member_idx, section)

    # --- Aggregate ---
    all_pass = all(c -> c.passed, checks)
    gov_idx = argmax([c.ratio for c in checks])
    gov = checks[gov_idx]

    FeasibilityExplanation(all_pass, checks, gov.name, gov.ratio)
end
