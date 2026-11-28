#=
Read-only orbit diagnostic for star/e0c0 (waffle framing).

Proves the premise of the decoupled chirality fix WITHOUT touching any sizer:
  1. The skeleton automorphism group partitions the beam member-groups into
     geometric orbits (mirror / rotation twins).
  2. Within an orbit, the converged design has installed DIFFERENT sections
     (the chirality) ...
  3. ... even though the groups' force demands differ only sub-permille — so a
     reflection-invariant orbit-elementwise-max demand would collapse each orbit
     to one section and remove the chirality by construction.

Nothing here changes a section or a demand; it only reads the converged state.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/sdf_e0c0_orbit_diag.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

using Printf

const SSc = StructuralSynthesizer

"""String name of a group's installed story-beam section (via a representative member)."""
function _group_section_name(struc, gid)
    mg = struc.member_groups[gid]
    isempty(mg.member_indices) && return "(empty)"
    b = struc.beams[first(mg.member_indices)]
    sec = SSc._story_beam_section(struc, b)
    sec === nothing && return "(none)"
    return hasproperty(sec, :name) ? string(sec.name) : string(sec)
end

"""Scalar demand fields compared across orbit mates (whatever the demand carries)."""
const _DEMAND_FIELDS = (:Pu_c, :Pu_t, :Mux, :Mux_pos, :Mux_neg, :Muy, :Vu_strong, :Vu_weak)

_demand_vector(d) = Float64[hasproperty(d, f) ? abs(float(getproperty(d, f))) : 0.0
                            for f in _DEMAND_FIELDS]

"""Max relative spread across a set of demand vectors: max over fields of
(max - min) / max, ignoring fields that are ~0 everywhere."""
function _max_rel_spread(vectors)
    isempty(vectors) && return 0.0
    worst = 0.0
    for k in eachindex(first(vectors))
        vals = [v[k] for v in vectors]
        hi = maximum(vals); lo = minimum(vals)
        hi > 1e-9 || continue
        worst = max(worst, (hi - lo) / hi)
    end
    return worst
end

function main(plan = "star/e0c0")
    println("\n===== e0c0 ORBIT DIAGNOSTIC (read-only) =====")
    p = rib_parameters(plan, :waffle)
    p.max_iterations = 12
    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    design_building(struc, p; restore = false)

    orbits = SSc.member_group_orbits(struc; member_type = :beams)
    n_groups = sum(length, orbits)
    nontrivial = filter(o -> length(o) > 1, orbits)
    println("\nbeam groups: $n_groups  |  orbits: $(length(orbits))  |  " *
            "collapse: $(round(n_groups / length(orbits); digits = 2))x  |  " *
            "multi-member orbits: $(length(nontrivial))")

    # Per-group demand (best-effort; needs a non-stale model after design).
    gid_demand = Dict{UInt64, Any}()
    try
        gids, demands, _ = SSc.member_group_demands(struc; member_edge_group = :beams)
        for (g, d) in zip(gids, demands)
            gid_demand[g] = d
        end
    catch err
        println("  (demand readout skipped: $(sprint(showerror, err)))")
    end

    mismatched = 0
    worst_mismatch_spread = 0.0
    println("\nMulti-member beam orbits (section A | section B | ... ; demand spread):")
    for orb in nontrivial
        names = [_group_section_name(struc, g) for g in orb]
        uniq = unique(names)
        vecs = [_demand_vector(gid_demand[g]) for g in orb if haskey(gid_demand, g)]
        spread = _max_rel_spread(vecs)
        flag = length(uniq) > 1 ? "  <-- MISMATCH" : ""
        if length(uniq) > 1
            mismatched += 1
            worst_mismatch_spread = max(worst_mismatch_spread, spread)
        end
        @printf("  |orbit|=%d  demand_spread=%.3g%%  sections: %s%s\n",
                length(orb), 100 * spread, join(names, " | "), flag)
    end

    println("\n----- SUMMARY -----")
    println("  multi-member orbits:            ", length(nontrivial))
    println("  orbits with mismatched sections: ", mismatched,
            "   (these are the chirality)")
    @printf("  worst demand spread among them:  %.3g%%  (the amplified seed)\n",
            100 * worst_mismatch_spread)
    println("  => an orbit-max demand makes each orbit's groups identical,")
    println("     so all mismatches collapse to one section (chirality removed).")
    println("===== END =====\n")
    return nothing
end

main(get(ENV, "DIAG_PLAN", "star/e0c0"))
