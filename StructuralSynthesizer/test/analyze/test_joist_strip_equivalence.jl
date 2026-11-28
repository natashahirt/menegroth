# A joist-aligned rectangle can be loaded two ways: a uniform strip on each
# joist, or the same bay cut along the joists. Both have to put the same
# force on each member and the same shear at each girder end.
#
# The strip is the reference. It is exact on a rectangle because the
# tributary width is constant, so the load is uniform and its centroid is
# mid-span. The cut is what every other outline uses.

using Test
using Unitful
using Asap
using StructuralSynthesizer

const SS = StructuralSynthesizer

const HZ = 3.5
const SPACING = 2.0

"""One-story rectangular joist bay. Joists run perpendicular to `span_axis`."""
function _rectangle_bay(corners::Vector{NTuple{2, Float64}}; span_axis::NTuple{2, Float64})
    skel = BuildingSkeleton{Float64}()
    n = length(corners)
    gnd = [add_vertex!(skel, [x, y, 0.0]) for (x, y) in corners]
    sto = [add_vertex!(skel, [x, y, HZ]) for (x, y) in corners]
    for i in 1:n
        add_element!(skel, gnd[i], sto[i]; group = :columns)
        add_element!(skel, sto[i], sto[mod1(i + 1, n)]; group = :beams)
    end
    supports = get!(skel.groups_vertices, :support, Int[])
    append!(supports, gnd)
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)

    xs = [c[1] for c in corners]
    ys = [c[2] for c in corners]
    area = SS._polygon_area_m2(corners)
    spans = SpanInfo{Float64}(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys),
                              span_axis, min(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys)))
    fidx = findfirst(vs -> Set(vs) == Set(sto), skel.face_vertex_indices)
    fidx === nothing && error("rectangle face not found")

    struc = BuildingStructure(skel)
    cell = Cell(fidx, area * u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
    cell.floor_type = :two_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab{Float64}([1],
        CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
        :two_way, spans, :interior, nothing, MaterialVolumes(),
        nothing, nothing, FramingLevel{Float64}[]))
    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end
    for e in sort(collect(skel.groups_edges[:columns]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.columns, Column([length(struc.segments)], L))
    end
    compute_cell_tributaries!(struc)
    populate_levels!(struc; opts = (materials = (steel = A992_Steel,), spacing = SPACING))
    return struc
end

"""Plan midpoint of a frame element, rounded so the two models share keys."""
function _mid(el)
    p1 = el.nodeStart.position
    p2 = el.nodeEnd.position
    return (round((ustrip(u"m", p1[1]) + ustrip(u"m", p2[1])) / 2; digits = 4),
            round((ustrip(u"m", p1[2]) + ustrip(u"m", p2[2])) / 2; digits = 4))
end

"""Downward force (N) a tributary load applies."""
function _force_N(ld::Asap.TributaryLoad)
    p1 = ld.element.nodeStart.position
    p2 = ld.element.nodeEnd.position
    Lm = hypot(ustrip(u"m", p2[1] - p1[1]), ustrip(u"m", p2[2] - p1[2]),
               ustrip(u"m", p2[3] - p1[3]))
    integ = 0.0
    p = ld.positions
    w = ld._widths_m
    for i in 1:(length(p) - 1)
        integ += 0.5 * (w[i] + w[i + 1]) * (p[i + 1] - p[i])
    end
    return ld._pressure_Pa * Lm * integ
end

"""Tributary force (N) on each frame element, keyed by plan midpoint."""
function _forces_by_member(loads)
    acc = Dict{NTuple{2, Float64}, Float64}()
    for ld in loads
        ld isa Asap.TributaryLoad || continue
        key = _mid(ld.element)
        acc[key] = get(acc, key, 0.0) + _force_N(ld)
    end
    return acc
end

"""Vertical shear (N) at each end of every beam element."""
function _end_shears(struc)
    model = struc.asap_model
    out = Dict{NTuple{2, Float64}, NTuple{2, Float64}}()
    for beam in struc.beams
        for si in SS.segment_indices(beam)
            e = struc.segments[si].edge_idx
            el = model.frame_elements[e]
            f = SS._element_forces_from_u(el, model.u, model.loads; resolution = 3)
            out[_mid(el)] = (f.Vz[1], f.Vz[end])
        end
    end
    return out
end

"""Vertical reaction (N) at each fixed base, keyed by plan position."""
function _base_reactions(model)
    out = Dict{NTuple{2, Float64}, Float64}()
    for n in model.nodes
        length(n.dof) >= 3 && n.dof[3] == false || continue
        key = (round(ustrip(u"m", n.position[1]); digits = 4),
               round(ustrip(u"m", n.position[2]); digits = 4))
        out[key] = ustrip(u"N", n.reaction[3])
    end
    return out
end

function _replace_tributary!(model, new_loads)
    keep = [ld for ld in model.loads if !(ld isa Asap.TributaryLoad)]
    empty!(model.loads)
    append!(model.loads, keep)
    append!(model.loads, new_loads)
    return model
end

"""Rotate a plan point `deg` degrees about the origin."""
_rot(x, y, deg) = begin
    a = deg * π / 180
    (cos(a) * x - sin(a) * y, sin(a) * x + cos(a) * y)
end

function _span_of(corners)
    dx = corners[2][1] - corners[1][1]
    dy = corners[2][2] - corners[1][2]
    L = hypot(dx, dy)
    return (dx / L, dy / L)
end

"""
Both load paths on one rectangle.

`strip` is the model the building actually builds (the uniform strip, when
the bay is a joist-aligned rectangle). `cut` is the same bay with those
strip loads replaced by the joist-cut tributaries at the same pressure.
"""
function _both_paths(corners; span_axis)
    params = DesignParameters(materials = MaterialOptions(steel = A992_Steel))
    strip = _rectangle_bay(corners; span_axis)
    cut = _rectangle_bay(corners; span_axis)
    @test SS._framed_slab_strip_geometry(strip, strip.slabs[1]) !== nothing
    to_asap!(strip; params = params, diaphragms = :none)
    to_asap!(cut; params = params, diaphragms = :none)

    cell = cut.cells[1]
    pressure = uconvert(u"Pa", envelope_pressure(params.load_combinations,
                                                 cell.sdl + cell.self_weight, cell.live_load))
    split = SS._cell_split_joist_loads(cut, cell, cut.asap_model.frame_elements)
    @test split !== nothing
    scaled = [SS._tributary_at(ld, pressure) for ld in split]
    _replace_tributary!(cut.asap_model, scaled)
    Asap.solve!(cut.asap_model; reprocess = true)
    Asap.reactions!(strip.asap_model)
    Asap.reactions!(cut.asap_model)
    return strip, cut
end

function _same_map(a::Dict, b::Dict; rtol, atol)
    for k in union(keys(a), keys(b))
        @test get(a, k, 0.0) ≈ get(b, k, 0.0) rtol = rtol atol = atol
    end
end

function _check_rectangle(corners; span_axis)
    strip, cut = _both_paths(corners; span_axis)
    area = SS._polygon_area_m2(corners)
    cell = strip.cells[1]
    params = DesignParameters(materials = MaterialOptions(steel = A992_Steel))
    p = ustrip(u"Pa", envelope_pressure(params.load_combinations,
                                        cell.sdl + cell.self_weight, cell.live_load))
    strip_forces = _forces_by_member(strip.asap_model.loads)
    cut_forces = _forces_by_member(cut.asap_model.loads)
    @test sum(values(strip_forces)) ≈ p * area rtol = 1e-3
    @test sum(values(cut_forces)) ≈ p * area rtol = 1e-3
    _same_map(strip_forces, cut_forces; rtol = 1e-3, atol = 1.0)

    strip_ends = _end_shears(strip)
    cut_ends = _end_shears(cut)
    for k in union(keys(strip_ends), keys(cut_ends))
        s = get(strip_ends, k, (0.0, 0.0))
        c = get(cut_ends, k, (0.0, 0.0))
        @test s[1] ≈ c[1] rtol = 1e-3 atol = 5.0
        @test s[2] ≈ c[2] rtol = 1e-3 atol = 5.0
    end
    _same_map(_base_reactions(strip.asap_model), _base_reactions(cut.asap_model);
              rtol = 1e-3, atol = 5.0)
end

@testset "a rectangle's joist cut matches the one-way strip" begin
    # 8 m by 6 m. Joists span the 6 m side and land every 2 m, so the two
    # edge strips are half a module.
    _check_rectangle(NTuple{2, Float64}[(0.0, 0.0), (8.0, 0.0), (8.0, 6.0), (0.0, 6.0)];
                     span_axis = (1.0, 0.0))
    # Joists span the 5.2 m side. Across the 9 m side the last gap is 1 m.
    _check_rectangle(NTuple{2, Float64}[(0.0, 0.0), (5.2, 0.0), (5.2, 9.0), (0.0, 9.0)];
                     span_axis = (0.0, 1.0))
    # The same 8×6 rectangle, turned 20°. The strip is only valid when the
    # joists stay parallel to a side, which they do.
    turned = NTuple{2, Float64}[_rot(x, y, 20.0) for (x, y) in
                                ((0.0, 0.0), (8.0, 0.0), (8.0, 6.0), (0.0, 6.0))]
    _check_rectangle(turned; span_axis = _span_of(turned))
end

@testset "a strip side over several members keeps its whole area" begin
    trap(ps, ws) = sum(0.5 * (ws[i] + ws[i + 1]) * (ps[i + 1] - ps[i]) for i in 1:length(ps) - 1)
    # A triangle's depth profile, rising to a peak at 0.4 and back to zero.
    ps = [0.0, 0.4, 1.0]
    ws = [0.0, 2.0, 0.0]
    whole = trap(ps, ws)
    cuts = [0.0, 0.25, 0.4, 0.7, 1.0]
    parts = 0.0
    for k in 1:length(cuts) - 1
        cps, cws = SS._clip_depth_profile(ps, ws, cuts[k], cuts[k + 1])
        @test first(cps) == cuts[k] && last(cps) == cuts[k + 1]
        parts += trap(cps, cws)
    end
    @test parts ≈ whole rtol = 1e-12
    # Outside the profile there is no depth.
    cps, cws = SS._clip_depth_profile([0.2, 0.6], [1.0, 1.0], 0.0, 1.0)
    @test (first(cps), last(cps)) == (0.2, 0.6)
    @test trap(cps, cws) ≈ 0.4 rtol = 1e-12
    @test isempty(first(SS._clip_depth_profile([0.2, 0.6], [1.0, 1.0], 0.7, 1.0)))
end
