# Reproduce the flat-plate member-stage non-convergence with a per-round trace.
# Uses the four-story core office (the reliable trigger: the profiling run threw
# "flat-plate member stage did not settle" on it) and runs design_building with
# SS_DEBUG_MEMBER_SETTLE on so the settle loop prints — flushed each round — the
# stale set, the staleness reasons, and the column plan sizes.
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/repro_member_settle.jl
ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_SKIP_SOLVER_WARMUP"]   = get(ENV, "SS_SKIP_SOLVER_WARMUP", "true")
ENV["SS_DEBUG_MEMBER_SETTLE"]  = "1"

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer
const SY = StructuralSynthesizer
const _SR = StructuralSizer
using Unitful
using Asap

# Four-story core office (FEA strip + core walls): the reliable trigger for the
# member-stage throw. Slow (~13 min of slab sizing before the member loop), but
# the settle trace now flushes each round, so the cycle streams live.
include(joinpath(@__DIR__, "core_office_geometry.jl"))

params = DesignParameters(
    name = "repro-member-settle",
    floor = FlatPlateOptions(method = FEA(design_approach = :strip)),
    materials = MaterialOptions(concrete = RC_4000_60.concrete, rebar = Rebar_60),
    columns = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60),
    wall_thickness = 0.3u"m",
    diaphragm_mode = :rigid,
    foundation_options = FoundationParameters(
        soil = _SR.medium_sand,
        options = _SR.FoundationOptions(strategy = :all_spread),
    ),
    skip_visualization = true,
)

println("Building four-story core office…"); flush(stdout)
struc = BuildingStructure(core_office_skeleton())
println("Running design_building (member-settle trace on)…"); flush(stdout)
try
    design_building(struc, params)
    println("\n=== design_building COMPLETED (converged) ==="); flush(stdout)
catch err
    println("\n=== design_building THREW ==="); flush(stdout)
    showerror(stdout, err); println(); flush(stdout)
end
