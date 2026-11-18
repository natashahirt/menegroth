"""
    classify_column_position(skel, vertex_idx[, vertex_coords, edge_face_counts])

Classify column position based on whether it touches boundary edges (edges in only one face).

A boundary edge is one that belongs to exactly one face (building perimeter).
This is more robust than counting neighbors, and provides directional information
needed for DDM/EFM analysis.

# Returns
- `position`: `:interior` (no free edge), `:edge` (one free edge), `:corner`
  (two free edges that are not collinear)
- `boundary_edge_dirs`: Unit vectors along each boundary edge (for DDM exterior support detection)

A boundary edge is one graph edge in exactly one face. On a straight perimeter
that one free edge is stored as two collinear segments meeting at the column,
so a count of graph edges is not the count of free edges. ACI 318-11
§11.11.1.2 / R11.11.7.2 (corpus: aci-318-11, pages 209–211) uses the
three-sided critical section at one free edge and the two-sided section where
two free edges meet. A re-entrant corner has two non-parallel free edges and
stays `:corner`.

The 4-argument overload uses precomputed `vertex_coords` (N×3 Float64 matrix) and
`edge_face_counts` (Dict{Int,Int}) for O(1) lookups instead of O(n_faces) scans.
"""
function classify_column_position(skel::BuildingSkeleton, vertex_idx::Int,
                                  vertex_coords::Matrix{Float64},
                                  edge_face_counts::Dict{Int,Int})
    v_x = vertex_coords[vertex_idx, 1]
    v_y = vertex_coords[vertex_idx, 2]
    v_z = vertex_coords[vertex_idx, 3]
    
    # Get all horizontal neighbors
    neighbors = Graphs.neighbors(skel.graph, vertex_idx)
    boundary_edge_dirs = NTuple{2, Float64}[]
    
    for n_idx in neighbors
        n_z = vertex_coords[n_idx, 3]
        abs(n_z - v_z) > 0.01 && continue  # skip non-horizontal neighbors
        
        edge_idx = find_edge(skel, vertex_idx, n_idx)
        isnothing(edge_idx) && continue
        
        # Boundary check via precomputed dict (O(1) instead of O(n_faces))
        get(edge_face_counts, edge_idx, 0) == 1 || continue
        
        dx = vertex_coords[n_idx, 1] - v_x
        dy = vertex_coords[n_idx, 2] - v_y
        len = hypot(dx, dy)
        if len > 1e-9
            push!(boundary_edge_dirs, (dx/len, dy/len))
        end
    end
    
    position = _column_position_from_boundary_dirs(boundary_edge_dirs)
    return (position, boundary_edge_dirs)
end

"""
    _column_position_from_boundary_dirs(dirs) -> Symbol

`:interior` with no directions, `:edge` when every boundary direction lies on
one straight line (including opposite segments of the same free edge), and
`:corner` when any pair is not collinear.

`abs(dot) < 0.99` is about 8° off parallel. Opposite unit vectors on one
straight edge have `abs(dot) = 1` and stay `:edge`. A kink of more than that
is a corner, including a re-entrant corner.
"""
function _column_position_from_boundary_dirs(dirs::Vector{NTuple{2,Float64}})
    n = length(dirs)
    n == 0 && return :interior
    n == 1 && return :edge
    for i in 1:(n - 1)
        d1 = dirs[i]
        for j in (i + 1):n
            d2 = dirs[j]
            abs(d1[1] * d2[1] + d1[2] * d2[2]) < 0.99 && return :corner
        end
    end
    return :edge
end


"""
    slab_material_angle(skel, vertex_idx, vertex_coords) -> Float64

Total angle (radians) of slab material around a column vertex: the sum of the
interior angles that every horizontal face incident to the vertex subtends there.
This is the geometric discriminator between corner kinds — ≈ 2π interior, ≈ π at
a straight free edge, `< π` at a convex (outside) corner, and `> π` at a
re-entrant (inside / L-notch) corner. It also recovers the wedge angle of
non-orthogonal corners.
"""
function slab_material_angle(skel::BuildingSkeleton, vertex_idx::Int,
                             vertex_coords::Matrix{Float64})
    v_x = vertex_coords[vertex_idx, 1]
    v_y = vertex_coords[vertex_idx, 2]
    v_z = vertex_coords[vertex_idx, 3]
    total = 0.0
    for fvi in skel.face_vertex_indices
        k = findfirst(==(vertex_idx), fvi)
        isnothing(k) && continue
        n = length(fvi)
        prev = fvi[mod1(k - 1, n)]
        nxt  = fvi[mod1(k + 1, n)]
        # Only horizontal (floor) faces: both face-neighbors share the vertex's z.
        (abs(vertex_coords[prev, 3] - v_z) > 0.01 ||
         abs(vertex_coords[nxt, 3] - v_z) > 0.01) && continue
        ax = vertex_coords[prev, 1] - v_x; ay = vertex_coords[prev, 2] - v_y
        bx = vertex_coords[nxt, 1]  - v_x; by = vertex_coords[nxt, 2]  - v_y
        la = hypot(ax, ay); lb = hypot(bx, by)
        (la < 1e-9 || lb < 1e-9) && continue
        total += acos(clamp((ax * bx + ay * by) / (la * lb), -1.0, 1.0))
    end
    return total
end

"""
    classify_corner_kind(skel, vertex_idx, vertex_coords, position; tol=0.1) -> Symbol

Refine a `:corner` column into `:convex` (outside corner, slab angle `< π`) or
`:reentrant` (inside / L-notch corner, slab angle `> π`), using
[`slab_material_angle`](@ref). Returns `:none` for non-corner positions.

A re-entrant corner's critical section carries (nearly) the full 4-sided
perimeter rather than the legacy 2-sided section, so it is routed through the
general-shape engine (ACI 421.1R-99 Appendix B). `tol` (radians) guards the
π boundary against meshing noise.

The two-argument method classifies from a precomputed `angle` (radians); the
four-argument method computes it via [`slab_material_angle`](@ref).
"""
function classify_corner_kind(angle::Float64, position::Symbol; tol::Float64 = 0.1)
    position === :corner || return :none
    return angle > π + tol ? :reentrant : :convex
end

function classify_corner_kind(skel::BuildingSkeleton, vertex_idx::Int,
                              vertex_coords::Matrix{Float64}, position::Symbol;
                              tol::Float64 = 0.1)
    position === :corner || return :none
    return classify_corner_kind(slab_material_angle(skel, vertex_idx, vertex_coords),
                                position; tol = tol)
end


"""
    is_exterior_support(col::Column, span_axis::NTuple{2, Float64}) -> Bool

Determine if a column is an exterior support for spans in the given direction.

For DDM/EFM analysis, a support is "exterior" if the slab does not continue 
beyond it in the span direction. This is indicated by a boundary edge that
is perpendicular to the span axis (the boundary edge runs along the support line).

# Arguments
- `col`: Column with `boundary_edge_dirs` populated
- `span_axis`: Unit vector in the span direction (e.g., (1.0, 0.0) for X-direction)

# Returns
`true` if the column is an exterior support for this span direction.

# Examples
- Interior column: always returns `false`
- Corner column: always returns `true` (exterior in all directions)
- Edge column: returns `true` only if a boundary edge is perpendicular to span_axis
"""
function is_exterior_support(col::Column, span_axis::NTuple{2, Float64})::Bool
    # Interior columns are never exterior supports
    isempty(col.boundary_edge_dirs) && return false
    
    # Normalize span axis
    ax_len = hypot(span_axis...)
    ax_len < 1e-9 && return false
    ax = (span_axis[1]/ax_len, span_axis[2]/ax_len)
    
    # Check if any boundary edge is perpendicular to span axis
    # (A boundary edge perpendicular to the span means the slab ends at this support)
    for dir in col.boundary_edge_dirs
        # Perpendicularity: dot product ≈ 0
        dot_product = abs(ax[1]*dir[1] + ax[2]*dir[2])
        if dot_product < 0.3  # Edge is roughly perpendicular to span (within ~73°)
            return true
        end
    end
    
    return false
end

# Convenience overload with direction symbol
"""
    is_exterior_support(col::Column, span_direction::Symbol) -> Bool

Convenience method using `:x` or `:y` for span direction.
"""
function is_exterior_support(col::Column, span_direction::Symbol)::Bool
    span_axis = span_direction == :x ? (1.0, 0.0) : (0.0, 1.0)
    return is_exterior_support(col, span_axis)
end

# =============================================================================
# Column centerlines and the slab edge
# =============================================================================
#
# Skeleton vertices are column and beam centerlines. A column resize does not
# move them. `boundary_inward_normals` still records which way the slab lies,
# and `structural_offset` stays (0, 0). The slab edge is the centerline shifted
# out to the largest column face on each straight run (`slab_vertex_overhang`).
#
# Input drawn as a slab edge is shifted onto those centerlines once, by
# `apply_facade_setback!`, and is not shifted again.
# =============================================================================

"""
    _column_half_dim_m(col, d::NTuple{2,Float64}) -> Float64

Distance (meters) from column center to column face in direction `d` (unit vector).

For circular columns: D/2 in any direction.
For rectangular columns: projects `d` into the column's local frame (rotated by θ)
and returns the distance to the bounding-box face along that direction.

Equivalent to StructuralSizer's `_column_face_offset_m` but self-contained so
StructuralSynthesizer doesn't depend on a private function.
"""
_length_m(x::Unitful.Quantity) = Float64(ustrip(u"m", x))
_length_m(x::Real) = Float64(x)

function _column_half_dim_m(col::Column, d::NTuple{2,Float64})
    (col.c1 === nothing || col.c2 === nothing) && return 0.0

    c1_m = _length_m(col.c1)
    c2_m = _length_m(col.c2)

    if col.shape == :circular
        return c1_m / 2  # D/2 in any direction
    end

    # Rotate d from global frame into the column's local frame.
    θ = col.θ
    cosθ = cos(θ); sinθ = sin(θ)
    dl_x =  cosθ * d[1] + sinθ * d[2]
    dl_y = -sinθ * d[1] + cosθ * d[2]

    # Axis-aligned bounding-box intersection: t = min distance such that
    # the ray from center along d_local hits the box edge.
    tx = abs(dl_x) > 1e-9 ? c1_m / (2 * abs(dl_x)) : Inf
    ty = abs(dl_y) > 1e-9 ? c2_m / (2 * abs(dl_y)) : Inf
    return min(tx, ty)
end

"""
    _compute_inward_normal(skel, vertex_idx, neighbor_idx, edge_idx) -> NTuple{2,Float64}

Compute the unit normal pointing **inward** (toward the slab interior) for a
boundary edge connecting `vertex_idx` and `neighbor_idx`.

Uses the CCW winding of the adjacent face: for a CCW-wound polygon, the
left-hand normal of each directed edge points into the polygon interior.
We find the face that contains this boundary edge, determine the edge's
direction as it appears in the face's vertex list, and return its 90° CCW
rotation (left-hand normal).

Robust to concave polygons — does not rely on centroid position.

## Split-edge fallback

If the face's CCW vertex list does not contain `(vertex_idx, neighbor_idx)` as
a consecutive pair, the edge has been subdivided by a framing joist landing
(`_split_host_edge!`) — `neighbor_idx` is a mid-edge landing that was inserted
onto the graph but not into `face_vertex_indices`. Since a landing lies
COLINEARLY on the original edge, its direction is unchanged, so we recover
the CCW direction by finding whichever consecutive face-vertex pair contains
`vertex_idx` on the line the edge belongs to (the face's original grid corner
adjacent to `vertex_idx` in the CCW list).
"""
function _compute_inward_normal(skel::BuildingSkeleton, vertex_idx::Int,
                                neighbor_idx::Int, edge_idx::Int)
    face_idx = 0
    for (fi, face_edges) in enumerate(skel.face_edge_indices)
        if edge_idx in face_edges
            face_idx = fi
            break
        end
    end
    face_idx == 0 && error("Boundary edge $edge_idx not found in any face")

    vis = skel.face_vertex_indices[face_idx]
    vc = skel.geometry.vertex_coords
    n_v = length(vis)

    ccw_direction(v_a, v_b) = begin
        dx = vc[v_b, 1] - vc[v_a, 1]
        dy = vc[v_b, 2] - vc[v_a, 2]
        len = hypot(dx, dy)
        len < 1e-12 && error("Zero-length edge in face $face_idx")
        return (-dy / len, dx / len)              # left-hand normal (inward for CCW)
    end

    # Fast path: (vertex_idx, neighbor_idx) is a consecutive CCW pair.
    for i in 1:n_v
        v_a = vis[i]
        v_b = vis[mod1(i + 1, n_v)]
        if (v_a == vertex_idx && v_b == neighbor_idx) ||
           (v_a == neighbor_idx && v_b == vertex_idx)
            return ccw_direction(v_a, v_b)
        end
    end

    # Split-edge fallback: `neighbor_idx` is a joist landing on the original
    # boundary edge. Find the CCW neighbor of `vertex_idx` in the face vertex
    # list that lies on the same line as `edge_idx` (colinearity within a
    # tight tolerance covers any float noise from `_landing_vertex!`).
    vx, vy = vc[vertex_idx, 1], vc[vertex_idx, 2]
    nx, ny = vc[neighbor_idx, 1], vc[neighbor_idx, 2]
    edx = nx - vx
    edy = ny - vy
    edge_len = hypot(edx, edy)
    edge_len < 1e-12 && error("Zero-length split edge $edge_idx at vertex $vertex_idx")
    ux, uy = edx / edge_len, edy / edge_len

    for i in 1:n_v
        v_a = vis[i]
        v_b = vis[mod1(i + 1, n_v)]
        v_a == vertex_idx || v_b == vertex_idx || continue
        v_other = v_a == vertex_idx ? v_b : v_a
        ox = vc[v_other, 1] - vx
        oy = vc[v_other, 2] - vy
        o_len = hypot(ox, oy)
        o_len < 1e-12 && continue
        # Same direction (u · o_hat) ≈ 1 means `v_other` is the ORIGINAL grid
        # corner colinear with `vertex_idx → neighbor_idx`. Use its CCW pair.
        if (ux * ox + uy * oy) / o_len > 1 - 1e-6
            return ccw_direction(v_a, v_b)
        end
    end

    error("Edge ($vertex_idx, $neighbor_idx) not found in face $face_idx vertex list")
end

"""
    update_structural_offsets!(struc; input_is_centerline=false)

Record each column's inward boundary normals and keep its center on the
skeleton vertex.

`structural_offset` is always `(0, 0)`. The grid is the centerline, and the
slab edge moves instead (`slab_vertex_overhang`). `input_is_centerline` remains
so existing callers keep working; the centerline is no longer shifted either way.
Interior columns have no boundary normals. The slab edge follows the column
sizes, so the edge-strip tributary areas are refreshed
([`refresh_edge_strip_tributaries!`](@ref)).

The function is idempotent — safe to call repeatedly.
"""
function update_structural_offsets!(struc::BuildingStructure;
                                    input_is_centerline::Bool = false)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    efc = skel.geometry.edge_face_counts

    for col in struc.columns
        col.structural_offset = (0.0, 0.0)
        if input_is_centerline || col.position == :interior
            empty!(col.boundary_inward_normals)
            continue
        end
        col.boundary_inward_normals = _unique_inward_normals(skel, vc, efc, col.vertex_idx)
    end

    # Column sizes set the slab edge, and the slab edge is support area.
    refresh_edge_strip_tributaries!(struc)
    return struc
end

"""Unique inward unit normals of the horizontal boundary edges at `vertex_idx`."""
function _unique_inward_normals(skel, vc, efc, vertex_idx::Int)
    all_normals = NTuple{2, Float64}[]
    v_z = vc[vertex_idx, 3]
    for n_idx in Graphs.neighbors(skel.graph, vertex_idx)
        abs(vc[n_idx, 3] - v_z) > 0.01 && continue
        edge_idx = find_edge(skel, vertex_idx, n_idx)
        isnothing(edge_idx) && continue
        get(efc, edge_idx, 0) == 1 || continue
        push!(all_normals, _compute_inward_normal(skel, vertex_idx, n_idx, edge_idx))
    end
    unique_normals = NTuple{2, Float64}[]
    for n in all_normals
        any(u -> n[1] * u[1] + n[2] * u[2] > 0.95, unique_normals) && continue
        push!(unique_normals, n)
    end
    return unique_normals
end

"""
    structural_center_xy_m(skel, col::Column) -> NTuple{2,Float64}

XY position (meters) of a column's centerline. The centerline is the
skeleton vertex. `structural_offset` is `(0, 0)`.
"""
function structural_center_xy_m(skel, col::Column)
    vc = skel.geometry.vertex_coords
    vi = col.vertex_idx
    return (vc[vi, 1] + col.structural_offset[1],
            vc[vi, 2] + col.structural_offset[2])
end

"""
    group_collinear_members!(struc::BuildingStructure; 
                             member_type::Symbol=:beams, tol::Real=1e-3)

Detect separate collinear beams (sharing a node with the same direction
vector) and assign them the same `group_id` so the optimizer can give that
line one section.

This is optional. A moment connection does not require the two members to be
the same shape. Edges that already belong to one beam are one member in
`initialize_members!` and are sized once without this grouping.

Two edges are collinear if they share a vertex and `|sin(θ)| < tol` where θ is
the angle between their direction vectors (cross product test).

# Arguments
- `member_type`: `:beams`, `:columns`, or `:struts`
- `tol`: Cross-product tolerance for collinearity (default 1e-3 ≈ 0.06°)

# Effects
- Sets `member.base.group_id` for all members in detected collinear chains
- Members not part of any chain keep their existing `group_id`
"""
function group_collinear_members!(struc::BuildingStructure{T};
                                   member_type::Symbol=:beams,
                                   tol::Real=1e-3) where T
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    
    members = if member_type == :beams
        struc.beams
    elseif member_type == :columns
        struc.columns
    elseif member_type == :struts
        struc.struts
    else
        throw(ArgumentError("Unknown member_type: $member_type"))
    end
    
    isempty(members) && return struc
    
    # Build a mapping: vertex_idx → list of (member_idx, other_vertex_idx, direction_2d)
    # Only considers the first segment of each member for endpoint detection
    vertex_members = Dict{Int, Vector{@NamedTuple{m_idx::Int, other_v::Int, dir::NTuple{2,Float64}}}}()
    
    for (m_idx, m) in enumerate(members)
        seg_indices_list = segment_indices(m)
        isempty(seg_indices_list) && continue
        
        # Collect all edge endpoints for this member
        first_edge = struc.segments[seg_indices_list[1]].edge_idx
        last_edge = struc.segments[seg_indices_list[end]].edge_idx
        
        v1_first, v2_first = skel.edge_indices[first_edge]
        v1_last, v2_last = skel.edge_indices[last_edge]
        
        # Member endpoints are the outermost vertices of the segment chain
        # For single-segment members: the two endpoints of that edge
        # For multi-segment (chain): first vertex of first edge, last vertex of last edge
        # We need the overall direction
        all_verts = Set{Int}()
        for si in seg_indices_list
            e = struc.segments[si].edge_idx
            a, b = skel.edge_indices[e]
            push!(all_verts, a, b)
        end
        
        # Find the two endpoints: vertices that appear in only one edge
        vert_count = Dict{Int,Int}()
        for si in seg_indices_list
            e = struc.segments[si].edge_idx
            a, b = skel.edge_indices[e]
            vert_count[a] = get(vert_count, a, 0) + 1
            vert_count[b] = get(vert_count, b, 0) + 1
        end
        endpoints = [v for (v, c) in vert_count if c == 1]
        length(endpoints) == 2 || continue
        
        ep1, ep2 = endpoints
        dx = vc[ep2, 1] - vc[ep1, 1]
        dy = vc[ep2, 2] - vc[ep1, 2]
        L = hypot(dx, dy)
        L < 1e-9 && continue
        dir = (dx / L, dy / L)
        
        # Register at both endpoints
        entry1 = (m_idx=m_idx, other_v=ep2, dir=dir)
        entry2 = (m_idx=m_idx, other_v=ep1, dir=(-dir[1], -dir[2]))
        push!(get!(Vector{@NamedTuple{m_idx::Int, other_v::Int, dir::NTuple{2,Float64}}}, vertex_members, ep1), entry1)
        push!(get!(Vector{@NamedTuple{m_idx::Int, other_v::Int, dir::NTuple{2,Float64}}}, vertex_members, ep2), entry2)
    end
    
    # Find collinear pairs: two members sharing a vertex with parallel directions
    visited = Set{Int}()
    chains = Vector{Vector{Int}}()
    
    for (m_idx, _) in enumerate(members)
        m_idx in visited && continue
        
        chain = Int[m_idx]
        push!(visited, m_idx)
        _grow_collinear_chain!(chain, visited, m_idx, members, vertex_members, 
                               struc.segments, skel, vc, tol)
        
        if length(chain) > 1
            push!(chains, chain)
        end
    end
    
    # Assign group IDs to collinear chains
    n_grouped = 0
    for chain in chains
        gid = UInt64(hash((:collinear_group, member_type, sort(chain))))
        for m_idx in chain
            set_group_id!(members[m_idx], gid)
        end
        n_grouped += length(chain)
    end
    
    @info "Collinear grouping" member_type=member_type chains=length(chains) grouped_members=n_grouped total_members=length(members)
    return struc
end

"""Recursively grow a collinear chain from a seed member by following shared vertices."""
function _grow_collinear_chain!(chain, visited, seed_idx, members, vertex_members, 
                                 segments, skel, vc, tol)
    m = members[seed_idx]
    seg_list = segment_indices(m)
    isempty(seg_list) && return
    
    # Get endpoints of this member
    vert_count = Dict{Int,Int}()
    for si in seg_list
        e = segments[si].edge_idx
        a, b = skel.edge_indices[e]
        vert_count[a] = get(vert_count, a, 0) + 1
        vert_count[b] = get(vert_count, b, 0) + 1
    end
    endpoints = [v for (v, c) in vert_count if c == 1]
    
    for ep in endpoints
        haskey(vertex_members, ep) || continue
        for entry in vertex_members[ep]
            entry.m_idx in visited && continue
            
            # Check if the seed member also has an entry at this vertex
            seed_entries = [e for e in vertex_members[ep] if e.m_idx == seed_idx]
            isempty(seed_entries) && continue
            seed_dir = seed_entries[1].dir
            
            # Cross product test for collinearity
            cross = abs(seed_dir[1] * entry.dir[2] - seed_dir[2] * entry.dir[1])
            if cross < tol
                push!(chain, entry.m_idx)
                push!(visited, entry.m_idx)
                _grow_collinear_chain!(chain, visited, entry.m_idx, members, 
                                       vertex_members, segments, skel, vc, tol)
            end
        end
    end
end

"""
    _chain_endpoint_vertices(skel, edge_indices) -> NTuple{2, Int}

Return the two terminal skeleton vertices of a beam whose resolved chain spans
`edge_indices` (a single-element collection for an unshattered edge). Terminals
are the vertices that appear in exactly one of the chain's edges; interior
shatter vertices appear in two. Falls back to the first edge's endpoints for a
degenerate (closed-loop) chain.
"""
function _chain_endpoint_vertices(skel::BuildingSkeleton, edge_indices)
    counts = Dict{Int, Int}()
    for e in edge_indices
        v1, v2 = skel.edge_indices[e]
        counts[v1] = get(counts, v1, 0) + 1
        counts[v2] = get(counts, v2, 0) + 1
    end
    terminals = sort!([v for (v, c) in counts if c == 1])
    length(terminals) >= 2 && return (terminals[1], terminals[2])
    v1, v2 = skel.edge_indices[first(edge_indices)]
    return (v1, v2)
end

"""
    classify_beam_role(endpoints, edge_indices, column_vertices, slab_support_edges) -> Symbol

Classify a Level-0 (skeleton-input) beam's framing-hierarchy role:

- `:girder` when **both** endpoints of the resolved chain coincide with a column
  vertex (`Column.vertex_idx`, collected into `column_vertices`).
- `:joist` when the beam supports a slab — any of its `edge_indices` lies on the
  boundary of a slab cell (`slab_support_edges`, from `slab_face_edge_ids`) —
  and it is not a girder.
- `:beam` otherwise (catch-all secondary member).

`endpoints` are the two terminal vertices from `_chain_endpoint_vertices`;
`edge_indices` are the skeleton edges the beam spans (the whole chain).
"""
function classify_beam_role(endpoints::NTuple{2, Int}, edge_indices,
                            column_vertices, slab_support_edges)
    v1, v2 = endpoints
    (v1 in column_vertices && v2 in column_vertices) && return :girder
    any(e -> e in slab_support_edges, edge_indices) && return :joist
    return :beam
end

