# HAND CHECK — ASCE 7-22 diaphragm idealization.
#
# Not a published example. Each case is the clause's own limit:
# §12.3.1 / §12.3.1.1 / §12.3.1.2 / §12.3.1.3 Eq. 12.3-1 (PDF p. 179),
# Table 12.3-1 type numbers as caller inputs (PDF p. 180), and the §26.2
# wind diaphragm (PDF p. 324). source_id: asce-7-22.

using Test
using Unitful
using StructuralSynthesizer

"""Classifier call with the required inputs named once."""
function _ideal(; loading, construction, span, depth, irregularities=Int[], kwargs...)
    return classify_diaphragm_idealization(;
        loading, construction, span, depth,
        horizontal_irregularity_types=irregularities,
        kwargs...)
end

@testset "ASCE 7-22 diaphragm idealization" begin
    @testset "HAND CHECK seismic rigid, flexible, and semirigid" begin
        # §12.3.1.2: concrete slab, span/depth = 3, no Type 2–5 → rigid.
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=3, depth=1) === :rigid
        # Exactly 3 with lengths, not bare numbers.
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=9.0u"m", depth=3.0u"m") === :rigid
        # Above 3 is not permitted.
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=3.01, depth=1) === :shell
        # Type 4 blocks the rigid permission. Type 1 does not.
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=3, depth=1, irregularities=[4]) === :shell
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=3, depth=1, irregularities=[1]) === :rigid
        for t in (2, 3, 5)
            @test _ideal(; loading=:seismic, construction=:concrete_slab,
                         span=3, depth=1, irregularities=[t]) === :shell
        end
        # §12.3.1.1 item 1: untopped steel deck over concrete shear walls.
        # The ratio is 10, so this is not a rigid permission.
        @test _ideal(; loading=:seismic, construction=:untopped_steel_deck,
                     span=10, depth=1,
                     vertical_elements=:concrete_shear_wall) === :flexible
        # Eq. 12.3-1 is strictly greater than 2. Neither §12.3.1.1 nor
        # §12.3.1.2 permits this slab (span/depth = 4).
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=4, depth=1,
                     delta_mdd=2.0, delta_adve=1.0) === :shell
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=4, depth=1,
                     delta_mdd=2.01, delta_adve=1.0) === :flexible
    end

    @testset "HAND CHECK wind does not borrow the seismic limit" begin
        @test _ideal(; loading=:wind, construction=:concrete_slab,
                     span=2, depth=1) === :rigid
        @test _ideal(; loading=:wind, construction=:concrete_slab,
                     span=2.5, depth=1) === :shell
        # The same slab is rigid for seismic. The classifier does not keep
        # the stricter of the two chapters.
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=2.5, depth=1) === :rigid
        # §26.2 does not name Type 4. A ratio of 2 stays rigid.
        @test _ideal(; loading=:wind, construction=:concrete_slab,
                     span=2, depth=1, irregularities=[4]) === :rigid
        @test _ideal(; loading=:wind, construction=:wood_structural_panels,
                     span=1, depth=1) === :flexible
        @test _ideal(; loading=:wind, construction=:untopped_steel_deck,
                     span=2, depth=1) === :rigid
    end

    @testset "HAND CHECK filled-deck names are one construction" begin
        # §26.2: concrete-filled steel deck, span/depth = 2 → rigid.
        # `:concrete_filled_metal_deck` is that same deck. Exactly 2 is permitted.
        @test _ideal(; loading=:wind, construction=:concrete_filled_steel_deck,
                     span=2, depth=1) === :rigid
        @test _ideal(; loading=:wind, construction=:concrete_filled_metal_deck,
                     span=2, depth=1) === :rigid
        # Just above 2 is not rigid. The seismic limit of 3 is not used,
        # and a Type 4 irregularity is not a §26.2 test.
        @test _ideal(; loading=:wind, construction=:concrete_filled_metal_deck,
                     span=2.01, depth=1) === :shell
        @test _ideal(; loading=:wind, construction=:concrete_filled_metal_deck,
                     span=2, depth=1, irregularities=[4]) === :rigid
        # Eq. 12.3-1 is not applied to wind. A displacement ratio above 2
        # does not make this shell into a flexible diaphragm.
        @test _ideal(; loading=:wind, construction=:concrete_filled_metal_deck,
                     span=2.01, depth=1,
                     delta_mdd=3.0, delta_adve=1.0) === :shell
        # §12.3.1.2: concrete-filled metal deck, span/depth = 3, no Type 2–5
        # → rigid. `:concrete_filled_steel_deck` is that same deck.
        # Exactly 3 is permitted. The wind limit of 2 is not used.
        @test _ideal(; loading=:seismic, construction=:concrete_filled_metal_deck,
                     span=3, depth=1) === :rigid
        @test _ideal(; loading=:seismic, construction=:concrete_filled_steel_deck,
                     span=3, depth=1) === :rigid
        @test _ideal(; loading=:seismic, construction=:concrete_filled_steel_deck,
                     span=2.5, depth=1) === :rigid
        # Just above 3 is not rigid. An empty irregularity list does not
        # invent a Type 2–5 irregularity, and Type 4 still blocks a ratio of 3.
        @test _ideal(; loading=:seismic, construction=:concrete_filled_steel_deck,
                     span=3.01, depth=1) === :shell
        @test _ideal(; loading=:seismic, construction=:concrete_filled_steel_deck,
                     span=3, depth=1, irregularities=Int[]) === :rigid
        @test _ideal(; loading=:seismic, construction=:concrete_filled_steel_deck,
                     span=3, depth=1, irregularities=[4]) === :shell
        # Untopped steel deck is wind-rigid at a ratio of 2 and is not
        # seismic-rigid. No §12.3.1.1 item is asserted here.
        @test _ideal(; loading=:seismic, construction=:untopped_steel_deck,
                     span=2, depth=1) === :shell
    end

    @testset "HAND CHECK §12.3.1.1 item 3 is caller-supplied" begin
        # Wood panels, not a listed vertical system, not a dwelling.
        # Item 3 is the only flexible permission, and only when the caller
        # says each line complies and the topping is within 1.5 in.
        item3 = (;
            loading=:seismic, construction=:wood_structural_panels,
            span=8, depth=1, vertical_elements=:moment_frame,
            light_frame=true, each_line_complies_table_12_12_1=true,
        )
        @test _ideal(; item3..., topping_thickness=1.5u"inch",
                     topping_is_nonstructural=true) === :flexible
        @test _ideal(; item3..., topping_thickness=38u"mm",
                     topping_is_nonstructural=true) === :flexible
        @test _ideal(; item3..., topping_thickness=0u"inch") === :flexible
        @test _ideal(; item3..., topping_thickness=1.5u"inch" + 1u"mm",
                     topping_is_nonstructural=true) === :shell
        # The compliance flag was not passed, so item 3 does not apply.
        @test _ideal(; loading=:seismic, construction=:wood_structural_panels,
                     span=8, depth=1, vertical_elements=:moment_frame,
                     light_frame=true, topping_thickness=0u"inch") === :shell
    end

    @testset "missing inputs throw" begin
        @test_throws ArgumentError _ideal(; loading=:seismic,
            construction=:concrete_slab, span=nothing, depth=1)
        @test_throws ArgumentError classify_diaphragm_idealization(;
            loading=:seismic, construction=:gypsum_panel, span=4, depth=1,
            horizontal_irregularity_types=Int[])
        @test_throws ArgumentError _ideal(; loading=:seismic,
            construction=:gypsum_panel, span=4, depth=1, delta_mdd=2.01)
        @test_throws ArgumentError _ideal(; loading=:other,
            construction=:concrete_slab, span=3, depth=1)
    end

    @testset "HAND CHECK tributary split is not applied to a building" begin
        # F_i = F * A_i / ΣA. 40 N split 1:3 → 10 N and 30 N.
        shares = distribute_flexible_diaphragm_story_force((40.0, 0.0), [1.0, 3.0])
        @test shares[1] == (10.0, 0.0)
        @test shares[2] == (30.0, 0.0)
        @test_throws ArgumentError distribute_flexible_diaphragm_story_force(
            (40.0, 0.0), [1.0, nothing])
        @test_throws ArgumentError distribute_flexible_diaphragm_story_force(
            (40.0, 0.0), Float64[])
    end

    @testset "to_asap! :flexible" begin
        skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1)
        bare = BuildingStructure(skel)
        err = try
            to_asap!(bare; diaphragms=:semirigid)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin(":flexible", sprint(showerror, err))
        @test_throws ArgumentError to_asap!(bare; diaphragms=:flexible)

        initialize!(bare)
        params = DesignParameters(diaphragm_mode=:flexible)
        model = to_asap!(bare; params=params)
        @test params.diaphragm_mode === :flexible
        @test isempty(bare.asap_rigid_links)
        @test isempty(model.shell_elements)
        # No story force was written onto the model.
        @test all(l -> !(l isa Asap.NodeForce), model.loads)
    end

    @testset "Concrete-filled deck floor" begin
        # The construction is fixed. Seismic §12.3.1.2 (PDF p. 179):
        # span/depth of 3 is rigid; above 3 is a shell. Wind §26.2
        # (PDF p. 324) uses 2, not the seismic 3.
        @test deck_floor_diaphragm(; loading=:seismic, span=30.0u"ft", depth=10.0u"ft",
                horizontal_irregularity_types=Int[]) === :rigid
        @test deck_floor_diaphragm(; loading=:seismic, span=40.0u"ft", depth=10.0u"ft",
                horizontal_irregularity_types=Int[]) === :shell
        @test deck_floor_diaphragm(; loading=:wind, span=20.0u"ft", depth=10.0u"ft",
                horizontal_irregularity_types=Int[]) === :rigid
        @test deck_floor_diaphragm(; loading=:wind, span=30.0u"ft", depth=10.0u"ft",
                horizontal_irregularity_types=Int[]) === :shell
        # A type 2 horizontal irregularity blocks the seismic rigid permission.
        @test deck_floor_diaphragm(; loading=:seismic, span=30.0u"ft", depth=10.0u"ft",
                horizontal_irregularity_types=[2]) === :shell
    end
end
