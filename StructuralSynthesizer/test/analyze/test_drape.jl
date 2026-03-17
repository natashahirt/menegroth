using Test
using LinearAlgebra: norm

# ─── Load project ─────────────────────────────────────────────────────────────
using StructuralSynthesizer
using StructuralSynthesizer: _idw_interpolate, _PolyCell, _poly_cell_interpolate

# =============================================================================
# Unit tests for IDW interpolation
# =============================================================================
@testset "IDW Interpolation" begin

    @testset "Single data point — always returns that value" begin
        v = _idw_interpolate(5.0, 5.0, [0.0], [0.0], [[1.0, 2.0, 3.0]])
        @test v ≈ [1.0, 2.0, 3.0]
    end

    @testset "Exact at data points" begin
        sx = [0.0, 6.0, 6.0, 0.0]
        sy = [0.0, 0.0, 4.0, 4.0]
        vals = [[0.0, 0.0, -0.01],
                [0.0, 0.0, -0.02],
                [0.0, 0.0, -0.03],
                [0.0, 0.0, -0.04]]

        for i in 1:4
            v = _idw_interpolate(sx[i], sy[i], sx, sy, vals)
            @test v ≈ vals[i]
        end
    end

    @testset "Centroid of equal weights → average" begin
        # Equilateral-like arrangement: IDW at centroid of a rectangle
        # where all data values are equal should return that value
        sx = [0.0, 1.0, 1.0, 0.0]
        sy = [0.0, 0.0, 1.0, 1.0]
        vals = [[0.0, 0.0, -1.0],
                [0.0, 0.0, -1.0],
                [0.0, 0.0, -1.0],
                [0.0, 0.0, -1.0]]
        v = _idw_interpolate(0.5, 0.5, sx, sy, vals)
        @test v ≈ [0.0, 0.0, -1.0]
    end

    @testset "Closer point dominates" begin
        sx = [0.0, 10.0]
        sy = [0.0, 0.0]
        vals = [[0.0, 0.0, -1.0],
                [0.0, 0.0, -2.0]]

        # Query close to first point
        v = _idw_interpolate(0.1, 0.0, sx, sy, vals)
        @test v[3] > -1.1  # Much closer to -1.0 than -2.0

        # Query close to second point
        v = _idw_interpolate(9.9, 0.0, sx, sy, vals)
        @test v[3] < -1.9  # Much closer to -2.0 than -1.0
    end

    @testset "Midpoint of two equal-distance points → exact average" begin
        sx = [0.0, 2.0]
        sy = [0.0, 0.0]
        vals = [[0.0, 0.0, -1.0],
                [0.0, 0.0, -3.0]]
        v = _idw_interpolate(1.0, 0.0, sx, sy, vals)
        @test v ≈ [0.0, 0.0, -2.0]
    end

    @testset "Empty data → zero vector" begin
        v = _idw_interpolate(1.0, 1.0, Float64[], Float64[], Vector{Float64}[])
        @test v ≈ [0.0, 0.0, 0.0]
    end
end

# =============================================================================
# Unit tests for polygon-cell interpolation (non-quad drape support)
# =============================================================================
@testset "Polygon Cell Interpolation" begin
    @testset "Exact at polygon vertices" begin
        verts = [(0.0, 0.0), (2.0, 0.0), (3.0, 1.0), (1.5, 2.0), (0.0, 1.0)]
        vals = [[0.0, 0.0, -0.01],
                [0.0, 0.0, -0.02],
                [0.0, 0.0, -0.03],
                [0.0, 0.0, -0.04],
                [0.0, 0.0, -0.05]]
        cell = _PolyCell(verts, vals)
        for i in eachindex(verts)
            x, y = verts[i]
            v = _poly_cell_interpolate(x, y, cell)
            @test v !== nothing
            @test v ≈ vals[i]
        end
    end

    @testset "Constant field reproduces constant interior value" begin
        verts = [(0.0, 0.0), (2.0, 0.0), (3.0, 1.0), (1.5, 2.0), (0.0, 1.0)]
        vals = [[1.0, -2.0, -0.02] for _ in eachindex(verts)]
        cell = _PolyCell(verts, vals)
        v = _poly_cell_interpolate(1.2, 0.8, cell)
        @test v !== nothing
        @test v ≈ [1.0, -2.0, -0.02]
    end

    @testset "Outside polygon returns nothing" begin
        verts = [(0.0, 0.0), (2.0, 0.0), (3.0, 1.0), (1.5, 2.0), (0.0, 1.0)]
        vals = [[0.0, 0.0, -0.01],
                [0.0, 0.0, -0.02],
                [0.0, 0.0, -0.03],
                [0.0, 0.0, -0.04],
                [0.0, 0.0, -0.05]]
        cell = _PolyCell(verts, vals)
        @test _poly_cell_interpolate(10.0, 10.0, cell) === nothing
    end
end

# =============================================================================
# Integration test: draping math on a synthetic scenario
# =============================================================================
@testset "Draping Superposition Math" begin

    @testset "Superposition formula" begin
        # Simulate:
        # Support at (0,0): coupled_disp = [0,0,-0.005], frame_disp = [0,0,-0.010]
        # Support at (6,0): coupled_disp = [0,0,-0.008], frame_disp = [0,0,-0.015]
        # Interior at (3,0): coupled_disp = [0,0,-0.020] (from coupled solve)

        sup_x = [0.0, 6.0]
        sup_y = [0.0, 0.0]

        coupled_sup = [[0.0, 0.0, -0.005], [0.0, 0.0, -0.008]]
        frame_sup   = [[0.0, 0.0, -0.010], [0.0, 0.0, -0.015]]

        # At midpoint (3,0), equal distance to both supports:
        # coupled_field = average of coupled supports = [0, 0, -0.0065]
        coupled_field = _idw_interpolate(3.0, 0.0, sup_x, sup_y, coupled_sup)
        @test coupled_field ≈ [0.0, 0.0, -0.0065]

        # δ_local = δ_coupled - coupled_field = [0,0,-0.020] - [0,0,-0.0065] = [0,0,-0.0135]
        δ_coupled = [0.0, 0.0, -0.020]
        δ_local = δ_coupled .- coupled_field
        @test δ_local ≈ [0.0, 0.0, -0.0135]

        # frame_field at (3,0) = average of frame supports = [0, 0, -0.0125]
        frame_field = _idw_interpolate(3.0, 0.0, sup_x, sup_y, frame_sup)
        @test frame_field ≈ [0.0, 0.0, -0.0125]

        # δ_draped = frame_field + δ_local = [0, 0, -0.0125 + -0.0135] = [0, 0, -0.026]
        δ_draped = frame_field .+ δ_local
        @test δ_draped ≈ [0.0, 0.0, -0.026]

        # Interpretation: the shell node at midspan has -13.5mm of local sag
        # plus -12.5mm of frame global settlement = -26.0mm total rendered displacement.
    end

    @testset "At support point, draping gives frame displacement" begin
        sup_x = [0.0, 6.0]
        sup_y = [0.0, 0.0]
        coupled_sup = [[0.0, 0.0, -0.005], [0.0, 0.0, -0.008]]
        frame_sup   = [[0.0, 0.0, -0.010], [0.0, 0.0, -0.015]]

        # Query exactly at first support
        coupled_field = _idw_interpolate(0.0, 0.0, sup_x, sup_y, coupled_sup)
        frame_field   = _idw_interpolate(0.0, 0.0, sup_x, sup_y, frame_sup)

        # At a support: δ_coupled = coupled_sup[1], so δ_local = 0
        δ_local = coupled_sup[1] .- coupled_field
        @test norm(δ_local) < 1e-12

        # Therefore δ_draped = frame_field = frame_sup[1]
        δ_draped = frame_field .+ δ_local
        @test δ_draped ≈ frame_sup[1]
    end

    @testset "When frame and coupled agree, draping is identity" begin
        sup_x = [0.0, 6.0, 6.0, 0.0]
        sup_y = [0.0, 0.0, 4.0, 4.0]
        # Same displacements in both models
        same_disp = [[0.0, 0.0, -0.01],
                     [0.0, 0.0, -0.01],
                     [0.0, 0.0, -0.01],
                     [0.0, 0.0, -0.01]]

        # Interior point
        δ_coupled_interior = [0.0, 0.0, -0.025]  # has local bending

        coupled_field = _idw_interpolate(3.0, 2.0, sup_x, sup_y, same_disp)
        δ_local = δ_coupled_interior .- coupled_field
        frame_field = _idw_interpolate(3.0, 2.0, sup_x, sup_y, same_disp)
        δ_draped = frame_field .+ δ_local

        # Should be identical to the original coupled displacement
        @test δ_draped ≈ δ_coupled_interior
    end
end

println("\n✅ All drape tests passed!")
