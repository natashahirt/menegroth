# A FEA mesh cache is reused only for the geometry key it was acquired with.
# A different key replaces the cache, so a mesh from another slab or an
# earlier column layout is not updated in place.

import StructuralSizer
import StructuralSynthesizer

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

# A column that grows between analyses rebuilds the mesh. The rebuilt cache
# must give the same answer as a fresh cache built at the grown size.
@testset "FEA remesh on column growth" begin
    skel = StructuralSynthesizer.gen_medium_office(24.0u"ft", 20.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = StructuralSynthesizer.BuildingStructure(skel)
    opts = StructuralSizer.FlatPlateOptions(material = StructuralSizer.RC_4000_60,
                                            method = StructuralSizer.FEA(),
                                            cover = 0.75u"inch")
    StructuralSynthesizer.initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0 * Asap.psf)
        cell.live_load = uconvert(u"kN/m^2", 50.0 * Asap.psf)
    end
    for col in struc.columns
        col.c1 = 12.0u"inch"
        col.c2 = 12.0u"inch"
    end
    StructuralSynthesizer.to_asap!(struc)

    slab = struc.slabs[1]
    columns = StructuralSizer.find_supporting_columns(struc, Set(slab.cell_indices))
    fc = 4000.0u"psi"
    γ = StructuralSizer.RC_4000_60.concrete.ρ
    ν = StructuralSizer.RC_4000_60.concrete.ν
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    h = 8.0u"inch"
    method = StructuralSizer.FEA(target_edge = 0.40u"m")
    analyze(cache) = StructuralSizer.run_moment_analysis(
        method, struc, slab, columns, h, fc, Ecs, γ;
        ν_concrete = ν, verbose = false, cache = cache)

    cache = StructuralSizer.FEAModelCache()
    analyze(cache)
    model_12 = cache.model
    key_12 = cache.mesh_key
    @test cache.initialized
    @test key_12 !== nothing

    analyze(cache)
    @test cache.model === model_12
    @test cache.mesh_key == key_12

    columns[1].c1 = 16.0u"inch"
    columns[1].c2 = 16.0u"inch"
    grown = analyze(cache)
    @test cache.model !== model_12
    @test cache.mesh_key != key_12

    fresh = analyze(StructuralSizer.FEAModelCache())
    @test grown.column_shears == fresh.column_shears
    @test grown.unbalanced_moments == fresh.unbalanced_moments

    # Same c1 and c2, circular instead of square: the patch is the
    # equivalent-area square, so the mesh key must change.
    for col in columns
        col.shape = :circular
    end
    key_circ = StructuralSizer.fea_mesh_key(struc, slab, columns;
                                            target_edge = method.target_edge)
    @test key_circ != cache.mesh_key
    @test key_circ[4][1][5] == :circular
end
