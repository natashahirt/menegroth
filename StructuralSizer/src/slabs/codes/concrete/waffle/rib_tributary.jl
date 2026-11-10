# =============================================================================
# Rectangular-bay tributary on a rib grid
# =============================================================================
#
# Each bay is a rectangle. Its load is divided among the four bounding ribs
# by the isotropic straight skeleton: equal wavefront speed, so the corner
# boundaries are 45°. A long edge carries a trapezoid and a short edge a
# triangle. An interior rib is the shared edge of two bays, so the two
# widths add. The profiles are the piecewise-linear widths a
# TributaryLoad integrates exactly.
#
# ACI 318-19 §8.2.1 (corpus: aci-318-19, page 101) permits this distribution
# as part of an analysis that satisfies equilibrium and compatibility. The
# skeleton itself is geometry: the areas below sum to the panel.

"""
    rectangle_edge_tributary(along, across) -> (positions, widths)

Width of one rectangle edge's skeleton region.

`along` is the edge length and `across` is the other side, in the same
length unit. `positions` run from 0 to 1 along the edge. `widths` are the
perpendicular depths at those stations. The width is zero at the corners
and peaks at `min(along, across) / 2`.
"""
function rectangle_edge_tributary(along::Real, across::Real)
    along > 0 || throw(ArgumentError("edge length must be positive, got $along"))
    across > 0 || throw(ArgumentError("the adjacent side must be positive, got $across"))
    peak = min(along, across) / 2
    ramp = across / 2
    if ramp < along / 2
        stations = [0.0, ramp, along - ramp, along]
        widths = [0.0, peak, peak, 0.0]
    else
        stations = [0.0, along / 2, along]
        widths = [0.0, peak, 0.0]
    end
    return (stations ./ along, widths)
end

"""Area under a width profile. `along` is the edge length in the width's unit."""
function tributary_profile_area(along::Real, positions, widths)
    length(positions) == length(widths) ||
        throw(ArgumentError("a tributary profile needs one width per station"))
    area = 0.0
    for i in 1:(length(positions) - 1)
        ds = (positions[i + 1] - positions[i]) * along
        area += 0.5 * (widths[i] + widths[i + 1]) * ds
    end
    return area
end

"""
    rectangle_rib_tributaries(Lx, Ly, nξ, nη) -> Vector{NamedTuple}

One profile per piece of [`rib_network`](@ref) on a rectangle `Lx` by `Ly`
divided into `nξ` by `nη` equal bays.

The piece order is that function's order: ξ-ribs first, each running in η,
then η-ribs. `positions` are fractions of the piece. `widths` are metres
when `Lx` and `Ly` are metres.
"""
function rectangle_rib_tributaries(Lx::Real, Ly::Real, nξ::Int, nη::Int)
    (Lx > 0 && Ly > 0) || throw(ArgumentError("panel sides must be positive, got $Lx by $Ly"))
    (nξ >= 1 && nη >= 1) || throw(ArgumentError("a rib grid needs at least one bay each way, got $nξ by $nη"))
    sx, sy = Lx / nξ, Ly / nη
    out = NamedTuple{(:positions, :widths), Tuple{Vector{Float64}, Vector{Float64}}}[]
    for i in 0:nξ
        sides = (i > 0) + (i < nξ)
        positions, widths = rectangle_edge_tributary(sy, sx)
        piece = (positions = positions, widths = widths .* sides)
        for _ in 1:nη
            push!(out, piece)
        end
    end
    for j in 0:nη
        sides = (j > 0) + (j < nη)
        positions, widths = rectangle_edge_tributary(sx, sy)
        piece = (positions = positions, widths = widths .* sides)
        for _ in 1:nξ
            push!(out, piece)
        end
    end
    return out
end

"""Absolute area of a simple polygon. `corners` are `(x, y)` in order."""
function polygon_area_m(corners)
    n = length(corners)
    n >= 3 || return 0.0
    area = 0.0
    for i in 1:n
        p = corners[i]
        q = corners[mod1(i + 1, n)]
        area += p[1] * q[2] - q[1] * p[2]
    end
    return abs(area) / 2
end

"""Profile running the other way along the same piece."""
function _reversed_profile(positions, widths)
    pos = reverse(1.0 .- collect(Float64, positions))
    w = reverse(collect(Float64, widths))
    for i in 2:length(pos)
        pos[i] < pos[i - 1] && (pos[i] = pos[i - 1])
    end
    return pos, w
end

_ξ_piece_index(i, j, nξ, nη) = i * nη + j + 1
_η_piece_index(i, j, nξ, nη) = (nξ + 1) * nη + j * nξ + i + 1

"""
    quad_rib_tributaries(corners, nξ, nη) -> Vector{NamedTuple}

One profile per piece of [`rib_network`](@ref) on a quadrilateral.

A rectangle keeps [`rectangle_rib_tributaries`](@ref). Any other quad gives
each bay to [`get_tributary_polygons_isotropic`](@ref) and adds that bay's
four edge profiles onto the ribs. A bay edge that runs against the piece is
reversed before the widths add. A bay that cannot be given a skeleton throws.
"""
function quad_rib_tributaries(corners, nξ::Int, nη::Int)
    length(corners) == 4 || throw(ArgumentError(
        "a rib panel is a quadrilateral, and this one has $(length(corners)) corners"))
    (nξ >= 1 && nη >= 1) || throw(ArgumentError(
        "a rib grid needs at least one bay each way, got $nξ by $nη"))
    c = ntuple(i -> (Float64(corners[i][1]), Float64(corners[i][2])), 4)
    if is_rectangular_panel(c)
        Lx = hypot(c[2][1] - c[1][1], c[2][2] - c[1][2])
        Ly = hypot(c[4][1] - c[1][1], c[4][2] - c[1][2])
        return rectangle_rib_tributaries(Lx, Ly, nξ, nη)
    end
    return _isotropic_rib_tributaries(c, nξ, nη)
end

"""Per-bay isotropic skeleton, in [`rib_network`](@ref) piece order."""
function _isotropic_rib_tributaries(c, nξ::Int, nη::Int)
    panel = IsoParametricPanel(c)
    n_pieces = (nξ + 1) * nη + (nη + 1) * nξ
    acc = Vector{Union{Nothing, Tuple{Vector{Float64}, Vector{Float64}}}}(nothing, n_pieces)
    for i in 0:(nξ - 1), j in 0:(nη - 1)
        c1 = physical_coords(panel, i / nξ, j / nη)
        c2 = physical_coords(panel, (i + 1) / nξ, j / nη)
        c3 = physical_coords(panel, (i + 1) / nξ, (j + 1) / nη)
        c4 = physical_coords(panel, i / nξ, (j + 1) / nη)
        ccw = _signed_area((c1, c2, c3, c4)) >= 0
        verts = ccw ? (c1, c2, c3, c4) : (c4, c3, c2, c1)
        targets = ccw ?
            ((_η_piece_index(i, j, nξ, nη), false),
             (_ξ_piece_index(i + 1, j, nξ, nη), false),
             (_η_piece_index(i, j + 1, nξ, nη), true),
             (_ξ_piece_index(i, j, nξ, nη), true)) :
            ((_η_piece_index(i, j + 1, nξ, nη), false),
             (_ξ_piece_index(i + 1, j, nξ, nη), true),
             (_η_piece_index(i, j, nξ, nη), true),
             (_ξ_piece_index(i, j, nξ, nη), false))
        pts = [Meshes.Point(p[1], p[2]) for p in verts]
        polys = try
            get_tributary_polygons_isotropic(pts)
        catch err
            throw(ArgumentError(
                "a rib bay could not be given an isotropic skeleton ($(sprint(showerror, err)))"))
        end
        length(polys) == 4 || throw(ArgumentError(
            "a rib bay could not be given an isotropic skeleton"))
        for (poly, (idx, rev)) in zip(polys, targets)
            pos, w = poly.profile_s, poly.profile_w
            rev && ((pos, w) = _reversed_profile(pos, w))
            w = [max(wi, 0.0) for wi in w]
            prof = (collect(Float64, pos), w)
            acc[idx] = acc[idx] === nothing ? prof : Asap._sum_profiles([acc[idx], prof])
        end
    end
    out = NamedTuple{(:positions, :widths), Tuple{Vector{Float64}, Vector{Float64}}}[]
    for k in 1:n_pieces
        prof = acc[k]
        prof === nothing && throw(ArgumentError(
            "rib piece $k received no skeleton width"))
        push!(out, (positions = prof[1], widths = prof[2]))
    end
    return out
end
