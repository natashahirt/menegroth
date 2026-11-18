# ==============================================================================
# Steel W Beam NLP Sizing (Dedicated Beam Formulation)
# ==============================================================================

"""
    size_steel_w_beam_nlp(Mu, Vu, geometry, opts::NLPWOptions; Mux_neg, Ix_min, x0) -> WColumnNLPResult

Size a W-shape beam using continuous (NLP) optimization with dedicated
AISC F2 flexure (including smooth LTB) and G2 shear constraints.

Unlike `size_w_nlp` (which uses H1-1 interaction with Pu=0), this
formulation directly optimizes for flexure and shear, producing beams
with wider flanges to resist lateral-torsional buckling.

When `Mux_neg > 0` (default `Mux_neg = Mu`), sizes against
`max(Mu, Mux_neg)` with hogging Chapter F (`Lb = L`, `Cb = 1.0`) if
deck-braced sagging `Lb`/`Cb` would otherwise inflate φMn.

AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
# ENGINEERING JUDGMENT
Hogging uses `Cb = 1.0` (`SteelMemberGeometry` has only sagging `Cb`).

# Arguments
- `Mu`: Factored moment — any moment unit
- `Vu`: Factored shear — any force unit
- `geometry`: `SteelMemberGeometry` with L, Lb (unbraced length), Cb
- `opts`: `NLPWOptions` with material, dimension bounds, solver settings

# Keyword Arguments
- `Mux_neg`: Hogging (top-flange compression) moment. Default: `Mu`
  (unsigned envelope includes hogging).
- `Ix_min`: Minimum required Ix for deflection (Length⁴ or bare in⁴). Use
  `required_Ix_for_deflection` to compute from service loads. Default: `nothing`.
- `x0`: Initial guess vector (default: automatic)

# Returns
`WColumnNLPResult` with `.section::ISymmSection` for analytical checks.

# Example
```julia
# Strength only
result = size_steel_w_beam_nlp(150.0u"kN*m", 100.0u"kN",
    SteelMemberGeometry(8.0; Kx=1.0, Ky=1.0),
    NLPWOptions(min_depth=8.0u"inch", max_depth=24.0u"inch"))

# With deflection constraint
Ix_req = required_Ix_for_deflection(0.8kip/u"ft", 25.0u"ft", 29000.0ksi)
result = size_steel_w_beam_nlp(Mu, Vu, geom, opts; Ix_min=Ix_req)
```
"""
function size_steel_w_beam_nlp(
    Mu,
    Vu,
    geometry::SteelMemberGeometry,
    opts::NLPWOptions;
    Mux_neg = Mu,
    Ix_min = nothing,
    Ix_min_total = nothing,
    Tu = 0.0,
    L_span = nothing,
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    problem = SteelWBeamNLPProblem(Mu, Vu, geometry, opts; Mux_neg=Mux_neg, Ix_min=Ix_min, Ix_min_total=Ix_min_total, Tu=Tu, L_span=L_span)
    
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )
    
    built = build_w_beam_nlp_result(problem, opt_result)
    return _w_beam_nlp_verify(built, problem, geometry, Mu, Vu, Mux_neg, Tu)
end

"""
    size_steel_w_beams_nlp(Mu, Vu, geometries, opts; Ix_min) -> Vector{WColumnNLPResult}

Size multiple W-shape beams using continuous (NLP) optimization.

`Ix_min` can be a scalar (applied to all) or a vector (per beam).
"""
function size_steel_w_beams_nlp(
    Mu::Vector,
    Vu::Vector,
    geometries::Vector{<:SteelMemberGeometry},
    opts::NLPWOptions;
    Mux_neg = Mu,
    Ix_min = nothing,
)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(geometries) || throw(ArgumentError("Mu and geometries must have same length"))
    
    results = Vector{WColumnNLPResult}(undef, n)
    for i in 1:n
        Ix_i = isnothing(Ix_min) ? nothing :
               (Ix_min isa AbstractVector ? Ix_min[i] : Ix_min)
        Mux_neg_i = Mux_neg isa AbstractVector ? Mux_neg[i] : Mux_neg
        results[i] = size_steel_w_beam_nlp(Mu[i], Vu[i], geometries[i], opts;
                                          Mux_neg=Mux_neg_i, Ix_min=Ix_i)
    end
    return results
end

# ==============================================================================
# Steel HSS Beam NLP Sizing (Dedicated Beam Formulation)
# ==============================================================================

"""
    size_steel_hss_beam_nlp(Mu, Vu, opts::NLPHSSOptions; Ix_min, x0) -> HSSColumnNLPResult

Size a rectangular HSS beam using continuous (NLP) optimization with
dedicated AISC F7 flexure and G4 shear constraints.

Unlike `size_hss_nlp` (which uses H1-1 interaction with Pu=0), this
formulation directly optimizes for flexure and shear without compression
capacity calculations, producing more efficient beam sections.

# Arguments
- `Mu`: Factored moment — any moment unit
- `Vu`: Factored shear — any force unit
- `opts`: `NLPHSSOptions` with material, dimension bounds, solver settings

# Keyword Arguments
- `Ix_min`: Minimum required Ix for deflection (Length⁴ or bare in⁴). Default: `nothing`.
- `x0`: Initial guess vector (default: automatic)

# Returns
`HSSColumnNLPResult` with `.section::HSSRectSection` for analytical checks.

# Example
```julia
result = size_steel_hss_beam_nlp(60.0u"kN*m", 80.0u"kN",
    NLPHSSOptions(min_outer=4.0u"inch", max_outer=12.0u"inch"))
```
"""
function size_steel_hss_beam_nlp(
    Mu,
    Vu,
    opts::NLPHSSOptions;
    Ix_min = nothing,
    Ix_min_total = nothing,
    Tu = 0.0,
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    problem = SteelHSSBeamNLPProblem(Mu, Vu, opts; Ix_min=Ix_min, Ix_min_total=Ix_min_total, Tu=Tu)
    
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )
    
    built = build_hss_beam_nlp_result(problem, opt_result)
    # Rectangular HSS flexure is AISC F7 (no LTB) and this NLP has Pu = 0,
    # so member length does not enter the strength check. The fabricated
    # section is still accepted only when AISCChecker passes.
    return _hss_beam_nlp_verify(built, problem, Mu, Vu, Tu)
end

"""
    size_steel_hss_beams_nlp(Mu, Vu, opts; Ix_min) -> Vector{HSSColumnNLPResult}

Size multiple HSS beams using continuous (NLP) optimization.

`Ix_min` can be a scalar (applied to all) or a vector (per beam).
"""
function size_steel_hss_beams_nlp(
    Mu::Vector,
    Vu::Vector,
    opts::NLPHSSOptions;
    Ix_min = nothing,
)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    
    results = Vector{HSSColumnNLPResult}(undef, n)
    for i in 1:n
        Ix_i = isnothing(Ix_min) ? nothing :
               (Ix_min isa AbstractVector ? Ix_min[i] : Ix_min)
        results[i] = size_steel_hss_beam_nlp(Mu[i], Vu[i], opts; Ix_min=Ix_i)
    end
    return results
end

"""
`true` when `section` passes the catalog `AISCChecker` for this beam demand.

An I-section whose web is not compact (AISC 360-16 Table B4.1b, Case 15,
corpus: aisc-360-16, page 75) does not pass: its strong-axis flexure needs
§F4/§F5, which `get_Mn` refuses. Snapping the NLP optimum up to 1/16 in can
land a web just past λp, and the grow loop then thickens it.
"""
function _steel_beam_passes(section, material, geometry, demand; max_depth)
    section isa ISymmSection &&
        get_slenderness(section, material).class_w !== :compact && return false
    checker = AISCChecker(; max_depth = max_depth)
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())
    return is_feasible(checker, cache, 1, section, material, demand, geometry)
end

function _w_beam_with_status(built::WColumnNLPResult, status::Symbol)
    return WColumnNLPResult(
        built.section, built.d_opt, built.bf_opt, built.tf_opt, built.tw_opt,
        built.d_final, built.bf_final, built.tf_final, built.tw_final,
        built.area, built.weight_per_ft, built.Ix, built.Iy, built.rx, built.ry,
        status, built.iterations)
end

"""
Grow flange width, then depth, then thicknesses, until `passes` accepts.
Each walk is at most 16 steps of 1/4 in. The fabricated plate girder stays
a plate girder; the catalog checker is the acceptance test.
"""
function _w_beam_grow(built::WColumnNLPResult, problem::SteelWBeamNLPProblem, passes)
    d, bf, tf, tw = built.d_final, built.bf_final, built.tf_final, built.tw_final
    opts = problem.opts
    step = 0.25
    limits = (
        (:bf, bf, to_inches(opts.max_flange_width)),
        (:d, d, to_inches(opts.max_depth)),
        (:tf, tf, to_inches(opts.max_flange_thickness)),
        (:tw, tw, to_inches(opts.max_web_thickness)),
    )
    for (which, _, hi) in limits
        for _ in 1:16
            if which === :bf
                bf + step > hi + 1e-6 && break
                bf = min(bf + step, hi)
            elseif which === :d
                d + step > hi + 1e-6 && break
                d = min(d + step, hi)
            elseif which === :tf
                tf + step > hi + 1e-6 && break
                tf = min(tf + step, hi)
            else
                tw + step > hi + 1e-6 && break
                tw = min(tw + step, hi)
            end
            trial = try
                _w_beam_nlp_at(problem, built.d_opt, built.bf_opt, built.tf_opt, built.tw_opt,
                               d, bf, tf, tw, built.status, built.iterations)
            catch
                continue
            end
            passes(trial.section) && return trial
        end
    end
    return nothing
end

function _w_beam_nlp_verify(
    built::WColumnNLPResult, problem::SteelWBeamNLPProblem,
    geometry::SteelMemberGeometry, Mu, Vu, Mux_neg, Tu,
)
    _rc_column_nlp_acceptable(built.status) || return built
    demand = MemberDemand(1; Mux = Mu, Mux_pos = Mu, Mux_neg = Mux_neg,
                          Vu_strong = Vu, Tu = Tu)
    passes(section) = _steel_beam_passes(
        section, problem.opts.material, geometry, demand;
        max_depth = problem.opts.max_depth)
    passes(built.section) && return built
    repaired = _w_beam_grow(built, problem, passes)
    return isnothing(repaired) ? _w_beam_with_status(built, :infeasible) : repaired
end

function _hss_beam_with_status(built::HSSColumnNLPResult, status::Symbol)
    return HSSColumnNLPResult(
        built.section, built.B_opt, built.H_opt, built.t_opt,
        built.B_final, built.H_final, built.t_final,
        built.area, built.weight_per_ft, status, built.iterations)
end

"""Grow depth, then wall thickness, then width, until `passes` accepts."""
function _hss_beam_grow(built::HSSColumnNLPResult, problem::SteelHSSBeamNLPProblem, passes)
    B, H, t = built.B_final, built.H_final, built.t_final
    opts = problem.opts
    step_o = max(ustrip(u"inch", opts.outer_increment), 0.25)
    step_t = max(ustrip(u"inch", opts.thickness_increment), 0.0625)
    B_max = problem.B_max
    t_max = problem.t_max
    for _ in 1:16
        H + step_o > B_max + 1e-6 && break
        H = min(H + step_o, B_max)
        t = min(t, min(B, H) / 4)
        trial = try
            _hss_beam_nlp_at(built.B_opt, built.H_opt, built.t_opt, B, H, t,
                             built.status, built.iterations)
        catch
            continue
        end
        passes(trial.section) && return trial
    end
    for _ in 1:16
        t + step_t > t_max + 1e-6 && break
        t = min(t + step_t, t_max, min(B, H) / 4)
        trial = try
            _hss_beam_nlp_at(built.B_opt, built.H_opt, built.t_opt, B, H, t,
                             built.status, built.iterations)
        catch
            continue
        end
        passes(trial.section) && return trial
    end
    for _ in 1:16
        B + step_o > B_max + 1e-6 && break
        B = min(B + step_o, B_max)
        trial = try
            _hss_beam_nlp_at(built.B_opt, built.H_opt, built.t_opt, B, H, t,
                             built.status, built.iterations)
        catch
            continue
        end
        passes(trial.section) && return trial
    end
    return nothing
end

function _hss_beam_nlp_verify(built::HSSColumnNLPResult, problem::SteelHSSBeamNLPProblem, Mu, Vu, Tu)
    _rc_column_nlp_acceptable(built.status) || return built
    # F7 has no LTB, and Pu = 0, so this length is not a strength input.
    geometry = SteelMemberGeometry(1.0u"m")
    demand = MemberDemand(1; Mux = Mu, Mux_pos = Mu, Mux_neg = Mu,
                          Vu_strong = Vu, Tu = Tu)
    passes(section) = _steel_beam_passes(
        section, problem.opts.material, geometry, demand;
        max_depth = problem.opts.max_outer)
    passes(built.section) && return built
    repaired = _hss_beam_grow(built, problem, passes)
    return isnothing(repaired) ? _hss_beam_with_status(built, :infeasible) : repaired
end

