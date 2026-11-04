# A FEA mesh cache is reused only for the geometry key it was acquired with.
# A different key replaces the cache, so a mesh from another slab or an
# earlier column layout is not updated in place.
# The remesh-on-column-growth check needs a building fixture and lives in
# StructuralSynthesizer/test/sizing/slabs/test_fea_remesh.jl.

import StructuralSizer

@testset "FEA mesh cache key" begin
    caches = Dict{Symbol, Any}()
    first = StructuralSizer.acquire_fea_cache!(caches, (:slab_a, 1))
    first.initialized = true

    again = StructuralSizer.acquire_fea_cache!(caches, (:slab_a, 1))
    @test again === first
    @test again.initialized
    @test again.mesh_key == (:slab_a, 1)

    other = StructuralSizer.acquire_fea_cache!(caches, (:slab_a, 2))
    @test other !== first
    @test other isa StructuralSizer.FEAModelCache
    @test !other.initialized
    @test other.model === nothing
    @test other.mesh_key == (:slab_a, 2)
    @test caches[:fea] === other

    # An unkeyed cache, including one left by an older session, is not reused.
    stale = StructuralSizer.FEAModelCache()
    stale.initialized = true
    caches[:fea] = stale
    keyed = StructuralSizer.acquire_fea_cache!(caches, (:slab_b,))
    @test keyed !== stale
    @test !keyed.initialized
    @test keyed.model === nothing
    @test caches[:fea] === keyed
end
