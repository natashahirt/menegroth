#=
Write a .mgscene packet.

    julia --project=StructuralSynthesizer scripts/runners/export_scene.jl [out.mgscene]

With no path, writes viewer/public/demo.mgscene from demo_frame_model().
=#

using StructuralSynthesizer

const out = isempty(ARGS) ?
    joinpath(@__DIR__, "..", "..", "viewer", "public", "demo.mgscene") :
    ARGS[1]

mkpath(dirname(out))
packet = export_scene(out, demo_frame_model())
println("wrote ", abspath(out))
println("  stages: ", join(packet.stages, ", "))
println("  nodes: ", packet.meta["counts"]["nodes"], "  elements: ", packet.meta["counts"]["elements"])
println("  max displacement: ", packet.meta["max_displacement"], " m")
println("  suggested scale: ", packet.meta["suggested_scale"])
