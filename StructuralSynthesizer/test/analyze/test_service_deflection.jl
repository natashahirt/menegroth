# Service deflection demands for steel beams (`member_group_demands`).
#
# Regression for three defects that left the L/360 and L/240 checks off:
#   1. the deflection read local z, which is horizontal at the default roll;
#   2. a one-element span had no deflection from its own member load;
#   3. with the default `pattern_loading = :none` the split records were
#      empty, so δ came back 0, which `MemberDemand` reads as "skip".
#
# Oracle: a simply supported span under uniform w, δ = 5 w L⁴ / (384 E I)
# (standard beam table). Service loads are nominal (unfactored): ASCE 7-16
# Commentary CC.2.1 (corpus: asce-7-16, PDF p. 856), "1/360 of the span for
# floors subjected to full nominal live load".

using Test
using Unitful
using Asap
import Meshes
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer

"""
One square bay of side `L` (m) on four corner supports. Each edge is one
pin-ended (`:freefree`) W16X26 element with a uniform 1.5 m tributary width,
recorded under the cell the way `to_asap!` records an unsplit build. The
model's load is at an arbitrary factored pressure; service loads must come
from the cell's own `sdl` and `live_load`. Slab self-weight is not part of
the total-load deflection.
"""
function _sd_square_bay(L; sdl = 2.0u"kN/m^2", sw = 1.5u"kN/m^2", ll = 3.0u"kN/m^2",
                        width = 1.5, self_weight_factor = nothing)
    skel = BuildingSkeleton{Float64}()
    z = 3.0
    v1 = add_vertex!(skel, [0.0, 0.0, z])
    v2 = add_vertex!(skel, [L, 0.0, z])
    v3 = add_vertex!(skel, [L, L, z])
    v4 = add_vertex!(skel, [0.0, L, z])
    add_element!(skel, v1, v2; group = :beams)
    add_element!(skel, v2, v3; group = :beams)
    add_element!(skel, v3, v4; group = :beams)
    add_element!(skel, v4, v1; group = :beams)
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    struc = BuildingStructure(skel)
    fidx = findfirst(vs -> Set(vs) == Set((v1, v2, v3, v4)), skel.face_vertex_indices)
    spans = SpanInfo{Float64}(L, L, (1.0, 0.0), L)
    cell = Cell(fidx, (L * L) * u"m^2", spans, sdl, ll)
    cell.self_weight = sw
    cell.floor_type = :two_way
    push!(struc.cells, cell)
    for e in sort(collect(skel.groups_edges[:beams]))
        Le = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, SS.Segment(e, Le))
        push!(struc.beams, Beam([length(struc.segments)], Le; role = :girder, level = 0))
    end

    coord(v) = (c = Meshes.coords(skel.vertices[v]);
                [ustrip(u"m", c.x) * u"m", ustrip(u"m", c.y) * u"m", ustrip(u"m", c.z) * u"m"])
    nodes = [Asap.Node(coord(v), :fixed) for v in 1:length(skel.vertices)]
    sec = StructuralSizer.to_asap_section(W("W16X26"), A992_Steel)
    els = Asap.FrameElement[Asap.Element(nodes[a], nodes[b], sec; release = :freefree)
                            for (a, b) in skel.edge_indices]
    factored = 7.5u"kN/m^2"
    tribs = Asap.TributaryLoad[Asap.TributaryLoad(el, [0.0, 1.0], [width * u"m", width * u"m"],
                                                  factored, (0.0, 0.0, -1.0)) for el in els]
    struc.cell_tributary_loads[1] = tribs
    loads = Asap.AbstractLoad[tribs...]
    if self_weight_factor !== nothing
        append!(loads, [Asap.GravityLoad(el, self_weight_factor) for el in els])
    end
    model = Asap.Model(nodes, els, loads)
    Asap.solve!(model)
    struc.asap_model = model
    return struc, sec
end

_sd_simple(w, L, E, I) = 5 * w * L^4 / (384 * E * I)

@testset "service deflection demands" begin
    L = 6.0
    width = 1.5

    @testset "default params give the hand value (pattern_loading = :none)" begin
        @test DesignParameters().pattern_loading === :none
        struc, sec = _sd_square_bay(L; width)
        E = ustrip(u"Pa", sec.E); I = ustrip(u"m^4", sec.Ix)
        # L/240 is live plus superimposed dead. Slab self-weight is excluded.
        # ENGINEERING JUDGMENT: the whole cell.sdl stands in for the dead load
        # applied after nonstructural elements are attached (AISC 360-16
        # Commentary L2, corpus: aisc-360-16, PDF p. 535).
        w_S = 2.0 * 1000 * width
        w_L = 3.0 * 1000 * width
        _, demands, L_tot, _ = SS.member_group_demands(struc)
        @test length(demands) == 4
        for (d, Lg) in zip(demands, L_tot)
            @test Lg ≈ L
            @test d.δ_max_LL ≈ _sd_simple(w_L, L, E, I) rtol = 1e-6
            @test d.δ_max_total ≈ _sd_simple(w_S + w_L, L, E, I) rtol = 1e-6
        end
    end

    @testset "member self-weight and slab weight are not in the total deflection" begin
        struc, sec = _sd_square_bay(L; width, self_weight_factor = 1.2 * 9.80665u"m/s^2")
        E = ustrip(u"Pa", sec.E); I = ustrip(u"m^4", sec.Ix)
        w_S = 2.0 * 1000 * width
        w_L = 3.0 * 1000 * width
        _, demands, _ = SS.member_group_demands(struc)
        for d in demands
            @test d.δ_max_LL ≈ _sd_simple(w_L, L, E, I) rtol = 1e-6
            @test d.δ_max_total ≈ _sd_simple(w_S + w_L, L, E, I) rtol = 1e-6
        end
    end

    @testset "the live deflection does not depend on the strength combination" begin
        # The old split divided the solved displacement by the first combo's
        # factors, so a combination with L = 0 erased the live deflection.
        struc, sec = _sd_square_bay(L; width)
        params = DesignParameters(load_combinations = [StructuralSizer.LoadCombination(
            name = :dead_only, D = 1.4, L = 0.0)])
        _, demands, _ = SS.member_group_demands(struc; params = params)
        E = ustrip(u"Pa", sec.E); I = ustrip(u"m^4", sec.Ix)
        @test all(d -> isapprox(d.δ_max_LL, _sd_simple(3000 * width, L, E, I); rtol = 1e-6),
                  demands)
    end

    @testset "a load with no known service split throws" begin
        struc, _ = _sd_square_bay(L; width)
        el = struc.asap_model.frame_elements[1]
        push!(struc.asap_model.loads,
              Asap.LineLoad(el, [0.0u"N/m", 0.0u"N/m", -1.0u"N/m"], :mystery))
        err = try
            SS.member_group_demands(struc); nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("mystery", err.msg)
    end

    @testset "slab loads with no cell record throw" begin
        struc, _ = _sd_square_bay(L; width)
        empty!(struc.cell_tributary_loads)
        @test_throws ArgumentError SS.member_group_demands(struc)
    end

    @testset "a deflection limit with no service deflection throws" begin
        d0 = StructuralSizer.MemberDemand(1; Mux = 1.0, δ_max_LL = 0.0, δ_max_total = 0.0)
        @test_throws ArgumentError SS._require_service_deflections([d0], [UInt64(7)], true)
        @test SS._require_service_deflections([d0], [UInt64(7)], false) === nothing
    end
end
