# The support classification has to survive design_building, not only initialize!.
# A beamless :two_way request is designed as a flat plate. A beam grid stays
# two-way and sizes its beams. A gap, and a beamless one-way slab, throw
# during preparation.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

function _params(; floor, columns=nothing, wall_thickness=nothing)
    DesignParameters(
        name = "two_way_support_pipeline",
        floor = floor,
        columns = columns,
        materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        max_iterations = 3,
        skip_visualization = true,
        wall_thickness = wall_thickness,
    )
end

"""Stand walls on the story below every roof beam, and remove the beam grid."""
function _walls_on_every_roof_edge!(skel)
    StructuralSynthesizer.rebuild_geometry_cache!(skel)
    vc = skel.geometry.vertex_coords
    function plan_key(edge)
        i, j = skel.edge_indices[edge]
        a = (round(vc[i, 1]; digits=4), round(vc[i, 2]; digits=4))
        b = (round(vc[j, 1]; digits=4), round(vc[j, 2]; digits=4))
        return a <= b ? (a, b) : (b, a)
    end
    beams = skel.groups_edges[:beams]
    zmax = maximum((vc[skel.edge_indices[e][1], 3] + vc[skel.edge_indices[e][2], 3]) / 2
                   for e in beams)
    roof = [e for e in beams
            if abs((vc[skel.edge_indices[e][1], 3] + vc[skel.edge_indices[e][2], 3]) / 2 - zmax) <= 1e-3]
    want = Set(plan_key(e) for e in roof)
    ground = [e for e in beams if e ∉ roof && plan_key(e) in want]
    skel.groups_edges[:beams] = filter(e -> e ∉ Set(vcat(roof, ground)), beams)
    skel.groups_edges[:walls] = ground
    return skel
end

function _beamless(x_bays, y_bays)
    skel = gen_medium_office(18.0u"ft" * x_bays, 14.0u"ft" * y_bays, 12.0u"ft",
                             x_bays, y_bays, 1)
    skel.groups_edges[:slab_edges] = pop!(skel.groups_edges, :beams)
    return BuildingStructure(skel)
end

@testset "two-way support pipeline" begin
    @testset "a beamless two-way building is designed as a flat plate" begin
        # Three spans each way, so the direct design method applies.
        struc = _beamless(3, 3)
        design = design_building(struc, _params(floor = TwoWayOptions()); restore = false)
        # One slab for the story, the flat-plate grouping. Nine separate bays
        # would each be a one-span frame and the direct design method would refuse them.
        slab = only(struc.slabs)
        @test slab.floor_type == :flat_plate
        @test length(slab.cell_indices) == 9
        @test slab.design_details !== nothing
        @test !isempty(struc.columns)
        # Flat-plate reconciliation writes a concrete section. The office
        # wireframe still has its lines: member init makes a Beam for every
        # edge that is not a column, a brace, or a wall. They are not in
        # :beams, so the beam stage does not size them.
        @test all(c -> c.base.section isa StructuralSizer.RCColumnSection ||
                       c.base.section isa StructuralSizer.RCCircularSection,
                  struc.columns)
        @test all(b -> b.base.section === nothing, struc.beams)
        @test !any(d -> occursin("beam sizing", d), design.diagnostics)
    end

    @testset "walls on every side stay two-way through the building" begin
        skel = gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 1, 1, 1)
        _walls_on_every_roof_edge!(skel)
        struc = BuildingStructure(skel)
        design = design_building(struc, _params(floor = TwoWayOptions(),
                                                wall_thickness = 0.3u"m");
                                 restore = false)
        slab = only(struc.slabs)
        @test slab.floor_type == :two_way
        @test slab.design_details.wall_supported
        @test !slab.design_details.missing_edge_beam
        # Roof lines stay in the skeleton and become unsized girders. The piers
        # are the story below, so those lines are not Wall members.
        @test all(b -> b.base.section === nothing, struc.beams)
        @test !isempty(struc.walls)
        @test all(c -> c.base.section isa StructuralSizer.RCColumnSection ||
                       c.base.section isa StructuralSizer.RCCircularSection,
                  struc.columns)
        @test !any(d -> occursin("beam sizing", d), design.diagnostics)
    end

    @testset "a beam grid stays two-way and sizes the beams" begin
        skel = gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 1, 1, 1)
        struc = BuildingStructure(skel)
        design_building(struc, _params(floor = TwoWayOptions()); restore = false)
        @test all(s -> s.floor_type == :two_way, struc.slabs)
        @test !isempty(struc.beams)
        @test all(b -> b.base.section !== nothing, struc.beams)
    end

    @testset "a missing interior beam throws before sizing" begin
        skel = gen_medium_office(36.0u"ft", 18.0u"ft", 12.0u"ft", 2, 1, 1)
        StructuralSynthesizer.rebuild_geometry_cache!(skel)
        vc = skel.geometry.vertex_coords
        roof_z = maximum(skel.stories_z)
        interior = Int[]
        for e in skel.groups_edges[:beams]
            i, j = skel.edge_indices[e]
            z = (vc[i, 3] + vc[j, 3]) / 2
            abs(z - ustrip(u"m", roof_z)) > 1e-3 && continue
            x = (vc[i, 1] + vc[j, 1]) / 2
            y = (vc[i, 2] + vc[j, 2]) / 2
            # The shared line of a 2×1 bay is the only edge off the outer box.
            on_box = x ≈ 0 || y ≈ 0 ||
                     abs(x - ustrip(u"m", 36.0u"ft")) < 1e-2 ||
                     abs(y - ustrip(u"m", 18.0u"ft")) < 1e-2
            on_box || push!(interior, e)
        end
        @test !isempty(interior)
        drop = Set(interior)
        skel.groups_edges[:beams] = filter(e -> e ∉ drop, skel.groups_edges[:beams])
        struc = BuildingStructure(skel)
        @test_throws ArgumentError design_building(struc, _params(floor = TwoWayOptions()))
    end

    @testset "a beamless one-way building still throws" begin
        struc = _beamless(2, 1)
        @test_throws ArgumentError design_building(struc, _params(floor = OneWayOptions()))
    end
end
