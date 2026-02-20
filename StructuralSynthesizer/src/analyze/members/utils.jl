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
    
    for (seg_idx, seg) in enumerate(struc.segments)
        edge_idx = seg.edge_idx
        
        if edge_idx in column_edges
            # Create Column
            v1, v2 = skel.edge_indices[edge_idx]
            z1 = vc[v1, 3]
            z2 = vc[v2, 3]
            # Top vertex is at the slab level (shares vertex index with face vertices)
            vertex_idx = z1 > z2 ? v1 : v2
            
            # Read story from geometry cache
            story = edge_story(skel, edge_idx)
            
            # Classify position using cached coords + edge-face counts
            position, boundary_edge_dirs = classify_column_position(skel, vertex_idx, vc, efc)
            
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

    Threads.@threads for g in 1:n_groups
        gid = all_group_ids[g]
        mg = struc.member_groups[gid]

        Pu_comp = 0.0; Pu_tens = 0.0
        Mux = 0.0; Muy = 0.0
        Vu_strong = 0.0; Vu_weak = 0.0
        L_total = 0.0; Lb_gov = 0.0; Cb_gov = Inf
        Kx_gov = 0.0; Ky_gov = 0.0
        has_any = false
        δ_max = 0.0; I_ref = 0.0

        for m_idx in mg.member_indices
            m = member_array[m_idx]
            Kx_gov = max(Kx_gov, m.base.Kx)
            Ky_gov = max(Ky_gov, m.base.Ky)

            for seg_idx in segment_indices(m)
                seg = struc.segments[seg_idx]
                edge_idx = seg.edge_idx
                edge_idx in beam_edge_ids || continue

                has_any = true
                len_val = to_meters(seg.L)
                lb_val  = to_meters(seg.Lb)
                L_total += len_val
                Lb_gov = max(Lb_gov, lb_val)
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
            end
        end

        par_has[g]  = has_any
        par_Pu_c[g] = Pu_comp; par_Pu_t[g] = Pu_tens
        par_Mux[g]  = Mux;     par_Muy[g]  = Muy
        par_Vus[g]  = Vu_strong; par_Vuw[g] = Vu_weak
        par_δ[g]    = δ_max;   par_Ir[g]   = I_ref
        par_L[g]    = L_total; par_Lb[g]   = Lb_gov
        par_Cb[g]   = Cb_gov;  par_Kx[g]   = Kx_gov; par_Ky[g] = Ky_gov
    end

    # Sequential filter & renumber indices
    group_ids = UInt64[]
    demands   = StructuralSizer.MemberDemand{Float64}[]
    L_totals  = Float64[]
    Lb_govs   = Float64[]
    Cb_govs   = Float64[]
    Kx_govs   = Float64[]
    Ky_govs   = Float64[]

    for g in 1:n_groups
        par_has[g] || continue
        push!(group_ids, all_group_ids[g])
        g_idx = length(group_ids)

        d = StructuralSizer.MemberDemand(g_idx;
            Pu_c=par_Pu_c[g], Pu_t=par_Pu_t[g],
            Mux=par_Mux[g], Muy=par_Muy[g],
            Vu_strong=par_Vus[g], Vu_weak=par_Vuw[g],
            δ_max=par_δ[g], I_ref=par_Ir[g])

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
    optimizer::Symbol=:auto,
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
    
    result = StructuralSizer.optimize_discrete(
        checker, demands, geometries, catalog, material;
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
    @info "Sized $(length(group_ids)) steel member groups via MIP" optimizer=optimizer n_max_sections=n_max_sections deflection_limit=defl_str
    return struc
end


# =============================================================================
# T-Beam Flange Parameters (ACI 318-19 §6.3.2.1)
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
| SteelMemberOptions   | :discrete  | `size_steel_members!`                    |
| ConcreteBeamOptions  | :discrete  | MIP via `size_beams` or `size_tbeams`    |
| ConcreteBeamOptions  | :nlp       | NLP via `size_rc_beams_nlp` / `_tbeams`  |

If no options are provided, falls back to `struc.design_parameters.beams`,
then to `SteelBeamOptions()`.

The concrete beam path extracts Mu, Vu, and Nu from the Asap analysis
results and passes them through to the ACI 318 beam checker. When Nu > 0
(axial compression from frame action), Vc is increased per ACI §22.5.6.1.

When `ConcreteBeamOptions.include_flange = true`, the dispatcher automatically:
- Reads slab thicknesses from `struc.slabs` (slabs must be sized first)
- Computes effective flange widths per ACI 318-19 §6.3.2.1 using beam
  tributary widths and edge/interior classification
- Routes to `size_tbeams` (discrete) or `size_rc_tbeams_nlp` (NLP)

# Example
```julia
# Steel beams with L/360 deflection check
size_beams!(struc, SteelBeamOptions(deflection_limit = 1/360))

# RC rectangular beams (discrete catalog MIP)
size_beams!(struc, ConcreteBeamOptions(grade = NWC_5000))

# RC T-beams — auto-detects flange from slab data
size_beams!(struc, ConcreteBeamOptions(grade = NWC_5000, include_flange = true))
```
"""
function size_beams!(
    struc::BuildingStructure,
    opts::Union{StructuralSizer.BeamOptions, Nothing} = nothing;
    method::Symbol = :discrete,
    resolution::Int = 200,
    reanalyze::Bool = true,
    gravity_factor::Quantity = GRAVITY,
)
    effective_opts = if !isnothing(opts)
        opts
    elseif !isnothing(struc.design_parameters) && !isnothing(struc.design_parameters.beams)
        struc.design_parameters.beams
    else
        StructuralSizer.SteelBeamOptions()
    end

    _size_beams_impl!(struc, effective_opts, Val(method);
                      resolution, reanalyze, gravity_factor)
end

# --- Steel beams (discrete) ---
function _size_beams_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.SteelMemberOptions,
    ::Val{:discrete};
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
)
    catalog = isnothing(opts.custom_catalog) ?
        StructuralSizer.steel_column_catalog(opts.section_type, opts.catalog) :
        opts.custom_catalog

    size_steel_members!(struc;
        catalog       = catalog,
        material        = opts.material,
        member_edge_group = :beams,
        max_depth       = opts.max_depth,
        n_max_sections  = opts.n_max_sections,
        optimizer       = opts.optimizer,
        resolution      = resolution,
        reanalyze       = reanalyze,
        gravity_factor  = gravity_factor,
        deflection_limit = opts.deflection_limit,
    )
end

# --- Shared helper: apply MIP/NLP beam results to the BuildingStructure ---
"""Apply sized sections (from MIP `result.sections`) to member groups, members, and ASAP elements."""
function _apply_beam_results!(
    struc::BuildingStructure,
    result,
    group_ids::Vector{UInt64},
    member_array,
    edge_ids_in_group::Set{Int},
    mat::StructuralSizer.AbstractMaterial,
)
    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]

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
                                 edge_ids_in_group, opts.grade)

            if reanalyze
                Asap.process!(struc.asap_model)
                Asap.solve!(struc.asap_model)
            end

            fc_psi = round(Int, ustrip(u"psi", opts.grade.fc′))
            bf_in  = round(ustrip(u"inch", bf_env); digits=1)
            hf_in  = round(ustrip(u"inch", hf_env); digits=1)
            @info "Sized $(length(group_ids)) RC T-beam groups via MIP" fc_psi bf_in hf_in

            return struc
        end
    end

    # ── Rectangular beam path (default) ──
    result = StructuralSizer.size_beams(Mu, Vu, geoms, opts; Nu=Nu)

    _apply_beam_results!(struc, result, group_ids, member_array,
                         edge_ids_in_group, opts.grade)

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    fc_psi = round(Int, ustrip(u"psi", opts.grade.fc′))
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
        grade      = opts.grade,
        rebar_grade = opts.rebar_grade,
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

        mat = opts.grade
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

    mat = opts.grade
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
    column_opts = ConcreteColumnOptions(grade = NWC_5000),
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
    opts::Union{StructuralSizer.ColumnOptions, Nothing} = nothing;
    resolution::Int = 200,
    reanalyze::Bool = true,
    gravity_factor::Quantity = GRAVITY,
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
function _apply_column_results!(struc, result, group_ids, material, material_type, edge_ids_in_group;
                                 I_factor::Real = 0.70)
    member_array = struc.columns
    
    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]
        
        mg = struc.member_groups[gid]
        mg.section = chosen
        
        # Build ASAP section (I_factor only applies to concrete per ACI 318-14 §6.6.3.1.1)
        asap_sec = if material_type === :concrete
            StructuralSizer.to_asap_section(chosen, material; I_factor=I_factor)
        else
            StructuralSizer.to_asap_section(chosen, material)
        end
        
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
