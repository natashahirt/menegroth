# Result Conversion
# ==============================================================================

"""
    RCColumnNLPResult

Result from RC column NLP optimization.

# Fields
- `section`: Optimized `RCColumnSection` (rounded to practical dimensions)
- `b_opt`: Optimal width from solver (inches, continuous)
- `h_opt`: Optimal depth from solver (inches, continuous)
- `ρ_opt`: Optimal reinforcement ratio (continuous). If `size_rc_column_nlp`
  had to repair the built section, this is the returned section's `ρg`.
- `b_final`: Final width of `section` (inches)
- `h_final`: Final depth of `section` (inches)
- `area`: Final cross-sectional area of `section` (sq in)
- `status`: Solver termination status
- `iterations`: Number of solver iterations/evaluations
"""
struct RCColumnNLPResult
    section::RCColumnSection
    b_opt::Float64
    h_opt::Float64
    ρ_opt::Float64
    b_final::Float64
    h_final::Float64
    area::Float64
    status::Symbol
    iterations::Int
end

"""
    build_rc_column_nlp_result(problem, opt_result) -> RCColumnNLPResult

Convert optimization result to `RCColumnNLPResult` with practical section.

With `snap`, each dimension rounds up to `dim_increment`, held to `max_dim`.
Solver noise of up to 1e-6 in above a grid value (e.g. `b_opt = 20 + 1e-7`
with `max_dim = 20`) does not push the dimension up a full increment.
"""
function build_rc_column_nlp_result(p::RCColumnNLPProblem, opt_result)
    b_opt, h_opt, ρ_opt = opt_result.minimizer
    incr = ustrip(u"inch", p.opts.dim_increment)

    if p.opts.snap
        # Round to practical dimensions
        snap_tol = 1e-6
        b_final = min(ceil((b_opt - snap_tol) / incr) * incr, p.b_max)
        h_final = min(ceil((h_opt - snap_tol) / incr) * incr, p.b_max)
    else
        b_final = b_opt
        h_final = h_opt
    end
    
    # Build final section with rounded dimensions
    section = _build_nlp_trial_section(b_final, h_final, ρ_opt, p.opts)
    
    # If rounding made it infeasible, try increasing dimensions
    if isnothing(section)
        b_final += incr
        h_final += incr
        section = _build_nlp_trial_section(b_final, h_final, ρ_opt, p.opts)
    end
    
    # Final fallback: return the continuous solution section
    if isnothing(section)
        section = _build_nlp_trial_section(b_opt, h_opt, ρ_opt, p.opts)
        b_final, h_final = b_opt, h_opt
    end
    isnothing(section) && throw(ArgumentError(
        "RC column NLP: no #$(p.opts.bar_size) layout builds at " *
        "$(round(b_final, digits=2))×$(round(h_final, digits=2)) in. " *
        "(ACI 318-19 §25.2.3 clear spacing). Use a smaller bar size or a larger min_dim."))
    
    return RCColumnNLPResult(
        section,
        b_opt, h_opt, ρ_opt,
        b_final, h_final,
        b_final * h_final,
        opt_result.status,
        opt_result.iterations
    )
end
# HSS NLP Result
# ==============================================================================

"""
    HSSColumnNLPResult

Result from HSS column NLP optimization.

# Fields
- `section`: Optimized `HSSRectSection` (rounded to standard sizes)
- `B_opt`, `H_opt`, `t_opt`: Continuous optimal values (inches)
- `B_final`, `H_final`, `t_final`: Final dimensions after rounding (inches)
- `area`: Final cross-sectional area (sq in)
- `weight_per_ft`: Weight per linear foot (lb/ft)
- `status`: Solver termination status
- `iterations`: Number of solver iterations
"""
struct HSSColumnNLPResult
    section::HSSRectSection
    B_opt::Float64
    H_opt::Float64
    t_opt::Float64
    B_final::Float64
    H_final::Float64
    t_final::Float64
    area::Float64
    weight_per_ft::Float64
    status::Symbol
    iterations::Int
end

"""
    build_hss_nlp_result(problem, opt_result) -> HSSColumnNLPResult

Convert optimization result to `HSSColumnNLPResult` with practical section.
"""
function build_hss_nlp_result(p::HSSColumnNLPProblem, opt_result)
    B_opt, H_opt, t_opt = opt_result.minimizer
    
    if p.opts.snap
        # Round to practical dimensions
        outer_incr = ustrip(u"inch", p.opts.outer_increment)
        t_incr = ustrip(u"inch", p.opts.thickness_increment)
        
        B_final = ceil(B_opt / outer_incr) * outer_incr
        H_final = ceil(H_opt / outer_incr) * outer_incr
        t_final = ceil(t_opt / t_incr) * t_incr
        
        # Ensure thickness doesn't exceed wall (practical limit)
        max_t = min(B_final, H_final) / 4
        t_final = min(t_final, max_t)
        t_final = max(t_final, p.t_min)
    else
        B_final = B_opt
        H_final = H_opt
        t_final = t_opt
    end
    
    # Build final section
    section = HSSRectSection(H_final * u"inch", B_final * u"inch", t_final * u"inch")
    
    # Calculate area and weight
    area = ustrip(u"inch^2", section.A)
    ρ_steel = 490.0  # lb/ft³
    weight_per_ft = area * ρ_steel / 144.0  # lb/ft
    
    return HSSColumnNLPResult(
        section,
        B_opt, H_opt, t_opt,
        B_final, H_final, t_final,
        area, weight_per_ft,
        opt_result.status,
        opt_result.iterations
    )
end
# W Section NLP Result
# ==============================================================================

"""
    WColumnNLPResult

Result from W section column NLP optimization.

# Fields
- `section`: Constructed `ISymmSection` from optimized dimensions
- `d_opt`, `bf_opt`, `tf_opt`, `tw_opt`: Continuous optimal values (inches)
- `d_final`, `bf_final`, `tf_final`, `tw_final`: Final dimensions (inches)
- `area`: Final cross-sectional area (sq in)
- `weight_per_ft`: Weight per linear foot (lb/ft)
- `Ix`, `Iy`: Moments of inertia (in⁴)
- `rx`, `ry`: Radii of gyration (in)
- `status`: Solver termination status
- `iterations`: Number of solver iterations
"""
struct WColumnNLPResult
    section::ISymmSection
    d_opt::Float64
    bf_opt::Float64
    tf_opt::Float64
    tw_opt::Float64
    d_final::Float64
    bf_final::Float64
    tf_final::Float64
    tw_final::Float64
    area::Float64
    weight_per_ft::Float64
    Ix::Float64
    Iy::Float64
    rx::Float64
    ry::Float64
    status::Symbol
    iterations::Int
end

"""
    build_w_nlp_result(problem, opt_result) -> WColumnNLPResult

Convert optimization result to `WColumnNLPResult`.
"""
function build_w_nlp_result(p::WColumnNLPProblem, opt_result)
    d_opt, bf_opt, tf_opt, tw_opt = opt_result.minimizer
    
    if p.opts.snap
        # Round to practical precision (1/16" increments)
        incr = 0.0625
        d_final = ceil(d_opt / incr) * incr
        bf_final = ceil(bf_opt / incr) * incr
        tf_final = ceil(tf_opt / incr) * incr
        tw_final = ceil(tw_opt / incr) * incr
    else
        d_final = d_opt
        bf_final = bf_opt
        tf_final = tf_opt
        tw_final = tw_opt
    end
    
    # Build ISymmSection from final dimensions (convert inches → Unitful)
    section = ISymmSection(
        d_final * u"inch", bf_final * u"inch",
        tw_final * u"inch", tf_final * u"inch";
        name = "NLP-W d=$(round(d_final, digits=2)) bf=$(round(bf_final, digits=2))",
        material = p.opts.material,
    )
    
    # Compute properties of final section
    A = _w_area_smooth(d_final, bf_final, tf_final, tw_final)
    Ix, Iy = _w_inertia_smooth(d_final, bf_final, tf_final, tw_final)
    rx = sqrt(Ix / A)
    ry = sqrt(Iy / A)
    
    # Weight per foot
    ρ_steel = 490.0  # lb/ft³
    weight_per_ft = A * ρ_steel / 144.0  # lb/ft
    
    return WColumnNLPResult(
        section,
        d_opt, bf_opt, tf_opt, tw_opt,
        d_final, bf_final, tf_final, tw_final,
        A, weight_per_ft,
        Ix, Iy, rx, ry,
        opt_result.status,
        opt_result.iterations
    )
end
