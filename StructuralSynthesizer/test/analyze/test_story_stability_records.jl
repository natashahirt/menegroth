# Story-stability records from a solved ELF analysis.
#
# `story_stability_records` maps each (story, direction) of an `ElfStoryAnalysis`
# onto a `StructuralSizer.StoryStability` for the approximate second-order column
# design. The defining regression hook is the ASCE 7-22 §12.8.7 identity
#
#     stability_index(record) == stability_coefficient(Px, hsx, Vx, Δxe)
#
# i.e. the ACI sway index Q reproduces the ELF seismic θ, because both are
# Px·Δxe/(hsx·Vx). These are pure fixtures: a single story, hand-chosen Px, Vx,
# and elastic drift, so the arithmetic is checkable by hand.

using Test
using StructuralSynthesizer
using StructuralSizer

"""One level above the base; only `px_kN` and `story_height_m` feed the record."""
function _stability_level(; story=1, px_kN=1000.0, story_height_m=4.0)
    return StructuralSynthesizer.ElfLevel(
        story, 4.0, 4.0, story_height_m, 100.0, 100.0, px_kN, nothing,
        (0.0, 0.0), (10.0, 6.0), (0.0, 10.0, 0.0, 6.0),
        Vector{Vector{NTuple{2, Float64}}}())
end

"""One `:drift` ELF case along `direction` with story shear `Vx` and elastic drift `Δe`."""
function _stability_drift_case(direction, Vx, Δe)
    z = zeros(1)
    none = Union{Float64, Nothing}[nothing]
    return StructuralSynthesizer.ElfCase(
        direction, :drift, :none, 0.1, 1.0, 1.0,
        z, [Vx], z, z, z, [Δe], z, none, none, none)
end

@testset "story_stability_records" begin
    level = _stability_level(; px_kN=1000.0, story_height_m=4.0)
    # Two x drift cases (the larger drift governs) and one y case.
    cases = [_stability_drift_case(:x, 50.0, 0.008),
             _stability_drift_case(:x, 50.0, 0.010),
             _stability_drift_case(:y, 40.0, 0.006)]
    analysis = StructuralSynthesizer.ElfStoryAnalysis(
        [level], cases, (1.0, 0.0), Vector{Vector{Float64}}())

    records = StructuralSynthesizer.story_stability_records(analysis)
    @test Set(keys(records)) == Set([(1, :x), (1, :y)])

    rx = records[(1, :x)]
    # Governing x case: the 0.010 drift, not the 0.008 one.
    @test rx.ΣPu == 1000.0
    @test rx.V == 50.0
    @test rx.Δ == 0.010
    @test rx.L == 4.0
    @test rx.Pmf == 0.0
    # §12.8.7 identity: Q == θ == Px·Δxe/(hsx·Vx) = 1000·0.010/(4·50) = 0.05.
    θx = StructuralSizer.stability_coefficient(1000.0, 4.0, 50.0, 0.010)
    @test StructuralSizer.stability_index(rx) ≈ θx
    @test StructuralSizer.stability_index(rx) ≈ 0.05

    ry = records[(1, :y)]
    @test ry.V == 40.0
    @test ry.Δ == 0.006
    θy = StructuralSizer.stability_coefficient(1000.0, 4.0, 40.0, 0.006)
    @test StructuralSizer.stability_index(ry) ≈ θy
    @test StructuralSizer.stability_index(ry) ≈ 0.00375 * 10  # 0.0375

    # pmf_fraction scales Pmf = fraction · Px for the AISC RM factor.
    with_mf = StructuralSynthesizer.story_stability_records(analysis; pmf_fraction=0.3)
    @test with_mf[(1, :x)].Pmf ≈ 300.0

    # Zero story shear in a direction yields no record for it.
    only_x = StructuralSynthesizer.ElfStoryAnalysis(
        [level], [_stability_drift_case(:x, 50.0, 0.010)], (1.0, 0.0),
        Vector{Vector{Float64}}())
    @test Set(keys(StructuralSynthesizer.story_stability_records(only_x))) == Set([(1, :x)])

    @test_throws ArgumentError StructuralSynthesizer.story_stability_records(
        analysis; pmf_fraction=1.5)
end
