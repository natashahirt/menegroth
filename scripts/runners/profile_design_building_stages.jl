#=
Stage-split a whole `design_building` run (speed.md measurement #1).

    julia --project=StructuralSynthesizer scripts/runners/profile_design_building_stages.jl

Runs the four-story core office under a `SizingProbe`, which installs an
`Asap.AnalysisLog` and tags every factorization / solve with the design-graph
stage that triggered it. Prints, per stage: inclusive wall time and the
factorization / refactorization / RHS counts, split into building-frame vs
other (slab mesh, story shell, wall) models. This is the breakdown the
core-office `pipeline` number (~699 s) never had.

Env: SS_ENABLE_VISUALIZATION=false recommended.
=#

using StructuralSynthesizer
const SY = StructuralSynthesizer
using Unitful

include(joinpath(@__DIR__, "core_office_geometry.jl"))

params = DesignParameters(
    name = "core-office-profile",
    floor = FlatPlateOptions(method = FEA(design_approach = :strip)),
    materials = MaterialOptions(concrete = RC_4000_60.concrete, rebar = Rebar_60),
    columns = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60),
    wall_thickness = 0.3u"m",
    diaphragm_mode = :rigid,
    foundation_options = FoundationParameters(
        soil = medium_sand,
        options = FoundationOptions(strategy = :all_spread),
    ),
    skip_visualization = true,
)

println("Profiling the four-story core office design_building…")
flush(stdout)
struc = BuildingStructure(core_office_skeleton())

local design
t_design = @elapsed begin
    design, probe = SY.with_sizing_probe() do
        design_building(struc, params; restore = false)
    end
end

println("\ndesign_building total: ", round(t_design; digits = 1), " s")

# design_building's own coarse phase timings (prepare / pipeline / capture).
println("\n-- design.phase_timings (coarse) --")
for (phase, secs) in sort(collect(design.phase_timings); by = last, rev = true)
    println("    ", rpad(string(phase), 24), round(secs; digits = 2), " s")
end

# The stage-by-stage breakdown with factorization accounting.
SY.probe_report(probe)

# Raw event total as a sanity check against Asap._N_FACTORIZATIONS semantics.
println("probe recorded ", length(probe.log.events), " analysis events across ",
        length(probe.building_models), " building model id(s) and ",
        length(probe.spans), " stage spans.")
