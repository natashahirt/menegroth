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

    if cache.depths[best_j] > checker.max_depth
        return "Depth: h=$(cache.depths[best_j])m > max_depth=$(checker.max_depth)m"
    end
    if cache.φMn[best_j] < Mu
        return "Flexure: φMn=$(round(cache.φMn[best_j], digits=1)) < Mu=$(round(Mu, digits=1)) kip·ft"
    end
    if cache.φMn_neg[best_j] < Mu_neg
        return "Neg. flexure: φMn_neg=$(round(cache.φMn_neg[best_j], digits=1)) < Mu_neg=$(round(Mu_neg, digits=1)) kip·ft"
    end
    fail = _rectangular_shear_failure(checker, cache, best_j, sec, demand)
    if fail !== nothing && fail.kind == :shear
        tag = fail.row.Nu_kip < 0 ? "Nu<0" : (fail.row.Nu_kip > 0 ? "Nu>0" : "Nu=0")
        φVn = _section_φVn(checker, cache, best_j, sec, fail.row.Nu_kip)
        return "Shear ($tag): φVn=$(round(φVn, digits=1)) < Vu=$(round(fail.row.Vu_kip, digits=1)) kip"
    elseif fail !== nothing
        return "Torsion: section inadequate for Tu=$(round(fail.row.Tu_kipin, digits=1)) kip·in"
    end
    if cache.εt[best_j] < 0.004
        return "εt: $(round(cache.εt[best_j], digits=4)) < 0.004 (ACI §10.3.5)"
    end
    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    b_in = ustrip(u"inch", sec.b)
    d_in = ustrip(u"inch", sec.d)
    As_in = ustrip(u"inch^2", sec.As)
    As_min = max(3.0 * sqrt(fc_psi) * b_in * d_in / fy_psi, 200.0 * b_in * d_in / fy_psi)
    if As_in < As_min
        return "As_min: As=$(round(As_in, digits=2)) < As_min=$(round(As_min, digits=2)) in²"
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
    # The reported row is the one with the highest Vu/φVn.
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

    # --- 4. Net Tensile Strain — ACI 318-11 §10.3.5 ---
    εt = cache.εt[j]
    εt_limit = 0.004
    εt_ratio = εt_limit > 0 ? εt_limit / max(εt, 1e-10) : 0.0
    push!(checks, CheckResult("net_tensile_strain", εt >= εt_limit,
          εt_ratio, εt_limit, εt, "ACI 318-11 10.3.5"))

    # --- 5. Minimum Reinforcement — ACI 318-11 §10.5.1 ---
    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    b_in   = ustrip(u"inch", section.b)
    d_in   = ustrip(u"inch", section.d)
    As_in  = ustrip(u"inch^2", section.As)
    As_min = _as_min_aci_1051(b_in, d_in, fc_psi, fy_psi)
    min_reinf_ratio = As_min > 0 ? As_min / max(As_in, 1e-10) : 0.0
    push!(checks, CheckResult("min_reinforcement", As_in >= As_min,
          min_reinf_ratio, As_min, As_in, "ACI 318-11 10.5.1"))

    # --- 6. Torsion Section Adequacy, each concurrent row above Tth — ACI 318-19 §22.7 ---
    torsion_ok = true
    torsion_tu = 0.0
    torsion_tth = 0.0
    for row in _demand_shear_rows(checker, demand)
        row.Tu_kipin > 0 || continue
        d_stir = ustrip(u"inch", rebar(section.stirrup_size).diameter)
        cov_in = ustrip(u"inch", section.cover)
        props = torsion_section_properties(section.b, section.h,
                                           (cov_in + d_stir / 2) * u"inch")
        Tth = threshold_torsion(props.Acp, props.pcp, fc_psi; λ=checker.λ)
        row.Tu_kipin > Tth || continue
        ok_row = torsion_section_adequate(row.Vu_kip, row.Tu_kipin, b_in, d_in,
                                          props.Aoh, props.ph, fc_psi; λ=checker.λ)
        torsion_tu = row.Tu_kipin
        torsion_tth = Tth
        torsion_ok = torsion_ok && ok_row
    end
    if torsion_tu > 0
        # approximate ratio — the exact ratio is internal to torsion_section_adequate
        push!(checks, CheckResult("torsion_adequacy", torsion_ok,
              torsion_ok ? 0.9 : 1.1, torsion_tu, torsion_tth, "ACI 318-19 22.7"))
    end

    # --- 6b. Service deflection — ACI 318-11 §9.5.2 (mirrors is_feasible) ---
    if checker.w_dead_kplf > 0
        defl = design_beam_deflection(
            section.b, section.h, section.d, section.As,
            fc_psi * u"psi", fy_psi * u"psi", checker.Es_ksi * ksi,
            geometry.L,
            checker.w_dead_kplf * kip / u"ft",
            checker.w_live_kplf * kip / u"ft";
            support = checker.defl_support,
            ξ = checker.defl_ξ,
            sustained_live_fraction = checker.defl_sustained_live,
        )
        push!(checks, CheckResult("deflection", defl.ok,
              defl.ok ? 0.9 : 1.1, 0.0, 0.0, "ACI 318-11 9.5.2"))
    end

    # --- 7. Story-shell deflection — ACI 318-11 §9.5.2 ---
    _push_shell_deflection_check!(checks, checker, demand.member_idx, section)

    # --- Aggregate ---
    all_pass = all(c -> c.passed, checks)
    gov_idx = argmax([c.ratio for c in checks])
    gov = checks[gov_idx]

    FeasibilityExplanation(all_pass, checks, gov.name, gov.ratio)
end
