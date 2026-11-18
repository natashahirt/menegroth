# `Beam.level` is the support rank of the beam's line.
#
# A line with two or more column, wall, or `:support` vertices is level 0,
# even when it is drawn as several members. A line that lands on other beams
# is one level above the higher end. Deflection is the offset from the chord
# through those supports, so a joist does not inherit the girder's sag.

using Test
using Unitful
using Asap
import Meshes
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer

function _fl_xyz(skel, v)
    c = Meshes.coords(skel.vertices[v])
    (ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z))
end

function _fl_add!(struc, a, b; role = :beam)
    skel = struc.skeleton
    e = add_element!(skel, a, b; group = :beams)
    p, q = _fl_xyz(skel, a), _fl_xyz(skel, b)
    L = sqrt(sum(abs2, p .- q))
    push!(struc.segments, SS.Segment(e, L))
    push!(struc.beams, Beam([length(struc.segments)], L; role = role))
    return length(struc.beams), e
end

"""
Perimeter girders on supports, a column-free line across the middle, and a
joist from that line to a girder.

```
A ---- B ---- C
|      |      |
D ---- E      F
|      |      |
G ---- H ---- I
```

A, C, G, I are supports. B-E-H has none.
"""
function _fl_grid()
    skel = BuildingSkeleton{Float64}()
    z = 3.0
    V(x, y) = add_vertex!(skel, [x, y, z])
    A, B, C = V(0, 0), V(6, 0), V(12, 0)
    D, E, F = V(0, 6), V(6, 6), V(12, 6)
    G, H, I = V(0, 12), V(6, 12), V(12, 12)
    for v in (A, C, G, I)
        push!(get!(skel.groups_vertices, :support, Int[]), v)
    end
    struc = BuildingStructure(skel)
    names = Dict{Symbol, Int}()
    function add(name, a, b)
        bi, _ = _fl_add!(struc, a, b)
        names[name] = bi
    end
    add(:bot1, A, B); add(:bot2, B, C)
    add(:top1, G, H); add(:top2, H, I)
    add(:left1, A, D); add(:left2, D, G)
    add(:right1, C, F); add(:right2, F, I)
    add(:cross1, B, E); add(:cross2, E, H)
    add(:joist, D, E)
    return struc, names
end

function _fl_square()
    skel = BuildingSkeleton{Float64}()
    z = 3.0
    V(x, y) = add_vertex!(skel, [x, y, z])
    a, b, c, d = V(0, 0), V(6, 0), V(6, 6), V(0, 6)
    struc = BuildingStructure(skel)
    _fl_add!(struc, a, b)
    _fl_add!(struc, b, c)
    _fl_add!(struc, c, d)
    _fl_add!(struc, d, a)
    return struc
end

"""
A soft girder, split at midspan, and a joist from that joint to a support.

The girder carries a wide tributary. The joist is pin-ended, so its live
deflection is the simple-beam value and not the girder's sag.
"""
function _fl_joist_on_girder()
    skel = BuildingSkeleton{Float64}()
    z = 3.0
    V(x, y) = add_vertex!(skel, [x, y, z])
    A, B, C, D = V(0, 0), V(6, 0), V(12, 0), V(6, 6)
    for v in (A, C, D)
        push!(get!(skel.groups_vertices, :support, Int[]), v)
    end
    struc = BuildingStructure(skel)
    g1, e1 = _fl_add!(struc, A, B; role = :girder)
    g2, e2 = _fl_add!(struc, B, C; role = :girder)
    joist, ej = _fl_add!(struc, B, D; role = :joist)

    # A, C, and D are held. D is fixed rather than pinned so its rotations,
    # which the pin-ended joist does not restrain, are not free.
    fix = Dict(A => :fixed, C => :fixed, D => :fixed, B => :free)
    coord(v) = (c = Meshes.coords(skel.vertices[v]);
                [ustrip(u"m", c.x) * u"m", ustrip(u"m", c.y) * u"m", ustrip(u"m", c.z) * u"m"])
    nodes = [Asap.Node(coord(v), fix[v]) for v in 1:length(skel.vertices)]
    sec = StructuralSizer.to_asap_section(W("W16X26"), A992_Steel)
    rel = Dict(e1 => :fixedfixed, e2 => :fixedfixed, ej => :freefree)
    els = Asap.FrameElement[
        Asap.Element(nodes[a], nodes[b], sec; release = rel[k])
        for (k, (a, b)) in enumerate(skel.edge_indices)]
    width = Dict(e1 => 8.0, e2 => 8.0, ej => 0.25)
    tribs = Asap.TributaryLoad[
        Asap.TributaryLoad(el, [0.0, 1.0], [width[k] * u"m", width[k] * u"m"],
                           3.0u"kN/m^2", (0.0, 0.0, -1.0))
        for (k, el) in enumerate(els)]
    spans = SpanInfo{Float64}(12.0, 6.0, (1.0, 0.0), 6.0)
    cell = Cell(0, 72.0u"m^2", spans, 0.0u"kN/m^2", 3.0u"kN/m^2")
    cell.floor_type = :two_way
    push!(struc.cells, cell)
    struc.cell_tributary_loads[1] = tribs
    model = Asap.Model(nodes, els, Asap.AbstractLoad[tribs...])
    Asap.solve!(model)
    struc.asap_model = model
    return struc, sec, (girder = (g1, g2), joist = joist, girder_edge = e1)
end

_fl_simple(w, L, E, I) = 5 * w * L^4 / (384 * E * I)

@testset "framing level from the beam lines" begin
    @testset "a column line split in two is the support" begin
        struc, names = _fl_grid()
        SS.assign_framing_levels!(struc)
        for name in (:bot1, :bot2, :top1, :top2, :left1, :left2, :right1, :right2)
            @test struc.beams[names[name]].level == 0
        end
        @test struc.beams[names[:cross1]].level == 1
        @test struc.beams[names[:cross2]].level == 1
        @test struc.beams[names[:joist]].level == 2
    end

    @testset "a square with nothing to land on stays level 0" begin
        struc = _fl_square()
        SS.assign_framing_levels!(struc)
        @test all(b -> b.level == 0, struc.beams)
    end

    @testset "a joist reports its own sag, not the girder's" begin
        struc, sec, ix = _fl_joist_on_girder()
        E = ustrip(u"Pa", sec.E)
        I = ustrip(u"m^4", sec.Ix)
        L = 6.0
        w = 3.0 * 1000 * 0.25
        hand = _fl_simple(w, L, E, I)

        gids, demands, _ = SS.member_group_demands(struc)
        j = findfirst(==(SS.group_id(struc.beams[ix.joist])), gids)
        @test j !== nothing
        @test demands[j].δ_max_LL ≈ hand rtol = 1e-4
        @test struc.beams[ix.girder[1]].level == 0
        @test struc.beams[ix.girder[2]].level == 0
        @test struc.beams[ix.joist].level == 1

        _, live, _ = SS._service_dead_live_loads(struc)
        uL, _ = Asap.solve(struc.asap_model,
                           Vector{Asap.AbstractLoad}[live, Asap.AbstractLoad[]],
                           struc.asap_rigid_links)
        el = struc.asap_model.frame_elements[ix.girder_edge]
        prof = Asap.element_deflection_profile(
            el, uL, Asap.frame_loads_by_element(struc.asap_model, live)[ix.girder_edge])
        girder_sag = maximum(abs, prof)
        @test girder_sag > 20 * demands[j].δ_max_LL
    end
end
