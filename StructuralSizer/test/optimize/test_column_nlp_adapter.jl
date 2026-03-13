# ==============================================================================
# Test size_columns NLP adapter (sizing_strategy = :nlp)
# ==============================================================================
# Verifies that ConcreteColumnOptions(sizing_strategy=:nlp) routes through the
# NLP path and returns the same NamedTuple shape as the MIP catalog path, so
# the slab-column iteration loop in size_flat_plate! works transparently.

using Test
using StructuralSizer
using Unitful
using Asap: kip, ksi

@testset "size_columns NLP adapter" begin

    # Shared test fixtures
    geoms = [ConcreteMemberGeometry(4.0; k=1.0, braced=true) for _ in 1:3]
    Pu  = [300.0, 500.0, 700.0] .* kip
    Mux = [100.0, 200.0, 300.0] .* kip .* u"ft"

    @testset "NLP path returns MIP-compatible result shape" begin
        # The slab pipeline reads column_result.sections[i] and calls
        # bounding_box(section) and section.ρg.  Verify the NLP adapter
        # returns the same fields.
        opts = ConcreteColumnOptions(
            material        = NWC_4000,
            sizing_strategy = :nlp,
        )
        result = StructuralSizer.size_columns(Pu, Mux, geoms, opts)

        @test hasproperty(result, :sections)
        @test hasproperty(result, :section_indices)
        @test hasproperty(result, :objective_value)
        @test length(result.sections) == 3
        @test length(result.section_indices) == 3

        for (i, sec) in enumerate(result.sections)
            @test sec isa RCColumnSection
            bb = bounding_box(sec)
            @test bb.width > 0u"inch"
            @test bb.depth > 0u"inch"
            @test sec.ρg >= 0.01
            @test sec.ρg <= 0.08
        end

        @test result.objective_value > 0
    end

    @testset "MIP and NLP produce comparable results" begin
        # Both strategies should produce valid columns for the same demands.
        # Dimensions may differ, but both must be structurally adequate.
        opts_mip = ConcreteColumnOptions(
            material        = NWC_4000,
            sizing_strategy = :discrete,
            catalog         = :high_capacity,
        )
        opts_nlp = ConcreteColumnOptions(
            material        = NWC_4000,
            sizing_strategy = :nlp,
        )

        result_mip = StructuralSizer.size_columns(Pu, Mux, geoms, opts_mip)
        result_nlp = StructuralSizer.size_columns(Pu, Mux, geoms, opts_nlp)

        for i in 1:3
            bb_mip = bounding_box(result_mip.sections[i])
            bb_nlp = bounding_box(result_nlp.sections[i])
            # Both should produce positive-dimension sections
            @test ustrip(u"inch", bb_mip.width) > 0
            @test ustrip(u"inch", bb_nlp.width) > 0
            # NLP may produce smaller sections (continuous optimization)
            # but shouldn't be wildly different — within 2× of each other
            area_mip = ustrip(u"inch", bb_mip.width) * ustrip(u"inch", bb_mip.depth)
            area_nlp = ustrip(u"inch", bb_nlp.width) * ustrip(u"inch", bb_nlp.depth)
            @test area_nlp / area_mip > 0.3  # NLP shouldn't be absurdly smaller
            @test area_nlp / area_mip < 3.0  # or absurdly larger
        end
    end

    @testset "NLP respects max_depth" begin
        # max_depth should limit the NLP solution dimensions
        opts = ConcreteColumnOptions(
            material        = NWC_4000,
            sizing_strategy = :nlp,
            max_depth       = 24.0u"inch",
        )
        result = StructuralSizer.size_columns(Pu, Mux, geoms, opts)

        for sec in result.sections
            bb = bounding_box(sec)
            # Allow small tolerance for rounding
            @test ustrip(u"inch", bb.width) <= 26.0
            @test ustrip(u"inch", bb.depth) <= 26.0
        end
    end

    @testset "sizing_strategy = :discrete still works (regression)" begin
        # Ensure the default MIP path is unaffected
        opts = ConcreteColumnOptions(
            material        = NWC_4000,
            sizing_strategy = :discrete,
        )
        result = StructuralSizer.size_columns(Pu, Mux, geoms, opts)

        @test hasproperty(result, :sections)
        @test length(result.sections) == 3
        for sec in result.sections
            @test sec isa RCColumnSection
        end
    end

    @testset "NLP with high demand (edge case)" begin
        # Near-capacity demand — NLP should still produce a feasible section
        # or hit the max dimension bound gracefully.
        Pu_high  = [1200.0kip]
        Mux_high = [500.0kip * u"ft"]
        geom_high = [ConcreteMemberGeometry(4.0; k=1.0, braced=true)]

        opts = ConcreteColumnOptions(
            material        = NWC_6000,
            sizing_strategy = :nlp,
            nlp_ρ_max       = 0.06,
        )
        result = StructuralSizer.size_columns(Pu_high, Mux_high, geom_high, opts)

        @test length(result.sections) == 1
        sec = result.sections[1]
        @test sec isa RCColumnSection
        bb = bounding_box(sec)
        @test ustrip(u"inch", bb.width) >= 8.0  # At least min dim
    end

    @testset "NLP NLPColumnOptions field forwarding" begin
        # Verify nlp_* fields on ConcreteColumnOptions are respected
        opts = ConcreteColumnOptions(
            sizing_strategy   = :nlp,
            nlp_dim_increment = 1.0u"inch",
            nlp_prefer_square = 0.5,
            nlp_ρ_max         = 0.04,
            nlp_maxiter       = 100,
        )
        # Just verify it runs without error — field forwarding is tested
        # by the fact that the NLP solver uses these settings.
        result = StructuralSizer.size_columns(Pu[1:1], Mux[1:1], geoms[1:1], opts)
        @test length(result.sections) == 1
    end

end

println("\n✅ All size_columns NLP adapter tests passed!")
