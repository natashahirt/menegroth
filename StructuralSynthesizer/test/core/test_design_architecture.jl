# Test the new design architecture
using StructuralSynthesizer
using StructuralSizer  # For Concrete, StructuralSteel types
using StructuralSizer: ksi  # Units from Asap via StructuralSizer
using Test
using Unitful

println("Testing design architecture types...")

@testset "Design Architecture" begin
    @testset "TributaryCache" begin
        cache = TributaryCache()
        @test isempty(cache.edge)
        @test isempty(cache.vertex)
        
        # Test cache key creation
        key1 = TributaryCacheKey(:one_way, UInt64(0))
        key2 = TributaryCacheKey(:one_way, UInt64(0))
        @test key1 == key2
        @test hash(key1) == hash(key2)
        
        key3 = TributaryCacheKey(:two_way, UInt64(0))
        @test key1 != key3
        
        # Test has_edge_tributaries
        @test !has_edge_tributaries(cache, key1)
    end
    
    @testset "DesignParameters" begin
        params = DesignParameters()
        @test params.name == "default"
        @test params.materials.concrete === nothing  # No default concrete override
        
        # Custom params with concrete from StructuralSizer
        concrete = StructuralSizer.Concrete(
            57000 * sqrt(4000) * u"psi",  # E
            4000.0u"psi",                  # fc'
            150.0u"lbf/ft^3",              # ρ
            0.2,                           # ν
            0.12                           # ecc
        )
        params2 = DesignParameters(
            name = "4ksi Concrete",
            materials = MaterialOptions(concrete = concrete),
        )
        @test params2.name == "4ksi Concrete"
        @test params2.materials.concrete.fc′ == 4000.0u"psi"
    end

    @testset "Resolved design context owns effective inputs" begin
        params = DesignParameters(
            name="owned",
            framing_opts=(; spacing=2.0u"m"),
        )
        context = resolve_design_context(params)
        expected_hash = context.content_hash

        params.name = "mutated by caller"
        params.framing_opts = (; spacing=3.0u"m")

        @test context.params.name == "owned"
        @test context.framing_opts.spacing == 2.0u"m"
        @test context.content_hash == expected_hash
    end
    
    @testset "BuildingDesign" begin
        # BuildingDesign requires a BuildingStructure
        skel = gen_medium_office(10.0u"m", 10.0u"m", 3.0u"m", 1, 1, 1)
        struc = BuildingStructure(skel)
        
        params = DesignParameters(name = "Test Design")
        design = BuildingDesign(struc, params)
        
        @test design.params.name == "Test Design"
        @test isempty(design.slabs)
        @test isempty(design.columns)
        @test all_ok(design)  # No failures yet
        @test critical_ratio(design) == 0.0
    end

    @testset "Captured designs own finalized state" begin
        skel = gen_medium_office(10.0u"m", 10.0u"m", 3.0u"m", 1, 1, 1)
        struc = BuildingStructure(skel)
        params = DesignParameters(name="captured")

        design = capture_design(struc, params)
        params.name = "later mutation"

        @test design.finalized
        @test design.structure !== struc
        @test design.params !== params
        @test design.params.name == "captured"
        @test !isempty(design.context_hash)
        @test_throws ArgumentError size!(design)
    end

    @testset "DesignSummary critical element prefers failing slabs over high-ratio passing foundations" begin
        skel = gen_medium_office(10.0u"m", 10.0u"m", 3.0u"m", 1, 1, 1)
        struc = BuildingStructure(skel)
        params = DesignParameters()
        design = BuildingDesign(struc, params)
        design.slabs[1] = SlabDesignResult(;
            thickness = 0.2u"m",
            self_weight = 1.0u"kPa",
            converged = true,
            deflection_ok = true,
            deflection_ratio = 0.1,
            punching_ok = false,
            punching_max_ratio = 1.5,
        )
        design.foundations[1] = FoundationDesignResult(;
            ok = true,
            bearing_ratio = 0.3,
            punching_ratio = 2.21,
            flexure_ratio = 0.2,
        )
        StructuralSynthesizer._compute_design_summary!(design, struc, params)
        @test !design.summary.all_checks_pass
        @test occursin("Slab", design.summary.critical_element)
        @test occursin("punching", design.summary.critical_element)
        @test design.summary.critical_ratio ≈ 1.5
    end

    @testset "slab_diagnostic_governing_check maps section_inadequate to reinforcement_design" begin
        sr = SlabDesignResult(;
            thickness = 0.2u"m",
            self_weight = 1.0u"kPa",
            converged = false,
            failure_reason = "section_inadequate",
            failing_check = "reinforcement_design",
            deflection_ok = true,
            punching_ok = true,
            deflection_ratio = 0.2,
            punching_max_ratio = 0.3,
        )
        @test StructuralSynthesizer.slab_diagnostic_governing_check(sr) == "reinforcement_design"
    end

    @testset "an unmeasured slab deflection is not a passing check" begin
        sr = SlabDesignResult(;
            thickness = 0.2u"m",
            self_weight = 1.0u"kPa",
            converged = true,
            punching_ok = true,
            punching_max_ratio = 0.4,
        )
        @test !StructuralSynthesizer.slab_deflection_measured(sr)
        @test StructuralSynthesizer.slab_diagnostic_governing_check(sr) == "punching_shear_slab"
        blank = SlabDesignResult(;
            thickness = 0.2u"m",
            self_weight = 1.0u"kPa",
            converged = true,
        )
        @test StructuralSynthesizer.slab_diagnostic_governing_check(blank) == ""
    end

    @testset "column_diagnostic_governing_check picks failing limit state, not max passing ratio" begin
        pc = PunchingDesignResult(;
            Vu = 100.0u"kN",
            φVc = 100.0u"kN",
            ratio = 1.3,
            ok = false,
            critical_perimeter = 4.0u"m",
            tributary_area = 25.0u"m^2",
        )
        col = ColumnDesignResult(;
            ok = false,
            axial_ratio = 0.2,
            interaction_ratio = 0.4,
            punching = pc,
        )
        @test StructuralSynthesizer.column_diagnostic_governing_check(col) == "punching_shear_col"
    end

    @testset "beam_diagnostic_governing_check picks shear when only shear exceeds 1" begin
        br = BeamDesignResult(;
            ok = false,
            flexure_ratio = 0.5,
            shear_ratio = 1.15,
            Mu = 0.0u"kN*m",
            Vu = 0.0u"kN",
        )
        @test StructuralSynthesizer.beam_diagnostic_governing_check(br) == "shear"
    end

    @testset "beam summary reports the sizer's governing check" begin
        br = BeamDesignResult(; ok = true, flexure_ratio = 0.4, shear_ratio = 0.3,
                              governing_check = "deflection_ll", governing_ratio = 0.93)
        @test StructuralSynthesizer.beam_diagnostic_governing_check(br) == "deflection_ll"

        skel = gen_medium_office(10.0u"m", 10.0u"m", 3.0u"m", 1, 1, 1)
        struc = BuildingStructure(skel)
        params = DesignParameters()
        design = BuildingDesign(struc, params)
        design.beams[1] = br
        StructuralSynthesizer._compute_design_summary!(design, struc, params)
        @test design.summary.critical_ratio ≈ 0.93
        @test occursin("deflection_ll", design.summary.critical_element)

        expl = StructuralSizer.FeasibilityExplanation(true, [
            StructuralSizer.CheckResult("shear_strong", true, 0.2, 0.0, 0.0, ""),
            StructuralSizer.CheckResult("shear_anchors", true, 0.9, 0.0, 0.0, ""),
            StructuralSizer.CheckResult("flexure_pos", true, 0.6, 0.0, 0.0, ""),
            StructuralSizer.CheckResult("pm_interaction_compression", true, 0.7, 0.0, 0.0, ""),
        ], "shear_anchors", 0.9)
        r = StructuralSynthesizer._apply_beam_check!(BeamDesignResult(), expl)
        @test r.governing_check == "shear_anchors" && r.governing_ratio == 0.9
        @test r.flexure_ratio == 0.7
        @test r.shear_ratio == 0.2
    end

    @testset "foundation_diagnostic_governing_check picks failing check over high passing bearing" begin
        fr = FoundationDesignResult(;
            ok = false,
            bearing_ratio = 0.55,
            punching_ratio = 1.4,
            flexure_ratio = 0.2,
        )
        @test StructuralSynthesizer.foundation_diagnostic_governing_check(fr) == "punching_shear_fdn"

        wall = FoundationDesignResult(; ok = false, bearing_ratio = 0.8,
                                      one_way_shear_ratio = 1.1, governing_ratio = 1.1)
        @test StructuralSynthesizer.foundation_diagnostic_governing_check(wall) == "one_way_shear_fdn"

        # A failing utilization that no reported check explains is not
        # attributed to the largest passing one.
        unexplained = FoundationDesignResult(; ok = false, bearing_ratio = 0.6,
                                             governing_ratio = 1.2)
        @test StructuralSynthesizer.foundation_diagnostic_governing_check(unexplained) == "utilization"
    end

    @testset "foundation results carry per-check utilizations" begin
        old = StructuralSizer.SpreadFootingResult{typeof(1.0u"m"), typeof(1.0u"m^3"), typeof(1.0u"kN")}(
            1.0u"m", 1.0u"m", 0.5u"m", 0.4u"m", 0.001u"m", 4, 0.016u"m",
            0.5u"m^3", 0.01u"m^3", 0.7)
        @test isnan(StructuralSizer.utilization_checks(old).punching)
        demand = StructuralSizer.FoundationDemand(1; Pu = 800.0u"kN", Ps = 560.0u"kN")
        r = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), demand,
                                           StructuralSizer.medium_sand)
        chk = StructuralSizer.utilization_checks(r)
        @test StructuralSizer.utilization(r) ≈ max(chk.bearing, chk.punching)
    end
    
    @testset "Existing Material Types (StructuralSizer)" begin
        # Test that we can use existing material types
        concrete = StructuralSizer.Concrete(
            3605.0u"ksi",      # E
            4.0u"ksi",         # fc' (use same units for comparison)
            150.0u"lbf/ft^3",  # ρ
            0.2,               # ν
            0.12               # ecc
        )
        @test concrete.fc′ == 4.0u"ksi"
        
        steel = StructuralSizer.StructuralSteel(
            29000.0u"ksi",     # E
            11200.0u"ksi",     # G
            50.0u"ksi",        # Fy
            65.0u"ksi",        # Fu
            490.0u"lbf/ft^3",  # ρ
            0.3,               # ν
            1.37               # ecc
        )
        @test steel.Fy == 50.0u"ksi"
    end
end

println("All design architecture tests passed!")
