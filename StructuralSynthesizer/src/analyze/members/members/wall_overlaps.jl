# Columns and beams that lie inside a wall are parked, not built.

# Plan tolerance [m] for "on the wall centerline". The office runners park
# pier-end columns at the same distance.
const _WALL_OVERLAP_TOL_M = 1e-3

"""
    park_wall_overlaps!(skel) -> (columns = Int[], beams = Int[])

Move every column and beam that lies inside a wall into `:absent`.

A wall is a `:walls` edge on its plan line, from its story elevation up the
pier height ([`_wall_pier_height`](@ref)). The wall is the support there, so
a member in the same place is not sized or detailed.

- A column is parked when its plan point lies on a wall centerline and its
  height overlaps the wall's height by more than the tolerance. A column
  that only touches the wall's bottom or top stays.
- A beam is parked when it is collinear with walls whose plan lines cover
  its whole length, at an elevation from the wall's base line through its
  top line. The top line is included: the slab there bears on the wall.
  A beam that the walls cover only in part stays.

A beam is any level edge outside `:columns`, `:braces`, `:walls`, and
`:absent`, the same edges [`initialize_members!`](@ref) builds as beams.
A shattered chain is parked only when every edge in it qualifies. The edges
keep their indices, so moving one back to its group restores it.

Returns the parked column and beam edge indices.
"""
function park_wall_overlaps!(skel::BuildingSkeleton)
    parked = (columns = Int[], beams = Int[])
    wall_edges = get(skel.groups_edges, :walls, Int[])
    isempty(wall_edges) && return parked
    isnothing(skel.geometry) && rebuild_geometry_cache!(skel)
    vc = skel.geometry.vertex_coords
    walls = [_wall_overlap_box(skel, eidx, vc) for eidx in wall_edges]

    column_edges = Set(get(skel.groups_edges, :columns, Int[]))
    brace_edges = Set(get(skel.groups_edges, :braces, Int[]))
    absent_edges = Set(get(skel.groups_edges, :absent, Int[]))
    wall_set = Set(wall_edges)
    beam_like(e) = !(e in column_edges || e in brace_edges || e in wall_set || e in absent_edges)

    inside = Dict{Int, Symbol}()
    for eidx in eachindex(skel.edges)
        if eidx in column_edges
            _column_in_wall(skel, eidx, vc, walls) && (inside[eidx] = :column)
        elseif beam_like(eidx)
            _beam_in_wall(skel, eidx, vc, walls) && (inside[eidx] = :beam)
        end
    end
    isempty(inside) && return parked

    # A chain is one member. Park it whole or not at all.
    chain_of = Dict{Int, Vector{Int}}()
    for (_, chain) in skel.edge_chains, e in chain
        chain_of[e] = chain
    end
    park = Set{Int}()
    for eidx in keys(inside)
        group = get(chain_of, eidx, [eidx])
        all(e -> get(inside, e, :none) === inside[eidx], group) || continue
        union!(park, group)
    end
    isempty(park) && return parked

    for e in sort!(collect(park))
        push!(inside[e] === :column ? parked.columns : parked.beams, e)
    end
    filter!(e -> !(e in park), get!(skel.groups_edges, :columns, Int[]))
    haskey(skel.groups_edges, :beams) && filter!(e -> !(e in park), skel.groups_edges[:beams])
    absent = get!(skel.groups_edges, :absent, Int[])
    for e in sort!(collect(park))
        e in absent || push!(absent, e)
    end
    @debug "Parked members inside walls" columns=length(parked.columns) beams=length(parked.beams)
    return parked
end

"""Plan line and height range of one `:walls` edge, in metres."""
function _wall_overlap_box(skel, eidx::Int, vc::Matrix{Float64})
    v1, v2 = skel.edge_indices[eidx]
    z = _wall_plan_z_m(skel, eidx, vc)
    story = _story_nearest_plan_z(skel, z)
    H = _wall_pier_height(skel, story)
    H_m = H isa Unitful.Quantity ? Float64(ustrip(u"m", H)) : Float64(H)
    return (a = (vc[v1, 1], vc[v1, 2]), b = (vc[v2, 1], vc[v2, 2]), z0 = z, z1 = z + H_m)
end

"""Distance [m] from point `p` to segment `a`–`b` in plan."""
function _plan_point_segment_distance(p, a, b)
    dx, dy = b[1] - a[1], b[2] - a[2]
    L2 = dx^2 + dy^2
    t = L2 > 0 ? clamp(((p[1] - a[1]) * dx + (p[2] - a[2]) * dy) / L2, 0.0, 1.0) : 0.0
    return hypot(p[1] - a[1] - t * dx, p[2] - a[2] - t * dy)
end

function _column_in_wall(skel, eidx::Int, vc::Matrix{Float64}, walls)
    v1, v2 = skel.edge_indices[eidx]
    hypot(vc[v1, 1] - vc[v2, 1], vc[v1, 2] - vc[v2, 2]) <= _WALL_OVERLAP_TOL_M || return false
    p = (vc[v1, 1], vc[v1, 2])
    zlo, zhi = minmax(vc[v1, 3], vc[v2, 3])
    tol = _WALL_OVERLAP_TOL_M
    return any(walls) do w
        min(zhi, w.z1) - max(zlo, w.z0) > tol &&
            _plan_point_segment_distance(p, w.a, w.b) <= tol
    end
end

function _beam_in_wall(skel, eidx::Int, vc::Matrix{Float64}, walls)
    v1, v2 = skel.edge_indices[eidx]
    tol = _WALL_OVERLAP_TOL_M
    abs(vc[v1, 3] - vc[v2, 3]) <= tol || return false
    z = (vc[v1, 3] + vc[v2, 3]) / 2
    p, q = (vc[v1, 1], vc[v1, 2]), (vc[v2, 1], vc[v2, 2])
    L = hypot(q[1] - p[1], q[2] - p[2])
    L > tol || return false
    u = ((q[1] - p[1]) / L, (q[2] - p[2]) / L)
    # Stations along the beam that collinear walls at this elevation cover.
    spans = Tuple{Float64, Float64}[]
    for w in walls
        w.z0 - tol <= z <= w.z1 + tol || continue
        _plan_point_line_distance(w.a, p, u) <= tol || continue
        _plan_point_line_distance(w.b, p, u) <= tol || continue
        s1 = (w.a[1] - p[1]) * u[1] + (w.a[2] - p[2]) * u[2]
        s2 = (w.b[1] - p[1]) * u[1] + (w.b[2] - p[2]) * u[2]
        push!(spans, minmax(s1, s2))
    end
    isempty(spans) && return false
    sort!(spans)
    reach = 0.0
    for (lo, hi) in spans
        lo > reach + tol && return false
        reach = max(reach, hi)
        reach >= L - tol && return true
    end
    return reach >= L - tol
end

"""Distance [m] from point `x` to the infinite line through `p` along unit `u`."""
_plan_point_line_distance(x, p, u) = abs((x[1] - p[1]) * u[2] - (x[2] - p[2]) * u[1])
