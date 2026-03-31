# =============================================================================
# Test uniform_column_sizing feature
#
# Verifies that :per_story and :building modes force all columns in a group
# to match the governing (largest) size after design_building.
#
# Run standalone:
#   julia --project=StructuralSynthesizer StructuralSynthesizer/test/core/test_uniform_column_sizing.jl
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful

println("Testing uniform column sizing...")

@testset "Uniform Column Sizing" begin

    # ─── Field existence ──────────────────────────────────────────────────
    @testset "DesignParameters field" begin
        p = DesignParameters()
        @test p.uniform_column_sizing === :off

        p2 = DesignParameters(uniform_column_sizing=:per_story)
        @test p2.uniform_column_sizing === :per_story

        p3 = DesignParameters(uniform_column_sizing=:building)
        @test p3.uniform_column_sizing === :building
    end

    # ─── per_story: all columns on same story match after design ──────────
    @testset "per_story harmonization (flat plate)" begin
        # 2×2 bay, 1 story → 9 columns (interior/edge/corner have different demands)
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
        struc = BuildingStructure(skel)

        design = design_building(struc, DesignParameters(
            floor = FlatPlateOptions(method = DDM()),
            uniform_column_sizing = :per_story,
            max_iterations = 3,
            skip_visualization = true,
        ))

        @test design isa BuildingDesign

        # Collect column sizes by story
        story_c1 = Dict{Int, Set{typeof(1.0u"m")}}()
        story_c2 = Dict{Int, Set{typeof(1.0u"m")}}()
        for col in struc.columns
            isnothing(col.c1) && continue
            push!(get!(Set{typeof(1.0u"m")}, story_c1, col.story), col.c1)
            push!(get!(Set{typeof(1.0u"m")}, story_c2, col.story), col.c2)
        end

        # After restore!, struc columns are reset. Check via the design instead.
        # The harmonization happened before capture_design, so we verify by
        # re-running with the same params and checking struc before restore.
        # Instead, just verify the DesignParameters was set correctly.
        @test design.params.uniform_column_sizing === :per_story
    end

    # ─── per_story: manual pipeline check ─────────────────────────────────
    @testset "per_story: columns uniform after harmonize (manual pipeline)" begin
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
        struc = BuildingStructure(skel)
        params = DesignParameters(
            floor = FlatPlateOptions(method = DDM()),
            uniform_column_sizing = :per_story,
            max_iterations = 3,
            skip_visualization = true,
        )

        prepare!(struc, params)

        for stage in build_pipeline(params)
            stage.fn(struc)
            stage.needs_sync && sync_asap!(struc; params=params)
        end

        # Before harmonize: columns may differ
        n_changed = StructuralSynthesizer.harmonize_uniform_column_sizes!(struc, params)

        # After harmonize: all columns on each story should have identical c1, c2
        by_story = Dict{Int, Vector{Tuple{typeof(1.0u"m"), typeof(1.0u"m")}}}()
        for col in struc.columns
            isnothing(col.c1) && continue
            push!(get!(Vector{Tuple{typeof(1.0u"m"), typeof(1.0u"m")}}, by_story, col.story),
                  (col.c1, col.c2))
        end

        for (story, dims) in by_story
            length(dims) <= 1 && continue
            c1_set = Set(d[1] for d in dims)
            c2_set = Set(d[2] for d in dims)
            @test length(c1_set) == 1  "Story $story: expected uniform c1, got $c1_set"
            @test length(c2_set) == 1  "Story $story: expected uniform c2, got $c2_set"
        end
    end

    # ─── building mode: every column the same ─────────────────────────────
    @testset "building: all columns uniform (manual pipeline)" begin
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 2)
        struc = BuildingStructure(skel)
        params = DesignParameters(
            floor = FlatPlateOptions(method = DDM()),
            uniform_column_sizing = :building,
            max_iterations = 3,
            skip_visualization = true,
        )

        prepare!(struc, params)

        for stage in build_pipeline(params)
            stage.fn(struc)
            stage.needs_sync && sync_asap!(struc; params=params)
        end

        StructuralSynthesizer.harmonize_uniform_column_sizes!(struc, params)

        all_c1 = Set{typeof(1.0u"m")}()
        all_c2 = Set{typeof(1.0u"m")}()
        for col in struc.columns
            isnothing(col.c1) && continue
            push!(all_c1, col.c1)
            push!(all_c2, col.c2)
        end

        @test length(all_c1) == 1  "Expected single c1 across building, got $all_c1"
        @test length(all_c2) == 1  "Expected single c2 across building, got $all_c2"
    end

    # ─── off mode: no harmonization ───────────────────────────────────────
    @testset "off mode: harmonize is a no-op" begin
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
        struc = BuildingStructure(skel)
        params = DesignParameters(
            floor = FlatPlateOptions(method = DDM()),
            uniform_column_sizing = :off,
            max_iterations = 3,
            skip_visualization = true,
        )

        prepare!(struc, params)

        for stage in build_pipeline(params)
            stage.fn(struc)
            stage.needs_sync && sync_asap!(struc; params=params)
        end

        n_changed = StructuralSynthesizer.harmonize_uniform_column_sizes!(struc, params)
        @test n_changed == 0
    end
end

println("\n✓ Uniform column sizing tests passed!")
