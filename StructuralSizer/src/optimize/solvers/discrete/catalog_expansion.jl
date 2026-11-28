# =============================================================================
# Multi-Material Discrete Optimization
# =============================================================================

"""
    expand_catalog_with_materials(catalog, materials) -> (expanded_catalog, sec_indices, mat_indices)

Create an expanded catalog where each entry is a (section, material) pair.
The expanded catalog has `N_sections × M_materials` entries.

# Returns
- `expanded_catalog`: Vector of sections (repeated for each material)
- `sec_indices`: Maps expanded index k → original section index j
- `mat_indices`: Maps expanded index k → material index m
"""
function expand_catalog_with_materials(
    catalog::AbstractVector{<:AbstractSection},
    materials::AbstractVector{<:AbstractMaterial},
)
    n_sec = length(catalog)
    n_mat = length(materials)
    n_total = n_sec * n_mat

    expanded = Vector{eltype(catalog)}(undef, n_total)
    sec_idx = Vector{Int}(undef, n_total)
    mat_idx = Vector{Int}(undef, n_total)

    k = 0
    for mi in 1:n_mat, ji in 1:n_sec
        k += 1
        expanded[k] = catalog[ji]
        sec_idx[k] = ji
        mat_idx[k] = mi
    end

    return expanded, sec_idx, mat_idx
end

# Register trace contract for multi-material optimize_discrete
TRACE_REGISTRY[(:optimize_discrete_multi, :optimizer)] =
    TracedFunctionMeta(:optimize_discrete_multi, :optimizer,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)

"""
    optimize_discrete(
        checker::AbstractCapacityChecker,
        demands::AbstractVector{<:AbstractDemand},
        geometries::AbstractVector{<:AbstractMemberGeometry},
        catalog::AbstractVector{<:AbstractSection},
        materials::AbstractVector{<:AbstractMaterial};
        kwargs...
    )

Multi-material discrete optimization. Expands the catalog into
`N_sections × M_materials` candidates, precomputes a separate capacity
cache per material, and solves a single MIP that can assign different
materials to different member groups.

# Returns
Named tuple: `(; section_indices, sections, material_indices, materials_chosen,
                 status, objective_value)`

where `section_indices` and `material_indices` index into the original
`catalog` and `materials` vectors respectively.

# Example
```julia
result = optimize_discrete(checker, demands, geometries, catalog,
                           [NWC_4000, NWC_5000, NWC_6000];
                           objective=MinCarbon())
result.materials_chosen  # Vector of materials chosen per group
```
"""
function optimize_discrete(
    checker::AbstractCapacityChecker,
    demands::AbstractVector{<:AbstractDemand},
    geometries::AbstractVector{<:AbstractMemberGeometry},
    catalog::AbstractVector{<:AbstractSection},
    materials::AbstractVector{<:AbstractMaterial};
    objective::AbstractObjective = MinVolume(),
    n_max_sections::Integer = 0,
    optimizer::Symbol = :auto,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    time_limit_sec::Real = 30.0,
    feasible::Union{Nothing, Vector{Vector{Int}}} = nothing,
    mip_start::Union{Nothing, Vector{Int}} = nothing,
    budget::Union{Nothing, Tuple{AbstractObjective, <:Real}} = nothing,
    budget_caches::Union{Nothing, AbstractVector{<:AbstractCapacityCache}} = nothing,
    caches::Union{Nothing, AbstractVector{<:AbstractCapacityCache}} = nothing,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    n_groups = length(demands)
    n_groups == length(geometries) || throw(ArgumentError("demands and geometries must have the same length"))
    n_sec = length(catalog)
    n_mat = length(materials)

    # Optional externally-supplied per-group candidate restriction (expanded-index
    # space, k = (m-1)*n_sec + j). Intersected with the internal capacity screening
    # below; `feasible === nothing` (default) reproduces prior behavior exactly.
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
        # [P2 SZ feasible validation, fix cycle 4] The multi-material overload expects
        # EXPANDED-index-space masks over the full (n_sec * n_mat) candidate set,
        # k = (m-1)*n_sec + j. HARD RANGE CHECK ONLY: every index must be in-range for
        # the ACTUAL expanded space [1, n_sec*n_mat], else refuse fail-loud (always
        # correct — an out-of-range index can never map to a real candidate).
        #
        # We intentionally do NOT try to detect a "single-material-space" mask (all
        # indices <= n_sec). Cycle 3 threw on that heuristic, but it FALSE-POSITIVES a
        # legitimate material-1-only restriction: the material-1 block IS exactly the
        # indices k = (1-1)*n_sec + j = j, all <= n_sec, so a valid in-range mask
        # confined to material 1 is INDISTINGUISHABLE from a mis-spaced single-material
        # mask and must not be rejected. Consequently a caller that mistakenly passes a
        # single-material-space mask on this multi-material overload cannot be caught
        # here — callers must build expanded indices (k = (m-1)*n_sec + j). (Solver-input
        # guard — no code provision, and NOT applicable to the single-material overload,
        # which already matches its own 1..n_sec space.)
        n_expanded = n_sec * n_mat
        for (i, idxs) in enumerate(feasible_restrict)
            for k in idxs
                (1 <= k <= n_expanded) || throw(ArgumentError(
                    "feasible restriction index $k for group $i is out of range for the " *
                    "expanded (n_sec * n_mat) = ($n_sec * $n_mat) = $n_expanded candidate " *
                    "space; the multi-material optimize_discrete expects EXPANDED indices " *
                    "k = (m-1)*n_sec + j, not a single-material-space (1..$n_sec) mask"))
            end
        end
    end

    if mip_start !== nothing
        length(mip_start) == n_groups || throw(ArgumentError(
            "mip_start must have one entry per group (got $(length(mip_start)) for " *
            "$n_groups groups); multi-material expects EXPANDED indices k = (m-1)*n_sec + j"))
    end

    emit!(tc, :optimizer, "optimize_discrete_multi", "", :enter;
          n_groups=n_groups, n_sections=n_sec, n_materials=n_mat,
          checker_type=string(typeof(checker)),
          objective_type=string(typeof(objective)),
          n_max_sections=n_max_sections)

    # Expand catalog: k = (m-1)*n_sec + j
    expanded, sec_idx_map, mat_idx_map = expand_catalog_with_materials(catalog, materials)
    n_total = length(expanded)

    # Extract lengths for objective calculation
    lengths = [g.L isa Length ? ustrip(u"m", g.L) : Float64(g.L) for g in geometries]

    # Precompute one objective cache per material (or reuse caller-supplied caches,
    # e.g. a Pareto sweep that precomputes once and reuses across every budget).
    if caches === nothing
        caches = Vector{AbstractCapacityCache}(undef, n_mat)
        for mi in 1:n_mat
            caches[mi] = create_cache(checker, n_sec)
            precompute_capacities!(checker, caches[mi], catalog, materials[mi], objective)
        end
    else
        length(caches) == n_mat || throw(ArgumentError(
            "caches must have one objective cache per material (got " *
            "$(length(caches)) for $n_mat materials)"))
        for mi in 1:n_mat
            _require_cache_match(checker, caches[mi], catalog, materials[mi])
        end
    end

    # Filter feasible expanded candidates per group
    feasible = Vector{Vector{Int}}(undef, n_groups)
    errors = Vector{Union{Nothing, String}}(nothing, n_groups)

    for i in 1:n_groups
        allow = feasible_restrict === nothing ? nothing : Set(feasible_restrict[i])
        idxs = Int[]
        for k in 1:n_total
            (allow === nothing || k in allow) || continue
            j = sec_idx_map[k]
            mi = mat_idx_map[k]
            if is_feasible(checker, caches[mi], j, catalog[j], materials[mi], demands[i], geometries[i])
                push!(idxs, k)
            end
        end
        if isempty(idxs)
            errors[i] = get_feasibility_error_msg(checker, demands[i], geometries[i])
        end
        feasible[i] = idxs
    end

    emit!(tc, :optimizer, "optimize_discrete_multi", "", :decision;
          phase="feasibility_screening",
          feasible_counts=[length(f) for f in feasible],
          any_infeasible=any(!isnothing, errors))

    # Check for infeasible groups
    for i in 1:n_groups
        if !isnothing(errors[i])
            emit!(tc, :optimizer, "optimize_discrete_multi", "group_$i", :failure;
                  reason="no_feasible_sections", message=errors[i])
            throw(ArgumentError("No feasible sections for group $i (multi-material): $(errors[i])"))
        end
    end

    # Build MIP model
    opt_factory, solver = _choose_mip_optimizer(optimizer)
    m = JuMP.Model(opt_factory)

    emit!(tc, :optimizer, "optimize_discrete_multi", "", :decision;
          phase="solver_selection", solver=string(solver))

    if solver === :highs
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

    # Decision: x[i,k] = 1 if group i uses expanded candidate k
    JuMP.@variable(m, x[i=1:n_groups, k=feasible[i]], binary=true)
    JuMP.@constraint(m, [i=1:n_groups], sum(x[i,k] for k in feasible[i]) == 1)

    # Optional: limit unique (section, material) pairs
    if n_max_sections > 0
        JuMP.@variable(m, z[k=1:n_total], binary=true)
        JuMP.@constraint(m, [k=1:n_total],
            sum(x[i,k] for i in 1:n_groups if k in feasible[i]) <= n_groups * z[k]
        )
        JuMP.@constraint(m, sum(z[k] for k in 1:n_total) <= n_max_sections)
    end

    # Objective: use the cache for the material associated with each expanded index
    JuMP.@objective(m, Min,
        sum(sum(x[i,k] * get_objective_coeff(checker, caches[mat_idx_map[k]], sec_idx_map[k]) * lengths[i]
                for k in feasible[i])
            for i in 1:n_groups))

    # Optional ε-constraint on a secondary objective (same length-weighted total
    # convention as the primary). Each material gets its own secondary cache so the
    # constraint uses the exact per-(section, material) coefficient. Sweeping the
    # budget traces the full cross-material Pareto front (see [`pareto_front`](@ref)).
    if budget !== nothing
        budget_obj, budget_value = budget
        bcaches = budget_caches
        if bcaches === nothing
            bcaches = Vector{AbstractCapacityCache}(undef, n_mat)
            for mi in 1:n_mat
                bcaches[mi] = create_cache(checker, n_sec)
                precompute_capacities!(checker, bcaches[mi], catalog, materials[mi], budget_obj)
            end
        else
            length(bcaches) == n_mat || throw(ArgumentError(
                "budget_caches must have one cache per material (got " *
                "$(length(bcaches)) for $n_mat materials)"))
        end
        JuMP.@constraint(m,
            sum(sum(x[i,k] * get_objective_coeff(checker, bcaches[mat_idx_map[k]], sec_idx_map[k]) * lengths[i]
                    for k in feasible[i])
                for i in 1:n_groups) <= Float64(budget_value))
        emit!(tc, :optimizer, "optimize_discrete_multi", "", :decision;
              phase="epsilon_constraint",
              budget_objective=string(typeof(budget_obj)),
              budget_value=Float64(budget_value))
    end

    # Optional MIP warm start (hint only; expanded-index space). Skipped when
    # n_max_sections > 0 (unseeded coupling `z` variables).
    if mip_start !== nothing && n_max_sections == 0
        _apply_mip_start!(x, feasible, mip_start)
    end

    JuMP.optimize!(m)

    status = JuMP.termination_status(m)

    # ε-constraint infeasibility (budget below the secondary objective's own optimum)
    # is a benign, expected outcome of a Pareto budget sweep — return an empty result
    # with the same shape so the caller can skip the point. Budget-path only; the
    # unconstrained path keeps its exact prior control flow.
    if budget !== nothing && JuMP.primal_status(m) != JuMP.MOI.FEASIBLE_POINT
        emit!(tc, :optimizer, "optimize_discrete_multi", "", :exit;
              status=string(status), objective_value=Inf, infeasible_budget=true)
        return (;
            section_indices = Int[],
            sections = eltype(catalog)[],
            material_indices = Int[],
            materials_chosen = eltype(materials)[],
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
            error("Multi-material MIP timed out with no feasible solution (primal_status=$ps)")
    elseif status != JuMP.MOI.OPTIMAL
        @warn "Multi-material MIP did not reach OPTIMAL" status
    end

    # Extract solution
    section_indices = Vector{Int}(undef, n_groups)
    material_indices = Vector{Int}(undef, n_groups)
    sections = Vector{eltype(catalog)}(undef, n_groups)
    materials_chosen = Vector{eltype(materials)}(undef, n_groups)

    for i in 1:n_groups
        vals = [JuMP.value(x[i, k]) for k in feasible[i]]
        bestk = feasible[i][argmax(vals)]
        j = sec_idx_map[bestk]
        mi = mat_idx_map[bestk]
        section_indices[i] = j
        material_indices[i] = mi
        sections[i] = catalog[j]
        materials_chosen[i] = materials[mi]
    end

    explanations = _explain_chosen(
        checker, i -> (caches[material_indices[i]], section_indices[i],
                       catalog[section_indices[i]], materials[material_indices[i]]),
        1:n_groups, demands, geometries, tc, "optimize_discrete_multi")

    obj_val = JuMP.objective_value(m)
    emit!(tc, :optimizer, "optimize_discrete_multi", "", :exit;
          status=string(status), objective_value=obj_val,
          n_unique_sections=length(unique(section_indices)),
          n_unique_materials=length(unique(material_indices)))

    normalized_status = _normalized_moi_status(status, JuMP.primal_status(m))
    return (;
        section_indices,
        sections,
        material_indices,
        materials_chosen,
        status,
        normalized_status,
        objective_value=obj_val,
        objective,
        backend=:mip,
        diagnostics=_explanation_disagreements(explanations),
        explanations,
    )
end