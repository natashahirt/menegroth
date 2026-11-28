# =============================================================================
# Flat plate analysed on the building model — FEA(source = :building)
#
#   - flat-plate floors are meshed into the building model as loaded shells,
#     and the cell edges between their panels carry no frame stiffness;
#   - each slab reads its column joint forces and strip moments from that
#     model, and the joint shears sum to the same floor load as the per-slab
#     FEA (`FEA(source = :slab)`);
#   - strip moments and interior shears stay close to the per-slab FEA;
#   - `flat_plate_analysis = :options` leaves the floors unmeshed.
#
# Run standalone:
#   julia scripts/runners/test_quiet.jl StructuralSynthesizer analyze/test_flat_plate_building_fea.jl
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Asap
using Test
using Unitful

const _SS_FPB = StructuralSynthesizer
const _SZ_FPB = StructuralSizer

function _fpb_building(mode::Symbol)
    skel = gen_medium_office(36.0u"ft", 28.0u"ft", 10.0u"ft", 2, 2, 2)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        floor = FlatPlateOptions(),
        materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        skip_visualization = true,
        flat_plate_analysis = mode,
    )
    _SS_FPB.prepare!(struc, params)
    return struc, params
end

@testset "Flat plate on the building model" begin
    struc, params = _fpb_building(:building)
    model = struc.asap_model
    layout = _SS_FPB.flat_plate_shell_layout(struc)

    @testset "floors are loaded shells; interior cell edges are inert" begin
        @test layout !== nothing
        @test !isempty(model.shell_elements)
        @test all(s -> _SZ_FPB.building_fea_available(struc, s), struc.slabs)
        @test any(ld -> ld isa Asap.AreaLoad, model.loads)
        fp_cells = Dict(ci => 0 for ci in keys(layout.cell_shells))
        inert = _SS_FPB._flat_plate_inert_edges(struc, fp_cells)
        @test !isempty(inert)
        for e in inert
            @test ustrip(u"m^2", model.frame_elements[e].section.A) == 0.0
        end
    end

    fc = NWC_4000.fc′
    γ = NWC_4000.ρ
    Ecs = _SZ_FPB.Ec(fc, ustrip(_SZ_FPB.pcf, γ))
    h = 7.0u"inch"
    kipft = _SZ_FPB.kip * u"ft"

    @testset "slab $si matches the per-slab FEA" for (si, slab) in enumerate(struc.slabs)
        cols = _SZ_FPB.find_supporting_columns(struc, Set(slab.cell_indices))
        rb = _SZ_FPB.run_moment_analysis(_SZ_FPB.FEA(source = :building), struc, slab, cols,
                                         h, fc, Ecs, γ; ν_concrete = 0.2)
        rs = _SZ_FPB.run_moment_analysis(_SZ_FPB.FEA(), struc, slab, cols, h, fc, Ecs, γ;
                                         ν_concrete = 0.2)
        @info "slab $si" building_patterns = rb.pattern_loading slab_patterns = rs.pattern_loading
        # Equilibrium: both models carry the same floor load into the columns.
        # Pattern envelopes are per column, so their sum is not a load.
        if !rb.pattern_loading && !rs.pattern_loading
            @test sum(rb.column_shears) ≈ sum(rs.column_shears) rtol = 1e-3
        end
        for f in (:M_neg_int, :M_pos)
            @test ustrip(kipft, getproperty(rb, f)) ≈ ustrip(kipft, getproperty(rs, f)) rtol = 0.15
        end
        # The building's columns shorten and the per-slab stubs barely do,
        # so interior shear moves a little toward the edges.
        for (i, c) in enumerate(cols)
            c.position === :interior || continue
            @test rb.column_shears[i] ≈ rs.column_shears[i] rtol = 0.15
        end
        @test 0.0u"m" < rb.fea_Δ_panel < 2 * rs.fea_Δ_panel
        # The slab's own load cases reuse the building factorization.
        t = @elapsed _SZ_FPB.run_moment_analysis(_SZ_FPB.FEA(source = :building), struc, slab,
                                                  cols, h, fc, Ecs, γ; ν_concrete = 0.2)
        @test t < 5.0
    end

    @testset "a copied model is meshed again" begin
        # The layout map is keyed by the model object. The incremental
        # engine's snapshot is a deepcopy, so the copy has the triangles
        # and not the map. The next sync has to mesh it for the copy's columns.
        copy = _SS_FPB.capture_node_state(struc)
        @test _SS_FPB.flat_plate_shell_layout(copy) === nothing
        col = copy.columns[findfirst(c -> c.c1 !== nothing, copy.columns)]
        col.c1 += 4.0u"inch"
        _SS_FPB.sync_asap!(copy; params)
        layout2 = _SS_FPB.flat_plate_shell_layout(copy)
        @test layout2 !== nothing
        si = first(keys(layout2.thickness))
        @test layout2.columns_key ==
              _SS_FPB._flat_plate_columns_key(copy, keys(layout2.thickness))
        h = Float64(ustrip(u"m", _SS_FPB.thickness(copy.slabs[si])))
        @test layout2.thickness[si] ≈ h
    end

    @testset ":options keeps floors off the building model" begin
        s2, _ = _fpb_building(:options)
        @test _SS_FPB.flat_plate_shell_layout(s2) === nothing
        @test !any(s -> _SZ_FPB.building_fea_available(s2, s), s2.slabs)
    end
end
