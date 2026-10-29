# ==============================================================================
# Courtyards: a bay the input face polygons leave out has no slab
# ==============================================================================
#
# One story, 3 × 3 bays of 6 m, columns at every grid point. The roof polygons
# cover the eight outer bays and leave out the middle one. That bay must get
# no cell (no slab, no load), its edges must be slab edges for cell, column,
# and composite-flange purposes, and the surrounding beams must take load from
# one side only.
# ==============================================================================

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const _BAY = 6.0
const _Z = 3.0

_top(i, j) = 1 + i + 4j            # grid vertex (i, j) at the roof
_base(i, j) = 17 + i + 4j          # the same grid point at the base

function _courtyard_input()
    verts = Vector{Vector{Float64}}()
    for z in (_Z, 0.0), j in 0:3, i in 0:3
        push!(verts, [i * _BAY, j * _BAY, z])
    end
    beams = Vector{Vector{Int}}()
    for j in 0:3, i in 0:2
        push!(beams, [_top(i, j), _top(i + 1, j)])
    end
    for j in 0:2, i in 0:3
        push!(beams, [_top(i, j), _top(i, j + 1)])
    end
    columns = [[_base(i, j), _top(i, j)] for j in 0:3 for i in 0:3]
    bay(i, j) = [[i * _BAY, j * _BAY, _Z], [(i + 1) * _BAY, j * _BAY, _Z],
                 [(i + 1) * _BAY, (j + 1) * _BAY, _Z], [i * _BAY, (j + 1) * _BAY, _Z]]
    roof = [bay(i, j) for j in 0:2 for i in 0:2 if (i, j) != (1, 1)]
    return StructuralSynthesizer.APIInput(
        units = "m",
        vertices = verts,
        edges = StructuralSynthesizer.APIEdgeGroups(
            beams = beams, columns = columns, braces = Vector{Vector{Int}}()),
        supports = [_base(i, j) for j in 0:3 for i in 0:3],
        stories_z = [0.0, _Z],
        faces = Dict("roof" => roof),
    )
end

"""Detected face whose vertices are exactly the corners of bay (i, j)."""
function _bay_face(skel, i, j)
    want = Set((_top(i, j), _top(i + 1, j), _top(i + 1, j + 1), _top(i, j + 1)))
    f = findfirst(vs -> Set(vs) == want, skel.face_vertex_indices)
    f === nothing && error("no face for bay ($i, $j)")
    return f
end

@testset "Courtyard bay left out of the face polygons" begin
    skel = json_to_skeleton(_courtyard_input())
    court = _bay_face(skel, 1, 1)
    north = _bay_face(skel, 1, 2)

    @testset "Face groups and edge counts" begin
        @test !(court in skel.groups_faces[:roof])
        @test length(unique(skel.groups_faces[:roof])) == 8
        @test StructuralSynthesizer.slab_face_indices(skel) !== nothing
        @test !(court in StructuralSynthesizer.slab_face_indices(skel))
        # Every courtyard edge borders one slab bay: a boundary edge.
        efc = skel.geometry.edge_face_counts
        @test all(e -> efc[e] == 1, skel.face_edge_indices[court])
        # An outer-ring bay touches the perimeter and the courtyard.
        @test StructuralSynthesizer.classify_cell_position(skel, north) != :interior
    end

    @testset "Floor outline has the courtyard as a hole" begin
        story = only(s for s in values(skel.stories) if court in s.faces)
        loops = story_floor_outline(skel, story)
        @test length(loops) == 2
        area(r) = 0.5 * sum(r[k][1] * r[mod1(k + 1, length(r))][2] -
                            r[mod1(k + 1, length(r))][1] * r[k][2] for k in eachindex(r))
        areas = sort(area.(loops))
        # Courtyard hole runs clockwise; exterior counterclockwise.
        @test areas[1] ≈ -_BAY^2
        @test areas[2] ≈ (3 * _BAY)^2
    end

    @testset "Columns on the courtyard are not interior" begin
        vc = skel.geometry.vertex_coords
        efc = skel.geometry.edge_face_counts
        pos, dirs = StructuralSynthesizer.classify_column_position(skel, _top(1, 1), vc, efc)
        @test pos != :interior
        @test length(dirs) == 2
    end

    @testset "No cell, one-sided beams" begin
        struc = BuildingStructure(skel)
        initialize!(struc; floor_type = :two_way)
        @test length(struc.cells) == 8
        @test all(c -> c.face_idx != court, struc.cells)
        compute_cell_tributaries!(struc)

        court_edges = Set(skel.face_edge_indices[court])
        on_court = filter(struc.beams) do b
            e = struc.segments[only(segment_indices(b))].edge_idx
            e in court_edges
        end
        @test length(on_court) == 4
        for b in on_court
            left, right = beam_side_profiles(struc, b)
            # One side is the slab bay, the courtyard side contributes nothing.
            @test (left === nothing) ⊻ (right === nothing)
        end

        # The four courtyard edges carry exactly one cell's tributary each.
        for e in court_edges
            n = count(enumerate(struc.cells)) do (ci, c)
                e in skel.face_edge_indices[c.face_idx] &&
                    StructuralSynthesizer.cell_edge_tributaries(struc, ci) !== nothing
            end
            @test n == 1
        end
    end
end
