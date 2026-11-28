# A module grid of ribs on any slab outline.
#
# Two orthogonal rib families at an angle are clipped to the slab and to the
# beam rings inside it. Crossing ribs share a node, so the ribs are one frame
# (ACI 318-19 §8.2.1, corpus: aci-318-19, page 101). Each bay the ribs enclose
# puts its own isotropic skeleton on the members around it.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SYM = StructuralSynthesizer

"""An L-shaped bay of edge beams with a ring of beams inside it."""
function _l_slab_with_ring(; z = 3.0)
    skel = BuildingSkeleton{Float64}()
    outline = [(0.0, 0.0), (12.0, 0.0), (12.0, 6.0), (6.0, 6.0), (6.0, 12.0), (0.0, 12.0)]
    ring = [(2.0, 2.0), (4.0, 2.0), (4.0, 4.0), (2.0, 4.0)]
    for loop in (outline, ring)
        vs = [add_vertex!(skel, [x, y, z]) for (x, y) in loop]
        for k in eachindex(vs)
            add_element!(skel, vs[k], vs[mod1(k + 1, length(vs))]; group = :beams)
        end
    end
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    struc = BuildingStructure(skel)
    fidx = argmax(f -> abs(SYM.calculate_signed_area(skel, skel.face_vertex_indices[f])),
                  eachindex(skel.face_vertex_indices))
    spans = SpanInfo{Float64}(12.0, 12.0, (1.0, 0.0), 6.0)
    cell = Cell(fidx, 104.0u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
    cell.floor_type = :one_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab([1], CIPSlabResult(0.2, 0.2, 5.0), spans; floor_type = :one_way))
    initialize_segments!(struc)
    initialize_members!(struc)
    return struc, ring
end

"""Plan segments of every edge of `beams`."""
function _beam_segments(struc, beams)
    skel = struc.skeleton
    out = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    for b in beams, si in b.base.segment_indices
        v1, v2 = skel.edge_indices[struc.segments[si].edge_idx]
        push!(out, (SYM._vertex_xy_m(skel, v1), SYM._vertex_xy_m(skel, v2)))
    end
    return out
end

@testset "module grid of ribs" begin
    @testset "pattern validation" begin
        @test_throws ArgumentError ModularRibPattern(0.0, (0.0, 1.0))
        @test_throws ArgumentError ModularRibPattern(NaN, (1.0, 1.0))
        p = ModularRibPattern(deg2rad(30), (0.9, 1.2), (1.0, 2.0))
        @test SYM.module_area(p) ≈ 1.08
        @test p.origin == (1.0, 2.0)
    end

    @testset "an L-shaped slab with a ring" begin
        struc, ring = _l_slab_with_ring()
        slab = only(struc.slabs)
        level = SYM.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                          pattern = ModularRibPattern(deg2rad(20), (0.9, 0.9)),
                                          material = StructuralSizer.A992_Steel,
                                          analysis = :grillage)
        push!(slab.framing_levels, level)
        joists = @test_logs (:warn, r"smaller than half a module") match_mode = :any SYM.materialize_level!(struc, slab, level)
        @test length(joists) > 20

        # No two rib pieces pass through each other between nodes.
        segs = _beam_segments(struc, joists)
        crossings = 0
        for i in 1:(length(segs) - 1), j in (i + 1):length(segs)
            hit = StructuralSizer._segment_crossing(segs[i][1], segs[i][2],
                                                    segs[j][1], segs[j][2], 1e-6)
            hit === nothing && continue
            t, u = hit
            interior = 1e-6 < t < 1 - 1e-6 && 1e-6 < u < 1 - 1e-6
            crossings += interior
        end
        @test crossings == 0

        # No rib piece is inside the ring or outside the L.
        outline = [(0.0, 0.0), (12.0, 0.0), (12.0, 6.0), (6.0, 6.0), (6.0, 12.0), (0.0, 12.0)]
        for (a, b) in segs
            mid = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
            @test StructuralSizer._inside_loop(mid, outline)
            @test !StructuralSizer._inside_loop(mid, ring)
        end

        # The bays carry the slab less the ring, and the ring beams take a share.
        profiles = SYM.grillage_edge_profiles(struc, slab, level)
        skel = struc.skeleton
        total = 0.0
        ring_area = 0.0
        for (e, (pos, w)) in profiles
            v1, v2 = skel.edge_indices[e]
            p1, p2 = SYM._vertex_xy_m(skel, v1), SYM._vertex_xy_m(skel, v2)
            a = StructuralSizer.tributary_profile_area(hypot((p2 .- p1)...), pos, w)
            total += a
            on_ring = all(p -> StructuralSizer._distance_to_loop(p, ring) < 1e-6, (p1, p2))
            on_ring && (ring_area += a)
        end
        @test total ≈ 108.0 - 4.0 rtol = 1e-6
        @test ring_area > 0

        small = SYM.undersized_rib_bays(struc, slab, level)
        @test !isempty(small)
        @test all(b -> b.area < 0.5 * 0.81, small)

        # §8.13.3 reads the larger module side.
        @test SYM._rib_spacing_m(struc, level) ≈ 0.9
    end

    @testset "a module grid is a grillage" begin
        struc, _ = _l_slab_with_ring()
        slab = only(struc.slabs)
        level = SYM.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                          pattern = ModularRibPattern(0.0, (1.0, 1.0)),
                                          material = StructuralSizer.A992_Steel)
        push!(slab.framing_levels, level)
        @test_throws ArgumentError SYM.materialize_level!(struc, slab, level)
    end

    @testset "options and wire" begin
        plan = SYM._rib_layout_opts((; module_spacing = (36.0u"inch", 30.0u"inch"),
                                     module_angle = 0.5))
        @test plan.grillage
        @test plan.layout === :module
        pat = SYM._grillage_pattern((; module_spacing = (36.0u"inch", 30.0u"inch"),
                                     module_angle = 0.5), :module)
        @test pat.spacing[1] ≈ 0.9144
        @test pat.spacing[2] ≈ 0.762
        @test pat.angle == 0.5
        @test_throws ArgumentError SYM._rib_layout_opts((; module_spacing = (1.0, 1.0),
                                                         n_xi = 2, n_eta = 2))
        @test_throws ArgumentError SYM._rib_layout_opts((; module_spacing = (1.0, 1.0),
                                                         solid_head = 0.2))
        @test_throws ArgumentError SYM._rib_layout_opts((; module_angle = 0.3))
        @test_throws ArgumentError SYM._rib_layout_opts((; module_spacing = (1.0, 1.0),
                                                         analysis = :tributary))

        raw = SYM.JSON3.read("""
            {"floor_type":"two_way","framing_levels":[
                {"material":"concrete","module_spacing_in":[36, 30],"module_angle_deg":45}
            ]}
            """, SYM.APIParams)
        opts = SYM.json_to_params(raw, "meters").framing_opts
        @test opts.module_spacing == (36.0u"inch", 30.0u"inch")
        @test opts.module_angle ≈ π / 4
        both = SYM.APIParams(framing_levels = [SYM.APIFramingLevel(
            material = "concrete", module_spacing_in = [36.0, 36.0], n_xi = 2, n_eta = 2)])
        @test_throws ErrorException SYM.json_to_params(both, "meters")
        on_beam = SYM.APIParams(framing_levels = [
            SYM.APIFramingLevel(material = "concrete", module_spacing_in = [36.0, 36.0]),
            SYM.APIFramingLevel(material = "concrete", module_spacing_in = [36.0, 36.0])])
        @test_throws ErrorException SYM.json_to_params(on_beam, "meters")
    end
end
