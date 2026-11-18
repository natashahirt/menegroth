# A solid head and a joist landing stay on this slab.
#
# A beam on another story, or outside this slab, is not a host and is not cut
# out of its group. The same beam on this slab, inside the head, is.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SY = StructuralSynthesizer

function _square!(skel, z; group = :beams)
    vs = [add_vertex!(skel, [x, y, z]) for (x, y) in
          ((0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0))]
    for k in 1:4
        add_element!(skel, vs[k], vs[mod1(k + 1, 4)]; group = group)
    end
    return vs
end

function _line!(skel, x0, y0, x1, y1, z; group = :beams)
    a = add_vertex!(skel, [x0, y0, z])
    b = add_vertex!(skel, [x1, y1, z])
    add_element!(skel, a, b; group = group)
    return length(skel.edges)
end

function _beam!(struc, edge, level)
    L = ustrip(u"m", struc.skeleton.geometry.edge_lengths[edge])
    push!(struc.segments, Segment(edge, L))
    push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = level))
    return length(struc.beams)
end

"""Two stacked 6 m by 4 m bays. The upper bay is the slab under test."""
function _stacked()
    skel = BuildingSkeleton{Float64}()
    _square!(skel, 3.0)
    _square!(skel, 6.0)
    # A line inside each bay. A wall is a line support, so the face stays one panel.
    lower_in = _line!(skel, 0.2, 0.2, 1.2, 0.8, 3.0; group = :walls)
    upper_in = _line!(skel, 0.2, 0.2, 1.2, 0.8, 6.0; group = :walls)
    outside = _line!(skel, 8.0, 0.0, 8.0, 4.0, 6.0)
    rebuild_stories!(skel)
    find_faces!(skel)
    # Within 1 cm of the slab, and 2 cm off it. Added after the faces so they
    # are not a second story.
    near = _line!(skel, 2.0, 1.0, 2.6, 1.2, 6.005)
    far = _line!(skel, 2.0, 2.0, 2.6, 2.2, 6.02)
    rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    spans = SpanInfo{Float64}(6.0, 4.0, (1.0, 0.0), 4.0)
    upper = findfirst(skel.face_vertex_indices) do vs
        abs(SY._vertex_z_m(skel, vs[1]) - 6.0) < 1e-6
    end
    cell = Cell(upper, 24.0u"m^2", spans, 2.0u"kN/m^2", 0.0u"kN/m^2")
    cell.floor_type = :one_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab([1], CIPSlabResult(0.2, 0.2, 5.0), spans; floor_type = :one_way))

    beams = Dict(
        :lower => _beam!(struc, lower_in, 1),
        :upper => _beam!(struc, upper_in, 1),
        :outside => _beam!(struc, outside, 1),
        :near => _beam!(struc, near, 1),
        :far => _beam!(struc, far, 1),
    )
    return struc, beams
end

function _edge_of(struc, bi)
    return struc.segments[only(segment_indices(struc.beams[bi]))].edge_idx
end

@testset "A solid head stays on its own slab" begin
    struc, beams = _stacked()
    slab = only(struc.slabs)
    hosts = SY._level_host_edges(struc, slab, 2)
    @test _edge_of(struc, beams[:upper]) in hosts
    @test _edge_of(struc, beams[:near]) in hosts
    @test _edge_of(struc, beams[:lower]) ∉ hosts
    @test _edge_of(struc, beams[:outside]) ∉ hosts
    @test _edge_of(struc, beams[:far]) ∉ hosts
    @test SY._level_host_edges(struc, slab, 2) == hosts

    gid_here = UInt64(11)
    gid_there = UInt64(12)
    set_group_id!(struc.beams[beams[:upper]], gid_here)
    set_group_id!(struc.beams[beams[:lower]], gid_there)
    struc.member_groups[gid_here] = MemberGroup(gid_here, [beams[:upper]], nothing)
    struc.member_groups[gid_there] = MemberGroup(gid_there, [beams[:lower]], nothing)
    kept = copy(segment_indices(struc.beams[beams[:lower]]))

    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(4, 4, 0.25),
                                     material = StructuralSizer.A992_Steel,
                                     analysis = :grillage)
    panel = SY._solid_head_panel(struc, slab)
    @test panel !== nothing
    SY._detach_host_solid_runs!(struc, slab, level,
                                [beams[:upper], beams[:lower]], panel)
    @test segment_indices(struc.beams[beams[:lower]]) == kept
    @test group_id(struc.beams[beams[:lower]]) == gid_there
    @test struc.member_groups[gid_there].member_indices == [beams[:lower]]
    # The same line on this slab sits in the corner head, so it leaves the group.
    @test beams[:upper] ∉ struc.member_groups[gid_here].member_indices

    SY._detach_host_solid_runs!(struc, slab, level, [beams[:lower]], panel)
    @test segment_indices(struc.beams[beams[:lower]]) == kept
    @test struc.member_groups[gid_there].member_indices == [beams[:lower]]
end
