using StructuralSizer
using Unitful
using Test

# A straight wall under a uniform line load. Hand values:
#   L = 20 ft, Ps = 200 kip, qa = 2 ksf → B = Ps / (qa L) = 5 ft
#   wall centered, so the face moment is qu (B − tw)^2 / 8 per unit length
#   (ACI 318-11 §15.4.1, §15.4.2(a); corpus: aci-318-11, page 272).

function _uniform_wall(; hw = 10.0u"ft", Ps_kip = 40.0, n = 5, L = 20.0u"ft", tw = 8.0u"inch")
    samples = WallLineSample[]
    for i in 0:(n - 1)
        s = L * i / (n - 1)
        push!(samples, WallLineSample(s, 1.4 * Ps_kip * u"kip", Ps_kip * u"kip"))
    end
    WallLineDemand(1, (0.0u"ft", 0.0u"ft"), (L, 0.0u"ft"), tw, hw, samples)
end

soil = Soil(2.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
            ks = 25_000.0u"kN/m^3")

@testset "Projection moment and shear at the wall face" begin
    qu = 2.8u"ksf"
    B = 5.0u"ft"
    tw = 8.0u"inch"
    d = 10.0u"inch"
    Mu = StructuralSizer._wall_projection_moment(qu, B, tw)
    @test Mu ≈ qu * (B - tw)^2 / 8
    Vu = StructuralSizer._wall_projection_shear(qu, B, tw, d)
    @test Vu ≈ qu * ((B - tw) / 2 - d)
    @test StructuralSizer._wall_projection_shear(qu, B, tw, 3.0u"ft") == 0.0u"ksf" * 0.0u"ft"
end

@testset "Uniform wall sizes to Ps / (qa L) and does not punch" begin
    leg = _uniform_wall()
    r = design_footing(StripFooting(), leg, soil)
    @test r isa StripFootingResult
    @test r.n_columns == 0
    @test r.analysis == :rigid
    @test ustrip(u"ft", r.L_ftg) ≈ 20 atol = 0.05
    @test ustrip(u"ft", r.B) ≈ 5 atol = 0.05
    @test r.utilization <= 1.0
    @test r.concrete_volume ≈ r.B * r.L_ftg * r.D
    # §15.8.2.2 dowels are in the steel even though nothing is in tension.
    @test r.As_tensile == 0.0u"m^2"
    @test r.steel_volume > 0.0u"m^3"
end

@testset "A heavier end lengthens the light side" begin
    # Resultant at 7.5 ft of a 10 ft wall. Covering the wall with the
    # centroid on the resultant takes Lf = 2 × 7.5 = 15 ft.
    samples = [
        WallLineSample(0.0u"ft", 14.0u"kip", 10.0u"kip"),
        WallLineSample(10.0u"ft", 42.0u"kip", 30.0u"kip"),
    ]
    leg = WallLineDemand(1, (0.0u"ft", 0.0u"ft"), (10.0u"ft", 0.0u"ft"),
                         8.0u"inch", 10.0u"ft", samples)
    r = design_footing(StripFooting(), leg, soil)
    @test r.analysis == :rigid
    @test ustrip(u"ft", r.L_ftg) ≈ 15 atol = 0.05
    # B = ceil(40 kip / (2 ksf × 15 ft)) to a 3 in. step, and at least 8 in.
    @test ustrip(u"inch", r.B) ≈ 18 atol = 0.1
    @test r.utilization <= 1.0
end

@testset "An L is one footing and the corner is not split" begin
    function leg(idx, p1, p2, stations, Ps)
        samples = [WallLineSample(s, 1.4 * Ps, Ps) for s in stations]
        WallLineDemand(idx, p1, p2, 0.2u"m", 3.0u"m", samples)
    end
    long = leg(1, (0.0u"m", 0.0u"m"), (6.0u"m", 0.0u"m"),
               (0.0u"m", 3.0u"m", 6.0u"m"), 50.0u"kN")
    # The corner reaction stays on the long leg. The short leg starts at 1 m.
    short = leg(2, (0.0u"m", 0.0u"m"), (0.0u"m", 4.0u"m"),
                (1.0u"m", 4.0u"m"), 40.0u"kN")
    r = design_footing(StripFooting(), [long, short], soil)
    @test r.n_columns == 0
    @test r.analysis == :rigid
    area = r.concrete_volume / r.D
    @test area < r.B * 10.0u"m"
    @test area > r.B * 6.0u"m"
    @test r.utilization <= 1.0

    both = leg(2, (0.0u"m", 0.0u"m"), (0.0u"m", 4.0u"m"),
               (0.0u"m", 4.0u"m"), 40.0u"kN")
    @test_throws ArgumentError design_footing(StripFooting(), [long, both], soil)
end

@testset "A closed cell is refused" begin
    function side(idx, p1, p2)
        samples = [WallLineSample(0.0u"m", 20.0u"kN", 14.0u"kN"),
                   WallLineSample(4.0u"m", 20.0u"kN", 14.0u"kN")]
        WallLineDemand(idx, p1, p2, 0.2u"m", 3.0u"m", samples)
    end
    box = [
        side(1, (0.0u"m", 0.0u"m"), (4.0u"m", 0.0u"m")),
        side(2, (4.0u"m", 0.0u"m"), (4.0u"m", 4.0u"m")),
        side(3, (4.0u"m", 4.0u"m"), (0.0u"m", 4.0u"m")),
        side(4, (0.0u"m", 4.0u"m"), (0.0u"m", 0.0u"m")),
    ]
    @test_throws ArgumentError design_footing(StripFooting(), box, soil)
end

@testset "Below Kr = 0.5 a straight wall switches to the beam on soil" begin
    # No wall height, stiff soil, so Eq. (5-1) is under 0.5 at the minimum
    # thickness. ks is present, so the fallback can run.
    leg = _uniform_wall(; hw = 0.0u"ft", Ps_kip = 20.0)
    stiff = Soil(2.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 2.0u"GPa";
                 ks = 50_000.0u"kN/m^3")
    refused = StripParams(on_inapplicable = :error)
    @test_throws ArgumentError design_footing(StripFooting(), leg, stiff; opts = refused)
    r = design_footing(StripFooting(), leg, stiff)
    @test r.analysis == :winkler
    @test r.n_columns == 0
    @test r.utilization <= 1.0
end

@testset "Minimum dowels use the concrete at the base" begin
    # ACI 318-11 §14.3.2 (corpus: aci-318-11, page 264): 0.0012 for No. 5 at
    # fy ≥ 60 ksi, 0.0015 otherwise. §15.8.2.2 (page 275) applies it at the joint.
    full = _uniform_wall()
    @test ustrip(u"ft", full.solid) ≈ 20 atol = 1e-6
    cut = WallLineDemand(1, (0.0u"ft", 0.0u"ft"), (20.0u"ft", 0.0u"ft"),
        8.0u"inch", 10.0u"ft", full.samples; solid_length = 10.0u"ft")
    fy = 60.0u"ksi"
    As5 = StructuralSizer._wall_min_dowel([full], 5, fy)
    As6 = StructuralSizer._wall_min_dowel([full], 6, fy)
    @test As5 ≈ 0.0012 * full.tw * full.solid
    @test As6 ≈ 0.0015 * full.tw * full.solid
    @test StructuralSizer._wall_min_dowel([cut], 6, fy) ≈ As6 / 2
end

@testset "Footing tension development is Eq. (12-1)" begin
    # No. 8, f'c = 4 ksi, fy = 60 ksi, 3 in cover, spacing wide enough that
    # cb is the cover to the bar center. (cb+Ktr)/db caps at 2.5.
    # ld/db = (3/40)·60000 / (√4000·2.5) ≈ 28.46. ACI 318-11 Eq. (12-1)
    # (corpus: aci-318-11, page 214). §12.2.5 is not applied.
    fc = 4000.0u"psi"
    fy = 60.0u"ksi"
    db = StructuralSizer.bar_diameter(8)
    ld = StructuralSizer._development_length_footing(8, fc, fy, 1.0, db;
                                                      clear_cover = 3.0u"inch",
                                                      spacing = 12.0u"inch")
    expect = (3 / 40) * 60_000 / (sqrt(4000) * 2.5)
    @test ustrip(u"inch", ld) ≈ expect rtol = 1e-6
    # No. 6 takes ψs = 0.8 (§12.2.4(c), page 216): about 17 in at the same cap.
    db6 = StructuralSizer.bar_diameter(6)
    ld6 = StructuralSizer._development_length_footing(6, fc, fy, 1.0, db6;
                                                       clear_cover = 3.0u"inch",
                                                       spacing = 12.0u"inch")
    @test ustrip(u"inch", ld6) ≈ 0.8 * expect * ustrip(u"inch", db6) rtol = 1e-6
    # §12.5.2 with §12.5.3(a): side cover 3 in and 2 in beyond the tail.
    ldh = StructuralSizer._hooked_development_length(8, fc, fy, 1.0, db;
                                                      side_cover = 3.0u"inch",
                                                      tail_cover = 2.0u"inch")
    @test ustrip(u"inch", ldh) ≈ 0.7 * 0.02 * 60_000 / sqrt(4000) rtol = 1e-6
end
