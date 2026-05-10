# Segment and Member initialization from skeleton edges

"""
Initialize segments from all skeleton edges, reading lengths from the geometry cache.

Default: Lb = L (unbraced, conservative). Call `update_bracing!` after to set Lb = 0
for slab-supported beams.
"""
function initialize_segments!(struc::BuildingStructure{T}; default_Cb=1.0) where T
    skel = struc.skeleton
    empty!(struc.segments)
    
    for edge_idx in eachindex(skel.edges)
        L = edge_length(skel, edge_idx)
        # If the structure uses plain floats, strip to meters
        L_seg = T <: Unitful.Quantity ? L : ustrip(u"m", L)
        segment = Segment(edge_idx, L_seg; Lb=L_seg, Cb=default_Cb)
        push!(struc.segments, segment)
    end
    
    @debug "Initialized $(length(struc.segments)) segments (Lb=L by default)"
end

"""
    initialize_members!(struc; default_Kx=1.0, default_Ky=1.0)

Initialize typed members (Beam, Column, Strut) from skeleton edge groups.

Uses skeleton `groups_edges` to determine member type:
- `:beams` → `Beam` (with role classification)
- `:columns` → `Column` (with position classification)
- `:braces` → `Strut`

Each segment becomes one member by default (1:1 mapping).
"""
function initialize_members!(struc::BuildingStructure{T}; 
                             default_Kx=1.0, default_Ky=1.0) where T
    skel = struc.skeleton
    
    # Clear existing members
    empty!(struc.beams)
    empty!(struc.columns)
    empty!(struc.struts)
    
    # Ensure geometry cache is available (always succeeds, even for faceless
    # beam-only skeletons — rebuild produces well-typed empty fields).
    if isnothing(skel.geometry)
        rebuild_geometry_cache!(skel)
    end
    vc  = skel.geometry.vertex_coords
    efc = skel.geometry.edge_face_counts
    
    # Get edge groups from skeleton
    beam_edges = Set(get(skel.groups_edges, :beams, Int[]))
    column_edges = Set(get(skel.groups_edges, :columns, Int[]))
    brace_edges = Set(get(skel.groups_edges, :braces, Int[]))
    
    # Build reverse lookup: edge_idx → chain_id (for shattered edges)
    edge_to_chain = Dict{Int, UInt64}()
    for (chain_id, chain_edge_indices) in skel.edge_chains
        for eidx in chain_edge_indices
            edge_to_chain[eidx] = chain_id
        end
    end
    
    # Build edge_idx → seg_idx lookup
    edge_to_seg = Dict{Int, Int}()
    for (seg_idx, seg) in enumerate(struc.segments)
        edge_to_seg[seg.edge_idx] = seg_idx
    end
    
    # Track which edges have been processed (to skip chain sub-segments)
    processed_edges = Set{Int}()
    
    for (seg_idx, seg) in enumerate(struc.segments)
        edge_idx = seg.edge_idx
        edge_idx in processed_edges && continue
        
        if haskey(edge_to_chain, edge_idx)
            # This edge is part of a shattered chain — process the whole chain
            chain_id = edge_to_chain[edge_idx]
            chain_edge_indices = skel.edge_chains[chain_id]
            
            # Mark all chain edges as processed
            for eidx in chain_edge_indices
                push!(processed_edges, eidx)
            end
            
            # Collect segment indices for the chain (ordered)
            chain_seg_indices = [edge_to_seg[eidx] for eidx in chain_edge_indices]
            chain_segs = [struc.segments[si] for si in chain_seg_indices]
            
            # Compute total length and governing unbraced length
            L_total = sum(s.L for s in chain_segs)
            Lb_gov = maximum(s.Lb for s in chain_segs)
            Cb_gov = minimum(s.Cb for s in chain_segs)
            
            # Determine group from the first edge in the chain
            first_edge = chain_edge_indices[1]
            
            if first_edge in column_edges
                _create_chain_column!(struc, skel, chain_seg_indices, chain_edge_indices,
                                      L_total, Lb_gov, Cb_gov, default_Kx, default_Ky, vc, efc)
            elseif first_edge in brace_edges
                strut = Strut(chain_seg_indices, L_total;
                             Lb=Lb_gov, Kx=default_Kx, Ky=default_Ky, Cb=Cb_gov,
                             brace_type=:both)
                push!(struc.struts, strut)
            else
                role = classify_beam_role(skel, first_edge)
                beam = Beam(chain_seg_indices, L_total;
                           Lb=Lb_gov, Kx=default_Kx, Ky=default_Ky, Cb=Cb_gov,
                           role=role)
                push!(struc.beams, beam)
            end
        else
            # Standalone edge (no chain) — 1:1 mapping as before
            push!(processed_edges, edge_idx)
            
            if edge_idx in column_edges
                v1, v2 = skel.edge_indices[edge_idx]
                z1 = vc[v1, 3]
                z2 = vc[v2, 3]
                vertex_idx = z1 > z2 ? v1 : v2
                story = edge_story(skel, edge_idx)
                position, boundary_edge_dirs = classify_column_position(skel, vertex_idx, vc, efc)
                
                col = Column(seg_idx, seg.L; 
                            Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb,
                            vertex_idx=vertex_idx, story=story, position=position,
                            boundary_edge_dirs=boundary_edge_dirs)
                push!(struc.columns, col)
                
            elseif edge_idx in brace_edges
                strut = Strut(seg_idx, seg.L;
                             Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb,
                             brace_type=:both)
                push!(struc.struts, strut)
                
            else
                role = classify_beam_role(skel, edge_idx)
                beam = Beam(seg_idx, seg.L;
                           Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb,
                           role=role)
                push!(struc.beams, beam)
            end
        end
    end
    
    n_total = length(struc.beams) + length(struc.columns) + length(struc.struts)
    n_chains = length(skel.edge_chains)
    @debug "Initialized members from $(length(struc.segments)) segments" beams=length(struc.beams) columns=length(struc.columns) struts=length(struc.struts) chains=n_chains
    
    # Link columns across stories (col.column_above)
    link_column_stack!(struc)
    
    # Compute Voronoi tributary areas for columns
    compute_column_tributaries!(struc)
    
    return struc
end

"""
Create a Column from a chain of shattered edge segments.

Uses the top vertex (highest Z) of the last edge in the chain for position
classification and story assignment.
"""
function _create_chain_column!(struc, skel, chain_seg_indices, chain_edge_indices,
                                L_total, Lb_gov, Cb_gov, default_Kx, default_Ky, vc, efc)
    # Use the top vertex of the chain (highest Z) for classification
    last_edge = chain_edge_indices[end]
    v1, v2 = skel.edge_indices[last_edge]
    z1 = vc[v1, 3]
    z2 = vc[v2, 3]
    vertex_idx = z1 > z2 ? v1 : v2
    
    story = edge_story(skel, last_edge)
    position, boundary_edge_dirs = classify_column_position(skel, vertex_idx, vc, efc)
    
    col = Column(chain_seg_indices, L_total;
                Lb=Lb_gov, Kx=default_Kx, Ky=default_Ky, Cb=Cb_gov,
                vertex_idx=vertex_idx, story=story, position=position,
                boundary_edge_dirs=boundary_edge_dirs)
    push!(struc.columns, col)
end

"""
    link_column_stack!(struc::BuildingStructure)

Populate `col.column_above` for every column by matching `(x, y)` position
across stories.  A column on story `s` is linked to the column at the same
`(x, y)` on story `s + 1`, if one exists.  Roof-level columns (no column
above) keep `column_above = nothing`.

Called automatically by `initialize_members!`.
"""
function link_column_stack!(struc::BuildingStructure)
    vc = struc.skeleton.geometry.vertex_coords

    # Build (x, y, story) → Column reference lookup
    ColT = eltype(struc.columns)
    lookup = Dict{Tuple{Float64, Float64, Int}, ColT}()
    for col in struc.columns
        key = (round(vc[col.vertex_idx, 1]; digits=COORD_DIGITS),
               round(vc[col.vertex_idx, 2]; digits=COORD_DIGITS),
               col.story)
        lookup[key] = col
    end

    n_linked = 0
    for col in struc.columns
        above_key = (round(vc[col.vertex_idx, 1]; digits=COORD_DIGITS),
                     round(vc[col.vertex_idx, 2]; digits=COORD_DIGITS),
                     col.story + 1)
        col.column_above = get(lookup, above_key, nothing)
        !isnothing(col.column_above) && (n_linked += 1)
    end

    @debug "Linked column stack" total=length(struc.columns) linked=n_linked roof=(length(struc.columns) - n_linked)
end

"""
    compute_column_tributaries!(struc::BuildingStructure)

Compute and store Voronoi vertex tributary areas in the TributaryCache.

For each cell:
1. Get the cell's corner vertices (column positions)
2. Compute Voronoi clipped to the cell boundary
3. Store in `struc._tributary_caches.vertex[story][vertex_idx]`

Access via:
- `column_tributary_area(struc, col)` → total area (m²)
- `column_tributary_by_cell(struc, col)` → Dict{Int, Float64}
- `column_tributary_polygons(struc, col)` → Dict{Int, Vector{NTuple{2,Float64}}}

Note: Columns use their bottom vertex_idx, but floor cells have vertices at the floor 
elevation. We match by (x,y) position to link columns to their supported floor areas.
"""
function compute_column_tributaries!(struc::BuildingStructure{T}) where T
    isempty(struc.columns) && return struc
    
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    
    # Build (x,y) → Column lookup (rounded to avoid FP precision issues)
    col_by_xy = Dict{Tuple{Float64, Float64}, Vector{Column{T}}}()
    for col in struc.columns
        xy = (round(vc[col.vertex_idx, 1], digits=6), 
              round(vc[col.vertex_idx, 2], digits=6))
        push!(get!(col_by_xy, xy, Column{T}[]), col)
    end
    
    # Temporary storage: (story, vertex_idx) → accumulated data
    col_by_cell = Dict{Tuple{Int, Int}, Dict{Int, AreaQuantity}}()
    col_polygons = Dict{Tuple{Int, Int}, Dict{Int, Vector{NTuple{2, LengthQuantity}}}}()
    col_totals = Dict{Tuple{Int, Int}, AreaQuantity}()
    
    # Process each cell
    for (cell_idx, cell) in enumerate(struc.cells)
        v_indices = skel.face_vertex_indices[cell.face_idx]
        length(v_indices) < 3 && continue
        
        # Get cell elevation from cached coordinates
        cell_z = vc[v_indices[1], 3]
        
        # Extract vertex positions from cached coordinates
        n_v = length(v_indices)
        col_positions = Vector{NTuple{2, Float64}}(undef, n_v)
        cell_xys = Vector{Tuple{Float64, Float64}}(undef, n_v)
        @inbounds for (k, vi) in enumerate(v_indices)
            x, y = vc[vi, 1], vc[vi, 2]
            col_positions[k] = (x, y)
            cell_xys[k] = (round(x, digits=6), round(y, digits=6))
        end
        
        # Compute Voronoi within cell boundary (boundary = cell vertices)
        tribs = StructuralSizer.compute_voronoi_tributaries(col_positions; floor_boundary=col_positions)
        
        # Store results (matching by x,y position)
        for (i, trib) in enumerate(tribs)
            xy = cell_xys[i]
            cols = get(col_by_xy, xy, nothing)
            isnothing(cols) && continue
            
            # vertex_idx is at the top (slab level) — match directly
            matched_col = nothing
            for col in cols
                if abs(vc[col.vertex_idx, 3] - cell_z) < 0.1
                    matched_col = col
                    break
                end
            end
            isnothing(matched_col) && continue
            
            # Accumulate in temp storage (converting to Unitful)
            key = (matched_col.story, matched_col.vertex_idx)
            if !haskey(col_by_cell, key)
                col_by_cell[key] = Dict{Int, AreaQuantity}()
                col_polygons[key] = Dict{Int, Vector{NTuple{2, LengthQuantity}}}()
                col_totals[key] = 0.0u"m^2"
            end
            
            area_unitful = trib.area * u"m^2"
            polygon_unitful = [(x * u"m", y * u"m") for (x, y) in trib.polygon]
            
            col_by_cell[key][cell_idx] = area_unitful
            col_polygons[key][cell_idx] = polygon_unitful
            col_totals[key] += area_unitful
        end
    end
    
    # Store in cache (all values are now Unitful)
    for (key, total_area) in col_totals
        story, vertex_idx = key
        cache_column_tributary!(struc, story, vertex_idx,
            total_area,
            col_by_cell[key],
            col_polygons[key])
    end
    
    # Populate tributary fields directly on each Column for Sizer access
    for col in struc.columns
        key = (col.story, col.vertex_idx)
        if haskey(col_by_cell, key)
            col.tributary_cell_indices = Set(keys(col_by_cell[key]))
            col.tributary_cell_areas = Dict{Int, Float64}(
                cell_idx => ustrip(u"m^2", area) 
                for (cell_idx, area) in col_by_cell[key]
            )
        end
    end
    
    return struc
end


"""
    classify_column_position(skel, vertex_idx[, vertex_coords, edge_face_counts])

Classify column position based on whether it touches boundary edges (edges in only one face).

A boundary edge is one that belongs to exactly one face (building perimeter).
This is more robust than counting neighbors, and provides directional information
needed for DDM/EFM analysis.

# Returns
- `position`: :interior (no boundary edges), :edge (1 boundary edge), :corner (2+ boundary edges)
- `boundary_edge_dirs`: Unit vectors along each boundary edge (for DDM exterior support detection)

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
    
    n_boundary = length(boundary_edge_dirs)
    position = n_boundary == 0 ? :interior : n_boundary >= 2 ? :corner : :edge
    return (position, boundary_edge_dirs)
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
# Structural Column Offset — Architectural → Centerline
# =============================================================================
#
# When columns are placed at architectural reference points (column face flush
# with slab edge), the structural centerline is inboard by half the column
# dimension normal to each boundary edge.  These functions compute that offset
# using the adjacent face's CCW winding to determine the inward direction —
# robust to concave floor plates and arbitrary edge orientations.
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
function _column_half_dim_m(col::Column, d::NTuple{2,Float64})
    (col.c1 === nothing || col.c2 === nothing) && return 0.0

    c1_m = Float64(ustrip(u"m", col.c1))
    c2_m = Float64(ustrip(u"m", col.c2))

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
"""
function _compute_inward_normal(skel::BuildingSkeleton, vertex_idx::Int,
                                neighbor_idx::Int, edge_idx::Int)
    # Find the single face that owns this boundary edge
    face_idx = 0
    for (fi, face_edges) in enumerate(skel.face_edge_indices)
        if edge_idx in face_edges
            face_idx = fi
            break
        end
    end
    face_idx == 0 && error("Boundary edge $edge_idx not found in any face")

    # Walk the face's CCW vertex list to find edge direction as seen by the face
    vis = skel.face_vertex_indices[face_idx]
    vc = skel.geometry.vertex_coords
    n_v = length(vis)
    for i in 1:n_v
        v_a = vis[i]
        v_b = vis[mod1(i + 1, n_v)]
        if (v_a == vertex_idx && v_b == neighbor_idx) ||
           (v_a == neighbor_idx && v_b == vertex_idx)
            # Directed edge as it appears in CCW face: v_a → v_b
            dx = vc[v_b, 1] - vc[v_a, 1]
            dy = vc[v_b, 2] - vc[v_a, 2]
            len = hypot(dx, dy)
            len < 1e-12 && error("Zero-length edge in face $face_idx")
            # Left-hand normal of CCW edge = inward: rotate (dx,dy) by +90°
            return (-dy / len, dx / len)
        end
    end
    error("Edge ($vertex_idx, $neighbor_idx) not found in face $face_idx vertex list")
end

"""
    update_structural_offsets!(struc; input_is_centerline=false)

Compute `structural_offset` and `boundary_inward_normals` for every column.

When `input_is_centerline=true`, all offsets are set to `(0,0)` — the input
vertex coordinates are already structural centerlines and no adjustment is needed.

When `input_is_centerline=false` (architectural input), edge and corner columns
are offset inward by half the column dimension normal to each boundary edge.
Interior columns always have zero offset.

Call this:
1. After `classify_column_position` (initial setup)
2. After any column resize (design iteration) to update offsets for new dimensions

The function is idempotent — safe to call repeatedly.
"""
function update_structural_offsets!(struc::BuildingStructure;
                                    input_is_centerline::Bool = false)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    efc = skel.geometry.edge_face_counts

    for col in struc.columns
        if input_is_centerline || col.position == :interior
            col.structural_offset = (0.0, 0.0)
            empty!(col.boundary_inward_normals)
            continue
        end

        # Recompute inward normals + offset from current column dimensions.
        # Multiple boundary edges may share the same inward normal (e.g., a
        # mid-edge column has two boundary edges both pointing the same way).
        # We deduplicate normals so the offset is applied once per unique
        # inward direction.
        all_normals = NTuple{2, Float64}[]
        v_idx = col.vertex_idx
        v_z = vc[v_idx, 3]

        neighbors = Graphs.neighbors(skel.graph, v_idx)
        for n_idx in neighbors
            abs(vc[n_idx, 3] - v_z) > 0.01 && continue  # horizontal only
            edge_idx = find_edge(skel, v_idx, n_idx)
            isnothing(edge_idx) && continue
            get(efc, edge_idx, 0) == 1 || continue  # boundary edges only

            n_inward = _compute_inward_normal(skel, v_idx, n_idx, edge_idx)
            push!(all_normals, n_inward)
        end

        # Deduplicate: keep only unique inward normal directions (cosine > 0.95)
        unique_normals = NTuple{2, Float64}[]
        for n in all_normals
            is_dup = false
            for u in unique_normals
                dot_val = n[1]*u[1] + n[2]*u[2]
                if dot_val > 0.95
                    is_dup = true
                    break
                end
            end
            is_dup || push!(unique_normals, n)
        end

        ox, oy = 0.0, 0.0
        for n_inward in unique_normals
            half_dim = _column_half_dim_m(col, n_inward)
            ox += n_inward[1] * half_dim
            oy += n_inward[2] * half_dim
        end

        col.boundary_inward_normals = unique_normals
        col.structural_offset = (ox, oy)
    end

    return struc
end

"""
    structural_center_xy_m(skel, col::Column) -> NTuple{2,Float64}

XY position (meters) of a column's **structural centerline**, accounting for
the inward offset from the architectural vertex.

For interior columns or when `input_is_centerline=true`, this returns the
same value as `_vertex_xy_m(skel, col.vertex_idx)`.
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

Detect collinear beams (sharing a node with the same direction vector) and assign
them the same `group_id` so the optimizer sizes them with the same section.

This enforces the constructability constraint that you don't splice a different
section mid-span along a continuous line.

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
    classify_beam_role(skel, edge_idx) -> Symbol

Classify beam role based on position in framing:
- Perimeter beams → :girder (primary)
- Interior beams on column lines → :girder
- Other beams → :beam (secondary)

Note: This is a simplified classification. For more accurate role assignment,
consider using explicit framing layout or load path analysis.
"""
function classify_beam_role(skel::BuildingSkeleton, edge_idx::Int)
    # Simple heuristic: beams on the building perimeter are girders
    # Check if edge is on any face boundary
    
    # For now, default to :beam - can be refined based on framing analysis
    # A more sophisticated approach would check if this edge lies on a column line
    return :beam
end

"""
    update_bracing!(struc; braced_by_slabs=true)

Update Lb for segments based on bracing conditions.

If `braced_by_slabs=true`, sets Lb=0 for any segment whose edge supports a slab
(top flange continuously braced by deck).
"""
function update_bracing!(struc::BuildingStructure{T}; braced_by_slabs::Bool=true) where T
    braced_by_slabs || return struc
    
    # Collect all edges that support slabs
    slab_edge_set = Set{Int}()
    for slab in struc.slabs
        for edge_idx in slab_face_edge_ids(struc, slab)
            push!(slab_edge_set, edge_idx)
        end
    end
    
    n_braced = 0
    for seg in struc.segments
        if seg.edge_idx in slab_edge_set
            seg.Lb = zero(seg.L)  # Fully braced by slab
            n_braced += 1
        end
    end
    
    @debug "Updated bracing: $(n_braced)/$(length(struc.segments)) segments braced by slabs (Lb=0)"
    return struc
end

# =============================================================================
# Discrete steel member sizing (simultaneous, catalog-based)
# =============================================================================

"""
    build_member_groups!(struc::BuildingStructure; member_type::Symbol=:beams)

Populate `struc.member_groups` from the specified member collection.

- `member_type`: Which members to group - `:beams`, `:columns`, `:struts`, or `:all`
- If `member.base.group_id === nothing`, the member is treated as its own singleton group
  and a deterministic `UInt64` group id is assigned.
- If `member.base.group_id` is set, all members with the same id are grouped together.

Note: member_indices in MemberGroup refer to indices within the specific member vector
(e.g., struc.beams[idx] for beams).
"""
function build_member_groups!(struc::BuildingStructure; member_type::Symbol=:beams)
    empty!(struc.member_groups)
    
    members = if member_type == :beams
        struc.beams
    elseif member_type == :columns
        struc.columns
    elseif member_type == :struts
        struc.struts
    elseif member_type == :all
        collect(all_members(struc))
    else
        throw(ArgumentError("Unknown member_type: $member_type. Use :beams, :columns, :struts, or :all"))
    end

    for (m_idx, m) in enumerate(members)
        gid = group_id(m) === nothing ? UInt64(hash((:singleton_member_group, member_type, m_idx))) : group_id(m)
        # Persist the resolved group id back onto the member
        set_group_id!(m, gid)

        mg = get!(struc.member_groups, gid) do
            MemberGroup(gid)
        end
        push!(mg.member_indices, m_idx)
    end

    return struc.member_groups
end

"""
    _service_load_deflections(struc, params) -> (δ_LL, δ_total)

Perform a service-load multi-RHS solve using the already-factorized stiffness
matrix. Returns two `Dict{Int, Float64}` (elementID → max deflection in meters):
  - `δ_LL`:    live-load-only deflection (for L/360 check)
  - `δ_total`: dead + live deflection (for L/240 check)

Load factors from `governing_combo(params)` are divided out to yield unfactored
(service) displacements. Only cell tributary loads (cell_dead_loads / cell_live_loads)
are included; secondary effects (vault thrust, self-weight) are omitted from the
split — this is a conservative simplification since vault thrust adds to total
deflection, making the factored-solve δ from `model.u` more conservative.
"""
function _service_load_deflections(
    struc::BuildingStructure,
    params::DesignParameters;
    resolution::Int = 20,
)
    model = struc.asap_model
    combo = governing_combo(params)
    factor_D = combo.D
    factor_L = combo.L

    dead_loads = Asap.AbstractLoad[]
    live_loads = Asap.AbstractLoad[]
    for loads in values(struc.cell_dead_loads)
        append!(dead_loads, loads)
    end
    for loads in values(struc.cell_live_loads)
        append!(live_loads, loads)
    end

    if isempty(dead_loads) && isempty(live_loads)
        empty_d = Dict{Int, Float64}()
        return (empty_d, copy(empty_d))
    end

    cases = Vector{Asap.AbstractLoad}[dead_loads, live_loads]
    u_vecs = Asap.solve(model, cases)
    u_D = u_vecs[1]
    u_L = u_vecs[2]

    # Unfactor to service-level displacements
    if factor_D != 0; u_D ./= factor_D; end
    if factor_L != 0; u_L ./= factor_L; end

    u_total = u_D .+ u_L

    δ_LL    = Asap.element_max_deflections(model, u_L; resolution=resolution)
    δ_total = Asap.element_max_deflections(model, u_total; resolution=resolution)

    return (δ_LL, δ_total)
end

"""
    _fem_to_aci_endmoments(M_start, M_end) -> (M1, M2)

Convert a pair of signed FEM internal end moments to ACI 318-19 / AISC 360-16
end-moment convention `(M1, M2)` with `|M2| ≥ |M1|`.

# FEM convention
For a column under purely end moments, the *internal* moment field is
linear and antisymmetric in single curvature (`M_start`, `M_end` opposite
signs) and even-symmetric in double curvature (same signs).

# ACI 318-19 / AISC 360-16 convention
`M1/M2 > 0` ⇔ **double** curvature (best case, low Cm),
`M1/M2 < 0` ⇔ **single** curvature (worst case, high Cm).

So same-sign FEM end moments map to a **positive** `M1/M2` ratio, and
opposite-sign FEM end moments map to a **negative** ratio.

`M2` is always returned positive (defines the reference direction);
`M1` carries the relative sign.
"""
function _fem_to_aci_endmoments(M_start::Real, M_end::Real)
    if abs(M_start) >= abs(M_end)
        M2_signed = M_start
        M1_signed = M_end
    else
        M2_signed = M_end
        M1_signed = M_start
    end

    M2 = abs(M2_signed)
    if M2 < 1e-12
        return (0.0, 0.0)
    end

    same_sign = sign(M2_signed) == sign(M1_signed) || iszero(M1_signed)
    M1 = same_sign ? abs(M1_signed) : -abs(M1_signed)
    return (M1, M2)
end

"""
    member_group_demands(struc; member_edge_group=:beams, resolution=200, params=DesignParameters())

Compute governing demands and geometry for each `MemberGroup` by enveloping ASAP internal
forces across all segments of all members in the group.

Conventions:
- gravity bending (strong axis) demand uses `My`
- weak-axis bending demand uses `Mz`
- shear demand uses `Vy`/`Vz` (mapped to weak/strong)
- deflection uses max local Z displacement from `ElementDisplacements.ulocal`

For columns (`member_edge_group == :columns`), signed end moments are
extracted at the start of the first segment and the end of the last
segment of each member, then converted to ACI 318-19 / AISC 360-16
`(M1, M2)` convention via [`_fem_to_aci_endmoments`](@ref). The group's
`M1x/M2x/M1y/M2y` are taken from the column with the largest |M2|.
This lets the slenderness path compute `Cm = 0.6 − 0.4·(M1/M2)`
instead of falling back on the conservative `M1 = 0` stand-in.

When `params` is provided and cell dead/live loads are available, a service-load
multi-RHS solve separates LL-only and total (DL+LL) deflections. Otherwise
the factored-solve deflection is used for both (conservative).

For multi-segment members (shattered edges), the `δ_max` in the returned demand
is pre-scaled so that `δ_max / L_total == δ_original / L_defl`, where `L_defl`
is the longest individual sub-segment (the actual deflection span between supports).

Returns `(group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)`.
"""
function member_group_demands(struc::BuildingStructure;
    member_edge_group::Symbol=:beams, resolution::Int=200,
    params::DesignParameters=DesignParameters())
    isempty(struc.asap_model.elements) && throw(ArgumentError("ASAP model is empty. Call `to_asap!(struc)` before sizing."))

    skel = struc.skeleton
    beam_edge_ids = Set(get(skel.groups_edges, member_edge_group, Int[]))

    member_type = member_edge_group == :columns ? :columns :
                  member_edge_group == :struts ? :struts : :beams
    member_array = member_type == :columns ? struc.columns :
                   member_type == :struts ? struc.struts : struc.beams

    # Always rebuild — groups are member-type-specific, and the shared dict
    # may hold stale groups from a previous call with a different member type.
    build_member_groups!(struc; member_type=member_type)

    all_group_ids = sort(collect(keys(struc.member_groups)))
    n_groups = length(all_group_ids)

    # Use lazy-cached element-to-loads map (avoids O(n_loads) rebuild per call)
    element_loads = Asap.get_elemental_loads(struc.asap_model)

    # Whether to extract signed end moments for ACI 318-19 slenderness Cm.
    # Only meaningful for columns; beams/struts use the conservative M1=0 default.
    extract_end_moments = member_type === :columns

    # Preallocated per-group parallel storage
    par_has  = Vector{Bool}(undef, n_groups)
    par_Pu_c = Vector{Float64}(undef, n_groups)
    par_Pu_t = Vector{Float64}(undef, n_groups)
    par_Mux  = Vector{Float64}(undef, n_groups)
    par_Muy  = Vector{Float64}(undef, n_groups)
    par_Vus  = Vector{Float64}(undef, n_groups)
    par_Vuw  = Vector{Float64}(undef, n_groups)
    par_δ    = Vector{Float64}(undef, n_groups)
    par_Ir   = Vector{Float64}(undef, n_groups)
    par_L    = Vector{Float64}(undef, n_groups)
    par_Lb   = Vector{Float64}(undef, n_groups)
    par_Cb   = Vector{Float64}(undef, n_groups)
    par_Kx   = Vector{Float64}(undef, n_groups)
    par_Ky   = Vector{Float64}(undef, n_groups)
    par_Ldefl = Vector{Float64}(undef, n_groups)  # deflection span (longest sub-segment)
    # Signed (M1, M2) per group, ACI 318-19 sign convention. Selected from the
    # member with the largest |M2| in each axis. Defaulted to (0,0) when no
    # column member is present (e.g., beam/strut groups).
    par_M1x = zeros(Float64, n_groups); par_M2x = zeros(Float64, n_groups)
    par_M1y = zeros(Float64, n_groups); par_M2y = zeros(Float64, n_groups)

    Threads.@threads for g in 1:n_groups
        gid = all_group_ids[g]
        mg = struc.member_groups[gid]

        Pu_comp = 0.0; Pu_tens = 0.0
        Mux = 0.0; Muy = 0.0
        Vu_strong = 0.0; Vu_weak = 0.0
        L_total = 0.0; Lb_gov = 0.0; Cb_gov = Inf
        L_defl = 0.0  # longest individual segment (deflection span)
        Kx_gov = 0.0; Ky_gov = 0.0
        has_any = false
        δ_max = 0.0; I_ref = 0.0

        # End-moment selection (column groups only). We pick the (M1, M2) from
        # whichever member in the group has the largest |M2| in that axis —
        # the worst-case Cm dominates the slenderness amplification.
        best_M2x = 0.0; best_M1x = 0.0
        best_M2y = 0.0; best_M1y = 0.0

        for m_idx in mg.member_indices
            m = member_array[m_idx]
            Kx_gov = max(Kx_gov, m.base.Kx)
            Ky_gov = max(Ky_gov, m.base.Ky)

            seg_list = segment_indices(m)
            n_segs = length(seg_list)

            # Per-member end-moment scratch (FEM internal-moment convention).
            # Walked in segment order: start = f.M[1] of first segment, end =
            # f.M[end] of last segment. Multi-segment columns walk through
            # interior splice points; only the outermost values matter for Cm.
            local_My_start = 0.0; local_My_end = 0.0
            local_Mz_start = 0.0; local_Mz_end = 0.0
            saw_first_seg = false; saw_last_seg = false

            for (seg_pos, seg_idx) in enumerate(seg_list)
                seg = struc.segments[seg_idx]
                edge_idx = seg.edge_idx
                edge_idx in beam_edge_ids || continue

                has_any = true
                len_val = to_meters(seg.L)
                lb_val  = to_meters(seg.Lb)
                L_total += len_val
                Lb_gov = max(Lb_gov, lb_val)
                L_defl = max(L_defl, len_val)  # track longest sub-segment
                Cb_gov = min(Cb_gov, seg.Cb)

                el = struc.asap_model.elements[edge_idx]
                el_loads = element_loads[el.elementID]

                # Combined forces + displacements in one pass (shared L, xinc, load iteration)
                fd = Asap.ElementForceAndDisplacement(el, el_loads; resolution=resolution)
                f = fd.forces
                edisp = fd.displacements

                min_P = minimum(f.P); max_P = maximum(f.P)
                if min_P < 0; Pu_comp = max(Pu_comp, abs(min_P)); end
                if max_P > 0; Pu_tens = max(Pu_tens, max_P); end

                Mux = max(Mux, mapreduce(abs, max, f.My))
                Vu_strong = max(Vu_strong, mapreduce(abs, max, f.Vz))
                Muy = max(Muy, mapreduce(abs, max, f.Mz))
                Vu_weak = max(Vu_weak, mapreduce(abs, max, f.Vy))

                δ_local = mapreduce(j -> abs(edisp.ulocal[3, j]), max, 1:size(edisp.ulocal, 2))
                δ_max = max(δ_max, δ_local)

                I_current = ustrip(u"m^4", el.section.Ix)
                I_ref = max(I_ref, I_current)

                if extract_end_moments
                    if seg_pos == 1
                        local_My_start = Float64(f.My[1])
                        local_Mz_start = Float64(f.Mz[1])
                        saw_first_seg = true
                    end
                    if seg_pos == n_segs
                        local_My_end = Float64(f.My[end])
                        local_Mz_end = Float64(f.Mz[end])
                        saw_last_seg = true
                    end
                end
            end

            if extract_end_moments && saw_first_seg && saw_last_seg
                M1x_m, M2x_m = _fem_to_aci_endmoments(local_My_start, local_My_end)
                M1y_m, M2y_m = _fem_to_aci_endmoments(local_Mz_start, local_Mz_end)
                if M2x_m > best_M2x
                    best_M2x = M2x_m; best_M1x = M1x_m
                end
                if M2y_m > best_M2y
                    best_M2y = M2y_m; best_M1y = M1y_m
                end
            end
        end

        par_has[g]  = has_any
        par_Pu_c[g] = Pu_comp; par_Pu_t[g] = Pu_tens
        par_Mux[g]  = Mux;     par_Muy[g]  = Muy
        par_Vus[g]  = Vu_strong; par_Vuw[g] = Vu_weak
        par_δ[g]    = δ_max;   par_Ir[g]   = I_ref
        par_L[g]    = L_total; par_Lb[g]   = Lb_gov
        par_Cb[g]   = Cb_gov;  par_Kx[g]   = Kx_gov; par_Ky[g] = Ky_gov
        par_Ldefl[g] = L_defl
        par_M1x[g] = best_M1x; par_M2x[g] = best_M2x
        par_M1y[g] = best_M1y; par_M2y[g] = best_M2y
    end

    # ── Service-load deflection split (LL-only vs DL+LL) ──
    # Solve for unfactored dead and live displacements separately,
    # then extract per-element max deflections.
    has_split = !isempty(struc.cell_dead_loads) || !isempty(struc.cell_live_loads)
    local δ_LL_map::Dict{Int, Float64}
    local δ_total_map::Dict{Int, Float64}
    if has_split
        δ_LL_map, δ_total_map = _service_load_deflections(struc, params)
    else
        δ_LL_map = Dict{Int, Float64}()
        δ_total_map = Dict{Int, Float64}()
    end

    # Aggregate service deflections per group (max over all segments)
    par_δ_LL    = Vector{Float64}(undef, n_groups)
    par_δ_total = Vector{Float64}(undef, n_groups)
    Threads.@threads for g in 1:n_groups
        par_has[g] || (par_δ_LL[g] = 0.0; par_δ_total[g] = 0.0; continue)
        gid = all_group_ids[g]
        mg = struc.member_groups[gid]
        δ_ll = 0.0; δ_tot = 0.0
        for m_idx in mg.member_indices
            m = member_array[m_idx]
            for seg_idx in segment_indices(m)
                seg = struc.segments[seg_idx]
                edge_idx = seg.edge_idx
                edge_idx in beam_edge_ids || continue
                el = struc.asap_model.elements[edge_idx]
                eid = el.elementID
                δ_ll  = max(δ_ll,  get(δ_LL_map, eid, 0.0))
                δ_tot = max(δ_tot, get(δ_total_map, eid, 0.0))
            end
        end
        par_δ_LL[g] = δ_ll
        par_δ_total[g] = δ_tot
    end

    # Sequential filter & renumber indices
    group_ids = UInt64[]
    demands   = StructuralSizer.MemberDemand{Float64, Nothing}[]
    L_totals  = Float64[]
    Lb_govs   = Float64[]
    Cb_govs   = Float64[]
    Kx_govs   = Float64[]
    Ky_govs   = Float64[]
    Ldefl_govs = Float64[]

    for g in 1:n_groups
        par_has[g] || continue
        push!(group_ids, all_group_ids[g])
        g_idx = length(group_ids)

        L_t = par_L[g]
        L_d = par_Ldefl[g]
        scale = (L_d > 0 && L_d < L_t) ? L_t / L_d : 1.0

        δ_ll_adj    = has_split ? par_δ_LL[g] * scale    : par_δ[g] * scale
        δ_total_adj = has_split ? par_δ_total[g] * scale  : 0.0

        # For column groups, par_M*x/par_M*y carry signed (M1, M2) per ACI
        # 318-19 from FEA. For other member types we leave M1/M2 unset so
        # the `MemberDemand` constructor falls back to its conservative
        # default (`M1 = 0`, `M2 = Mux/Muy` ⇒ Cm = 0.6).
        if extract_end_moments
            d = StructuralSizer.MemberDemand(g_idx;
                Pu_c=par_Pu_c[g], Pu_t=par_Pu_t[g],
                Mux=par_Mux[g], Muy=par_Muy[g],
                M1x=par_M1x[g], M2x=par_M2x[g],
                M1y=par_M1y[g], M2y=par_M2y[g],
                Vu_strong=par_Vus[g], Vu_weak=par_Vuw[g],
                δ_max_LL=δ_ll_adj, δ_max_total=δ_total_adj,
                I_ref=par_Ir[g],
                transverse_load=false)
        else
            d = StructuralSizer.MemberDemand(g_idx;
                Pu_c=par_Pu_c[g], Pu_t=par_Pu_t[g],
                Mux=par_Mux[g], Muy=par_Muy[g],
                Vu_strong=par_Vus[g], Vu_weak=par_Vuw[g],
                δ_max_LL=δ_ll_adj, δ_max_total=δ_total_adj,
                I_ref=par_Ir[g])
        end

        push!(demands, d)
        push!(L_totals, par_L[g])
        push!(Lb_govs, par_Lb[g])
        push!(Cb_govs, par_Cb[g])
        push!(Kx_govs, par_Kx[g])
        push!(Ky_govs, par_Ky[g])
    end

    return group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs
end

"""
    size_steel_members!(struc; catalog, material, member_edge_group, ...)

Discrete, simultaneous catalog-based sizing for steel members using a MIP.
Respects `Member.group_id` by solving at the group level.

Uses `AISCChecker` for capacity checks and `StructuralSizer.to_asap_section`
for ASAP model updates.

# Arguments
- `catalog`: Steel section catalog (default: all W shapes)
- `material`: Steel grade (default: A992_Steel)
- `member_edge_group`: Which edge group to size — `:beams`, `:columns`, `:struts` (default: `:beams`)
- `deflection_limit`: L/δ ratio, e.g. `1/360`. `nothing` = strength-only (default: `nothing`)

Side effects:
- populates/overwrites `struc.member_groups[gid].section`
- populates each `member.section` and `member.volumes`
- updates ASAP element sections for all member segments in `member_edge_group`
"""
function size_steel_members!(
    struc::BuildingStructure;
    catalog=StructuralSizer.all_W(),
    material=StructuralSizer.A992_Steel,
    member_edge_group::Symbol=:beams,
    max_depth=Inf * u"m",
    n_max_sections::Integer=0,
    solver::Symbol=:auto,
    resolution::Int=200,
    reanalyze::Bool=true,
    gravity_factor::Quantity=GRAVITY,  # standard gravity (9.80665 m/s²)
    deflection_limit::Union{Nothing, Real}=nothing,  # e.g., 1/360
    skel = struc.skeleton,
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[])))
    
    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)
    
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution)

    # Determine member array from edge group name (must match member_group_demands logic)
    member_array = member_edge_group == :columns ? struc.columns :
                   member_edge_group == :struts ? struc.struts : struc.beams

    # Convert to SteelMemberGeometry objects for new API
    geometries = [StructuralSizer.SteelMemberGeometry(L; Lb=Lb, Cb=Cb, Kx=Kx, Ky=Ky)
                  for (L, Lb, Cb, Kx, Ky) in zip(L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)]
    
    # Create AISC checker with design constraints
    checker = StructuralSizer.AISCChecker(;
        max_depth=max_depth,
        deflection_limit=deflection_limit,
    )
    
    # Choose solver: binary search (fast, per-group optimal) when there are no
    # shared-section constraints; MIP when n_max_sections is active.
    if n_max_sections > 0
        result = StructuralSizer.optimize_discrete(
            checker, demands, geometries, catalog, material;
            n_max_sections=n_max_sections,
            optimizer=solver,
        )
        solver_name = "MIP"
    else
        result = StructuralSizer.optimize_binary_search(
            checker, demands, geometries, catalog, material,
        )
        solver_name = "binary search"
    end

    # Apply results to member groups + ASAP elements + individual members
    for (g_idx, gid) in enumerate(group_ids)
        chosen_template = result.sections[g_idx]
        
        # Create a copy with the specific material for this group
        # (Catalog sections usually have material=nothing)
        chosen = copy(chosen_template)
        chosen.material = material

        mg = struc.member_groups[gid]
        mg.section = chosen

        # Build ASAP section once per group
        asap_sec = StructuralSizer.to_asap_section(chosen, material)

        for m_idx in mg.member_indices
            m = member_array[m_idx]  # Index into appropriate member array
            
            # Compute total length and store section/volume on member
            # Ensure L_total has units (skeleton may use plain Float64)
            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_volumes!(m, MaterialVolumes(material => StructuralSizer.section_area(chosen) * L_total))
            
            # Update ASAP elements
            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
                struc.asap_model.elements[edge_idx].section = asap_sec
            end
        end
    end

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    defl_str = isnothing(deflection_limit) ? "none" : "L/$(Int(round(1/deflection_limit)))"
    @info "Sized $(length(group_ids)) steel member groups via $solver_name" n_max_sections=n_max_sections deflection_limit=defl_str
    return struc
end


# =============================================================================
# T-Beam Flange Parameters (ACI 318-11 §8.12.2)
# =============================================================================

"""
    _compute_flange_params(struc, group_ids, L_totals; bw_default=12.0u"inch")
        -> (bf_vec, hf_vec)

Compute effective T-beam flange width and slab thickness per beam group.

For each beam group:
1. Finds adjacent slabs via edge→slab mapping
2. Extracts slab thickness (`hf`) as the minimum across adjacent slabs
3. Determines beam position (`:interior` or `:edge`) from `edge_face_counts`
   — boundary edges (count=1) indicate edge beams
4. Reads the beam's `tributary_width` as the clear spacing `sw`
5. Computes effective flange width via `effective_flange_width`

Groups without adjacent slabs get `bf = nothing`, `hf = nothing`.

# Returns
`(bf_vec, hf_vec)` — vectors of `Union{Nothing, Length}` per group.
"""
function _compute_flange_params(
    struc::BuildingStructure,
    group_ids::Vector{UInt64},
    L_totals::Vector{Float64};
    bw_default::Unitful.Length = 12.0u"inch",
)
    skel = struc.skeleton
    efc = skel.geometry.edge_face_counts

    # Build edge → slab thickness mapping
    edge_slab_hf = Dict{Int, Vector{typeof(1.0u"m")}}()
    for slab in struc.slabs
        hf = uconvert(u"m", StructuralSizer.total_depth(slab.result))
        for cell_idx in slab.cell_indices
            face_idx = struc.cells[cell_idx].face_idx
            for e_idx in skel.face_edge_indices[face_idx]
                push!(get!(Vector{typeof(1.0u"m")}, edge_slab_hf, e_idx), hf)
            end
        end
    end

    member_array = struc.beams
    n_groups = length(group_ids)

    bf_vec = Vector{Union{Nothing, typeof(1.0u"m")}}(nothing, n_groups)
    hf_vec = Vector{Union{Nothing, typeof(1.0u"m")}}(nothing, n_groups)

    for (g_idx, gid) in enumerate(group_ids)
        mg = struc.member_groups[gid]

        slab_hfs = typeof(1.0u"m")[]
        sizehint!(slab_hfs, 4)  # typical: 1-4 edges per member group
        max_face_count = 0
        trib_w_m = 0.0  # meters

        for m_idx in mg.member_indices
            m = member_array[m_idx]

            # Tributary width (beam spacing proxy)
            if !isnothing(m.tributary_width)
                tw = m.tributary_width isa Unitful.Quantity ?
                    ustrip(u"m", m.tributary_width) : Float64(m.tributary_width)
                trib_w_m = max(trib_w_m, tw)
            end

            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                if haskey(edge_slab_hf, edge_idx)
                    append!(slab_hfs, edge_slab_hf[edge_idx])
                    max_face_count = max(max_face_count, get(efc, edge_idx, 0))
                end
            end
        end

        # No adjacent slabs → stays rectangular
        isempty(slab_hfs) && continue

        hf = minimum(slab_hfs)
        hf_vec[g_idx] = hf

        # Position: boundary edge (count=1) → :edge, interior (count≥2) → :interior
        pos = max_face_count >= 2 ? :interior : :edge

        # Span and spacing
        ln = L_totals[g_idx] * u"m"
        sw = trib_w_m > 0 ? trib_w_m * u"m" : ln / 4  # fallback

        bf = StructuralSizer.effective_flange_width(
            bw=bw_default, hf=hf, sw=sw, ln=ln, position=pos)
        bf_vec[g_idx] = bf
    end

    return bf_vec, hf_vec
end

# =============================================================================
# Beam Sizing Dispatcher
# =============================================================================

"""
    size_beams!(struc, opts; method=:discrete, ...)

Size beams, dispatching on material (steel vs concrete) and method (:discrete / :nlp).

# Dispatch Table
| Options type         | method     | Implementation                           |
|:---------------------|:-----------|:-----------------------------------------|
| SteelBeamOptions     | :discrete  | `size_steel_members!`                    |
| ConcreteBeamOptions  | :discrete  | MIP via `size_beams` or `size_tbeams`    |
| ConcreteBeamOptions  | :nlp       | NLP via `size_rc_beams_nlp` / `_tbeams`  |

If no options are provided, falls back to `struc.design_parameters.beams`,
then to `SteelBeamOptions()`.

The concrete beam path extracts Mu, Vu, and Nu from the Asap analysis
results and passes them through to the ACI 318 beam checker. When Nu > 0
(axial compression from frame action), Vc is increased per ACI §22.5.6.1.

When `ConcreteBeamOptions.include_flange = true`, the dispatcher automatically:
- Reads slab thicknesses from `struc.slabs` (slabs must be sized first)
- Computes effective flange widths per ACI 318-11 §8.12.2 using beam
  tributary widths and edge/interior classification
- Routes to `size_tbeams` (discrete) or `size_rc_tbeams_nlp` (NLP)

# Example
```julia
# Steel beams with L/360 deflection check
size_beams!(struc, SteelBeamOptions(deflection_limit = 1/360))

# RC rectangular beams (discrete catalog MIP)
size_beams!(struc, ConcreteBeamOptions(material = NWC_5000))

# RC T-beams — auto-detects flange from slab data
size_beams!(struc, ConcreteBeamOptions(material = NWC_5000, include_flange = true))
```
"""
function size_beams!(
    struc::BuildingStructure,
    opts::Union{StructuralSizer.BeamOptions, Nothing} = nothing;
    method::Union{Symbol, Nothing} = nothing,
    resolution::Int = 200,
    reanalyze::Bool = true,
    gravity_factor::Quantity = GRAVITY,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
)
    dp = (hasproperty(struc, :design_parameters) && !isnothing(struc.design_parameters)) ?
         struc.design_parameters : nothing

    effective_opts = if !isnothing(opts)
        opts
    elseif !isnothing(dp) && !isnothing(dp.beams)
        dp.beams
    else
        obj = !isnothing(dp) ? resolve_objective(dp.optimize_for) : StructuralSizer.MinWeight()
        StructuralSizer.SteelBeamOptions(objective=obj)
    end

    # Resolve strategy: explicit `method` kwarg wins, else read from opts field
    strategy = if !isnothing(method)
        method
    elseif hasproperty(effective_opts, :sizing_strategy)
        effective_opts.sizing_strategy
    else
        :discrete
    end

    StructuralSizer.emit!(tc, :sizing, "size_beams!", "", :enter;
                          opts_type=string(typeof(effective_opts)),
                          strategy=string(strategy))

    if hasproperty(struc, :design_parameters) && !isnothing(struc.design_parameters) && struc.design_parameters.collinear_grouping
        group_collinear_members!(struc; member_type=:beams)
    end

    result = _size_beams_impl!(struc, effective_opts, Val(strategy);
                               resolution, reanalyze, gravity_factor)
    StructuralSizer.emit!(tc, :sizing, "size_beams!", "", :exit)
    return result
end

# --- Steel beams (discrete) — calls public StructuralSizer.size_beams ---
function _size_beams_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.SteelBeamOptions,
    ::Val{:discrete};
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
)
    skel = struc.skeleton
    edge_ids_in_group = Set(get(skel.groups_edges, :beams, Int[]))
    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=:beams, resolution=resolution)

    isempty(group_ids) && return struc

    geometries = [StructuralSizer.SteelMemberGeometry(L; Lb=Lb, Cb=Cb, Kx=Kx, Ky=Ky)
                  for (L, Lb, Cb, Kx, Ky) in zip(L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)]

    Mu_vec = [d.Mux for d in demands]
    Vu_vec = [d.Vu_strong for d in demands]
    δ_LL_vec   = [d.δ_max_LL for d in demands]
    δ_total_vec = [d.δ_max_total for d in demands]
    I_ref_v  = [d.I_ref for d in demands]

    result = StructuralSizer.size_beams(
        Mu_vec, Vu_vec, geometries, opts;
        δ_max_vec = any(>(0), δ_LL_vec)   ? δ_LL_vec   : nothing,
        δ_max_total_vec = any(>(0), δ_total_vec) ? δ_total_vec : nothing,
        I_ref_vec = any(>(0), I_ref_v)    ? I_ref_v    : nothing,
    )

    member_array = struc.beams
    mat = opts.material
    _apply_beam_results!(struc, result, group_ids, member_array, edge_ids_in_group, mat)

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    @info "Sized $(length(group_ids)) steel beam groups via size_beams API"
    return struc
end

# --- Shared helper: apply MIP/NLP beam results to the BuildingStructure ---
"""
    _apply_beam_results!(struc, result, group_ids, member_array, edge_ids_in_group, mat)

Apply sized sections (from MIP `result.sections`) to member groups, members, and ASAP elements.

When the result comes from multi-material optimization (`hasproperty(result, :materials_chosen)`),
each group uses its own material from `result.materials_chosen[g_idx]`. Otherwise, the single
`mat` argument is used for all groups.
"""
function _apply_beam_results!(
    struc::BuildingStructure,
    result,
    group_ids::Vector{UInt64},
    member_array,
    edge_ids_in_group::Set{Int},
    mat::StructuralSizer.AbstractMaterial,
)
    has_multi_mat = hasproperty(result, :materials_chosen)

    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]
        group_mat = has_multi_mat ? result.materials_chosen[g_idx] : mat

        mg = struc.member_groups[gid]
        mg.section = chosen

        asap_sec = StructuralSizer.to_asap_section(chosen, group_mat)

        for m_idx in mg.member_indices
            m = member_array[m_idx]

            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_volumes!(m, MaterialVolumes(group_mat => StructuralSizer.section_area(chosen) * L_total))

            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
                struc.asap_model.elements[edge_idx].section = asap_sec
            end
        end
    end
end

# --- Concrete beams (discrete MIP) ---
function _size_beams_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.ConcreteBeamOptions,
    ::Val{:discrete};
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
)
    skel = struc.skeleton
    edge_ids_in_group = Set(get(skel.groups_edges, :beams, Int[]))

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Extract demands from analysis (MemberDemand in SI: N, N·m, m)
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=:beams, resolution=resolution)

    isempty(group_ids) && return struc

    member_array = struc.beams

    # Build demand vectors with Unitful SI units
    Mu = [d.Mux * u"N*m"      for d in demands]
    Vu = [d.Vu_strong * u"N"   for d in demands]
    Nu = [d.Pu_c * u"N"        for d in demands]

    # Build geometries (L_totals are Float64 in meters)
    geoms = [StructuralSizer.ConcreteMemberGeometry(L) for L in L_totals]

    # ── T-beam path (include_flange = true) ──
    if opts.include_flange
        isempty(struc.slabs) && error(
            "include_flange=true but no slabs found. Size slabs first.")

        bf_vec, hf_vec = _compute_flange_params(struc, group_ids, L_totals)

        # Envelope: use min bf/hf across groups that have slabs (conservative)
        valid = findall(!isnothing, bf_vec)
        if isempty(valid)
            @warn "include_flange=true but no beams have adjacent slabs — " *
                  "falling back to rectangular beam sizing"
        else
            bf_env = minimum(bf_vec[i] for i in valid)
            hf_env = minimum(hf_vec[i] for i in valid)

            result = StructuralSizer.size_tbeams(
                Mu, Vu, geoms, opts;
                flange_width     = bf_env,
                flange_thickness = hf_env,
                Nu               = Nu,
                catalog_size     = opts.catalog_size_tbeam,
            )

            _apply_beam_results!(struc, result, group_ids, member_array,
                                 edge_ids_in_group, opts.material)

            if reanalyze
                Asap.process!(struc.asap_model)
                Asap.solve!(struc.asap_model)
            end

            fc_psi = round(Int, ustrip(u"psi", opts.material.fc′))
            bf_in  = round(ustrip(u"inch", bf_env); digits=1)
            hf_in  = round(ustrip(u"inch", hf_env); digits=1)
            @info "Sized $(length(group_ids)) RC T-beam groups via MIP" fc_psi bf_in hf_in

            return struc
        end
    end

    # ── Rectangular beam path (default) ──
    result = StructuralSizer.size_beams(Mu, Vu, geoms, opts; Nu=Nu)

    _apply_beam_results!(struc, result, group_ids, member_array,
                         edge_ids_in_group, opts.material)

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    fc_psi = round(Int, ustrip(u"psi", opts.material.fc′))
    @info "Sized $(length(group_ids)) RC beam groups via MIP" fc_psi=fc_psi

    return struc
end

# --- Concrete beams (NLP) ---
function _size_beams_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.ConcreteBeamOptions,
    ::Val{:nlp};
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
)
    skel = struc.skeleton
    edge_ids_in_group = Set(get(skel.groups_edges, :beams, Int[]))

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Extract demands from analysis (MemberDemand in SI: N, N·m, m)
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=:beams, resolution=resolution)

    isempty(group_ids) && return struc

    member_array = struc.beams

    # Build demand vectors with Unitful SI units
    Mu = [d.Mux * u"N*m"    for d in demands]
    Vu = [d.Vu_strong * u"N" for d in demands]

    # Map ConcreteBeamOptions → NLPBeamOptions (shared material fields)
    stirrup_int = parse(Int, replace(string(opts.transverse_bar_size), "no" => ""))
    nlp_opts = StructuralSizer.NLPBeamOptions(
        material       = opts.material,
        rebar_material = opts.rebar_material,
        cover      = opts.cover,
        stirrup_size = stirrup_int,
        max_depth  = opts.max_depth,
        max_width  = isfinite(opts.max_width) ? opts.max_width : 24.0u"inch",
        objective  = opts.objective,
    )

    # ── T-beam path (include_flange = true) ──
    if opts.include_flange
        isempty(struc.slabs) && error(
            "include_flange=true but no slabs found. Size slabs first.")

        bf_vec, hf_vec = _compute_flange_params(struc, group_ids, L_totals)

        # NLP supports per-beam bf/hf vectors
        # Groups without slabs → fall back to rectangular NLP
        tbeam_idx = findall(!isnothing, bf_vec)
        rect_idx  = findall(isnothing, bf_vec)

        mat = opts.material
        n_feasible = 0

        if !isempty(tbeam_idx)
            Mu_t  = Mu[tbeam_idx]
            Vu_t  = Vu[tbeam_idx]
            bf_t  = [bf_vec[i] for i in tbeam_idx]
            hf_t  = [hf_vec[i] for i in tbeam_idx]

            t_results = StructuralSizer.size_rc_tbeams_nlp(Mu_t, Vu_t, bf_t, hf_t, nlp_opts)

            for (k, g_idx) in enumerate(tbeam_idx)
                r = t_results[k]
                r.status in (:optimal, :feasible) || continue
                n_feasible += 1

                gid = group_ids[g_idx]
                chosen = r.section
                mg = struc.member_groups[gid]
                mg.section = chosen
                asap_sec = StructuralSizer.to_asap_section(chosen, mat)

                for m_idx in mg.member_indices
                    m = member_array[m_idx]
                    L_raw = sum(struc.segments[i].L for i in segment_indices(m))
                    L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
                    set_section!(m, chosen)
                    set_volumes!(m, MaterialVolumes(mat => StructuralSizer.section_area(chosen) * L_total))
                    for seg_idx in segment_indices(m)
                        edge_idx = struc.segments[seg_idx].edge_idx
                        edge_idx in edge_ids_in_group || continue
                        struc.asap_model.elements[edge_idx].section = asap_sec
                    end
                end
            end
        end

        # Rectangular fallback for groups without slabs
        if !isempty(rect_idx)
            Mu_r = Mu[rect_idx]
            Vu_r = Vu[rect_idx]
            r_results = StructuralSizer.size_rc_beams_nlp(Mu_r, Vu_r, nlp_opts)

            for (k, g_idx) in enumerate(rect_idx)
                r = r_results[k]
                r.status in (:optimal, :feasible) || continue
                n_feasible += 1

                gid = group_ids[g_idx]
                chosen = r.section
                mg = struc.member_groups[gid]
                mg.section = chosen
                asap_sec = StructuralSizer.to_asap_section(chosen, mat)

                for m_idx in mg.member_indices
                    m = member_array[m_idx]
                    L_raw = sum(struc.segments[i].L for i in segment_indices(m))
                    L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
                    set_section!(m, chosen)
                    set_volumes!(m, MaterialVolumes(mat => StructuralSizer.section_area(chosen) * L_total))
                    for seg_idx in segment_indices(m)
                        edge_idx = struc.segments[seg_idx].edge_idx
                        edge_idx in edge_ids_in_group || continue
                        struc.asap_model.elements[edge_idx].section = asap_sec
                    end
                end
            end
        end

        if reanalyze
            Asap.process!(struc.asap_model)
            Asap.solve!(struc.asap_model)
        end

        fc_psi = round(Int, ustrip(u"psi", mat.fc′))
        n_total = length(group_ids)
        n_tbeam = length(tbeam_idx)
        @info "Sized $n_feasible/$n_total RC beam groups via NLP ($(n_tbeam) T-beam)" fc_psi

        return struc
    end

    # ── Rectangular NLP path (default) ──
    results = StructuralSizer.size_rc_beams_nlp(Mu, Vu, nlp_opts)

    mat = opts.material
    n_feasible = 0
    for (g_idx, gid) in enumerate(group_ids)
        r = results[g_idx]
        r.status in (:optimal, :feasible) || continue
        n_feasible += 1

        chosen = r.section

        mg = struc.member_groups[gid]
        mg.section = chosen

        asap_sec = StructuralSizer.to_asap_section(chosen, mat)

        for m_idx in mg.member_indices
            m = member_array[m_idx]

            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_volumes!(m, MaterialVolumes(mat => StructuralSizer.section_area(chosen) * L_total))

            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
                struc.asap_model.elements[edge_idx].section = asap_sec
            end
        end
    end

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    fc_psi = round(Int, ustrip(u"psi", mat.fc′))
    n_total = length(group_ids)
    @info "Sized $n_feasible/$n_total RC beam groups via NLP" fc_psi=fc_psi

    return struc
end

# --- PixelFrame beams (discrete MIP) ---
function _size_beams_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.PixelFrameBeamOptions,
    ::Val{:discrete};
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
)
    skel = struc.skeleton
    edge_ids_in_group = Set(get(skel.groups_edges, :beams, Int[]))

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Extract demands from analysis (MemberDemand in SI: N, N·m, m)
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=:beams, resolution=resolution)

    isempty(group_ids) && return struc

    member_array = struc.beams

    # Build demand vectors with Unitful SI units
    Mu = [d.Mux * u"N*m"      for d in demands]
    Vu = [d.Vu_strong * u"N"   for d in demands]

    # Build geometries (L_totals are Float64 in meters)
    geoms = [StructuralSizer.ConcreteMemberGeometry(L) for L in L_totals]

    # Call PixelFrame beam sizing (validates pixel divisibility, runs MIP)
    result = StructuralSizer.size_beams(Mu, Vu, geoms, opts)

    # Build per-pixel material pool from catalog
    cat = if !isnothing(opts.custom_catalog)
        opts.custom_catalog
    else
        StructuralSizer.generate_pixelframe_catalog(;
            StructuralSizer._pf_catalog_kwargs(opts)...)
    end
    material_pool = unique(s.material for s in cat)

    # Build checker for per-pixel assignment
    checker = StructuralSizer.PixelFrameChecker(;
        StructuralSizer._pf_checker_kwargs(opts)...)

    # Strip pixel length to mm at the boundary
    px_mm = StructuralSizer._pf_pixel_mm(opts)

    # Apply results to member groups + ASAP elements + individual members
    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]
        n_px = result.n_pixels[g_idx]

        mg = struc.member_groups[gid]
        mg.section = chosen

        # Build ASAP section for FEA stiffness update
        asap_sec = StructuralSizer.to_asap_section(chosen)

        # Build uniform pixel demands (same demand for all pixels in this group)
        # The MIP already selected the governing section; per-pixel relaxation
        # assigns the lowest-carbon material at each pixel position.
        pixel_demands = [demands[g_idx] for _ in 1:n_px]

        # Build PixelFrameDesign with per-pixel material assignment
        design = StructuralSizer.build_pixel_design(
            chosen,
            L_totals[g_idx] * u"m",
            px_mm,
            pixel_demands,
            material_pool,
            checker,
        )

        for m_idx in mg.member_indices
            m = member_array[m_idx]

            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_pixel_design!(m, design)

            # Compute volumes from per-pixel material assignment
            pv = StructuralSizer.pixel_volumes(design)
            vols = MaterialVolumes()
            for (mat, vol) in pv
                vols[mat] = vol
            end
            set_volumes!(m, vols)

            # Update ASAP elements
            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
                struc.asap_model.elements[edge_idx].section = asap_sec
            end
        end
    end

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    n_total = length(group_ids)
    λs = join(string.(opts.λ_values), ",")
    @info "Sized $n_total PixelFrame beam groups via MIP" layups=λs pixel_mm=StructuralSizer._pf_pixel_mm(opts)

    return struc
end

# =============================================================================
# Member Sizing Orchestrator
# =============================================================================

"""
    size_members!(struc; beam_opts=nothing, column_opts=nothing, ...)

Top-level orchestrator that sizes beams, columns, and struts.

Dispatches automatically to `size_beams!` and `size_columns!` based on
the options types.  Options fall back to `struc.design_parameters` if not
provided explicitly.

# Example
```julia
size_members!(struc;
    beam_opts   = SteelBeamOptions(deflection_limit = 1/360),
    column_opts = ConcreteColumnOptions(material = NWC_5000),
)
```
"""
function size_members!(
    struc::BuildingStructure;
    beam_opts::Union{StructuralSizer.BeamOptions, Nothing} = nothing,
    column_opts::Union{StructuralSizer.ColumnOptions, Nothing} = nothing,
    beam_method::Symbol = :discrete,
    column_method::Symbol = :discrete,
    resolution::Int = 200,
    reanalyze::Bool = false,   # defer re-analysis to end
    gravity_factor::Quantity = GRAVITY,
)
    # Size beams
    size_beams!(struc, beam_opts;
        method = beam_method,
        resolution, reanalyze = false, gravity_factor)

    # Size columns
    size_columns!(struc, column_opts;
        resolution, reanalyze = false, gravity_factor)

    # Single re-analysis after both member types are sized
    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    return struc
end

# =============================================================================
# Multi-Material Column Sizing
# =============================================================================

"""
    size_columns!(struc::BuildingStructure)
    size_columns!(struc::BuildingStructure, opts::SteelColumnOptions)
    size_columns!(struc::BuildingStructure, opts::ConcreteColumnOptions)

Size columns using discrete MIP optimization.

If no options are provided, uses `struc.design_parameters.columns` if set,
otherwise defaults to `SteelColumnOptions()`.

# Example
```julia
# Use design parameters (recommended)
struc.design_parameters = DesignParameters(
    columns = ConcreteColumnOptions(material = NWC_5000),
)
size_columns!(struc)

# Or pass options directly
size_columns!(struc, SteelColumnOptions(section_type = :hss))
size_columns!(struc, ConcreteColumnOptions(max_depth = 0.6))
```
"""
function size_columns!(
    struc::BuildingStructure,
    opts::Union{StructuralSizer.ColumnOptions, Nothing} = nothing;
    resolution::Int = 200,
    reanalyze::Bool = true,
    gravity_factor::Quantity = GRAVITY,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
)
    dp = (hasproperty(struc, :design_parameters) && !isnothing(struc.design_parameters)) ?
         struc.design_parameters : nothing

    effective_opts = if !isnothing(opts)
        opts
    elseif !isnothing(dp) && !isnothing(dp.columns)
        dp.columns
    else
        obj = !isnothing(dp) ? resolve_objective(dp.optimize_for) : StructuralSizer.MinWeight()
        StructuralSizer.SteelColumnOptions(objective=obj)
    end

    StructuralSizer.emit!(tc, :sizing, "size_columns!", "", :enter;
                          opts_type=string(typeof(effective_opts)))

    if !isnothing(dp) && dp.collinear_grouping
        group_collinear_members!(struc; member_type=:columns)
    end
    
    result = _size_columns_impl!(struc, effective_opts; resolution, reanalyze, gravity_factor)
    StructuralSizer.emit!(tc, :sizing, "size_columns!", "", :exit)
    return result
end

# Steel implementation
function _size_columns_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.SteelColumnOptions;
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
)
    skel = struc.skeleton
    member_edge_group = :columns
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[]))
    
    # Add gravity loads
    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)
    
    # Get group demands
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution)
    
    # Build geometries
    geometries = [StructuralSizer.SteelMemberGeometry(L; Lb=Lb, Cb=Cb, Kx=Kx, Ky=Ky)
                  for (L, Lb, Cb, Kx, Ky) in zip(L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)]
    
    # Extract demands (N, N*m for steel)
    Pu = [d.Pu_c for d in demands]
    Mux = [d.Mux for d in demands]
    Muy = [d.Muy for d in demands]
    
    # Run optimization
    result = StructuralSizer.size_columns(Pu, Mux, geometries, opts; Muy=Muy)
    
    # Apply results
    _apply_column_results!(struc, result, group_ids, opts.material, :steel, edge_ids_in_group)
    
    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end
    
    @info "Sized $(length(group_ids)) column groups" material="steel" section_type=opts.section_type
    return struc
end

# Concrete implementation
function _size_columns_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.ConcreteColumnOptions;
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
)
    skel = struc.skeleton
    member_edge_group = :columns
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[]))

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution)

    # Concrete columns now carry per-axis effective length factors so the ACI
    # 318 slenderness check evaluates the strong (kx, h, b·h³/12) and weak
    # (ky, b, h·b³/12) axes independently. Previously both axes collapsed
    # onto Ky, which silently lost the strong-axis bracing information.
    geometries = [StructuralSizer.ConcreteMemberGeometry(L; Lu=Lb, kx=Kx, ky=Ky)
                  for (L, Lb, Kx, Ky) in zip(L_totals, Lb_govs, Kx_govs, Ky_govs)]

    # Build RC demands directly from the analysis output. `member_group_demands`
    # already populated `M1x/M2x/M1y/M2y` from FEA at the column ends in
    # ACI 318-19 sign convention. We just need to re-unit SI → ACI (kip,
    # kip·ft) before constructing `RCColumnDemand`s; the demand-driven
    # `size_columns` overload preserves the signed end moments end-to-end so
    # the slenderness path can compute `Cm = 0.6 − 0.4·(M1/M2)` instead of
    # the conservative `M1 = 0` stand-in.
    rc_demands = StructuralSizer.RCColumnDemand[]
    for (i, d) in enumerate(demands)
        Pu_kip   = ustrip(uconvert(Asap.kip,         d.Pu_c * u"N"))
        Mux_kipf = ustrip(uconvert(Asap.kip*u"ft",   d.Mux  * u"N*m"))
        Muy_kipf = ustrip(uconvert(Asap.kip*u"ft",   d.Muy  * u"N*m"))
        M1x_kipf = ustrip(uconvert(Asap.kip*u"ft",   d.M1x  * u"N*m"))
        M2x_kipf = ustrip(uconvert(Asap.kip*u"ft",   d.M2x  * u"N*m"))
        M1y_kipf = ustrip(uconvert(Asap.kip*u"ft",   d.M1y  * u"N*m"))
        M2y_kipf = ustrip(uconvert(Asap.kip*u"ft",   d.M2y  * u"N*m"))

        push!(rc_demands, StructuralSizer.RCColumnDemand(i;
            Pu  = Pu_kip,
            Mux = Mux_kipf, Muy = Muy_kipf,
            M1x = M1x_kipf, M2x = M2x_kipf,
            M1y = M1y_kipf, M2y = M2y_kipf,
            βdns = opts.βdns,
            transverse_load = d.transverse_load,
        ))
    end

    result = StructuralSizer.size_columns(rc_demands, geometries, opts)

    _apply_column_results!(struc, result, group_ids, opts.material, :concrete, edge_ids_in_group)

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    @info "Sized $(length(group_ids)) column groups" material=StructuralSizer.material_name(opts.material)
    return struc
end

# PixelFrame column implementation
function _size_columns_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.PixelFrameColumnOptions;
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
)
    skel = struc.skeleton
    member_edge_group = :columns
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[]))

    # Add gravity loads
    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Get group demands
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution)

    isempty(group_ids) && return struc

    member_array = struc.columns

    # Build demand vectors with Unitful SI units
    Pu  = [d.Pu_c * u"N"    for d in demands]
    Mux = [d.Mux * u"N*m"   for d in demands]
    Muy = [d.Muy * u"N*m"   for d in demands]

    # PixelFrame columns are graded by pixel material, but slenderness still
    # uses ACI 318 mechanics. Carry per-axis kx/ky so weak-axis Muy magnification
    # uses (ky, b, h·b³/12) instead of the strong-axis dimensions.
    geometries = [StructuralSizer.ConcreteMemberGeometry(L; Lu=Lb, kx=Kx, ky=Ky)
                  for (L, Lb, Kx, Ky) in zip(L_totals, Lb_govs, Kx_govs, Ky_govs)]

    # Call PixelFrame column sizing (validates pixel divisibility, runs MIP)
    result = StructuralSizer.size_columns(Pu, Mux, geometries, opts; Muy=Muy)

    # Build per-pixel material pool from catalog
    cat = if !isnothing(opts.custom_catalog)
        opts.custom_catalog
    else
        StructuralSizer.generate_pixelframe_catalog(;
            StructuralSizer._pf_catalog_kwargs(opts)...)
    end
    material_pool = unique(s.material for s in cat)

    # Build checker for per-pixel assignment
    checker = StructuralSizer.PixelFrameChecker(;
        StructuralSizer._pf_checker_kwargs(opts)...)

    # Strip pixel length to mm at the boundary
    px_mm = StructuralSizer._pf_pixel_mm(opts)

    # Apply results to member groups + ASAP elements + individual members
    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]
        n_px = result.n_pixels[g_idx]

        mg = struc.member_groups[gid]
        mg.section = chosen

        # Build ASAP section for FEA stiffness update
        asap_sec = StructuralSizer.to_asap_section(chosen)

        # Build uniform pixel demands (same demand for all pixels in this group)
        pixel_demands = [demands[g_idx] for _ in 1:n_px]

        # Build PixelFrameDesign with per-pixel material assignment
        design = StructuralSizer.build_pixel_design(
            chosen,
            L_totals[g_idx] * u"m",
            px_mm,
            pixel_demands,
            material_pool,
            checker,
        )

        for m_idx in mg.member_indices
            m = member_array[m_idx]

            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_pixel_design!(m, design)

            # Compute volumes from per-pixel material assignment
            pv = StructuralSizer.pixel_volumes(design)
            vols = MaterialVolumes()
            for (mat, vol) in pv
                vols[mat] = vol
            end
            set_volumes!(m, vols)

            # Update ASAP elements
            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
                struc.asap_model.elements[edge_idx].section = asap_sec
            end
        end
    end

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    n_total = length(group_ids)
    λs = join(string.(opts.λ_values), ",")
    @info "Sized $n_total PixelFrame column groups via MIP" layups=λs pixel_mm=StructuralSizer._pf_pixel_mm(opts)

    return struc
end

"""Add self-weight `GravityLoad`s to ASAP elements in the given edge group."""
function _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)
    existing_gravity_ids = Set{UInt}()
    for load in struc.asap_model.loads
        if isa(load, Asap.GravityLoad)
            push!(existing_gravity_ids, objectid(load.element))
        end
    end
    
    for edge_idx in edge_ids_in_group
        el = struc.asap_model.elements[edge_idx]
        objectid(el) in existing_gravity_ids && continue
        push!(struc.asap_model.loads, Asap.GravityLoad(el, gravity_factor))
    end
end

# Helper: apply optimization results
"""
    _apply_column_results!(struc, result, group_ids, material, material_type, edge_ids_in_group; I_factor)

Apply sized sections to column member groups, members, and ASAP elements.

When the result comes from multi-material optimization (`hasproperty(result, :materials_chosen)`),
each group uses its own material from `result.materials_chosen[g_idx]`. Otherwise, the single
`material` argument is used for all groups.
"""
function _apply_column_results!(struc, result, group_ids, material, material_type, edge_ids_in_group;
                                 I_factor::Real = 0.70)
    member_array = struc.columns
    has_multi_mat = hasproperty(result, :materials_chosen)
    
    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]
        group_mat = has_multi_mat ? result.materials_chosen[g_idx] : material
        
        mg = struc.member_groups[gid]
        mg.section = chosen
        
        # Build ASAP section (I_factor only applies to concrete per ACI 318-11 §10.10.4.1)
        asap_sec = if material_type === :concrete
            StructuralSizer.to_asap_section(chosen, group_mat; I_factor=I_factor)
        else
            StructuralSizer.to_asap_section(chosen, group_mat)
        end
        
        for m_idx in mg.member_indices
            m = member_array[m_idx]
            
            # Compute total length
            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            
            set_section!(m, chosen)
            set_volumes!(m, MaterialVolumes(group_mat => StructuralSizer.section_area(chosen) * L_total))
            
            # Update ASAP elements
            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
                struc.asap_model.elements[edge_idx].section = asap_sec
            end
        end
    end
end

# =============================================================================
# Initial Column Size Estimation
# =============================================================================

"""
    estimate_column_sizes!(struc; fc=4000u"psi", qu_default=200psf, method=:tributary,
                           input_is_centerline=false)

Estimate initial column sizes and store in Column.c1, Column.c2.

This provides preliminary column dimensions needed for slab clear span calculation
(ln = l - c) before full column design. The estimate is intentionally conservative.

After sizing, calls `update_structural_offsets!` to compute the inward offset
from architectural vertices to structural centerlines for edge/corner columns.

# Arguments
- `struc`: BuildingStructure with columns and tributary areas computed
- `fc`: Concrete compressive strength (default 4000 psi)
- `qu_default`: Default factored floor load if not available from cells (default 200 psf)
- `method`: :tributary (from Voronoi area) or :span (from span rule of thumb)
- `input_is_centerline`: forwarded to `update_structural_offsets!`; when `true`, all offsets are zero

# Requires
- Columns initialized with `initialize_members!()`
- Tributary areas computed with `compute_column_tributaries!()`

# Effects
- Sets `col.c1` and `col.c2` for each column
- Uses square columns (c1 = c2) for interior
- May use rectangular (c2 = 1.5 × c1) for edge columns

# Example
```julia
initialize!(struc; floor_type=:flat_plate, ...)
compute_column_tributaries!(struc)  # Usually called by initialize!
estimate_column_sizes!(struc; fc=5000u"psi")

# Now columns have c1, c2 set
for col in struc.columns
    println("Column at story \$(col.story): \$(col.c1) × \$(col.c2)")
end
```
"""
function estimate_column_sizes!(struc::BuildingStructure;
                                 fc::Unitful.Pressure = 4000u"psi",
                                 qu_default::Unitful.Pressure = 200psf,
                                 method::Symbol = :tributary,
                                 input_is_centerline::Bool = false)
    skel = struc.skeleton
    n_total_stories = length(skel.stories_z) - 1  # stories_z includes ground (0)
    
    if n_total_stories < 1
        @warn "No stories found in skeleton, cannot estimate column sizes"
        return struc
    end
    
    estimated_count = 0
    
    # Get average span for punching-based column sizing (flat plate design)
    avg_span = _estimate_avg_span(skel)
    
    for col in struc.columns
        # Number of stories above this column
        n_above = n_total_stories - col.story
        n_above = max(n_above, 1)  # At least 1 (supports at least 1 floor)
        
        if method == :tributary
            # Get tributary area (already Unitful from cache)
            At = column_tributary_area(struc, col)
            
            if isnothing(At) || ustrip(u"m^2", At) <= 0
                # Fall back to span-based estimate
                c = StructuralSizer.estimate_column_size_from_span(avg_span)
                col.c1 = c
                col.c2 = c
            else
                # Get average load from adjacent cells
                qu = _get_column_load_intensity(struc, col, qu_default)
                
                # Estimate column size considering both axial load AND punching shear
                # Pass span for punching-based minimum (c ≥ span/15 per StructurePoint)
                c = StructuralSizer.estimate_column_size(At, qu, n_above, fc; span=avg_span)
                
                # Rectangular for edge/corner columns (optional)
                if col.position == :interior
                    col.c1 = c
                    col.c2 = c
                else
                    # Edge/corner: use rectangular (c2 = c, c1 = c/1.2)
                    # This gives better punching shear capacity at edges
                    col.c1 = c
                    col.c2 = c
                end
            end
        else  # method == :span
            c = StructuralSizer.estimate_column_size_from_span(avg_span)
            col.c1 = c
            col.c2 = c
        end
        
        estimated_count += 1
    end
    
    @info "Estimated initial column sizes" method=method columns=estimated_count fc=fc

    # Compute structural offsets now that column dimensions are available.
    update_structural_offsets!(struc; input_is_centerline=input_is_centerline)

    return struc
end

"""Get average span from skeleton for span-based column estimate."""
function _estimate_avg_span(skel::BuildingSkeleton)
    isempty(skel.edges) && return 20u"ft"
    
    vc = skel.geometry.vertex_coords
    total_len = 0.0u"m"
    n = 0
    
    for (e_idx, (v1, v2)) in enumerate(skel.edge_indices)
        abs(vc[v1, 3] - vc[v2, 3]) < 0.1 || continue  # horizontal only
        total_len += edge_length(skel, e_idx)
        n += 1
    end
    
    return n > 0 ? total_len / n : 20u"ft"
end

"""
    _get_column_load_intensity(struc, col, qu_default; combo=default_combo) -> PressureQuantity

Get area-weighted factored load intensity for a column from adjacent cells.

Uses `total_factored_pressure(cell, combo)` which includes SDL, live load,
AND slab self-weight, factored per the given load combination.

Note: Cell self-weight is populated during slab sizing via `initialize_slabs!`.
If called before slab sizing, self-weight will be zero.
"""
function _get_column_load_intensity(struc::BuildingStructure, col, qu_default;
                                    combo::LoadCombination = default_combo)
    by_cell = column_tributary_by_cell(struc, col)
    
    if isnothing(by_cell) || isempty(by_cell)
        return qu_default
    end
    
    total_load = 0.0u"kN"
    total_area = 0.0u"m^2"
    
    for (cell_idx, area) in by_cell
        if cell_idx <= length(struc.cells)
            cell = struc.cells[cell_idx]
            qu = total_factored_pressure(cell, combo)
            total_load += qu * area
            total_area += area
        end
    end
    
    return total_area > 0u"m^2" ? total_load / total_area : qu_default
end
