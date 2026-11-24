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

# Unconstrained optimum sets the richest part count (the top of the sweep).
println("Warming up (precompile, cold + coupled-warm paths)…")
let wd = [MemberDemand(g; Mux = 5.0e3, δ_max_LL = I_req[g] * 1.3 * DEFLECTION_LIMIT * Ls[g], I_ref = 1.0)
          for g in 1:N_GROUPS]
    w0 = optimize_discrete(checker, wd, geometries, catalog, A992_Steel;
                           objective = MinVolume(), n_max_sections = 4, time_limit_sec = 120.0)
    optimize_discrete(checker, wd, geometries, catalog, A992_Steel;
                      objective = MinVolume(), n_max_sections = 4,
                      mip_start = w0.section_indices, time_limit_sec = 120.0)
end

full = solve(; nmax = 0)
n_distinct_full = length(unique(full.section_indices))
kmax = min(n_distinct_full, 10)

println("\n" * "="^84)
println("Part-count Pareto  (W catalog: $n_cat sections, $N_GROUPS groups; " *
        "unconstrained uses $n_distinct_full distinct)")
println("="^84)
println(rpad("n_max", 7), rpad("volume (m³)", 14), rpad("distinct", 10),
        rpad("cold (ms)", 12), rpad("warm (ms)", 12), rpad("×", 7), "obj match")
println("-"^84)

function sweep()
    prev = nothing
    tot_cold = 0.0
    tot_warm = 0.0
    all_match = true
    vols = Float64[]
    for k in 1:kmax
        t_cold = @elapsed cold = solve(; nmax = k)
        seed = prev === nothing ? nothing : prev
        t_warm = @elapsed warm = solve(; nmax = k, mip_start = seed)
        @assert cold.status == MOI.OPTIMAL && warm.status == MOI.OPTIMAL "non-optimal at k=$k"

        match = isapprox(warm.objective_value, cold.objective_value; rtol = 1e-6)
        all_match &= match
        prev = warm.section_indices          # ≤ k distinct ⇒ valid seed for k+1
        push!(vols, cold.objective_value)
        tot_cold += t_cold
        tot_warm += t_warm

        println(rpad(k, 7),
                rpad(round(cold.objective_value, sigdigits = 6), 14),
                rpad(length(unique(cold.section_indices)), 10),
                rpad(round(t_cold * 1e3, digits = 1), 12),
                rpad(round(t_warm * 1e3, digits = 1), 12),
                rpad("×$(round(t_cold / max(t_warm, 1e-9), digits = 2))", 7),
                match ? "YES ✓" : "NO ✗")
    end
    return (; tot_cold, tot_warm, all_match, vols)
end

(; tot_cold, tot_warm, all_match, vols) = sweep()

# Pareto front must be monotone: more allowed parts ⇒ never heavier.
monotone = all(vols[k] ≥ vols[k + 1] - 1e-9 for k in 1:(length(vols) - 1))
println("-"^84)
println("Volume at n_max=1 : $(round(vols[1], sigdigits=6)) m³   →   unconstrained : " *
        "$(round(full.objective_value, sigdigits=6)) m³   " *
        "(material penalty for a single section: ×$(round(vols[1]/full.objective_value, digits=2)))")
println("TOTAL   cold = $(round(tot_cold*1e3, digits=1)) ms   warm = $(round(tot_warm*1e3, digits=1)) ms   " *
        "coupled-warm aggregate speedup ×$(round(tot_cold/max(tot_warm,1e-9), digits=2))")
println("Pareto front monotone (volume ↓ as parts ↑): $(monotone ? "YES ✓" : "NO ✗")")
println("Every warm solve matched the cold optimum: $(all_match ? "YES ✓" : "NO ✗")")
println("="^84)

ok = monotone && all_match
println(ok ? "PART-COUNT PARETO + COUPLED WARM START PROVEN ✓" : "FAILED ✗")
ok || error("part-count Pareto run failed its acceptance checks")
