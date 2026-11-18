using Test
using Unitful
using Asap
using StructuralSizer

"""Signed area. Positive when the polygon is counter-clockwise."""
_area(poly) = 0.5 * sum(poly[i][1] * poly[mod1(i + 1, length(poly))][2] -
                        poly[mod1(i + 1, length(poly))][1] * poly[i][2]
                        for i in eachindex(poly))

@testset "Slab edge outside the centerline" begin
    # 10 m by 6 m. Columns at the four corners are 0.2 m to the face.
    # A fifth column at midspan of the south edge is 0.5 m to the face.
    poly = [(0.0, 0.0), (10.0, 0.0), (10.0, 6.0), (0.0, 6.0)]
    columns = [
        (xy = (0.0, 0.0), half = d -> 0.2),
        (xy = (10.0, 0.0), half = d -> 0.2),
        (xy = (10.0, 6.0), half = d -> 0.2),
        (xy = (0.0, 6.0), half = d -> 0.2),
        (xy = (5.0, 0.0), half = d -> 0.5),
    ]
    edge = StructuralSizer.story_slab_edge(poly, columns)
    @test length(edge.runs) == 4
    @test length(edge.outline) == 4
    south = findfirst(r -> r.outward[2] < -0.9, edge.runs)
    north = findfirst(r -> r.outward[2] > 0.9, edge.runs)
    west = findfirst(r -> r.outward[1] < -0.9, edge.runs)
    @test edge.runs[south].width ≈ 0.5
    @test edge.runs[north].width ≈ 0.2
    @test edge.runs[west].width ≈ 0.2
    # The south edge is one straight line, out at the deep column.
    sw = edge.outline[findfirst(r -> r.edges[1] == 1, edge.runs)]
    # outline[k] is the corner at the start of run k. South run starts at (0, 0)
    # when edge 1 is the south edge, which it is for this polygon.
    @test edge.edge_run[1] == south
    @test edge.outline[south][2] ≈ -0.5
    @test edge.outline[south][1] ≈ -0.2
    se_run = edge.edge_run[2]  # east edge starts at the south-east corner
    @test edge.outline[se_run][2] ≈ -0.5
    @test edge.outline[se_run][1] ≈ 10.2
    @test abs(edge.outline[south][2] - edge.outline[se_run][2]) < 1e-9
    @test _area(edge.outline) > _area(poly)

    # A larger south column moves only that edge.
    columns[5] = (xy = (5.0, 0.0), half = d -> 0.8)
    grown = StructuralSizer.story_slab_edge(poly, columns)
    @test grown.runs[south].width ≈ 0.8
    @test grown.runs[north].width ≈ 0.2
    @test grown.outline[south][2] ≈ -0.8
    @test grown.outline[south][1] ≈ edge.outline[south][1]
end

@testset "A point past the end of a segment is off it" begin
    @test StructuralSizer._segment_station((5.0, 0.0), (0.0, 0.0), (10.0, 0.0)) ≈ 0.5
    @test StructuralSizer._segment_station((12.0, 0.0), (0.0, 0.0), (10.0, 0.0)) === nothing
    @test StructuralSizer._segment_station((-1.0, 0.0), (0.0, 0.0), (10.0, 0.0)) === nothing
end

_col(vi, c1, c2) = (vertex_idx = vi, c1 = c1, c2 = c2, shape = :rectangular, θ = 0.0,
                    column_above = nothing)

"""
Two slabs side by side at z = 3 m: cell 1 is 0..5 × 0..6, cell 2 is 5..10 × 0..6.
Vertex 3, the south-east corner, has the column 1.0 m deep in y.
"""
function _two_slab_floor(; deep = 1.0u"m")
    vc = [0.0 0.0 3.0; 5.0 0.0 3.0; 10.0 0.0 3.0; 10.0 6.0 3.0; 5.0 6.0 3.0; 0.0 6.0 3.0]
    skel = (
        geometry = (vertex_coords = vc,),
        face_vertex_indices = [[1, 2, 5, 6], [2, 3, 4, 5]],
        face_edge_indices = [[1, 7, 5, 6], [2, 3, 4, 7]],
        edge_indices = [(1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 1), (2, 5)],
    )
    cells = [(face_idx = 1,), (face_idx = 2,)]
    columns = Any[_col(vi, 0.4u"m", 0.4u"m") for vi in (1, 2, 4, 5, 6)]
    push!(columns, _col(3, 0.4u"m", deep))
    return (skeleton = skel, cells = cells, columns = columns)
end

@testset "The floor's slab edge skips edges between slabs" begin
    floor = _two_slab_floor()
    loops = StructuralSizer.floor_slab_edges(floor, 3.0)
    @test length(loops) == 1
    loop = only(loops)
    @test length(loop.vertices) == 6
    @test !((2, 5) in [minmax(loop.vertices[i], loop.vertices[mod1(i + 1, 6)]) for i in 1:6])
    @test _area(loop.polygon) > 0
    # The south side is one straight run across both slabs, out at the deep column.
    off = StructuralSizer.slab_edge_offsets(loops)
    @test off.side[(1, 2)].width ≈ 0.5
    @test off.side[(2, 3)].width ≈ 0.5
    @test off.side[(5, 6)].width ≈ 0.2
    @test !haskey(off.side, (2, 5))
    @test off.shift[2][2] ≈ -0.5
    @test off.shift[1][1] ≈ -0.2 && off.shift[1][2] ≈ -0.5

    # The corner slab beyond the two run rectangles is 0.2 × 0.5 at the south-west.
    edge = loop.edge
    sw = findfirst(==(1), loop.vertices)
    k = edge.edge_run[sw]
    @test edge.runs[k].edges[1] == sw
    prev = edge.runs[mod1(k - 1, length(edge.runs))]
    @test StructuralSizer.slab_edge_corner_area(loop.polygon[sw], prev, edge.runs[k],
                                                edge.outline[k]) ≈ 0.1

    # Edge width seen by a frame line on the south side, and inside the floor.
    @test StructuralSizer.slab_edge_width_at(floor, 3.0, [(0.0, 0.0), (5.0, 0.0)], (0.0, -1.0)) ≈ 0.5
    @test StructuralSizer.slab_edge_width_at(floor, 3.0, [(5.0, 6.0)], (0.0, 1.0)) ≈ 0.2
    @test StructuralSizer.slab_edge_width_at(floor, 3.0, [(5.0, 0.0), (5.0, 6.0)], (1.0, 0.0)) == 0.0
    @test StructuralSizer.slab_edge_width_at(floor, 7.0, [(0.0, 0.0)], (0.0, -1.0)) == 0.0
    @test StructuralSizer._frame_edge_strip_m(floor, floor.columns[1:2], (0.0, -1.0)) ≈ 0.5

    # Sizes without units are metres.
    bare = _two_slab_floor()
    bare.columns[end] = _col(3, 0.4, 1.0)
    @test StructuralSizer.slab_edge_offsets(
        StructuralSizer.floor_slab_edges(bare, 3.0)).side[(1, 2)].width ≈ 0.5
end

_xy(node) = (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))

"""Centerline mesh of cell 1 of `floor` plus its edge band."""
function _slab_one_mesh(floor)
    vc = floor.skeleton.geometry.vertex_coords
    boundary = [1, 2, 5, 6]
    node_map = Dict(vi => Asap.Node([vc[vi, 1] * u"m", vc[vi, 2] * u"m", 0.0u"m"], :free)
                    for vi in boundary)
    section = Asap.ShellSection(0.2u"m", 30u"GPa", 0.2)
    shells = Asap.Shell(Tuple(node_map[vi] for vi in boundary), section;
                        target_edge_length = 1.0u"m", edge_support_type = :free)
    slab = (cell_indices = [1],)
    StructuralSizer._append_flat_plate_edge_strip!(shells, section, floor, slab, node_map, boundary)
    return (shells = shells, node_map = node_map)
end

@testset "Flat-plate edge band follows the floor's slab edge" begin
    mesh = _slab_one_mesh(_two_slab_floor())
    band = filter(el -> el.id === :slab_edge, mesh.shells)
    @test !isempty(band)
    # South 5 × 0.5 + west 6 × 0.2 + north 5 × 0.2, plus the corners
    # 0.2 × 0.5 (south-west) and 0.2 × 0.2 (north-west). No band on x = 5.
    @test sum(el.area for el in band) ≈ 4.84 rtol = 1e-6
    interior = filter(el -> el.id !== :slab_edge, mesh.shells)
    @test sum(el.area for el in interior) ≈ 30.0 rtol = 1e-6
    xs = [_xy(n)[1] for el in band for n in el.nodes]
    @test maximum(xs) ≈ 5.0 atol = 1e-9
    @test any(el -> any(n -> all(isapprox.(_xy(n), (5.0, -0.5); atol = 1e-9)), el.nodes), band)
    @test _xy(mesh.node_map[1]) == (0.0, 0.0)
    # Every band node is shared with another triangle or the centerline mesh:
    # a moved node sits at a distinct place, and no node is duplicated.
    pos = Dict{NTuple{2, Float64}, Set{UInt}}()
    for el in mesh.shells, n in el.nodes
        push!(get!(() -> Set{UInt}(), pos, round.(_xy(n); digits = 9)), objectid(n))
    end
    @test all(s -> length(s) == 1, values(pos))

    # The area load is built on the same shell vector.
    load = Asap.AreaLoad(mesh.shells, 5.0u"kPa")
    @test any(el -> el.id === :slab_edge, load.shells)

    # The deep column grows: the band widens, the centerline does not move.
    grown = _slab_one_mesh(_two_slab_floor(deep = 1.6u"m"))
    band2 = filter(el -> el.id === :slab_edge, grown.shells)
    @test sum(el.area for el in band2) ≈ 4.84 + 5.0 * 0.3 + 0.2 * 0.3 rtol = 1e-6
    @test _xy(grown.node_map[1]) == (0.0, 0.0)

    # No sized column, no band.
    unsized = _two_slab_floor()
    for i in eachindex(unsized.columns)
        unsized.columns[i] = _col(unsized.columns[i].vertex_idx, nothing, nothing)
    end
    @test !any(el -> el.id === :slab_edge, _slab_one_mesh(unsized).shells)
end

"""
One L-shaped slab at z = 3 m: 0..6 × 0..6 without the 3..6 × 3..6 quarter.
No column sits on the inner leg y = 3, so that run has no band. The column at
(3, 6) widens the inner leg x = 3, which moves the re-entrant corner (3, 3)
along y = 3.
"""
function _l_slab_floor()
    vc = [0.0 0.0 3.0; 6.0 0.0 3.0; 6.0 3.0 3.0; 3.0 3.0 3.0; 3.0 6.0 3.0; 0.0 6.0 3.0]
    skel = (
        geometry = (vertex_coords = vc,),
        face_vertex_indices = [[1, 2, 3, 4, 5, 6]],
        face_edge_indices = [[1, 2, 3, 4, 5, 6]],
        edge_indices = [(1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 1)],
    )
    columns = Any[_col(vi, 0.4u"m", 0.4u"m") for vi in (1, 2, 5, 6)]
    return (skeleton = skel, cells = [(face_idx = 1,)], columns = columns)
end

@testset "A band corner sliding along an unbanded run stays conforming" begin
    floor = _l_slab_floor()
    vc = floor.skeleton.geometry.vertex_coords
    boundary = collect(1:6)
    node_map = Dict(vi => Asap.Node([vc[vi, 1] * u"m", vc[vi, 2] * u"m", 0.0u"m"], :free)
                    for vi in boundary)
    section = Asap.ShellSection(0.2u"m", 30u"GPa", 0.2)
    shells = Asap.Shell(Tuple(node_map[vi] for vi in boundary), section;
                        target_edge_length = 0.1u"m", edge_support_type = :free)
    centerline = copy(shells)
    StructuralSizer._append_flat_plate_edge_strip!(shells, section, floor,
                                                   (cell_indices = [1],), node_map, boundary)
    off = StructuralSizer.slab_edge_offsets(StructuralSizer.floor_slab_edges(floor, 3.0))
    @test off.side[(3, 4)].width == 0.0
    @test all(isapprox.(off.shift[4], (0.2, 0.0); atol = 1e-12))

    band = filter(el -> el.id === :slab_edge, shells)
    @test !isempty(band)
    @test minimum(el.area for el in band) > 1e-6
    # The band fills the slab edge outline less the centerline slab, once.
    outline = only(StructuralSizer.floor_slab_edges(floor, 3.0)).edge.outline
    @test sum(el.area for el in band) ≈ _area(outline) - 27.0 rtol = 1e-9
    # Centerline nodes on y = 3 between the corner and its moved position are
    # corners of band triangles, not hanging on a band edge.
    inner = [n for el in centerline for n in el.nodes
             if abs(_xy(n)[2] - 3.0) < 1e-9 && 3.0 + 1e-6 < _xy(n)[1] < 3.2 - 1e-6]
    @test !isempty(inner)
    @test all(n -> any(el -> any(m -> m === n, el.nodes), band), inner)
end
