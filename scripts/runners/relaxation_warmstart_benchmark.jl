# ==============================================================================
# Relaxation-guided warm-start benchmark (optimization-architecture.md §9)
# ==============================================================================
#
# Proves the first proving slice of Workstream R against the REAL member MIP
# (`optimize_discrete`), with zero edits to the live sizing owners:
#
#   1. Byte-identical warm start — seeding R.1's continuous projection as the MIP's
#      `mip_start` reproduces the cold solve's section choice exactly, and (on a
#      non-trivial catalog) shortens the solve.
#   2. Band contains the optimum — restricting each group to R.1's ±k candidate
#      band via the MIP's `feasible` hook recovers the cold objective (the certified
#      optimality gap is zero when the band brackets the pick).
#   3. Projection within one catalog step — R.1's projected section matches the
#      full-MIP pick (the §9 acceptance metric).
#
# The benchmark is DEFLECTION-GOVERNED on purpose: there the strong-axis second
# moment of area `I` is the single governing property, so the owner's lightest-
# feasible section is, by construction, `project_to_catalog(I_required)`. The
# required `I` is encoded exactly through the AISC deflection check, which enforces
#     Ix ≥ δ_max_LL · I_ref / (deflection_limit · L) =: I_required
# (see members/codes/aisc/checker/steel_feasibility.jl). This makes the comparison
# rigorous and non-circular — the target comes from Euler–Bernoulli serviceability,
# not from the catalog or the solver.
#
# Run: julia --project=StructuralSizer scripts/runners/relaxation_warmstart_benchmark.jl

using StructuralSizer
using Unitful
import JuMP
const MOI = JuMP.MOI

# ─── Problem setup ────────────────────────────────────────────────────────────
const DEFLECTION_LIMIT = 1 / 360          # AISC/IBC live-load serviceability L/360
const N_GROUPS = 30
const BAND_K = 2                          # ±2-step candidate band around the projection

# Full W catalog; extract the SI property tables the relaxation needs (catalog order).
catalog = steel_column_catalog(:w, :all)
Ix_cat = [ustrip(u"m^4", Ix(s)) for s in catalog]
A_cat  = [ustrip(u"m^2", section_area(s)) for s in catalog]
n_cat = length(catalog)

# Per-group required stiffness `I_required`, spanning the interior of the catalog.
# Targets sit just above catalog stiffnesses so each projects to a definite section.
Ix_sorted = sort(Ix_cat)
ranks = round.(Int, range(0.15 * n_cat, 0.88 * n_cat; length = N_GROUPS))
I_required = [Ix_sorted[r] * 1.0005 for r in ranks]

# Deflection-governed demands: encode I_required through δ_max_LL with I_ref = 1 m⁴,
# so feasibility ⇔ Ix ≥ I_required. A small moment keeps the strength path live but
# non-governing.
Ls = [6.0 + 0.2 * (g - 1) for g in 1:N_GROUPS]          # 6.0 … 11.8 m spans
demands = [MemberDemand(g;
                        Mux = 5.0e3,                     # 5 kN·m — never governs
                        δ_max_LL = I_required[g] * DEFLECTION_LIMIT * Ls[g],
                        I_ref = 1.0)
           for g in 1:N_GROUPS]
geometries = [SteelMemberGeometry(Ls[g]; Lb = Ls[g]) for g in 1:N_GROUPS]
checker = AISCChecker(; deflection_limit = DEFLECTION_LIMIT)

solve(; mip_start = nothing, feasible = nothing) = optimize_discrete(
    checker, demands, geometries, catalog, A992_Steel;
    objective = MinVolume(), mip_start = mip_start, feasible = feasible,
    time_limit_sec = 60.0)

# ─── Warm up (precompile the FULL-SIZE solver path) ──────────────────────────
# Warm up at the SAME problem size with PERTURBED demands: same model-build code
# path (so JIT compilation is excluded from the timings below) but a different memo
# key (so no timed config returns a cache hit). This isolates true solve time —
# a smaller-sized warmup would leave the full-size model build to compile inside
# the first timed solve and badly inflate it.
println("Warming up the MIP solver (precompile, full size, all three solver paths)…")
let warm_demands = [MemberDemand(g; Mux = 5.0e3,
                                 δ_max_LL = I_required[g] * 1.13 * DEFLECTION_LIMIT * Ls[g],
                                 I_ref = 1.0) for g in 1:N_GROUPS],
    warm_ws = relaxation_warm_start(Ix_cat, A_cat,
                                    [Ix_sorted[r] * 1.13 for r in ranks]; k = BAND_K)
    # Compile each code path (cold, mip_start, feasible) so none inflates its timing.
    optimize_discrete(checker, warm_demands, geometries, catalog, A992_Steel;
                      objective = MinVolume(), time_limit_sec = 60.0)
    optimize_discrete(checker, warm_demands, geometries, catalog, A992_Steel;
                      objective = MinVolume(), mip_start = warm_ws.mip_start, time_limit_sec = 60.0)
    optimize_discrete(checker, warm_demands, geometries, catalog, A992_Steel;
                      objective = MinVolume(), feasible = warm_ws.band, time_limit_sec = 60.0)
end

# ─── 1. Cold solve (fresh) ───────────────────────────────────────────────────
t_cold = @elapsed cold = solve()
@assert cold.status == MOI.OPTIMAL "cold solve did not reach OPTIMAL: $(cold.status)"

# ─── R.1 continuous projection → warm start ──────────────────────────────────
ws = relaxation_warm_start(Ix_cat, A_cat, I_required; k = BAND_K)
@assert !any(ws.grown) "a target exceeded the catalog; tighten the rank range"

# ─── 2. Warm start (mip_start): must be byte-identical to cold ───────────────
t_warm = @elapsed warm = solve(mip_start = ws.mip_start)
@assert warm.status == MOI.OPTIMAL "warm solve did not reach OPTIMAL: $(warm.status)"
identical = warm.section_indices == cold.section_indices

# ─── 3. Band restriction (feasible): objective gap vs cold ───────────────────
t_band = @elapsed band = solve(feasible = ws.band)
band_ok = band.status == MOI.OPTIMAL
obj_gap = band_ok ? (band.objective_value - cold.objective_value) / cold.objective_value : NaN
band_matches = band_ok && band.section_indices == cold.section_indices

# ─── Acceptance metric: projection vs cold MIP pick, in catalog I-rank steps ──
# Rank each section by strong-axis I; the step distance is |rank(pick) − rank(proj)|.
rank_of = Dict(p => r for (r, p) in enumerate(sortperm(Ix_cat)))
step_dist = [abs(rank_of[cold.section_indices[g]] - rank_of[ws.mip_start[g]]) for g in 1:N_GROUPS]
max_step = maximum(step_dist)
mean_step = sum(step_dist) / N_GROUPS
within_one = count(≤(1), step_dist)

# ─── Report ──────────────────────────────────────────────────────────────────
println("\n" * "="^72)
println("Relaxation-guided warm-start benchmark  (W catalog: $n_cat sections, $N_GROUPS groups)")
println("="^72)
println("Cold solve                : $(round(t_cold*1e3, digits=1)) ms   obj = $(round(cold.objective_value, sigdigits=6))")
println("Warm start (mip_start)    : $(round(t_warm*1e3, digits=1)) ms   speedup ×$(round(t_cold/max(t_warm,1e-9), digits=2))")
println("  → sections byte-identical to cold : $(identical ? "YES ✓" : "NO ✗")")
println("Band restriction (feasible, k=$BAND_K) : $(round(t_band*1e3, digits=1)) ms   speedup ×$(round(t_cold/max(t_band,1e-9), digits=2))")
println("  → objective gap vs cold           : $(round(obj_gap*100, digits=4)) %   (sections match: $(band_matches ? "YES ✓" : "NO ✗"))")
println("Projection vs cold MIP pick (I-rank steps):")
println("  → max step = $max_step, mean step = $(round(mean_step, digits=3)), within ±1 step: $within_one / $N_GROUPS")
println("="^72)

all_ok = identical && band_matches && max_step ≤ 1
println(all_ok ? "ALL CLAIMS HOLD ✓" : "SOME CLAIMS FAILED ✗ — inspect above")
all_ok || error("relaxation warm-start benchmark failed its acceptance claims")
