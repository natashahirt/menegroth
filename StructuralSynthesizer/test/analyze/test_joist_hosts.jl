# Level-1 joists land on an interior girder and on a wall.
#
# The girder is the beam the two bays share. The wall is a plan line across
# the same bays. Each joist gets a node on that line. A taller bay has more
# joists, and every one still lands. A wall on another story is not a host.
# A second populate adds nothing. The wall's length stays the pier height.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer

const HOST_Z = 3.5
const HOST_SPACING = 2.0
const PIER = 3.0

"""
Two bays, 12 m along x and `height` along y, split at `cross_x` by a beam or
a wall. A wall at x = 8 sits one story above and must not catch a joist.
Joists run along x.
"""
function _host_bays(height; cross::Symbol, cross_x::Float64)
    skel = BuildingSkeleton{Float64}()
    v(x, y, z) = add_vertex!(skel, [x, y, z])
    bl, bm, br = v(0.0, 0.0, HOST_Z), v(cross_x, 0.0, HOST_Z), v(12.0, 0.0, HOST_Z)
    tr, tm, tl = v(12.0, height, HOST_Z), v(cross_x, height, HOST_Z), v(0.0, height, HOST_Z)
    for (a, b) in ((bl, bm), (bm, br), (br, tr), (tr, tm), (tm, tl), (tl, bl))
        add_element!(skel, a, b; group = :beams)
    end
    cross_e = add_element!(skel, bm, tm; group = cross)
    above0, above1 = v(8.0, 0.0, HOST_Z + 6.0), v(8.0, height, HOST_Z + 6.0)
    above = add_element!(skel, above0, above1; group = :walls)
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)

    spans = SpanInfo{Float64}(12.0, height, (0.0, 1.0), height)
    struc = BuildingStructure(skel)
    faces = Int[]
    for (i, vis) in enumerate(skel.face_vertex_indices)
        isempty(vis) && continue
        abs(skel.geometry.vertex_coords[vis[1], 3] - HOST_Z) < 1e-6 && push!(faces, i)
    end
    for f in faces
        area = ustrip(u"m^2", face_net_area(skel, f))
        cell = Cell(f, area * u"m^2", spans, 2.0u"kN/m^2", 0.0u"kN/m^2")
        cell.floor_type = :two_way
        push!(struc.cells, cell)
    end
    push!(struc.slabs, Slab{Float64}(collect(eachindex(struc.cells)),
        CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
        :two_way, spans, :interior, nothing, MaterialVolumes(),
        nothing, nothing, FramingLevel{Float64}[]))
    for e in sort(collect(get(skel.groups_edges, :beams, Int[])))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end
    if cross === :walls
        L = ustrip(u"m", skel.geometry.edge_lengths[cross_e])
        push!(struc.segments, Segment(cross_e, L))
        push!(struc.walls, Wall([length(struc.segments)], PIER; thickness = 0.2,
                                 x1 = cross_x, y1 = 0.0, x2 = cross_x, y2 = height))
    end
    Labove = ustrip(u"m", skel.geometry.edge_lengths[above])
    push!(struc.segments, Segment(above, Labove))
    push!(struc.walls, Wall([length(struc.segments)], PIER; thickness = 0.2,
                             x1 = 8.0, y1 = 0.0, x2 = 8.0, y2 = height, story = 1))
    compute_cell_tributaries!(struc)
    populate_levels!(struc; opts = (materials = (steel = A992_Steel,),
                                     spacing = HOST_SPACING, axis = (1.0, 0.0)))
    return struc
end

_metres(x) = x isa Unitful.Quantity ? ustrip(u"m", x) : Float64(x)

function _joist_vertices(struc)
    pts = NTuple{2, Float64}[]
    for b in struc.beams
        b.role === :joist || continue
        for si in SS.segment_indices(b)
            for v in struc.skeleton.edge_indices[struc.segments[si].edge_idx]
                push!(pts, (struc.skeleton.geometry.vertex_coords[v, 1],
                            struc.skeleton.geometry.vertex_coords[v, 2]))
            end
        end
    end
    return pts
end

function _joists_on(struc, x)
    n = 0
    for b in struc.beams
        b.role === :joist || continue
        hits = any(SS.segment_indices(b)) do si
            any(struc.skeleton.edge_indices[struc.segments[si].edge_idx]) do v
                abs(struc.skeleton.geometry.vertex_coords[v, 1] - x) < 1e-6
            end
        end
        hits && (n += 1)
    end
    return n
end

@testset "Joist hosts" begin
    @testset "An interior girder is a level-1 support" begin
        short = _host_bays(6.0; cross = :beams, cross_x = 6.0)
        tall = _host_bays(9.0; cross = :beams, cross_x = 6.0)
        n_short = count(b -> b.role === :joist, short.beams)
        n_tall = count(b -> b.role === :joist, tall.beams)
        @test n_short == 2
        @test n_tall > n_short
        @test _joists_on(short, 6.0) == n_short
        @test _joists_on(tall, 6.0) == n_tall
        @test _joists_on(short, 8.0) == 0
        n_beams = length(short.beams)
        populate_levels!(short; opts = (materials = (steel = A992_Steel,),
                                         spacing = HOST_SPACING, axis = (1.0, 0.0)))
        @test length(short.beams) == n_beams
        @test _joists_on(short, 6.0) == n_short
    end

    @testset "A wall the joists cross is split at the landings" begin
        short = _host_bays(6.0; cross = :walls, cross_x = 4.0)
        tall = _host_bays(9.0; cross = :walls, cross_x = 4.0)
        wall = short.walls[1]
        @test _metres(wall.base.L) ≈ PIER atol = 1e-9
        @test length(SS.segment_indices(wall)) > 1
        n_short = count(b -> b.role === :joist, short.beams)
        n_tall = count(b -> b.role === :joist, tall.beams)
        @test n_tall > n_short
        @test _joists_on(short, 4.0) == n_short
        @test _joists_on(tall, 4.0) == n_tall
        # The wall one story up is still one segment, and no joist meets it.
        @test length(SS.segment_indices(short.walls[2])) == 1
        @test _joists_on(short, 8.0) == 0
        n_beams = length(short.beams)
        n_segs = length(SS.segment_indices(wall))
        populate_levels!(short; opts = (materials = (steel = A992_Steel,),
                                         spacing = HOST_SPACING, axis = (1.0, 0.0)))
        @test length(short.beams) == n_beams
        @test length(SS.segment_indices(wall)) == n_segs
        @test _metres(wall.base.L) ≈ PIER atol = 1e-9
    end

    @testset "Splitting one edge of a girder keeps its other edges" begin
        skel = BuildingSkeleton{Float64}()
        v(x) = add_vertex!(skel, [x, 0.0, HOST_Z])
        a, b, c = v(0.0), v(6.0), v(12.0)
        e1 = add_element!(skel, a, b; group = :beams)
        e2 = add_element!(skel, b, c; group = :beams)
        mid = add_vertex!(skel, [3.0, 0.0, HOST_Z])
        struc = BuildingStructure(skel)
        push!(struc.segments, Segment(e1, 6.0), Segment(e2, 6.0))
        push!(struc.beams, Beam([1, 2], 12.0; role = :girder, level = 0))
        SS._split_host_edge!(struc, struc.beams[1], e1, [mid])
        owned = [struc.segments[si].edge_idx for si in SS.segment_indices(struc.beams[1])]
        @test e2 in owned
        @test e1 in owned
        @test any(owned) do e
            ij = struc.skeleton.edge_indices[e]
            mid in ij
        end
        @test _metres(struc.beams[1].base.L) ≈ 12.0 atol = 1e-9
    end
end
