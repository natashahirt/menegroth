# ==============================================================================
# Multi-material Pareto front by weighted-scalarization continuation (Pillar B)
# ==============================================================================
#
# A genuine two-objective materials trade-off: WEIGHT vs EMBODIED CARBON for RC
# columns offered a choice between normalweight and lightweight concrete at the
# same strength. Lightweight concrete (LWC) cuts structural self-weight (ρ 1840 vs
# 2380 kg/m³) — valuable for seismic mass and foundations — but carries higher
# embodied carbon per volume (ecc 0.243 vs 0.127 kgCO₂e/kg). Neither dominates, so
# the designer faces a real Pareto choice.
#
# The front is traced with `ParetoScalarization(MinWeight, MinCarbon, w, …)`: a
# single dimensionless objective `w·weight/ref_w + (1−w)·carbon/ref_c` swept over
# w ∈ [0,1] on the multi-material MIP. w=1 reproduces the min-weight design
# (all-LWC), w=0 the min-carbon design (all-NWC); intermediate w walks the
# supported points between. Each design's REAL (weight, carbon) is then measured
# and the non-dominated frontier extracted.
#
# NOTE ON SCOPE: a single capacity checker handles one material family, so this
# steel-free demo mixes concrete grades. A true steel↔concrete front needs the
# multi-checker extension (future work). The scalarization engine itself is
# material-agnostic.
#
# Run: julia --project=StructuralSizer scripts/runners/multimaterial_pareto.jl

using StructuralSizer
using Unitful
using Asap          # registers the kgCO2e unit module for the @u_str macro

const MATERIALS = [NWC_4000, LWC_4000]
const MAT_NAME = Dict(NWC_4000 => "NWC", LWC_4000 => "LWC")

# Heterogeneous columns: a spread of axial/moment demands and lengths.
const N = 8
Pu = [400.0 + 90.0 * (g - 1) for g in 1:N]       # kip
Mux = [40.0 + 9.0 * (g - 1) for g in 1:N]        # kip·ft
Ls = [3.0 + 0.25 * (g - 1) for g in 1:N]         # m
geometries = [ConcreteMemberGeometry(Ls[g]) for g in 1:N]

opts(obj) = ConcreteColumnOptions(materials = MATERIALS, objective = obj, include_biaxial = false)
solve(obj) = size_columns(Pu, Mux, geometries, opts(obj))

# Measure each design's weight/carbon with the SAME rebar split the MIP optimised
# (size_columns wraps the concrete in a ReinforcedConcreteMaterial), so the plane
# is self-consistent with the objective that produced it.
const REBAR = opts(MinWeight()).rebar_material
const TRANSVERSE = get_transverse_rebar(opts(MinWeight()))
design_weight(res) = sum(ustrip(u"kg",
    objective_value(MinWeight(), res.sections[g], res.materials_chosen[g], Ls[g] * u"m";
                    rebar = REBAR, transverse = TRANSVERSE)) for g in 1:N)
design_carbon(res) = sum(ustrip(u"kgCO2e",
    objective_value(MinCarbon(), res.sections[g], res.materials_chosen[g], Ls[g] * u"m";
                    rebar = REBAR, transverse = TRANSVERSE)) for g in 1:N)
n_lwc(res) = count(m -> m === LWC_4000, res.materials_chosen)

println("Warming up (precompile multi-material MIP paths)…")
_ = solve(MinWeight())

# Anchors set the normalisation so both objectives read ≈1 at their own optimum.
anchor_w = solve(MinWeight())
anchor_c = solve(MinCarbon())
W_min = design_weight(anchor_w)
C_min = design_carbon(anchor_c)
ref_w = W_min * u"kg"
ref_c = C_min * u"kgCO2e"

println("\n" * "="^78)
println("Multi-material Pareto  (RC columns, $N groups; menu: " *
        join([MAT_NAME[m] * "-4000" for m in MATERIALS], " / ") * ")")
println("Min-weight design : $(round(W_min, digits=0)) kg   |   " *
        "Min-carbon design : $(round(C_min, digits=0)) kgCO₂e")
println("="^78)
println(rpad("w (→weight)", 13), rpad("weight (kg)", 13), rpad("carbon (kgCO₂e)", 17),
        rpad("#LWC", 7), "#NWC")
println("-"^78)

ws = range(1.0, 0.0; length = 11)
designs = Tuple{Float64,Float64,Int}[]       # (weight, carbon, n_lwc)
for w in ws
    res = solve(ParetoScalarization(MinWeight(), MinCarbon(), w, ref_w, ref_c))
    W = design_weight(res)
    C = design_carbon(res)
    nl = n_lwc(res)
    push!(designs, (W, C, nl))
    println(rpad(round(w, digits = 2), 13), rpad(round(W, digits = 0), 13),
            rpad(round(C, digits = 0), 17), rpad(nl, 7), N - nl)
end

# Non-dominated frontier: keep points not strictly beaten on BOTH axes.
function pareto_front(pts)
    keep = Tuple{Float64,Float64,Int}[]
    for (i, p) in enumerate(pts)
        dominated = any(q -> (q[1] ≤ p[1] && q[2] ≤ p[2]) && (q[1] < p[1] || q[2] < p[2]),
                        pts[setdiff(1:length(pts), i)])
        dominated || push!(keep, p)
    end
    return unique(q -> (round(q[1], digits = 3), round(q[2], digits = 3)), keep)
end

front = pareto_front(designs)
# Anchors must bound the front; weight-opt is lightest, carbon-opt is lowest carbon.
W_at_Cmin = design_weight(anchor_c)
C_at_Wmin = design_carbon(anchor_w)
conflict = (W_min < W_at_Cmin - 1e-6) && (C_min < C_at_Wmin - 1e-6)
all_front_valid = all(p -> p[1] ≥ W_min - 1e-6 && p[2] ≥ C_min - 1e-6, designs)

println("-"^78)
println("Trade-off span : weight $(round(W_min,digits=0))→$(round(W_at_Cmin,digits=0)) kg  " *
        "(×$(round(W_at_Cmin/W_min, digits=2)))   " *
        "carbon $(round(C_min,digits=0))→$(round(C_at_Wmin,digits=0)) kgCO₂e  " *
        "(×$(round(C_at_Wmin/C_min, digits=2)))")
println("Distinct non-dominated Pareto designs : $(length(front))")
println("Genuine conflict (neither objective's optimum wins the other) : $(conflict ? "YES ✓" : "NO ✗")")
println("Every swept design ≥ both certified anchors : $(all_front_valid ? "YES ✓" : "NO ✗")")
println("="^78)

ok = conflict && all_front_valid && length(front) ≥ 2
println(ok ? "MULTI-MATERIAL PARETO (WEIGHT ↔ CARBON) PROVEN ✓" : "FAILED ✗")
ok || error("multi-material Pareto run failed its acceptance checks")
