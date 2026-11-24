# =============================================================================
# Binary Search Sizing — Lightest Feasible Section per Group
# =============================================================================
#
# Sorts the catalog by objective coefficient (weight, volume, cost, or carbon),
# then binary searches for the lightest feasible section for each member group.
#
# Faster than MIP for single-group sizing or when unique-section constraints
# are not needed. Falls back gracefully when the feasibility landscape is
# non-monotonic (rare for weight-sorted W catalogs).

# Register trace contract for optimize_binary_search (docstring conflict with @traced).
TRACE_REGISTRY[(:optimize_binary_search, :optimizer)] =
    TracedFunctionMeta(:optimize_binary_search, :optimizer,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)

"""
    optimize_binary_search(
        checker::AbstractCapacityChecker,
        demands::AbstractVector{<:AbstractDemand},
        geometries::AbstractVector{<:AbstractMemberGeometry},
        catalog::AbstractVector{<:AbstractSection},
        material::AbstractMaterial;
        objective::AbstractObjective = MinVolume(),
        cache::Union{Nothing, AbstractCapacityCache} = nothing,
        tc::Union{Nothing, TraceCollector} = nothing,
    )

Lightest-feasible section assignment via binary search.

For each member group, sorts the catalog by the objective coefficient
(ascending), then binary searches for the lightest section that passes
all capacity checks. If binary search lands on an infeasible section
(non-monotonic feasibility), falls back to linear scan from the candidate.

Compared to the MIP solver (`optimize_discrete`):
- Much faster for independent groups (no solver overhead)
- Cannot enforce `n_max_sections` (shared section constraints)
- Optimal per-group but not globally optimal when groups are coupled

# Arguments
Same interface as `optimize_discrete`, minus `n_max_sections` and solver options.

# Returns
Named tuple: `(; section_indices, sections, status, objective_value)`
where `section_indices` index into the original (unsorted) catalog.
"""
function optimize_binary_search(
    checker::AbstractCapacityChecker,
    demands::AbstractVector{<:AbstractDemand},
    geometries::AbstractVector{<:AbstractMemberGeometry},
    catalog::AbstractVector{<:AbstractSection},
    material::AbstractMaterial;
    objective::AbstractObjective = MinVolume(),
    cache::Union{Nothing, AbstractCapacityCache} = nothing,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    n_groups = length(demands)
    n_groups == length(geometries) || throw(ArgumentError(
        "demands and geometries must have the same length"))
    n_sections = length(catalog)
    n_sections > 0 || throw(ArgumentError("catalog must be non-empty"))

    emit!(tc, :optimizer, "optimize_binary_search", "", :enter;
          n_groups=n_groups, n_sections=n_sections,
          checker_type=string(typeof(checker)),
          objective_type=string(typeof(objective)))

    lengths = [g.L isa Length ? ustrip(u"m", g.L) : Float64(g.L) for g in geometries]

    # Reuse or build cache
    if cache === nothing
        cache = create_cache(checker, n_sections)
        precompute_capacities!(checker, cache, catalog, material, objective)
    else
        _require_cache_match(checker, cache, catalog, material)
    end

    # Sort catalog indices by objective coefficient (ascending = lightest first)
    sorted_idx = sortperm([get_objective_coeff(checker, cache, j) for j in 1:n_sections])

    # Per-group binary search (independent → parallelizable)
    section_indices = Vector{Int}(undef, n_groups)
    sections = Vector{eltype(catalog)}(undef, n_groups)
    group_obj = Vector{Float64}(undef, n_groups)
    all_feasible = Threads.Atomic{Bool}(true)

    Threads.@threads for i in 1:n_groups
        idx = _binary_search_feasible(
            checker, cache, catalog, material,
            demands[i], geometries[i], sorted_idx)

        if idx == 0
            Threads.atomic_and!(all_feasible, false)
            # Placeholder — will throw below
            section_indices[i] = 0
            group_obj[i] = Inf
        else
            section_indices[i] = idx
            sections[i] = catalog[idx]
            group_obj[i] = get_objective_coeff(checker, cache, idx) * lengths[i]
        end
    end

    if !all_feasible[]
        infeasible = findall(==(0), section_indices)
        msgs = [get_feasibility_error_msg(checker, demands[i], geometries[i])
                for i in infeasible]
        emit!(tc, :optimizer, "optimize_binary_search", "", :failure;
              reason="no_feasible_sections",
              infeasible_groups=infeasible,
              n_infeasible=length(infeasible))
        throw(ArgumentError(
            "No feasible sections for group(s) $(infeasible): $(join(msgs, "; "))"))
    end

    status = :OPTIMAL
    obj_val = sum(group_obj)

    emit!(tc, :optimizer, "optimize_binary_search", "", :exit;
          status=string(status),
          objective_value=obj_val)
    return (; section_indices, sections, status, objective_value=obj_val)
end

"""
    separable_lower_bound(checker, demands, geometries, catalog, material;
                          objective=MinVolume(), cache=nothing) -> Float64

Certified lower bound on the discrete sizing optimum for ANY problem that adds
only COUPLING constraints on top of per-group feasibility — an `n_max_sections`
part-count cap, a shared-section requirement, an inventory limit, and the like.
Relaxing every such constraint leaves the separable problem, whose optimum is
`Σ_g (lightest feasible coeff)_g · L_g`; dropping constraints can only lower the
minimum, so this value never exceeds the constrained optimum.

It is the SAME quantity [`optimize_binary_search`](@ref) returns, exposed as a
bound: cheap (per-group binary search, no MIP) and far TIGHTER than the
continuous convex-hull envelope ([`relaxation_lower_bound`](@ref)) because it uses
the actual lightest feasible catalog section per group rather than a smooth
idealisation. Pair it with [`optimality_gap`](@ref) to certify how close a
coupling-constrained design (e.g. a part-count-capped solve) sits to the global
catalog optimum without enumerating the catalog.
"""
function separable_lower_bound(
    checker::AbstractCapacityChecker,
    demands::AbstractVector{<:AbstractDemand},
    geometries::AbstractVector{<:AbstractMemberGeometry},
    catalog::AbstractVector{<:AbstractSection},
    material::AbstractMaterial;
    objective::AbstractObjective = MinVolume(),
    cache::Union{Nothing, AbstractCapacityCache} = nothing,
)
    return optimize_binary_search(checker, demands, geometries, catalog, material;
                                  objective = objective, cache = cache).objective_value
end

"""
Binary search for the lightest feasible section in a weight-sorted catalog.

Returns the original catalog index of the lightest feasible section,
or 0 if no section is feasible.
"""
function _binary_search_feasible(
    checker::AbstractCapacityChecker,
    cache::AbstractCapacityCache,
    catalog::AbstractVector{<:AbstractSection},
    material::AbstractMaterial,
    demand::AbstractDemand,
    geometry::AbstractMemberGeometry,
    sorted_idx::Vector{Int},
)::Int
    n = length(sorted_idx)
    n == 0 && return 0

    # The heaviest section can fail a depth limit while a lighter section
    # passes. Feasibility is not monotone in catalog order, so that case is
    # a full scan. When the heaviest does pass, binary search still finds a
    # feasible section and the scan below it keeps the lightest feasible one.
    heaviest = sorted_idx[n]
    if !is_feasible(checker, cache, heaviest, catalog[heaviest], material, demand, geometry)
        return _lightest_feasible(checker, cache, catalog, material, demand, geometry,
                                   sorted_idx, 1, n)
    end

    lightest = sorted_idx[1]
    if is_feasible(checker, cache, lightest, catalog[lightest], material, demand, geometry)
        return lightest
    end

    # Invariant: sorted_idx[lo] is infeasible, sorted_idx[hi] is feasible.
    lo, hi = 1, n
    while hi - lo > 1
        mid = (lo + hi) >>> 1
        j = sorted_idx[mid]
        if is_feasible(checker, cache, j, catalog[j], material, demand, geometry)
            hi = mid
        else
            lo = mid
        end
    end

    return _lightest_feasible(checker, cache, catalog, material, demand, geometry,
                              sorted_idx, 1, hi)
end

"""Lightest feasible catalog index in `sorted_idx[lo:hi]`, or 0."""
function _lightest_feasible(
    checker, cache, catalog, material, demand, geometry,
    sorted_idx::Vector{Int}, lo::Int, hi::Int,
)::Int
    best = 0
    best_obj = Inf
    for k in lo:hi
        j = sorted_idx[k]
        obj = get_objective_coeff(checker, cache, j)
        obj >= best_obj && continue
        is_feasible(checker, cache, j, catalog[j], material, demand, geometry) || continue
        best = j
        best_obj = obj
    end
    return best
end
