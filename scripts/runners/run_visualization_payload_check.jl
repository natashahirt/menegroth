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
@assert haskey(viz, :sized_slabs) "Visualization missing sized_slabs"
@assert haskey(viz, :deflected_slab_meshes) "Visualization missing deflected_slab_meshes"
@assert haskey(viz, :foundations) "Visualization missing foundations"
@assert haskey(viz, :is_beamless_system) "Visualization missing is_beamless_system"

frame_elements = viz.frame_elements
sized_slabs = viz.sized_slabs
slab_meshes = viz.deflected_slab_meshes
foundations = viz.foundations

@assert viz.is_beamless_system isa Bool "Visualization is_beamless_system must be Bool"

for (i, s) in enumerate(sized_slabs)
    @assert haskey(s, :drop_panels) "Sized slab $i missing drop_panels"
    for (j, dp) in enumerate(s.drop_panels)
        @assert haskey(dp, :center) "Sized slab $i drop panel $j missing center"
        @assert haskey(dp, :length) "Sized slab $i drop panel $j missing length"
        @assert haskey(dp, :width) "Sized slab $i drop panel $j missing width"
        @assert haskey(dp, :extra_depth) "Sized slab $i drop panel $j missing extra_depth"
        @assert length(dp.center) == 3 "Sized slab $i drop panel $j center must be length 3"
    end
end

for (i, m) in enumerate(slab_meshes)
    @assert haskey(m, :vertex_displacements_local) "Slab mesh $i missing vertex_displacements_local"
    @assert haskey(m, :drop_panels) "Slab mesh $i missing drop_panels"
    n_global = length(m.vertex_displacements)
    n_local = length(m.vertex_displacements_local)
    @assert n_local == n_global "Slab mesh $i local/global displacement counts differ ($n_local != $n_global)"
    for (j, dp) in enumerate(m.drop_panels)
        @assert haskey(dp, :center) "Slab mesh $i drop panel $j missing center"
        @assert haskey(dp, :length) "Slab mesh $i drop panel $j missing length"
        @assert haskey(dp, :width) "Slab mesh $i drop panel $j missing width"
        @assert haskey(dp, :extra_depth) "Slab mesh $i drop panel $j missing extra_depth"
        @assert length(dp.center) == 3 "Slab mesh $i drop panel $j center must be length 3"
    end
end

if !isempty(frame_elements)
    for (i, e) in enumerate(frame_elements)
        @assert haskey(e, :element_type) "Frame element $i missing element_type"
        @assert haskey(e, :material_color_hex) "Frame element $i missing material_color_hex"
        et = String(e.element_type)
        @assert et in ("beam", "column", "strut", "other") "Frame element $i has unknown element_type=$et"
        if et in ("beam", "column")
            @assert haskey(e, :section_depth) "Frame element $i missing section_depth"
            @assert haskey(e, :section_width) "Frame element $i missing section_width"
            has_poly = haskey(e, :section_polygon) && length(e.section_polygon) >= 3
            has_dims = e.section_depth > 0 && e.section_width > 0
            @assert has_poly || has_dims "Frame element $i ($et) missing renderable section geometry"
        end
    end
end

println("Visualization payload check passed:")
println("  frame_elements = $(length(frame_elements))")
println("  sized_slabs = $(length(sized_slabs))")
println("  deflected_slab_meshes = $(length(slab_meshes))")
println("  foundations = $(length(foundations))")
