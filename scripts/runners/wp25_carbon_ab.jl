# WP 2.5 carbon A/B on medium_office (flat plate, 3x3 bays, 3 stories).
#
# Both designs run on the post-WP-2.5 code, where the flat-plate column capacity
# cache is built from a ReinforcedConcreteMaterial (rebar-inclusive obj_coeffs).
# The ONLY difference is the column objective:
#   A — MinWeight()  (rank sections by total mass, incl. rebar)
#   B — MinCarbon()  (rank sections by true embodied carbon, incl. rebar) — the
#       new ConcreteColumnOptions default.
#
# ec.jl embodied carbon is computed identically for both (objective-independent),
# so the column-carbon delta isolates what the MinCarbon objective buys. Capacity
# is already proven identical (scripts/runners/equiv_column_rc_capacity.jl).
#
#   SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#       julia --project=StructuralSynthesizer scripts/runners/wp25_carbon_ab.jl
ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_SKIP_SOLVER_WARMUP"]   = get(ENV, "SS_SKIP_SOLVER_WARMUP", "true")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer
using Unitful
using Asap  # registers the kgCO2e embodied-carbon unit
const SZ = StructuralSizer

kg(x) = round(ustrip(u"kgCO2e", x); digits = 0)

function _design(objective)
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 3)
    params = DesignParameters(
        name = "wp25-carbon-ab",
        floor = FlatPlateOptions(),
        materials = MaterialOptions(concrete = RC_4000_60.concrete, rebar = Rebar_60),
        columns = ConcreteColumnOptions(material = RC_4000_60.concrete,
                                        rebar_material = Rebar_60, objective = objective),
        max_iterations = 10,
        skip_visualization = true,
    )
    t0 = time()
    d = design_building(BuildingStructure(skel), params; restore = false)
    @info "design done" objective seconds = round(time() - t0; digits = 1)
    return d.summary
end

sA = _design(SZ.MinWeight())
sB = _design(SZ.MinCarbon())

pct(a, b) = round(100 * (1 - ustrip(b) / ustrip(a)); digits = 2)

println("\n=== WP 2.5 CARBON A/B (medium_office, 3x3 bays, 3 stories) ===")
println("                          A: MinWeight     B: MinCarbon     Δ (A→B)")
println("  all_checks_pass    : ", rpad(sA.all_checks_pass, 15), rpad(sB.all_checks_pass, 16))
println("  columns  (kgCO2e)  : ", rpad(kg(sA.embodied_carbon_columns), 15),
        rpad(kg(sB.embodied_carbon_columns), 16), pct(sA.embodied_carbon_columns, sB.embodied_carbon_columns), "%")
println("  total    (kgCO2e)  : ", rpad(kg(sA.embodied_carbon), 15),
        rpad(kg(sB.embodied_carbon), 16), pct(sA.embodied_carbon, sB.embodied_carbon), "%")
println()
if !(sA.all_checks_pass && sB.all_checks_pass)
    println("WARNING: a design did not pass every check — compare with care.")
elseif ustrip(sB.embodied_carbon_columns) <= ustrip(sA.embodied_carbon_columns) + 1e-6
    println("RESULT: MinCarbon column carbon ≤ MinWeight — WP 2.5 does not regress carbon (as intended).")
else
    println("RESULT: MinCarbon column carbon > MinWeight — unexpected; investigate selection path.")
end
