# ==============================================================================
# Relaxation continuation sweep (optimization-architecture.md, Pillar B primitive)
# ==============================================================================
#
# Pillar B maps a family of related designs (a load family, a weight sweep, a
# Pareto trace) cheaply by *continuation*: solve the first point, then warm-start
# each neighbouring point from the previous solution. This runner proves the
# continuation primitive against the REAL member MIP, with zero edits to the live
# sizing owners, and reports the certified optimality gap at every step.
#
# The sweep parameter is a global demand factor α scaling the required stiffness
# of every beam (a proxy for a load-case family or a serviceability tightening).
# At each step we solve two ways on the SAME problem:
#   • cold          — full catalog, no hint (the baseline cost);
#   • continuation  — `mip_start` seeded from the previous step's design (step 1
#                     is seeded by R.1's continuous projection).
# The continuation design must reproduce the cold design byte-for-byte at every
# step (a pure hint cannot move the optimum), while costing less in aggregate.
#
# Run: julia --project=StructuralSizer scripts/runners/relaxation_continuation_sweep.jl

using StructuralSizer
using Unitful
import JuMP
const MOI = JuMP.MOI

const DEFLECTION_LIMIT = 1 / 360
const N_GROUPS = 20
const ALPHAS = collect(range(0.8, 1.4; length = 7))   # demand-factor sweep

# Full W catalog → SI property tables (catalog order).
catalog = steel_column_catalog(:w, :all)
Ix_cat = [ustrip(u"m^4", Ix(s)) for s in catalog]
A_cat  = [ustrip(u"m^2", section_area(s)) for s in catalog]
n_cat = length(catalog)

# Base required stiffness per group, kept in the catalog interior so the whole
# α-sweep stays inside the catalog (no growth).
Ix_sorted = sort(Ix_cat)
ranks = round.(Int, range(0.12 * n_cat, 0.58 * n_cat; length = N_GROUPS))
I_base = [Ix_sorted[r] * 1.0005 for r in ranks]
Ls = [6.0 + 0.2 * (g - 1) for g in 1:N_GROUPS]

# Scaling law for the lower-bound certificate and the step-1 projection.
law = fit_section_scaling_law(Ix_cat, A_cat)

# Build deflection-governed demands for a given target vector (I_req encoded via
# δ_max_LL with I_ref = 1 m⁴, so feasibility ⇔ Ix ≥ I_req).
make_demands(targets) = [MemberDemand(g;
                            Mux = 5.0e3,
                            δ_max_LL = targets[g] * DEFLECTION_LIMIT * Ls[g],
                            I_ref = 1.0) for g in 1:N_GROUPS]
geometries = [SteelMemberGeometry(Ls[g]; Lb = Ls[g]) for g in 1:N_GROUPS]
checker = AISCChecker(; deflection_limit = DEFLECTION_LIMIT)

solve(demands; mip_start = nothing) = optimize_discrete(
    checker, demands, geometries, catalog, A992_Steel;
    objective = MinVolume(), mip_start = mip_start, time_limit_sec = 60.0)

# Warm up BOTH solver paths at full problem size with perturbed demands: same
# model-build path (JIT excluded from the timings) but distinct memo keys (no timed
# solve is pre-cached). Both the cold and the mip_start paths must be compiled, or
# the first continuation step pays the mip_start JIT and looks spuriously slow.
println("Warming up (precompile, full size, both solver paths)…")
_ = solve(make_demands(I_base .* 1.37))
_ = solve(make_demands(I_base .* 1.41); mip_start = collect(1:N_GROUPS))

println("\n" * "="^84)
println("Relaxation continuation sweep  (W catalog: $n_cat sections, $N_GROUPS groups, $(length(ALPHAS)) steps)")
println("="^84)
println(rpad("α", 6), rpad("cold (ms)", 12), rpad("cont. (ms)", 12), rpad("×", 7),
        rpad("identical", 11), rpad("LB (m³)", 12), "gap vs LB")
println("-"^84)

function run_sweep()
    prev_indices = nothing
    tot_cold = 0.0
    tot_cont = 0.0
    all_identical = true
    max_gap = 0.0

    for α in ALPHAS
        targets = I_base .* α
        demands = make_demands(targets)

        # Step-1 seed from R.1's projection; thereafter carry the previous design.
        seed = prev_indices === nothing ?
            relaxation_warm_start(Ix_cat, A_cat, targets; k = 1).mip_start : prev_indices

        t_cold = @elapsed cold = solve(demands)
        t_cont = @elapsed cont = solve(demands; mip_start = seed)
        @assert cold.status == MOI.OPTIMAL && cont.status == MOI.OPTIMAL "non-optimal at α=$α"

        identical = cont.section_indices == cold.section_indices
        all_identical &= identical
        prev_indices = cont.section_indices

        lb = relaxation_lower_bound(law, targets, Ls)
        gap = optimality_gap(cold.objective_value, lb)
        max_gap = max(max_gap, gap)
        tot_cold += t_cold
        tot_cont += t_cont

        println(rpad(round(α, digits = 2), 6),
                rpad(round(t_cold * 1e3, digits = 1), 12),
                rpad(round(t_cont * 1e3, digits = 1), 12),
                rpad("×$(round(t_cold / max(t_cont, 1e-9), digits = 2))", 7),
                rpad(identical ? "YES ✓" : "NO ✗", 11),
                rpad(round(lb, sigdigits = 5), 12),
                "$(round(gap * 100, digits = 3)) %")
    end
    return (; tot_cold, tot_cont, all_identical, max_gap)
end

(; tot_cold, tot_cont, all_identical, max_gap) = run_sweep()

println("-"^84)
println("TOTAL   cold = $(round(tot_cold*1e3, digits=1)) ms   continuation = $(round(tot_cont*1e3, digits=1)) ms   " *
        "aggregate speedup ×$(round(tot_cold/max(tot_cont,1e-9), digits=2))")
println("All continuation designs byte-identical to cold: $(all_identical ? "YES ✓" : "NO ✗")")
println("Max realized optimality gap vs certified lower bound: $(round(max_gap*100, digits=3)) %")
println("="^84)

ok = all_identical
println(ok ? "CONTINUATION PRIMITIVE PROVEN ✓" : "CONTINUATION FAILED ✗")
ok || error("continuation sweep produced a design that differs from cold")
