# =============================================================================
# Design-dependent capacity coupling for the discrete member MILP
# =============================================================================
#
# When a member's DEMAND is itself a function of the design — the classic case is
# self-weight, where a column's axial load accumulates the weight of every member
# it supports — the naive sizing loop alternates "size against the current demand"
# with "recompute the demand from the new sizes". That Picard / block-Gauss-Seidel
# iteration RATCHETS: it only approaches the self-consistent point from one side,
# one catalog step per pass, and the sequence of solves at stale demands never
# certifies the coupled optimum.
#
# This module removes the iteration when the coupling is LINEAR in the section-
# selection binaries. Self-weight is exactly that: the force section `s` adds is a
# constant `A_s·L·ρg`, so the load a group carries is a linear function of `x`. If,
# in addition, the section's CAPACITY against that load is a precomputable constant
# per candidate (true for axial under a fixed member moment — the AISC Chapter H
# interaction, monotone in axial, inverts to one `P_cap(s)` per section), then the
# whole coupled sizing is a single MILP:
#
#   base_i  +  Σ_{j ∈ sources_i} Σ_t weight_j(t)·x[j,t]   ≤   Σ_s cap_i(s)·x[i,s]
#   └ x-independent load ┘   └──── load from the chosen sections (LINEAR) ────┘      └ capacity of the section chosen for i ┘
#
# Both sides are linear in `x` (exactly one `x[i,s] = 1` per group, so the right
# side evaluates to the chosen section's capacity), so the solver returns the
# globally optimal, self-consistent design in ONE pass with a true optimality
# certificate — no ratchet, and it may move sizes down as freely as up.
#
# This struct is MATERIAL-AGNOSTIC: it is plain `Float64` loads and capacities over
# group/catalog indices. Building `weight` and `cap` (e.g. inverting the H1
# interaction for `P_cap`) is the caller's job, in the layer where the sections and
# the checker are in scope.

"""
    LinearCapacityCoupling

A set of design-dependent, LINEAR capacity constraints for [`optimize_discrete`].
For each constrained group `i` (an entry of `groups`), the member must carry a
load that is a linear function of the section choices and the chosen section must
have at least that capacity:

    base[c] + Σ_{j ∈ sources[c]} Σ_t weight[j][t]·x[j,t]  ≤  Σ_s cap[c][s]·x[i,s]

where `c` is the position of `i` in `groups`. All indices are the solver's own:
`i`, `j` are group indices (`1:n_groups`) and `t`, `s` are catalog indices
(`1:n_sections`). Both sides are linear in the binaries `x`, so the coupled sizing
stays one MILP and is solved exactly in a single pass (no demand-fixpoint
iteration). See this file's header for the self-weight motivation.

# Fields
- `groups`  — the constrained group indices `i` (each needs one coupling row).
- `sources` — aligned to `groups`: for constrained group `i`, the groups whose
              chosen-section load accumulates onto it (may include `i` itself).
- `base`    — aligned to `groups`: the x-independent part of the load on `i`.
- `weight`  — length `n_groups`: `weight[j]` is the per-catalog-section load that
              group `j` contributes when it picks that section (length
              `n_sections`; a group that contributes nothing may be left empty).
- `cap`     — aligned to `groups`: `cap[c]` is the per-catalog-section capacity of
              constrained group `i` against the coupled load (length `n_sections`).

A section whose `cap` is below the minimum achievable load is simply never
selectable for that group — the capacity screening and this constraint together
still certify every returned section, so the coupling can only GUIDE the choice,
never admit an under-capacity member.
"""
struct LinearCapacityCoupling
    groups::Vector{Int}
    sources::Vector{Vector{Int}}
    base::Vector{Float64}
    weight::Vector{Vector{Float64}}
    cap::Vector{Vector{Float64}}
end

"""
    _validate_coupling(coupling, n_groups, n_sections)

Throw an `ArgumentError` if `coupling`'s dimensions are inconsistent with a
problem of `n_groups` groups and `n_sections` catalog entries. Checks the aligned
lengths (`groups`/`sources`/`base`/`cap`), the group/section index ranges, and
that every `weight[j]`/`cap[c]` that is used spans the full catalog.
"""
function _validate_coupling(coupling::LinearCapacityCoupling, n_groups::Int, n_sections::Int)
    nc = length(coupling.groups)
    (length(coupling.sources) == nc && length(coupling.base) == nc &&
     length(coupling.cap) == nc) || throw(ArgumentError(
        "LinearCapacityCoupling: groups, sources, base and cap must have equal " *
        "length (got $nc, $(length(coupling.sources)), $(length(coupling.base)), " *
        "$(length(coupling.cap)))"))
    length(coupling.weight) == n_groups || throw(ArgumentError(
        "LinearCapacityCoupling: weight must have one entry per group " *
        "(got $(length(coupling.weight)) for $n_groups groups)"))
    for (c, i) in enumerate(coupling.groups)
        (1 ≤ i ≤ n_groups) || throw(ArgumentError(
            "LinearCapacityCoupling: constrained group $i out of range 1:$n_groups"))
        length(coupling.cap[c]) == n_sections || throw(ArgumentError(
            "LinearCapacityCoupling: cap[$c] must span the catalog " *
            "(got $(length(coupling.cap[c])) for $n_sections sections)"))
        for j in coupling.sources[c]
            (1 ≤ j ≤ n_groups) || throw(ArgumentError(
                "LinearCapacityCoupling: source group $j (for constrained group " *
                "$i) out of range 1:$n_groups"))
            length(coupling.weight[j]) == n_sections || throw(ArgumentError(
                "LinearCapacityCoupling: weight[$j] must span the catalog " *
                "(got $(length(coupling.weight[j])) for $n_sections sections)"))
        end
    end
    return nothing
end

"""
    _add_capacity_coupling!(m, x, feasible, coupling)

Add one linear capacity-coupling constraint per constrained group of `coupling`
to the JuMP model `m`, over the per-group selection binaries `x[i, j in feasible[i]]`.
Only feasibility-screened candidates appear, so the constraint is consistent with
the model's variable set. Returns nothing.
"""
function _add_capacity_coupling!(m, x, feasible::Vector{Vector{Int}},
                                 coupling::LinearCapacityCoupling)
    for (c, i) in enumerate(coupling.groups)
        load = JuMP.AffExpr(coupling.base[c])
        for j in coupling.sources[c]
            w = coupling.weight[j]
            for t in feasible[j]
                JuMP.add_to_expression!(load, w[t], x[j, t])
            end
        end
        cap_i = coupling.cap[c]
        JuMP.@constraint(m, load <= sum(cap_i[s] * x[i, s] for s in feasible[i]))
    end
    return nothing
end
