# Opening frames: trimmers run support to support, headers close the opening.
#
# One rectangular bay. The short side is the span, so the headers are the
# edges perpendicular to that span and their length is the opening's width
# across it. A larger opening lengthens the headers and removes more slab.
# A second pass adds nothing.

using Test
using Unitful
using StructuralSynthesizer

const _FR_Z = 3.0

function _fr_bay(lx, ly, opening; framing::Symbol=:auto)
    verts = Vector{Vector{Float64}}()
    for z in (_FR_Z, 0.0), (x, y) in ((0.0, 0.0), (lx, 0.0), (lx, ly), (0.0, ly))
        push!(verts, [x, y, z])
    end
    skel = json_to_skeleton(StructuralSynthesizer.APIInput(
        units = "m",
        vertices = verts,
        edges = StructuralSynthesizer.APIEdgeGroups(
            beams = [[1, 2], [2, 3], [3, 4], [4, 1]],
            columns = [[5, 1], [6, 2], [7, 3], [8, 4]],
            braces = Vector{Vector{Int}}()),
        supports = [5, 6, 7, 8],
        stories_z = [0.0, _FR_Z],
        openings = Vector{Vector{Vector{Float64}}}(),
    ))
    opening === nothing && return skel
    level = only(k for (k, s) in skel.stories if abs(ustrip(u"m", s.elevation) - _FR_Z) < 1e-6)
    add_slab_opening!(skel, opening, level; framing = framing)
    return skel
end

_fr_rect(x0, y0, x1, y1) = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]

function _fr_axis(skel)
    face = only(eachindex(skel.face_vertex_indices))
    si = StructuralSynthesizer.get_cell_spans(skel, face)
    return (Float64(si.axis[1]), Float64(si.axis[2]))
end

function _fr_edge_geom(skel, e)
    v1, v2 = skel.edge_indices[e]
    a = StructuralSynthesizer._frame_xy(skel, v1)
    b = StructuralSynthesizer._frame_xy(skel, v2)
    d = (b[1] - a[1], b[2] - a[2])
    L = hypot(d[1], d[2])
    return L < 1e-9 ? nothing : (L = L, dir = (d[1] / L, d[2] / L))
end

"""Lengths of member chains whose edges all run with `axis`."""
function _fr_parallel_chains(skel, axis)
    lens = Float64[]
    for chain in values(skel.edge_chains)
        total = 0.0
        parallel = true
        for e in chain
            g = _fr_edge_geom(skel, e)
            g === nothing && continue
            abs(g.dir[1] * axis[1] + g.dir[2] * axis[2]) > 0.95 || (parallel = false)
            total += g.L
        end
        parallel && total > 0 && push!(lens, total)
    end
    return lens
end

"""Lengths of beam edges perpendicular to `axis`."""
function _fr_header_lengths(skel, axis)
    lens = Float64[]
    for e in get(skel.groups_edges, :beams, Int[])
        g = _fr_edge_geom(skel, e)
        g === nothing && continue
        abs(g.dir[1] * axis[1] + g.dir[2] * axis[2]) < 0.05 && push!(lens, g.L)
    end
    return lens
end

function _fr_net_area(skel)
    struc = BuildingStructure(skel)
    StructuralSynthesizer.initialize_cells!(struc)
    return (n = length(struc.cells),
            area = sum(ustrip(u"m^2", c.area) for c in struc.cells; init = 0.0))
end

@testset "Opening framing" begin
    small = _fr_rect(4.0, 2.0, 8.0, 4.0)     # 4 m across x, 2 m along y
    big = _fr_rect(3.0, 1.0, 9.0, 5.0)       # 6 m across x, 4 m along y
    bay_small = _fr_bay(12.0, 6.0, small)
    axis = _fr_axis(bay_small)
    # The 12 × 6 bay spans the short way.
    @test abs(axis[2]) > 0.9

    n0 = length(bay_small.edges)
    frame_slab_openings!(bay_small; floor_type = :one_way)
    @test length(bay_small.edges) > n0

    # Header length is the opening's extent perpendicular to the span: 4 m.
    headers = _fr_header_lengths(bay_small, axis)
    @test any(L -> isapprox(L, 4.0; atol = 1e-6), headers)

    bay_along = hypot(12.0 * axis[1], 6.0 * axis[2])
    trimmers = _fr_parallel_chains(bay_small, axis)
    @test any(L -> isapprox(L, bay_along; atol = 1e-6), trimmers)

    net = _fr_net_area(bay_small)
    @test net.area ≈ 12.0 * 6.0 - 4.0 * 2.0 atol = 1e-6
    @test net.n == 4

    n1 = length(bay_small.edges)
    frame_slab_openings!(bay_small; floor_type = :one_way)
    @test length(bay_small.edges) == n1
    @test _fr_net_area(bay_small).area ≈ net.area atol = 1e-6

    bay_big = _fr_bay(12.0, 6.0, big)
    frame_slab_openings!(bay_big; floor_type = :one_way)
    big_headers = _fr_header_lengths(bay_big, axis)
    @test maximum(big_headers) > maximum(headers) + 1.0
    @test any(L -> isapprox(L, bay_along; atol = 1e-6), _fr_parallel_chains(bay_big, axis))
    @test _fr_net_area(bay_big).area ≈ 12.0 * 6.0 - 6.0 * 4.0 atol = 1e-6
    @test _fr_net_area(bay_big).area < net.area

    @testset "opt out, flat plate, and a skew opening" begin
        opted = _fr_bay(12.0, 6.0, small; framing = :none)
        n = length(opted.edges)
        @test_logs (:warn, r"left unframed") frame_slab_openings!(opted; floor_type = :one_way)
        @test length(opted.edges) == n

        plate = _fr_bay(12.0, 6.0, small)
        n = length(plate.edges)
        frame_slab_openings!(plate; floor_type = :flat_plate)
        @test length(plate.edges) == n

        # A rectangle rotated 20° is not on the span axis.
        c, ang = (6.0, 3.0), deg2rad(20)
        skew = NTuple{2, Float64}[]
        for (dx, dy) in ((1.5, 0.5), (1.5, -0.5), (-1.5, -0.5), (-1.5, 0.5))
            x = c[1] + dx * cos(ang) - dy * sin(ang)
            y = c[2] + dx * sin(ang) + dy * cos(ang)
            push!(skew, (x, y))
        end
        auto = _fr_bay(12.0, 6.0, skew)
        n = length(auto.edges)
        frame_slab_openings!(auto; floor_type = :one_way)
        @test length(auto.edges) == n

        asked = _fr_bay(12.0, 6.0, skew; framing = :opening_axes)
        frame_slab_openings!(asked; floor_type = :one_way)
        @test length(asked.edges) > n
        dir = (cos(ang), sin(ang))
        parallel = 0
        for e in asked.groups_edges[:beams]
            g = _fr_edge_geom(asked, e)
            g === nothing && continue
            abs(g.dir[1] * dir[1] + g.dir[2] * dir[2]) > 0.95 && (parallel += 1)
        end
        @test parallel >= 2
    end

    @testset "An unframed opening thickens the one-way slab" begin
        # The bay is 6 m on the span. A strip of 5 m from the beam to the
        # opening is a cantilever (ℓ/10); the plain bay is simple (ℓ/20).
        plain = _fr_bay(12.0, 6.0, nothing)
        near = _fr_rect(2.0, 0.4, 6.0, 1.0)     # 5 m of slab beyond the opening
        far = _fr_rect(2.0, 2.5, 6.0, 3.5)      # 2.5 m, shorter than the plain span
        h(opening) = begin
            skel = opening === nothing ? plain : _fr_bay(12.0, 6.0, opening; framing = :none)
            struc = BuildingStructure(skel)
            initialize!(struc; floor_type = :one_way)
            slab = only(s for s in struc.slabs if s.floor_type == :one_way)
            return total_depth(slab.result)
        end
        h_plain = h(nothing)
        h_long = h(near)
        h_short = h(far)
        @test h_long > h_plain
        @test h_short < h_long
        # A second design of the same opening does not move the thickness.
        skel = _fr_bay(12.0, 6.0, near; framing = :none)
        struc = BuildingStructure(skel)
        initialize!(struc; floor_type = :one_way)
        first = total_depth(only(s for s in struc.slabs if s.floor_type == :one_way).result)
        initialize!(struc; floor_type = :one_way)
        second = total_depth(only(s for s in struc.slabs if s.floor_type == :one_way).result)
        @test second ≈ first
    end
end
