# An opening is a hole in the diaphragm, the semirigid mesh, and the centre of mass.
#
# The shell covers the slab that remains. A larger opening removes more. The
# centre of mass moves away from an opening, and further when that opening grows.
# A second call does not move it.

using Test
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer
const OD_Z = 3.0

function _od_bay(opening)
    corners = [(0.0, 0.0), (12.0, 0.0), (12.0, 6.0), (0.0, 6.0)]
    skel = BuildingSkeleton{Float64}()
    coords = [[x, y, OD_Z] for (x, y) in corners]
    sto = [add_vertex!(skel, c) for c in coords]
    for i in 1:4
        add_element!(skel, sto[i], sto[mod1(i + 1, 4)]; group = :beams)
    end
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    if opening !== nothing
        add_slab_opening!(skel, opening, SS.story_index_at(skel, OD_Z); framing = :none)
    end
    fidx = findfirst(vs -> Set(vs) == Set(sto), skel.face_vertex_indices)
    spans = SpanInfo{Float64}(12.0, 6.0, (0.0, 1.0), 6.0)
    struc = BuildingStructure(skel)
    cell = Cell(fidx, 72.0u"m^2", spans, 2.0u"kN/m^2", 0.0u"kN/m^2")
    cell.floor_type = :flat_plate
    push!(struc.cells, cell)
    push!(struc.slabs, Slab{Float64}([1],
        CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
        :flat_plate, spans, :interior, nothing, MaterialVolumes(),
        nothing, nothing, FramingLevel{Float64}[]))
    nodes = [Asap.Node(c .* u"m", :free) for c in coords]
    return struc, skel, skel.stories[SS.story_index_at(skel, OD_Z)], nodes
end

_od_area(shells) = sum(sh.area isa Unitful.Quantity ? ustrip(u"m^2", sh.area) : Float64(sh.area)
                       for sh in shells)

@testset "Openings are holes downstream" begin
    small = [(1.0, 2.0), (5.0, 2.0), (5.0, 4.0), (1.0, 4.0)]
    big = [(1.0, 1.0), (7.0, 1.0), (7.0, 5.0), (1.0, 5.0)]

    struc, skel, story, nodes = _od_bay(small)
    com = story_center_of_mass(skel, story, struc.cells)
    # 72 m² at (6, 3), minus 8 m² at (3, 3).
    @test com[1] ≈ (72 * 6 - 8 * 3) / 64 atol = 1e-6
    @test com[2] ≈ 3.0 atol = 1e-6
    @test story_center_of_mass(skel, story, struc.cells) == com

    wide, skel_w, story_w, wide_nodes = _od_bay(big)
    com_w = story_center_of_mass(skel_w, story_w, wide.cells)
    # 24 m² at (4, 3) pulls the centre further right than the 8 m² opening.
    @test com_w[1] ≈ (72 * 6 - 24 * 4) / 48 atol = 1e-6
    @test com_w[1] > com[1] + 0.2

    plain, _, _, plain_nodes = _od_bay(nothing)
    plain_shells = SS.create_slab_diaphragm_shells(plain, only(plain.slabs), plain_nodes)
    small_shells = SS.create_slab_diaphragm_shells(struc, only(struc.slabs), nodes)
    wide_shells = SS.create_slab_diaphragm_shells(wide, only(wide.slabs), wide_nodes)
    @test _od_area(plain_shells) ≈ 72 atol = 0.5
    @test _od_area(small_shells) ≈ 64 atol = 0.5
    @test _od_area(wide_shells) < _od_area(small_shells) - 10

    mesh(opening) = begin
        s, sk, _, nd = _od_bay(opening)
        face = only(sk.face_vertex_indices |> eachindex)
        SS._mesh_semirigid_face(sk, face, nd, Asap.Node[], Dict{Any, Any}(),
            2.0, 0.2u"m", 30.0e9u"Pa", 0.2)
    end
    @test _od_area(mesh(nothing)) ≈ 72 atol = 1e-3
    @test _od_area(mesh(small)) ≈ 64 atol = 1e-3
    @test _od_area(mesh(big)) ≈ 48 atol = 1e-3
end
