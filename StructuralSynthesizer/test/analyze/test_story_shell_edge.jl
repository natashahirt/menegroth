# The re-entrant corner of an L slides along the unbanded inner edge.
# Columns of 0.4 m sit at (0, 0), (6, 0), (3, 6) and (0, 6). None sit on
# y = 3, so that run has no width. The column at (3, 6) widens x = 3, and
# the corner (3, 3) moves to (3.2, 3), along the mesh. The band has to stay
# a set of positive-area triangles, and the mesh nodes on that slide have to
# be corners of the band.

using Test
using Unitful
using StructuralSynthesizer
using Asap

function _l_edge_story()
    skel = BuildingSkeleton{Float64}()
    z = 3.0
    pts = [(0.0, 0.0), (6.0, 0.0), (6.0, 3.0), (3.0, 3.0), (3.0, 6.0), (0.0, 6.0)]
    ids = Int[]
    for p in pts
        push!(ids, add_vertex!(skel, [p[1], p[2], z]))
    end
    for i in eachindex(ids)
        add_element!(skel, ids[i], ids[mod1(i + 1, length(ids))]; group = :beams)
    end
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    struc = BuildingStructure(skel)
    face = findfirst(vs -> Set(vs) == Set(ids), skel.face_vertex_indices)
    face === nothing && error("the L story has no face")
    spans = SpanInfo{Float64}(6.0, 6.0, (1.0, 0.0), 3.0)
    cell = Cell(face, 27.0u"m^2", spans, 2.0u"kN/m^2", 0.0u"kN/m^2")
    cell.floor_type = :one_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab([1], CIPSlabResult(0.20, 0.20, 5.0), spans; floor_type = :one_way))
    # Vertices 3 and 4 are the inner leg at y = 3. No column there.
    for i in (1, 2, 5, 6)
        push!(struc.columns, Column(1, 3.0; vertex_idx = ids[i], story = 0,
                                    c1 = 0.4, c2 = 0.4))
    end
    return struc
end

@testset "A story-shell band corner sliding along an unbanded run stays a triangle" begin
    struc = _l_edge_story()
    shell = build_story_shell(struc, 0; target_edge = 0.1u"m")
    @test shell.model !== nothing
    @test isempty(shell.reasons)
    built = shell.built
    @test length(built.panel_index) == length(built.shells)
    @test all(el -> el.area > 1e-6, built.shells)
    @test all(el -> length(unique(objectid, el.nodes)) == 3, built.shells)
    band = filter(el -> el.id === :slab_edge, built.shells)
    @test !isempty(band)
    inner = Asap.Node[]
    seen = Set{UInt64}()
    for el in built.shells, n in el.nodes
        id = objectid(n)
        id in seen && continue
        push!(seen, id)
        x = ustrip(u"m", n.position[1])
        y = ustrip(u"m", n.position[2])
        abs(y - 3.0) < 1e-6 && 3.0 + 1e-6 < x < 3.2 - 1e-6 && push!(inner, n)
    end
    @test !isempty(inner)
    @test all(n -> any(el -> any(m -> m === n, el.nodes), band), inner)
end
