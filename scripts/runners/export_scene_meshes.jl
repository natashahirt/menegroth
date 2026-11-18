#=
Write the solids in a scene packet as a Wavefront OBJ.

    julia --project=StructuralSynthesizer scripts/runners/export_scene_meshes.jl [scene.mgscene] [out.obj]

Columns are the swept member solids. Slabs and walls are each shell triangle
extruded by its thickness. Footings are the sized boxes. Meters, Z up.
The default scene is the core office already written for the viewer.
=#

using StructuralSynthesizer

const scene_path = length(ARGS) >= 1 ? ARGS[1] :
    joinpath(@__DIR__, "..", "..", "viewer", "public", "core_office.mgscene")
const obj_path = if length(ARGS) >= 2
    ARGS[2]
else
    endswith(scene_path, ".mgscene") ||
        error("pass the output path: export_scene_meshes.jl <scene.mgscene> <out.obj>")
    replace(scene_path, r"\.mgscene$" => ".obj")
end

meshes = export_scene_meshes(scene_path, obj_path)
println("wrote ", abspath(obj_path), "  (", round(filesize(obj_path) / 1024; digits = 1), " KiB)")
for mesh in meshes
    println("  ", rpad(mesh.name, 10), length(mesh.faces) ÷ 3, " triangles")
end
