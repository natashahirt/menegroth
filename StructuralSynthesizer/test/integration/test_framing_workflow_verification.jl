using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful
using Asap

# Test-agent regression suite for the Phase-5 → main-pipeline / REST-API wiring.
#
# CONTRACT UNDER TEST: a single `design_building(struc, params)` call, where
# `params` was produced by `json_to_params` from an `APIParams` carrying
# `framing_levels`, must auto-generate the multi-level framing hierarchy
# (joists + secondary beams/girders) with the requested per-level materials.
#
# The generated hierarchy is stored as `Slab.framing_levels::Vector{FramingLevel}`
# (fields `level`, `role`, `material`, …) — the same representation the engineer's
# own `test_auto_framing_integration.jl` §4 inspects. It is NOT materialized into
# `struc.beams` (those hold the level-0 primary one-way girders/beams). Verifying
# `framing_levels` is therefore the correct, reliable post-pipeline check.
#
# ORIGINAL BUG (reproduced by these tests): before the fix, `prepare!` /
# `design_building` ignored `params.framing_opts` (only the explicit `framing_opts`
# kwarg was honored), so an API-driven `framing_levels` request produced ZERO
# framing levels — every `slab.framing_levels` stayed empty.
#
# Geometry: 54'×42', 2×2 bays, 1 story — the battle-tested design_building fixture
# (avoids the single-bay corner-offset edge case in estimate_column_sizes!).
# `skip_visualization=true` drops the ~50s analysis-model build; it does not
# affect framing generation.
const SS = StructuralSynthesizer

"""All framing levels across every slab, flattened, as (level, role, material)."""
_framing(struc) = [fl for slab in struc.slabs for fl in slab.framing_levels]

@testset "Framing Workflow Verification (design_building end-to-end)" begin

    # ─── 1. Multi-level framing survives the full pipeline ───────────────────
    # WHY interesting: exercises the whole json_to_params → design_building path
    # with 3 framing levels of MIXED materials (steel joists, steel girders,
    # concrete girders). Reproduces the original bug: with the fix reverted, the
    # design carries zero framing levels and every assertion below fails.
    @testset "Full Design Workflow with Multi-level Framing" begin
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
        struc = BuildingStructure(skel)

        api_params = SS.APIParams(
            floor_type = "one_way",
            skip_visualization = true,
            framing_levels = [
                SS.APIFramingLevel(material = "steel", spacing_in = 30.0),                          # L1 joists
                SS.APIFramingLevel(material = "steel", role = "beam", count = 2, axis = [1.0, 0.0]),    # L2 girders
                SS.APIFramingLevel(material = "concrete", role = "beam", count = 1, axis = [0.0, 1.0]), # L3 girders
            ],
        )

        params = json_to_params(api_params)

        # The API → params wiring must populate framing_opts (levels 2 and 3 keyed).
        @test !isempty(params.framing_opts)
        @test haskey(params.framing_opts, :level_2)
        @test haskey(params.framing_opts, :level_3)

        design = design_building(struc, params)
        @test design isa BuildingDesign

        # Every slab must carry the requested 3-level hierarchy after the full run.
        @test !isempty(design.structure.slabs)
        for slab in design.structure.slabs
            levels = sort([fl.level for fl in slab.framing_levels])
            @test levels == [1, 2, 3]

            by_level = Dict(fl.level => fl for fl in slab.framing_levels)
            # L1 joists, steel.
            @test by_level[1].role == :joist
            @test by_level[1].material isa StructuralSizer.StructuralSteel
            # L2 secondary beams, steel.
            @test by_level[2].role == :beam
            @test by_level[2].material isa StructuralSizer.StructuralSteel
            # L3 secondary beams, reinforced concrete (default materials.concrete = NWC_4000).
            @test by_level[3].role == :beam
            @test by_level[3].material isa StructuralSizer.ReinforcedConcreteMaterial
            @test by_level[3].material.concrete == StructuralSizer.NWC_4000
        end
    end

    # ─── 2. Edge case: spacing vs. count controls, three levels ──────────────
    # WHY interesting: mixes a spacing-driven level (spacing_in) with a
    # count-driven level, and omits axes so the alternating-axis default path
    # runs. All three requested levels must still materialize per slab.
    @testset "Spacing vs Count Controls" begin
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
        struc = BuildingStructure(skel)

        api_params = SS.APIParams(
            floor_type = "one_way",
            skip_visualization = true,
            framing_levels = [
                SS.APIFramingLevel(material = "steel"),                    # L1 joists (default spacing)
                SS.APIFramingLevel(material = "steel", spacing_in = 60.0), # L2 (spacing-driven)
                SS.APIFramingLevel(material = "steel", count = 1),         # L3 (count-driven)
            ],
        )
        params = json_to_params(api_params)
        design = design_building(struc, params)

        @test !isempty(design.structure.slabs)
        for slab in design.structure.slabs
            @test sort([fl.level for fl in slab.framing_levels]) == [1, 2, 3]
        end
    end

    # ─── 3. Edge case: no framing requested is a strict no-op ────────────────
    # WHY interesting: guards the "empty NamedTuple ⇒ byte-identical" contract.
    # With no framing_levels, framing_opts must be empty and NO framing level may
    # be generated on any slab.
    @testset "Empty Framing Request" begin
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
        struc = BuildingStructure(skel)

        api_params = SS.APIParams(floor_type = "one_way", skip_visualization = true)
        params = json_to_params(api_params)
        @test isempty(params.framing_opts)

        design = design_building(struc, params)
        @test isempty(_framing(design.structure))
    end
end
