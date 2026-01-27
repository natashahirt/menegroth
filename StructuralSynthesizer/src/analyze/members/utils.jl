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
Initialize members from segments.
Default: each segment becomes its own member (1:1 mapping).
Override by passing explicit segment groupings.
"""
function initialize_members!(struc::BuildingStructure{T}; 
                             segment_groupings::Union{Nothing, Vector{Vector{Int}}}=nothing,
                             default_Kx=1.0, default_Ky=1.0) where T
    empty!(struc.members)
    
    if isnothing(segment_groupings)
        # Default: 1 member per segment
        for (seg_idx, seg) in enumerate(struc.segments)
            member = Member(seg_idx, seg.L; Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb)
            push!(struc.members, member)
        end
    else
        # Explicit groupings: combine segments into members
        for seg_indices in segment_groupings
            segs = [struc.segments[i] for i in seg_indices]
            # Governing values
            L_gov = sum(s.L for s in segs)
            Lb_gov = maximum(s.Lb for s in segs)
            Cb_gov = minimum(s.Cb for s in segs)  # conservative
            
            member = Member(seg_indices, L_gov; Lb=Lb_gov, Kx=default_Kx, Ky=default_Ky, Cb=Cb_gov)
            push!(struc.members, member)
        end
    end
    
    @debug "Initialized $(length(struc.members)) members from $(length(struc.segments)) segments"
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
    build_member_groups!(struc::BuildingStructure)

Populate `struc.member_groups` from `struc.members` using `Member.group_id`.

- If `member.group_id === nothing`, the member is treated as its own singleton group
  and a deterministic `UInt64` group id is assigned.
- If `member.group_id` is set, all members with the same id are grouped together.
"""
function build_member_groups!(struc::BuildingStructure)
    empty!(struc.member_groups)

    for (m_idx, m) in enumerate(struc.members)
        gid = m.group_id === nothing ? UInt64(hash((:singleton_member_group, m_idx))) : m.group_id
        # Persist the resolved group id back onto the member (useful for downstream operations)
        m.group_id = gid

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

    # Build member groups if needed
    isempty(struc.member_groups) && build_member_groups!(struc)

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
            m = struc.members[m_idx]
            
            # Group geometry governance (take worst case K across members in group)
            Kx_gov = max(Kx_gov, m.Kx)
            Ky_gov = max(Ky_gov, m.Ky)

            for seg_idx in m.segment_indices
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
            m = struc.members[m_idx]
            
            # Compute total length and store section/volume on member
            # Ensure L_total has units (skeleton may use plain Float64)
            L_raw = sum(struc.segments[i].L for i in m.segment_indices)
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            m.section = chosen
            m.volumes = MaterialVolumes(material => StructuralSizer.area(chosen) * L_total)
            
            # Update ASAP elements
            for seg_idx in m.segment_indices
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
