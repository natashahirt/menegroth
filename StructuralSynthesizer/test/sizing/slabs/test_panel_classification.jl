# A panel with no direction is one-way when its long side is more than twice
# its short side, and two-way otherwise (ACI 318-19 R8.3.1.2, corpus:
# aci-318-19, PDF p. 103). A direction forces one-way along that direction.
#
# The design pass only sets the minimum thickness. Moments, bars, and shear
# wait on the analysis method.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

function _panel(x, y; axis=nothing)
    skel = gen_medium_office(x, y, 12.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    initialize!(struc; floor_type=:auto, tributary_axis=axis)
    return struc
end

@testset "Concrete panel classification" begin
    @testset "Long bay is one-way on the short span" begin
        struc = _panel(40.0u"ft", 10.0u"ft")
        @test length(struc.slabs) == 1
        slab = only(struc.slabs)
        @test slab.floor_type == :one_way
        @test isapprox(uconvert(u"ft", slab.spans.primary), 10.0u"ft"; atol=0.05u"ft")
        design_floors!(struc; options=OneWayOptions())
        r = only(struc.slabs).result
        @test r isa StructuralSizer.CIPSlabResult
        # One bay with beams on both ends is simply supported. ACI 318-19
        # Table 7.3.1.1 (corpus: aci-318-19, page 92): ℓ/20. The generator
        # stores the bay a few millimetres over 10 ft, so ℓ/20 is just over
        # 6 in and the half-inch roundup lands on 6.5 in.
        @test StructuralSizer._slab_span_support(struc, slab) == StructuralSizer.SIMPLE
        raw = StructuralSizer.min_thickness(StructuralSizer.OneWay(), slab.spans.primary;
                                            support = StructuralSizer.SIMPLE)
        @test ustrip(u"inch", raw) ≈ 6.0 atol = 0.1
        expect = ceil(ustrip(u"inch", raw) * 2) / 2 * u"inch"
        @test isapprox(uconvert(u"inch", r.thickness), expect; atol=0.01u"inch")
        # Only a thickness was set. The slab must not claim an analysis.
        dd = only(struc.slabs).design_details
        @test dd.analysis_status == :not_analyzed
        @test !hasproperty(dd, :method_used)
    end

    @testset "Square bay is two-way" begin
        struc = _panel(20.0u"ft", 20.0u"ft")
        @test only(struc.slabs).floor_type == :two_way
        design_floors!(struc; options=FlatPlateOptions())
        r = only(struc.slabs).result
        @test r isa StructuralSizer.CIPSlabResult
        @test only(struc.slabs).design_details.analysis_status == :not_analyzed
        # ACI 318-11 §9.5.3.3: ln is the long span along a reinforcement axis,
        # 20 ft here, not the 28.3 ft diagonal. Beams are not sized, so the
        # bound is 1.1 × ln(0.8 + 60/200)/36 = 8.07 in, rounded up to 8.5 in.
        @test isapprox(uconvert(u"inch", r.thickness), 8.5u"inch"; atol=0.01u"inch")
    end

    @testset "A direction forces one-way" begin
        struc = _panel(20.0u"ft", 20.0u"ft"; axis=(0.0, 1.0))
        slab = only(struc.slabs)
        @test slab.floor_type == :one_way
        @test isapprox(uconvert(u"ft", slab.spans.primary), 20.0u"ft"; atol=0.05u"ft")
        @test abs(slab.spans.axis[2]) > 0.9
    end

    @testset "Continuity along the span allows a thinner slab" begin
        # Two 10 ft bays in the span direction. Each bay runs past the shared
        # beam at one end, so Table 7.3.1.1 uses ℓ/24 rather than ℓ/20.
        # A longer single bay is thicker still.
        function designed(ny, span)
            skel = gen_medium_office(40.0u"ft", span * ny, 12.0u"ft", 1, ny, 1)
            struc = BuildingStructure(skel)
            initialize!(struc; floor_type=:one_way, floor_opts=OneWayOptions())
            design_floors!(struc; options=OneWayOptions())
            return struc
        end
        one = designed(1, 10.0u"ft")
        two = designed(2, 10.0u"ft")
        long = designed(1, 16.0u"ft")
        single = only(s for s in one.slabs if s.floor_type == :one_way)
        pair = [s for s in two.slabs if s.floor_type == :one_way]
        longer = only(s for s in long.slabs if s.floor_type == :one_way)
        @test StructuralSizer._slab_span_support(one, single) == StructuralSizer.SIMPLE
        @test all(s -> StructuralSizer._slab_span_support(two, s) == StructuralSizer.ONE_END_CONT, pair)
        @test all(s -> s.result.thickness < single.result.thickness, pair)
        @test longer.result.thickness > single.result.thickness
    end

    @testset "A skewed bay is carried by its beams" begin
        # Every edge is within 30° of the span axis, so none of them faces
        # the span. The beams are still there. ACI 318-11 Table 9.5(a)
        # (corpus: aci-318-11, page 131): supports on both sides, and no
        # continuity, is a simple span.
        skel = BuildingSkeleton{Float64}()
        corners = [(0.0, 0.0), (4.0, 1.0), (6.0, 0.0), (2.0, -1.0)]
        vs = [add_vertex!(skel, [x, y, 3.0]) for (x, y) in corners]
        for k in 1:4
            add_element!(skel, vs[k], vs[mod1(k + 1, 4)]; group = :beams)
        end
        rebuild_stories!(skel)
        find_faces!(skel)
        rebuild_geometry_cache!(skel)
        struc = BuildingStructure(skel)
        spans = SpanInfo{Float64}(6.0, 2.0, (1.0, 0.0), 2.0)
        fidx = findfirst(f -> Set(f) == Set(vs), skel.face_vertex_indices)
        @test fidx !== nothing
        cell = Cell(fidx, 6.0u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
        cell.floor_type = :one_way
        push!(struc.cells, cell)
        push!(struc.slabs, Slab([1], StructuralSizer.CIPSlabResult(0.2, 0.2, 5.0),
                                 spans; floor_type = :one_way))
        @test StructuralSizer._slab_span_support(struc, only(struc.slabs)) ==
              StructuralSizer.SIMPLE
    end
end
