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

    @testset "the shorter span stays continuous and cuts the longer one" begin
        # 12 m by 10 m. The vertical across the short direction is one line.
        # The horizontal is longer, so it is cut where the vertical crosses.
        skel = BuildingSkeleton{Float64}()
        z = 3.0
        V(x, y) = add_vertex!(skel, [x, y, z])
        A, B, C = V(0, 0), V(6, 0), V(12, 0)
        D, E, F = V(0, 5), V(6, 5), V(12, 5)
        G, H, I = V(0, 10), V(6, 10), V(12, 10)
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
        add(:short1, B, E); add(:short2, E, H)
        add(:long1, D, E); add(:long2, E, F)
        SS.assign_framing_levels!(struc)
        for name in (:bot1, :bot2, :top1, :top2, :left1, :left2, :right1, :right2)
            @test struc.beams[names[name]].level == 0
        end
        @test struc.beams[names[:short1]].level == 1
        @test struc.beams[names[:short2]].level == 1
        @test struc.beams[names[:long1]].level == 2
        @test struc.beams[names[:long2]].level == 2
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

"""Two collinear 5 m pieces between supports 10 m apart."""
function _fl_split_bay()
    skel = BuildingSkeleton{Float64}()
    z = 3.0
    V(x) = add_vertex!(skel, [x, 0.0, z])
    A, B, C = V(0.0), V(5.0), V(10.0)
    for v in (A, C)
        push!(get!(skel.groups_vertices, :support, Int[]), v)
    end
    struc = BuildingStructure(skel)
    _fl_add!(struc, A, B)
    _fl_add!(struc, B, C)
    return struc
end

@testset "steel shell spans follow the framing line" begin
    @testset "a bay drawn as two pieces is one 10 m span" begin
        struc = _fl_split_bay()
        table = SS._shell_line_lookup(struc)
        a = table[Symbol("beam_1")]
        b = table[Symbol("beam_2")]
        @test a.total ≈ 10.0
        @test b.total ≈ 10.0
        @test a.supports ≈ [0.0, 10.0]
        @test b.supports ≈ [0.0, 10.0]
        @test a.s1 - a.s0 ≈ 5.0
        @test b.s1 - b.s0 ≈ 5.0
        @test min(a.s0, b.s0) ≈ 0.0
        @test max(a.s1, b.s1) ≈ 10.0
        @test a.ids == b.ids
        # The reinforced-concrete span still sees only the columns it is given.
        # A beam crossing this line is not one of them.
        rc = StructuralSizer.shell_service_spans([(0.0, 0.0), (10.0, 0.0)],
                                                 [(0.0, 0.0), (10.0, 0.0)])
        @test length(rc) == 1 && !rc[1].cantilever
    end

    @testset "one element between two supports still sags" begin
        # Translations held, twist held, bending rotations free: a simple beam.
        # A fully pinned node also leaves the twist free, and the two ends
        # spinning together has no stiffness.
        simple = [false, false, false, false, true, true]
        n1 = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], simple)
        n2 = Asap.Node([10.0u"m", 0.0u"m", 0.0u"m"], simple)
        sec = StructuralSizer.to_asap_section(W("W16X26"), A992_Steel)
        el = Asap.Element(n1, n2, sec, :span; release = :fixedfixed)
        load = Asap.TributaryLoad(el, [0.0, 1.0], [1.0u"m", 1.0u"m"],
                                   3.0u"kN/m^2", (0.0, 0.0, -1.0))
        model = Asap.Model([n1, n2], Asap.Element[el], Asap.AbstractLoad[load])
        Asap.solve!(model)
        line = SS.ShellLineSpan([(0.0, 0.0), (10.0, 0.0)], [0.0, 10.0],
                                0.0, 10.0, [:span], 10.0)
        beam = SS.ShellServiceBeam(:span, [(0.0, 0.0), (10.0, 0.0)], sec,
                                   [(0.0, 0.0), (10.0, 0.0)]; line = line)
        loads_of = Asap.get_elemental_loads(model.loads, length(model.frame_elements))
        readings = SS._steel_line_readings(model.frame_elements, model.u, loads_of,
                                           beam, Dict{Symbol, Vector{Tuple{Float64, Float64}}}())
        E = ustrip(u"Pa", sec.E)
        I = ustrip(u"m^4", sec.Ix)
        hand = _fl_simple(3000.0, 10.0, E, I)
        @test length(readings) == 1
        @test readings[1].L ≈ 10.0
        # The two end nodes sit on the chord, so a nodal reading is zero.
        @test readings[1].Δ ≈ hand rtol = 1e-3
        @test readings[1].Δ > 1e-4
    end

    @testset "a cantilever uses twice its length" begin
        n1 = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], :fixed)
        n2 = Asap.Node([4.0u"m", 0.0u"m", 0.0u"m"], :free)
        sec = StructuralSizer.to_asap_section(W("W16X26"), A992_Steel)
        el = Asap.Element(n1, n2, sec, :cant; release = :fixedfixed)
        load = Asap.TributaryLoad(el, [0.0, 1.0], [1.0u"m", 1.0u"m"],
                                   3.0u"kN/m^2", (0.0, 0.0, -1.0))
        model = Asap.Model([n1, n2], Asap.Element[el], Asap.AbstractLoad[load])
        Asap.solve!(model)
        line = SS.ShellLineSpan([(0.0, 0.0), (4.0, 0.0)], [0.0],
                                0.0, 4.0, [:cant], 4.0)
        beam = SS.ShellServiceBeam(:cant, [(0.0, 0.0), (4.0, 0.0)], sec,
                                   [(0.0, 0.0)]; line = line)
        loads_of = Asap.get_elemental_loads(model.loads, length(model.frame_elements))
        readings = SS._steel_line_readings(model.frame_elements, model.u, loads_of,
                                           beam, Dict{Symbol, Vector{Tuple{Float64, Float64}}}())
        E = ustrip(u"Pa", sec.E)
        I = ustrip(u"m^4", sec.Ix)
        # Tip of a uniform cantilever: wL^4 / (8EI). The limit length is 2L.
        tip = 3000.0 * 4.0^4 / (8 * E * I)
        @test length(readings) == 1
        @test readings[1].L ≈ 8.0
        @test readings[1].cantilever
        @test readings[1].Δ ≈ tip rtol = 1e-3
    end
end
