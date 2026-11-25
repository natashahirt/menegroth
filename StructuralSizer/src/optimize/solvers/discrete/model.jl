# =============================================================================
# Generic Discrete Optimization (Checker-Based)
# =============================================================================

# Register trace contract for single-material optimize_discrete
TRACE_REGISTRY[(:optimize_discrete, :optimizer)] =
    TracedFunctionMeta(:optimize_discrete, :optimizer,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)

"""
    _explain_chosen(checker, candidate, indices, demands, geometries, tc, fn)
        -> Vector{FeasibilityExplanation}

Every check of each group's chosen section, without short-circuiting.
`candidate(k)` returns `(cache, j, section, material)` for chosen index `k`.
One call per group, so it runs on every solve, not only when tracing.
"""
function _explain_chosen(checker, candidate, indices, demands, geometries, tc, fn::String)
    return map(eachindex(indices)) do i
        cache, j, section, material = candidate(indices[i])
        expl = explain_feasibility(checker, cache, j, section, material,
                                   demands[i], geometries[i])
        tc === nothing || emit!(tc, :optimizer, fn, "group_$i", :decision;
              phase="post_solve_explanation",
              section=string(section),
              passed=expl.passed,
              governing_check=expl.governing_check,
              governing_ratio=expl.governing_ratio,
              n_checks=length(expl.checks),
              checks=[(name=c.name, passed=c.passed, ratio=c.ratio,
                       code_clause=c.code_clause) for c in expl.checks])
        expl
    end
end

"""
Groups whose chosen section passed `is_feasible` but whose explanation fails.
The two are separate implementations of one check; a disagreement means they
have drifted.
"""
function _explanation_disagreements(explanations)
    out = String[]
    for (i, e) in enumerate(explanations)
        e.passed && continue
        push!(out, "group $i: explain_feasibility fails ($(e.governing_check), " *
                   "ratio $(round(e.governing_ratio; digits=3))) on a section " *
                   "is_feasible accepted")
    end
    return out
end

"""
    optimize_discrete(
        checker::AbstractCapacityChecker,
        demands::AbstractVector{<:AbstractDemand},
        geometries::AbstractVector{<:AbstractMemberGeometry},
        catalog::AbstractVector{<:AbstractSection},
        material::AbstractMaterial;
        objective::AbstractObjective = MinVolume(),
        n_max_sections::Integer = 0,
        optimizer::Symbol = :auto,
        mip_gap::Real = 1e-4,
        output_flag::Integer = 0,
    )

Generic discrete section assignment using a pluggable capacity checker.

This is the material-agnostic core optimization routine. The `checker` parameter
implements the `is_feasible` interface for the specific design code.

# Arguments
- `checker`: Capacity checker implementing `is_feasible(checker, ...)` 
- `demands`: Vector of demand objects (material-specific type)
- `geometries`: Vector of geometry objects (material-specific type)
- `catalog`: Vector of sections to choose from
- `material`: Material for capacity calculations

# Keyword Arguments
- `objective`: Optimization objective (default: `MinVolume()`)
- `n_max_sections`: Max unique sections (0 = no limit)
- `optimizer`: `:auto`, `:highs`, or `:gurobi`
- `mip_gap`: MIP optimality gap tolerance
- `output_flag`: Solver verbosity (0 = silent)
- `time_limit_sec`: Maximum solver wall-clock time in seconds (default 30)
- `feasible`: Optional per-group vector of ALLOWED catalog indices. When supplied
  it is INTERSECTED with the internal per-group capacity screening (never a
  substitute for it), so a caller can narrow one group's candidate set (e.g. a
  per-group catalog / depth / deflection restriction) without touching any other
  group. `nothing` (default) reproduces the prior behavior byte-for-byte.
- `mip_start`: Optional per-group vector of prior catalog indices used purely as a
  MIP warm start (`JuMP.set_start_value` on the binaries). This is a solver HINT
  only — it seeds the branch-and-bound incumbent to shorten solve time; it adds no
  constraint and cannot change the feasible region. When the solver returns
  `OPTIMAL` and the optimum is unique (or resolved by the deterministic `argmax`
  tie-break used below), the chosen sections are identical to a cold solve. A prior
  index that is no longer feasible for its group is silently skipped (a partial
  warm start is valid). `nothing` (default) reproduces prior behavior byte-for-byte.
  With `n_max_sections > 0` the coupling `z` (section-usage) binaries are seeded
  consistently with the capped `x`, so the hint stays valid; it preserves the
  optimal objective but — unlike the separable `n_max_sections == 0` case — need
  not reproduce the exact assignment when several section sets are equally optimal.
- `budget`: Optional `(secondary_objective, budget_value)` tuple that turns this
  into an **ε-constraint** solve: `objective` is still minimized, but subject to the
  total of `secondary_objective` (summed over all groups, same length-weighted
  convention as the primary objective) being `≤ budget_value`. Sweeping the budget
  across the secondary objective's range traces the full Pareto front — including
  non-convex points that a weighted-sum scalarization provably misses (see
  [`pareto_front`](@ref)). `budget_value` must be expressed in the secondary
  objective's unit-stripped total (per-unit-length coefficient × length in metres),
  matching what the MIP sees. When the budget is tighter than the single-objective
  optimum of `secondary_objective`, the solve is infeasible and a result with an
  empty `section_indices` (and `objective_value = Inf`) is returned rather than
  throwing. `nothing` (default) reproduces prior behavior byte-for-byte.
- `budget_cache`: Optional precomputed capacity cache for the `budget` secondary
  objective (avoids re-running `precompute_capacities!` for every budget in a
  Pareto sweep). When `nothing`, it is built internally.

# Returns
Named tuple: `(; section_indices, sections, status, objective_value)`

# Example
```julia
checker = AISCChecker(; deflection_limit=1/360, prefer_penalty=1.05)
demands = [MemberDemand(1; Mux=100e3), MemberDemand(2; Mux=150e3)]
geometries = [SteelMemberGeometry(6.0; Lb=6.0), SteelMemberGeometry(8.0; Lb=8.0)]
result = optimize_discrete(checker, demands, geometries, all_W(), A992_Steel)
```
"""
function optimize_discrete(
    checker::AbstractCapacityChecker,
    demands::AbstractVector{<:AbstractDemand},
    geometries::AbstractVector{<:AbstractMemberGeometry},
    catalog::AbstractVector{<:AbstractSection},
    material::AbstractMaterial;
    objective::AbstractObjective = MinVolume(),
    n_max_sections::Integer = 0,
    optimizer::Symbol = :auto,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    time_limit_sec::Real = 30.0,
    cache::Union{Nothing, AbstractCapacityCache} = nothing,
    feasible::Union{Nothing, Vector{Vector{Int}}} = nothing,
    mip_start::Union{Nothing, Vector{Int}} = nothing,
    budget::Union{Nothing, Tuple{AbstractObjective, <:Real}} = nothing,
    budget_cache::Union{Nothing, AbstractCapacityCache} = nothing,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    n_groups = length(demands)
    n_groups == length(geometries) || throw(ArgumentError("demands and geometries must have the same length"))
    n_sections = length(catalog)

    # Optional externally-supplied per-group candidate restriction (e.g.
    # StructuralSynthesizer member_group_overrides: a per-group catalog / max_depth /
    # deflection narrowing). It is INTERSECTED with the internal capacity screening
    # below, so it can only ever REMOVE candidates, never admit an
    # unchecked one — capacity feasibility always still runs through `checker`.
    # `feasible === nothing` (the default) reproduces the prior behavior exactly.
    feasible_restrict = feasible
    if feasible_restrict !== nothing
        length(feasible_restrict) == n_groups || throw(ArgumentError(
            "feasible restriction must have one entry per group (got " *
            "$(length(feasible_restrict)) for $n_groups groups)"))
        # Defense-in-depth: a per-group `feasible` mask is exact-first-safe ONLY when
        # n_max_sections == 0. With a section-count cap the MIP couples groups, so an
        # externally-narrowed group could force a coupled group onto an unchecked /
        # unconservative section. Refuse the combination at the SZ layer (the SS layer
        # already enforces this invariant, but this backstops any direct caller).
        n_max_sections == 0 || throw(ArgumentError(
            "feasible restriction is only supported with n_max_sections == 0 " *
            "(got n_max_sections=$n_max_sections); combining a per-group feasible " *
            "mask with a section-count cap couples groups and is not exact-first-safe"))
    end

    if mip_start !== nothing
        length(mip_start) == n_groups || throw(ArgumentError(
            "mip_start must have one entry per group (got $(length(mip_start)) for " *
            "$n_groups groups)"))
    end

    # A budget (ε-constraint) solve is skipped by the memo: each Pareto-sweep budget
    # is a distinct problem, so hits would be rare, and gating on `budget === nothing`
    # keeps the unconstrained path's memo behavior byte-for-byte identical.
    memo_key = nothing
    if tc === nothing && budget === nothing
        try
            # The catalog is the object itself. A rebuilt catalog, even one
            # with the same section names and areas, is a miss. Editing a
            # section inside a cached catalog is not detected.
            memo_key = (
                _memo_token((
                    checker, demands, geometries, material, objective,
                    Int(n_max_sections), optimizer, Float64(mip_gap),
                    Float64(time_limit_sec), feasible, mip_start,
                )),
                objectid(catalog),
            )
            hit = _discrete_memo_get(memo_key)
            if hit !== nothing
                return (;
                    section_indices = copy(hit.section_indices),
                    sections = copy(hit.sections),
                    status = hit.status,
                    normalized_status = hit.normalized_status,
                    objective_value = hit.objective_value,
                    objective = hit.objective,
                    backend = hit.backend,
                    diagnostics = copy(hit.diagnostics),
                    explanations = copy(hit.explanations),
                )
            end
        catch
            memo_key = nothing
        end
    end

    emit!(tc, :optimizer, "optimize_discrete", "", :enter;
          n_groups=n_groups, n_sections=n_sections,
          checker_type=string(typeof(checker)),
          objective_type=string(typeof(objective)),
          n_max_sections=n_max_sections)

    # Extract lengths for objective calculation
    # Strip units — JuMP can't handle Unitful quantities in expressions
    lengths = [g.L isa Length ? ustrip(u"m", g.L) : Float64(g.L) for g in geometries]
    
    # Reuse provided cache or create a fresh one
    if cache === nothing
        cache = create_cache(checker, n_sections)
        precompute_capacities!(checker, cache, catalog, material, objective)
    else
        _require_cache_match(checker, cache, catalog, material)
    end
    
    # Filter feasible sections per group (each group is independent)
    feasible = Vector{Vector{Int}}(undef, n_groups)
    errors = Vector{Union{Nothing, String}}(nothing, n_groups)

    if Threads.nthreads() > 1
        Threads.@threads for i in 1:n_groups
            allow = feasible_restrict === nothing ? nothing : Set(feasible_restrict[i])
            idxs = Int[]
            for j in 1:n_sections
                (allow === nothing || j in allow) || continue
                if is_feasible(checker, cache, j, catalog[j], material, demands[i], geometries[i])
                    push!(idxs, j)
                end
            end
            if isempty(idxs)
                errors[i] = get_feasibility_error_msg(checker, demands[i], geometries[i])
            end
            feasible[i] = idxs
        end
    else
        for i in 1:n_groups
            allow = feasible_restrict === nothing ? nothing : Set(feasible_restrict[i])
            idxs = Int[]
            for j in 1:n_sections
                (allow === nothing || j in allow) || continue
                if is_feasible(checker, cache, j, catalog[j], material, demands[i], geometries[i])
                    push!(idxs, j)
                end
            end
            if isempty(idxs)
                errors[i] = get_feasibility_error_msg(checker, demands[i], geometries[i])
            end
            feasible[i] = idxs
        end
    end

    emit!(tc, :optimizer, "optimize_discrete", "", :decision;
          phase="feasibility_screening",
          feasible_counts=[length(f) for f in feasible],
          any_infeasible=any(!isnothing, errors))

    # Check for infeasible groups (sequential — only on error path)
    for i in 1:n_groups
        if !isnothing(errors[i])
            diag = diagnose_infeasibility(checker, cache, catalog, material, demands[i], geometries[i])
            msg = "No feasible sections for group $i: $(errors[i])"
            if !isnothing(diag)
                msg *= ". Diagnostic: $diag"
            end
            emit!(tc, :optimizer, "optimize_discrete", "group_$i", :failure;
                  reason="no_feasible_sections", message=msg)
            throw(ArgumentError(msg))
        end
    end
    
    # Build MIP model
    opt_factory, solver = _choose_mip_optimizer(optimizer)
    m = JuMP.Model(opt_factory)
    
    emit!(tc, :optimizer, "optimize_discrete", "", :decision;
          phase="solver_selection", solver=string(solver))

    if solver === :highs
        # HiGHS expects Bool for output_flag
        JuMP.set_optimizer_attribute(m, "output_flag", output_flag > 0)
        JuMP.set_optimizer_attribute(m, "mip_rel_gap", mip_gap)
        JuMP.set_optimizer_attribute(m, "time_limit", Float64(time_limit_sec))
    else
        if output_flag == 0
            JuMP.set_silent(m)
        else
            JuMP.set_optimizer_attribute(m, "OutputFlag", output_flag)
        end
        JuMP.set_optimizer_attribute(m, "MIPGap", mip_gap)
        JuMP.set_optimizer_attribute(m, "TimeLimit", Float64(time_limit_sec))
    end
    
    # Decision: x[i,j] = 1 if group i uses section j
    JuMP.@variable(m, x[i=1:n_groups, j=feasible[i]], binary=true)
    JuMP.@constraint(m, [i=1:n_groups], sum(x[i,j] for j in feasible[i]) == 1)
    
    # Optional: limit unique sections
    if n_max_sections > 0
        JuMP.@variable(m, z[j=1:n_sections], binary=true)
        JuMP.@constraint(m, [j=1:n_sections],
            sum(x[i,j] for i in 1:n_groups if j in feasible[i]) <= n_groups * z[j]
        )
        JuMP.@constraint(m, sum(z[j] for j in 1:n_sections) <= n_max_sections)
    end
    
    # Minimize objective
    JuMP.@objective(m, Min, 
        sum(sum(x[i,j] * get_objective_coeff(checker, cache, j) * lengths[i] 
                for j in feasible[i]) 
            for i in 1:n_groups))

    # Optional ε-constraint: bound the TOTAL of a secondary objective (same
    # length-weighted convention as the primary) by `budget_value`. Minimizing the
    # primary objective across a sweep of budgets traces the full Pareto front,
    # including non-convex points a weighted-sum scalarization cannot reach. The
    # secondary coefficients come from their own precomputed cache so the constraint
    # uses the exact per-section values the primary objective would (rebar split etc.).
    if budget !== nothing
        budget_obj, budget_value = budget
        bcache = budget_cache
        if bcache === nothing
            bcache = create_cache(checker, n_sections)
            precompute_capacities!(checker, bcache, catalog, material, budget_obj)
        else
            _require_cache_match(checker, bcache, catalog, material)
        end
        JuMP.@constraint(m,
            sum(sum(x[i,j] * get_objective_coeff(checker, bcache, j) * lengths[i]
                    for j in feasible[i])
                for i in 1:n_groups) <= Float64(budget_value))
        emit!(tc, :optimizer, "optimize_discrete", "", :decision;
              phase="epsilon_constraint",
              budget_objective=string(typeof(budget_obj)),
              budget_value=Float64(budget_value))
    end

    # Optional MIP warm start (hint only — no constraint, cannot alter the feasible
    # region or the optimum). With a section-count cap the coupling `z` binaries are
    # seeded too (consistent with the capped `x`), so the start remains valid.
    if mip_start !== nothing
        if n_max_sections == 0
            _apply_mip_start!(x, feasible, mip_start)
        else
            _apply_mip_start!(x, z, feasible, mip_start, n_sections)
        end
    end

    JuMP.optimize!(m)
    
    status = JuMP.termination_status(m)

    # ε-constraint infeasibility (budget tighter than the secondary objective's own
    # optimum) is an expected, benign outcome of a Pareto budget sweep — not an
    # error. Return an empty-assignment result with the same shape so the caller can
    # skip the point. This early return only fires on the budget path; the
    # unconstrained path keeps its exact prior control flow.
    if budget !== nothing && JuMP.primal_status(m) != JuMP.MOI.FEASIBLE_POINT
        emit!(tc, :optimizer, "optimize_discrete", "", :exit;
              status=string(status), objective_value=Inf, infeasible_budget=true)
        return (;
            section_indices = Int[],
            sections = eltype(catalog)[],
            status,
            normalized_status = _normalized_moi_status(status, JuMP.primal_status(m)),
            objective_value = Inf,
            objective,
            backend = :mip,
            diagnostics = String[],
            explanations = FeasibilityExplanation[],
        )
    end

    if status == JuMP.MOI.TIME_LIMIT
        ps = JuMP.primal_status(m)
        ps == JuMP.MOI.FEASIBLE_POINT ||
            error("MIP timed out with no feasible solution (primal_status=$ps)")
        @warn "MIP hit TIME_LIMIT but has a feasible solution — result may be suboptimal"
    elseif status != JuMP.MOI.OPTIMAL
        @warn "MIP did not reach OPTIMAL" status
    end
    
    # Extract solution
    section_indices = Vector{Int}(undef, n_groups)
    sections = Vector{eltype(catalog)}(undef, n_groups)
    for i in 1:n_groups
        vals = [JuMP.value(x[i, j]) for j in feasible[i]]
        bestj = feasible[i][argmax(vals)]
        # Reflection-invariant tie-break (separable case, n_max_sections == 0):
        # when several feasible sections achieve this group's MINIMUM objective
        # coefficient, the MIP is indifferent and the solver's branch order picks
        # one arbitrarily — a member-index-dependent choice that, on a non-chiral
        # plan, hands two mirror-symmetric groups different-but-equal-cost sections
        # and seeds a chiral design (bistable split). Instead pick the LOWEST
        # catalog index among the equal-minimum-cost feasible sections. The catalog
        # and the feasibility screen are shared by every group, so two groups with
        # identical demands resolve the tie to the SAME section. This never changes
        # the total objective (equal coefficient) and the section is already
        # feasibility-screened. Gated on n_max_sections == 0: with a unique-section
        # budget the objective couples groups, so an equal-cost swap could violate
        # the cap or change the optimum, and the solver's coupled choice must stand.
        if n_max_sections == 0 && length(feasible[i]) > 1
            best_coeff = get_objective_coeff(checker, cache, bestj)
            for j in feasible[i]          # feasible[i] is in ascending catalog order
                if get_objective_coeff(checker, cache, j) == best_coeff
                    bestj = j
                    break
                end
            end
        end
        section_indices[i] = bestj
        sections[i] = catalog[bestj]
    end
    
    explanations = _explain_chosen(checker, j -> (cache, j, catalog[j], material),
                                   section_indices, demands, geometries, tc,
                                   "optimize_discrete")

    obj_val = JuMP.objective_value(m)
    emit!(tc, :optimizer, "optimize_discrete", "", :exit;
          status=string(status), objective_value=obj_val,
          n_unique_sections=length(unique(section_indices)))

    normalized_status = _normalized_moi_status(status, JuMP.primal_status(m))
    result = (;
        section_indices,
        sections,
        status,
        normalized_status,
        objective_value=obj_val,
        objective,
        backend=:mip,
        diagnostics=_explanation_disagreements(explanations),
        explanations,
    )
    memo_key === nothing || _discrete_memo_put!(memo_key, result)
    return result
end

