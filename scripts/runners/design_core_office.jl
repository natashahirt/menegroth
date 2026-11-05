#=
Fully designed four-story core office, written as a viewer scene.

    julia --project=StructuralSynthesizer scripts/runners/design_core_office.jl [out.mgscene]

Same geometry as export_core_office.jl: 3×3 bays of 8 m, four stories of 3.6 m,
the center bay claimed as 300 mm walls on every story below the roof. Those
floors are open over the core; the roof is closed. Frames that run into the
shaft have fewer than three continuous spans and end on a wall, so direct
design is not used (ACI 318-11 §13.6.1.1 and R13.1). The flat plate is sized
by FEA on design strips. `:frame` would still split moments with the
§13.6.4/.6 fractions, which measure column to column and jump the shaft.
`:strip` reads the shell field of the wall-supported plate. Concrete columns and isolated
spread footings on medium sand. No lateral design. Then builds the frame +
slab + wall service model (`build_analysis_model!`) and writes
viewer/public/core_office.mgscene.
Prints the time of each step.
=#

using StructuralSynthesizer
using Asap
using Unitful

include(joinpath(@__DIR__, "core_office_geometry.jl"))

const out = isempty(ARGS) ?
    joinpath(@__DIR__, "..", "..", "viewer", "public", "core_office.mgscene") :
    ARGS[1]

params = DesignParameters(
    name = "core-office",
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

println("Designing the four-story core office…")
flush(stdout)
struc = BuildingStructure(core_office_skeleton())
t_design = @elapsed design = design_building(struc, params; restore = false)
t_model = @elapsed build_analysis_model!(design)
model = design.asap_model
t_scene = @elapsed packet = build_scene(design)
mkpath(dirname(out))
t_write = @elapsed write_scene(out, packet)

kinds = Dict{Symbol, Int}()
for sh in model.shell_elements
    k = sh.id === :wall ? :wall : startswith(String(sh.id), "slab") ? :slab : sh.id
    kinds[k] = get(kinds, k, 0) + 1
end
slab_nodes = Set(objectid(n) for sh in model.shell_elements if sh.id !== :wall for n in sh.nodes)
wall_nodes = Set(objectid(n) for sh in model.shell_elements if sh.id === :wall for n in sh.nodes)

println("wrote ", abspath(out), "  (", round(filesize(out) / 1024; digits = 1), " KiB)")
println("  slabs: ", length(design.slabs), "  column segments: ", length(design.columns),
        "  footings: ", length(design.foundations))
println("  model nodes: ", length(model.nodes), "  frame elements: ", length(model.frame_elements),
        "  shell triangles: ", kinds)
println("  slab nodes shared with walls: ", length(intersect(slab_nodes, wall_nodes)))
println("  max displacement: ", round(packet.meta["max_displacement"] * 1000; digits = 2), " mm",
        "  suggested scale: ", round(packet.meta["suggested_scale"]; digits = 1))
println("  timings (s): design ", round(t_design; digits = 1),
        "  analysis model ", round(t_model; digits = 2),
        "  build_scene ", round(t_scene; digits = 2),
        "  write ", round(t_write; digits = 3))
for (phase, secs) in sort(collect(design.phase_timings); by = last, rev = true)
    println("    ", rpad(phase, 24), round(secs; digits = 2), " s")
end
