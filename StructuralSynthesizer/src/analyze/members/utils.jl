# Segment and Member initialization from skeleton edges

"""Compute segment length from skeleton edge."""
function get_segment_length(skel::BuildingSkeleton{T}, edge_idx::Int) where T
    seg = skel.edges[edge_idx]
    L = Meshes.measure(seg)
    # If the structure uses plain floats, ensure we return meters.
    # If it uses Quantities, return as-is (assuming consistent unit system).
    if T <: Unitful.Quantity
        return L
    else
        return ustrip(uconvert(u"m", L))
    end
end

"""
Initialize segments from all skeleton edges.

Default: Lb = L (unbraced, conservative). Call `update_bracing!` after to set Lb = 0
for slab-supported beams.
"""
function initialize_segments!(struc::BuildingStructure{T}; default_Cb=1.0) where T
    skel = struc.skeleton
    empty!(struc.segments)
    
    for edge_idx in eachindex(skel.edges)
        L = get_segment_length(skel, edge_idx)
        # Default: full span unbraced (conservative)
        segment = Segment(edge_idx, L; Lb=L, Cb=default_Cb)
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
    
    # Get edge groups from skeleton
    beam_edges = Set(get(skel.groups_edges, :beams, Int[]))
    column_edges = Set(get(skel.groups_edges, :columns, Int[]))
    brace_edges = Set(get(skel.groups_edges, :braces, Int[]))
    
    for (seg_idx, seg) in enumerate(struc.segments)
        edge_idx = seg.edge_idx
        
        if edge_idx in column_edges
            # Create Column
            # Find which vertex this column connects to (bottom vertex for column position)
            v1, v2 = skel.edge_indices[edge_idx]
            z1 = Meshes.coords(skel.vertices[v1]).z
            z2 = Meshes.coords(skel.vertices[v2]).z
            # Bottom vertex is the one with lower z
            vertex_idx = z1 < z2 ? v1 : v2
            
            # Determine story from edge level
            story = get_edge_story(skel, edge_idx)
            
            # Classify position based on boundary edges (robust method)
            position, boundary_edge_dirs = classify_column_position(skel, vertex_idx)
            
            col = Column(seg_idx, seg.L; 
                        Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb,
                        vertex_idx=vertex_idx, story=story, position=position,
                        boundary_edge_dirs=boundary_edge_dirs)
            push!(struc.columns, col)
            
        elseif edge_idx in brace_edges
            # Create Strut
            strut = Strut(seg_idx, seg.L;
                         Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb,
                         brace_type=:both)
            push!(struc.struts, strut)
            
        else
            # Default to Beam (includes edges in :beams group or ungrouped)
            role = classify_beam_role(skel, edge_idx)
            beam = Beam(seg_idx, seg.L;
                       Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb,
                       role=role)
            push!(struc.beams, beam)
        end
    end
    
    n_total = length(struc.beams) + length(struc.columns) + length(struc.struts)
    @debug "Initialized members from $(length(struc.segments)) segments" beams=length(struc.beams) columns=length(struc.columns) struts=length(struc.struts)
    
    # Compute Voronoi tributary areas for columns
    compute_column_tributaries!(struc)
    
    return struc
end

"""
    compute_column_tributaries!(struc::BuildingStructure)

Compute and store Voronoi vertex tributary areas in the TributaryCache.

For each cell:
1. Get the cell's corner vertices (column positions)
2. Compute Voronoi clipped to the cell boundary
3. Store in `struc.tributaries.vertex[story][vertex_idx]`

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
    
    # Type aliases from Asap: AreaQuantity = typeof(1.0u"m^2"), LengthQuantity = typeof(1.0u"m")
    
    # Build (x,y) → Column lookup (rounded to avoid FP precision issues)
    col_by_xy = Dict{Tuple{Float64, Float64}, Vector{Column{T}}}()
    for col in struc.columns
        c = Meshes.coords(skel.vertices[col.vertex_idx])
        xy = (round(Float64(ustrip(u"m", c.x)), digits=6), 
              round(Float64(ustrip(u"m", c.y)), digits=6))
        push!(get!(col_by_xy, xy, Column{T}[]), col)
    end
    
    # Temporary storage: (story, vertex_idx) → accumulated data
    # Using Unitful quantities for type safety
    col_by_cell = Dict{Tuple{Int, Int}, Dict{Int, AreaQuantity}}()
    col_polygons = Dict{Tuple{Int, Int}, Dict{Int, Vector{NTuple{2, LengthQuantity}}}}()
    col_totals = Dict{Tuple{Int, Int}, AreaQuantity}()
    
    # Process each cell
    for (cell_idx, cell) in enumerate(struc.cells)
        v_indices = skel.face_vertex_indices[cell.face_idx]
        length(v_indices) < 3 && continue
        
        # Get cell elevation for matching columns
        first_vert = skel.vertices[v_indices[1]]
        cell_z = Float64(ustrip(u"m", Meshes.coords(first_vert).z))
        
        # Extract vertex positions as tuples (in meters, raw Float64 for Voronoi algorithm)
        col_positions = NTuple{2, Float64}[]
        cell_xys = Tuple{Float64, Float64}[]
        for vi in v_indices
            c = Meshes.coords(skel.vertices[vi])
            xy = (Float64(ustrip(u"m", c.x)), Float64(ustrip(u"m", c.y)))
            push!(col_positions, xy)
            push!(cell_xys, (round(xy[1], digits=6), round(xy[2], digits=6)))
        end
        
        # Compute Voronoi within cell boundary (boundary = cell vertices)
        tribs = StructuralSizer.compute_voronoi_tributaries(col_positions; floor_boundary=col_positions)
        
        # Store results (matching by x,y position)
        for (i, trib) in enumerate(tribs)
            xy = cell_xys[i]
            cols = get(col_by_xy, xy, nothing)
            isnothing(cols) && continue
            
            # Find the column whose TOP is at this floor level
            matched_col = nothing
            for col in cols
                v_c = Meshes.coords(skel.vertices[col.vertex_idx])
                col_bottom_z = Float64(ustrip(u"m", v_c.z))
                col_top_z = col_bottom_z + Float64(ustrip(u"m", col.base.L))
                if abs(col_top_z - cell_z) < 0.1  # Within 10cm tolerance
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
            
            # Convert raw Float64 from Voronoi to Unitful quantities
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
    n_populated = 0
    for col in struc.columns
        key = (col.story, col.vertex_idx)
        if haskey(col_by_cell, key)
            col.tributary_cell_indices = Set(keys(col_by_cell[key]))
            # Store areas as raw Float64 in m² for Sizer to use without Unitful lookups
            col.tributary_cell_areas = Dict{Int, Float64}(
                cell_idx => ustrip(u"m^2", area) 
                for (cell_idx, area) in col_by_cell[key]
            )
            n_populated += 1
        end
    end
    
    
    n_cached = length(col_totals)
    @info "Computed Voronoi tributary areas" columns_with_tribs=n_cached total_columns=length(struc.columns) columns_populated=n_populated
    
    return struc
end

"""
    get_edge_story(skel, edge_idx) -> Int

Determine which story an edge belongs to based on its z-coordinate.
"""
function get_edge_story(skel::BuildingSkeleton, edge_idx::Int)
    v1, v2 = skel.edge_indices[edge_idx]
    z1 = Meshes.coords(skel.vertices[v1]).z
    z2 = Meshes.coords(skel.vertices[v2]).z
    z_mid = (z1 + z2) / 2
    
    # Find which story interval contains z_mid
    for (level_idx, story) in skel.stories
        if abs(story.elevation - z_mid) < 0.1u"m" || 
           (level_idx > 0 && z_mid > skel.stories_z[level_idx] && z_mid <= story.elevation)
            return level_idx
        end
    end
    return 0
end

"""
    classify_column_position(skel, vertex_idx) -> (position::Symbol, boundary_edge_dirs::Vector{NTuple{2,Float64}})

Classify column position based on whether it touches boundary edges (edges in only one face).

A boundary edge is one that belongs to exactly one face (building perimeter).
This is more robust than counting neighbors, and provides directional information
needed for DDM/EFM analysis.

# Returns
- `position`: :interior (no boundary edges), :edge (1 boundary edge), :corner (2+ boundary edges)
- `boundary_edge_dirs`: Unit vectors along each boundary edge (for DDM exterior support detection)
"""
function classify_column_position(skel::BuildingSkeleton, vertex_idx::Int)
    v_coords = Meshes.coords(skel.vertices[vertex_idx])
    v_z = v_coords.z
    v_x = ustrip(u"m", v_coords.x)
    v_y = ustrip(u"m", v_coords.y)
    
    # Get all horizontal neighbors
    neighbors = Graphs.neighbors(skel.graph, vertex_idx)
    horizontal_neighbors = filter(neighbors) do n_idx
        n_z = Meshes.coords(skel.vertices[n_idx]).z
        abs(n_z - v_z) < 0.01u"m"
    end
    
    # Check each horizontal edge for boundary status
    boundary_edge_dirs = NTuple{2, Float64}[]
    
    for n_idx in horizontal_neighbors
        # Find the edge index for this vertex pair
        edge_idx = find_edge(skel, vertex_idx, n_idx)
        isnothing(edge_idx) && continue
        
        # Is this edge a boundary edge? (only belongs to one face)
        faces_with_edge = count(skel.face_edge_indices) do face_edges
            edge_idx in face_edges
        end
        
        if faces_with_edge == 1
            # This is a boundary edge — record its direction
            n_coords = Meshes.coords(skel.vertices[n_idx])
            dx = ustrip(u"m", n_coords.x) - v_x
            dy = ustrip(u"m", n_coords.y) - v_y
            len = hypot(dx, dy)
            if len > 1e-9
                push!(boundary_edge_dirs, (dx/len, dy/len))
            end
        end
    end
    
    # Classify based on boundary edge count
    n_boundary = length(boundary_edge_dirs)
    
    position = if n_boundary == 0
        :interior
    elseif n_boundary >= 2
        :corner
    else
        :edge
    end
    
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
    member_group_demands(struc; member_edge_group=:beams, resolution=200)

Compute governing demands and geometry for each `MemberGroup` by enveloping ASAP internal
forces across all segments of all members in the group.

Conventions:
- gravity bending (strong axis) demand uses `My`
- weak-axis bending demand uses `Mz`
- shear demand uses `Vy`/`Vz` (mapped to weak/strong)
- deflection uses max local Z displacement from `ElementDisplacements.ulocal`

Returns `(group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)`.
"""
function member_group_demands(struc::BuildingStructure; member_edge_group::Symbol=:beams, resolution::Int=200)
    isempty(struc.asap_model.elements) && throw(ArgumentError("ASAP model is empty. Call `to_asap!(struc)` before sizing."))

    skel = struc.skeleton
    beam_edge_ids = Set(get(skel.groups_edges, member_edge_group, Int[]))

    # Determine member type from edge group name
    member_type = member_edge_group == :columns ? :columns : 
                  member_edge_group == :struts ? :struts : :beams
    
    # Get the appropriate member array
    member_array = member_type == :columns ? struc.columns :
                   member_type == :struts ? struc.struts : struc.beams

    # Build member groups if needed
    isempty(struc.member_groups) && build_member_groups!(struc; member_type=member_type)

    # Only include groups that actually contain at least one segment in `beam_edge_ids`.
    all_group_ids = sort!(collect(keys(struc.member_groups)))  # deterministic ordering

    group_ids = UInt64[]
    # `StructuralSizer.MemberDemand(idx; ...)` intentionally returns `MemberDemand{Any}`
    # to support mixed numeric types (and Unitful quantities in some callers).
    demands = StructuralSizer.MemberDemand{Any}[]
    
    # We enforce base SI units (meters) for geometry passed to the optimizer,
    # consistent with `get_segment_length` returning meters for Float64 structures.
    L_totals = Float64[]
    Lb_govs  = Float64[]
    Cb_govs  = Float64[]
    Kx_govs  = Float64[]
    Ky_govs  = Float64[]

    for gid in all_group_ids
        mg = struc.member_groups[gid]

        # Envelope over segments in the requested edge group
        Pu_comp = 0.0
        Pu_tens = 0.0
        Mux = 0.0
        Muy = 0.0
        Vu_strong = 0.0
        Vu_weak = 0.0

        # Geometry accumulation
        L_total = 0.0
        Lb_gov = 0.0
        Cb_gov = Inf
        Kx_gov = 0.0
        Ky_gov = 0.0
        
        has_any_segment = false

        # Track max deflection and reference I for deflection scaling
        δ_max = 0.0
        I_ref = 0.0

        for m_idx in mg.member_indices
            m = member_array[m_idx]  # Index into appropriate member array
            
            # Group geometry governance (take worst case K across members in group)
            Kx_gov = max(Kx_gov, m.base.Kx)
            Ky_gov = max(Ky_gov, m.base.Ky)

            for seg_idx in segment_indices(m)
                seg = struc.segments[seg_idx]
                edge_idx = seg.edge_idx
                edge_idx in beam_edge_ids || continue

                has_any_segment = true
                
                # Assume seg.L and seg.Lb are already compatible (meters or consistent units).
                len_val = seg.L isa Unitful.Quantity ? ustrip(uconvert(u"m", seg.L)) : seg.L
                lb_val  = seg.Lb isa Unitful.Quantity ? ustrip(uconvert(u"m", seg.Lb)) : seg.Lb

                L_total += len_val
                Lb_gov = max(Lb_gov, lb_val)
                Cb_gov = min(Cb_gov, seg.Cb)

                el = struc.asap_model.elements[edge_idx]
                f = Asap.InternalForces(el, struc.asap_model; resolution=resolution)

                # Convention check:
                # ASAP P: Tension is positive. Compression is negative.
                P_vals = f.P
                min_P = minimum(P_vals)
                max_P = maximum(P_vals)
                
                if min_P < 0
                    Pu_comp = max(Pu_comp, abs(min_P))
                end
                if max_P > 0
                    Pu_tens = max(Pu_tens, max_P)
                end

                # ASAP My: Moment about local y-axis. (Strong axis bending for W-shapes)
                # ASAP Mz: Moment about local z-axis. (Weak axis bending)
                # Strong Axis: My (moment), Vz (shear)
                Mux = max(Mux, maximum(abs.(f.My)))
                Vu_strong = max(Vu_strong, maximum(abs.(f.Vz)))

                # Weak Axis: Mz (moment), Vy (shear)
                Muy = max(Muy, maximum(abs.(f.Mz)))
                Vu_weak = max(Vu_weak, maximum(abs.(f.Vy)))

                # Local deflection for serviceability check
                # ulocal[3,:] is the local Z deflection (transverse to beam axis)
                edisp = Asap.ElementDisplacements(el, struc.asap_model; resolution=resolution)
                δ_local = maximum(abs.(edisp.ulocal[3, :]))  # Max local Z deflection
                δ_max = max(δ_max, δ_local)
                
                # Get reference moment of inertia from current section (for deflection scaling)
                # Deflection scales as 1/I, so: δ_new = δ_current * I_current / I_new
                I_current = ustrip(u"m^4", el.section.Ix)  # Strong axis I
                I_ref = max(I_ref, I_current)  # Use largest I as reference (conservative)
            end
        end

        has_any_segment || continue

        push!(group_ids, gid)
        g_idx = length(group_ids)  # group index in the filtered ordering
        
        d = StructuralSizer.MemberDemand(g_idx; 
            Pu_c=Pu_comp, Pu_t=Pu_tens, 
            Mux=Mux, Muy=Muy, 
            Vu_strong=Vu_strong, Vu_weak=Vu_weak,
            δ_max=δ_max, I_ref=I_ref)
            
        push!(demands, d)
        push!(L_totals, L_total)
        push!(Lb_govs, Lb_gov)
        push!(Cb_govs, Cb_gov)
        push!(Kx_govs, Kx_gov)
        push!(Ky_govs, Ky_gov)
    end

    return group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs
end

"""
    size_members_discrete!(
        struc::BuildingStructure;
        catalogue=StructuralSizer.all_W(),
        material=StructuralSizer.A992_Steel,
        member_edge_group::Symbol=:beams,
        max_depth=Inf*u"m",
        n_max_sections::Integer=0,
        optimizer::Symbol=:auto,
        resolution::Int=200,
        reanalyze::Bool=true,
        deflection_limit::Union{Nothing, Real}=nothing,
    )

Discrete, simultaneous catalog-based sizing for physical members using a MIP.
Respects `Member.group_id` by solving at the group level.

!!! warning "Steel-Specific Implementation"
    This function is currently hardcoded for steel members using `AISCChecker` and
    `StructuralSizer.to_asap_section`. To support other materials (concrete, timber), the
    design checker and ASAP section conversion need to be parameterized by material.
    See `StructuralSizer` for the generic checker interface.

# Arguments
- `deflection_limit::Union{Nothing, Real}=nothing`: Optional deflection limit as a ratio.
  E.g., `1/360` means max local deflection ≤ L/360 (typical floor beam limit).
  If `nothing`, no deflection check is performed (strength-only).

Side effects:
- populates/overwrites `struc.member_groups[gid].section` (shared for ASAP updates)
- populates each `member.section` and `member.volumes` for individual access
- updates ASAP element sections for all member segments in `member_edge_group`
"""
function size_members_discrete!(
    struc::BuildingStructure;
    catalogue=StructuralSizer.all_W(),
    material=StructuralSizer.A992_Steel,
    member_edge_group::Symbol=:beams,
    max_depth=Inf * u"m",
    n_max_sections::Integer=0,
    optimizer::Symbol=:auto,
    resolution::Int=200,
    reanalyze::Bool=true,
    gravity_factor::Quantity=9.81u"m/s^2",  # gravity acceleration
    deflection_limit::Union{Nothing, Real}=nothing,  # e.g., 1/360
    skel = struc.skeleton,
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[])))
    
    # Add gravity loads to all elements in the member group
    # GravityLoad reads from element.section at calculation time, so it will automatically
    # update when sections change during optimization
    existing_gravity_elements = Set()
    for load in struc.asap_model.loads
        if isa(load, Asap.GravityLoad)
            push!(existing_gravity_elements, load.element)
        end
    end
    
    for edge_idx in edge_ids_in_group
        el = struc.asap_model.elements[edge_idx]
        el in existing_gravity_elements && continue  # Skip if gravity load already exists
        push!(struc.asap_model.loads, Asap.GravityLoad(el, gravity_factor))
    end
    
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
    
    result = StructuralSizer.optimize_discrete(
        checker, demands, geometries, catalogue, material;
        n_max_sections=n_max_sections,
        optimizer=optimizer,
    )

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
    @info "Sized $(length(group_ids)) member groups using discrete MIP" optimizer=optimizer n_max_sections=n_max_sections deflection_limit=defl_str
    return struc
end

# =============================================================================
# Multi-Material Column Sizing
# =============================================================================

"""
    rc_section_to_asap(section, material)

Convert an RC section to an ASAP Section for structural analysis.
Delegates to `StructuralSizer.to_asap_section`.

!!! note "Deprecated"
    Use `StructuralSizer.to_asap_section(section, material)` directly.
"""
rc_section_to_asap(section, material) = StructuralSizer.to_asap_section(section, material)

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
    columns = ConcreteColumnOptions(grade = NWC_5000),
)
size_columns!(struc)

# Or pass options directly
size_columns!(struc, SteelColumnOptions(section_type = :hss))
size_columns!(struc, ConcreteColumnOptions(max_depth = 0.6))
```
"""
function size_columns!(
    struc::BuildingStructure,
    opts::Union{StructuralSizer.SteelColumnOptions, StructuralSizer.ConcreteColumnOptions, Nothing} = nothing;
    resolution::Int = 200,
    reanalyze::Bool = true,
    gravity_factor::Quantity = 9.81u"m/s^2",
)
    # Determine options: explicit > design_parameters > default
    effective_opts = if !isnothing(opts)
        opts
    elseif !isnothing(struc.design_parameters) && !isnothing(struc.design_parameters.columns)
        struc.design_parameters.columns
    else
        StructuralSizer.SteelColumnOptions()
    end
    
    _size_columns_impl!(struc, effective_opts; resolution, reanalyze, gravity_factor)
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
    
    # Add gravity loads
    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)
    
    # Get group demands
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution)
    
    # Build geometries (concrete uses Lu, k)
    geometries = [StructuralSizer.ConcreteMemberGeometry(L; Lu=Lb, k=Ky)
                  for (L, Lb, Ky) in zip(L_totals, Lb_govs, Ky_govs)]
    
    # Convert demands to Unitful quantities then strip for size_columns API
    Pu = [uconvert(Asap.kip, d.Pu_c * u"N") for d in demands]
    Mux = [uconvert(Asap.kip*u"ft", d.Mux * u"N*m") for d in demands]
    Muy = [uconvert(Asap.kip*u"ft", d.Muy * u"N*m") for d in demands]
    
    # Run optimization (size_columns expects stripped values in kip, kip*ft)
    result = StructuralSizer.size_columns(ustrip.(Pu), ustrip.(Mux), geometries, opts; Muy=ustrip.(Muy))
    
    # Apply results
    _apply_column_results!(struc, result, group_ids, opts.grade, :concrete, edge_ids_in_group)
    
    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end
    
    @info "Sized $(length(group_ids)) column groups" material="concrete" grade=StructuralSizer.material_name(opts.grade)
    return struc
end

# Helper: add gravity loads
function _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)
    existing_gravity_elements = Set()
    for load in struc.asap_model.loads
        if isa(load, Asap.GravityLoad)
            push!(existing_gravity_elements, load.element)
        end
    end
    
    for edge_idx in edge_ids_in_group
        el = struc.asap_model.elements[edge_idx]
        el in existing_gravity_elements && continue
        push!(struc.asap_model.loads, Asap.GravityLoad(el, gravity_factor))
    end
end

# Helper: apply optimization results
function _apply_column_results!(struc, result, group_ids, material, material_type, edge_ids_in_group)
    member_array = struc.columns
    
    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]
        
        mg = struc.member_groups[gid]
        mg.section = chosen
        
        # Build ASAP section
        asap_sec = StructuralSizer.to_asap_section(chosen, material)
        
        for m_idx in mg.member_indices
            m = member_array[m_idx]
            
            # Compute total length
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
end

# =============================================================================
# Initial Column Size Estimation
# =============================================================================

"""
    estimate_column_sizes!(struc; fc=4000u"psi", qu_default=200u"psf", method=:tributary)

Estimate initial column sizes and store in Column.c1, Column.c2.

This provides preliminary column dimensions needed for slab clear span calculation
(ln = l - c) before full column design. The estimate is intentionally conservative.

# Arguments
- `struc`: BuildingStructure with columns and tributary areas computed
- `fc`: Concrete compressive strength (default 4000 psi)
- `qu_default`: Default factored floor load if not available from cells (default 200 psf)
- `method`: :tributary (from Voronoi area) or :span (from span rule of thumb)

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
                                 qu_default::Unitful.Pressure = 200u"psf",
                                 method::Symbol = :tributary)
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
            avg_span = _estimate_avg_span(skel)
            c = StructuralSizer.estimate_column_size_from_span(avg_span)
            col.c1 = c
            col.c2 = c
        end
        
        estimated_count += 1
    end
    
    @info "Estimated initial column sizes" method=method columns=estimated_count fc=fc
    return struc
end

"""Get average span from skeleton for span-based column estimate."""
function _estimate_avg_span(skel::BuildingSkeleton)
    if isempty(skel.edges)
        return 20u"ft"  # Default assumption
    end
    
    # Sample horizontal edge lengths
    total_len = 0.0u"m"
    count = 0
    
    for edge in skel.edges
        len = Meshes.measure(edge)
        # Only count horizontal edges (beams, not columns)
        p1, p2 = edge.vertices
        z1 = Meshes.coords(p1).z
        z2 = Meshes.coords(p2).z
        if abs(z1 - z2) < 0.1u"m"  # Horizontal
            total_len += len
            count += 1
        end
    end
    
    if count > 0
        return total_len / count
    else
        return 20u"ft"  # Default
    end
end

"""
    _get_column_load_intensity(struc, col, qu_default) -> PressureQuantity

Get area-weighted factored load intensity for a column from adjacent cells.

Uses `total_factored_pressure(cell)` which includes SDL, live load, AND slab self-weight
(1.2×DL + 1.6×LL per ACI 318 load combinations).

Note: Cell self-weight is populated during slab sizing via `initialize_slabs!`.
If called before slab sizing, self-weight will be zero.
"""
function _get_column_load_intensity(struc::BuildingStructure, col, qu_default)
    # Get cells contributing to this column (areas are Unitful)
    by_cell = column_tributary_by_cell(struc, col)
    
    if isnothing(by_cell) || isempty(by_cell)
        return qu_default
    end
    
    # Area-weighted average of cell loads
    total_load = 0.0u"kN"
    total_area = 0.0u"m^2"
    
    for (cell_idx, area) in by_cell  # area is already Unitful (m²)
        if cell_idx <= length(struc.cells)
            cell = struc.cells[cell_idx]
            # Use total_factored_pressure which includes SDL + self_weight + LL
            # with proper load factors (1.2D + 1.6L)
            qu = total_factored_pressure(cell)
            
            total_load += qu * area
            total_area += area
        end
    end
    
    if total_area > 0u"m^2"
        return total_load / total_area
    else
        return qu_default
    end
end
