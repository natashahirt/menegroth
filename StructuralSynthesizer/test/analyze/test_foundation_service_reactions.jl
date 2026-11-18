# Service reactions include loads lumped onto fixed nodes.
# A wall shell's self-weight is a nodal AreaLoad, so the base row of the mesh
# receives a share of it directly at the supports. Asap's reaction is
# K u - P + Pf at fixed DOFs; the service solve must use the same, or that
# share is lost from Ps.

using Test
using Unitful
using Asap

using StructuralSynthesizer

@testset "Service reactions on a fixed-base wall" begin
    # 2 m × 3 m wall in the XZ plane, 3 × 4 node grid, base row fixed.
    width, height = 2.0, 3.0
    nx, nz = 3, 4
    t = 0.3
    ρ = 2400.0
    grid = [Asap.Node([width * (i - 1) / (nx - 1) * u"m", 0.0u"m",
                       height * (k - 1) / (nz - 1) * u"m"],
                      k == 1 ? :fixed : :free)
            for i in 1:nx, k in 1:nz]
    shells = Asap.ShellTri3[]
    for i in 1:(nx - 1), k in 1:(nz - 1)
        a, b, c, d = grid[i, k], grid[i + 1, k], grid[i + 1, k + 1], grid[i, k + 1]
        push!(shells, Asap.ShellTri3((a, b, c), t * u"m", 30e9u"Pa", 0.2; id = :wall, ρ = ρ))
        push!(shells, Asap.ShellTri3((a, c, d), t * u"m", 30e9u"Pa", 0.2; id = :wall, ρ = ρ))
    end
    model = Asap.Model(vec(grid), Asap.Element{Asap.FixedFixed}[], shells,
                       Asap.AbstractLoad[])
    Asap.process!(model)
    struc = BuildingStructure(BuildingSkeleton{Float64}())
    struc.asap_model = model

    g = ustrip(u"m/s^2", Asap.GRAVITY)
    W = ρ * t * g * width * height

    loads = StructuralSynthesizer._unfactored_DL_loads(struc)
    # The case under test: part of the load is applied at fixed DOFs.
    F = Asap.create_F(model, Vector{Asap.AbstractLoad}(loads))
    z_fixed = [nd.globalID[3] for nd in grid[:, 1]]
    @test sum(F[z_fixed]) < -1e-6 * W

    R = StructuralSynthesizer._service_reactions(struc)
    z_all = [nd.globalID[3] for nd in grid]
    @test sum(R[z_fixed]) ≈ W rtol = 1e-9
    @test all(iszero, R[setdiff(z_all, z_fixed)])
    # Horizontal reactions balance: no lateral load.
    @test abs(sum(R[[nd.globalID[1] for nd in grid[:, 1]]])) <= 1e-9 * W
end
