using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
Pkg.instantiate()

using Unitful
using StructuralSizer
using StructuralSynthesizer

"""
Return unique naked-boundary vertex indices from a triangle face list.
"""
function boundary_vertex_indices(faces::Vector{Vector{Int}})
    edge_count = Dict{Tuple{Int, Int}, Int}()
    for tri in faces
        length(tri) == 3 || continue
        i1, i2, i3 = tri
        for (a, b) in ((i1, i2), (i2, i3), (i3, i1))
            key = a <= b ? (a, b) : (b, a)
            edge_count[key] = get(edge_count, key, 0) + 1
        end
    end
    vids = Set{Int}()
    for ((a, b), c) in edge_count
        c == 1 || continue
        push!(vids, a)
        push!(vids, b)
    end
    return collect(vids)
end

"""
Squared distance from point to segment in 2D.
"""
function point_to_segment_dist2(px, py, x0, y0, x1, y1)
    dx = x1 - x0
    dy = y1 - y0
    denom = dx * dx + dy * dy
    if denom <= 1e-18
        return (px - x0)^2 + (py - y0)^2
    end
    t = clamp(((px - x0) * dx + (py - y0) * dy) / denom, 0.0, 1.0)
    qx = x0 + t * dx
    qy = y0 + t * dy
    return (px - qx)^2 + (py - qy)^2
end

"""
Distance from point to closed polygon boundary in 2D.
"""
function point_to_polygon_boundary_dist(px, py, poly::Vector{Vector{Float64}})
    n = length(poly)
    n < 2 && return Inf
    best_d2 = Inf
    for i in 1:n
        p0 = poly[i]
        p1 = poly[mod1(i + 1, n)]
        d2 = point_to_segment_dist2(px, py, p0[1], p0[2], p1[1], p1[2])
        d2 < best_d2 && (best_d2 = d2)
    end
    return sqrt(best_d2)
end

println("Running slab edge alignment check...")

# Small but non-trivial floor plate (exterior columns create boundary offsets).
skel = gen_medium_office(72.0u"ft", 48.0u"ft", 12.0u"ft", 3, 2, 1)
struc = BuildingStructure(skel)

params = DesignParameters(
    name = "slab_edge_alignment_check",
    max_iterations = 2,
    materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
    floor = FlatPlateOptions(method = DDM()),
)

design = design_building(struc, params)
build_analysis_model!(design; mesh_density = 2)
viz = StructuralSynthesizer._serialize_visualization(design, design.params.display_units)
@assert !isnothing(viz) "Visualization payload is missing"

sized_by_id = Dict{Int, Any}()
for s in viz.sized_slabs
    sized_by_id[s.slab_id] = s
end

@assert !isempty(viz.deflected_slab_meshes) "No deflected slab meshes generated"

tol = 0.08  # display length units (ft in default imperial mode)
global_max = let
    gmax = 0.0
    for dm in viz.deflected_slab_meshes
        slab_id = dm.slab_id
        @assert haskey(sized_by_id, slab_id) "Missing sized slab boundary for slab_id=$slab_id"
        poly = sized_by_id[slab_id].boundary_vertices
        bvids = boundary_vertex_indices(dm.faces)
        isempty(bvids) && continue

        slab_max = 0.0
        for vi in bvids
            (vi < 1 || vi > length(dm.vertices)) && continue
            v = dm.vertices[vi]
            d = point_to_polygon_boundary_dist(v[1], v[2], poly)
            d > slab_max && (slab_max = d)
            d > gmax && (gmax = d)
        end
        println("  slab $slab_id max boundary mismatch = $(round(slab_max, digits=4))")
    end
    gmax
end

println("Global max boundary mismatch = $(round(global_max, digits=4))")
@assert global_max <= tol "Boundary mismatch too large: $(round(global_max, digits=4)) > $tol"
println("Slab edge alignment check passed (tol=$tol).")
