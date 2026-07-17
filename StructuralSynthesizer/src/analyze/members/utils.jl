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

    # Deferred beam-role classification: (beam_index, endpoints, edge_indices).
    # Roles are assigned after the full column set exists so the `:girder` test
    # can reference every `Column.vertex_idx` (see `classify_beam_role`).
    beam_class_info = Tuple{Int, NTuple{2, Int}, Vector{Int}}[]

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
                beam = Beam(chain_seg_indices, L_total;
                           Lb=Lb_gov, Kx=default_Kx, Ky=default_Ky, Cb=Cb_gov)
                push!(struc.beams, beam)
                push!(beam_class_info,
                      (length(struc.beams),
                       _chain_endpoint_vertices(skel, chain_edge_indices),
                       collect(chain_edge_indices)))
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
    # otherwise. Skeleton-input members keep the default `level = 0`.
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
    @debug "Initialized members from $(length(struc.segments)) segments" beams=length(struc.beams) columns=length(struc.columns) struts=length(struc.struts) chains=n_chains
    
    # Link columns across stories (col.column_above)
    link_column_stack!(struc)
    
    # Compute Voronoi tributary areas for columns
    compute_column_tributaries!(struc)
    
    return struc
end

# =============================================================================
# Member (Beam) Tributary Profiles — Layer 1 of the tributary pipeline
# =============================================================================
#
# Layer 0 (cells → cell edges) is `compute_cell_tributaries!`.
# Layer 1 (cells/panels → Level-0 beams) is `compute_member_tributaries!` below:
# it merges the per-cell edge tributaries that meet on each beam into a single
# variable `TributaryProfile` stored on the beam. The load path
# (`_create_cell_tributary_loads!`) still emits `Asap.TributaryLoad`s directly
# from the cell cache; these member profiles feed the design layer (effective
# flange width, and — in later phases — the level-to-level tributary cascade).

"""
    compute_member_tributaries!(struc; strategy::Symbol=:cell_merge) -> struc

Populate each `Beam`'s `tributary_profile` (Layer 1 of the tributary pipeline).

# Strategies
- `:cell_merge` (default): merge the per-cell edge tributaries that meet on each
  beam — the width contributions from the (up to two) adjacent cells are summed
  along the beam. Mirrors the geometry already used by
  `_create_cell_tributary_loads!`.
- `:shell_panels`: delegate to `Asap._shell_panels_to_tributary_loads` when the
  Asap model carries shell elements (multi-bay continuous-girder case). The
  synthesizer's design model is frame-only today, so when no shells are present
  this falls back to `:cell_merge` with a warning.

Beams with no adjacent tributary keep `tributary_profile == nothing`.
"""
function compute_member_tributaries!(struc::BuildingStructure; strategy::Symbol=:cell_merge)
    if strategy === :cell_merge
        return _compute_member_tributaries_cell_merge!(struc)
    elseif strategy === :shell_panels
        return _compute_member_tributaries_shell_panels!(struc)
    else
        throw(ArgumentError(
            "compute_member_tributaries!: unknown strategy $(strategy); use :cell_merge or :shell_panels"))
    end
end

"""Convert a length in meters (Float64) to the structure's length type `T`."""
_meters_to_T(::Type{T}, x_m::Float64) where {T} = convert(T, x_m)
_meters_to_T(::Type{T}, x_m::Float64) where {T<:Unitful.Quantity} = convert(T, x_m * u"m")

"""Frame elements of an Asap model (handles frame-only vs mixed models)."""
function _frame_elements(model)
    isnothing(model) && return []
    hasproperty(model, :frame_elements) && return model.frame_elements
    hasproperty(model, :elements) && return model.elements
    return []
end

"""Shell elements of an Asap model, or an empty vector for a frame-only model."""
function _asap_shell_elements(model)
    isnothing(model) && return []
    hasproperty(model, :shell_elements) && return model.shell_elements
    return []
end

"""Clamped piecewise-linear interpolation of `w` sampled at `pos` evaluated at `s`."""
function _interp_linear(pos::Vector{Float64}, w::Vector{Float64}, s::Float64)
    s <= pos[1] && return w[1]
    s >= pos[end] && return w[end]
    idx = clamp(searchsortedlast(pos, s), 1, length(pos) - 1)
    p0, p1 = pos[idx], pos[idx + 1]
    p1 == p0 && return w[idx + 1]
    return w[idx] + (w[idx + 1] - w[idx]) * (s - p0) / (p1 - p0)
end

"""
Ordered vertex sequence `[v0, v1, ..., vn]` traversed by a chain of `edges`, so
edge `k` connects `verts[k]` → `verts[k+1]`. For a single edge, returns the edge
in its canonical (`edge_indices`) orientation.
"""
function _ordered_chain_vertices(skel, edges::Vector{Int})
    n = length(edges)
    verts = Vector{Int}(undef, n + 1)
    if n == 1
        a, b = skel.edge_indices[edges[1]]
        verts[1] = a
        verts[2] = b
        return verts
    end
    e1 = skel.edge_indices[edges[1]]
    e2 = skel.edge_indices[edges[2]]
    # Start of edge 1 is its endpoint not shared with edge 2.
    start_v = (e1[1] == e2[1] || e1[1] == e2[2]) ? e1[2] : e1[1]
    verts[1] = start_v
    cur = start_v
    for (k, e) in enumerate(edges)
        a, b = skel.edge_indices[e]
        nxt = a == cur ? b : a
        verts[k + 1] = nxt
        cur = nxt
    end
    return verts
end

"""Extend a `[?, ?]`-spanning (positions, widths) profile to span `[0, 1]` by flat
extension of the boundary widths."""
function _span_unit_interval(pos::Vector{Float64}, w::Vector{Float64})
    isempty(pos) && return ([0.0, 1.0], [0.0, 0.0])
    p = copy(pos)
    ww = copy(w)
    if p[1] > 1e-9
        pushfirst!(p, 0.0)
        pushfirst!(ww, ww[1])
    else
        p[1] = 0.0
    end
    if p[end] < 1.0 - 1e-9
        push!(p, 1.0)
        push!(ww, ww[end])
    else
        p[end] = 1.0
    end
    return (p, ww)
end

"""
Accumulate per-cell edge tributary width profiles, keyed by global edge index and
stored in the canonical edge orientation (`edge_indices[e] = (v1, v2)`, i.e.
`s = 0` at `v1`). Widths are in meters.
"""
function _accumulate_edge_width_profiles(struc::BuildingStructure)
    skel = struc.skeleton
    ProfT = Tuple{Vector{Float64}, Vector{Float64}}
    edge_profiles = Dict{Int, Vector{ProfT}}()
    for (cell_idx, cell) in enumerate(struc.cells)
        tribs = cell_edge_tributaries(struc, cell_idx)
        isnothing(tribs) && continue
        face_edges = skel.face_edge_indices[cell.face_idx]
        face_verts = skel.face_vertex_indices[cell.face_idx]
        (isempty(face_edges) || isempty(face_verts)) && continue
        n_verts = length(face_verts)
        for trib in tribs
            trib.area < 1e-12 && continue
            length(trib.s) < 2 && continue
            positions, widths_m = _extract_width_profile(trib)
            length(positions) < 2 && continue
            local_idx = trib.local_edge_idx
            (local_idx < 1 || local_idx > length(face_edges)) && continue
            global_edge = face_edges[local_idx]
            expected_v1 = face_verts[local_idx]
            expected_v2 = face_verts[mod1(local_idx + 1, n_verts)]
            actual_v1, actual_v2 = skel.edge_indices[global_edge]
            if actual_v1 == expected_v2 && actual_v2 == expected_v1
                positions = reverse(1.0 .- positions)
                widths_m = reverse(widths_m)
            end
            push!(get!(Vector{ProfT}, edge_profiles, global_edge), (positions, widths_m))
        end
    end
    return edge_profiles
end

"""Sum the (≤ 2) cell width profiles that share an edge onto the union of their
breakpoints. Widths in meters, canonical edge orientation."""
function _merge_edge_profiles(profiles::Vector{Tuple{Vector{Float64}, Vector{Float64}}})
    isempty(profiles) && return (Float64[], Float64[])
    length(profiles) == 1 && return profiles[1]
    all_pos = Float64[]
    for (pos, _) in profiles
        append!(all_pos, pos)
    end
    sort!(all_pos)
    unique_pos = Float64[]
    for p in all_pos
        if isempty(unique_pos) || abs(p - unique_pos[end]) > 1e-9
            push!(unique_pos, p)
        end
    end
    merged_w = zeros(Float64, length(unique_pos))
    for (pos, w) in profiles
        for (i, s) in enumerate(unique_pos)
            merged_w[i] += _interp_linear(pos, w, s)
        end
    end
    return (unique_pos, merged_w)
end

"""
Assign `beam.tributary_profile` from a dict of per-edge width profiles (canonical
orientation, meters). Concatenates each beam's segments in chain order, mapping
each segment's local `[0, 1]` onto the beam's global `[0, 1]` by physical length.
Beams whose edges carry no tributary are left untouched.
"""
function _assign_beam_profiles_from_edges!(struc::BuildingStructure{T},
        edge_merged::Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}}) where {T}
    skel = struc.skeleton

    # (Phase 10) Sub-edge → chain-head lookup. When a Level-0 host has been
    # subdivided by `_split_host_edge!` (Phase 5 landings on the boundary, or
    # Phase 10 higher-level landings on lower-level joists), the cell tributary
    # profile is still stored under the ORIGINAL (chain-head) edge index in
    # `edge_merged`, parameterized in `[0, 1]` over the FULL original edge —
    # not over the shorter head sub-edge alone. The per-sub-edge loop below
    # naively treats that profile as local to the head sub-edge, compressing an
    # 8 m trapezoid into 2 m and losing 3/4 of the tributary area. Detect the
    # chain here and treat the head-stored profile as the WHOLE-BEAM profile
    # instead (head's `[0, 1]` is already the beam's `[0, 1]` because a
    # host-chain beam covers exactly the original edge end-to-end).
    edge_to_chain = Dict{Int, Vector{Int}}()
    for (_, sub_edges) in skel.edge_chains
        length(sub_edges) < 2 && continue
        for e in sub_edges
            edge_to_chain[e] = sub_edges
        end
    end

    for beam in struc.beams
        segs = segment_indices(beam)
        isempty(segs) && continue
        edges = [struc.segments[si].edge_idx for si in segs]
        verts = _ordered_chain_vertices(skel, edges)

        seg_len_m = Float64[]
        for si in segs
            L = struc.segments[si].L
            push!(seg_len_m, L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L))
        end
        total = sum(seg_len_m)
        total <= 0 && continue

        # (Phase 10) Whole-beam fast path for host-chain beams. The beam's
        # edges must exactly equal a single chain in `skel.edge_chains` for
        # this to apply — otherwise fall through to the per-sub-edge loop.
        head_chain = get(edge_to_chain, edges[1], nothing)
        if head_chain !== nothing && head_chain == edges &&
           haskey(edge_merged, head_chain[1])
            head = head_chain[1]
            pos_c, w_c = edge_merged[head]
            a, _ = skel.edge_indices[head]
            # Head sub-edge orientation: canonical edge_indices[head] = (a, _),
            # but after `_split_host_edge!` the head IS the first sub-edge
            # `(chain_vs[1], chain_vs[2])`. The beam is ordered `verts[1] →
            # verts[end]`; the head profile is [0, 1] over `v_a → v_b` of the
            # ORIGINAL edge (see `_accumulate_edge_width_profiles`). Since
            # `_split_host_edge!` preserves the original v1→v2 orientation as
            # the beam's chain direction (v1 == verts[1], v2 == verts[end]),
            # the head profile is naturally in the beam's forward direction if
            # `verts[1] == a`; reverse otherwise.
            if verts[1] != a
                pos_c = reverse(1.0 .- pos_c)
                w_c = reverse(w_c)
            end
            positions_all, widths_all_m = _span_unit_interval(pos_c, w_c)
            if maximum(widths_all_m) > 0
                widths_T = T[_meters_to_T(T, w) for w in widths_all_m]
                beam.tributary_profile = TributaryProfile{T}(positions_all, widths_T, nothing)
            end
            continue
        end

        positions_all = Float64[]
        widths_all_m = Float64[]
        offset = 0.0
        any_trib = false
        for k in eachindex(edges)
            e = edges[k]
            if haskey(edge_merged, e)
                pos_c, w_c = edge_merged[e]
                # Canonical orientation is edge_indices[e] = (a, b) with s = 0 at a.
                # The beam traverses verts[k] → verts[k+1]; reverse if it disagrees.
                a, _ = skel.edge_indices[e]
                if verts[k] != a
                    pos_c = reverse(1.0 .- pos_c)
                    w_c = reverse(w_c)
                end
                pos_c, w_c = _span_unit_interval(pos_c, w_c)
                maximum(w_c) > 0 && (any_trib = true)
            else
                pos_c = [0.0, 1.0]
                w_c = [0.0, 0.0]
            end
            Lk = seg_len_m[k]
            for j in eachindex(pos_c)
                push!(positions_all, (offset + pos_c[j] * Lk) / total)
                push!(widths_all_m, w_c[j])
            end
            offset += Lk
        end

        any_trib || continue

        positions_all[1] = 0.0
        positions_all[end] = 1.0
        for i in 2:length(positions_all)
            positions_all[i] < positions_all[i - 1] && (positions_all[i] = positions_all[i - 1])
        end
        widths_T = T[_meters_to_T(T, w) for w in widths_all_m]
        beam.tributary_profile = TributaryProfile{T}(positions_all, widths_T, nothing)
    end
    return struc
end

"""`:cell_merge` strategy — merge per-cell edge tributaries onto each beam."""
function _compute_member_tributaries_cell_merge!(struc::BuildingStructure)
    edge_profiles = _accumulate_edge_width_profiles(struc)
    edge_merged = Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}}()
    for (e, profs) in edge_profiles
        edge_merged[e] = _merge_edge_profiles(profs)
    end
    return _assign_beam_profiles_from_edges!(struc, edge_merged)
end

"""`:shell_panels` strategy — delegate to `Asap._shell_panels_to_tributary_loads`
when shells are present, else fall back to `:cell_merge`.

Shells are grouped into per-bay panels by their `id` tag (Phase 7): shells built
per slab (e.g. `:slab_1`, `:slab_2` from `build_analysis_model!`) form separate
panels, so a girder shared by two bays receives its tributary from **both** and
`Asap._shell_panels_to_tributary_loads` sums the depths across panels — the
multi-bay continuous-girder case that function was written for. A single shared
tag collapses to one panel (the earlier behavior). Only host members (non-joist
beams) are handed to the Asap matcher, since it requires every beam to lie on a
panel boundary; interior joists are served by `:cell_merge`. If the frame-only
design model carries no shells, or the panel geometry does not match the beams,
this falls back to `:cell_merge` with a warning."""
function _compute_member_tributaries_shell_panels!(struc::BuildingStructure)
    shells = _asap_shell_elements(struc.asap_model)
    if isempty(shells)
        @warn "compute_member_tributaries!(strategy=:shell_panels): no shell elements in the Asap model (design model is frame-only); falling back to :cell_merge."
        return _compute_member_tributaries_cell_merge!(struc)
    end

    frame_els = _frame_elements(struc.asap_model)
    isempty(frame_els) && return struc

    # Map each HOST (non-joist) beam edge to its Asap frame element. The Asap
    # multi-panel matcher requires every beam to sit on a panel boundary, so only
    # boundary/host members are eligible; interior joists route via :cell_merge.
    edge_to_el = Dict{Int, Asap.FrameElement}()
    el_to_edge = Dict{Asap.FrameElement, Int}()
    for beam in struc.beams
        is_joist(beam) && continue
        for si in segment_indices(beam)
            e = struc.segments[si].edge_idx
            (e >= 1 && e <= length(frame_els)) || continue
            el = frame_els[e]
            edge_to_el[e] = el
            el_to_edge[el] = e
        end
    end
    isempty(edge_to_el) && return struc

    beam_elements = collect(Asap.FrameElement, values(edge_to_el))
    # Per-bay panels keyed by shell id (see the docstring). Pressure is a unit
    # dummy — only the geometric widths from the returned loads are consumed.
    by_id = Dict{Symbol, Vector{Asap.ShellElement}}()
    for sh in shells
        push!(get!(() -> Asap.ShellElement[], by_id, sh.id), sh)
    end
    panels = collect(values(by_id))

    local loads
    try
        loads = Asap._shell_panels_to_tributary_loads(panels, beam_elements, 1.0u"Pa")
    catch err
        @warn "compute_member_tributaries!(strategy=:shell_panels): shell panels did not match the host beams; falling back to :cell_merge." exception=(err, catch_backtrace())
        return _compute_member_tributaries_cell_merge!(struc)
    end

    edge_merged = Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}}()
    for ld in loads
        el = ld.element
        haskey(el_to_edge, el) || continue
        widths_m = [ustrip(u"m", w) for w in ld.widths]
        edge_merged[el_to_edge[el]] = (copy(ld.positions), widths_m)
    end
    return _assign_beam_profiles_from_edges!(struc, edge_merged)
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

# =============================================================================
# End-release resolution (Phase 2)
# =============================================================================
#
# Segments own per-end fixity symbols (:default | :fixed | :pinned); the resolver
# collapses a beam's chain of segments plus its whole-member torsion flag to one
# of Asap's five element-release enums. `:default` symbols defer to the Phase 3
# `(role, material, lateral_role)` dispatch — `StructuralSizer.default_release`
# and `StructuralSizer.default_torsion_released` (declared in
# `StructuralSizer/src/members/defaults.jl`, per-material specializations in the
# material modules), imported here via `@reexport using StructuralSizer` in
# `StructuralSynthesizer.jl`.

# Allowed per-end segment release symbols.
const _RELEASE_SEGMENT_SYMS = (:default, :fixed, :pinned)

"""
    _release_enum(start_sym, end_sym, torsion_released) -> Symbol

Collapse a pair of resolved per-end fixity symbols (each `:fixed` or `:pinned`)
plus a whole-member torsion flag to one of Asap's five element-release enums
(`external/Asap/src/Elements/elements.jl`): `:fixedfixed`, `:freefixed`,
`:fixedfree`, `:freefree`, `:joist`. `torsion_released` only selects between
`:joist` and `:freefree` for the pinned–pinned case; it is irrelevant otherwise.

!!! note "`torsion_released` naming — reconciled in Phase 3 via docstring"
    Asap's `k_joist` kernel (`external/Asap/src/Elements/K.jl` line 293) is built
    from `E, A, L, G, J` — it **retains** axial and torsion and releases only
    bending, whereas `k_freefree` retains axial alone. Physically Asap's `:joist`
    therefore keeps torsion **fixed**, so the field name `torsion_released` reads
    as the inverse of the DOF state it selects. Phase 3 keeps the field name
    (Option A) and documents the intended meaning on `Beam.torsion_released`:
    `torsion_released == true` selects Asap's OWSJ-style `:joist` element (pinned
    bending ends, retained torsional `GJ`), it does **not** mean literal torsion
    release. The `(:pinned, :pinned) + torsion_released == true => :joist` mapping
    encodes that intent (steel OWSJ => Asap `:joist`).
"""
function _release_enum(start_sym::Symbol, end_sym::Symbol, torsion_released::Bool)
    start_sym === :fixed  && end_sym === :fixed  && return :fixedfixed
    start_sym === :pinned && end_sym === :fixed  && return :freefixed
    start_sym === :fixed  && end_sym === :pinned && return :fixedfree
    start_sym === :pinned && end_sym === :pinned && return torsion_released ? :joist : :freefree
    error("resolve_release: resolved end symbols must each be :fixed or :pinned, " *
          "got (start = $(start_sym), end = $(end_sym))")
end

"""
    _resolve_beam_end_symbols(beam, chain, material) -> (start_sym, end_sym, torsion_released)

Resolve a beam's outer end fixity symbols (`:fixed`/`:pinned`) and its
whole-member torsion flag, enforcing the chain-interior constraint.

`chain` is the ordered `Vector{Segment}` spanned by `beam` (same order as
`segment_indices(beam)`; the first segment's `release_start` is the member start
node, the last segment's `release_end` is the member end node).

Resolution rules:
- `:default` outer symbols defer to `default_release(role, material, lateral_role)`.
- Interior fixity symbols — every symbol other than the first segment's
  `release_start` and the last segment's `release_end` — must be `:fixed` (or
  `:default`, treated as `:fixed` for moment continuity across a shatter node).
  An explicit interior `:pinned` is an accidental mid-member hinge and errors,
  naming the offending segment.
- `torsion_released === nothing` defers to `default_torsion_released(role, material)`.
"""
function _resolve_beam_end_symbols(beam::Beam, chain::AbstractVector{<:Segment}, material)
    n = length(chain)
    n == 0 && error("resolve_release: beam has an empty segment chain")
    role = getfield(beam, :role)
    lateral_role = getfield(beam, :lateral_role)

    # Validate raw per-end symbols before interpreting them.
    for (i, seg) in enumerate(chain)
        seg.release_start in _RELEASE_SEGMENT_SYMS || error(
            "resolve_release: segment $i (edge $(seg.edge_idx)) has invalid " *
            "release_start = $(seg.release_start); expected one of $(_RELEASE_SEGMENT_SYMS)")
        seg.release_end in _RELEASE_SEGMENT_SYMS || error(
            "resolve_release: segment $i (edge $(seg.edge_idx)) has invalid " *
            "release_end = $(seg.release_end); expected one of $(_RELEASE_SEGMENT_SYMS)")
    end

    # Interior ends must be moment-continuous (:fixed or :default).
    _interior_ok(sym) = sym === :fixed || sym === :default
    _check_interior(sym, seg, which) =
        _interior_ok(sym) || error(
            "resolve_release: interior end (`$(which)`) of segment (edge " *
            "$(seg.edge_idx)) is `$(sym)`; chain-interior segments must be `:fixed` " *
            "(an interior `:pinned` would be an accidental mid-member hinge)")

    if n > 1
        _check_interior(chain[1].release_end, chain[1], :release_end)
        _check_interior(chain[n].release_start, chain[n], :release_start)
        for i in 2:(n - 1)
            _check_interior(chain[i].release_start, chain[i], :release_start)
            _check_interior(chain[i].release_end, chain[i], :release_end)
        end
    end

    raw_start = chain[1].release_start
    raw_end = chain[n].release_end

    # Resolve :default outer ends via the (role, material, lateral_role) dispatch.
    def_start, def_end = default_release(role, material, lateral_role)
    start_sym = raw_start === :default ? def_start : raw_start
    end_sym = raw_end === :default ? def_end : raw_end

    (start_sym in (:fixed, :pinned)) || error(
        "resolve_release: resolved start symbol `$(start_sym)` is not :fixed/:pinned")
    (end_sym in (:fixed, :pinned)) || error(
        "resolve_release: resolved end symbol `$(end_sym)` is not :fixed/:pinned")

    tors_raw = getfield(beam, :torsion_released)
    torsion_released = tors_raw === nothing ? default_torsion_released(role, material) : tors_raw

    return (start_sym, end_sym, torsion_released)
end

"""
    resolve_release(beam, chain, material) -> Symbol

Collapse a beam's per-segment `release_start`/`release_end` symbols and its
`torsion_released` flag to a single Asap element-release enum
(`:fixedfixed`, `:freefixed`, `:fixedfree`, `:freefree`, or `:joist`).

`chain` is the ordered `Vector{Segment}` spanned by `beam` (same order as
`segment_indices(beam)`; first segment's `release_start` is the member start, last
segment's `release_end` is the member end). Interior segments must be
moment-continuous, so an explicit interior `:pinned` errors. `:default` symbols
defer to the `(role, material, lateral_role)` dispatch
(`StructuralSizer.default_release` / `default_torsion_released`). A `nothing`
`material` (no beam material specified) resolves to fully-fixed ends, preserving
the prior all-`:fixedfixed` behavior.

For a shattered (multi-segment) chain this single symbol is the member-level
idealization; the per-element assignment used at Asap model construction is
[`resolve_edge_releases`](@ref).
"""
function resolve_release(beam::Beam, chain::AbstractVector{<:Segment}, material)
    start_sym, end_sym, torsion_released = _resolve_beam_end_symbols(beam, chain, material)
    return _release_enum(start_sym, end_sym, torsion_released)
end

"""
    resolve_edge_releases(beam, chain, material) -> Vector{Symbol}

Per-element release symbols for a beam's chain, in `chain` order (one symbol per
skeleton edge / Asap element). A single-segment chain yields
`[resolve_release(...)]`. For a shattered (multi-segment) chain the member's
resolved start fixity is applied to the first element, the resolved end fixity to
the last element, and every interior element is `:fixedfixed` — so a released
member end never turns an interior shatter node into an accidental mid-member
hinge.

Note: a member-level torsion release (`:joist`) cannot be represented on a
shattered chain (torsion continuity spans shatter nodes); such a member collapses
to `:freefixed`/`:fixedfree` outer elements. No producer currently emits
multi-segment released members (Phase 3/5 concern).
"""
function resolve_edge_releases(beam::Beam, chain::AbstractVector{<:Segment}, material)
    start_sym, end_sym, torsion_released = _resolve_beam_end_symbols(beam, chain, material)
    n = length(chain)
    n == 1 && return [_release_enum(start_sym, end_sym, torsion_released)]
    releases = fill(:fixedfixed, n)
    releases[1] = _release_enum(start_sym, :fixed, torsion_released)
    releases[n] = _release_enum(:fixed, end_sym, torsion_released)
    return releases
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
    # Preserve per-group catalog overrides (Phase 6) across the rebuild.
    # build_member_groups! is re-run on every sizing pass (via
    # member_group_demands), so a catalog_override set by materialize_level!
    # (Phase 5) — keyed on the stable group_id — must survive the
    # empty!/recreate cycle rather than being reset to `nothing`.
    prev_overrides = Dict{UInt64, Any}()
    for (gid, mg) in struc.member_groups
        mg.catalog_override === nothing || (prev_overrides[gid] = mg.catalog_override)
    end
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
            MemberGroup(gid; catalog_override = get(prev_overrides, gid, nothing))
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
`(M1, M2)` convention via `_fem_to_aci_endmoments`. The group's
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
    member_edge_group::Union{Symbol, AbstractVector{Symbol}, Tuple{Vararg{Symbol}}}=:beams,
    resolution::Int=200,
    params::DesignParameters=DesignParameters())
    isempty(struc.asap_model.elements) && throw(ArgumentError("ASAP model is empty. Call `to_asap!(struc)` before sizing."))

    skel = struc.skeleton
    groups = member_edge_group isa Symbol ? (member_edge_group,) : member_edge_group
    beam_edge_ids = Set{Int}()
    for g in groups
        union!(beam_edge_ids, get(skel.groups_edges, g, Int[]))
    end

    member_type = if member_edge_group === :columns || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :columns in member_edge_group)
        :columns
    elseif member_edge_group === :struts || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :struts in member_edge_group)
        :struts
    else
        :beams
    end
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
    member_array = if member_edge_group === :columns || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :columns in member_edge_group)
        struc.columns
    elseif member_edge_group === :struts || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :struts in member_edge_group)
        struc.struts
    else
        struc.beams
    end

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
            set_volumes!(m, MaterialVolumes(
                _volume_key(material) => StructuralSizer.section_area(chosen) * L_total))

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
# Single member-group sizing (Phase 6 catalog-override seam)
# =============================================================================

# First non-`nothing` argument (left-to-right), or `nothing` when all are unset.
# Unlike `something`, it may return `nothing` (so it works for the strength-only
# `deflection_limit = nothing` default), and it short-circuits.
_first_set() = nothing
_first_set(x, rest...) = x === nothing ? _first_set(rest...) : x

"""
    size_member_group!(struc, gid; catalog=StructuralSizer.all_W(),
                        material=StructuralSizer.A992_Steel,
                        member_edge_group=:beams, max_depth=Inf*u"m",
                        resolution=200, reanalyze=true, deflection_limit=nothing,
                        override=nothing)

Size a **single** steel `MemberGroup` (`struc.member_groups[gid]`), honouring both
its per-group `catalog_override` (Phase 6 seam) and an optional per-design
[`MemberGroupSizingOverride`](@ref) passed via `override` (Run 4, Part 1 — obtained
from `params.member_group_overrides` through
[`resolve_member_group_override`](@ref)).

Each sizing input is resolved with `_first_set` (first non-`nothing`), which
establishes a THREE-level precedence, highest first:

```julia
resolved_catalog          = _first_set(override.catalog, group.catalog_override, catalog)
resolved_deflection_limit = _first_set(override.deflection_limit, deflection_limit)
resolved_max_depth        = _first_set(override.max_depth, max_depth)
```

So an `override === nothing` (its default) collapses to exactly the pre-Run-4
resolution — `catalog` falls to `something(group.catalog_override, catalog)`,
`deflection_limit`/`max_depth` to the caller's kwargs — making this call
byte-for-byte identical to before for every existing caller. A populated
`override` field wins over the `MemberGroup` seam and the global default for
*this group only*. The resolved catalog is passed to the per-group AISC selector
(`StructuralSizer.optimize_binary_search`, which is optimal per independent
group), and the winning section is written back to the group, its members, and
the ASAP elements — mirroring [`size_steel_members!`](@ref) for one group.

The model must already be analysed (solved) so `member_group_demands` can
envelope internal forces; this function does not add loads.

!!! note "Phase 5 seam"
    `materialize_level!` (Phase 5, not yet implemented) is expected to set
    `group.catalog_override = level.catalog_override` from the owning
    [`FramingLevel`](@ref) before calling `size_member_group!`, so a joist level
    with a restricted catalog (e.g. a specific set of W-shapes) sizes against
    exactly that catalog. `build_member_groups!` preserves the override across
    its rebuild so it survives the demand-extraction pass.

Returns the sized `MemberGroup`.
"""
function size_member_group!(
    struc::BuildingStructure,
    gid::UInt64;
    catalog = StructuralSizer.all_W(),
    material = StructuralSizer.A992_Steel,
    member_edge_group::Symbol = :beams,
    max_depth = Inf * u"m",
    resolution::Int = 200,
    reanalyze::Bool = true,
    deflection_limit::Union{Nothing, Real} = nothing,
    override::Union{Nothing, MemberGroupSizingOverride} = nothing,
)
    # member_group_demands rebuilds the groups (preserving catalog_override) and
    # envelopes internal forces, so fetch the (possibly recreated) group after.
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution)

    haskey(struc.member_groups, gid) ||
        throw(ArgumentError("no MemberGroup with id $gid in struc.member_groups"))
    group = struc.member_groups[gid]

    g_idx = findfirst(==(gid), group_ids)
    g_idx === nothing && throw(ArgumentError(
        "MemberGroup $gid has no demands in edge group :$member_edge_group"))

    # Override resolution (Run 4, Part 1). Precedence, highest first:
    #   1. the per-design `member_group_overrides[gid]` entry (`override`),
    #   2. `MemberGroup.catalog_override` (catalog only — Phase 6 seam),
    #   3. the caller's global default kwarg.
    # ENGINEERING KNOBS (not published-code factors): catalog / deflection limit /
    # max depth are sizing inputs. A `nothing` override (the default) collapses each
    # to the pre-Run-4 resolution, so this is byte-identical for every existing call.
    ovr_catalog = override === nothing ? nothing : override.catalog
    ovr_defl    = override === nothing ? nothing : override.deflection_limit
    ovr_depth   = override === nothing ? nothing : override.max_depth

    resolved_catalog          = _first_set(ovr_catalog, group.catalog_override, catalog)
    resolved_deflection_limit = _first_set(ovr_defl, deflection_limit)
    resolved_max_depth        = _first_set(ovr_depth, max_depth)

    geometry = StructuralSizer.SteelMemberGeometry(
        L_totals[g_idx]; Lb=Lb_govs[g_idx], Cb=Cb_govs[g_idx],
        Kx=Kx_govs[g_idx], Ky=Ky_govs[g_idx])

    checker = StructuralSizer.AISCChecker(;
        max_depth=resolved_max_depth, deflection_limit=resolved_deflection_limit)

    result = StructuralSizer.optimize_binary_search(
        checker, [demands[g_idx]], [geometry], resolved_catalog, material)

    # Catalog sections usually carry material=nothing; stamp the group's material.
    chosen = copy(result.sections[1])
    chosen.material = material
    group.section = chosen

    member_array = if member_edge_group === :columns || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :columns in member_edge_group)
        struc.columns
    elseif member_edge_group === :struts || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :struts in member_edge_group)
        struc.struts
    else
        struc.beams
    end
    skel = struc.skeleton
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[]))
    asap_sec = StructuralSizer.to_asap_section(chosen, material)

    for m_idx in group.member_indices
        m = member_array[m_idx]
        L_raw = sum(struc.segments[i].L for i in segment_indices(m))
        L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
        set_section!(m, chosen)
        set_volumes!(m, MaterialVolumes(
            _volume_key(material) => StructuralSizer.section_area(chosen) * L_total))
        for seg_idx in segment_indices(m)
            edge_idx = struc.segments[seg_idx].edge_idx
            edge_idx in edge_ids_in_group || continue
            struc.asap_model.elements[edge_idx].section = asap_sec
        end
    end

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    return group
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
4. Reads the beam's max-envelope tributary width (`tributary_width_envelope`) as the clear spacing `sw`
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

            # Tributary width (beam spacing proxy). Collapse the beam's variable
            # tributary profile w(s) to a single representative clear spacing sw
            # via the max envelope w_max = max_s w(s).
            #
            # ENGINEERING JUDGMENT: ACI 318-11 §8.12.2 (interior) / §8.12.3 (edge)
            # (corpus: aci-318-11, PDF p.119) define the effective flange width
            # from the clear web spacing sw but do not prescribe how to collapse a
            # spatially varying tributary to a single sw. `effective_flange_width`
            # caps each overhang at the least of {8·hf (edge 6·hf), sw/2,
            # ln/8 (edge ln/12)}, so the sw term can only *reduce* bf; taking the
            # max spacing is the least-reducing choice and reproduces the prior
            # scalar behavior exactly when the profile is constant. This is NOT a
            # literal code requirement — per-station bf(x) is preferred once the
            # section checks accept a variable width.
            tw = tributary_width_envelope(m)
            if !isnothing(tw)
                tw_m = tw isa Unitful.Quantity ? ustrip(u"m", tw) : Float64(tw)
                trib_w_m = max(trib_w_m, tw_m)
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
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
)
    dp = (hasproperty(struc, :design_parameters) && !isnothing(struc.design_parameters)) ?
         struc.design_parameters : nothing

    # Universal size-time gate backstop (Phase B fix cycle 4): when NO explicit
    # `member_group_overrides` kwarg is threaded, default it from the structure's
    # design parameters so any struc-only caller (`size_members!`, or a bare
    # `size_beams!(struc, ...)`) still reaches the honor-or-throw gid gate in
    # `_size_beams_impl!` rather than silently dropping an effective override. An
    # explicit non-`nothing` kwarg ALWAYS wins, so the `design_building` /
    # `redesign_incremental!` path (which threads `params.member_group_overrides`
    # explicitly) is UNCHANGED and byte-identical. `dp === nothing` / a missing /
    # `nothing` / empty field stays `nothing` → strict no-op. NOTE: as of this writing
    # `BuildingStructure` has NO `design_parameters` field (see
    # building_types/structure.jl) and it is never assigned in the SS source, so `dp`
    # is `nothing` here and this default is an inert backstop; the authoritative
    # universal coverage is the explicit thread at core/size.jl's `size!`.
    # (Engineering sizing knobs — no code citation.)
    if member_group_overrides === nothing && dp !== nothing &&
       hasproperty(dp, :member_group_overrides) &&
       !isnothing(dp.member_group_overrides) && !isempty(dp.member_group_overrides)
        member_group_overrides = dp.member_group_overrides
    end

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
                               resolution, reanalyze, gravity_factor,
                               member_group_overrides)
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
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
)
    skel = struc.skeleton
    edge_ids_in_group = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(edge_ids_in_group, get(skel.groups_edges, g, Int[]))
    end
    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=BEAM_GROUP_SYMBOLS, resolution=resolution)

    # DEFINITIVE size-time gid gate (Run 4 / Phase B, [P1-2] + [P2-3]). `group_ids`
    # here is the REAL steel-beam group set the sizer actually emits: collinear-MERGED
    # (`group_collinear_members!` ran in `size_beams!` before this call) AND
    # par_has-FILTERED (`member_group_demands` drops groups with no segment on a
    # :beams edge). Every EFFECTIVE `member_group_overrides` entry MUST target one of
    # these gids — anything else can never be honored on this path and would be
    # SILENTLY DROPPED, so we refuse fail-loud (pinned `member_group_overrides`
    # ArgumentError) BEFORE any BuildingDesign is produced. Runs BEFORE the empty-group
    # early return so an override under a floor that emits NO steel beam group (every
    # beam par_has-absent) is refused too, never silently dropped. This single gate:
    #   [P1-2] a collinear beam gid IS in `group_ids` → HONORED (no unreliable
    #          door-side reproduction of collinear grouping is needed);
    #   [P2-3] a par_has-absent beam gid is NOT in `group_ids` → REFUSED (no silent drop);
    #   a column / strut gid, or any unknown / garbage gid, is NOT in `group_ids` → REFUSED.
    # Fires on ALL BuildingDesign-producing paths that size beams (from-scratch
    # `design_building` and incremental `redesign_incremental!` both route
    # `_size_beams_columns!` → `size_beams!` → here). (Engineering-scope guard —
    # catalog / deflection_limit / max_depth are sizing knobs, no code citation.)
    if member_group_overrides !== nothing
        honorable_beam_gids = Set(group_ids)
        for (gid, ovr) in member_group_overrides
            _is_effective(ovr) || continue
            gid in honorable_beam_gids || throw(ArgumentError(_mgo_refusal_message(
                "override targets member group $(gid), which is NOT among the " *
                "$(length(honorable_beam_gids)) steel beam groups the batched " *
                "size_beams! path emits at size time (collinear-merged and " *
                "par_has-filtered); a column / strut group, an unknown gid, or a beam " *
                "group with no segment on a :beams edge is not sized per-group here and " *
                "would be silently dropped")))
        end

        # Phase B is STEEL-beam-only: a bare-steel Ix mask must never be applied to a
        # COMPOSITE beam demand (whose code check uses I_LB, AISC 360-16 Commentary
        # I3.2). Refuse fail-loud rather than over-restrict.
        #
        # [composite cleanup, fix cycle 3] DEFENSE-IN-DEPTH ONLY: the composite-refusal
        # branch inside `_assert_no_composite_override` is CURRENTLY UNREACHABLE on this
        # batched path — `member_group_demands` builds `MemberDemand{Float64, Nothing}`,
        # so every `demands[i].composite` is `nothing` by construction and the assertion
        # never throws here. It is retained (not deleted) as an explicit backstop against
        # a future batched demand-builder that surfaces composite demands, and is covered
        # by a DIRECT unit test on synthetic composite stubs (test (ix)) rather than
        # through this call site. Do NOT read this as live coverage of a composite path.
        _assert_no_composite_override(group_ids, demands, member_group_overrides)
    end

    isempty(group_ids) && return struc

    geometries = [StructuralSizer.SteelMemberGeometry(L; Lb=Lb, Cb=Cb, Kx=Kx, Ky=Ky)
                  for (L, Lb, Cb, Kx, Ky) in zip(L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)]

    Mu_vec = [d.Mux for d in demands]
    Vu_vec = [d.Vu_strong for d in demands]
    δ_LL_vec   = [d.δ_max_LL for d in demands]
    δ_total_vec = [d.δ_max_total for d in demands]
    I_ref_v  = [d.I_ref for d in demands]

    # Run 4 / Phase B ([A-revert]): honor per-group restrictions on STEEL beam
    # groups sourced ONLY from an EFFECTIVE per-design `member_group_overrides`
    # entry. The single batched size_beams call is routed through a UNION catalog +
    # per-group `feasible` index mask (see `_beam_override_union_and_feasible`).
    # `MemberGroup.catalog_override` (the Phase 6 seam) is a documented NO-OP on this
    # batched design_building / incremental path — it is honored only by the isolated
    # `size_member_group!` path (it was never honored here pre-Phase-B, and honoring
    # it opened a regression). Every group with no effective override keeps the full
    # default catalog and the identical internal AISCChecker screening, so its result
    # is byte-identical. With no effective override on any group we take the
    # pre-Phase-B path verbatim (feasible === nothing).
    has_eff_override =
        member_group_overrides !== nothing &&
        any(gid -> (o = get(member_group_overrides, gid, nothing)) !== nothing &&
                   _is_effective(o), group_ids)

    result = if has_eff_override
        union_cat, feasible = _beam_override_union_and_feasible(
            struc, opts, group_ids, L_totals, δ_LL_vec, I_ref_v, member_group_overrides)
        StructuralSizer.size_beams(
            Mu_vec, Vu_vec, geometries, opts;
            δ_max_vec = any(>(0), δ_LL_vec)   ? δ_LL_vec   : nothing,
            δ_max_total_vec = any(>(0), δ_total_vec) ? δ_total_vec : nothing,
            I_ref_vec = any(>(0), I_ref_v)    ? I_ref_v    : nothing,
            catalog = union_cat,
            feasible = feasible,
        )
    else
        StructuralSizer.size_beams(
            Mu_vec, Vu_vec, geometries, opts;
            δ_max_vec = any(>(0), δ_LL_vec)   ? δ_LL_vec   : nothing,
            δ_max_total_vec = any(>(0), δ_total_vec) ? δ_total_vec : nothing,
            I_ref_vec = any(>(0), I_ref_v)    ? I_ref_v    : nothing,
        )
    end

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

# --- Per-group override narrowing for the batched steel-beam path (Run 4 / Phase B) ---
#
# Stable identity key for a catalog section (W-shapes carry a unique `name`).
_beam_sec_key(s) = (nameof(typeof(s)),
                    (hasproperty(s, :name) && getfield(s, :name) !== nothing) ?
                        getfield(s, :name) : objectid(s))

# [P2 section-identity, fix cycle 4] Structural (value-level) equality of two catalog
# section FIELDS. `_beam_sec_key` keys identity on `(typename, name)` only, so two
# sections that share a name but differ in PROPERTIES (e.g. a hand-modified
# ISymmSection named "W14X22" with a reduced Ix) collide. Section types (e.g.
# `ISymmSection`) are MUTABLE structs, so Julia's default `==`/`===` is identity-based,
# not value-based — hence a recursive field-by-field comparison. A field is identical
# when it is the SAME object (`===`), value-equal under `isequal` (so a `missing` field
# matches `missing`, and unit-aware Unitful quantities match — cycle-3's bare `==`
# wrongly refused a `missing` field because `missing == missing === missing`, not
# `true`), OR — for a distinct-but-value-equal composite field that defines no `==`
# (e.g. a freshly built `material` object rather than the shared singleton) — equal by
# recursing into its own fields. This keeps genuinely value-equal sections deduping
# byte-identically while a genuinely DIFFERING field (e.g. a reduced Ix, or a differing
# material property) still resolves to "not identical" so the caller refuses rather than
# silently substitutes. (Engineering-scope guard — no code citation.)
function _field_identical(x, y)
    x === y && return true
    isequal(x, y) === true && return true
    # Distinct objects with no value `==`/`isequal`: fall back to structural equality
    # (same concrete type, matching field-by-field). A leaf value that is neither `===`,
    # `isequal`, nor a comparable struct is treated as differing.
    typeof(x) === typeof(y) || return false
    (isstructtype(typeof(x)) && !isempty(fieldnames(typeof(x)))) || return false
    for f in fieldnames(typeof(x))
        _field_identical(getfield(x, f), getfield(y, f)) || return false
    end
    return true
end

function _sections_identical(a, b)
    a === b && return true
    typeof(a) === typeof(b) || return false
    for f in fieldnames(typeof(a))
        _field_identical(getfield(a, f), getfield(b, f)) || return false
    end
    return true
end

"""
    _assert_no_composite_override(group_ids, demands, member_group_overrides)

Refuse fail-loud (pinned `member_group_overrides` `ArgumentError`) if any group
carrying an EFFECTIVE per-design override has a COMPOSITE beam demand
(`demand.composite !== nothing`).

Phase B is STEEL-beam-only. The batched feasible mask
([`_beam_override_union_and_feasible`](@ref)) gates deflection on the bare-steel
`Ix`, whereas the composite code check uses the lower-bound composite inertia
`I_LB` (AISC 360-16 Commentary I3.2; `is_feasible` composite overload in
`members/codes/aisc/checker.jl`, `I_LB > Ix`). Applying the bare-`Ix` mask to a
composite group would OVER-restrict it, so we refuse rather than size it against
the wrong stiffness. In the batched path `member_group_demands` builds
`MemberDemand{Float64, Nothing}` (composite always `nothing`), so this is a
defense-in-depth assertion for that path; it is testable directly on synthetic
composite demands. (Engineering-scope guard — the cited mechanics is only that
`I_LB > Ix` for composite sections.)
"""
function _assert_no_composite_override(
    group_ids::Vector{UInt64},
    demands,
    member_group_overrides::Dict{UInt64, MemberGroupSizingOverride},
)
    for (i, gid) in enumerate(group_ids)
        ovr = get(member_group_overrides, gid, nothing)
        (ovr !== nothing && _is_effective(ovr)) || continue
        demands[i].composite === nothing || throw(ArgumentError(_mgo_refusal_message(
            "override on beam group $(gid) targets a COMPOSITE beam demand; the " *
            "batched size_beams! mask gates deflection on bare-steel Ix while the " *
            "composite code check uses I_LB (AISC 360-16 Commentary I3.2), so Phase B " *
            "refuses composite-beam overrides rather than over-restrict the group")))
    end
    return nothing
end

"""
    _beam_override_union_and_feasible(struc, opts, group_ids, L_totals,
                                      δ_LL_vec, I_ref_v, member_group_overrides)
        -> (union_cat, feasible)

Build a UNION catalog (default ∪ every group's override catalog) and a per-group
`feasible` index mask (indices into `union_cat`) so that ONE batched
`StructuralSizer.size_beams` call can honor per-group `member_group_overrides` on
steel beam groups while leaving every other group byte-identical.

The mask is INTERSECTED with `size_beams -> optimize_discrete`'s internal capacity
screening (which always still runs `AISCChecker` on the global `opts`), so it can
only ever NARROW a group's candidate set — never admit an unchecked section. An
override therefore *tightens* a group relative to the global default; a knob set
LOOSER than the global default is clamped by the global screening (conservative /
safe by construction).

Per-knob precedence on this batched path ([A-revert] — the `MemberGroup.catalog_override`
seam is NOT consulted here; it is honored only by `size_member_group!`):
- `catalog`         : `override.catalog` > default
- `max_depth`       : `override.max_depth` > `opts.max_depth`
- `deflection_limit`: `override.deflection_limit` > `opts.deflection_limit`

Groups with NO effective override get the full default catalog and NO external
depth/deflection filter — the internal global `AISCChecker` governs them exactly
as before (byte-identical). `total_deflection_limit` is not an override field, so
the global `opts.total_deflection_limit` continues to apply to every group.
"""
function _beam_override_union_and_feasible(
    struc::BuildingStructure,
    opts::StructuralSizer.SteelBeamOptions,
    group_ids::Vector{UInt64},
    L_totals::Vector,
    δ_LL_vec::Vector,
    I_ref_v::Vector,
    member_group_overrides::Dict{UInt64, MemberGroupSizingOverride},
)
    # Default catalog — mirror the exact precedence used inside
    # StructuralSizer.size_columns (custom_catalog > material-default).
    default_cat = opts.custom_catalog === nothing ?
        StructuralSizer.steel_column_catalog(opts.section_type, opts.catalog) :
        opts.custom_catalog

    # Union catalog: default sections FIRST (original order preserved so non-override
    # groups' feasible index order is unchanged), override-only extras appended.
    union_cat = collect(default_cat)
    key2idx = Dict{Any, Int}()
    for (j, s) in enumerate(union_cat)
        get!(key2idx, _beam_sec_key(s), j)
    end
    n_default = length(union_cat)

    resolved_cats = Vector{Any}(undef, length(group_ids))
    for (i, gid) in enumerate(group_ids)
        ovr = get(member_group_overrides, gid, nothing)
        eff = ovr !== nothing && _is_effective(ovr)
        # [A-revert]: the batched path honors ONLY the per-design override.
        # `MemberGroup.catalog_override` is a documented no-op here (honored solely
        # by `size_member_group!`), so a group with no EFFECTIVE override keeps the
        # full default catalog → byte-identical to pre-Phase-B.
        if !eff
            resolved_cats[i] = nothing          # no effective override → default catalog membership
            continue
        end
        # Catalog precedence on this batched path: override.catalog > default.
        rc = _first_set(ovr.catalog, default_cat)
        resolved_cats[i] = rc
        for s in rc
            k = _beam_sec_key(s)
            existing = get(key2idx, k, nothing)
            if existing === nothing
                push!(union_cat, s)
                key2idx[k] = length(union_cat)
            elseif !_sections_identical(s, union_cat[existing])
                # [P2 section-identity, fix cycle 3] An override-catalog section whose
                # `(typename, name)` key COLLIDES an existing union section (a default or
                # a previously-added override) but whose PROPERTIES DIFFER would be
                # silently mapped onto the existing section's index by the `key2idx`
                # dedup below — substituting a DIFFERENT section (e.g. a hand-modified
                # "W14X22" with a reduced Ix) for the one the user supplied, then sizing
                # / reporting against the wrong stiffness. Refuse fail-loud (pinned
                # `member_group_overrides` ArgumentError) rather than size against the
                # wrong section. Genuinely IDENTICAL sections still dedup byte-identically
                # (the `steel_column_catalog` sections and `W(name)` share the cached
                # `W_CATALOG` singletons, so `_sections_identical` short-circuits `===`).
                # (Engineering-scope guard — no code citation.)
                nm = (hasproperty(s, :name) && getfield(s, :name) !== nothing) ?
                        getfield(s, :name) : "<unnamed>"
                throw(ArgumentError(_mgo_refusal_message(
                    "override on beam group $(gid) supplies a $(nameof(typeof(s))) named " *
                    "\"$(nm)\" whose (type, name) identity collides a DIFFERENT section " *
                    "already in the batched catalog but with differing properties; the " *
                    "section-identity dedup keys on (type, name) only and would silently " *
                    "substitute the existing section, so Phase B refuses the ambiguous " *
                    "override rather than size against the wrong section")))
            end
        end
    end

    default_idxs = collect(1:n_default)
    feasible = Vector{Vector{Int}}(undef, length(group_ids))
    for (i, gid) in enumerate(group_ids)
        rc = resolved_cats[i]
        if rc === nothing
            feasible[i] = copy(default_idxs)    # internal global checker governs → byte-identical
            continue
        end
        # rc !== nothing ⇒ this group carried an EFFECTIVE override (first loop), so
        # its entry is present; depth/deflection knobs fall through to the global
        # `opts` when the override leaves them unset ([A-revert]).
        ovr = member_group_overrides[gid]
        resolved_depth = _first_set(ovr.max_depth, opts.max_depth)
        resolved_defl  = _first_set(ovr.deflection_limit, opts.deflection_limit)
        δ_LL  = δ_LL_vec[i]
        I_ref = I_ref_v[i]
        L_m   = L_totals[i] isa Unitful.Quantity ? ustrip(u"m", L_totals[i]) : Float64(L_totals[i])
        idxs = Int[]
        for s in rc
            # Depth narrowing — identical `section_depth(s) <= max_depth` gate the
            # AISCChecker applies (StructuralSizer src/members/codes/aisc/checker.jl).
            StructuralSizer.section_depth(s) <= resolved_depth || continue
            # LL-deflection narrowing — identical formula to AISCChecker.is_feasible
            # (aisc/checker.jl): δ_scaled = δ_max_LL * I_ref / Ix; ratio = δ_scaled / L.
            if resolved_defl !== nothing && I_ref > 0 && δ_LL > 0
                Ix_m4 = ustrip(u"m^4", StructuralSizer.Ix(s))
                (δ_LL * I_ref / Ix_m4) / L_m <= resolved_defl || continue
            end
            push!(idxs, key2idx[_beam_sec_key(s)])
        end
        feasible[i] = sort!(unique!(idxs))
    end

    return union_cat, feasible
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
        vol_key = _volume_key(group_mat)

        mg = struc.member_groups[gid]
        mg.section = chosen

        asap_sec = StructuralSizer.to_asap_section(chosen, group_mat)

        for m_idx in mg.member_indices
            m = member_array[m_idx]

            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_volumes!(m, MaterialVolumes(
                vol_key => StructuralSizer.section_area(chosen) * L_total))

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
    # Accepted for a uniform `size_beams!` dispatch but NOT honored here: per-group
    # member_group_overrides are only threaded into the STEEL discrete path this
    # increment. `_assert_member_group_overrides_unsupported` refuses any EFFECTIVE
    # override that would reach non-steel-beam sizing, so this is always nothing/vacuous.
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
)
    skel = struc.skeleton
    edge_ids_in_group = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(edge_ids_in_group, get(skel.groups_edges, g, Int[]))
    end

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Extract demands from analysis (MemberDemand in SI: N, N·m, m)
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=BEAM_GROUP_SYMBOLS, resolution=resolution)

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
    # Accepted for uniform `size_beams!` dispatch, NOT honored here (non-steel path;
    # the guard refuses effective overrides that would reach it — always nothing/vacuous).
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
)
    skel = struc.skeleton
    edge_ids_in_group = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(edge_ids_in_group, get(skel.groups_edges, g, Int[]))
    end

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Extract demands from analysis (MemberDemand in SI: N, N·m, m)
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=BEAM_GROUP_SYMBOLS, resolution=resolution)

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
                    set_volumes!(m, MaterialVolumes(_volume_key(mat) => StructuralSizer.section_area(chosen) * L_total))
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
                    set_volumes!(m, MaterialVolumes(_volume_key(mat) => StructuralSizer.section_area(chosen) * L_total))
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
            set_volumes!(m, MaterialVolumes(_volume_key(mat) => StructuralSizer.section_area(chosen) * L_total))

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
    # Accepted for uniform `size_beams!` dispatch, NOT honored here (non-steel path;
    # the guard refuses effective overrides that would reach it — always nothing/vacuous).
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
)
    skel = struc.skeleton
    edge_ids_in_group = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(edge_ids_in_group, get(skel.groups_edges, g, Int[]))
    end

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Extract demands from analysis (MemberDemand in SI: N, N·m, m)
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=BEAM_GROUP_SYMBOLS, resolution=resolution)

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
            set_volumes!(m, MaterialVolumes(
                _volume_key(group_mat) => StructuralSizer.section_area(chosen) * L_total))
            
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
