# =============================================================================
# Rib network for a grillage
# =============================================================================
#
# A waffle grid becomes one frame graph. Each rib is a chain of straight
# pieces, and a crossing is one shared node, so the rib is continuous there.
#
# ACI 318-19 §8.2.1 (corpus: aci-318-19, page 101) permits a slab system to
# be analyzed by any procedure that satisfies equilibrium and compatibility.
# The grillage is that procedure. The clause does not prescribe the mesh.
# A bilinear iso-ξ or iso-η line is straight, so a grid rib is one piece
# between crossings. A curved rib is cut so its sagitta stays inside the
# caller's tolerance: n = ceil(L / sqrt(8 R δ)) on a circular arc of length
# L and radius R.

"""One straight piece of a rib, between two shared nodes."""
struct RibPiece
    "Index of the continuous rib this piece belongs to."
    rib::Int
    "`:ξ` is a rib of constant ξ. `:η` is a rib of constant η."
    family::Symbol
    "Node index at the start of the piece."
    a::Int
    "Node index at the end of the piece."
    b::Int
    "The piece's parametric midpoint sits in a solid head."
    solid::Bool
end

"""Crossings and the straight pieces that meet at them."""
struct RibNetwork
    nodes::Vector{NTuple{2, Float64}}
    pieces::Vector{RibPiece}
end

"""
    rib_network(grid) -> RibNetwork

Crossings of `grid` and one straight piece between adjacent crossings.

Node `(i, j)` is the physical image of `(ξ, η) = (i/nξ, j/nη)`, with `i`
running fastest. ξ-ribs are numbered first, one per constant `i`, then
η-ribs, one per constant `j`. Pieces of one rib are stored in order, and
both families use the same node index at a crossing.
"""
function rib_network(grid::WaffleRibGrid)
    nξ, nη = grid.nξ, grid.nη
    nx = nξ + 1
    nodes = Vector{NTuple{2, Float64}}(undef, nx * (nη + 1))
    at(i, j) = j * nx + i + 1
    for j in 0:nη, i in 0:nξ
        nodes[at(i, j)] = physical_coords(grid.panel, i / nξ, j / nη)
    end
    pieces = RibPiece[]
    sizehint!(pieces, nξ * (nη + 1) + nη * (nξ + 1))
    rib = 0
    for i in 0:nξ
        rib += 1
        ξ = i / nξ
        for j in 0:(nη - 1)
            push!(pieces, RibPiece(rib, :ξ, at(i, j), at(i, j + 1),
                                   is_in_solid_head(ξ, (j + 0.5) / nη, grid.solid_head)))
        end
    end
    for j in 0:nη
        rib += 1
        η = j / nη
        for i in 0:(nξ - 1)
            push!(pieces, RibPiece(rib, :η, at(i, j), at(i + 1, j),
                                   is_in_solid_head((i + 0.5) / nξ, η, grid.solid_head)))
        end
    end
    return RibNetwork(nodes, pieces)
end

"""
    solid_head_transitions(grid) -> Vector{NTuple{2, Float64}}

Physical points where a rib enters or leaves a solid head.

Each point is the shared node between two pieces of one rib whose `solid`
flags differ. A grid with no solid head returns an empty vector.
"""
function solid_head_transitions(grid::WaffleRibGrid)
    grid.solid_head <= 0 && return NTuple{2, Float64}[]
    net = rib_network(grid)
    pts = NTuple{2, Float64}[]
    i = 1
    n = length(net.pieces)
    while i <= n
        rib = net.pieces[i].rib
        j = i
        while j < n && net.pieces[j + 1].rib == rib
            j += 1
        end
        for k in i:(j - 1)
            a = net.pieces[k]
            b = net.pieces[k + 1]
            a.solid == b.solid && continue
            push!(pts, net.nodes[a.b])
        end
        i = j + 1
    end
    return pts
end

"""Node indices of rib `rib`, in order along the rib."""
function rib_chain(net::RibNetwork, rib::Int)
    pieces = [p for p in net.pieces if p.rib == rib]
    isempty(pieces) && return Int[]
    return [pieces[1].a; [p.b for p in pieces]]
end

"""
    circular_rib_pieces(L, R, delta) -> Int

How many straight pieces a circular rib needs.

`L` is the rib length and `R` its radius. A chord `c` has sagitta
`c²/(8R)`, so pieces no longer than `sqrt(8 R δ)` keep the sagitta within
`delta`: `n = ceil(L / sqrt(8 R δ))`. An infinite radius is straight and
returns one piece.
"""
function circular_rib_pieces(L::Real, R::Real, delta::Real)
    L > 0 || throw(ArgumentError("rib length must be positive, got $L"))
    R > 0 || throw(ArgumentError("rib radius must be positive, got $R"))
    delta > 0 || throw(ArgumentError("sagitta tolerance must be positive, got $delta"))
    isinf(R) && return 1
    return max(1, ceil(Int, L / sqrt(8 * R * delta)))
end

"""
Largest distance from `points` to the chord through the first and last.

This is the sagitta of the polyline. Two points, or a chord of zero
length, have sagitta zero.
"""
function rib_sagitta(points)
    length(points) >= 2 || throw(ArgumentError("a rib needs two points"))
    a, b = points[1], points[end]
    dx, dy = b[1] - a[1], b[2] - a[2]
    L = hypot(dx, dy)
    L == 0 && return 0.0
    best = 0.0
    for p in points
        d = abs(dx * (p[2] - a[2]) - dy * (p[1] - a[1])) / L
        best = max(best, d)
    end
    return best
end

"""
    curved_rib_pieces(points, delta) -> Int

Piece count from a measured sagitta.

On a shallow circular arc the sagitta is `L²/(8R)`, and splitting the chord
into `n` equal parts divides that sagitta by `n²`. Then
`n = ceil(sqrt(Δ / δ))` is the same count as [`circular_rib_pieces`](@ref).
A polyline already inside `delta` is one piece.
"""
function curved_rib_pieces(points, delta::Real)
    delta > 0 || throw(ArgumentError("sagitta tolerance must be positive, got $delta"))
    Δ = rib_sagitta(points)
    Δ <= delta && return 1
    return ceil(Int, sqrt(Δ / delta))
end

"""Distance along a polyline."""
function _polyline_length(points)
    s = 0.0
    for i in 1:(length(points) - 1)
        a, b = points[i], points[i + 1]
        s += hypot(b[1] - a[1], b[2] - a[2])
    end
    return s
end

"""Point at arc length `dist` along `points`."""
function _point_at_arc(points, dist::Real)
    left = dist
    for i in 1:(length(points) - 1)
        a, b = points[i], points[i + 1]
        seg = hypot(b[1] - a[1], b[2] - a[2])
        if left <= seg || i == length(points) - 1
            t = seg == 0 ? 0.0 : clamp(left / seg, 0.0, 1.0)
            return (a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2]))
        end
        left -= seg
    end
    last = points[end]
    return (Float64(last[1]), Float64(last[2]))
end

"""
    curved_rib_polyline(points, delta) -> Vector{NTuple{2, Float64}}

Straight stations along a curved rib.

`delta` is the sagitta tolerance, in the same length unit as `points`.
The count is [`curved_rib_pieces`](@ref), and the stations are equally
spaced in arc length, including both ends. A rib already inside `delta`
is the chord through the ends.
"""
function curved_rib_polyline(points, delta::Real)
    length(points) >= 2 || throw(ArgumentError("a rib needs two points"))
    delta > 0 || throw(ArgumentError("sagitta tolerance must be positive, got $delta"))
    n = curved_rib_pieces(points, delta)
    n <= 1 && return [(Float64(points[1][1]), Float64(points[1][2])),
                      (Float64(points[end][1]), Float64(points[end][2]))]
    L = _polyline_length(points)
    return [_point_at_arc(points, k * L / n) for k in 0:n]
end
