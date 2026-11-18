# =============================================================================
# RC beam catalog growth: a named catalog with no passing section grows one
# tier at a time, with a warning. A custom catalog and the top tier throw.
# =============================================================================

using Test
using Unitful
using StructuralSizer
using Asap: kip, ksi

@testset "RC beam catalog growth" begin
    geoms = [ConcreteMemberGeometry(30.0u"ft")]
    opts = ConcreteBeamOptions(deflection_limit = nothing)
    deepest_standard = maximum(s -> s.h, rc_beam_catalog(:standard))

    # Past the deepest :standard section in flexure.
    Mu = [1600.0 * kip * u"ft"]
    Vu = [120.0 * kip]
    result = @test_logs (:warn, r"no section in the :standard catalog passes") match_mode = :any begin
        size_beams(Mu, Vu, geoms, opts)
    end
    sec = only(result.sections)
    @test sec.h > deepest_standard
    # The section still passes the checker it was picked by.
    checker = ACIBeamChecker(;
        fy_ksi = ustrip(ksi, opts.rebar_material.Fy),
        fyt_ksi = ustrip(ksi, StructuralSizer.get_transverse_rebar(opts).Fy),
        Es_ksi = ustrip(ksi, opts.rebar_material.E),
        λ = opts.material.λ, max_depth = opts.max_depth)
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [sec], opts.material, opts.objective)
    @test is_feasible(checker, cache, 1, sec, opts.material,
                      RCBeamDemand(1; Mu = 1600.0, Vu = 120.0), geoms[1])

    # A demand that fits :standard does not grow.
    small = @test_logs min_level = Base.CoreLogging.Warn size_beams(
        [100.0 * kip * u"ft"], [30.0 * kip], geoms, opts)
    @test only(small.sections).h <= deepest_standard

    # Nothing in :xlarge either: the error is kept.
    @test_throws ArgumentError size_beams(
        [1.0e5 * kip * u"ft"], [120.0 * kip], geoms, opts)

    # A custom catalog is used as given.
    custom = ConcreteBeamOptions(deflection_limit = nothing,
                                 custom_catalog = rc_beam_catalog(:standard))
    @test_throws ArgumentError size_beams(Mu, Vu, geoms, custom)

    # A hard catalog errors instead of growing.
    held = ConcreteBeamOptions(deflection_limit = nothing, catalog_constraint = :hard)
    @test_throws ArgumentError size_beams(Mu, Vu, geoms, held)
end
