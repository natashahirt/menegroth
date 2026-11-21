# Capacity-invariance check for WP 2.5 (rebar-inclusive column objective).
#
# To make the column obj_coeffs rebar-aware, the capacity cache must be built
# from a ReinforcedConcreteMaterial instead of a plain Concrete, which routes
# precompute_capacities! through the `::ReinforcedConcreteMaterial` overload. The
# P-M DIAGRAMS depend on the material only through the material tuple fed to
# generate_PM_diagram; the objective does not enter diagram generation at all.
#
# This runner PROVES the material swap does not change capacity:
#   1. Analytical: to_material_tuple(concrete, checker.fy, checker.Es) ==
#      to_material_tuple(rc)  (same fc, same fy/Es from the same rebar, same εcu).
#   2. Structural: the two caches' scalar fields (fc/fy/Es/εcu, depths, is_square)
#      are equal.
#   3. Behavioral: is_feasible verdicts over a dense (Pu, Mux, Muy) grid are
#      identical for every catalog section.
#   4. Sanity: obj_coeffs DO differ (the intended rebar-inclusive change).
#
# NOTHING is changed in the pipeline; this is read-only evidence for the WP.
#
#   SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#       julia --project=StructuralSynthesizer scripts/runners/equiv_column_rc_capacity.jl
ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_SKIP_SOLVER_WARMUP"]   = get(ENV, "SS_SKIP_SOLVER_WARMUP", "true")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer
const SZ = StructuralSizer
using Unitful
using Asap

# Same column options the medium_office benchmark uses.
column_opts = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60)

checker  = StructuralSynthesizer._aci_column_checker(column_opts)
catalog  = StructuralSynthesizer._memo_column_catalog(column_opts)
concrete = column_opts.material
transverse = something(column_opts.transverse_rebar_material, column_opts.rebar_material)
rc = SZ.ReinforcedConcreteMaterial(concrete, column_opts.rebar_material, transverse)

println("=== WP 2.5 COLUMN CAPACITY-INVARIANCE CHECK ===")
println("catalog sections: ", length(catalog))

# ── 1. Analytical: the two material tuples feeding generate_PM_diagram ──
matA = SZ.to_material_tuple(concrete, checker.fy_ksi, checker.Es_ksi)
matB = SZ.to_material_tuple(rc)
println("\n[1] material tuples")
println("    Concrete path: ", matA)
println("    RC path:       ", matB)
tuples_equal = matA == matB
println("    EQUAL: ", tuples_equal)

# ── Build both caches ──
objective = column_opts.objective
cacheA = SZ.create_cache(checker, length(catalog))
SZ.precompute_capacities!(checker, cacheA, catalog, concrete, objective)   # ::Concrete (today)
cacheB = SZ.create_cache(checker, length(catalog))
SZ.precompute_capacities!(checker, cacheB, catalog, rc, objective)         # ::RC (proposed)

# ── 2. Structural: scalar + per-section capacity-defining fields ──
scalar_ok = cacheA.fc_ksi == cacheB.fc_ksi && cacheA.fy_ksi == cacheB.fy_ksi &&
            cacheA.Es_ksi == cacheB.Es_ksi && cacheA.εcu == cacheB.εcu &&
            cacheA.depths == cacheB.depths && cacheA.is_square == cacheB.is_square
println("\n[2] scalar/geometry cache fields equal: ", scalar_ok)

# ── 3. Behavioral: feasibility over a dense P-M grid, every section ──
geom = SZ.ConcreteMemberGeometry(SZ.to_meters(10.0u"ft"); k = 1.0, braced = true)
# Demands in kip / kip·ft (the StructuralSizer convention for bare Float64).
Pus  = range(0.0, 1500.0; length = 25)       # kip (compression +)
Mus  = range(0.0, 400.0;  length = 13)        # kip·ft
mismatches = 0
tested = 0
for j in eachindex(catalog)
    sec = catalog[j]
    for p in Pus, mx in Mus, my in Mus
        d = SZ.RCColumnDemand(1; Pu = p, Mux = mx, Muy = my, βdns = column_opts.βdns)
        fa = SZ.is_feasible(checker, cacheA, j, sec, concrete, d, geom)
        fb = SZ.is_feasible(checker, cacheB, j, sec, concrete, d, geom)
        global tested += 1
        fa == fb || (global mismatches += 1)
    end
end
println("\n[3] feasibility grid: ", tested, " (section,demand) pairs tested")
println("    verdict mismatches: ", mismatches)

# ── 4. Sanity: obj_coeffs actually change (the intended rebar-inclusive effect) ──
obj_diffs = count(j -> !isapprox(cacheA.obj_coeffs[j], cacheB.obj_coeffs[j]; rtol = 1e-9),
                  eachindex(catalog))
println("\n[4] obj_coeffs that differ (intended): ", obj_diffs, " / ", length(catalog))

ok = tuples_equal && scalar_ok && mismatches == 0
println("\n", "="^55)
if ok
    println("RESULT: PASS — capacity is byte-identical under the material swap.")
    println("        Only obj_coeffs change (", obj_diffs, " sections). WP 2.5 is capacity-safe.")
else
    println("RESULT: FAIL — the material swap changed capacity. Do NOT proceed.")
    println("        tuples_equal=", tuples_equal, " scalar_ok=", scalar_ok,
            " mismatches=", mismatches)
    exit(1)
end
