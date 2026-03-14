using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
using HTTP
using JSON3

const BASE = length(ARGS) >= 1 ? rstrip(ARGS[1], '/') : "http://127.0.0.1:8080"

resp = HTTP.get("$(BASE)/result"; readtimeout=30)
@assert resp.status == 200 "GET /result failed with status $(resp.status)"

obj = JSON3.read(String(resp.body))
@assert haskey(obj, :visualization) "Result missing visualization block"
viz = obj.visualization

@assert haskey(viz, :frame_elements) "Visualization missing frame_elements"
@assert haskey(viz, :deflected_slab_meshes) "Visualization missing deflected_slab_meshes"
@assert haskey(viz, :foundations) "Visualization missing foundations"

frame_elements = viz.frame_elements
slab_meshes = viz.deflected_slab_meshes
foundations = viz.foundations

for (i, m) in enumerate(slab_meshes)
    @assert haskey(m, :vertex_displacements_local) "Slab mesh $i missing vertex_displacements_local"
    n_global = length(m.vertex_displacements)
    n_local = length(m.vertex_displacements_local)
    @assert n_local == n_global "Slab mesh $i local/global displacement counts differ ($n_local != $n_global)"
end

if !isempty(frame_elements)
    @assert haskey(frame_elements[1], :element_type) "Frame element missing element_type"
end

println("Visualization payload check passed:")
println("  frame_elements = $(length(frame_elements))")
println("  deflected_slab_meshes = $(length(slab_meshes))")
println("  foundations = $(length(foundations))")
