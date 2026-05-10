# Quick check: does rc_column_catalog(:rect, :high_capacity) return non-empty,
# and does precompute_capacities! work without errors?

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using StructuralSizer
using Asap         # registers ksi/kip with Unitful — must come BEFORE u"ksi" use
using Unitful

println("\n=== Catalog smoke test ===\n")

cat_high = StructuralSizer.rc_column_catalog(:rect, :high_capacity)
println("rc_column_catalog(:rect, :high_capacity) → $(length(cat_high)) sections")

cat_std  = StructuralSizer.rc_column_catalog(:rect, :standard)
println("rc_column_catalog(:rect, :standard)      → $(length(cat_std)) sections")

if !isempty(cat_high)
    s = cat_high[1]
    println("\nFirst high-capacity section: $(s.b) × $(s.h)")
end

println("\n=== Column checker + precompute_capacities! ===\n")

opts    = StructuralSizer.ConcreteColumnOptions(material = StructuralSizer.NWC_6000,
                                                 catalog = :high_capacity)
checker = StructuralSizer.ACIColumnChecker(;
              include_slenderness = opts.include_slenderness,
              include_biaxial     = opts.include_biaxial,
              fy_ksi              = ustrip(u"ksi", opts.rebar_material.Fy),
              Es_ksi              = ustrip(u"ksi", opts.rebar_material.E),
              max_depth           = opts.max_depth,
          )
println("Checker built ok. max_depth = $(checker.max_depth)")

cache = StructuralSizer.create_cache(checker, length(cat_high))
println("Cache created for $(length(cat_high)) sections.")

try
    StructuralSizer.precompute_capacities!(checker, cache, cat_high, opts.material, opts.objective)
    println("precompute_capacities! OK")
catch e
    println("\n>>> EXCEPTION:")
    println(sprint(showerror, e))
    println("\n>>> Stacktrace:")
    for (k, frame) in enumerate(stacktrace(catch_backtrace()))
        println("  [$k] ", frame)
        k >= 25 && (println("  ..."); break)
    end
end

println("\n=== Now try is_feasible on each section with a simple demand ===\n")

geom = StructuralSizer.ConcreteMemberGeometry(12.0u"ft"; kx=1.0, ky=1.0, braced=true)
demand = StructuralSizer.RCColumnDemand(1; Pu=400.0u"kip", Mux=80.0u"kip*ft", Muy=0.0u"kip*ft")
println("Demand: $(demand.Pu) kip, Mux=$(demand.Mux), Muy=$(demand.Muy), M1x=$(demand.M1x), M2x=$(demand.M2x)")

n_ok, n_bad = 0, 0
for j in 1:min(length(cat_high), 50)   # spot-check first 50 sections
    try
        ok = StructuralSizer.is_feasible(checker, cache, j, cat_high[j], opts.material, demand, geom)
        ok ? (n_ok += 1) : (n_bad += 1)
    catch e
        println("  >>> EXCEPTION at section $j ($(cat_high[j].b)×$(cat_high[j].h)):")
        println("  ", sprint(showerror, e))
        for (k, frame) in enumerate(stacktrace(catch_backtrace()))
            println("    [$k] ", frame)
            k >= 15 && (println("    ..."); break)
        end
        break
    end
end
println("\nFirst 50 sections: $n_ok feasible, $n_bad infeasible")

println("\n=== Done ===\n")
