# ==============================================================================
# NLP Column Sizing (Continuous Optimization)
# ==============================================================================

"""Demand stored on the NLP problem and passed to the as-built checker.

A caller [`RCColumnDemand`](@ref) is kept as the same object, so `M1`/`M2`
and `transverse_load` are not replaced by the `M1 = 0` stand-in. `nothing`
builds that stand-in from the envelope `Pu`/`Mux`/`Muy`.
"""
function _rc_column_nlp_use_demand(
    Pu, Mux, Muy,
    opts::NLPColumnOptions,
    demand::Union{Nothing,RCColumnDemand},
)
    isnothing(demand) || return demand
    return RCColumnDemand(1;
        Pu = to_kip(Pu),
        Mux = to_kipft(Mux),
        Muy = to_kipft(Muy),
        βdns = opts.βdns,
    )
end

"""
    size_rc_column_nlp(Pu, Mux, geometry, opts::NLPColumnOptions; Muy=0) -> RCColumnNLPResult

Size a single RC column using continuous (NLP) optimization.

Unlike `size_columns` which selects from a discrete catalog, this function
optimizes column dimensions (b, h) and reinforcement ratio (ρg) continuously
to find the minimum-volume section that satisfies ACI 318 requirements.

Uses the interior point solver (Ipopt) by default via `optimize_continuous`.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `ConcreteMemberGeometry` with Lu, k, braced
- `opts`: `NLPColumnOptions` with material, bounds, solver settings

# Keyword Arguments
- `Muy`: Factored moment about y-axis (default: 0). Ignored when `demand` is set.
- `x0`: Optional start `[b, h, ρg]` in inches and ratio. Solved together
  with the axial-only start, unless it already matches that start.
  `nothing` (default) uses the moment-informed [`initial_guess`](@ref).
- `demand`: Caller [`RCColumnDemand`](@ref). When set, this object — including
  `M1`/`M2` and `transverse_load` — is the demand on the NLP problem and on
  the as-built `ACIColumnChecker` gate. `nothing` (default) builds an envelope
  stand-in with `M1 = 0` and `transverse_load = false`.

# Returns
`RCColumnNLPResult` with:
- `section`: Optimized `RCColumnSection` (rounded to practical dimensions)
- `b_opt`, `h_opt`, `ρ_opt`: Continuous optimal values
- `b_final`, `h_final`: Final dimensions after rounding
- `area`: Final cross-sectional area (sq in)
- `status`: `:optimal`, `:feasible`, `:converged`, `:infeasible`, `:failed`

# Example
```julia
using Unitful
using StructuralSizer: kip

# Define demand and geometry
Pu = 500.0kip
Mux = 200.0kip * u"ft"
geom = ConcreteMemberGeometry(4.0; k=1.0, braced=true)

# Size with defaults
result = size_rc_column_nlp(Pu, Mux, geom, NLPColumnOptions())
println("Optimal: \$(result.b_final)\" × \$(result.h_final)\"")

# Custom options
opts = NLPColumnOptions(
    material = NWC_5000,
    min_dim = 14.0u"inch",
    max_dim = 30.0u"inch",
    prefer_square = 0.1,
    verbose = true
)
result = size_rc_column_nlp(Pu, Mux, geom, opts)
```

# Algorithm
1. Formulates the problem as `RCColumnNLPProblem <: AbstractNLPProblem`
2. For Ipopt, solves from the axial-only start and from the moment-informed
   start (or an explicit `x0`). Random `n_multistart` samples do not replace
   that axial start.
3. Rounds each start's solution to a practical `RCColumnSection` and checks
   that built section with the real `ACIColumnChecker`, whatever the solver
   status. A failing section is repaired (more bars, then larger b and h
   within the bounds); if nothing passes, that start is `:infeasible`.
4. Keeps the acceptable as-built section with the better objective.
   `:infeasible` and `:failed` do not replace `:optimal`, `:feasible`, or
   `:converged`.

See also: [`size_columns`](@ref), [`NLPColumnOptions`](@ref), [`RCColumnNLPProblem`](@ref)
"""
function size_rc_column_nlp(
    Pu,
    Mux,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions;
    Muy = 0.0,
    x0::Union{Nothing,Vector{Float64}} = nothing,
    demand::Union{Nothing,RCColumnDemand,RCColumnDemandSet} = nothing,
)
    problem = if demand isa RCColumnDemandSet
        RCColumnNLPProblem(demand, geometry, opts)
    else
        RCColumnNLPProblem(
            _rc_column_nlp_use_demand(Pu, Mux, Muy, opts, demand), geometry, opts)
    end

    # Grid / NLopt / NonConvex do not consume x0. One solve matches the
    # previous path. Ipopt is local, so try the axial-only basin too.
    if opts.solver !== :ipopt
        opt_result = optimize_continuous(
            problem;
            objective = opts.objective,
            solver = opts.solver,
            maxiter = opts.maxiter,
            tol = opts.tol,
            verbose = opts.verbose,
            x0 = x0,
            n_multistart = opts.n_multistart,
        )
        return _rc_column_nlp_verify_as_built(
            problem, build_rc_column_nlp_result(problem, opt_result))
    end

    x_axial = axial_only_initial_guess(problem)
    x_other = isnothing(x0) ? initial_guess(problem) : copy(x0)
    built = _solve_rc_column_nlp_from(problem, opts, x_axial)
    if !_rc_column_starts_match(problem, x_other, x_axial)
        other = _solve_rc_column_nlp_from(problem, opts, x_other)
        if _rc_column_nlp_candidate_wins(problem, built, other)
            built = other
        end
    end
    return built
end

"""Statuses that may win the two-start comparison.

`:optimal` and `:feasible` meet the KKT tolerance (or the relaxed one).
`:converged` is an iteration-limit or slow-progress stop. In
`size_rc_column_nlp` every status reaches the comparison only after
[`_rc_column_nlp_verify_as_built`](@ref), which turns a section that fails
the real ACI checker into `:infeasible`.
`:infeasible` and `:failed` are not candidates while another start is acceptable.
"""
function _rc_column_nlp_acceptable(status::Symbol)
    return status === :optimal || status === :feasible || status === :converged
end

"""True when two column starts are the same point inside the bounds."""
function _rc_column_starts_match(
    problem::RCColumnNLPProblem,
    a::Vector{Float64},
    b::Vector{Float64},
)
    length(a) == length(b) == n_variables(problem) || return false
    lb, ub = variable_bounds(problem)
    for i in eachindex(a)
        ai = clamp(a[i], lb[i], ub[i])
        bi = clamp(b[i], lb[i], ub[i])
        isapprox(ai, bi; atol=1e-8, rtol=1e-8) || return false
    end
    return true
end

"""Objective of the section `size_rc_column_nlp` would return. Lower is better.

`MinVolume` with no square penalty ranks by final gross area. Every other
objective, including `prefer_square`, uses `objective_fn` at the built
section (`b_final`, `h_final`, and the section's as-built `ρg`) so a squarer
section can win when that penalty asks for it.
"""
function _rc_column_returned_cost(problem::RCColumnNLPProblem, built::RCColumnNLPResult)
    if problem.opts.objective isa MinVolume && problem.opts.prefer_square <= 0
        return built.area
    end
    return objective_fn(problem, [built.b_final, built.h_final, built.section.ρg])
end

"""
    _rc_column_nlp_candidate_wins(problem, incumbent, candidate) -> Bool

`candidate` replaces the axial-only `incumbent` only when it is acceptable
and better. An `:infeasible` or `:failed` solve never replaces an acceptable
one. A start whose built section fails the real ACI checker (and cannot be
repaired) is already `:infeasible` before this comparison. When `prefer_square` is off,
a larger final area does not count as better.
"""
function _rc_column_nlp_candidate_wins(
    problem::RCColumnNLPProblem,
    incumbent::RCColumnNLPResult,
    candidate::RCColumnNLPResult,
)
    cand_ok = _rc_column_nlp_acceptable(candidate.status)
    inc_ok = _rc_column_nlp_acceptable(incumbent.status)
    cand_ok || return false
    inc_ok || return true

    area_smaller = candidate.area < incumbent.area - 1e-6
    area_larger = candidate.area > incumbent.area + 1e-6
    if problem.opts.prefer_square <= 0 && area_larger
        return false
    end

    c_cand = _rc_column_returned_cost(problem, candidate)
    c_inc = _rc_column_returned_cost(problem, incumbent)
    isfinite(c_cand) || return false
    isfinite(c_inc) || return true
    if c_cand < c_inc - 1e-8
        return true
    end
    # Equal objective: keep the smaller snapped section.
    return problem.opts.prefer_square <= 0 && area_smaller && c_cand <= c_inc + 1e-8
end

"""
    _rc_column_nlp_checker(opts) -> ACIColumnChecker

The real ACI column checker set up to enforce what `RCColumnNLPProblem` does:

- `include_slenderness = opts.include_slenderness` (the NLP magnifies Mux
  only when this is on).
- `include_biaxial = true` with `α_biaxial = 1.5`, the NLP's Bresler
  exponent. Both the checker and the NLP skip the biaxial check unless
  Muy > 0.
- `fy_ksi`, `Es_ksi` from `opts.rebar_material`, the same values the NLP
  material tuple uses.
- `max_depth = opts.max_dim`. The checker limits `h` only; `b` is checked
  against the bounds in [`_rc_column_as_built_ok`](@ref).
"""
function _rc_column_nlp_checker(opts::NLPColumnOptions)
    return ACIColumnChecker(;
        include_slenderness = opts.include_slenderness,
        include_biaxial = true,
        α_biaxial = 1.5,
        fy_ksi = fy_ksi(opts.rebar_material),
        Es_ksi = Es_ksi(opts.rebar_material),
        max_depth = opts.max_dim,
    )
end

"""Dimension slack (in) for the `min_dim`/`max_dim` bounds on a built section."""
const _RC_NLP_DIM_TOL_IN = 1e-6

"""
    _rc_column_rho_within_cap(ρg, ρ_max) -> Bool

True when `ρg` does not exceed `ρ_max`.

A section whose ratio is the cap can land one binary ulp above it. That single
ulp is accepted. A larger overshoot, including the `1e-8` band previously
allowed here, is not. This is not a relaxation of ACI 318-19 §10.6.1.1.
"""
function _rc_column_rho_within_cap(ρg::Real, ρ_max::Real)
    ρ = Float64(ρg)
    cap = Float64(ρ_max)
    ρ <= cap && return true
    return ρ <= nextfloat(cap)
end

"""
    _rc_column_as_built_ok(problem, checker, section) -> Bool

True when the built `section` can be returned:

1. `min_dim ≤ b, h ≤ max_dim` (the NLP variable bounds).
2. At most `RC_COLUMN_NLP_MAX_BARS` bars.
3. `0.01 ≤ ρg ≤ 0.08` — ACI 318-19 §10.6.1.1 (aci-318-19, p. 158) — and
   `ρg ≤ opts.ρ_max`. The practical cap does not replace the ACI limits.
   The checker does not test either ratio; this gate does.
4. `is_feasible` of the real `ACIColumnChecker` with every case on the
   problem (the caller demand when one was supplied, including `M1`/`M2`
   and `transverse_load`) and `problem.geometry`, on a one-section capacity cache.
"""
function _rc_column_as_built_ok(
    problem::RCColumnNLPProblem,
    checker::ACIColumnChecker,
    section::RCColumnSection,
)
    opts = problem.opts
    b = ustrip(u"inch", section.b)
    h = ustrip(u"inch", section.h)
    lo = problem.b_min - _RC_NLP_DIM_TOL_IN
    hi = problem.b_max + _RC_NLP_DIM_TOL_IN
    (lo <= b <= hi && lo <= h <= hi) || return false
    length(section.bars) <= RC_COLUMN_NLP_MAX_BARS || return false
    # ACI 318-19 §10.6.1.1 (aci-318-19, p. 158). opts.ρ_max is a tighter
    # practical cap and does not raise the ACI minimum or maximum.
    0.01 <= section.ρg <= 0.08 || return false
    _rc_column_rho_within_cap(section.ρg, opts.ρ_max) || return false

    cache = create_cache(checker, 1)
    # Objective coefficients are not used here; MinVolume needs no material data.
    precompute_capacities!(checker, cache, [section], opts.material, MinVolume())
    return is_feasible(checker, cache, 1, section, opts.material,
                       _rc_nlp_checked_demand(problem), problem.geometry)
end

"""One demand, or a set when the problem carries more than one case."""
function _rc_nlp_checked_demand(problem)
    length(problem.cases) == 1 && return problem.demand
    return RCColumnDemandSet(problem.demand.member_idx, problem.cases)
end

"""Copy of `built` with a different status."""
function _rc_column_nlp_with_status(built::RCColumnNLPResult, status::Symbol)
    return RCColumnNLPResult(
        built.section, built.b_opt, built.h_opt, built.ρ_opt,
        built.b_final, built.h_final, built.area, status, built.iterations)
end

"""
    _rc_column_nlp_repair(problem, checker, built) -> Union{RCColumnNLPResult, Nothing}

Smallest-first search for a section that passes [`_rc_column_as_built_ok`](@ref),
starting from the failed `built` section.

At each `b × h` (start: `b_final × h_final`, held to `max_dim`), try the bar
count `_build_nlp_trial_section` would use for `ρ_opt`, lowered to the largest
even count with `ρg ≤ opts.ρ_max` when it exceeds that cap, then add 2 bars at
a time while the count stays ≤ `RC_COLUMN_NLP_MAX_BARS` and the added steel
keeps `ρg ≤ opts.ρ_max`. A size where even the tie-type minimum count exceeds
`opts.ρ_max` is skipped. If none passes, grow both `b` and `h` by
`dim_increment`, each held to `max_dim`, and retry.

Terminates when the proposed step does not increase `b` or `h` (including a
`dim_increment` so small that `b + incr == b` in Float64), once both sit at
`max_dim`, or when `dim_increment ≤ 0` or `max_dim` is not finite. Each inner
pass tries at most `RC_COLUMN_NLP_MAX_BARS / 2` counts. Returns `nothing`
when no section in that range passes. ACI 318-19 §10.6.1.1 (0.01 and 0.08)
still applies inside [`_rc_column_as_built_ok`](@ref); this search does not
raise `ρ_max` to make the minimum bar count legal.
"""
function _rc_column_nlp_repair(
    problem::RCColumnNLPProblem,
    checker::ACIColumnChecker,
    built::RCColumnNLPResult,
)
    opts = problem.opts
    A_bar = ustrip(u"inch^2", rebar(opts.bar_size).A)
    incr = ustrip(u"inch", opts.dim_increment)
    b_cap = problem.b_max
    b = min(built.b_final, b_cap)
    h = min(built.h_final, b_cap)
    n_failed = length(built.section.bars)
    b_failed = ustrip(u"inch", built.section.b)
    h_failed = ustrip(u"inch", built.section.h)

    while true
        n_top = min(RC_COLUMN_NLP_MAX_BARS, floor(Int, opts.ρ_max * b * h / A_bar))
        # Ipopt often stops at ρ_opt = ρ_max; rounding that count up to even
        # then exceeds ρ_max at every b × h. Start at the largest even count
        # within ρ_max instead of skipping the size.
        n_cap = iseven(n_top) ? n_top : n_top - 1
        n = min(_nlp_trial_bar_count(b, h, built.ρ_opt, opts), n_cap)
        ρ_start = (b > 0 && h > 0) ? n * A_bar / (b * h) : Inf
        if n >= _nlp_min_bars(opts) && _rc_column_rho_within_cap(ρ_start, opts.ρ_max)
            while true
                # `built.section` already failed; do not check it twice.
                same_as_failed = n == n_failed && b == b_failed && h == h_failed
                if !same_as_failed
                    section = _build_nlp_column_section(b, h, n, opts)
                    if !isnothing(section) && _rc_column_as_built_ok(problem, checker, section)
                        return RCColumnNLPResult(
                            section, built.b_opt, built.h_opt, section.ρg,
                            b, h, b * h, built.status, built.iterations)
                    end
                end
                n + 2 <= n_top || break
                n += 2
            end
        end

        (incr > 0 && isfinite(b_cap)) || return nothing
        (b < b_cap || h < b_cap) || return nothing
        b_next = min(b + incr, b_cap)
        h_next = min(h + incr, b_cap)
        # Float64: an increment below spacing leaves b and h unchanged and
        # would otherwise spin while `b < b_cap` stays true.
        (b_next > b || h_next > h) || return nothing
        b = b_next
        h = h_next
    end
end

"""
    _rc_column_nlp_verify_as_built(problem, built) -> RCColumnNLPResult

Check the section `size_rc_column_nlp` would return with the real ACI
checker ([`_rc_column_as_built_ok`](@ref)), whatever the solver status.

- Acceptable status (`:optimal`, `:feasible`, `:converged`) and the built
  section passes: `built` is returned unchanged.
- It fails: [`_rc_column_nlp_repair`](@ref) adds bars, then grows the
  section. A repaired result keeps the solver status and reports the
  repaired section's `b_final`, `h_final`, `area`, and `ρ_opt = ρg`.
- No section passes: status becomes `:infeasible`, so the start cannot win
  the two-start comparison and callers do not treat it as usable.

`:infeasible` and `:failed` solves are returned unchanged.
"""
function _rc_column_nlp_verify_as_built(
    problem::RCColumnNLPProblem,
    built::RCColumnNLPResult,
)
    _rc_column_nlp_acceptable(built.status) || return built
    checker = _rc_column_nlp_checker(problem.opts)
    _rc_column_as_built_ok(problem, checker, built.section) && return built
    repaired = _rc_column_nlp_repair(problem, checker, built)
    return isnothing(repaired) ? _rc_column_nlp_with_status(built, :infeasible) : repaired
end

"""One Ipopt solve from `x_start`, returned as a snapped column result.

The returned section is verified (and repaired if needed) with the real ACI
checker before the caller compares the two starts.
"""
function _solve_rc_column_nlp_from(
    problem::RCColumnNLPProblem,
    opts::NLPColumnOptions,
    x_start::Vector{Float64},
)
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x_start,
        n_multistart = opts.n_multistart,
    )
    return _rc_column_nlp_verify_as_built(
        problem, build_rc_column_nlp_result(problem, opt_result))
end

"""
    size_rc_columns_nlp(Pu, Mux, geometries, opts::NLPColumnOptions; Muy=...) -> Vector{RCColumnNLPResult}

Size multiple RC columns using continuous (NLP) optimization.

Applies `size_rc_column_nlp` to each column independently.

# Arguments
- `Pu`: Vector of factored axial loads
- `Mux`: Vector of factored moments about x-axis
- `geometries`: Vector of `ConcreteMemberGeometry`
- `opts`: `NLPColumnOptions` (shared for all columns)

# Keyword Arguments
- `Muy`: Vector of factored moments about y-axis (default: zeros)

# Returns
Vector of `RCColumnNLPResult`, one per column.

# Example
```julia
Pu = [400.0, 600.0, 800.0] .* kip
Mux = [150.0, 200.0, 250.0] .* kip .* u"ft"
geoms = [ConcreteMemberGeometry(4.0; k=1.0) for _ in 1:3]

results = size_rc_columns_nlp(Pu, Mux, geoms, NLPColumnOptions())
for (i, r) in enumerate(results)
    println("Column \$i: \$(r.b_final)\" × \$(r.h_final)\"")
end
```
"""
function size_rc_columns_nlp(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:ConcreteMemberGeometry},
    opts::NLPColumnOptions;
    Muy::Vector = zeros(length(Pu))
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))

    return _rc_nlp_batch(n, i -> begin
        Muy_i = i <= length(Muy) ? Muy[i] : 0.0
        return _rc_column_nlp_key(Pu[i], Mux[i], Muy_i, geometries[i], opts)
    end) do i
        Muy_i = i <= length(Muy) ? Muy[i] : 0.0
        return size_rc_column_nlp(Pu[i], Mux[i], geometries[i], opts; Muy=Muy_i)
    end
end

"""
    size_rc_columns_nlp(demands, geometries, opts) -> Vector{RCColumnNLPResult}

Size each column from its [`RCColumnDemand`](@ref), keeping `M1`/`M2` and
`transverse_load` on the NLP problem and the as-built check.
"""
function size_rc_columns_nlp(
    demands::Vector{<:Union{RCColumnDemand, RCColumnDemandSet}},
    geometries::Vector{<:ConcreteMemberGeometry},
    opts::NLPColumnOptions,
)
    n = length(demands)
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))
    return _rc_nlp_batch(n, i -> _rc_column_nlp_key(demands[i], geometries[i], opts)) do i
        d = demands[i]
        anchor = d isa RCColumnDemandSet ?
            d.cases[argmax([Float64(to_kip(c.Pu)) for c in d.cases])] : d
        return size_rc_column_nlp(
            anchor.Pu, anchor.Mux, geometries[i], opts; Muy=anchor.Muy, demand=d)
    end
end

const _RC_NLP_MEMO_HITS = Ref(0)

"""Key for one rectangular NLP column. `member_idx` is not part of the key."""
function _rc_column_nlp_key(Pu, Mux, Muy, g::ConcreteMemberGeometry, opts::NLPColumnOptions)
    return (
        Float64(to_kip(Pu)), Float64(to_kipft(Mux)), Float64(to_kipft(Muy)),
        Float64(ustrip(u"m", g.L)), Float64(ustrip(u"m", g.Lu)),
        g.kx, g.ky, g.braced, opts,
    )
end

function _rc_column_nlp_key(d::RCColumnDemandSet, g::ConcreteMemberGeometry, opts::NLPColumnOptions)
    return (
        Tuple(_rc_nlp_case_key(c) for c in d.cases),
        Float64(ustrip(u"m", g.L)), Float64(ustrip(u"m", g.Lu)),
        g.kx, g.ky, g.braced, opts,
    )
end

function _rc_column_nlp_key(d::RCColumnDemand, g::ConcreteMemberGeometry, opts::NLPColumnOptions)
    return (
        Float64(to_kip(d.Pu)), Float64(to_kipft(d.Mux)), Float64(to_kipft(d.Muy)),
        Float64(to_kipft(d.M1x)), Float64(to_kipft(d.M2x)),
        Float64(to_kipft(d.M1y)), Float64(to_kipft(d.M2y)),
        d.βdns, d.transverse_load, d.magnify,
        Float64(ustrip(u"m", g.L)), Float64(ustrip(u"m", g.Lu)),
        g.kx, g.ky, g.braced, opts,
    )
end

"""
Solve columns `1:n`, reusing a result when the load, geometry, and options match.

Each hit is a copy, so later per-column edits do not alias the stored section.
A key that cannot be built falls through to a fresh solve.
"""
function _rc_nlp_batch(compute::Function, n::Int, keyfn)
    results = Vector{RCColumnNLPResult}(undef, n)
    memo = Dict{Any, RCColumnNLPResult}()
    for i in 1:n
        key = try
            keyfn(i)
        catch
            nothing
        end
        if key !== nothing && haskey(memo, key)
            _RC_NLP_MEMO_HITS[] += 1
            results[i] = try
                deepcopy(memo[key])
            catch
                memo[key]
            end
            continue
        end
        results[i] = compute(i)
        key === nothing || (memo[key] = results[i])
    end
    return results
end

# ==============================================================================
# RC Circular Column NLP Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_rc_column_nlp(::Type{RCCircularSection}, Pu, Mux, geometry, opts) -> RCCircularNLPResult

Size a single circular RC column using continuous (NLP) optimization.

Optimizes column diameter (D) and reinforcement ratio (ρg) continuously
to find the minimum-area section that satisfies ACI 318 requirements.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `ConcreteMemberGeometry` with Lu, k, braced
- `opts`: `NLPColumnOptions` with material, bounds, solver settings.
  Use `tie_type=:spiral` for spiral confinement (typical for circular).

# Returns
`RCCircularNLPResult` with:
- `section`: Optimized `RCCircularSection` (rounded to practical diameter)
- `D_opt`, `ρ_opt`: Continuous optimal values
- `D_final`: Final diameter after rounding
- `area`: Final cross-sectional area (sq in)
- `status`: `:optimal`, `:feasible`, `:infeasible`, `:failed`

# Example
```julia
using Unitful
using StructuralSizer: kip

Pu = 500.0kip
Mux = 200.0kip * u"ft"
geom = ConcreteMemberGeometry(4.0; k=1.0, braced=true)

opts = NLPColumnOptions(tie_type=:spiral, min_dim=10.0u"inch", max_dim=36.0u"inch")
result = size_rc_column_nlp(RCCircularSection, Pu, Mux, geom, opts)
println("Optimal diameter: \$(result.D_final)\"")
```

See also: [`size_rc_column_nlp`](@ref), [`NLPColumnOptions`](@ref), [`RCCircularNLPProblem`](@ref)
"""
function size_rc_column_nlp(::Type{RCCircularSection},
    Pu,
    Mux,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions;
    x0::Union{Nothing,Vector{Float64}} = nothing
)
    Pu_kip = to_kip(Pu)
    Mux_kipft = to_kipft(Mux)

    demand = RCColumnDemand(1;
        Pu = Pu_kip,
        Mux = Mux_kipft,
        Muy = 0.0,
        βdns = opts.βdns
    )

    problem = RCCircularNLPProblem(demand, geometry, opts)

    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
        n_multistart = opts.n_multistart,
    )

    return _rc_circular_nlp_verify_as_built(
        problem, build_rc_circular_nlp_result(problem, opt_result))
end

"""Copy of a circular NLP result with a different status."""
function _rc_circular_nlp_with_status(built::RCCircularNLPResult, status::Symbol)
    return RCCircularNLPResult(
        built.section, built.D_opt, built.ρ_opt, built.D_final,
        built.area, status, built.iterations)
end

"""
    _rc_circular_as_built_ok(problem, checker, section) -> Bool

Same acceptance rule as the rectangular column gate, on a circular section:
diameter inside the NLP bounds, at most `RC_COLUMN_NLP_MAX_BARS` bars,
ACI 318-19 §10.6.1.1 (`0.01 ≤ ρg ≤ 0.08`) and `opts.ρ_max`, then
`is_feasible` of `ACIColumnChecker`.
"""
function _rc_circular_as_built_ok(
    problem::RCCircularNLPProblem,
    checker::ACIColumnChecker,
    section::RCCircularSection,
)
    opts = problem.opts
    D = ustrip(u"inch", section.D)
    lo = problem.D_min - _RC_NLP_DIM_TOL_IN
    hi = problem.D_max + _RC_NLP_DIM_TOL_IN
    (lo <= D <= hi) || return false
    length(section.bars) <= RC_COLUMN_NLP_MAX_BARS || return false
    0.01 <= section.ρg <= 0.08 || return false
    _rc_column_rho_within_cap(section.ρg, opts.ρ_max) || return false

    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], opts.material, MinVolume())
    return is_feasible(checker, cache, 1, section, opts.material,
                       _rc_nlp_checked_demand(problem), problem.geometry)
end

"""
    _rc_circular_nlp_repair(problem, checker, built) -> Union{RCCircularNLPResult, Nothing}

Even bar counts at the snapped diameter, starting from the count for `ρ_opt`
lowered to `ρ_max` when rounding would exceed it, then a larger diameter.
Same order as the rectangular repair.
"""
function _rc_circular_nlp_repair(
    problem::RCCircularNLPProblem,
    checker::ACIColumnChecker,
    built::RCCircularNLPResult,
)
    opts = problem.opts
    A_bar = ustrip(u"inch^2", rebar(opts.bar_size).A)
    incr = ustrip(u"inch", opts.dim_increment)
    D_cap = problem.D_max
    D = min(built.D_final, D_cap)
    n_failed = length(built.section.bars)
    D_failed = ustrip(u"inch", built.section.D)

    while true
        Ag = π * D^2 / 4
        n_top = min(RC_COLUMN_NLP_MAX_BARS, floor(Int, opts.ρ_max * Ag / A_bar))
        n_cap = iseven(n_top) ? n_top : n_top - 1
        n = min(_circular_trial_bar_count(D, built.ρ_opt, opts), n_cap)
        ρ_start = Ag > 0 ? n * A_bar / Ag : Inf
        if n >= _nlp_min_bars(opts) && _rc_column_rho_within_cap(ρ_start, opts.ρ_max)
            while true
                same_as_failed = n == n_failed && D == D_failed
                if !same_as_failed
                    section = _build_nlp_circular_section(D, n, opts)
                    if !isnothing(section) && _rc_circular_as_built_ok(problem, checker, section)
                        return RCCircularNLPResult(
                            section, built.D_opt, section.ρg, D,
                            π * D^2 / 4, built.status, built.iterations)
                    end
                end
                n + 2 <= n_top || break
                n += 2
            end
        end
        (incr > 0 && isfinite(D_cap) && D < D_cap) || return nothing
        D_next = min(D + incr, D_cap)
        D_next > D || return nothing
        D = D_next
    end
end

"""
    _rc_circular_nlp_verify_as_built(problem, built) -> RCCircularNLPResult

[`ACIColumnChecker`](@ref) on the snapped circular section. A miss is repaired
by [`_rc_circular_nlp_repair`](@ref); if nothing in the bounds passes, the
status becomes `:infeasible`.
"""
function _rc_circular_nlp_verify_as_built(
    problem::RCCircularNLPProblem,
    built::RCCircularNLPResult,
)
    _rc_column_nlp_acceptable(built.status) || return built
    checker = _rc_column_nlp_checker(problem.opts)
    _rc_circular_as_built_ok(problem, checker, built.section) && return built
    repaired = _rc_circular_nlp_repair(problem, checker, built)
    return isnothing(repaired) ? _rc_circular_nlp_with_status(built, :infeasible) : repaired
end

"""
    size_rc_columns_nlp(::Type{RCCircularSection}, Pu, Mux, geometries, opts) -> Vector{RCCircularNLPResult}

Size multiple circular RC columns using continuous (NLP) optimization.
Applies `size_rc_column_nlp(RCCircularSection, ...)` to each column independently.
"""
function size_rc_columns_nlp(::Type{RCCircularSection},
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:ConcreteMemberGeometry},
    opts::NLPColumnOptions
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))

    results = Vector{RCCircularNLPResult}(undef, n)
    for i in 1:n
        results[i] = size_rc_column_nlp(RCCircularSection, Pu[i], Mux[i], geometries[i], opts)
    end
    return results
end

