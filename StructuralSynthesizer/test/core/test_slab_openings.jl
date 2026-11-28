# ==============================================================================
# Slab openings: stored on the skeleton per story, cut from cell spans and areas
# ==============================================================================
#
# One story at z = 3 m, 2 × 1 bays of 6 m, columns at every grid point.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const _OP_BAY = 6.0
const _OP_Z = 3.0

_op_top(i, j) = 1 + i + 3j          # grid vertex (i, j) at the roof
_op_base(i, j) = 7 + i + 3j         # the same grid point at the base

function _op_input(openings)
    verts = Vector{Vector{Float64}}()
    for z in (_OP_Z, 0.0), j in 0:1, i in 0:2
        push!(verts, [i * _OP_BAY, j * _OP_BAY, z])
    end
    beams = Vector{Vector{Int}}()
    for j in 0:1, i in 0:1
        push!(beams, [_op_top(i, j), _op_top(i + 1, j)])
    end
    for i in 0:2
        push!(beams, [_op_top(i, 0), _op_top(i, 1)])
    end
    columns = [[_op_base(i, j), _op_top(i, j)] for j in 0:1 for i in 0:2]
    return StructuralSynthesizer.APIInput(
        units = "m",
        vertices = verts,
        edges = StructuralSynthesizer.APIEdgeGroups(
            beams = beams, columns = columns, braces = Vector{Vector{Int}}()),
        supports = [_op_base(i, j) for j in 0:1 for i in 0:2],
        stories_z = [0.0, _OP_Z],
        openings = [[[x, y, _OP_Z] for (x, y) in poly] for poly in openings],
    )
end

function _op_bay_face(skel, i)
    want = Set((_op_top(i, 0), _op_top(i + 1, 0), _op_top(i + 1, 1), _op_top(i, 1)))
    f = findfirst(vs -> Set(vs) == want, skel.face_vertex_indices)
    f === nothing && error("no face for bay $i")
    return f
end

_op_rect(x0, y0, x1, y1) = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]

@testset "Slab openings" begin
    @testset "Plan overlap area" begin
        overlap = StructuralSynthesizer._overlap_area
        L = [(0.0, 0.0), (6.0, 0.0), (6.0, 3.0), (3.0, 3.0), (3.0, 6.0), (0.0, 6.0)]
        @test overlap(L, _op_rect(2.0, 2.0, 5.0, 5.0)) ≈ 5.0 atol=1e-9   # 9 minus the notch's 4
        U = [(0.0, 0.0), (3.0, 0.0), (3.0, 3.0), (2.0, 3.0), (2.0, 1.0), (1.0, 1.0), (1.0, 3.0), (0.0, 3.0)]
        @test overlap(_op_rect(-1.0, -1.0, 4.0, 4.0), U) ≈ 7.0 atol=1e-9
        @test overlap(_op_rect(-1.0, -1.0, 1.5, 4.0), U) ≈ 3.5 atol=1e-9
        @test overlap(U, _op_rect(-1.0, -1.0, 1.5, 4.0)) ≈ 3.5 atol=1e-9
        @test overlap(_op_rect(0.0, 0.0, 1.0, 1.0), _op_rect(1.0, 0.0, 2.0, 1.0)) == 0.0
    end

    centre = _op_rect(2.5, 2.5, 3.5, 3.5)
    straddle = _op_rect(5.5, 2.0, 6.5, 3.0)          # half in each bay
    skel = json_to_skeleton(_op_input([centre, straddle]))
    west, east = _op_bay_face(skel, 0), _op_bay_face(skel, 1)
    roof = StructuralSynthesizer.face_story(skel, west)

    @testset "Storage and per-face lookup" begin
        @test length(skel.openings) == 2
        @test all(op -> op.story == roof, skel.openings)
        @test face_openings(skel, west) == [1, 2]
        @test face_openings(skel, east) == [2]
        @test ustrip(u"m^2", face_net_area(skel, west)) ≈ 36.0 - 1.0 - 0.5 atol=1e-9
        @test ustrip(u"m^2", face_net_area(skel, east)) ≈ 36.0 - 0.5 atol=1e-9
    end

    @testset "Adding openings is checked" begin
        @test_throws ArgumentError add_slab_opening!(skel, _op_rect(3.0, 3.0, 4.0, 4.0), roof)
        @test_throws ArgumentError add_slab_opening!(skel, _op_rect(8.0, 1.0, 9.0, 2.0), 99)
        @test_throws ArgumentError add_slab_opening!(skel, [(0.0, 0.0), (1.0, 0.0)], roof)
        # The same plan cut on another story is a separate opening.
        base = only(k for k in keys(skel.stories) if k != roof)
        add_slab_opening!(skel, _op_rect(3.0, 3.0, 4.0, 4.0), base)
        @test face_openings(skel, west) == [1, 2]
        pop!(skel.openings)
    end

    @testset "Cells use net area" begin
        struc = BuildingStructure(skel)
        StructuralSynthesizer.initialize_cells!(struc)
        cell_w = only(c for c in struc.cells if c.face_idx == west)
        @test ustrip(u"m^2", cell_w.area) ≈ 34.5 atol=1e-9
    end

    @testset "An opening across the bay cuts its span" begin
        cut = _op_rect(2.5, -1.0, 3.5, 7.0)             # crosses the whole west bay in y
        s = json_to_skeleton(_op_input([cut]))
        w, e = _op_bay_face(s, 0), _op_bay_face(s, 1)
        struc = BuildingStructure(s)
        StructuralSynthesizer.initialize_cells!(struc)
        sw = only(c for c in struc.cells if c.face_idx == w).spans
        se = only(c for c in struc.cells if c.face_idx == e).spans
        # Same bay shape, different openings: the span cache must not share them.
        @test ustrip(u"m", sw.primary) ≈ 2.5 atol=1e-9
        @test sw.axis == (1.0, 0.0)
        @test ustrip(u"m", sw.secondary) ≈ 6.0 atol=1e-9
        @test ustrip(u"m", se.primary) ≈ 6.0 atol=1e-9
    end

    @testset "Geometry hash sees openings" begin
        h0 = StructuralSynthesizer.compute_geometry_hash(_op_input(Vector{Tuple{Float64, Float64}}[]))
        h1 = StructuralSynthesizer.compute_geometry_hash(_op_input([centre]))
        @test h0 != h1
    end
end
