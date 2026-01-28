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
            
            # Classify position based on connectivity
            position = classify_column_position(skel, vertex_idx)
            
            col = Column(seg_idx, seg.L; 
                        Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb,
                        vertex_idx=vertex_idx, story=story, position=position)
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

Compute and store Voronoi vertex tributary areas on each Column.

For each cell:
1. Get the cell's corner vertices (column positions)
2. Compute Voronoi clipped to the cell boundary
3. Store per-cell area in `col.tributary_by_slab[cell_idx]`
4. Store per-cell polygon in `col.tributary_polygons[cell_idx]` (for visualization)
5. Sum contributions to get total `col.tributary_area`

Note: Columns use their bottom vertex_idx, but floor cells have vertices at the floor 
elevation. We match by (x,y) position to link columns to their supported floor areas.
"""
function compute_column_tributaries!(struc::BuildingStructure{T}) where T
    isempty(struc.columns) && return struc
    
    skel = struc.skeleton
    
    # Build (x,y) → Column lookup (rounded to avoid FP precision issues)
    # We use the column's vertex position (bottom of column) to get x,y
    col_by_xy = Dict{Tuple{Float64, Float64}, Vector{Column{T}}}()
    for col in struc.columns
        c = Meshes.coords(skel.vertices[col.vertex_idx])
        xy = (round(Float64(ustrip(u"m", c.x)), digits=6), 
              round(Float64(ustrip(u"m", c.y)), digits=6))
        push!(get!(col_by_xy, xy, Column{T}[]), col)
        
        # Reset tributary data
        col.tributary_area = 0.0
        empty!(col.tributary_by_slab)
        empty!(col.tributary_polygons)
    end
    
    # Process each cell
    for (cell_idx, cell) in enumerate(struc.cells)
        v_indices = skel.face_vertex_indices[cell.face_idx]
        length(v_indices) < 3 && continue
        
        # Get cell elevation for matching columns
        first_vert = skel.vertices[v_indices[1]]
        cell_z = Float64(ustrip(u"m", Meshes.coords(first_vert).z))
        
        # Extract vertex positions as tuples (in meters)
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
        
        # Store results on columns (matching by x,y position)
        for (i, trib) in enumerate(tribs)
            xy = cell_xys[i]
            cols = get(col_by_xy, xy, nothing)
            isnothing(cols) && continue
            
            # Find the column whose TOP is at or below this floor level
            # (column that supports this floor)
            matched_col = nothing
            for col in cols
                v_c = Meshes.coords(skel.vertices[col.vertex_idx])
                col_bottom_z = Float64(ustrip(u"m", v_c.z))
                # This column supports the floor if its top is at the floor elevation
                # Column top = col_bottom_z + column height (L)
                col_top_z = col_bottom_z + Float64(ustrip(u"m", col.base.L))
                if abs(col_top_z - cell_z) < 0.1  # Within 10cm tolerance
                    matched_col = col
                    break
                end
            end
            isnothing(matched_col) && continue
            
            # Store area and polygon
            matched_col.tributary_by_slab[cell_idx] = trib.area
            matched_col.tributary_polygons[cell_idx] = trib.polygon
            matched_col.tributary_area += trib.area
        end
    end
    
    n_with_trib = count(c.tributary_area > 0 for c in struc.columns)
    n_with_breakdown = count(!isempty(c.tributary_by_slab) for c in struc.columns)
    @debug "Computed Voronoi tributary areas" total=n_with_trib per_cell=n_with_breakdown columns=length(struc.columns)
    
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
    classify_column_position(skel, vertex_idx) -> Symbol

Classify column position based on number of connected horizontal edges at ground level.
- 4+ connections → :interior
- 2 connections → :corner  
- 3 connections → :edge
"""
function classify_column_position(skel::BuildingSkeleton, vertex_idx::Int)
    # Count horizontal edges connected to this vertex at ground level
    neighbors = Graphs.neighbors(skel.graph, vertex_idx)
    
    # Filter to horizontal edges (same z-level)
    v_z = Meshes.coords(skel.vertices[vertex_idx]).z
    horizontal_neighbors = filter(neighbors) do n_idx
        n_z = Meshes.coords(skel.vertices[n_idx]).z
        abs(n_z - v_z) < 0.01u"m"  # Same level (within tolerance)
    end
    
    n_connections = length(horizontal_neighbors)
    
    if n_connections >= 4
        return :interior
    elseif n_connections <= 2
        return :corner
    else
        return :edge
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

    # Build member groups for beams if needed
    isempty(struc.member_groups) && build_member_groups!(struc; member_type=:beams)

    # Only include groups that actually contain at least one segment in `beam_edge_ids`.
    all_group_ids = sort!(collect(keys(struc.member_groups)))  # deterministic ordering

    group_ids = UInt64[]
    demands = StructuralSizer.MemberDemand{Float64}[]
    
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
            m = struc.beams[m_idx]  # member_groups for beams index into struc.beams
            
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
                f = AsapToolkit.InternalForces(el, struc.asap_model; resolution=resolution)

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
                edisp = AsapToolkit.ElementDisplacements(el, struc.asap_model; resolution=resolution)
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
    `AsapToolkit.toASAPframe`. To support other materials (concrete, timber), the
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
        chosen.name === nothing && throw(ArgumentError("Chosen section has no name; cannot convert to ASAP section via `toASAPframe(name, ...)`."))
        sec_name = chosen.name
        asap_sec = AsapToolkit.toASAPframe(sec_name; E=material.E, G=material.G, ρ=material.ρ, unit=u"m")

        for m_idx in mg.member_indices
            m = struc.beams[m_idx]  # member_groups for beams index into struc.beams
            
            # Compute total length and store section/volume on member
            # Ensure L_total has units (skeleton may use plain Float64)
            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_volumes!(m, MaterialVolumes(material => StructuralSizer.area(chosen) * L_total))
            
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
