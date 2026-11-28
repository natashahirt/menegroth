# ==============================================================================
# PROVING SLICE — flat-plate JOINT SEARCH optimality (slab thickness × columns × studs)
# ==============================================================================
#
# The production flat-plate sizer (`punching_strategy = :joint_search`) chooses a
# slab thickness and, at that thickness, each column's size/stud option together
# by embodied carbon (see StructuralSizer/.../pipeline/joint_search.jl and
# docs/flat-plate-joint-sizing-plan.md). It is NOT a ratchet and NOT a MILP: at a
# fixed thickness every column's punching is LOCAL, so the columns are independent
# and each takes its cheapest passing option; the thickness is an outer scan with a
# concrete-only lower-bound early stop. Because the problem decouples at fixed
# thickness, this pruned enumeration already returns the GLOBAL optimum over the
# discrete grid — a MILP would be strictly more work for the same answer.
#
# WHAT THIS SLICE PROVES: on a real DDM flat plate, the production joint_search's
# minimum feasible objective equals an EXHAUSTIVE reference that disables both
# prunings — every thickness scanned (no early stop) and every column size on the
# increment grid evaluated (no cheapest-passing short-circuit). Agreement to
# machine precision certifies that the early stop and the short-circuit never skip
# a cheaper feasible design. The reference (`brute_force_joint_optimum`) reuses the
# identical demand scaling, slab terms, punching checks, and stud design, so a
# disagreement would be a pruning defect, not a mechanics difference.
#
# The comparison is gated behind `SS_PROVE_JOINT_SEARCH=1`; with the flag off the
# production path is byte-identical (no reference solve runs).
#
# Run: julia --project=StructuralSynthesizer \
#        scripts/runners/joint_search_proving_slice.jl

using StructuralSynthesizer
using StructuralSizer
using Unitful
using Printf
const SZ = StructuralSizer

const REL_TOL = 1.0e-9   # production min == exhaustive min (same arithmetic ⇒ exact)

"""Size a 3×3, 30 ft-bay DDM flat plate with small start columns under `:joint_search`."""
function size_joint_fixture(; c0 = 12.0u"inch", kw...)
    opts = FlatPlateOptions(; method = DDM(), punching_strategy = :joint_search, kw...)
    struc = BuildingStructure(gen_medium_office(90.0u"ft", 90.0u"ft", 12.0u"ft", 3, 3, 1))
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for col in struc.columns
        col.c1 = c0
        col.c2 = c0
    end
    slab = first(struc.slabs)
    return SZ.size_flat_plate!(struc, slab, ConcreteColumnOptions();
                               method = DDM(), opts = opts, verbose = false)
end

function main()
    empty!(SZ.JOINT_PROVE_LOG)
    ENV["SS_PROVE_JOINT_SEARCH"] = "1"
    try
        # Cover the stud-bearing variants so the reference exercises bare + studded
        # options and the stud-weight knob, not just one configuration.
        size_joint_fixture()                               # studs allowed (default)
        size_joint_fixture(joint_studs = false)            # bare columns only
        size_joint_fixture(stud_weight = 1.0e6)            # studs priced out
        size_joint_fixture(objective = MinVolume())        # a different objective
    finally
        delete!(ENV, "SS_PROVE_JOINT_SEARCH")
    end

    log = SZ.JOINT_PROVE_LOG
    @printf("%-5s  %14s  %14s  %10s  %7s  %7s  %6s\n",
            "call", "prod minJ", "exhaustive minJ", "rel.err", "prod h", "bf h", "#feas")
    println("-"^80)
    max_relerr = 0.0
    h_mismatch = 0
    empties = 0
    for (k, e) in enumerate(log)
        if e.prod_minJ === nothing || e.bf_minJ === nothing
            empties += 1
            @printf("%-5d  %14s  %14s  %10s  %7s  %7s  %6d\n", k,
                    string(e.prod_minJ), string(e.bf_minJ), "-",
                    string(e.prod_h), string(e.bf_h), e.n_prod_feasible)
            # Both empty is consistent (infeasible at this call); one empty is a defect.
            e.prod_minJ === e.bf_minJ || (max_relerr = Inf)
            continue
        end
        max_relerr = max(max_relerr, e.relerr)
        e.prod_h == e.bf_h || (h_mismatch += 1)
        @printf("%-5d  %14.3f  %14.3f  %10.2e  %7s  %7s  %6d\n", k,
                e.prod_minJ, e.bf_minJ, e.relerr,
                string(e.prod_h), string(e.bf_h), e.n_prod_feasible)
    end
    println("-"^80)
    @printf("joint_search calls: %d   empty(both/one): %d   h near-ties differing: %d\n",
            length(log), empties, h_mismatch)
    @printf("max relative error (production min vs exhaustive min): %.3e   tol: %.1e\n",
            max_relerr, REL_TOL)

    if isempty(log)
        println("NO JOINT_SEARCH CALLS LOGGED ✗  (did the pipeline take the :joint_search path?)")
        error("joint-search proving slice recorded no comparisons")
    end
    ok = max_relerr ≤ REL_TOL
    println(ok ?
        "JOINT SEARCH IS OPTIMAL ✓  (pruned scan == exhaustive grid optimum, exactly)" :
        "JOINT SEARCH SUBOPTIMAL ✗  (a pruning skipped a cheaper feasible design)")
    ok || error("joint-search proving slice failed its optimality claim")
    # An h near-tie differing is allowed (equal objective within the 1% tie rule),
    # but surface it so a reviewer can see the search landed on an equivalent design.
    h_mismatch > 0 && @info "Note: $h_mismatch call(s) chose a different thickness within the tie band (equal objective)."
    return ok
end

main()
