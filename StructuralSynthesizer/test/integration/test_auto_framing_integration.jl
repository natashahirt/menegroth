using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful
using Asap

# Predicates that handle any AbstractMember safely
_is_joist(m::AbstractMember) = m isa Beam && is_joist(m)
_is_beam(m::AbstractMember) = m isa Beam && is_beam(m)
_level_of(m::AbstractMember) = m isa Beam ? level_of(m) : 0

@testset "Auto-framing Integration" begin

    # ─── 1. API Deserialization ──────────────────────────────────────────────
    @testset "API Deserialization" begin
        # Test basic resolution of framing_levels from JSON-like APIParams
        api_params = StructuralSynthesizer.APIParams(
            floor_type = "one_way",
            framing_levels = [
                StructuralSynthesizer.APIFramingLevel(
                    material = "steel",
                    spacing_in = 24.0
                ),
                StructuralSynthesizer.APIFramingLevel(
                    material = "concrete",
                    role = "beam",
                    axis = [1.0, 0.0],
                    count = 3
                )
            ]
        )

        params = StructuralSynthesizer.json_to_params(api_params, "meters")
        opts = params.framing_opts

        @test !isempty(opts)
        @test haskey(opts, :materials)
        @test haskey(opts, :spacing)
        @test haskey(opts, :level_2)

        # Level 1 (joists)
        @test opts.spacing == 24.0u"inch"
        @test opts.materials.steel isa StructuralSizer.AbstractMaterial
        @test opts.materials.beam == opts.materials.steel

        # Level 2 (girders)
        @test opts.level_2.material isa StructuralSizer.ReinforcedConcreteMaterial
        @test opts.level_2.role == :beam
        @test opts.level_2.axis == (1.0, 0.0)
        @test opts.level_2.count == 3
    end

    # ─── 2. Integration with prepare! ────────────────────────────────────────
    @testset "prepare! auto-generation" begin
        # Baseline: no framing levels. Multi-bay grid (single-bay 1x1 hits a
        # pre-existing update_structural_offsets! edge case — see the Phase 5
        # integration test's note on 1x1 subdivision).
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
        struc_base = BuildingStructure(skel)
        params_base = DesignParameters()
        prepare!(struc_base, params_base)

        n_members_base = length(struc_base.beams) + length(struc_base.columns) + length(struc_base.struts)

        # With framing: one level of steel joists at 24"
        # Must use a floor type that supports auto-framing
        struc_framing = BuildingStructure(skel)
        params_framing = DesignParameters(
            floor = OneWayOptions(),
            materials = MaterialOptions(steel = StructuralSizer.A992_Steel),
            framing_opts = (;
                materials = (; beam = StructuralSizer.A992_Steel),
                spacing = 24.0u"inch"
            )
        )
        prepare!(struc_framing, params_framing)

        n_members_framing = length(struc_framing.beams) + length(struc_framing.columns) + length(struc_framing.struts)
        @test n_members_framing > n_members_base

        # Verify joists were added
        joists = filter(is_joist, struc_framing.beams)
        @test !isempty(joists)
        @test all(m -> m.level == 1, joists)
    end

    # ─── 3. End-to-End Workflow Integration ──────────────────────────────────
    @testset "design_building integration" begin
        # Multi-bay grid (single-bay 1x1 hits a pre-existing
        # update_structural_offsets! edge case — see the Phase 5 test's note).
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
        struc = BuildingStructure(skel)

        # Request steel joists and concrete girders through APIParams
        api_params = StructuralSynthesizer.APIParams(
            floor_type = "one_way",
            framing_levels = [
                StructuralSynthesizer.APIFramingLevel(material = "steel", spacing_in = 24.0),
                StructuralSynthesizer.APIFramingLevel(material = "concrete", role = "beam")
            ]
        )
        params = json_to_params(api_params)

        design = design_building(struc, params)
        @test design isa BuildingDesign

        final_struc = design.structure
        @test !isempty(filter(is_joist, final_struc.beams))
        # Level 2 members exist
        @test !isempty(filter(m -> level_of(m) == 2, final_struc.beams))
    end

    # ─── 4. Critic regression: axis alternation, level-1 params, schema fields ─
    @testset "Critic regression fixes" begin
        SS = StructuralSynthesizer
        # Multi-bay grid (single-bay 1x1 hits a pre-existing update_structural_offsets!
        # edge case — see the Phase 5 integration test's note).
        _grid() = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)

        # (P1) Level-1 axis + count must survive deserialization (were dropped).
        api_l1 = SS.APIParams(
            floor_type = "one_way",
            framing_levels = [SS.APIFramingLevel(material = "steel",
                                                 axis = [1.0, 0.0], count = 5)],
        )
        opts_l1 = SS.json_to_params(api_l1).framing_opts
        @test opts_l1.axis == (1.0, 0.0)
        @test opts_l1.count == 5

        # (P1) end_fixity + catalog_override schema fields must plumb through.
        api_adv = SS.APIParams(
            floor_type = "one_way",
            framing_levels = [
                SS.APIFramingLevel(material = "steel"),
                SS.APIFramingLevel(material = "steel", role = "beam",
                                   end_fixity = ["pinned", "fixed"],
                                   catalog_override = "preferred_W"),
            ],
        )
        opts_adv = SS.json_to_params(api_adv).framing_opts
        @test opts_adv.level_2.end_fixity == (:pinned, :fixed)
        @test opts_adv.level_2.catalog_override == StructuralSizer.preferred_W()

        # Invalid end_fixity / catalog_override names error clearly.
        @test_throws ErrorException SS._resolve_framing_end_fixity(["welded", "fixed"])
        @test_throws ErrorException SS._resolve_framing_end_fixity(["fixed"])
        @test_throws ErrorException SS._resolve_framing_catalog_override("bogus_catalog")

        # (P0) Level 3+ default axis must alternate (⟂ to the level below), not
        # stay pinned to spans.axis. With no explicit axis on levels 2/3, level 2
        # defaults to spans.axis and level 3 must default to its perpendicular, so
        # the materialized level-2 and level-3 joist patterns are perpendicular.
        api_alt = SS.APIParams(
            floor_type = "one_way",
            framing_levels = [
                SS.APIFramingLevel(material = "steel", spacing_in = 60.0),   # L1
                SS.APIFramingLevel(material = "steel", role = "beam", count = 2),  # L2 (no axis)
                SS.APIFramingLevel(material = "steel", role = "beam", count = 1),  # L3 (no axis)
            ],
        )
        opts_alt = SS.json_to_params(api_alt).framing_opts
        struc_alt = BuildingStructure(_grid())
        prepare!(struc_alt, DesignParameters(floor = OneWayOptions(),
                 materials = MaterialOptions(steel = StructuralSizer.A992_Steel),
                 framing_opts = opts_alt))
        checked = false
        for slab in struc_alt.slabs
            base = slab.spans.axis
            l2i = findfirst(fl -> fl.level == 2, slab.framing_levels)
            l3i = findfirst(fl -> fl.level == 3, slab.framing_levels)
            (l2i === nothing || l3i === nothing) && continue
            a2 = slab.framing_levels[l2i].pattern.axis
            a3 = slab.framing_levels[l3i].pattern.axis
            # Consecutive levels perpendicular: a2·a3 ≈ 0.
            @test isapprox(a2[1]*a3[1] + a2[2]*a3[2], 0.0; atol = 1e-9)
            # Level 3 defaults to the perpendicular of spans.axis (⟂ level 2).
            @test isapprox(a3[1]*base[1] + a3[2]*base[2], 0.0; atol = 1e-9)
            checked = true
        end
        @test checked   # at least one slab carried both levels 2 and 3
    end

    # ─── 5. Critic regression: incremental-mode state leak ────────────────────
    @testset "Incremental engine does not leak framing across reuse" begin
        # Reusing the SAME struc handle across successive prepare_engine calls
        # (multi-level, then single-level) must NOT accumulate joists: the engine
        # prepares an independent copy, so the caller's struc stays pristine and
        # each engine's baseline reflects exactly the requested framing.
        struc = BuildingStructure(gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1))

        params_multi = DesignParameters(
            floor = OneWayOptions(),
            materials = MaterialOptions(steel = StructuralSizer.A992_Steel),
            framing_opts = (;
                materials = (; beam = StructuralSizer.A992_Steel),
                spacing = 60.0u"inch",
                level_2 = (; material = StructuralSizer.A992_Steel, role = :beam, count = 2),
                level_3 = (; material = StructuralSizer.A992_Steel, role = :beam, count = 1),
            ),
        )
        params_single = DesignParameters(
            floor = OneWayOptions(),
            materials = MaterialOptions(steel = StructuralSizer.A992_Steel),
            framing_opts = (;
                materials = (; beam = StructuralSizer.A992_Steel),
                spacing = 60.0u"inch",
            ),
        )

        eng_multi = StructuralSynthesizer.prepare_engine(struc, params_multi)
        n_multi = count(m -> level_of(m) >= 1, eng_multi.baseline.beams)
        @test any(m -> level_of(m) >= 2, eng_multi.baseline.beams)
        # Caller's struc is untouched by prepare_engine (works on a copy).
        @test isempty(struc.beams)

        # Reuse the SAME pristine struc handle for a reduced-framing engine.
        eng_single = StructuralSynthesizer.prepare_engine(struc, params_single)
        # No leaked level 2/3 members from the earlier multi-level engine.
        @test !any(m -> level_of(m) >= 2, eng_single.baseline.beams)
        n_single = count(m -> level_of(m) >= 1, eng_single.baseline.beams)
        @test n_single < n_multi
    end

    # ─── 6. Edge Cases ───────────────────────────────────────────────────────
    @testset "Edge Cases" begin
        # Invalid material: timber has no NDS-grounded preset registered, so a
        # bare "timber" request (no materials.timber preset) still errors.
        @test_throws ErrorException StructuralSynthesizer._resolve_framing_material("timber", StructuralSynthesizer.APIParams())

        # Empty framing levels (strict no-op)
        skel = gen_medium_office(30.0u"ft", 30.0u"ft", 10.0u"ft", 1, 1, 1)
        struc = BuildingStructure(skel)
        
        # Manually initialize to count members accurately after skeleton → structure mapping
        initialize!(struc)
        n_members_pre = length(struc.beams) + length(struc.columns) + length(struc.struts)
        
        prepare!(struc, DesignParameters(framing_opts = NamedTuple()))
        n_members_post = length(struc.beams) + length(struc.columns) + length(struc.struts)
        @test n_members_post == n_members_pre
    end

end
