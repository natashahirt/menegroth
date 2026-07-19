# Phase 4 smoke test — FramingLevel + AbstractJoistPattern + joist_geometry.
#
# Exercises the type-plumbing added in Phase 4 of the joists-roles-materials
# plan: the four joist-pattern types, the FramingLevel container, the
# attach_framing_level! public API (against a minimal BuildingStructure/Slab),
# and the joist_geometry trait dispatch on floor-system types.
#
# Run:
#   SS_ENABLE_VISUALIZATION=false \
#   julia --project=StructuralSynthesizer scripts/runners/run_phase4_framing_smoke.jl

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap  # units

@testset "Phase 4 — FramingLevel & AbstractJoistPattern" begin

    @testset "Pattern constructors" begin
        # Linear one-way joist field: 4 ft ≈ 1.219 m on center, count unresolved.
        lin = LinearAxisPattern{Float64}((0.0, 1.0), ustrip(u"m", 4.0u"ft"), nothing)
        @test lin isa AbstractJoistPattern
        @test lin.axis == (0.0, 1.0)
        @test lin.spacing ≈ ustrip(u"m", 4.0u"ft")
        @test lin.count === nothing

        # Explicit-count variant.
        lin2 = LinearAxisPattern{Float64}((1.0, 0.0), 1.2, 8)
        @test lin2.count == 8

        # Isoparametric waffle grid: 6 × 8 rib modules.
        iso = IsoparametricPattern(6, 8)
        @test iso isa AbstractJoistPattern
        @test iso.n_xi == 6
        @test iso.n_eta == 8

        # Radial fan: 24 ribs at 15° pitch from the origin.
        rad = RadialPattern{Float64}((0.0, 0.0), deg2rad(15.0), 24)
        @test rad isa AbstractJoistPattern
        @test rad.n == 24
        @test rad.angular_spacing ≈ deg2rad(15.0)

        # Custom generator: callable stored without boxing.
        gen = slab -> Vector{NTuple{2, Float64}}[[(0.0, 0.0), (5.0, 0.0)]]
        cust = CustomPattern(gen)
        @test cust isa AbstractJoistPattern
        @test cust.generator([]) == [[(0.0, 0.0), (5.0, 0.0)]]
    end

    @testset "FramingLevel{Float64} with defaults" begin
        fl = FramingLevel{Float64}(
            slab_idx = 3,
            level    = 1,
            pattern  = IsoparametricPattern(4, 4),
            material = NWC_4000,
        )
        @test fl.role === :joist                      # default
        @test fl.end_fixity === (:default, :default)  # default
        @test fl.torsion_released === nothing         # default
        @test fl.group_id === nothing                 # default
        @test fl.catalog_override === nothing         # default
        @test fl.supports == Int[]                    # default
        @test fl.pattern isa IsoparametricPattern
        @test fl.material === NWC_4000
    end

    @testset "attach_framing_level!" begin
        # Minimal Float64 structure + slab (avoids the unitful sizing pipeline).
        struc = BuildingStructure(BuildingSkeleton{Float64}())
        result = CIPSlabResult(0.2, 0.2, 5.0)                 # plain-Float64 result stub
        spans  = SpanInfo{Float64}(6.0, 8.0, (1.0, 0.0), 7.0)
        slab = Slab{Float64}([1], result, :two_way, spans, :interior,
                             nothing, MaterialVolumes(), nothing, nothing,
                             FramingLevel{Float64}[])
        push!(struc.slabs, slab)
        @test isempty(slab.framing_levels)

        level = FramingLevel{Float64}(
            slab_idx = 0,   # unset → attach sets it
            level    = 1,
            pattern  = LinearAxisPattern{Float64}((1.0, 0.0), ustrip(u"m", 4.0u"ft"), nothing),
            role     = :joist,
            material = A992_Steel,
        )
        returned = attach_framing_level!(struc, slab, level)

        @test returned === level
        @test level.slab_idx == 1                       # set to slab's index
        @test length(slab.framing_levels) == 1
        @test slab.framing_levels[1] === level          # points back correctly

        # Idempotent slab_idx match is fine; a mismatch errors.
        level2 = FramingLevel{Float64}(
            slab_idx = 1, level = 2,
            pattern = IsoparametricPattern(2, 2), material = A992_Steel)
        attach_framing_level!(struc, slab, level2)
        @test length(slab.framing_levels) == 2

        bad = FramingLevel{Float64}(
            slab_idx = 99, level = 1,
            pattern = IsoparametricPattern(2, 2), material = A992_Steel)
        @test_throws ArgumentError attach_framing_level!(struc, slab, bad)
    end

    @testset "joist_geometry — derived values (not placeholders)" begin
        # Default AbstractFloorSystem singletons → nothing (unchanged contract).
        @test joist_geometry(FlatPlate(), 1) === nothing
        @test joist_geometry(OneWay(), 1) === nothing

        # Singleton floor-type markers carry NO geometry. The removed placeholder
        # overrides used to short-circuit these to hardcoded patterns
        # (IsoparametricPattern(1, 1) / LinearAxisPattern((1.0, 0.0), …)); real
        # geometry now comes only from the data-bearing overloads below, so the
        # bare singletons fall through to the `nothing` default.
        @test joist_geometry(Waffle(), 1) === nothing
        @test joist_geometry(MassTimberJoist(), 1) === nothing
        @test joist_geometry(JoistRoofDeck(), 1) === nothing

        # --- Waffle: IsoparametricPattern derived from a real WaffleRibGrid ---
        panel = StructuralSizer.IsoParametricPanel(
            ((0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)))
        grid = StructuralSizer.WaffleRibGrid(panel, 6, 8)          # nξ = 6, nη = 8
        wg = joist_geometry(grid, 1)
        @test wg isa IsoparametricPattern
        @test wg.n_xi == 6                                          # from grid.nξ
        @test wg.n_eta == 8                                         # from grid.nη
        @test joist_geometry(grid, 2) === nothing

        # Waffle slab: sizing returns a CIPSlabResult (no rib grid), so the Slab
        # entry point returns nothing today. Documents the Phase-5 seam — a
        # rib-grid-bearing waffle result will route through joist_geometry(grid).
        waffle_slab = Slab{Float64}(
            [1], CIPSlabResult(0.3, 0.3, 6.0), :waffle,
            SpanInfo{Float64}(6.0, 8.0, (0.0, 1.0), 7.0), :interior,
            nothing, MaterialVolumes(), nothing, nothing, FramingLevel{Float64}[])
        @test joist_geometry(waffle_slab, 1) === nothing

        # --- MassTimberJoist: LinearAxisPattern derived from result + spans ---
        mtj_spacing = ustrip(u"m", 600.0u"mm")                     # 0.6 m on center
        mtj_result = TimberJoistResult(
            "GLT 175x400", 0.4, mtj_spacing, "CLT panel", 0.44, 0.05, 1.2)
        mtj_spans = SpanInfo{Float64}(5.0, 7.0, (1.0, 0.0), 6.0)   # span axis = +x

        mtj = joist_geometry(mtj_result, mtj_spans, 1)
        @test mtj isa LinearAxisPattern
        @test mtj.axis == (1.0, 0.0)                               # from spans.axis
        @test mtj.spacing ≈ mtj_spacing                            # from result.joist_spacing
        @test mtj.count === nothing
        @test joist_geometry(mtj_result, mtj_spans, 2) === nothing

        mtj_slab = Slab{Float64}(
            [2], mtj_result, :mass_timber_joist, mtj_spans, :interior,
            nothing, MaterialVolumes(), nothing, nothing, FramingLevel{Float64}[])
        mtj_from_slab = joist_geometry(mtj_slab, 1)
        @test mtj_from_slab isa LinearAxisPattern
        @test mtj_from_slab.axis == (1.0, 0.0)
        @test mtj_from_slab.spacing ≈ mtj_spacing
        @test joist_geometry(mtj_slab, 2) === nothing

        # --- JoistRoofDeck: LinearAxisPattern derived from result + spans ---
        jrd_spacing = ustrip(u"m", 4.0u"ft")                       # 4 ft on center
        jrd_result = JoistDeckResult(
            "22K6", 0.55, jrd_spacing, "1.5B deck", 0.04, 0.59, 0.02, 0.8)
        jrd_spans = SpanInfo{Float64}(8.0, 12.0, (0.0, 1.0), 10.0) # span axis = +y

        jrd = joist_geometry(jrd_result, jrd_spans, 1)
        @test jrd isa LinearAxisPattern
        @test jrd.axis == (0.0, 1.0)                               # from spans.axis
        @test jrd.spacing ≈ jrd_spacing                            # from result.joist_spacing
        @test jrd.count === nothing
        @test joist_geometry(jrd_result, jrd_spans, 2) === nothing

        jrd_slab = Slab{Float64}(
            [3], jrd_result, :joist_roof_deck, jrd_spans, :interior,
            nothing, MaterialVolumes(), nothing, nothing, FramingLevel{Float64}[])
        jrd_from_slab = joist_geometry(jrd_slab, 1)
        @test jrd_from_slab isa LinearAxisPattern
        @test jrd_from_slab.axis == (0.0, 1.0)
        @test jrd_from_slab.spacing ≈ jrd_spacing
        @test joist_geometry(jrd_slab, 2) === nothing
    end
end
