# Monolithic column self-weight coupling: a steel column group's governing axial
# demand is written as a LINEAR function of every column group's section area via
# exact FE self-weight influence coefficients φ, so the coupled column design is
# one certified MILP instead of a self-weight ratchet. The FE identity itself is
# proven to machine precision in scripts/runners/selfweight_influence_proving_slice.jl;
# here we check the production ASSEMBLY on a real multi-story steel building.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SY = StructuralSynthesizer

"""A small, indeterminate multi-story steel building, initialized and solved."""
function _steel_frame_struc()
    struc = BuildingStructure(gen_medium_office(6.0u"m", 6.0u"m", 3.6u"m", 2, 2, 2))
    initialize!(struc)
    to_asap!(struc)
    size_columns!(struc, SteelColumnOptions(); reanalyze = true)   # install sections + solve
    return struc
end

"""Column-group demands, geometries, catalog, material — as `_size_columns_impl!` builds them."""
function _column_inputs(struc, opts)
    gids, demands, L, Lb, Cb, Kx, Ky =
        SY.member_group_demands(struc; member_edge_group = :columns, resolution = 200)
    geoms = [StructuralSizer.SteelMemberGeometry(l; Lb = lb, Cb = cb, Kx = kx, Ky = ky)
             for (l, lb, cb, kx, ky) in zip(L, Lb, Cb, Kx, Ky)]
    cat = StructuralSizer.steel_column_catalog(opts.section_type, opts.catalog)
    return gids, demands, geoms, cat, opts.material
end

@testset "monolithic self-weight: assembled coupling is well-formed" begin
    struc = _steel_frame_struc()
    opts = SteelColumnOptions()
    gids, demands, geoms, cat, material = _column_inputs(struc, opts)

    coupling = SY.build_column_selfweight_coupling(struc, opts, gids, demands, geoms, cat,
                                                   material; resolution = 200)
    @test coupling !== nothing
    n = length(gids)
    @test coupling.groups == collect(1:n)
    @test coupling.influence !== nothing
    @test length(coupling.influence) == n
    @test all(length(row) == n for row in coupling.influence)
    @test length(coupling.weight) == n
    @test all(length(w) == length(cat) for w in coupling.weight)
    @test all(length(c) == length(cat) for c in coupling.cap)
    # weight[g][s] is the catalog area (m²), identical across groups (shared catalog).
    areas = [ustrip(u"m^2", StructuralSizer.section_area(s)) for s in cat]
    @test all(coupling.weight[g] ≈ areas for g in 1:n)
    # A self-influence is positive (a column's own weight compresses it) and the
    # cap rows are finite and nonnegative.
    @test all(coupling.influence[i][i] > 0 for i in 1:n)
    @test all(all(isfinite, c) && all(≥(0.0), c) for c in coupling.cap)
end

@testset "monolithic self-weight: φ reproduces a fresh re-solve exactly (pure load change)" begin
    struc = _steel_frame_struc()
    opts = SteelColumnOptions()
    gids, demands, geoms, cat, material = _column_inputs(struc, opts)
    coupling = SY.build_column_selfweight_coupling(struc, opts, gids, demands, geoms, cat,
                                                   material; resolution = 200)
    @test coupling !== nothing
    n = length(gids)

    # Per-group current area (matches the builder's `area_cur`: the Asap element
    # section area GravityLoad uses).
    group_els = SY._column_group_frame_elements(struc, gids)
    area_cur = [ustrip(u"m^2", struc.asap_model.frame_elements[first(group_els[g])].section.A)
                for g in 1:n]
    Pu0 = [d.Pu_c for d in demands]

    # Scaling one group's GravityLoad `factor` scales its self-weight by (1+ε) with
    # the stiffness matrix UNCHANGED — a pure load change, for which linear_response
    # (hence φ) is exact. Equivalent to a +ε·area_cur area increment on that group.
    # NOTE: the re-solve MUST reprocess. `solve!(…; reprocess=false)` reuses the
    # cached `P`/`Pf`, so a scaled `GravityLoad.factor` reaches the DISPLACEMENT
    # solve only through `process!` (which reassembles the load vectors). The real
    # sizing loop reprocesses on every section change, so φ's redistribution term
    # is exact there; here we reprocess by hand to emulate a genuine section change.
    grav_by_el = Dict{UInt, Asap.GravityLoad}()
    for ld in struc.asap_model.loads
        ld isa Asap.GravityLoad && (grav_by_el[ld.element.elementID] = ld)
    end

    ε = 0.05
    g0 = argmax(area_cur)              # perturb the heaviest group (largest signal)
    touched = Asap.GravityLoad[]
    for i in group_els[g0]
        el = struc.asap_model.frame_elements[i]
        ld = get(grav_by_el, el.elementID, nothing)
        ld === nothing && continue
        ld.factor *= (1 + ε)
        push!(touched, ld)
    end
    # reprocess=true reassembles P/Pf from the scaled self-weight (same K).
    Asap.solve!(struc.asap_model, struc.asap_rigid_links; reprocess = true)
    _, demands_p, = SY.member_group_demands(struc; member_edge_group = :columns, resolution = 200)
    # Restore so the fixture is pristine for any later use.
    for ld in touched
        ld.factor /= (1 + ε)
    end
    Asap.solve!(struc.asap_model, struc.asap_rigid_links; reprocess = true)

    max_relerr = 0.0
    for i in 1:n
        Δtruth = demands_p[i].Pu_c - Pu0[i]
        Δpred = ε * area_cur[g0] * coupling.influence[i][g0]
        max_relerr = max(max_relerr, abs(Δpred - Δtruth) / max(abs(Δtruth), 1.0))
    end
    @test max_relerr < 1e-6
end

@testset "monolithic self-weight: flag off is byte-identical (single call)" begin
    s_off = _steel_frame_struc()
    s_def = _steel_frame_struc()
    opts = SteelColumnOptions()
    SY.update_analysis!(s_off, :stiffness)
    SY.update_analysis!(s_def, :stiffness)
    size_columns!(s_off, opts; reanalyze = false, monolithic_selfweight = false)
    size_columns!(s_def, opts; reanalyze = false)   # default is off
    for (a, b) in zip(s_off.columns, s_def.columns)
        @test SY._sections_identical(section(a), section(b))
    end
end

@testset "monolithic self-weight: coupled column design is self-consistent in one pass" begin
    struc = _steel_frame_struc()
    opts = SteelColumnOptions()
    # One monolithic column solve, then re-solve on the chosen sections.
    size_columns!(struc, opts; reanalyze = true, monolithic_selfweight = true)
    before = [section(c) for c in struc.columns]
    # A SECOND monolithic solve on the self-consistent design must not move any
    # section: the first pass already accounted for every column's self-weight
    # (the whole point of the coupling — no ratchet).
    size_columns!(struc, opts; reanalyze = true, monolithic_selfweight = true)
    after = [section(c) for c in struc.columns]
    @test all(SY._sections_identical(a, b) for (a, b) in zip(before, after))

    # Safety: every installed column group carries its own self-consistent demand
    # (the fresh FE axial on the installed sections passes the AISC check).
    gids, demands, geoms, cat, material = _column_inputs(struc, opts)
    checker = StructuralSizer.AISCChecker(; max_depth = opts.max_depth)
    cache = StructuralSizer.create_cache(checker, length(cat))
    StructuralSizer.precompute_capacities!(checker, cache, cat, material, StructuralSizer.MinVolume())
    for (i, gid) in enumerate(gids)
        # The installed section lives on the group's columns; `_column_inputs`
        # just rebuilt `member_groups` via `member_group_demands`, which does not
        # re-stamp `.section`, so read it from the member itself.
        m_idx = first(struc.member_groups[gid].member_indices)
        sec = section(struc.columns[m_idx])
        j = findfirst(c -> c.name == sec.name, cat)
        @test j !== nothing
        @test StructuralSizer.is_feasible(checker, cache, j, cat[j], material, demands[i], geoms[i])
    end
end
