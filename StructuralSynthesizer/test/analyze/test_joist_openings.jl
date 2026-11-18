# Joists stop at an unframed opening.
#
# A joist that crosses the opening is cut there. The piece with one support is
# a cantilever: fixed at that support, free at the opening. A joist that lies
# in the opening is omitted. A larger opening shortens the cantilevers, and a
# second populate adds nothing.

using Test
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer

const JO_HZ = 3.5
const JO_SPACING = 2.0

_jo_rect(x0, y0, x1, y1) = NTuple{2, Float64}[(x0, y0), (x1, y0), (x1, y1), (x0, y1)]

"""12 m by 6 m joist bay. Joists run in y. `opening` is left unframed."""
function _joist_opening_bay(opening::Vector{NTuple{2, Float64}})
    corners = _jo_rect(0.0, 0.0, 12.0, 6.0)
    skel = BuildingSkeleton{Float64}()
    n = length(corners)
    gnd = [add_vertex!(skel, [x, y, 0.0]) for (x, y) in corners]
    sto = [add_vertex!(skel, [x, y, JO_HZ]) for (x, y) in corners]
    for i in 1:n
        add_element!(skel, gnd[i], sto[i]; group = :columns)
        add_element!(skel, sto[i], sto[mod1(i + 1, n)]; group = :beams)
    end
    append!(get!(skel.groups_vertices, :support, Int[]), gnd)
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    level = SS.story_index_at(skel, JO_HZ)
    add_slab_opening!(skel, opening, level; framing = :none)

    spans = SpanInfo{Float64}(12.0, 6.0, (1.0, 0.0), 6.0)
    fidx = findfirst(vs -> Set(vs) == Set(sto), skel.face_vertex_indices)
    fidx === nothing && error("joist bay face not found")
    net = SS._polygon_area_m2(corners) - SS._polygon_area_m2(opening)
    struc = BuildingStructure(skel)
    cell = Cell(fidx, net * u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
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
    populate_levels!(struc; opts = (materials = (steel = A992_Steel,), spacing = JO_SPACING))
    return struc
end

_metres(x) = x isa Unitful.Quantity ? ustrip(u"m", x) : Float64(x)

function _joist_lengths(struc)
    return [_metres(b.base.L) for b in struc.beams if b.role === :joist]
end

function _joist_releases(struc)
    out = NTuple{2, Symbol}[]
    for b in struc.beams
        b.role === :joist || continue
        segs = SS.segment_indices(b)
        push!(out, (struc.segments[first(segs)].release_start,
                    struc.segments[last(segs)].release_end))
    end
    return out
end

"""A joist segment midpoint lies strictly inside `opening`."""
function _joist_crosses(struc, opening)
    for b in struc.beams
        b.role === :joist || continue
        for si in SS.segment_indices(b)
            v1, v2 = struc.skeleton.edge_indices[struc.segments[si].edge_idx]
            a = SS._vertex_xy_m(struc.skeleton, v1)
            c = SS._vertex_xy_m(struc.skeleton, v2)
            m = ((a[1] + c[1]) / 2, (a[2] + c[2]) / 2)
            SS._point_in_polygon_xy(m[1], m[2], opening) || continue
            SS._point_on_polygon_boundary(m[1], m[2], opening; tol = 1e-4) && continue
            return true
        end
    end
    return false
end

function _joist_force(struc)
    roles = Dict{Int, Symbol}()
    for b in struc.beams, si in SS.segment_indices(b)
        roles[struc.segments[si].edge_idx] = b.role
    end
    edge_of = IdDict{Any, Int}()
    for (e, el) in enumerate(struc.asap_model.frame_elements)
        edge_of[el] = e
    end
    total = 0.0
    joist = 0.0
    for ld in struc.asap_model.loads
        ld isa Asap.TributaryLoad || continue
        L = ld.element.length
        Lm = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
        integ = 0.0
        p = ld.positions
        w = ld._widths_m
        for i in 1:(length(p) - 1)
            integ += 0.5 * (w[i] + w[i + 1]) * (p[i + 1] - p[i])
        end
        f = ld._pressure_Pa * Lm * integ
        total += f
        get(roles, get(edge_of, ld.element, 0), :missing) === :joist && (joist += f)
    end
    return (total = total, joist = joist)
end

@testset "Joists stop at an unframed opening" begin
    params = DesignParameters(materials = MaterialOptions(steel = A992_Steel))
    narrow = _jo_rect(3.0, 2.0, 9.0, 4.0)
    wide = _jo_rect(3.0, 1.0, 9.0, 5.0)

    struc = _joist_opening_bay(narrow)
    lens = _joist_lengths(struc)
    full = filter(L -> L > 5.0, lens)
    cants = filter(L -> L < 5.0, lens)
    @test length(full) == 2
    @test all(L -> abs(L - 6.0) < 0.05, full)
    @test length(cants) == 6
    @test all(L -> abs(L - 2.0) < 0.05, cants)
    @test !_joist_crosses(struc, narrow)

    rels = _joist_releases(struc)
    for (b, rel) in zip((b for b in struc.beams if b.role === :joist), rels)
        if _metres(b.base.L) > 5.0
            @test rel == (:default, :default)
        else
            @test rel == (:fixed, :pinned) || rel == (:pinned, :fixed)
        end
    end

    n_beams = length(struc.beams)
    populate_levels!(struc; opts = (materials = (steel = A992_Steel,), spacing = JO_SPACING))
    @test length(struc.beams) == n_beams
    @test sort(_joist_lengths(struc)) == sort(lens)

    wider = _joist_opening_bay(wide)
    wide_cants = filter(L -> L < 5.0, _joist_lengths(wider))
    @test length(wide_cants) == 6
    @test all(L -> abs(L - 1.0) < 0.05, wide_cants)
    @test maximum(wide_cants) < minimum(cants)

    covered = _joist_opening_bay(_jo_rect(4.0, 0.0, 8.0, 6.0))
    covered_L = _joist_lengths(covered)
    @test length(covered_L) == 2
    @test all(L -> abs(L - 6.0) < 0.05, covered_L)
    @test !_joist_crosses(covered, _jo_rect(4.0, 0.0, 8.0, 6.0))

    cell = struc.cells[1]
    p = ustrip(u"Pa", uconvert(u"Pa", envelope_pressure(params.load_combinations,
        cell.sdl + cell.self_weight, cell.live_load)))
    to_asap!(struc; params = params, diaphragms = :none)
    first = _joist_force(struc)
    to_asap!(struc; params = params, diaphragms = :none)
    second = _joist_force(struc)
    net = 72.0 - 12.0
    @test first.total ≈ p * net rtol = 1e-2
    @test first.joist > 0.2 * first.total
    @test second.total ≈ first.total rtol = 1e-9
    @test second.joist ≈ first.joist rtol = 1e-9

    to_asap!(wider; params = params, diaphragms = :none)
    grown = _joist_force(wider)
    @test grown.total ≈ p * (72.0 - 24.0) rtol = 1e-2
    @test grown.total < first.total
end
