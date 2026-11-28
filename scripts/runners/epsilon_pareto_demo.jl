# ==============================================================================
# ε-constraint Pareto front vs weighted-sum scalarization (Pillar B)
# ==============================================================================
#
# A weighted-sum scalarization (`ParetoScalarization`) can only recover SUPPORTED
# Pareto points — the lower convex hull of the objective space. Any NON-SUPPORTED
# point (one lying above that hull, yet dominated by no single design) is invisible
# to it: no weight makes such a point the unique minimum. The ε-constraint method
# (`pareto_front`) bounds one objective and minimizes the other, so it recovers the
# COMPLETE front — convex or not.
#
# This runner proves the gap on a controlled weight↔carbon conflict: three steel
# "materials" with IDENTICAL strength/stiffness (so feasibility is identical and
# only the objective differs) whose (ρ, ecc) place the middle material strictly
# above the hull line. ε-constraint must find all three; a full scalarization sweep
# finds only two. A second, multi-group case shows a richer traced front.
#
# HiGHS is forced so the demo is reproducible without a Gurobi license.
#
# Run: julia --project=StructuralSizer scripts/runners/epsilon_pareto_demo.jl

using StructuralSizer
using Asap          # registers the `ksi` unit used below
using Unitful
import JuMP
const MOI = JuMP.MOI

const OPT = :highs   # reproducible without a Gurobi license

# Identical E/G/Fy/Fu/ν ⇒ identical AISC capacity; only ρ (weight) and ecc (carbon)
# differ. ρ in kg/m³ and ecc in kgCO₂e/kg keep the objective units canonical.
_steel(ρ, ecc) = StructuralSteel(29000.0u"ksi", 11200.0u"ksi", 50.0u"ksi", 65.0u"ksi",
                                 ρ * u"kg/m^3", 0.29, ecc * u"kgCO2e/kg")
#   mat        (ρ,   ecc)      (weight, carbon) per unit area·length
const MAT_LIGHT = _steel(2000.0, 5.0)    # (2000, 10000)  — min weight
const MAT_MID   = _steel(6000.0, 1.5)    # (6000,  9000)  — NON-supported
const MAT_HEAVY = _steel(10000.0, 0.2)   # (10000, 2000)  — min carbon
const MATS = [MAT_LIGHT, MAT_MID, MAT_HEAVY]

catalog = all_W()
checker = AISCChecker()

print_header(t) = (println(); println("="^74); println(t); println("="^74))

# ------------------------------------------------------------------------------
# Case 1 — the non-supported point: ε-constraint finds it, scalarization cannot.
# ------------------------------------------------------------------------------
print_header("Case 1 — one group, three materials: the non-supported middle point")

dem1 = [MemberDemand(1; Mux = 120.0e3)]
geo1 = [SteelMemberGeometry(5.0; Lb = 5.0)]

front1 = pareto_front(checker, dem1, geo1, catalog, MATS;
                      objective1 = MinWeight(), objective2 = MinCarbon(),
                      n_points = 11, optimizer = OPT)

println("\nε-constraint front ($(length(front1)) points):")
println("  idx   weight        carbon      material")
for (k, p) in enumerate(front1)
    println("  ", lpad(k, 2), "   ", lpad(round(p.objective1; digits = 2), 10), "   ",
            lpad(round(p.objective2; digits = 2), 10), "      mat ", only(p.material_indices))
end

# Weighted-sum sweep: which materials does it EVER select?
selected = Set{Int}()
for w in 0.0:0.02:1.0
    ps = ParetoScalarization(MinWeight(), MinCarbon(), w, 1.0u"kg", 1.0u"kgCO2e")
    r = optimize_discrete(checker, dem1, geo1, catalog, MATS; objective = ps, optimizer = OPT)
    push!(selected, only(r.material_indices))
end
println("\nweighted-sum sweep (w = 0 … 1) ever selects materials: ", sort(collect(selected)))
missed = setdiff(Set(1:length(MATS)), selected)
println("→ ε-constraint recovered ", length(front1), " designs; ",
        "scalarization recovered ", length(selected),
        ".  Non-supported material(s) MISSED by scalarization: ", sort(collect(missed)))

# ------------------------------------------------------------------------------
# Case 2 — a richer multi-group traced front.
# ------------------------------------------------------------------------------
print_header("Case 2 — eight groups, three materials: a richer traced front")

ng = 8
dem2 = [MemberDemand(g; Mux = (80.0 + 25.0 * g) * 1.0e3) for g in 1:ng]
geo2 = [SteelMemberGeometry(4.0 + 0.3 * g; Lb = 4.0 + 0.3 * g) for g in 1:ng]

front2 = pareto_front(checker, dem2, geo2, catalog, MATS;
                      objective1 = MinWeight(), objective2 = MinCarbon(),
                      n_points = 21, optimizer = OPT, time_limit_sec = 120.0)

w_lo, w_hi = front2[1].objective1, front2[end].objective1
c_lo, c_hi = front2[end].objective2, front2[1].objective2
println("\ntraced front: ", length(front2), " non-dominated designs")
println("  weight spans ", round(w_lo; digits = 1), " … ", round(w_hi; digits = 1),
        "  (", round(w_hi / w_lo; digits = 2), "×)")
println("  carbon spans ", round(c_lo; digits = 1), " … ", round(c_hi; digits = 1),
        "  (", round(c_hi / c_lo; digits = 2), "×)")
println("  idx   weight        carbon      #LIGHT  #MID  #HEAVY")
for (k, p) in enumerate(front2)
    mi = p.material_indices
    println("  ", lpad(k, 2), "   ", lpad(round(p.objective1; digits = 2), 10), "   ",
            lpad(round(p.objective2; digits = 2), 10), "      ",
            lpad(count(==(1), mi), 4), "  ", lpad(count(==(2), mi), 4), "  ",
            lpad(count(==(3), mi), 5))
end

# Every returned design must be mutually non-dominated (sanity check).
dominated = false
for a in front2, b in front2
    a === b && continue
    if b.objective1 ≤ a.objective1 && b.objective2 ≤ a.objective2 &&
       (b.objective1 < a.objective1 || b.objective2 < a.objective2)
        global dominated = true
    end
end
println("\nall returned designs mutually non-dominated: ", !dominated)

println("\nDone.")
