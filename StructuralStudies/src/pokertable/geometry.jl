# Parametric poker-table node layout. Coordinates are stored in inches and
# converted to Asap quantities at node construction.

using Asap
using Unitful

Base.@kwdef struct TableGeom
    core_length::Float64 = 60.0
    width::Float64 = 44.0
    height::Float64 = 30.0
    poker_length::Float64 = 96.0
    a_top::Float64 = 27.0
    b_top::Float64 = 19.5
    a_foot::Float64 = 24.0
    b_foot::Float64 = 16.5
    king_drop::Float64 = 12.0
    z_hub::Float64 = 28.8
    support_x::Float64 = 46.5
    end_foot_x::Float64 = 46.5
    leaf_support::Symbol = :struts   # :struts | :endleg
    hinge_stations::Int = 9
    arc_stations::Int = 11
    chord_stations::Int = 6
    spreader_stations::Int = 4
    mesh_edge::typeof(1.0u"inch") = 5.0u"inch"
end

half_width(g::TableGeom) = g.width / 2
half_core(g::TableGeom) = g.core_length / 2
leaf_depth(g::TableGeom) = (g.poker_length - g.core_length) / 2

inch_node(x, y, z, fixity=:free; id=:node) =
    Asap.Node([x * u"inch", y * u"inch", z * u"inch"], fixity, id)

function hinge_ys(g::TableGeom)
    hw = half_width(g)
    return range(-hw, hw; length = g.hinge_stations)
end

function ellipse_arc(g::TableGeom, side::Int)
    a = leaf_depth(g)
    b = half_width(g)
    x0 = side * half_core(g)
    θs = range(-π / 2, π / 2; length = g.arc_stations)
    return [(x0 + side * a * cos(θ), b * sin(θ)) for θ in θs]
end

function core_boundary_nodes(g::TableGeom)
    hc = half_core(g)
    hw = half_width(g)
    z = g.height
    ys = collect(hinge_ys(g))
    nodes = Asap.Node[]
    push!(nodes, inch_node(-hc, -hw, z; id = :core))
    push!(nodes, inch_node(hc, -hw, z; id = :core))
    for y in ys[2:end]
        push!(nodes, inch_node(hc, y, z; id = :core_hinge_p))
    end
    push!(nodes, inch_node(-hc, hw, z; id = :core))
    for y in reverse(ys)[2:end-1]
        push!(nodes, inch_node(-hc, y, z; id = :core_hinge_m))
    end
    return nodes
end

function _shoelace_xy(nodes)
    n = length(nodes)
    a = 0.0
    for i in 1:n
        x1, y1 = _node_xy(nodes[i])
        x2, y2 = _node_xy(nodes[mod1(i + 1, n)])
        a += x1 * y2 - x2 * y1
    end
    return a / 2
end

_node_xy(node) = (ustrip(u"inch", node.position[1]), ustrip(u"inch", node.position[2]))

function _node_xyz_inch(node)
    p = node.position
    return (ustrip(u"inch", p[1]), ustrip(u"inch", p[2]), ustrip(u"inch", p[3]))
end

# Inclusive chain from n0 to n1. Ends are the given nodes; interiors are new.
function ring_chain(n0, n1, n_stations, id)
    n_stations >= 2 || error("ring_chain needs at least two stations")
    x0, y0, z0 = _node_xyz_inch(n0)
    x1, y1, z1 = _node_xyz_inch(n1)
    nodes = Asap.Node[n0]
    for i in 2:(n_stations - 1)
        t = (i - 1) / (n_stations - 1)
        push!(nodes, inch_node(
            (1 - t) * x0 + t * x1,
            (1 - t) * y0 + t * y1,
            (1 - t) * z0 + t * z1;
            id,
        ))
    end
    push!(nodes, n1)
    return nodes
end

function ring_interiors(chains)
    nodes = Asap.Node[]
    for ch in chains
        append!(nodes, ch[2:end-1])
    end
    return nodes
end

function leaf_boundary_nodes(g::TableGeom, side::Int)
    hc = half_core(g)
    z = g.height
    ys = collect(hinge_ys(g))
    tag = side > 0 ? :leaf_p : :leaf_m
    nodes = Asap.Node[]
    # Walk the hinge with the leaf interior on the left (CCW), then the outer arc.
    hinge_ys_walk = side > 0 ? reverse(ys) : ys
    for y in hinge_ys_walk
        push!(nodes, inch_node(side * hc, y, z; id = tag))
    end
    arc = ellipse_arc(g, side)
    arc_walk = side > 0 ? arc : reverse(arc)
    for (x, y) in arc_walk[2:end-1]
        push!(nodes, inch_node(x, y, z; id = tag))
    end
    if _shoelace_xy(nodes) < 0
        reverse!(nodes)
    end
    return nodes
end

function base_nodes(g::TableGeom)
    A = [
        inch_node(-g.a_top, -g.b_top, g.height; id = :bearing),
        inch_node(-g.a_top,  g.b_top, g.height; id = :bearing),
        inch_node( g.a_top, -g.b_top, g.height; id = :bearing),
        inch_node( g.a_top,  g.b_top, g.height; id = :bearing),
    ]
    F = [
        inch_node(-g.a_foot, -g.b_foot, 0.0, :fixed; id = :foot),
        inch_node(-g.a_foot,  g.b_foot, 0.0, :fixed; id = :foot),
        inch_node( g.a_foot, -g.b_foot, 0.0, :fixed; id = :foot),
        inch_node( g.a_foot,  g.b_foot, 0.0, :fixed; id = :foot),
    ]
    C = inch_node(0.0, 0.0, g.z_hub; id = :hub)
    K = inch_node(0.0, 0.0, g.z_hub - g.king_drop; id = :king)
    chords = [
        ring_chain(A[1], A[3], g.chord_stations, :rail),  # south long
        ring_chain(A[2], A[4], g.chord_stations, :rail),  # north long
    ]
    spreaders = [
        ring_chain(A[1], A[2], g.spreader_stations, :rail),  # west short
        ring_chain(A[3], A[4], g.spreader_stations, :rail),  # east short
    ]
    ring = ring_interiors(vcat(chords, spreaders))
    S = [
        inch_node(-g.support_x, 0.0, g.height; id = :apex),
        inch_node( g.support_x, 0.0, g.height; id = :apex),
    ]
    E = Asap.Node[]
    if g.leaf_support === :endleg
        E = [
            inch_node(-g.end_foot_x, 0.0, 0.0, :fixed; id = :endfoot),
            inch_node( g.end_foot_x, 0.0, 0.0, :fixed; id = :endfoot),
        ]
    end
    return (; A, F, C, K, S, E, chords, spreaders, ring)
end
