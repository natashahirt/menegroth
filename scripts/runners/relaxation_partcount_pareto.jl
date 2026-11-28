# ==============================================================================
# Part-count Pareto front, warm-started by continuation (Pillar B)
# ==============================================================================
#
# Maps the material-efficiency ↔ fabrication-economy trade-off: cap the number of
# DISTINCT sections (`n_max_sections = k`) and sweep k. Fewer unique parts is
# cheaper to detail, fabricate and erect, but forces members to share sections and
# so costs material. Sweeping k traces a genuine Pareto front (total volume vs part
# count) on the REAL member MIP.
#
# The capped MIP couples all groups through the section-usage binaries `z`, so it
# is far harder than the separable sizing problem — exactly where a warm start
# pays. This runner proves the newly-added COUPLED warm start: each k is seeded by
# continuation from the k−1 design (which uses ≤ k−1 ≤ k distinct sections, a valid
# seed). The warm solve must reach the same objective as the cold solve at every k.
#
# Run: julia --project=StructuralSizer scripts/runners/relaxation_partcount_pareto.jl

using StructuralSizer
using Unitful
import JuMP
const MOI = JuMP.MOI

const N_GROUPS = 16
const DEFLECTION_LIMIT = 1 / 360

catalog = steel_column_catalog(:w, :all)
Ix_cat = [ustrip(u"m^4", Ix(s)) for s in catalog]
Ix_sorted = sort(Ix_cat)
n_cat = length(catalog)

# Spread required stiffness so the unconstrained optimum uses many distinct sections.
ranks = round.(Int, range(0.15 * n_cat, 0.7 * n_cat; length = N_GROUPS))
I_req = [Ix_sorted[r] * 1.0005 for r in ranks]
Ls = [6.0 + 0.3 * (g - 1) for g in 1:N_GROUPS]
demands = [MemberDemand(g; Mux = 5.0e3, δ_max_LL = I_req[g] * DEFLECTION_LIMIT * Ls[g], I_ref = 1.0)
           for g in 1:N_GROUPS]
geometries = [SteelMemberGeometry(Ls[g]; Lb = Ls[g]) for g in 1:N_GROUPS]
checker = AISCChecker(; deflection_limit = DEFLECTION_LIMIT)

solve(; nmax, mip_start = nothing) = optimize_discrete(
    checker, demands, geometries, catalog, A992_Steel;
    objective = MinVolume(), n_max_sections = nmax, mip_start = mip_start, time_limit_sec = 120.0)

# --- Tight certified lower bound (JuMP-free) and the separable optimum ----------
# Relaxing the part-count coupling leaves the separable problem; its optimum is an
# exact lower bound on every capped solve, and its per-group picks seed the DP.
sep = optimize_binary_search(checker, demands, geometries, catalog, A992_Steel; objective = MinVolume())
LB = sep.objective_value                                   # == separable_lower_bound(...)
sep_coeffs = [ustrip(u"m^2", catalog[j].A) for j in sep.section_indices]

# Loose continuous reference, for contrast: the convex-hull area envelope.
law = fit_section_scaling_law([ustrip(u"m^4", Ix(s)) for s in catalog],
                              [ustrip(u"m^2", s.A) for s in catalog])
LB_hull = relaxation_lower_bound(law, I_req, Ls)

# Warm up every code path at full size (cold + coupled-warm) so timings are clean.
println("Warming up (precompile, cold + coupled-warm paths)…")
let wd = [MemberDemand(g; Mux = 5.0e3, δ_max_LL = I_req[g] * 1.3 * DEFLECTION_LIMIT * Ls[g], I_ref = 1.0)
          for g in 1:N_GROUPS]
    ws = optimize_binary_search(checker, wd, geometries, catalog, A992_Steel; objective = MinVolume())
    seed = continuation_seed(ws.section_indices,
                             [ustrip(u"m^2", catalog[j].A) for j in ws.section_indices], Ls, 4)
    optimize_discrete(checker, wd, geometries, catalog, A992_Steel;
                      objective = MinVolume(), n_max_sections = 4, time_limit_sec = 120.0)
    optimize_discrete(checker, wd, geometries, catalog, A992_Steel;
                      objective = MinVolume(), n_max_sections = 4,
                      mip_start = seed, time_limit_sec = 120.0)
end

n_distinct_full = length(unique(sep.section_indices))
kmax = min(n_distinct_full, 10)

println("\n" * "="^96)
println("Part-count Pareto  (W catalog: $n_cat sections, $N_GROUPS groups; " *
        "unconstrained uses $n_distinct_full distinct)")
println("Certified lower bound  (separable optimum) : $(round(LB, sigdigits=6)) m³    " *
        "convex-hull bound (loose) : $(round(LB_hull, sigdigits=6)) m³")
println("="^96)
println(rpad("n_max", 7), rpad("volume (m³)", 13), rpad("distinct", 10),
        rpad("gap vs LB", 11), rpad("cold (ms)", 11), rpad("warm (ms)", 11),
        rpad("×", 7), "obj match")
println("-"^96)

function sweep()
    tot_cold = 0.0
    tot_warm = 0.0
    all_match = true
    vols = Float64[]
    for k in 1:kmax
        t_cold = @elapsed cold = solve(; nmax = k)
        # Smart seed: DP-optimal ≤k-distinct bucketing of the separable optimum.
        seed = continuation_seed(sep.section_indices, sep_coeffs, Ls, k)
        t_warm = @elapsed warm = solve(; nmax = k, mip_start = seed)
        @assert cold.status == MOI.OPTIMAL && warm.status == MOI.OPTIMAL "non-optimal at k=$k"

        match = isapprox(warm.objective_value, cold.objective_value; rtol = 1e-6)
        all_match &= match
        push!(vols, cold.objective_value)
        tot_cold += t_cold
        tot_warm += t_warm

        println(rpad(k, 7),
                rpad(round(cold.objective_value, sigdigits = 6), 13),
                rpad(length(unique(cold.section_indices)), 10),
                rpad("$(round(100 * optimality_gap(cold.objective_value, LB), digits=2))%", 11),
                rpad(round(t_cold * 1e3, digits = 1), 11),
                rpad(round(t_warm * 1e3, digits = 1), 11),
                rpad("×$(round(t_cold / max(t_warm, 1e-9), digits = 2))", 7),
                match ? "YES ✓" : "NO ✗")
    end
    return (; tot_cold, tot_warm, all_match, vols)
end

(; tot_cold, tot_warm, all_match, vols) = sweep()

# Pareto front must be monotone: more allowed parts ⇒ never heavier, and never
# below the certified lower bound.
monotone = all(vols[k] ≥ vols[k + 1] - 1e-9 for k in 1:(length(vols) - 1))
above_lb = all(v ≥ LB - 1e-9 for v in vols)
println("-"^96)
println("Volume at n_max=1 : $(round(vols[1], sigdigits=6)) m³   →   unconstrained : " *
        "$(round(LB, sigdigits=6)) m³   " *
        "(material penalty for a single section: ×$(round(vols[1]/LB, digits=2)))")
println("Certified-gap closes to $(round(100*optimality_gap(vols[end], LB), digits=2))% at n_max=$kmax; " *
        "the separable bound is $(round(LB/LB_hull, digits=2))× tighter than the convex-hull bound.")
println("TOTAL   cold = $(round(tot_cold*1e3, digits=1)) ms   smart-warm = $(round(tot_warm*1e3, digits=1)) ms   " *
        "DP-seed aggregate speedup ×$(round(tot_cold/max(tot_warm,1e-9), digits=2))")
println("Pareto front monotone (volume ↓ as parts ↑): $(monotone ? "YES ✓" : "NO ✗")")
println("Every point above the certified lower bound : $(above_lb ? "YES ✓" : "NO ✗")")
println("Every warm solve matched the cold optimum   : $(all_match ? "YES ✓" : "NO ✗")")
println("="^96)

ok = monotone && above_lb && all_match
println(ok ? "PART-COUNT PARETO + DP SEED + CERTIFIED BOUND PROVEN ✓" : "FAILED ✗")
ok || error("part-count Pareto run failed its acceptance checks")
