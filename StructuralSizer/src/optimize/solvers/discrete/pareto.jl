# =============================================================================
# ε-Constraint Pareto Front (Discrete Catalog Selection)
# =============================================================================
#
# A weighted-sum scalarization (`ParetoScalarization`) can only recover the
# SUPPORTED Pareto points — those on the lower convex hull of the objective
# space. Any non-convex ("sunken") part of a discrete front is invisible to it:
# no weight makes such a point the unique scalarized minimum. The ε-constraint
# method fixes this: minimize one objective while BOUNDING the other by a budget,
# then sweep the budget across its feasible range. Because the bound is a hard
# constraint rather than a trade-off weight, every Pareto point — convex or not —
# is reachable at some budget.
#
# This builder sits entirely on top of `optimize_discrete`'s `budget` keyword, so
# it inherits the exact capacity checks, rebar/concrete split, and n_max_sections
# coupling of the underlying MIP.

"""
    ParetoPoint

One non-dominated design on a Pareto front.

# Fields
- `objective1`, `objective2`: unit-stripped length-weighted totals of the two
  objectives (per-unit-length coefficient × member length in metres, summed over
  all groups) — the same convention the MIP optimizes.
- `section_indices`: chosen catalog index per member group.
- `material_indices`: chosen material index per group (multi-material fronts), or
  `nothing` for a single-material front.
- `status`: the terminating MOI status of the solve that produced this point.
"""
struct ParetoPoint
    objective1::Float64
    objective2::Float64
    section_indices::Vector{Int}
    material_indices::Union{Nothing, Vector{Int}}
    status::Any
end

"""Member lengths in metres (unit-stripped), matching the MIP's objective scaling."""
_group_lengths_m(geometries) =
    [g.L isa Length ? ustrip(u"m", g.L) : Float64(g.L) for g in geometries]

"""
Non-dominated filter for a minimize-both objective space. Sorts by `objective1`
ascending (ties broken by `objective2` ascending) and keeps a point only when its
`objective2` strictly improves on every point with a smaller-or-equal `objective1`.
This both discards dominated points and deduplicates equal designs, returning the
frontier ordered by increasing `objective1` (hence decreasing `objective2`).
"""
function _nondominated(points::Vector{ParetoPoint})
    isempty(points) && return points
    sort!(points; by = p -> (p.objective1, p.objective2))
    out = ParetoPoint[]
    best_o2 = Inf
    for p in points
        # The first point is always kept; afterwards keep a point only when its
        # objective2 strictly improves on the best seen so far. (The empty-`out`
        # guard avoids an `Inf - εInf = NaN` threshold on that first comparison.)
        if isempty(out) || p.objective2 < best_o2 - 1e-12 * max(abs(best_o2), 1.0)
            push!(out, p)
            best_o2 = p.objective2
        end
    end
    return out
end

"""
Budget grid over `[o2_lo, o2_hi]` (secondary-objective range), nudged up by a
negligible slack so the lower endpoint stays feasible under solver tolerance.
Returns an empty grid when the range collapses (objectives are aligned).
"""
function _budget_grid(o2_lo::Real, o2_hi::Real, n_points::Integer)
    span = o2_hi - o2_lo
    span > 1e-12 * max(abs(o2_hi), 1.0) || return Float64[]
    slack = 1e-9 * max(abs(o2_hi), 1.0)
    return [o2_lo + span * (t - 1) / (n_points - 1) + slack for t in 1:n_points]
end

"""
    pareto_front(checker, demands, geometries, catalog, material;
                 objective1, objective2, n_points=11, kwargs...) -> Vector{ParetoPoint}

Trace the discrete Pareto front between `objective1` and `objective2` via the
**ε-constraint** method: minimize `objective1` subject to `objective2 ≤ ε`, sweeping
`ε` across its feasible range. Unlike a weighted-sum scalarization, this recovers the
**complete** front, including non-convex points.

The two single-objective optima (anchors) fix the range of the secondary objective;
`n_points` interior-and-endpoint budgets are then solved. Each returned [`ParetoPoint`](@ref)
is a genuine feasible design (every capacity check passed inside the MIP); the result
is dominance-filtered and ordered by increasing `objective1`.

`kwargs...` are forwarded to `optimize_discrete` — so `optimizer`, `mip_gap`,
`time_limit_sec`, and even `n_max_sections` (for a part-count-capped front) all apply.
Do not pass `objective`, `cache`, `budget`, or `budget_cache` through `kwargs`; the
builder sets those itself.

Each ε-constraint solve minimizes `objective1` under its budget, so returned points are
Pareto-efficient up to the solver's `mip_gap`; the dominance filter additionally removes
any weakly-dominated duplicates.

# Example
```julia
front = pareto_front(checker, demands, geometries, catalog, A992_Steel;
                     objective1 = MinWeight(), objective2 = MinCarbon(), n_points = 15)
for p in front
    println(p.objective1, "  ", p.objective2)
end
```
"""
function pareto_front(
    checker::AbstractCapacityChecker,
    demands::AbstractVector{<:AbstractDemand},
    geometries::AbstractVector{<:AbstractMemberGeometry},
    catalog::AbstractVector{<:AbstractSection},
    material::AbstractMaterial;
    objective1::AbstractObjective,
    objective2::AbstractObjective,
    n_points::Integer = 11,
    kwargs...,
)
    n_points >= 2 || throw(ArgumentError("pareto_front: n_points must be ≥ 2 (got $n_points)"))
    n = length(catalog)
    lengths = _group_lengths_m(geometries)

    # Precompute each objective's cache once and reuse it across every solve.
    c1 = create_cache(checker, n); precompute_capacities!(checker, c1, catalog, material, objective1)
    c2 = create_cache(checker, n); precompute_capacities!(checker, c2, catalog, material, objective2)
    total1(idxs) = sum(get_objective_coeff(checker, c1, idxs[i]) * lengths[i] for i in eachindex(idxs))
    total2(idxs) = sum(get_objective_coeff(checker, c2, idxs[i]) * lengths[i] for i in eachindex(idxs))

    # Anchors fix the secondary-objective range [o2_lo, o2_hi].
    a1 = optimize_discrete(checker, demands, geometries, catalog, material;
                           objective = objective1, cache = c1, kwargs...)
    a2 = optimize_discrete(checker, demands, geometries, catalog, material;
                           objective = objective2, cache = c2, kwargs...)
    o2_hi = total2(a1.section_indices)   # secondary at the primary-optimal design
    o2_lo = total2(a2.section_indices)   # secondary optimum

    points = ParetoPoint[
        ParetoPoint(total1(a1.section_indices), o2_hi, a1.section_indices, nothing, a1.status),
        ParetoPoint(total1(a2.section_indices), o2_lo, a2.section_indices, nothing, a2.status),
    ]

    for ε in _budget_grid(o2_lo, o2_hi, n_points)
        r = optimize_discrete(checker, demands, geometries, catalog, material;
                              objective = objective1, cache = c1,
                              budget = (objective2, ε), budget_cache = c2, kwargs...)
        isempty(r.section_indices) && continue
        push!(points, ParetoPoint(total1(r.section_indices), total2(r.section_indices),
                                  r.section_indices, nothing, r.status))
    end

    return _nondominated(points)
end

"""
    pareto_front(checker, demands, geometries, catalog, materials::AbstractVector;
                 objective1, objective2, n_points=11, kwargs...) -> Vector{ParetoPoint}

Multi-material ε-constraint Pareto front: as the single-material method, but the MIP
may assign a different material to each group, so the front is traced over the full
cross-material design space. Each returned [`ParetoPoint`](@ref) carries both
`section_indices` and `material_indices`.
"""
function pareto_front(
    checker::AbstractCapacityChecker,
    demands::AbstractVector{<:AbstractDemand},
    geometries::AbstractVector{<:AbstractMemberGeometry},
    catalog::AbstractVector{<:AbstractSection},
    materials::AbstractVector{<:AbstractMaterial};
    objective1::AbstractObjective,
    objective2::AbstractObjective,
    n_points::Integer = 11,
    kwargs...,
)
    n_points >= 2 || throw(ArgumentError("pareto_front: n_points must be ≥ 2 (got $n_points)"))
    n = length(catalog)
    n_mat = length(materials)
    lengths = _group_lengths_m(geometries)

    # One cache per material per objective, reused across every solve.
    c1 = [create_cache(checker, n) for _ in 1:n_mat]
    c2 = [create_cache(checker, n) for _ in 1:n_mat]
    for mi in 1:n_mat
        precompute_capacities!(checker, c1[mi], catalog, materials[mi], objective1)
        precompute_capacities!(checker, c2[mi], catalog, materials[mi], objective2)
    end
    total1(si, mi) = sum(get_objective_coeff(checker, c1[mi[i]], si[i]) * lengths[i] for i in eachindex(si))
    total2(si, mi) = sum(get_objective_coeff(checker, c2[mi[i]], si[i]) * lengths[i] for i in eachindex(si))

    a1 = optimize_discrete(checker, demands, geometries, catalog, materials;
                           objective = objective1, caches = c1, kwargs...)
    a2 = optimize_discrete(checker, demands, geometries, catalog, materials;
                           objective = objective2, caches = c2, kwargs...)
    o2_hi = total2(a1.section_indices, a1.material_indices)
    o2_lo = total2(a2.section_indices, a2.material_indices)

    points = ParetoPoint[
        ParetoPoint(total1(a1.section_indices, a1.material_indices), o2_hi,
                    a1.section_indices, a1.material_indices, a1.status),
        ParetoPoint(total1(a2.section_indices, a2.material_indices), o2_lo,
                    a2.section_indices, a2.material_indices, a2.status),
    ]

    for ε in _budget_grid(o2_lo, o2_hi, n_points)
        r = optimize_discrete(checker, demands, geometries, catalog, materials;
                              objective = objective1, caches = c1,
                              budget = (objective2, ε), budget_caches = c2, kwargs...)
        isempty(r.section_indices) && continue
        push!(points, ParetoPoint(total1(r.section_indices, r.material_indices),
                                  total2(r.section_indices, r.material_indices),
                                  r.section_indices, r.material_indices, r.status))
    end

    return _nondominated(points)
end
