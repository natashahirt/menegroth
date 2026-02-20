using Test
using StructuralSizer
using Unitful

@testset "Fire Provisions" begin

    # =========================================================================
    # AggregateType enum
    # =========================================================================
    @testset "AggregateType" begin
        @test siliceous isa AggregateType
        @test carbonate isa AggregateType
        @test sand_lightweight isa AggregateType
        @test lightweight isa AggregateType
    end

    # =========================================================================
    # Concrete struct with aggregate_type
    # =========================================================================
    @testset "Concrete aggregate_type" begin
        c = NWC_4000
        @test c.aggregate_type == siliceous  # default

        # Custom with carbonate
        c2 = Concrete(c.E, c.fc′, c.ρ, c.ν, c.ecc; aggregate_type=carbonate)
        @test c2.aggregate_type == carbonate
    end

    # =========================================================================
    # ACI 216.1 — Minimum slab thickness (Table 4.2)
    # =========================================================================
    @testset "min_thickness_fire (ACI 216.1 Table 4.2)" begin
        # Siliceous, 2 hr → 5.0"
        @test min_thickness_fire(2.0, siliceous) ≈ 5.0u"inch"
        # Carbonate, 2 hr → 4.6"
        @test min_thickness_fire(2.0, carbonate) ≈ 4.6u"inch"
        # Lightweight, 1 hr → 2.5"
        @test min_thickness_fire(1.0, lightweight) ≈ 2.5u"inch"
        # Siliceous, 4 hr → 7.0"
        @test min_thickness_fire(4.0, siliceous) ≈ 7.0u"inch"
        # Zero rating → 0"
        @test min_thickness_fire(0.0, siliceous) ≈ 0.0u"inch"
        # Invalid rating
        @test_throws ArgumentError min_thickness_fire(2.5, siliceous)
    end

    # =========================================================================
    # ACI 216.1 — Minimum slab cover (Table 4.3.1.1)
    # =========================================================================
    @testset "min_cover_fire_slab (ACI 216.1 Table 4.3.1.1)" begin
        # Restrained: ¾" for all ratings
        @test min_cover_fire_slab(2.0, siliceous; restrained=true) ≈ 0.75u"inch"
        @test min_cover_fire_slab(4.0, siliceous; restrained=true) ≈ 0.75u"inch"
        # Unrestrained siliceous: 2 hr → 1.0", 4 hr → 1.625"
        @test min_cover_fire_slab(2.0, siliceous; restrained=false) ≈ 1.00u"inch"
        @test min_cover_fire_slab(4.0, siliceous; restrained=false) ≈ 1.625u"inch"
        # Zero → 0"
        @test min_cover_fire_slab(0.0, siliceous) ≈ 0.0u"inch"
    end

    # =========================================================================
    # ACI 216.1 — Minimum beam cover (Table 4.3.1.2)
    # =========================================================================
    @testset "min_cover_fire_beam (ACI 216.1 Table 4.3.1.2)" begin
        # Restrained, 10" beam, 2 hr → 0.75"
        @test min_cover_fire_beam(2.0, 10.0; restrained=true) ≈ 0.75u"inch"
        # Unrestrained, 7" beam, 3 hr → 1.75"
        @test min_cover_fire_beam(3.0, 7.0; restrained=false) ≈ 1.75u"inch"
        # Unrestrained, 5" beam, 3 hr → Inf (NP)
        @test isinf(ustrip(min_cover_fire_beam(3.0, 5.0; restrained=false)))
        # Zero → 0"
        @test min_cover_fire_beam(0.0, 10.0) ≈ 0.0u"inch"
        # Interpolation: 6" beam (between 5" and 7")
        c = min_cover_fire_beam(2.0, 6.0; restrained=true)
        @test c ≈ 0.75u"inch"  # both endpoints are 0.75"
    end

    # =========================================================================
    # ACI 216.1 — Minimum column dimension (Table 4.5.1a)
    # =========================================================================
    @testset "min_dimension_fire_column (ACI 216.1 Table 4.5.1a)" begin
        @test min_dimension_fire_column(1.0, siliceous) ≈ 8.0u"inch"
        @test min_dimension_fire_column(2.0, siliceous) ≈ 10.0u"inch"
        @test min_dimension_fire_column(4.0, carbonate) ≈ 12.0u"inch"
        @test min_dimension_fire_column(0.0, siliceous) ≈ 0.0u"inch"
    end

    # =========================================================================
    # ACI 216.1 — Minimum column cover (Section 4.5.3)
    # =========================================================================
    @testset "min_cover_fire_column (ACI 216.1 §4.5.3)" begin
        @test min_cover_fire_column(1.0) ≈ 1.0u"inch"
        @test min_cover_fire_column(2.0) ≈ 2.0u"inch"
        @test min_cover_fire_column(0.0) ≈ 0.0u"inch"
    end

    # =========================================================================
    # Fire Protection types
    # =========================================================================
    @testset "FireProtection types" begin
        @test NoFireProtection() isa FireProtection
        @test SFRM() isa FireProtection
        @test SFRM().density_pcf == 15.0
        @test IntumescentCoating() isa FireProtection
        @test IntumescentCoating().density_pcf == 6.0
        @test CustomCoating(0.5, 15.0, "Test") isa FireProtection
    end

    # =========================================================================
    # SFRM thickness (UL X772)
    # =========================================================================
    @testset "sfrm_thickness_x772" begin
        # W14x90: W=90 lb/ft, PA≈47", PB≈62.5"
        # As a column (4-sided): W/D = 90/62.5 = 1.44
        # 2 hr: h = 2 / (1.05*1.44 + 0.61) = 2 / 2.122 ≈ 0.943"
        h = sfrm_thickness_x772(2.0, 1.44)
        @test h ≈ 2.0 / (1.05 * 1.44 + 0.61) atol=0.001

        # Zero rating → 0
        @test sfrm_thickness_x772(0.0, 1.44) == 0.0

        # Very low W/D → thick SFRM
        h_heavy = sfrm_thickness_x772(2.0, 0.5)
        @test h_heavy > 1.5  # should be > 1.5" for low W/D

        # Minimum 0.25"
        h_high_wd = sfrm_thickness_x772(1.0, 6.0)
        @test h_high_wd >= 0.25
    end

    # =========================================================================
    # Intumescent thickness (UL N643)
    # =========================================================================
    @testset "intumescent_thickness_n643" begin
        # 1 hr unrestrained, any W/D ≥ 1.75 → 0.043"
        @test intumescent_thickness_n643(1.0, 2.0) ≈ 0.043 atol=0.001

        # 2 hr unrestrained, W/D = 1.0 → 0.196"
        @test intumescent_thickness_n643(2.0, 1.0; restrained=false) ≈ 0.196 atol=0.01

        # Zero → 0
        @test intumescent_thickness_n643(0.0, 1.0) == 0.0

        # Invalid for unrestrained 3 hr
        @test_throws ArgumentError intumescent_thickness_n643(3.0, 1.0; restrained=false)

        # Restrained 3 hr is valid
        @test intumescent_thickness_n643(3.0, 1.0; restrained=true) ≈ 0.139 atol=0.01
    end

    # =========================================================================
    # SurfaceCoating + weight
    # =========================================================================
    @testset "SurfaceCoating" begin
        c = SurfaceCoating(1.0, 15.0, "SFRM")
        @test c.thickness_in == 1.0
        @test c.density_pcf == 15.0

        # Weight per foot: 1" thickness × 60" perimeter = 60 in² → 60/144 ft² = 0.4167 ft²
        # × 15 pcf = 6.25 lb/ft
        w = coating_weight_per_foot(c, 60.0)
        @test w ≈ 6.25 atol=0.01
    end

    # =========================================================================
    # compute_surface_coating dispatch
    # =========================================================================
    @testset "compute_surface_coating" begin
        # NoFireProtection
        c = compute_surface_coating(NoFireProtection(), 2.0, 90.0, 60.0)
        @test c.thickness_in == 0.0

        # SFRM on a W14x90-like member (column, PB≈62.5")
        c = compute_surface_coating(SFRM(), 2.0, 90.0, 62.5)
        @test c.thickness_in > 0.5
        @test c.density_pcf == 15.0
        @test contains(c.name, "SFRM")

        # Custom
        c = compute_surface_coating(CustomCoating(0.75, 22.0, "High-Density"), 2.0, 90.0, 62.5)
        @test c.thickness_in == 0.75
        @test c.density_pcf == 22.0
    end

    # =========================================================================
    # ISymmSection PA/PB
    # =========================================================================
    @testset "ISymmSection PA/PB (no fillet)" begin
        # W14x90 geometry, no kdes_db → kdes defaults to tf (r=0, thin-wall)
        sec = ISymmSection(14.02u"inch", 14.520u"inch", 0.440u"inch", 0.710u"inch")
        
        # PB = 2d + 4bf - 2tw = 2(14.02) + 4(14.520) - 2(0.440) = 85.24"
        @test ustrip(u"inch", sec.PB) ≈ 85.24 atol=0.01
        # PA = PB - bf = 70.72"
        @test ustrip(u"inch", sec.PA) ≈ 70.72 atol=0.01
        @test sec.PB ≈ sec.PA + sec.bf
    end

    @testset "ISymmSection PA/PB (with fillet)" begin
        # W14x90: d=14.0", bf=14.5", tw=0.44", tf=0.71", kdes=1.31"
        # r = kdes - tf = 0.60"
        # Fillet correction = 4 * 0.60 * (π/2 - 2) ≈ −1.030"
        sec = ISymmSection(14.0u"inch", 14.5u"inch", 0.44u"inch", 0.71u"inch";
                           kdes_db=1.31u"inch")
        
        r = 1.31 - 0.71  # = 0.60"
        correction = 4 * r * (π/2 - 2)  # ≈ −1.030"
        PB_thin = 2*14.0 + 4*14.5 - 2*0.44  # = 85.12"
        PB_expected = PB_thin + correction    # ≈ 84.09"
        @test ustrip(u"inch", sec.PB) ≈ PB_expected atol=0.01
        @test ustrip(u"inch", sec.PA) ≈ (PB_expected - 14.5) atol=0.01
        @test sec.PB ≈ sec.PA + sec.bf
        
        # Compare to AISC: PA=69.6", PB=84.1" → expect <3%
        PA_ref, PB_ref = 69.6, 84.1
        @test abs(ustrip(u"inch", sec.PA) - PA_ref) / PA_ref * 100 < 3.0
        @test abs(ustrip(u"inch", sec.PB) - PB_ref) / PB_ref * 100 < 3.0
    end

end
