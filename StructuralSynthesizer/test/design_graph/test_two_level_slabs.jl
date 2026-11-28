# Shared-column floors size in two levels: each slab proposes on a private
# copy, one envelope adopts the governing column, then every slab commits
# against that column. A floor that is already one slab per story keeps the
# single level.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

struct _SteelSection
    id::Int
    As_total
end

mutable struct _ColBase
    section
    volumes
end

mutable struct _Col
    c1
    c2
    shape
    base::_ColBase
end

function _support(idx, c1, c2, As; id = idx)
    StructuralSizer.FloorSupportUpdate(
        idx, c1, c2, :rectangular, _SteelSection(id, As), nothing)
end

function _office(nx, ny, nstories; grouping = :by_floor, method = DDM())
    span = 20.0u"ft"
    skel = gen_medium_office(span * nx, span * ny, 12.0u"ft", nx, ny, nstories)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name = "two_level_slabs",
        floor = FlatPlateOptions(method = method, grouping = grouping),
        materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        loads = GravityLoads(
            floor_LL = 125.0u"psf", roof_LL = 125.0u"psf",
            floor_SDL = 40.0u"psf", roof_SDL = 40.0u"psf"),
        # A 20 ft bay at this load drives the column to its 30 inch cap, then
        # thickens the slab. Five iterations stop at a punching ratio of about
        # 1.2; the production default of 20 finishes the thickening.
        max_iterations = 20,
        skip_visualization = true,
    )
    return struc, params
end

@testset "governing column is order-independent" begin
    current = (10.0u"inch", 20.0u"inch", _SteelSection(0, 1.0u"inch^2"))
    wide = _support(1, 14.0u"inch", 20.0u"inch", 1.0u"inch^2"; id = 1)
    tall = _support(2, 11.0u"inch", 22.0u"inch", 4.0u"inch^2"; id = 2)
    shrinks = _support(3, 12.0u"inch", 16.0u"inch", 9.0u"inch^2"; id = 3)
    labeled = [(5, tall), (2, wide), (9, shrinks)]
    chosen = StructuralSynthesizer._governing_support_update(
        current..., labeled)
    @test chosen.section.id == 1
    reversed = StructuralSynthesizer._governing_support_update(
        current..., reverse(labeled))
    @test reversed.section.id == chosen.section.id

    same = [
        (5, _support(5, 12.0u"inch", 18.0u"inch", 1.0u"inch^2"; id = 5)),
        (2, _support(2, 12.0u"inch", 18.0u"inch", 1.0u"inch^2"; id = 2)),
    ]
    tie = StructuralSynthesizer._governing_support_update(
        10.0u"inch", 10.0u"inch", _SteelSection(0, 1.0u"inch^2"), same)
    @test tie.section.id == 2
    heavier = StructuralSynthesizer._governing_support_update(
        12.0u"inch", 18.0u"inch", _SteelSection(0, 1.0u"inch^2"),
        [(2, _support(2, 12.0u"inch", 18.0u"inch", 2.0u"inch^2"; id = 7))])
    @test heavier.section.id == 7
    @test StructuralSynthesizer._governing_support_update(
        12.0u"inch", 18.0u"inch", _SteelSection(0, 2.0u"inch^2"),
        [(2, _support(2, 12.0u"inch", 18.0u"inch", 2.0u"inch^2"; id = 7))]) === nothing
    @test StructuralSynthesizer._governing_support_update(
        10.0u"inch", 10.0u"inch", _SteelSection(0, 1.0u"inch^2"),
        [(1, _support(1, 8.0u"inch", 8.0u"inch", 5.0u"inch^2"))]) === nothing

    col = _Col(10.0u"inch", 10.0u"inch", :rectangular,
               _ColBase(_SteelSection(1, 1.0u"inch^2"), [1.0]))
    StructuralSynthesizer._install_governing_support!(
        col, StructuralSizer.FloorSupportUpdate(
            1, 14.0u"inch", 14.0u"inch", :rectangular, nothing, nothing))
    @test col.c1 == 10.0u"inch"
    @test col.base.section.id == 1
end

@testset "one slab per story stays a single level" begin
    struc, params = _office(1, 1, 1)
    prepare!(struc, params)
    g = build_design_graph(struc, params)
    @test !haskey(g.index, StructuralSynthesizer.NODE_SLAB_ENVELOPE)
    @test haskey(g.index, StructuralSynthesizer.slab_node_key(1))

    struc2, params2 = _office(1, 1, 2)
    prepare!(struc2, params2)
    @test length(struc2.slabs) == 2
    g2 = build_design_graph(struc2, params2)
    @test !haskey(g2.index, StructuralSynthesizer.NODE_SLAB_ENVELOPE)
    @test StructuralSynthesizer.dependencies(
        StructuralSynthesizer.get_node(g2, StructuralSynthesizer.NODE_MEMBERS)) ==
          [StructuralSynthesizer.slab_node_key(i) for i in 1:2]
end

@testset "two-by-two individual flat plate designs from the column envelope" begin
    struc_g, params = _office(2, 2, 1; grouping = :individual, method = FEA())
    prepare!(struc_g, params)
    n = length(struc_g.slabs)
    @test n == 4
    @test StructuralSynthesizer._flat_plate_slabs_share_columns(struc_g)
    prepared = [(col.c1, col.c2) for col in struc_g.columns]
    g = build_design_graph(struc_g, params)
    @test StructuralSynthesizer.dependencies(
        StructuralSynthesizer.get_node(g, StructuralSynthesizer.NODE_SLAB_ENVELOPE)) ==
          [StructuralSynthesizer.slab_propose_key(i) for i in 1:n]
    @test StructuralSynthesizer.dependencies(
        StructuralSynthesizer.get_node(g, StructuralSynthesizer.NODE_MEMBERS)) ==
          [StructuralSynthesizer.NODE_SLAB_LOCK]
    for i in 1:n
        @test StructuralSynthesizer.dependencies(
            StructuralSynthesizer.get_node(g, StructuralSynthesizer.slab_node_key(i))) ==
              [StructuralSynthesizer.NODE_SLAB_ENVELOPE]
    end

    struc_d, params_d = _office(2, 2, 1; grouping = :individual, method = FEA())
    design = design_building(struc_d, params_d; restore = false)
    @test length(design.slabs) == n
    @test all(s -> s.thickness > 0.0u"m", values(design.slabs))
    grew = false
    for (i, col) in enumerate(design.structure.columns)
        @test col.c1 + 1.0e-6u"inch" >= prepared[i][1]
        @test col.c2 + 1.0e-6u"inch" >= prepared[i][2]
        col.base.section === nothing && continue
        if col.c1 > prepared[i][1] + 0.05u"inch" || col.c2 > prepared[i][2] + 0.05u"inch"
            grew = true
        end
    end
    @test grew
end
