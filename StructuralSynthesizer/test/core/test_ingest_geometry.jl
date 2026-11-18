# Ingest refuses a joint drawn twice and beams that pass through each other,
# and an L or a U face is matched from a point inside it.

using Test
using Unitful
using StructuralSynthesizer

function _input(; vertices, beams, faces = Dict{String, Vector{Vector{Vector{Float64}}}}())
    return StructuralSynthesizer.APIInput(
        units = "m",
        vertices = vertices,
        edges = StructuralSynthesizer.APIEdgeGroups(
            beams = beams,
            columns = Vector{Vector{Int}}(),
            braces = Vector{Vector{Int}}(),
        ),
        supports = Int[],
        stories_z = [3.0],
        faces = faces,
    )
end

function _square(z = 3.0)
    return [[0.0, 0.0, z], [4.0, 0.0, z], [4.0, 4.0, z], [0.0, 4.0, z]]
end

@testset "Ingest geometry" begin
    @testset "vertices within 1 mm are one joint" begin
        near = _input(vertices = vcat(_square(), [[0.0005, 0.0, 3.0]]),
                      beams = [[1, 2], [2, 3], [3, 4], [4, 1]])
        err = try
            json_to_skeleton(near)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("0.0005", err.msg)
        @test occursin("(0.0, 0.0, 3.0)", err.msg)

        # 2 mm apart is a different joint, and the square still has one face.
        apart = _input(vertices = vcat(_square(), [[0.002, 0.0, 3.0]]),
                       beams = [[1, 2], [2, 3], [3, 4], [4, 1]])
        skel = json_to_skeleton(apart)
        @test length(skel.face_vertex_indices) == 1
        @test json_to_skeleton(apart).face_vertex_indices == skel.face_vertex_indices
    end

    @testset "beams that cross need a joint" begin
        # A plus sign. The arms meet at (1, 1) and no vertex is there.
        plus = _input(
            vertices = [[0.0, 1.0, 3.0], [2.0, 1.0, 3.0], [1.0, 0.0, 3.0], [1.0, 2.0, 3.0]],
            beams = [[1, 2], [3, 4]])
        err = try
            json_to_skeleton(plus)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("(1.0, 1.0)", err.msg)

        # Longer arms cross at the same point and still say so.
        wide = _input(
            vertices = [[-2.0, 1.0, 3.0], [4.0, 1.0, 3.0], [1.0, -2.0, 3.0], [1.0, 4.0, 3.0]],
            beams = [[1, 2], [3, 4]])
        wide_err = try
            json_to_skeleton(wide)
            nothing
        catch e
            e
        end
        @test wide_err isa ArgumentError
        @test occursin("(1.0, 1.0)", wide_err.msg)

        # Two beams that share an end are a joint.
        corner = _input(
            vertices = _square(),
            beams = [[1, 2], [2, 3], [3, 4], [4, 1]])
        @test length(json_to_skeleton(corner).face_vertex_indices) == 1

        # The same plus sign one story up does not meet the lower beam.
        stacked = _input(
            vertices = [[0.0, 1.0, 3.0], [2.0, 1.0, 3.0], [1.0, 0.0, 6.0], [1.0, 2.0, 6.0]],
            beams = [[1, 2], [3, 4]])
        @test length(json_to_skeleton(stacked).edges) == 2
    end

    @testset "an explicit U matches the face, not the notch" begin
        # 6 m square with a 2 m by 4 m notch. The vertex average sits in the notch.
        u = [[0.0, 0.0, 3.0], [6.0, 0.0, 3.0], [6.0, 6.0, 3.0], [4.0, 6.0, 3.0],
             [4.0, 2.0, 3.0], [2.0, 2.0, 3.0], [2.0, 6.0, 3.0], [0.0, 6.0, 3.0]]
        beams = [[k, mod1(k + 1, 8)] for k in 1:8]
        input = _input(vertices = u, beams = beams, faces = Dict("floor" => [u]))
        skel = json_to_skeleton(input)
        @test skel.groups_faces[:floor] == [1]
        @test ustrip(u"m^2", face_net_area(skel, 1)) ≈ 28.0

        # A wider notch is a smaller floor and still matches.
        wide = [[0.0, 0.0, 3.0], [6.0, 0.0, 3.0], [6.0, 6.0, 3.0], [5.0, 6.0, 3.0],
                [5.0, 2.0, 3.0], [1.0, 2.0, 3.0], [1.0, 6.0, 3.0], [0.0, 6.0, 3.0]]
        wide_in = _input(vertices = wide, beams = beams, faces = Dict("floor" => [wide]))
        wide_skel = json_to_skeleton(wide_in)
        @test wide_skel.groups_faces[:floor] == [1]
        @test ustrip(u"m^2", face_net_area(wide_skel, 1)) < 28.0
        @test json_to_skeleton(input).groups_faces[:floor] == skel.groups_faces[:floor]
    end
end
