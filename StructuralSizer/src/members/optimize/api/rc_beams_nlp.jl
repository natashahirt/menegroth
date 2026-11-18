# ==============================================================================
# RC Beam NLP Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_rc_beam_nlp(Mu, Vu, opts::NLPBeamOptions) -> RCBeamNLPResult

Size a single RC beam using continuous (NLP) optimization.

Optimizes beam width (b), depth (h), and reinforcement ratio (ρ) to find
the minimum-area section satisfying ACI 318 flexure and shear requirements.

# Arguments
- `Mu`: Factored moment — any moment unit (kip·ft, kN·m, etc.)
- `Vu`: Factored shear — any force unit (kip, kN, etc.)
- `opts`: `NLPBeamOptions` with material, bounds, solver settings

# Returns
`RCBeamNLPResult` with:
- `section`: Constructed `RCBeamSection`
- `b_opt`, `h_opt`, `ρ_opt`: Continuous optimal values
- `b_final`, `h_final`: Final dimensions after optional snapping
- `area`: Final cross-sectional area (in²)
- `status`: Solver termination status

# Example
```julia
using Unitful
using StructuralSizer: kip

Mu = 200.0kip * u"ft"
Vu = 40.0kip
opts = NLPBeamOptions(min_depth=14.0u"inch", max_depth=30.0u"inch")
result = size_rc_beam_nlp(Mu, Vu, opts)
println("Section: \$(result.section.name), Area: \$(result.area) in²")
```
"""
function size_rc_beam_nlp(Mu, Vu, opts::NLPBeamOptions;
                          Tu = 0.0,
                          Nu = 0.0,
                          Mu_neg = nothing,
                          x0::Union{Nothing,Vector{Float64}} = nothing)
    problem = RCBeamNLPProblem(Mu, Vu, opts; Tu=Tu, Nu=Nu)

    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )

    result = build_rc_beam_nlp_result(problem, opt_result)
    # Snapped bars can push εt under §10.3.5. The catalog checker is the
    # gate; a miss drops a bar, then deepens, then widens, inside the bounds.
    # Public default Mu_neg = Mu (unsigned envelope) is unchanged.
    Mu_neg_kipft = to_kipft(isnothing(Mu_neg) ? Mu : Mu_neg)
    return _rc_beam_nlp_verify(result, problem, opts, Mu_neg_kipft)
end

"""Accept the snapped beam, or the repaired section, or `:infeasible`."""
function _rc_beam_nlp_verify(
    result::RCBeamNLPResult,
    problem::RCBeamNLPProblem,
    opts::NLPBeamOptions,
    Mu_neg_kipft::Float64,
)
    _rc_column_nlp_acceptable(result.status) || return result
    demand = (
        Mu_kipft = problem.Mu_kipft, Mu_neg_kipft = Mu_neg_kipft,
        Vu_kip = problem.Vu_kip, Nu_kip = problem.Nu_kip, Tu_kipin = problem.Tu_kipin,
    )
    _beam_nlp_passes_checker(result.section, opts; demand...) && return result
    found = _beam_nlp_repair(
        (b, h, n) -> _rc_beam_with_bars(b, h, n, opts), opts,
        result.b_final, result.h_final, problem.b_max, problem.h_max,
        result.ρ_opt, result.section.n_bars,
        sec -> _beam_nlp_passes_checker(sec, opts; demand...),
    )
    isnothing(found) && return RCBeamNLPResult(
        result.section, result.b_opt, result.h_opt, result.ρ_opt,
        result.b_final, result.h_final, result.area, :infeasible, result.iterations)
    section, b, h = found
    return RCBeamNLPResult(
        section, result.b_opt, result.h_opt, result.ρ_opt,
        b, h, b * h, result.status, result.iterations)
end

"""
    _beam_nlp_passes_checker(section, opts; Mu_kipft, Mu_neg_kipft, Vu_kip, Nu_kip, Tu_kipin) -> Bool

`true` when `section` passes [`ACIBeamChecker`](@ref) for this demand.

Span is not an input of the beam NLP, so story-shell deflection is not
part of this gate (`shell_spans` stays empty). Stirrup yield is taken
equal to the longitudinal grade, matching the NLP problem.
"""
function _beam_nlp_passes_checker(
    section,
    opts::NLPBeamOptions;
    Mu_kipft::Float64,
    Mu_neg_kipft::Float64,
    Vu_kip::Float64,
    Nu_kip::Float64,
    Tu_kipin::Float64,
    joist_spacing::Union{Nothing, Length} = nothing,
    joist_direction::Symbol = :one_way,
)
    fy = fy_ksi(opts.rebar_material)
    checker = ACIBeamChecker(;
        fy_ksi = fy,
        fyt_ksi = fy,
        Es_ksi = Es_ksi(opts.rebar_material),
        λ = opts.material.λ,
        max_depth = opts.max_depth,
        joist_spacing = joist_spacing,
        joist_direction = joist_direction,
    )
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], opts.material, MinVolume())
    demand = RCBeamDemand(1;
        Mu = Mu_kipft, Mu_neg = Mu_neg_kipft,
        Vu = Vu_kip, Nu = Nu_kip, Tu = Tu_kipin)
    # Unused by the strength checks. Shell deflection is off.
    geometry = ConcreteMemberGeometry(1.0u"m")
    return is_feasible(checker, cache, 1, section, opts.material, demand, geometry)
end

"""Effective depth (inches) used by the beam NLP cover model."""
function _beam_nlp_d_in(h_in::Real, opts::NLPBeamOptions)
    cov = ustrip(u"inch", opts.cover)
    d_stir = ustrip(u"inch", rebar(opts.stirrup_size).diameter)
    db = ustrip(u"inch", rebar(opts.bar_size).diameter)
    return h_in - cov - d_stir - db / 2
end

"""Bar count the beam builder would ceil to, held to 2–20."""
function _beam_nlp_bar_count(b_in::Real, d_in::Real, ρ::Real, opts::NLPBeamOptions)
    As_bar = ustrip(u"inch^2", rebar(opts.bar_size).A)
    n = max(2, ceil(Int, ρ * b_in * max(d_in, 1.0) / As_bar))
    return min(n, 20)
end

"""Rectangular beam with an explicit bar count. `nothing` if the constructor rejects it."""
function _rc_beam_with_bars(b_in::Real, h_in::Real, n_bars::Int, opts::NLPBeamOptions)
    (2 <= n_bars <= 20) || return nothing
    _beam_nlp_d_in(h_in, opts) > 1 || return nothing
    try
        return RCBeamSection(
            b = b_in * u"inch", h = h_in * u"inch",
            bar_size = opts.bar_size, n_bars = n_bars,
            cover = opts.cover, stirrup_size = opts.stirrup_size,
        )
    catch
        return nothing
    end
end

"""T-beam with an explicit bar count. `bf_in` and `hf_in` are the fixed flange."""
function _rc_tbeam_with_bars(
    bw_in::Real, h_in::Real, n_bars::Int,
    bf_in::Real, hf_in::Real, opts::NLPBeamOptions,
)
    (2 <= n_bars <= 20) || return nothing
    bw_in <= bf_in + 1e-6 || return nothing
    h_in > hf_in + 1 || return nothing
    _beam_nlp_d_in(h_in, opts) > 1 || return nothing
    try
        return RCTBeamSection(
            bw = bw_in * u"inch", h = h_in * u"inch",
            bf = bf_in * u"inch", hf = hf_in * u"inch",
            bar_size = opts.bar_size, n_bars = n_bars,
            cover = opts.cover, stirrup_size = opts.stirrup_size,
        )
    catch
        return nothing
    end
end

"""
    _beam_nlp_repair(make_section, opts, b0, h0, b_max, h_max, ρ, n_failed, passes)

Search for a section `passes` accepts.

Bar rounding raises ρ and can drop εt below ACI 318-11 §10.3.5 (page 142).
Fewer bars are tried first at the snapped size. Then depth grows by
`opts.dim_increment`, then width, and at each new size the count for `ρ`
is walked down to 2. At most 16 dimension steps. Returns `(section, b, h)`
or `nothing`.
"""
function _beam_nlp_repair(
    make_section, opts::NLPBeamOptions,
    b0::Real, h0::Real, b_max::Real, h_max::Real,
    ρ::Real, n_failed::Int, passes;
    widen_first::Bool = false,
)
    incr = ustrip(u"inch", opts.dim_increment)

    function try_counts(b, h, n_hi; skip_failed::Bool)
        for n in n_hi:-1:2
            (skip_failed && n == n_failed && b == b0 && h == h0) && continue
            section = make_section(b, h, n)
            section === nothing && continue
            passes(section) && return (section, Float64(b), Float64(h))
        end
        return nothing
    end

    found = try_counts(b0, h0, n_failed; skip_failed=true)
    found === nothing || return found

    b, h = Float64(b0), Float64(h0)
    for _ in 1:16
        # A joist that snapped past §8.13.2 needs a wider rib before a deeper
        # one: extra depth makes the stem-to-width limit worse.
        grow_width = widen_first && incr > 0 && b + 1e-6 < b_max
        if grow_width
            b = min(b + incr, b_max)
        elseif incr > 0 && h + 1e-6 < h_max
            h = min(h + incr, h_max)
        elseif incr > 0 && b + 1e-6 < b_max
            b = min(b + incr, b_max)
        else
            return nothing
        end
        n_hi = _beam_nlp_bar_count(b, _beam_nlp_d_in(h, opts), ρ, opts)
        found = try_counts(b, h, n_hi; skip_failed=false)
        found === nothing || return found
    end
    return nothing
end

"""
    size_rc_beams_nlp(Mu, Vu, opts::NLPBeamOptions) -> Vector{RCBeamNLPResult}

Size multiple RC beams using continuous (NLP) optimization.
"""
function size_rc_beams_nlp(Mu::Vector, Vu::Vector, opts::NLPBeamOptions;
                           Mu_neg::Vector = Mu,
                           Nu::Vector = zeros_like(Vu))
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(Mu_neg) || throw(ArgumentError("Mu_neg must have same length as Mu"))
    n == length(Nu) || throw(ArgumentError("Nu must have same length as Vu"))

    results = Vector{RCBeamNLPResult}(undef, n)
    for i in 1:n
        results[i] = size_rc_beam_nlp(Mu[i], Vu[i], opts; Mu_neg=Mu_neg[i], Nu=Nu[i])
    end
    return results
end

