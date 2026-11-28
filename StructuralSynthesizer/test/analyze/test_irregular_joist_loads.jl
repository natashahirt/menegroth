# A joist bay that is not a rectangle still puts the slab on the joists.
# The uniform strip is only for a joist-aligned rectangle. Everything else is
# cut along the joists, and the one-way partition has to cover the cell.

using Test
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer

const HZ = 3.5
const SPACING = 2.0

"""One-story joist bay on `corners` (m), joists running along `span_axis`."""
function _joist_bay(corners::Vector{NTuple{2, Float64}}; span_axis::NTuple{2, Float64})
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
    prim = maximum(xs) - minimum(xs)
    sec = maximum(ys) - minimum(ys)
    area = SS._polygon_area_m2(corners)
    spans = SpanInfo{Float64}(prim, sec, span_axis, min(prim, sec))
    fidx = findfirst(vs -> Set(vs) == Set(sto), skel.face_vertex_indices)
    fidx === nothing && error("joist bay face not found")

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

function _force_N(ld::Asap.TributaryLoad)
    L = ld.element.length
    Lm = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
    integ = 0.0
    p = ld.positions
    w = ld._widths_m
    for i in 1:(length(p) - 1)
        integ += 0.5 * (w[i] + w[i + 1]) * (p[i + 1] - p[i])
    end
    return ld._pressure_Pa * Lm * integ
end

"""Downward tributary force (N) on joists, and on the girders nearest `y0` and `y1`."""
function _split_forces(struc, y0, y1)
    roles = Dict{Int, Symbol}()
    for b in struc.beams, si in SS.segment_indices(b)
        roles[struc.segments[si].edge_idx] = b.role
    end
    edge_of = IdDict{Any, Int}()
    for (e, el) in enumerate(struc.asap_model.frame_elements)
        edge_of[el] = e
    end
    joist = 0.0
    low = 0.0
    high = 0.0
    total = 0.0
    for ld in struc.asap_model.loads
        ld isa Asap.TributaryLoad || continue
        f = _force_N(ld)
        total += f
        e = get(edge_of, ld.element, 0)
        role = get(roles, e, :missing)
        role === :joist && (joist += f)
        role === :girder || continue
        p1 = ld.element.nodeStart.position
        p2 = ld.element.nodeEnd.position
        y = (ustrip(u"m", p1[2]) + ustrip(u"m", p2[2])) / 2
        abs(y - y0) <= abs(y - y1) ? (low += f) : (high += f)
    end
    return (total = total, joist = joist, low = low, high = high)
end

function _pressure_Pa(struc, params)
    cell = struc.cells[1]
    p = envelope_pressure(params.load_combinations,
                          cell.sdl + cell.self_weight, cell.live_load)
    return ustrip(u"Pa", uconvert(u"Pa", p))
end

@testset "Irregular joist bays carry the slab" begin
    params = DesignParameters(materials = MaterialOptions(steel = A992_Steel))
    narrow = NTuple{2, Float64}[(0.0, 0.0), (8.0, 0.0), (6.0, 4.0), (2.0, 4.0)]
    wide = NTuple{2, Float64}[(0.0, 0.0), (12.0, 0.0), (6.0, 4.0), (2.0, 4.0)]

    struc = _joist_bay(narrow; span_axis = (1.0, 0.0))
    @test SS._framed_slab_strip_geometry(struc, struc.slabs[1]) === nothing
    @test !isempty([b for b in struc.beams if b.role === :joist])

    to_asap!(struc; params = params, diaphragms = :none)
    first_pass = _split_forces(struc, 0.0, 4.0)
    to_asap!(struc; params = params, diaphragms = :none)
    second_pass = _split_forces(struc, 0.0, 4.0)

    p = _pressure_Pa(struc, params)
    area = SS._polygon_area_m2(narrow)
    @test first_pass.total ≈ p * area rtol = 1e-3
    @test first_pass.joist > 0.2 * first_pass.total
    @test second_pass.total ≈ first_pass.total rtol = 1e-9
    @test second_pass.joist ≈ first_pass.joist rtol = 1e-9
    @test second_pass.low ≈ first_pass.low rtol = 1e-9

    wider = _joist_bay(wide; span_axis = (1.0, 0.0))
    to_asap!(wider; params = params, diaphragms = :none)
    grown = _split_forces(wider, 0.0, 4.0)
    wide_area = SS._polygon_area_m2(wide)
    @test grown.total ≈ p * wide_area rtol = 1e-3
    @test grown.total > first_pass.total
    # Joists run across the span axis, so the longer base is extra joist
    # tributary. That added load lands on the joists, not on the short edge.
    added = grown.total - first_pass.total
    @test (grown.joist - first_pass.joist) > 0.5 * added
    @test (grown.high - first_pass.high) < 0.5 * added
end
