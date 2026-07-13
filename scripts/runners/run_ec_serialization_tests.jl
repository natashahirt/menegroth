#!/usr/bin/env julia
"""
    run_ec_serialization_tests.jl

Targeted runner for the embodied-carbon serialization helper (`to_dict`)
and the geometry-hash change (`stories_z` dropped from
`compute_geometry_hash`). Skips the rest of the (slow) StructuralSynthesizer
test suite.

Run via:

    SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \\
        scripts/runners/run_ec_serialization_tests.jl
"""

using Test
using Unitful
using StructuralSynthesizer

const _TEST_DIR = joinpath(dirname(@__DIR__), "..",
                           "StructuralSynthesizer", "test")

@testset "Synthesizer — postprocess EC + geometry hash" begin
    include(joinpath(_TEST_DIR, "core", "test_postprocess_ec.jl"))

    # Inline regression: stories_z is excluded from compute_geometry_hash so
    # cosmetically different stories_z payloads must produce the same hash
    # when the rest of the geometry is identical.
    @testset "compute_geometry_hash ignores stories_z" begin
        # Build a minimal APIInput by directly mutating defaults — saves us
        # from having to spell out every nested @kwdef struct.
        base = APIInput()
        base.units = "m"
        base.vertices = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
        base.edges.beams = [[1, 2]]
        base.supports = [1]
        base.stories_z = [0.0, 3.0]
        h1 = compute_geometry_hash(base)

        with_other_stories = deepcopy(base)
        with_other_stories.stories_z = [0.0, 3.5, 7.0]
        h2 = compute_geometry_hash(with_other_stories)

        no_stories = deepcopy(base)
        no_stories.stories_z = Float64[]
        h3 = compute_geometry_hash(no_stories)

        @test h1 == h2
        @test h1 == h3

        # Sanity: the hash *does* still change when the geometry changes.
        moved = deepcopy(base)
        moved.vertices = [[0.0, 0.0, 0.0], [2.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
        @test compute_geometry_hash(moved) != h1
    end
end
