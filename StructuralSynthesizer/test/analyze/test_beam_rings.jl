# A free-standing beam ring carries the slab outside it. An opening of the
# same outline does not: that strip stays on the outer beams.

using Test
using Unitful
using Asap
using StructuralSynthesizer

function _square!(skel, x0, y0, L, z)
    vs = [add_vertex!(skel, [x0, y0, z]), add_vertex!(skel, [x0 + L, y0, z]),
          add_vertex!(skel, [x0 + L, y0 + L, z]), add_vertex!(skel, [x0, y0 + L, z])]
    for i in 1:4
        add_element!(skel, vs[i], vs[mod1(i + 1, 4)]; group = :beams)
    end
    return vs
end

"""One-way cells on the faces `find_faces!` cut, plus one beam per skeleton edge."""
function _one_way_cells!(struc)
    skel = struc.skeleton
    spans = SpanInfo{Float64}(10.0, 10.0, (1.0, 0.0), 10.0)
    for i in eachindex(skel.face_vertex_indices)
        area = ustrip(u"m^2", face_net_area(skel, i))
        cell = Cell(i, area * u"m^2", spans, 2.0u"kN/m^2", 0.0u"kN/m^2")
        cell.floor_type = :one_way
        push!(struc.cells, cell)
    end
    for e in sort(collect(get(skel.groups_edges, :beams, Int[])))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end
    compute_cell_tributaries!(struc; tributary_axis = (1.0, 0.0))
    compute_member_tributaries!(struc)
    return struc
end

function _ring_building(side)
    skel = BuildingSkeleton{Float64}()
    _square!(skel, 0.0, 0.0, 10.0, 3.0)
    o = (10.0 - side) / 2
    _square!(skel, o, o, side, 3.0)
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    return _one_way_cells!(BuildingStructure(skel))
end

function _opening_building()
    skel = BuildingSkeleton{Float64}()
    _square!(skel, 0.0, 0.0, 10.0, 3.0)
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    add_slab_opening!(skel, [(4.0, 4.0), (6.0, 4.0), (6.0, 6.0), (4.0, 6.0)],
                      only(keys(skel.stories)); framing = :none)
    return _one_way_cells!(BuildingStructure(skel))
end

_outer_index(struc) = argmax(i -> ustrip(u"m^2", struc.cells[i].area), eachindex(struc.cells))

function _ring_edge_set(struc, cell)
    skel = struc.skeleton
    pairs = Dict{NTuple{2, Int}, Int}()
    for (e, (a, b)) in enumerate(skel.edge_indices)
        pairs[(a, b)] = e
        pairs[(b, a)] = e
    end
    edges = Set{Int}()
    for ring in get(skel.face_hole_vertices, cell.face_idx, Vector{Int}[])
        for i in eachindex(ring)
            push!(edges, pairs[(ring[i], ring[mod1(i + 1, length(ring))])])
        end
    end
    return edges
end

function _beam_area(struc, beam)
    p = beam.tributary_profile
    p === nothing && return 0.0
    w = [x isa Unitful.Quantity ? ustrip(u"m", x) : Float64(x) for x in p.widths]
    L = 0.0
    for si in segment_indices(beam)
        len = struc.segments[si].L
        L += len isa Unitful.Quantity ? ustrip(u"m", len) : Float64(len)
    end
    return Asap._trapezoid(p.positions, w) * L
end

@testset "Beam rings carry the surrounding slab" begin
    small = _ring_building(2.0)
    ci = _outer_index(small)
    cell = small.cells[ci]
    tribs = cell_edge_tributaries(small, ci)
    n = length(small.skeleton.face_vertex_indices[cell.face_idx])
    outside = sum(t.area for t in tribs if t.local_edge_idx > n; init = 0.0)
    # 2 m ring, one-way across x: each vertical edge takes half of the 4 m gap.
    @test outside ≈ 8.0 atol = 1e-4
    @test sum(t.area for t in tribs) ≈ ustrip(u"m^2", cell.area) atol = 1e-4

    edges = _ring_edge_set(small, cell)
    ring_beams = filter(small.beams) do b
        struc_edge = small.segments[only(segment_indices(b))].edge_idx
        struc_edge in edges
    end
    carried = sum(_beam_area(small, b) for b in ring_beams)
    # The ring also bounds the inner bay, so the beams carry that too.
    @test carried > outside
    @test carried ≈ outside + 4.0 atol = 0.05

    big = _ring_building(4.0)
    bi = _outer_index(big)
    big_cell = big.cells[bi]
    big_tribs = cell_edge_tributaries(big, bi)
    nbig = length(big.skeleton.face_vertex_indices[big_cell.face_idx])
    @test sum(t.area for t in big_tribs if t.local_edge_idx > nbig; init = 0.0) > outside + 1.0

    # The same outline with no beams is an opening: nothing is credited past
    # the outer edges, and the outer beams keep that strip.
    opened = _opening_building()
    ocell = only(opened.cells)
    otribs = cell_edge_tributaries(opened, 1)
    @test sum(t.area for t in otribs if t.local_edge_idx > 4; init = 0.0) ≈ 0.0 atol = 1e-6
    @test sum(t.area for t in otribs) ≈ 96.0 atol = 1e-3
    outer_beams = sum(_beam_area(opened, b) for b in opened.beams)
    small_outer = sum(_beam_area(small, b) for b in small.beams if
                      small.segments[only(segment_indices(b))].edge_idx ∉ edges)
    @test outer_beams > small_outer + 1.0

    compute_cell_tributaries!(small; tributary_axis = (1.0, 0.0))
    again = cell_edge_tributaries(small, ci)
    @test sum(t.area for t in again if t.local_edge_idx > n; init = 0.0) ≈ outside
end

"""Two-way cells. The ring is a wavefront of the straight skeleton."""
function _two_way_ring(side)
    skel = BuildingSkeleton{Float64}()
    _square!(skel, 0.0, 0.0, 10.0, 3.0)
    o = (10.0 - side) / 2
    _square!(skel, o, o, side, 3.0)
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    struc = BuildingStructure(skel)
    spans = SpanInfo{Float64}(10.0, 10.0, (1.0, 0.0), 10.0)
    for i in eachindex(skel.face_vertex_indices)
        area = ustrip(u"m^2", face_net_area(skel, i))
        cell = Cell(i, area * u"m^2", spans, 2.0u"kN/m^2", 0.0u"kN/m^2")
        cell.floor_type = :two_way
        push!(struc.cells, cell)
    end
    compute_cell_tributaries!(struc)
    return struc
end

@testset "A two-way ring carries the slab around it" begin
    small = _two_way_ring(2.0)
    ci = _outer_index(small)
    cell = small.cells[ci]
    tribs = cell_edge_tributaries(small, ci)
    n = length(small.skeleton.face_vertex_indices[cell.face_idx])
    outside = sum(t.area for t in tribs if t.local_edge_idx > n; init = 0.0)
    # Square frame, gap 4 m: each ring edge takes the 8 m² trapezoid.
    @test outside ≈ 32.0 atol = 1e-3
    @test sum(t.area for t in tribs) ≈ ustrip(u"m^2", cell.area) atol = 1e-3

    big = _two_way_ring(4.0)
    bi = _outer_index(big)
    big_cell = big.cells[bi]
    big_tribs = cell_edge_tributaries(big, bi)
    nbig = length(big.skeleton.face_vertex_indices[big_cell.face_idx])
    bigger = sum(t.area for t in big_tribs if t.local_edge_idx > nbig; init = 0.0)
    @test bigger ≈ 33.0 atol = 1e-3
    @test bigger > outside

    compute_cell_tributaries!(small)
    again = cell_edge_tributaries(small, ci)
    @test sum(t.area for t in again if t.local_edge_idx > n; init = 0.0) ≈ outside
end
