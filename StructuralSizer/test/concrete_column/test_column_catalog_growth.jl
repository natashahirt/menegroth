# =============================================================================
# RC column catalog growth. A soft named catalog with no passing section
# grows one tier at a time and warns. A hard catalog, a custom catalog, and
# the top tier throw. The first step off a square catalog stays square.
# =============================================================================

using Test
using Unitful
using StructuralSizer
using Asap: kip

@testset "RC column catalog growth" begin
    standard = rc_column_catalog(:rect, :standard)
    grown = grow_rc_column_catalog(standard, :rect, :standard)
    @test grown !== nothing
    next_cat, next_tier = grown
    @test next_tier === :high_capacity
    @test all(s -> s.b ≈ s.h, next_cat)
    @test maximum(s -> s.h, next_cat) > maximum(s -> s.h, standard)
    @test grow_rc_column_catalog(standard, :rect, :all) === nothing

    geoms = [ConcreteMemberGeometry(4.0u"m"; k = 1.0, braced = true)]
    # Past every :low_capacity section, inside :standard.
    Pu = [2500.0 * kip]
    Mu = [0.0 * kip * u"ft"]
    soft = ConcreteColumnOptions(catalog = :low_capacity)
    result = @test_logs (:warn, r"no section in the :low_capacity catalog passes") match_mode = :any begin
        size_columns(Pu, Mu, geoms, soft)
    end
    sec = only(result.sections)
    @test sec.b ≈ sec.h
    @test sec.h > 24.0u"inch"

    # A demand that fits does not grow.
    small = @test_logs min_level = Base.CoreLogging.Warn size_columns(
        [400.0 * kip], Mu, geoms, soft)
    @test only(small.sections).h <= 24.0u"inch"

    # Hard stays in the named catalog.
    held = ConcreteColumnOptions(catalog = :low_capacity, catalog_constraint = :hard)
    @test_throws ArgumentError size_columns(Pu, Mu, geoms, held)

    # A custom catalog is the range, soft or hard.
    custom = ConcreteColumnOptions(
        catalog_constraint = :soft,
        custom_catalog = rc_column_catalog(:rect, :low_capacity))
    @test_throws ArgumentError size_columns(Pu, Mu, geoms, custom)

    # Past :standard. The added tier's squares are what get tried first,
    # so the section that passes is still square.
    heavy = [4000.0 * kip]
    square = ConcreteColumnOptions(catalog = :standard)
    bumped = @test_logs (:warn, r"no section in the :standard catalog passes") match_mode = :any begin
        size_columns(heavy, Mu, geoms, square)
    end
    picked = only(bumped.sections)
    @test picked.b ≈ picked.h
    left_standard = picked.h > 36.0u"inch" ||
        maximum(b -> ustrip(u"inch^2", b.As), picked.bars) > 1.56 + 1e-6
    @test left_standard
end
