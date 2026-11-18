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
    initialize_members!(struc; default_Kx=1.0, default_Ky=1.0, wall_thickness=nothing)

Initialize typed members (Beam, Column, Strut, Wall) from skeleton edge groups.

Uses skeleton `groups_edges` to determine member type:
- `:beams` → `Beam` (with role classification)
- `:columns` → `Column` (with position classification)
- `:braces` → `Strut`
- `:walls` → `Wall`

A `:walls` edge never becomes a `Beam`. An edge index that is in `:walls`
and also in `:beams`, `:columns`, or `:braces` throws `ArgumentError`
naming that edge index. The beam, column, or brace is not dropped. Each
wall edge, or each shattered chain of `:walls` edges, becomes one `Wall`.
An `:absent` edge keeps its segment and becomes no member. `to_asap!`
still holds that edge's frame slot. An edge index that is in `:absent`
and also in `:beams`, `:columns`, `:braces`, or `:walls` throws
`ArgumentError`. A shattered chain that mixes `:absent` with another
group throws the same way. A chain whose edges are all `:absent` builds
no member.
`segment_indices` point at `struc.segments`, same as beams. `Wall.story`
is the 0-based story whose elevation is nearest the plan-line Z. Both
ends of a `:walls` edge already share that Z. The nearest distance must
be at most 1e-4 m; a larger gap throws `ArgumentError`. This does not
use [`edge_story`](@ref) or its 0.1 m window (columns still do). Every
edge in a chain must resolve to the same story.
`base.L` is the pier height from [`_wall_pier_height`](@ref): the next
higher story whose `Story.faces` is non-empty, minus this story's floor
elevation. Stories that contain only vertices are skipped. The plan edge
length is not used. Plan endpoints `x1,y1,x2,y2` are the chain-end
`vertex_coords` in metres (the `story_plate_geometry` datum). `concrete`
stays `nothing`.

`wall_thickness` is required, and must already have the structure length
type `T`, when `groups_edges[:walls]` is non-empty. [`DesignParameters`](@ref)
has no wall thickness. `wall_thickness = nothing` with a non-empty `:walls`
group throws `ArgumentError` on purpose. There is no default thickness.
An empty `:walls` group leaves `struc.walls` empty and does not read
`wall_thickness`.

[`to_wall_line`](@ref) maps `WallLine.story = Wall.story + 1` because
`WallLine.story` is 1-based. This function stores the 0-based index and
does not apply that shift.

Other segments, aside from `:absent`, stay 1:1 with a member, with
shattered chains merged the same way as beams.
"""
function initialize_members!(struc::BuildingStructure{T};
                             default_Kx=1.0, default_Ky=1.0,
                             wall_thickness=nothing,
                             plan_axis::NTuple{2, <:Real}=(1.0, 0.0)) where T
    skel = struc.skeleton
    
    # Clear existing members
    empty!(struc.beams)
    empty!(struc.columns)
    empty!(struc.struts)
    empty!(struc.walls)
    
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
    wall_edges = Set(get(skel.groups_edges, :walls, Int[]))
    absent_edges = Set(get(skel.groups_edges, :absent, Int[]))
    # One edge index in two groups would become only a Wall and the beam,
    # column, or brace would disappear. Name the edge and refuse.
    for eidx in sort!(collect(wall_edges))
        others = String[]
        eidx in beam_edges && push!(others, ":beams")
        eidx in column_edges && push!(others, ":columns")
        eidx in brace_edges && push!(others, ":braces")
        isempty(others) && continue
        throw(ArgumentError(
            "initialize_members!: edge index $eidx is in :walls and also in " *
            join(others, ", ") * "."))
    end
    # :absent is parked geometry. It is not a beam that the fall-through
    # below would otherwise build, and it is not a second member on an
    # edge that already has one.
    for eidx in sort!(collect(absent_edges))
        others = String[]
        eidx in beam_edges && push!(others, ":beams")
        eidx in column_edges && push!(others, ":columns")
        eidx in brace_edges && push!(others, ":braces")
        eidx in wall_edges && push!(others, ":walls")
        isempty(others) && continue
        throw(ArgumentError(
            "initialize_members!: edge index $eidx is in :absent and also in " *
            join(others, ", ") * "."))
    end
    # Nothing when :walls is empty. Throws if the group is non-empty and
    # wall_thickness is nothing — no default thickness. `prepare!` forwards
    # `DesignParameters.wall_thickness`.
    thickness = _require_wall_thickness(T, wall_edges, wall_thickness)
    # c1 lies along the plan axis. (1, 0) gives θ = 0, the previous default.
    e1 = unit_plan_axis(plan_axis)
    column_θ = atan(e1[2], e1[1])
    
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

    # Deferred beam-role classification: (beam_index, endpoints, edge_indices).
    # Roles are assigned after the full column set exists so the `:girder` test
    # can reference every `Column.vertex_idx` (see `classify_beam_role`).
    beam_class_info = Tuple{Int, NTuple{2, Int}, Vector{Int}}[]

    for (seg_idx, seg) in enumerate(struc.segments)
        edge_idx = seg.edge_idx
        edge_idx in processed_edges && continue
        
        if haskey(edge_to_chain, edge_idx)
            # One beam. The solve graph may cut it into several edges, and
            # those edges are this one member, so they take one section.
            # Separate beams that only happen to be collinear are not joined
            # here. That grouping is optional (`collinear_grouping`).
            chain_id = edge_to_chain[edge_idx]
            chain_edge_indices = skel.edge_chains[chain_id]
            
            # Mark all chain edges as processed
            for eidx in chain_edge_indices
                push!(processed_edges, eidx)
            end
            
            # Collect segment indices for the chain (ordered)
            chain_seg_indices = [edge_to_seg[eidx] for eidx in chain_edge_indices]

            # :walls is checked before the beam fall-through. A mixed chain
            # throws inside _chain_is_all_walls rather than becoming a Beam.
            # Pier height is story-to-story, so the plan length is not computed
            # on this path.
            if _chain_is_all_walls(chain_edge_indices, wall_edges)
                _push_wall!(struc, skel, chain_seg_indices, chain_edge_indices,
                            thickness, vc)
            elseif all(e -> e in absent_edges, chain_edge_indices)
                # Parked chain: the segments stay, and no member is built.
            elseif any(e -> e in absent_edges, chain_edge_indices)
                bad = chain_edge_indices[findfirst(e -> e in absent_edges, chain_edge_indices)]
                throw(ArgumentError(
                    "initialize_members!: edge index $bad is in :absent inside " *
                    "a chain that also has another group."))
            else
                chain_segs = [struc.segments[si] for si in chain_seg_indices]

                # Compute total length and governing unbraced length
                L_total = sum(s.L for s in chain_segs)
                Lb_gov = maximum(s.Lb for s in chain_segs)
                Cb_gov = minimum(s.Cb for s in chain_segs)

                # Determine group from the first edge in the chain
                first_edge = chain_edge_indices[1]

                if first_edge in column_edges
                    _create_chain_column!(struc, skel, chain_seg_indices, chain_edge_indices,
                                          L_total, Lb_gov, Cb_gov, default_Kx, default_Ky, vc, efc,
                                          column_θ)
                elseif first_edge in brace_edges
                    strut = Strut(chain_seg_indices, L_total;
                                 Lb=Lb_gov, Kx=default_Kx, Ky=default_Ky, Cb=Cb_gov,
                                 brace_type=:both)
                    push!(struc.struts, strut)
                else
                    beam = Beam(chain_seg_indices, L_total;
                               Lb=Lb_gov, Kx=default_Kx, Ky=default_Ky, Cb=Cb_gov)
                    push!(struc.beams, beam)
                    push!(beam_class_info,
                          (length(struc.beams),
                           _chain_endpoint_vertices(skel, chain_edge_indices),
                           collect(chain_edge_indices)))
                end
            end
        else
            # Standalone edge (no chain) — 1:1 mapping as before
            push!(processed_edges, edge_idx)
            
            if edge_idx in wall_edges
                _push_wall!(struc, skel, [seg_idx], [edge_idx], thickness, vc)
            elseif edge_idx in column_edges
                v1, v2 = skel.edge_indices[edge_idx]
                z1 = vc[v1, 3]
                z2 = vc[v2, 3]
                vertex_idx = z1 > z2 ? v1 : v2
                story = edge_story(skel, edge_idx)
                position, boundary_edge_dirs = classify_column_position(skel, vertex_idx, vc, efc)
                corner_angle = position == :corner ? slab_material_angle(skel, vertex_idx, vc) : 0.0
                corner_kind = classify_corner_kind(corner_angle, position)
                
                col = Column(seg_idx, seg.L; 
                            Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb,
                            vertex_idx=vertex_idx, story=story, position=position,
                            corner_kind=corner_kind, corner_angle=corner_angle,
                            boundary_edge_dirs=boundary_edge_dirs, θ=column_θ)
                push!(struc.columns, col)
                
            elseif edge_idx in brace_edges
                strut = Strut(seg_idx, seg.L;
                             Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb,
                             brace_type=:both)
                push!(struc.struts, strut)

            elseif edge_idx in absent_edges
                # Parked edge: the segment stays, and no member is built.

            else
                beam = Beam(seg_idx, seg.L;
                           Lb=seg.Lb, Kx=default_Kx, Ky=default_Ky, Cb=seg.Cb)
                push!(struc.beams, beam)
                push!(beam_class_info,
                      (length(struc.beams),
                       _chain_endpoint_vertices(skel, (edge_idx,)),
                       [edge_idx]))
            end
        end
    end

    # Classify beam roles now that all columns exist. `:girder` when both chain
    # endpoints land on a column vertex; `:joist` when the beam supports a slab
    # (any sub-edge lies on a slab-cell boundary) and is not a girder; `:beam`
    # otherwise. Skeleton members stay at `level = 0` until
    # `assign_framing_levels!` (`populate_levels!`) writes the support rank.
    column_vertices = Set(col.vertex_idx for col in struc.columns)
    slab_support_edges = Set{Int}()
    for slab in struc.slabs
        for e_idx in slab_face_edge_ids(struc, slab)
            push!(slab_support_edges, e_idx)
        end
    end
    for (b_idx, endpoints, edge_indices) in beam_class_info
        struc.beams[b_idx].role =
            classify_beam_role(endpoints, edge_indices, column_vertices, slab_support_edges)
    end

    n_total = length(struc.beams) + length(struc.columns) + length(struc.struts)
    n_chains = length(skel.edge_chains)
    @debug "Initialized members from $(length(struc.segments)) segments" beams=length(struc.beams) columns=length(struc.columns) struts=length(struc.struts) walls=length(struc.walls) chains=n_chains
    
    # Link columns across stories (col.column_above)
    link_column_stack!(struc)
    
    # Compute Voronoi tributary areas for columns
    compute_column_tributaries!(struc)

    # Link walls across stories (wall.wall_above). Last, so every Wall exists.
    link_wall_stack!(struc)
    
    return struc
end

# Exact-match tolerance [m] on plan-line Z (bare metres). Copied from the
# elevation exact-match tolerance in `_find_level_idx` (1e-4). A vertical pier
# is metres tall and fails the per-edge |z2-z1| check; float noise on a
# horizontal edge does not. The same tolerance is the maximum distance from a
# wall's plan-line Z to the nearest story elevation. `edge_story` uses a 0.1 m
# window and the first hit in the story dict; walls do not.

"""
Create a Column from a chain of shattered edge segments.

Uses the top vertex (highest Z) of the last edge in the chain for position
classification and story assignment.
"""
function _create_chain_column!(struc, skel, chain_seg_indices, chain_edge_indices,
                                L_total, Lb_gov, Cb_gov, default_Kx, default_Ky, vc, efc,
                                column_θ::Float64=0.0)
    # Use the top vertex of the chain (highest Z) for classification
    last_edge = chain_edge_indices[end]
    v1, v2 = skel.edge_indices[last_edge]
    z1 = vc[v1, 3]
    z2 = vc[v2, 3]
    vertex_idx = z1 > z2 ? v1 : v2
    
    story = edge_story(skel, last_edge)
    position, boundary_edge_dirs = classify_column_position(skel, vertex_idx, vc, efc)
    corner_angle = position == :corner ? slab_material_angle(skel, vertex_idx, vc) : 0.0
    corner_kind = classify_corner_kind(corner_angle, position)
    
    col = Column(chain_seg_indices, L_total;
                Lb=Lb_gov, Kx=default_Kx, Ky=default_Ky, Cb=Cb_gov,
                vertex_idx=vertex_idx, story=story, position=position,
                corner_kind=corner_kind, corner_angle=corner_angle,
                boundary_edge_dirs=boundary_edge_dirs, θ=column_θ)
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
