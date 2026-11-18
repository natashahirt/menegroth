#=
Rebuild viewer/public/core_office.mgscene from the saved design.

    julia --project=StructuralSynthesizer scripts/runners/rebuild_core_office_scene.jl

Loads core_office.mgdesign, rebuilds the service model, and writes the scene.
The design itself is not re-run.
=#

using StructuralSynthesizer

const dir = joinpath(@__DIR__, "..", "..", "viewer", "public")
const design_path = joinpath(dir, "core_office.mgdesign")
const scene_path = joinpath(dir, "core_office.mgscene")

println("load ", design_path)
design = load_design(design_path)
println("analysis model")
build_analysis_model!(design)
println("scene")
packet = build_scene(design)
write_scene(scene_path, packet)
counts = packet.meta["counts"]
println("wrote ", scene_path, "  tributary polygons ", get(counts, "tributary_polygons", 0))
