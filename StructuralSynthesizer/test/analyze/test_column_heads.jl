# A column on a rib grid seeds the bays around it.
#
# A corner is one bay, a mid-edge column is the bays along that edge, and an
# interior column is the bays around the crossing. A column on another story
# is not seeded. The head is not grown: growth waits for a punching check to
# name a direction. A second call matches the first.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SY = StructuralSynthesizer

function _rib_panel()
    skel = BuildingSkeleton{Float64}()
    corners = [(0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0)]
    vs = [add_vertex!(skel, [x, y, 3.0]) for (x, y) in corners]
    for k in 1:4
        add_element!(skel, vs[k], vs[mod1(k + 1, 4)]; group = :beams)
    end
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    struc = BuildingStructure(skel)
    spans = SpanInfo{Float64}(6.0, 4.0, (0.0, 1.0), 4.0)
    fidx = findfirst(f -> Set(f) == Set(vs), skel.face_vertex_indices)
    cell = Cell(fidx, 24.0u"m^2", spans, 2.0u"kN/m^2", 0.0u"kN/m^2")
    cell.floor_type = :two_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab([1], CIPSlabResult(0.2, 0.2, 5.0), spans; floor_type = :two_way))
    initialize_segments!(struc)
    initialize_members!(struc)
    slab = only(struc.slabs)
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(2, 2),
                                     material = A992_Steel,
                                     analysis = :grillage)
    push!(slab.framing_levels, level)
    SY.materialize_level!(struc, slab, level)
    return struc, slab, level
end

function _add_column!(struc, xy, z0, z1)
    skel = struc.skeleton
    function at(z)
        for i in eachindex(skel.vertices)
            p = SY._vertex_xy_m(skel, i)
            abs(p[1] - xy[1]) < 1e-6 && abs(p[2] - xy[2]) < 1e-6 &&
                abs(SY._vertex_z_m(skel, i) - z) < 1e-6 && return i
        end
        return add_vertex!(skel, [xy[1], xy[2], z]; group = :columns)
    end
    a, b = at(z0), at(z1)
    e = add_element!(skel, a, b; group = :columns)
    p, q = SY._vertex_xy_m(skel, a), SY._vertex_xy_m(skel, b)
    L = hypot(q[1] - p[1], q[2] - p[2], SY._vertex_z_m(skel, b) - SY._vertex_z_m(skel, a))
    push!(struc.segments, Segment(e, L))
    push!(struc.columns, Column([length(struc.segments)], L))
    return struc.columns[end]
end

_bays_at(heads, xy) = only(h.bays for h in heads if
    hypot(h.column[1] - xy[1], h.column[2] - xy[2]) < 1e-6)

@testset "A column seeds the rib bays around it" begin
    struc, slab, level = _rib_panel()
    _add_column!(struc, (0.0, 0.0), 0.0, 3.0)
    _add_column!(struc, (3.0, 0.0), 0.0, 3.0)
    _add_column!(struc, (3.0, 2.0), 0.0, 3.0)
    # Same plan point, one story above the slab.
    _add_column!(struc, (3.0, 0.0), 6.0, 9.0)

    heads = SY.slab_column_heads(struc, slab, level)
    @test length(heads) == 3
    corner = _bays_at(heads, (0.0, 0.0))
    edge = _bays_at(heads, (3.0, 0.0))
    interior = _bays_at(heads, (3.0, 2.0))
    @test length(corner) == 1
    @test length(edge) == 2
    @test length(interior) == 4
    @test length(edge) > length(corner)
    @test length(interior) > length(edge)

    again = SY.slab_column_heads(struc, slab, level)
    @test [h.bays for h in again] == [h.bays for h in heads]
    @test [h.column for h in again] == [h.column for h in heads]
end
