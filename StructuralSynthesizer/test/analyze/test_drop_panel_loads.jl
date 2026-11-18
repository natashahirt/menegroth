# =============================================================================
# Drop-Panel Self-Weight Loads
# =============================================================================
#
# The drop projection below the slab soffit enters the building model as a
# column-top nodal dead load (`:drop_panel_self_weight`). Checks:
#   - no drop panel → no loads, no effect
#   - volumes use the sizer's clipped drop outline (interior = full 2a₁ × 2a₂)
#   - Σ force = ρ g Σ V, and the model stores the self-weight dead factor
#   - re-syncing replaces the loads instead of adding a second copy
#   - the per-vertex weights the story-stability fallback reads match

using Test
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer

const _SS = StructuralSynthesizer

function _drop_test_structure()
    skel = gen_medium_office(60.0u"ft", 60.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    opts = FlatPlateOptions(material = RC_4000_60, method = DDM(),
                            cover = 0.75u"inch", bar_size = 5)
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    return struc
end

_drop_loads(model) = [ld for ld in model.loads
                      if ld isa Asap.NodeForce && ld.id === _SS.DROP_PANEL_LOAD_ID]

_fz(ld) = ustrip(u"N", ld.value[3])

@testset "Drop-panel self-weight loads" begin
    struc = _drop_test_structure()
    params = DesignParameters()
    to_asap!(struc; params)

    @testset "no drop panel" begin
        @test !_SS._has_drop_panels(struc)
        @test isempty(_drop_loads(struc.asap_model))
        @test isempty(_SS.unfactored_drop_panel_loads(struc))
        @test isempty(_SS.drop_panel_weights_by_vertex(struc))
        @test _SS._sync_drop_panel_loads!(struc, params) == 0
    end

    # Attach a drop panel and the slab concrete that sets its density.
    dp = StructuralSizer.DropPanelGeometry(4.0u"inch", 5.0u"ft", 5.0u"ft")
    conc = RC_4000_60.concrete
    for slab in struc.slabs
        slab.drop_panel = dp
        slab.volumes[conc] = 1.0u"m^3"
    end

    @testset "volumes follow the sizer's drop outline" begin
        full = uconvert(u"m^3", dp.h_drop * (2dp.a_drop_1) * (2dp.a_drop_2))
        for slab in struc.slabs
            vols = _SS.drop_panel_column_volumes(struc, slab)
            @test !isempty(vols)
            for (v, V) in vols
                @test V > 0.0u"m^3"
                @test V <= full * (1 + 1e-9)
                col = only(c for c in struc.columns if c.vertex_idx == v)
                col.position === :interior && @test V ≈ full rtol = 1e-9
            end
        end
    end

    @testset "Σ force = ρ g Σ V" begin
        ΣV = sum(V for slab in struc.slabs for (_, V) in _SS.drop_panel_column_volumes(struc, slab))
        W = uconvert(u"N", conc.ρ * Asap.GRAVITY * ΣV)
        unf = _SS.unfactored_drop_panel_loads(struc)
        @test !isempty(unf)
        @test all(ld -> _fz(ld) < 0, unf)
        @test -sum(_fz, unf) ≈ ustrip(u"N", W) rtol = 1e-9
        @test sum(values(_SS.drop_panel_weights_by_vertex(struc))) ≈ W rtol = 1e-9
    end

    @testset "sync stores the dead factor and does not duplicate" begin
        n = _SS._sync_drop_panel_loads!(struc, params)
        @test n > 0
        @test length(_drop_loads(struc.asap_model)) == n
        @test _SS._sync_drop_panel_loads!(struc, params) == n
        @test length(_drop_loads(struc.asap_model)) == n

        factor = _SS._self_weight_dead_factor(params;
                                              patterned = _SS._pattern_dead_split(struc, params))
        unf = -sum(_fz, _SS.unfactored_drop_panel_loads(struc))
        @test -sum(_fz, _drop_loads(struc.asap_model)) ≈ factor * unf rtol = 1e-9
    end

    @testset "removing the drop removes its loads" begin
        for slab in struc.slabs
            slab.drop_panel = nothing
        end
        @test _SS._sync_drop_panel_loads!(struc, params) == 0
        @test isempty(_drop_loads(struc.asap_model))
    end
end
