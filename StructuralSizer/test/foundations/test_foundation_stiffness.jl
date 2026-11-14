# ACI 336.2R §5.2 Eq. (5-1) and §5.3 Eq. (5-3).
# corpus: aci-336-combined-footings-mats, PDF pages 8–9.

using StructuralSizer
using Test
using Unitful

const SS = StructuralSizer

@testset "Eq. 5-1 relative stiffness" begin
    # I_F = h^3/12 = 0.018 m^3. B^3 = 64 m^3.
    # Kr = 30e9 * 0.018 / (20e6 * 64) = 0.421875.
    E = 30.0e9u"Pa"
    Es = 20.0e6u"Pa"
    B = 4.0u"m"
    h = 0.6u"m"
    Kr = SS.wall_footing_kr(E, Es, B, h, SS.WallLineDemand[])
    @test Kr ≈ 0.421875 rtol = 1e-9

    # One wall: t_w h_w^3/12 = 4/3 m^4, divided by B = 4 m.
    # I_B = 0.018 + 1/3. Kr = 8.234375.
    leg = SS.WallLineDemand(1,
        (0.0u"m", 0.0u"m"), (4.0u"m", 0.0u"m"),
        0.25u"m", 4.0u"m",
        [SS.WallLineSample(0.0u"m", 1.0u"N", 1.0u"N")])
    Kr_w = SS.wall_footing_kr(E, Es, B, h, [leg])
    @test Kr_w ≈ 8.234375 rtol = 1e-9
    @test Kr_w > Kr

    # Σ I_b = 0.4 m^4, divided by B = 4 m, adds 0.1 to I_B.
    # I_B = 0.018 + 0.1. Kr = 30e9 * 0.118 / (20e6 * 64) = 2.765625.
    Kr_f = SS.wall_footing_kr(E, Es, B, h, SS.WallLineDemand[];
                              framed_I = 0.4u"m^4")
    @test Kr_f ≈ 2.765625 rtol = 1e-9
    @test Kr_f > Kr
end

@testset "Eq. 5-3 characteristic" begin
    # K_s = k_s B and I = B h^3/12, so B cancels.
    # λ = (1e7 / (4 * 25e9 * 0.5^3/12))^(1/4) = 0.313017 / m.
    ks = 10000.0u"kN/m^3"
    Ec = 25.0e9u"Pa"
    h = 0.5u"m"
    λ4 = SS.footing_lambda(ks, Ec, 4.0u"m", h)
    λ8 = SS.footing_lambda(ks, Ec, 8.0u"m", h)
    @test ustrip(u"m^-1", λ4) ≈ 0.313016916015 rtol = 1e-9
    @test ustrip(u"m^-1", λ4) ≈ ustrip(u"m^-1", λ8) rtol = 1e-9
end

@testset "a wide mat with no walls is not rigid" begin
    demands = [
        FoundationDemand(1; Pu = 200.0kip, Ps = 140.0kip),
        FoundationDemand(2; Pu = 200.0kip, Ps = 140.0kip),
    ]
    positions = [(0.0u"ft", 0.0u"ft"), (20.0u"ft", 0.0u"ft")]
    soil = Soil(3.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
                ks = 25000.0u"kN/m^3")
    opts = MatParams(; min_depth = 18.0u"inch", on_inapplicable = :error)
    err = try
        design_footing(MatFoundation(), demands, positions, soil; opts = opts)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("Eq. 5-1", sprint(showerror, err))
end
