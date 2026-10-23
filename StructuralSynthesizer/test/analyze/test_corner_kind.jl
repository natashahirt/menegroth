# =============================================================================
# Corner refinement — convex vs re-entrant classification
# =============================================================================
#
# `slab_material_angle` sums the interior angle each incident horizontal face
# subtends at a column vertex; `classify_corner_kind` turns that into
# :convex (< π) vs :reentrant (> π). Re-entrant corners are routed through the
# general-shape punching engine (ACI 421.1R-99 App. B) because their critical
# section carries (nearly) the full 4-sided perimeter.
#
# These unit tests only need `skel.face_vertex_indices` and a vertex_coords
# matrix, so the skeletons are assembled directly without meshing.

using Test
using StructuralSynthesizer

const SSy = StructuralSynthesizer

@testset "Corner kind (convex vs re-entrant)" begin

    @testset "Convex (outside) corner — single quadrant of slab" begin
        skel = BuildingSkeleton{Float64}()
        skel.face_vertex_indices = [[1, 2, 3, 4]]
        vc = [0.0 0.0 0.0;   # 1: corner vertex
              2.0 0.0 0.0;   # 2
              2.0 2.0 0.0;   # 3
              0.0 2.0 0.0]   # 4
        ang = slab_material_angle(skel, 1, vc)
        @test ang ≈ π / 2 rtol = 1e-9
        @test classify_corner_kind(skel, 1, vc, :corner) == :convex
        @test classify_corner_kind(skel, 1, vc, :edge) == :none
    end

    @testset "Re-entrant (inside / L-notch) corner — three quadrants of slab" begin
        skel = BuildingSkeleton{Float64}()
        # Three unit squares around vertex 1, missing the (+x,+y) quadrant.
        skel.face_vertex_indices = [[2, 3, 4, 1], [1, 4, 5, 6], [2, 1, 7, 8]]
        vc = [ 0.0  0.0 0.0;   # 1: re-entrant vertex
              -1.0  0.0 0.0;   # 2
              -1.0 -1.0 0.0;   # 3
               0.0 -1.0 0.0;   # 4
               1.0 -1.0 0.0;   # 5
               1.0  0.0 0.0;   # 6
               0.0  1.0 0.0;   # 7
              -1.0  1.0 0.0]   # 8
        ang = slab_material_angle(skel, 1, vc)
        @test ang ≈ 3π / 2 rtol = 1e-9
        @test classify_corner_kind(skel, 1, vc, :corner) == :reentrant
    end

    @testset "Interior vertex — full 2π of slab" begin
        skel = BuildingSkeleton{Float64}()
        # Four unit squares fully surrounding vertex 1.
        skel.face_vertex_indices = [[1, 2, 3, 4], [1, 4, 5, 6], [1, 6, 7, 8], [1, 8, 9, 2]]
        vc = [ 0.0  0.0 0.0;   # 1: center
               1.0  0.0 0.0;   # 2
               1.0 -1.0 0.0;   # 3
               0.0 -1.0 0.0;   # 4
              -1.0 -1.0 0.0;   # 5
              -1.0  0.0 0.0;   # 6
              -1.0  1.0 0.0;   # 7
               0.0  1.0 0.0;   # 8
               1.0  1.0 0.0]   # 9
        @test slab_material_angle(skel, 1, vc) ≈ 2π rtol = 1e-9
    end

    @testset "classify_corner_kind from a precomputed angle" begin
        @test classify_corner_kind(π / 2, :corner) == :convex
        @test classify_corner_kind(3π / 2, :corner) == :reentrant
        @test classify_corner_kind(deg2rad(225), :corner) == :reentrant
        @test classify_corner_kind(3π / 2, :edge) == :none
        @test classify_corner_kind(3π / 2, :interior) == :none
    end

    @testset "Non-orthogonal convex wedge recovers its angle" begin
        skel = BuildingSkeleton{Float64}()
        skel.face_vertex_indices = [[1, 2, 3]]
        # 60° wedge at vertex 1 between (1,0) and (cos60°, sin60°).
        vc = [0.0 0.0 0.0;
              1.0 0.0 0.0;
              cosd(60.0) sind(60.0) 0.0]
        @test slab_material_angle(skel, 1, vc) ≈ deg2rad(60) rtol = 1e-9
        @test classify_corner_kind(skel, 1, vc, :corner) == :convex
    end

end
