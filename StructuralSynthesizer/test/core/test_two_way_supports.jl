# A :two_way panel is classified from its supports before sizing.
# No beams: flat plate. Walls on every side: two-way, stiff-support thickness.
# A gap on an interior beam line throws. A missing building-edge beam stays
# two-way and carries ACI 318-11 §9.5.3.3(d)'s 10%.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

function _roof_beam_split(skel)
    StructuralSynthesizer.rebuild_geometry_cache!(skel)
    vc = skel.geometry.vertex_coords
    beams = skel.groups_edges[:beams]
    mids = Dict{Int, NTuple{3, Float64}}()
    for e in beams
        i, j = skel.edge_indices[e]
        mids[e] = ((vc[i, 1] + vc[j, 1]) / 2,
                   (vc[i, 2] + vc[j, 2]) / 2,
                   (vc[i, 3] + vc[j, 3]) / 2)
    end
    zmax = maximum(mid[3] for mid in values(mids))
    roof = [e for (e, mid) in mids if abs(mid[3] - zmax) <= 1e-3]
    xs = [mids[e][1] for e in roof]
    ys = [mids[e][2] for e in roof]
    xmin, xmax = extrema(xs)
    ymin, ymax = extrema(ys)
    interior = Int[]
    exterior = Int[]
    for e in roof
        x, y, _ = mids[e]
        on_box = abs(x - xmin) <= 1e-3 || abs(x - xmax) <= 1e-3 ||
                 abs(y - ymin) <= 1e-3 || abs(y - ymax) <= 1e-3
        push!(on_box ? exterior : interior, e)
    end
    return interior, exterior
end

function _drop_beams!(skel, edges)
    drop = Set(edges)
    skel.groups_edges[:beams] = filter(e -> e ∉ drop, skel.groups_edges[:beams])
    return skel
end

"""Plan line of an edge, so a pier below a slab can be matched to the slab edge."""
function _plan_key(skel, edge)
    i, j = skel.edge_indices[edge]
    vc = skel.geometry.vertex_coords
    a = (round(vc[i, 1]; digits=4), round(vc[i, 2]; digits=4))
    b = (round(vc[j, 1]; digits=4), round(vc[j, 2]; digits=4))
    return a <= b ? (a, b) : (b, a)
end

"""
Drop the roof beams and stand walls on the story below the chosen roof edges.
A roof edge cannot be a wall: the pier lives on the story underneath and
runs up to the slab.
"""
function _walls_under_roof!(skel, roof_edges)
    StructuralSynthesizer.rebuild_geometry_cache!(skel)
    want = Set(_plan_key(skel, e) for e in roof_edges)
    ground = Int[]
    for e in skel.groups_edges[:beams]
        e in roof_edges && continue
        _plan_key(skel, e) in want && push!(ground, e)
    end
    interior, exterior = _roof_beam_split(skel)
    _drop_beams!(skel, vcat(interior, exterior, ground))
    skel.groups_edges[:walls] = ground
    return skel
end

function _expected_two_way_inches(slab; wall_supported=false, missing_edge_beam=false)
    ln = max(slab.spans.primary, slab.spans.secondary)
    short = min(slab.spans.primary, slab.spans.secondary)
    beta = ln / short
    h_min = min_thickness(TwoWay(), ln; fy=60000u"psi", beta=beta,
                          wall_supported=wall_supported,
                          missing_edge_beam=missing_edge_beam)
    return ceil(ustrip(u"inch", h_min) * 2) / 2
end

@testset "two-way support classification" begin
    @testset "columns alone become a flat plate" begin
        skel = gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 1, 1, 1)
        skel.groups_edges[:slab_edges] = pop!(skel.groups_edges, :beams)
        struc = BuildingStructure(skel)
        initialize!(struc; floor_type=:two_way, floor_opts=TwoWayOptions())
        @test all(s -> s.floor_type == :flat_plate, struc.slabs)
        @test any(c -> c.floor_type == :flat_plate, struc.cells)
        @test all(c -> c.floor_type in (:flat_plate, :grade), struc.cells)
    end

    @testset "a multi-bay beamless floor is one flat plate" begin
        # Flat plate grouping is one slab per story. Nine panels would each be
        # a one-span frame, and ACI 318-11 §13.6.1.1 would refuse the floor.
        skel = gen_medium_office(18.0u"ft" * 3, 14.0u"ft" * 3, 12.0u"ft", 3, 3, 1)
        skel.groups_edges[:slab_edges] = pop!(skel.groups_edges, :beams)
        struc = BuildingStructure(skel)
        initialize!(struc; floor_type=:two_way, floor_opts=TwoWayOptions())
        slab = only(struc.slabs)
        @test slab.floor_type == :flat_plate
        @test length(slab.cell_indices) == 9
        @test all(c -> c.floor_type in (:flat_plate, :grade), struc.cells)
    end

    @testset "columns and one wall stay a flat plate" begin
        skel = gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 1, 1, 1)
        _, exterior = _roof_beam_split(skel)
        _walls_under_roof!(skel, [first(exterior)])
        struc = BuildingStructure(skel)
        initialize!(struc; floor_type=:two_way, floor_opts=TwoWayOptions(),
                    wall_thickness=0.3u"m")
        @test all(s -> s.floor_type == :flat_plate, struc.slabs)
    end

    @testset "walls on every side stay two-way" begin
        skel = gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 1, 1, 1)
        interior, exterior = _roof_beam_split(skel)
        _walls_under_roof!(skel, vcat(interior, exterior))
        struc = BuildingStructure(skel)
        initialize!(struc; floor_type=:two_way, floor_opts=TwoWayOptions(),
                    wall_thickness=0.3u"m")
        slab = only(struc.slabs)
        @test slab.floor_type == :two_way
        @test isapprox(ustrip(u"inch", slab.result.thickness),
                       _expected_two_way_inches(slab; wall_supported=true); atol=0.01)
        design_floors!(struc; options=TwoWayOptions())
        @test only(struc.slabs).design_details.wall_supported
        @test !only(struc.slabs).design_details.missing_edge_beam
    end

    @testset "a full beam grid stays two-way" begin
        skel = gen_medium_office(20.0u"ft", 20.0u"ft", 12.0u"ft", 1, 1, 1)
        struc = BuildingStructure(skel)
        initialize!(struc; floor_type=:auto)
        slab = only(struc.slabs)
        @test slab.floor_type == :two_way
        # Beams are not sized yet, so this is the unknown-αfm bound: 8.5 in
        # on a 20 ft square, the same thickness as before this classification.
        @test isapprox(uconvert(u"inch", slab.result.thickness), 8.5u"inch"; atol=0.05u"inch")
    end

    @testset "a missing interior beam throws" begin
        skel = gen_medium_office(40.0u"ft", 20.0u"ft", 12.0u"ft", 2, 1, 1)
        interior, _ = _roof_beam_split(skel)
        @test !isempty(interior)
        _drop_beams!(skel, interior)
        struc = BuildingStructure(skel)
        err = try
            initialize!(struc; floor_type=:two_way, floor_opts=TwoWayOptions())
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("interior edge", sprint(showerror, err))
    end

    @testset "a missing building-edge beam is allowed" begin
        skel = gen_medium_office(40.0u"ft", 20.0u"ft", 12.0u"ft", 2, 1, 1)
        _, exterior = _roof_beam_split(skel)
        @test !isempty(exterior)
        _drop_beams!(skel, exterior)
        struc = BuildingStructure(skel)
        initialize!(struc; floor_type=:two_way, floor_opts=TwoWayOptions())
        @test all(s -> s.floor_type == :two_way, struc.slabs)
        design_floors!(struc; options=TwoWayOptions())
        @test all(s -> s.design_details.missing_edge_beam, struc.slabs)
        @test all(s -> !s.design_details.wall_supported, struc.slabs)
    end

    @testset "planned joists keep a beamless two-way slab" begin
        skel = gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 1, 1, 1)
        skel.groups_edges[:slab_edges] = pop!(skel.groups_edges, :beams)
        struc = BuildingStructure(skel)
        initialize!(struc; floor_type=:two_way, floor_opts=TwoWayOptions(),
                    joists_planned=true, topping_span=30.0u"inch")
        slab = only(struc.slabs)
        @test slab.floor_type == :two_way
        @test slab.design_details.topping_span == 30.0u"inch"
        # 30 in centers, 4 in minimum rib: clear 26 in, §8.13.6.1, rounded to 1/2 in.
        @test uconvert(u"inch", slab.result.thickness) ≈ 2.5u"inch"

        skel_ow = gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 1, 1, 1)
        skel_ow.groups_edges[:slab_edges] = pop!(skel_ow.groups_edges, :beams)
        struc_ow = BuildingStructure(skel_ow)
        initialize!(struc_ow; floor_type=:one_way, floor_opts=OneWayOptions(),
                    joists_planned=true, topping_span=30.0u"inch")
        @test only(struc_ow.slabs).floor_type == :one_way
    end

    @testset "preparation flat plate is the code minimum thickness" begin
        span = 20.0u"ft"
        c1 = StructuralSizer.estimate_column_size_from_span(span; ratio=15.0)
        ln = StructuralSizer.clear_span(span, c1)
        h_min = StructuralSizer.min_thickness(StructuralSizer.FlatPlate(), ln;
                                              discontinuous_edge=true)
        h = ceil(ustrip(u"inch", h_min) * 2) / 2
        thin = StructuralSizer._size_span_floor(
            StructuralSizer.FlatPlate(), span, 40.0u"psf", 125.0u"psf";
            position=:edge, thickness_only=true)
        full = StructuralSizer._size_span_floor(
            StructuralSizer.FlatPlate(), span, 40.0u"psf", 125.0u"psf";
            position=:edge)
        @test isapprox(ustrip(u"inch", thin.thickness), h; atol=0.01)
        @test thin.thickness <= full.thickness
        opts = StructuralSizer.ConcreteBeamOptions()
        @test opts.uniform_geometry == false
        @test opts.rib_form == :mip
        @test_throws ArgumentError StructuralSynthesizer._require_known_rib_form(
            StructuralSizer.ConcreteBeamOptions(rib_form=:standard_pan))
    end

    @testset "auto on a beamless square bay is a flat plate" begin
        skel = gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 1, 1, 1)
        skel.groups_edges[:slab_edges] = pop!(skel.groups_edges, :beams)
        struc = BuildingStructure(skel)
        initialize!(struc; floor_type=:auto)
        @test only(struc.slabs).floor_type == :flat_plate
    end
end
