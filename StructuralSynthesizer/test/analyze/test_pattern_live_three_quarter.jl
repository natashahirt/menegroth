# Checkerboard live pressure is three-quarters of the full factored live load.
#
# ACI 318-11 §13.7.6.3 (corpus: aci-318-11, page 261) permits three-quarters
# of the full factored live load on alternate panels. §13.7.6.4 (same page)
# keeps the full-load case unscaled. Dead load is not reduced.
#
# Equal-cell envelope tests still pass if patterned live stays at 1.0,
# because a full-pressure subset is still a subset. This file fails that wiring.

using Test
using Unitful
using Asap

using StructuralSynthesizer
using StructuralSizer

"""1-story 2×2 flat plate with separated dead and live tributary loads."""
function _three_quarter_plate(; sdl=20.0u"psf", ll=50.0u"psf")
    skel = gen_medium_office(60.0u"ft", 60.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    opts = FlatPlateOptions(
        material = RC_4000_60,
        method   = DDM(),
        cover    = 0.75u"inch",
        bar_size = 5,
    )
    initialize!(struc; floor_type=:flat_plate, floor_opts=opts)
    for cell in struc.cells
        cell.sdl       = uconvert(u"kN/m^2", sdl)
        cell.live_load = uconvert(u"kN/m^2", ll)
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    return struc
end

_tributaries(case) = [ld for ld in case if ld isa Asap.TributaryLoad]

@testset "Pattern live is three-quarters on alternate panels" begin
    struc = _three_quarter_plate()
    params = DesignParameters(pattern_loading = :checkerboard)
    to_asap!(struc; params)

    stored_dead = Asap.TributaryLoad[]
    stored_live = Asap.TributaryLoad[]
    for (_, loads) in struc.cell_dead_loads
        append!(stored_dead, loads)
    end
    for (_, loads) in struc.cell_live_loads
        append!(stored_live, loads)
    end
    @test !isempty(stored_dead)
    @test !isempty(stored_live)

    p_dead = stored_dead[1].pressure
    p_live = stored_live[1].pressure
    @test all(ld -> ld.pressure ≈ p_dead, stored_dead)
    @test all(ld -> ld.pressure ≈ p_live, stored_live)
    @test p_live > 0.0u"Pa"
    @test p_dead > 0.0u"Pa"
    # Classification below treats these three pressures as distinct.
    @test !(p_dead ≈ p_live)
    @test !(p_dead ≈ 0.75 * p_live)

    cases = StructuralSynthesizer._generate_pattern_cases(struc)
    @test length(cases) == 3
    full, pat_a, pat_b = cases

    # Full case reuses the stored objects at full pressure (§13.7.6.4).
    for src in stored_live
        @test any(ld -> ld === src, full)
        @test !any(ld -> ld === src, pat_a)
        @test !any(ld -> ld === src, pat_b)
    end
    for src in stored_dead
        @test any(ld -> ld === src, full)
        @test any(ld -> ld === src, pat_a)
        @test any(ld -> ld === src, pat_b)
        @test src.pressure ≈ p_dead
    end

    full_tribs = _tributaries(full)
    @test count(ld -> ld.pressure ≈ p_live, full_tribs) == length(stored_live)
    @test count(ld -> ld.pressure ≈ p_dead, full_tribs) == length(stored_dead)
    @test count(ld -> ld.pressure ≈ 0.75 * p_live, full_tribs) == 0

    # Alternate panels: every patterned live tributary is a new load at 3/4.
    n_pat = 0
    for case in (pat_a, pat_b)
        tribs = _tributaries(case)
        n_live_pat = count(ld -> ld.pressure ≈ 0.75 * p_live, tribs)
        n_dead_pat = count(ld -> ld.pressure ≈ p_dead, tribs)
        @test n_live_pat > 0
        @test n_live_pat < length(stored_live)
        @test n_dead_pat == length(stored_dead)
        @test n_live_pat + n_dead_pat == length(tribs)
        @test count(ld -> ld.pressure ≈ p_live, tribs) == 0
        n_pat += n_live_pat
    end
    @test n_pat == length(stored_live)

    # Self-weight copies, when present, use the same factor on every case.
    gfactor(case) = [ld.factor for ld in case if ld isa Asap.GravityLoad]
    @test gfactor(pat_a) == gfactor(full)
    @test gfactor(pat_b) == gfactor(full)
end
