# =============================================================================
# Phase 2 Feature Tests
# Tests for: fireproofing EC, collinear grouping, binary search sizing
#
# Run from repo root:
#   julia scripts/runners/run_phase2_tests.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using Test, Unitful
using StructuralSizer
using Asap

println("═"^60)
println("  Phase 2 Feature Tests")
println("═"^60)

@testset "Phase 2 Features" begin

    # =========================================================================
    # 1. Fireproofing EC
    # =========================================================================
    @testset "Fireproofing EC" begin

        @testset "exposed_perimeter — ISymmSection" begin
            sec = W("W14X22")
            PA = exposed_perimeter(sec; exposure=:three_sided)
            PB = exposed_perimeter(sec; exposure=:four_sided)

            @test PA isa Unitful.Length
            @test PB isa Unitful.Length
            @test ustrip(u"m", PB) > ustrip(u"m", PA)
            # PB ≈ PA + bf (one flange width)
            bf_m = ustrip(u"m", sec.bf)
            diff = ustrip(u"m", PB) - ustrip(u"m", PA)
            @test isapprox(diff, bf_m; rtol=0.02)
        end

        @testset "coating_volume / coating_mass / coating_ec" begin
            sec = W("W14X22")
            coating = SurfaceCoating(1.0, 15.0, "SFRM (15 pcf)")
            L = 6.0u"m"

            vol = coating_volume(sec, coating, L; exposure=:three_sided)
            @test vol isa Unitful.Volume
            @test ustrip(u"m^3", vol) > 0

            mass = coating_mass(sec, coating, L; exposure=:three_sided)
            @test ustrip(u"kg", mass) > 0

            ec = coating_ec(sec, coating, L; exposure=:three_sided, ecc=ECC_SFRM)
            @test ec > 0
            # EC = mass_kg * ecc
            @test isapprox(ec, ustrip(u"kg", mass) * ECC_SFRM; rtol=1e-6)
        end

        @testset "zero thickness → zero EC" begin
            sec = W("W14X22")
            coating = SurfaceCoating(0.0, 15.0, "None")
            L = 6.0u"m"

            @test ustrip(u"m^3", coating_volume(sec, coating, L)) == 0.0
            @test coating_ec(sec, coating, L) == 0.0
        end

        @testset "compute_surface_coating → coating_ec round-trip" begin
            sec = W("W14X22")
            fp = SFRM(15.0)
            W_plf = ustrip(u"lb/ft", weight_per_length(sec, A992_Steel))
            P_in = ustrip(u"inch", sec.PA)
            
            coating = compute_surface_coating(fp, 2.0, W_plf, P_in)
            @test coating.thickness_in > 0.25

            ec = coating_ec(sec, coating, 6.0u"m"; exposure=:three_sided)
            @test ec > 0
        end
    end

    # =========================================================================
    # 2. Binary Search Sizing
    # =========================================================================
    @testset "Binary Search Sizing" begin

        @testset "single group — matches MIP result" begin
            catalog = preferred_W()
            material = A992_Steel
            checker = AISCChecker(; deflection_limit=1/360)

            demand = MemberDemand(1; Mux=200e3, Vu_strong=50e3, δ_max=0.005, I_ref=1e-4)
            geometry = SteelMemberGeometry(6.0; Lb=6.0)

            mip = optimize_discrete(checker, [demand], [geometry], catalog, material)
            bs  = optimize_binary_search(checker, [demand], [geometry], catalog, material)

            # Both should select the same section (lightest feasible)
            @test bs.sections[1].name == mip.sections[1].name
        end

        @testset "multiple groups — all feasible" begin
            catalog = all_W()
            material = A992_Steel
            checker = AISCChecker()

            demands = [
                MemberDemand(1; Mux=100e3),
                MemberDemand(2; Mux=300e3),
                MemberDemand(3; Mux=500e3),
            ]
            geometries = [
                SteelMemberGeometry(5.0; Lb=5.0),
                SteelMemberGeometry(8.0; Lb=8.0),
                SteelMemberGeometry(10.0; Lb=10.0),
            ]

            result = optimize_binary_search(checker, demands, geometries, catalog, material)
            @test length(result.sections) == 3
            @test all(!isnothing, result.sections)
            @test result.status == :OPTIMAL
        end

        @testset "infeasible demand throws" begin
            catalog = preferred_W()
            material = A992_Steel
            checker = AISCChecker()

            # Absurdly large demand
            demand = MemberDemand(1; Mux=1e12)
            geometry = SteelMemberGeometry(6.0; Lb=6.0)

            @test_throws ArgumentError optimize_binary_search(
                checker, [demand], [geometry], catalog, material)
        end

        @testset "heavier groups get heavier sections" begin
            catalog = all_W()
            material = A992_Steel
            checker = AISCChecker()

            d_light = MemberDemand(1; Mux=50e3)
            d_heavy = MemberDemand(2; Mux=800e3)
            g = SteelMemberGeometry(8.0; Lb=8.0)

            r = optimize_binary_search(checker, [d_light, d_heavy], [g, g], catalog, material)

            w_light = ustrip(u"kg/m", weight_per_length(r.sections[1], A992_Steel))
            w_heavy = ustrip(u"kg/m", weight_per_length(r.sections[2], A992_Steel))
            @test w_heavy > w_light
        end

        @testset "shared cache between MIP and binary search" begin
            catalog = preferred_W()
            material = A992_Steel
            checker = AISCChecker(; deflection_limit=1/240)

            n = length(catalog)
            cache = create_cache(checker, n)
            precompute_capacities!(checker, cache, catalog, material, MinVolume())

            demand = MemberDemand(1; Mux=150e3, δ_max=0.004, I_ref=8e-5)
            geometry = SteelMemberGeometry(7.0; Lb=3.5)

            r_mip = optimize_discrete(checker, [demand], [geometry], catalog, material; cache=cache)
            r_bs  = optimize_binary_search(checker, [demand], [geometry], catalog, material; cache=cache)

            @test r_bs.sections[1].name == r_mip.sections[1].name
        end
    end

    # =========================================================================
    # 3. Integration: DesignParameters.collinear_grouping
    # =========================================================================
    @testset "DesignParameters — collinear_grouping field" begin
        using StructuralSynthesizer

        @testset "default is false" begin
            p = DesignParameters()
            @test p.collinear_grouping === false
        end

        @testset "can set to true" begin
            p = DesignParameters(collinear_grouping=true)
            @test p.collinear_grouping === true
        end
    end

    # =========================================================================
    # 4. Integration: auto solver selection (binary search vs MIP)
    # =========================================================================
    @testset "Auto solver selection" begin

        @testset "binary search gives same result as MIP for n_max_sections=0" begin
            catalog = preferred_W()
            material = A992_Steel
            checker = AISCChecker(; deflection_limit=1/360)

            demands = [
                MemberDemand(1; Mux=120e3, Vu_strong=30e3, δ_max=0.003, I_ref=5e-5),
                MemberDemand(2; Mux=250e3, Vu_strong=60e3, δ_max=0.006, I_ref=1e-4),
            ]
            geometries = [
                SteelMemberGeometry(6.0; Lb=3.0),
                SteelMemberGeometry(9.0; Lb=4.5),
            ]

            r_mip = optimize_discrete(checker, demands, geometries, catalog, material;
                                       n_max_sections=0)
            r_bs  = optimize_binary_search(checker, demands, geometries, catalog, material)

            @test r_bs.sections[1].name == r_mip.sections[1].name
            @test r_bs.sections[2].name == r_mip.sections[2].name
        end
    end

    # =========================================================================
    # 5. DesignParameters.uniform_column_sizing field
    # =========================================================================
    @testset "DesignParameters — uniform_column_sizing field" begin
        using StructuralSynthesizer

        @testset "default is :off" begin
            p = DesignParameters()
            @test p.uniform_column_sizing === :off
        end

        @testset "can set to :per_story" begin
            p = DesignParameters(uniform_column_sizing=:per_story)
            @test p.uniform_column_sizing === :per_story
        end

        @testset "can set to :building" begin
            p = DesignParameters(uniform_column_sizing=:building)
            @test p.uniform_column_sizing === :building
        end
    end

end

println("\n✓ All Phase 2 tests passed!")
