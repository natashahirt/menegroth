# Column shrink-and-verify (Part B proof-of-value, plan.md O4 + the architecture's
# "final shrink pass").
#
# 1. Design one flat-plate benchmark normally (grow-only pipeline)  -> design A.
# 2. Install on every oversized column the lightest section its own final demands
#    allow (flat_plate_column_shrink_verify!), re-solve the frame.
# 3. Re-capture the design -> design B, and read all_checks_pass + carbon.
#
# Reports: which columns shrank, whether B still passes every check, and the
# column + total carbon delta. The verification is conservative at the column
# level (checks use the heavier pre-shrink demands) but does NOT re-run the slab
# FEA (embedded in the slab sizer); see flat_plate_column_shrink_verify! docstring.
#
#   SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#       julia --project=StructuralSynthesizer scripts/runners/column_shrink_verify.jl
ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_SKIP_SOLVER_WARMUP"]   = get(ENV, "SS_SKIP_SOLVER_WARMUP", "true")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer
using Unitful
using Asap  # registers the kgCO2e embodied-carbon unit

function _case()
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 3)
    params = DesignParameters(
        name = "shrink-verify",
        floor = FlatPlateOptions(),
        materials = MaterialOptions(concrete = RC_4000_60.concrete, rebar = Rebar_60),
        columns = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60),
        max_iterations = 10,
        skip_visualization = true,
    )
    return BuildingStructure(skel), params
end

kg(x) = round(ustrip(u"kgCO2e", x); digits = 0)

struc, params = _case()
t0 = time()
designA = design_building(struc, params; restore = false)
@info "design A done" seconds = round(time() - t0; digits = 1)
sA = designA.summary

rc_opts = StructuralSynthesizer._flat_plate_column_opts(params)
shrunk = StructuralSynthesizer.flat_plate_column_shrink_verify!(struc, params, rc_opts)
designB = StructuralSynthesizer.capture_design(struc, params)
sB = designB.summary

println("\n=== COLUMN SHRINK-AND-VERIFY (flat plate, 3x3 bays, 3 stories) ===")
println("columns shrunk: ", length(shrunk), "  ", shrunk)
println()
println("all_checks_pass:   A = ", sA.all_checks_pass, "   B = ", sB.all_checks_pass)
println()
println("embodied carbon (kgCO2e):")
println("  columns : A = ", kg(sA.embodied_carbon_columns),
        "   B = ", kg(sB.embodied_carbon_columns),
        "   Δ = ", round(100 * (1 - ustrip(sB.embodied_carbon_columns) /
                                     ustrip(sA.embodied_carbon_columns)); digits = 1), "%")
println("  total   : A = ", kg(sA.embodied_carbon),
        "   B = ", kg(sB.embodied_carbon),
        "   Δ = ", round(100 * (1 - ustrip(sB.embodied_carbon) /
                                     ustrip(sA.embodied_carbon)); digits = 2), "%")
println()
if sB.all_checks_pass && length(shrunk) > 0
    println("RESULT: PASS — shrunk ", length(shrunk),
            " column(s); design B still passes every check and is lighter.")
elseif length(shrunk) == 0
    println("RESULT: no oversized columns to shrink on this benchmark.")
else
    println("RESULT: FAIL — shrinking broke a check (B all_checks_pass = false). ",
            "The probe was optimistic; a smaller column changes demands enough to fail on re-capture.")
end
