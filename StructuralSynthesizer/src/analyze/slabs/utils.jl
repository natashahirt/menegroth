# Cell and Slab initialization from skeleton faces

# =============================================================================
# Geometry Helpers
# =============================================================================

"""
    get_cell_spans(skel, face_idx; axis=nothing) -> SpanInfo{T}

Compute SpanInfo for a skeleton face.

## Arguments
- `skel`: BuildingSkeleton
- `face_idx`: Face index
- `axis`: Optional primary span direction as `(x, y)` tuple. If `nothing`, auto-detects short axis.

## Returns
- `SpanInfo{T}`: Span info with values in skeleton's length type (with units)
"""
function get_cell_spans(skel::BuildingSkeleton{T}, face_idx::Int; 
                        axis::Union{Nothing, NTuple{2,Float64}}=nothing) where T
    verts = [skel.vertices[i] for i in skel.face_vertex_indices[face_idx]]
    
    # Compute SpanInfo (returns Float64 in meters)
    si = StructuralSizer.SpanInfo(verts; axis=axis)
    
    # Convert to Quantity with meter units
    StructuralSizer.SpanInfo{T}(
        si.primary * u"m",
        si.secondary * u"m",
        si.axis,
        si.isotropic * u"m"
    )
end

"""
    classify_cell_position(skel, face_idx) -> Symbol

Classify cell position based on how many boundary edges it has.
- 2+ boundary edges → :corner
- 1 boundary edge → :edge
- 0 boundary edges → :interior

A boundary edge is one that belongs to only one face (building perimeter).
Reads from the geometry cache (`skel.geometry.edge_face_counts`).
"""
function classify_cell_position(skel::BuildingSkeleton, face_idx::Int)
    efc = skel.geometry.edge_face_counts
    face_edges = skel.face_edge_indices[face_idx]
    boundary_count = count(e -> get(efc, e, 0) == 1, face_edges)
    return boundary_count >= 2 ? :corner : boundary_count == 1 ? :edge : :interior
end

"""
    initialize_cells!(struc; loads=GravityLoads())

Initialize cells from skeleton faces with service-level SDL and LL.

Loads are taken from the `GravityLoads` struct.  In the `design_building`
pipeline, `params.loads` is passed here automatically.

See also: [`GravityLoads`](@ref), [`initialize!`](@ref)
"""
function initialize_cells!(struc::BuildingStructure{T, A, P};
                           loads::GravityLoads = GravityLoads()) where {T, A, P}
    skel = struc.skeleton
    empty!(struc.cells)
    
    lmap = load_map(loads)   # [:grade => (LL, SDL), :floor => ..., :roof => ...]
    
    processed_faces = Set{Int}()
    
    for (grp_name, (ll, sdl)) in lmap
        face_indices = get(skel.groups_faces, grp_name, Int[])
        
        for face_idx in face_indices
            face_idx in processed_faces && continue
            push!(processed_faces, face_idx)
            
            area_raw = face_area(skel, face_idx)
            area = convert(A, area_raw)   # ensure area matches BuildingStructure type A
            spans = get_cell_spans(skel, face_idx)
            position = classify_cell_position(skel, face_idx)
            
            # Ensure loads match the pressure type P of the BuildingStructure
            sdl_p = convert(P, sdl)
            ll_p = convert(P, ll)
            cell = Cell(face_idx, area, spans, sdl_p, ll_p; position=position)
            # Set floor_type for grade cells (they don't need slab design)
            if grp_name == :grade
                cell.floor_type = :grade
            end
            push!(struc.cells, cell)
        end
    end
    
    n_corner = count(c.position == :corner for c in struc.cells)
    n_edge = count(c.position == :edge for c in struc.cells)
    n_interior = count(c.position == :interior for c in struc.cells)
    @debug "Initialized $(length(struc.cells)) cells" corner=n_corner edge=n_edge interior=n_interior
end

"""
    initialize_slabs!(struc; material, floor_type, floor_opts, tributary_axis, cell_groupings, slab_group_ids)

Initialize slabs from cells.

# Cell Grouping Options

`cell_groupings` controls how cells are combined into physical slabs:

- `:auto` (default): Use the grouping mode from floor type options (e.g., `FlatPlateOptions.grouping`)
- `:individual`: One slab per cell (traditional behavior)
- `:by_floor`: Group all cells on each floor into a single continuous slab
- `:building_wide`: Group all cells into one slab (for PT post-tensioned systems)
- `Vector{Vector{Int}}`: Explicit cell index groupings

# Examples

```julia
# Use default from FlatPlateOptions (grouping = :by_floor)
initialize!(struc; floor_type = :flat_plate)

# Override to individual slabs per cell
initialize!(struc; floor_type = :flat_plate, cell_groupings = :individual)

# Explicit groupings
initialize!(struc; cell_groupings = [[1,2,3], [4,5,6]])
```

# Notes
- `Cell` stores **service** `sdl`/`live_load`. Slab sizing computes service self-weight.
- The `span` passed to sizing depends on floor type; see `_sizing_span`.
"""
function initialize_slabs!(struc::BuildingStructure{T};
                           material::AbstractMaterial=NWC_4000,
                           floor_type::Symbol=:auto,
                           floor_opts::StructuralSizer.AbstractFloorOptions=StructuralSizer.FlatPlateOptions(),
                           tributary_axis=nothing,
                           cell_groupings::Union{Symbol, Vector{Vector{Int}}}=:auto,
                           slab_group_ids::Union{Nothing, AbstractVector}=nothing) where T
    empty!(struc.slabs)
    empty!(struc.slab_parallel_batches)
    
    # Clear stale cell groups and tributary cache
    empty!(struc.cell_groups)
    clear_geometry_caches!(struc)
    
    # Resolve cell_groupings to actual indices
    resolved_groupings = _resolve_cell_groupings(struc, cell_groupings, floor_type, floor_opts)
    
    # 1. Build per-slab "specs"
    slab_specs = _build_slab_specs(struc, floor_type, resolved_groupings, slab_group_ids)

    # 2. Assign fallback deterministic group IDs
    _assign_deterministic_group_ids!(slab_specs)

    # 3. Group specs by ID
    groups = _group_slab_specs(slab_specs)

    # 4. Size once per slab group
    group_results, group_sw, group_spans = _size_slab_groups(groups, slab_specs, struc, material, floor_opts)

    # 5. Fan out results to cells and create Slab objects (with volumes)
    _apply_slab_results!(struc, slab_specs, group_results, group_sw, group_spans, material, floor_opts)

    # 6. Finalize grouping structure
    build_slab_groups!(struc)

    # 7. Compute tributary areas
    compute_cell_tributaries!(struc; floor_opts=floor_opts, tributary_axis=tributary_axis)

    @debug "Initialized $(length(struc.slabs)) slabs from $(length(struc.cells)) cells"
end

# =============================================================================
# Initialization Helpers
# =============================================================================

"""Build per-slab specification tuples from cells and grouping options."""
function _build_slab_specs(struc, floor_type, cell_groupings, slab_group_ids)
    slab_specs = NamedTuple[]

    if isnothing(cell_groupings)
        # Default: 1 slab per cell
        for (cell_idx, cell) in enumerate(struc.cells)
            # Skip grade cells (ground floor doesn't need slab design)
            cell.floor_type == :grade && continue
            
            spans = cell.spans
            
            # Use primary/secondary for floor type inference
            ft_sym = floor_type == :auto ? infer_floor_type(spans.primary, spans.secondary) : floor_type
            gid = _resolve_slab_group_id(slab_group_ids, cell_idx; tag=:cell)

            push!(slab_specs, (; cell_indices=[cell_idx],
                              spans_gov=spans,
                              sdl_gov=cell.sdl, live_gov=cell.live_load,
                              floor_type=ft_sym, group_id=gid))
        end
    else
        # Explicit groupings: combine cells into physical slabs (PT, etc.)
        for cell_indices in cell_groupings
            # Filter out grade cells from groupings
            filtered_indices = filter(i -> struc.cells[i].floor_type != :grade, cell_indices)
            isempty(filtered_indices) && continue  # Skip if all cells are grade
            
            cells = [struc.cells[i] for i in filtered_indices]

            # Compute governing spans across all cells in this slab
            cell_spans = [c.spans for c in cells]
            spans_gov = StructuralSizer.governing_spans(cell_spans)
            
            sdl_gov = maximum(c.sdl for c in cells)
            live_gov = maximum(c.live_load for c in cells)

            # For grouped slabs, default to :pt_banded unless specified
            ft_sym = floor_type == :auto ? :pt_banded : floor_type

            # Group id: must be consistent across all cells participating in this physical slab
            gid = _resolve_group_id_for_cell_set(slab_group_ids, filtered_indices)

            push!(slab_specs, (; cell_indices=filtered_indices,
                              spans_gov=spans_gov,
                              sdl_gov=sdl_gov, live_gov=live_gov,
                              floor_type=ft_sym, group_id=gid))
        end
    end
    return slab_specs
end

"""
    _resolve_cell_groupings(struc, groupings, floor_type, opts) -> Union{Nothing, Vector{Vector{Int}}}

Resolve cell_groupings parameter to actual cell index vectors.

- `:auto` → Use floor type options to determine grouping mode
- `:individual` → `nothing` (default: 1 slab per cell)
- `:by_floor` → Group all cells on each floor
- `:building_wide` → All cells in one slab
- `Vector{Vector{Int}}` → Pass through as-is
"""
function _resolve_cell_groupings(struc::BuildingStructure, groupings::Symbol, 
                                  floor_type::Symbol, opts::StructuralSizer.AbstractFloorOptions)
    mode = if groupings == :auto
        _get_grouping_mode(floor_type, opts)
    else
        groupings
    end
    
    @debug "Resolving cell groupings" input=groupings floor_type resolved_mode=mode
    
    if mode == :individual
        return nothing
    elseif mode == :by_floor
        result = _group_cells_by_floor(struc)
        @debug "Auto-grouped cells by floor" n_groups=length(result) cells_per_group=[length(g) for g in result]
        return result
    elseif mode == :building_wide
        all_cells = [i for (i, c) in enumerate(struc.cells) if c.floor_type != :grade]
        @debug "Building-wide grouping" n_cells=length(all_cells)
        return [all_cells]
    else
        error("Unknown cell_groupings mode: $mode. Use :auto, :individual, :by_floor, :building_wide, or explicit Vector{Vector{Int}}.")
    end
end

"""Pass-through: explicit cell index groupings require no resolution."""
function _resolve_cell_groupings(struc::BuildingStructure, groupings::Vector{Vector{Int}}, 
                                  floor_type::Symbol, ::StructuralSizer.AbstractFloorOptions)
    return groupings
end

"""
    _get_grouping_mode(floor_type, opts) -> Symbol

Get the default slab grouping mode from floor type options.
"""
function _get_grouping_mode(floor_type::Symbol, opts::StructuralSizer.AbstractFloorOptions)
    if floor_type in (:flat_plate, :flat_slab)
        fp = opts isa StructuralSizer.FlatSlabOptions ? opts.base : opts
        return hasproperty(fp, :grouping) ? fp.grouping : :individual
    elseif floor_type == :pt_banded
        return :by_floor
    else
        return :individual
    end
end

"""
    _group_cells_by_floor(struc) -> Vector{Vector{Int}}

Group cells by their floor/story level for continuous slab design.
Returns a vector of cell index vectors, one per floor.
Skips grade cells (ground level).
"""
function _group_cells_by_floor(struc::BuildingStructure)
    skel = struc.skeleton
    
    # Build reverse lookup: face_idx → story_idx
    face_to_story = Dict{Int, Int}()
    for (story_idx, story) in skel.stories
        for face_idx in story.faces
            face_to_story[face_idx] = story_idx
        end
    end
    
    # Group cells by story
    story_cells = Dict{Int, Vector{Int}}()
    
    for (cell_idx, cell) in enumerate(struc.cells)
        # Skip grade cells
        cell.floor_type == :grade && continue
        
        story_idx = get(face_to_story, cell.face_idx, -1)
        if story_idx >= 0
            push!(get!(story_cells, story_idx, Int[]), cell_idx)
        else
            @warn "Cell not mapped to story during :by_floor grouping" cell_idx face_idx=cell.face_idx maxlog=5
        end
    end
    
    # Convert to vector of vectors (sorted by story for determinism)
    return [story_cells[k] for k in sort!(collect(keys(story_cells)))]
end

"""Assign hash-based group IDs to any slab specs that have `group_id === nothing`."""
function _assign_deterministic_group_ids!(slab_specs)
    for (i, spec) in enumerate(slab_specs)
        if spec.group_id === nothing
            # Create a new named tuple with the assigned group_id
            # Note: slab_specs is a Vector{NamedTuple}, so we replace the entry
            slab_specs[i] = merge(spec, (; group_id=UInt64(hash((:singleton_slab_group, i)))))
        end
    end
end

"""Group slab spec indices by their `group_id` hash."""
function _group_slab_specs(slab_specs)
    groups = Dict{UInt64, Vector{Int}}()
    for (i, spec) in enumerate(slab_specs)
        push!(get!(groups, spec.group_id, Int[]), i)
    end
    return groups
end

"""Size all slab groups in parallel and return result/self-weight/span dictionaries."""
function _size_slab_groups(groups, slab_specs, struc, material, floor_opts::StructuralSizer.AbstractFloorOptions)
    gids = collect(keys(groups))
    n = length(gids)
    
    results_vec  = Vector{AbstractFloorResult}(undef, n)
    sw_vec       = Vector{typeof(0.0u"kPa")}(undef, n)
    spans_vec    = Vector{SpanInfo}(undef, n)
    
    @inbounds Threads.@threads for k in 1:n
        gid = gids[k]
        spec_idxs = groups[gid]
        specs = slab_specs[spec_idxs]
        result, sw_service, spans_gov = _process_single_slab_group(gid, specs, struc, material, floor_opts)
        
        results_vec[k] = result
        sw_vec[k]      = sw_service
        spans_vec[k]   = spans_gov
    end
    
    group_results = Dict{UInt64, AbstractFloorResult}(gids[k] => results_vec[k] for k in 1:n)
    group_sw      = Dict{UInt64, typeof(0.0u"kPa")}(gids[k] => sw_vec[k] for k in 1:n)
    group_spans   = Dict{UInt64, SpanInfo}(gids[k] => spans_vec[k] for k in 1:n)

    return group_results, group_sw, group_spans
end

"""Size a single slab group: resolve governing demands, call the backend, return `(result, self_weight, spans)`."""
function _process_single_slab_group(gid, specs, struc, material, floor_opts::StructuralSizer.AbstractFloorOptions)
    ft_syms = unique(getfield.(specs, :floor_type))
    length(ft_syms) == 1 || throw(ArgumentError("Slab group $gid has mixed floor types: $(ft_syms)."))

    ft_sym = only(ft_syms)
    ft = StructuralSizer.floor_type(ft_sym)

    if ft isa Vault
        for s in specs
            length(s.cell_indices) == 1 || throw(ArgumentError("Vault slabs must be a single rectangular face; got a slab with $(length(s.cell_indices)) cells in group $gid."))
            cell = struc.cells[only(s.cell_indices)]
            _assert_rectangular_slab_face(struc, cell.face_idx)
        end
    end

    all_spans = [s.spans_gov for s in specs]
    spans_gov = StructuralSizer.governing_spans(all_spans)
    
    sdl_gov = maximum(getfield.(specs, :sdl_gov))
    live_gov = maximum(getfield.(specs, :live_gov))

    span_for_sizing = _sizing_span(ft, spans_gov)

    extra_kwargs = if ft isa Vault && !(floor_opts isa StructuralSizer.VaultOptions)
        (lambda=10.0,)
    else
        NamedTuple()
    end
    result = StructuralSizer._size_span_floor(ft, span_for_sizing, sdl_gov, live_gov;
                                               material=material, options=floor_opts, extra_kwargs...)
    sw_service = StructuralSizer.self_weight(result)

    return result, sw_service, spans_gov
end

"""Write group results back into `struc.slabs` and update cell self-weights."""
function _apply_slab_results!(struc, slab_specs, group_results, group_sw, group_spans, 
                              primary_material, opts::StructuralSizer.AbstractFloorOptions)
    for spec in slab_specs
        gid = spec.group_id
        result = group_results[gid]
        sw_service = group_sw[gid]
        spans_gov = group_spans[gid]

        # Propagate structural data to cells
        for c_idx in spec.cell_indices
            cell = struc.cells[c_idx]
            cell.self_weight = sw_service
            cell.floor_type = spec.floor_type
        end

        # Derive slab position from its cells (most exterior wins)
        slab_position = _derive_slab_position(struc, spec.cell_indices)

        # Compute floor area and material volumes
        floor_area = sum(struc.cells[i].area for i in spec.cell_indices)
        volumes = _compute_slab_volumes(result, floor_area, primary_material, opts)

        slab = Slab(spec.cell_indices, result, spans_gov; 
                    floor_type=spec.floor_type, position=slab_position, 
                    group_id=gid, volumes=volumes)
        push!(struc.slabs, slab)
    end
end

"""Derive slab position from its cells (corner > edge > interior)."""
function _derive_slab_position(struc, cell_indices)
    positions = [struc.cells[i].position for i in cell_indices]
    # Priority: corner > edge > interior
    :corner in positions && return :corner
    :edge in positions && return :edge
    return :interior
end

"""Compute material volumes for a slab from its result and floor area."""
function _compute_slab_volumes(result::R, floor_area, primary_mat, opts::StructuralSizer.AbstractFloorOptions) where R<:AbstractFloorResult
    mat_map = StructuralSizer.result_materials(result, primary_mat, opts)
    
    # Compute volumes: material → total volume
    volumes = MaterialVolumes()
    for mat_sym in StructuralSizer.materials(result)
        mat = mat_map[mat_sym]
        vol_per_area = StructuralSizer.volume_per_area(result, mat_sym)
        volumes[mat] = vol_per_area * floor_area
    end
    return volumes
end

"""
    update_slab_volumes!(struc; options, primary_material=nothing)

Recompute material volumes for all slabs based on their current results.

Call this after `size_slabs!` to update the volumes with accurate material
quantities (including reinforcement) for EC calculations.

# Example
```julia
size_slabs!(struc; options=opts)
update_slab_volumes!(struc; options=opts)
ec = compute_building_ec(struc)
```
"""
function update_slab_volumes!(struc::BuildingStructure; 
                              options::StructuralSizer.AbstractFloorOptions=StructuralSizer.FlatPlateOptions(),
                              primary_material=nothing)
    for slab in struc.slabs
        isnothing(slab.result) && continue   # skip non-converged slabs
        floor_area = sum(struc.cells[idx].area for idx in slab.cell_indices)
        mat = isnothing(primary_material) ? _primary_material(options) : primary_material
        slab.volumes = _compute_slab_volumes(slab.result, floor_area, mat, options)
    end
    return struc
end

"""Extract primary material from floor options for volume calculations."""
_primary_material(opts::StructuralSizer.FlatPlateOptions) = opts.material.concrete
_primary_material(opts::StructuralSizer.FlatSlabOptions)  = opts.base.material.concrete
_primary_material(opts::StructuralSizer.OneWayOptions)    = opts.material.concrete
_primary_material(opts::StructuralSizer.VaultOptions)     = opts.material
_primary_material(::StructuralSizer.AbstractFloorOptions) = StructuralSizer.NWC_4000

# =============================================================================
# Slab grouping helpers
# =============================================================================

"""
    build_slab_groups!(struc::BuildingStructure)

Populate `struc.slab_groups` from `struc.slabs` using `Slab.group_id`.

- If `slab.group_id === nothing`, the slab is treated as its own singleton group
  and a deterministic `UInt64` group id is assigned.
- If `slab.group_id` is set, all slabs with the same id are grouped together.
"""
function build_slab_groups!(struc::BuildingStructure)
    empty!(struc.slab_groups)

    for (s_idx, s) in enumerate(struc.slabs)
        gid = s.group_id === nothing ? UInt64(hash((:singleton_slab_group, s_idx))) : UInt64(s.group_id)
        s.group_id = gid

        sg = get!(struc.slab_groups, gid) do
            SlabGroup(gid)
        end

        push!(sg.slab_indices, s_idx)
    end

    return struc.slab_groups
end

# =============================================================================
# Cell Grouping (for tributary area optimization)
# =============================================================================

"""
    build_cell_groups!(struc::BuildingStructure)

Group cells by rotation-invariant geometry for tributary computation.
- For isotropic cells: groups cells with same shape (rotation + reflection invariant)
- For one-way cells: groups cells with same shape AND same relative span direction

Cells in the same group share identical parametric tributary polygons (computed once).
"""
function build_cell_groups!(struc::BuildingStructure)
    empty!(struc.cell_groups)

    for (c_idx, cell) in enumerate(struc.cells)
        key = _cell_group_hash(struc, cell)

        cg = get!(struc.cell_groups, key) do
            CellGroup(key)
        end
        push!(cg.cell_indices, c_idx)
    end

    return struc.cell_groups
end

"""
Hash cell by rotation-invariant geometry signature.

For isotropic cells (spans.axis ≈ (0,0)): hash only the canonical geometry.
For one-way cells: hash canonical geometry + canonical span edge index.
"""
function _cell_group_hash(struc::BuildingStructure, cell::Cell)
    canon_sig, canon_start, is_reversed = _cell_geometry_signature(struc, cell)
    
    # Check if isotropic (axis ≈ zero)
    axis = cell.spans.axis
    is_isotropic = hypot(axis[1], axis[2]) < 1e-9
    
    if is_isotropic
        # Isotropic: only geometry matters (full rotation + reflection invariance)
        return UInt64(hash(canon_sig))
    else
        # One-way: include canonical span edge index
        n_edges = length(canon_sig)
        span_edge_idx = _find_span_edge_index(struc, cell)
        canon_span_idx = _canonicalize_edge_index(span_edge_idx, canon_start, is_reversed, n_edges)
        return UInt64(hash((canon_sig, canon_span_idx)))
    end
end

"""
Compute rotation+reflection invariant geometry signature.

Returns:
- `canon_sig`: Canonical feature sequence (edge_length, interior_angle) tuples
- `canon_start`: Starting vertex index in the canonical form
- `is_reversed`: Whether the canonical form is the reversed (reflected) sequence
"""
function _cell_geometry_signature(struc::BuildingStructure, cell::Cell)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    v_indices = skel.face_vertex_indices[cell.face_idx]
    
    coords = [(vc[vi, 1], vc[vi, 2]) for vi in v_indices]
    features = _compute_polygon_features(coords)
    return _find_canonical_form(features)
end

"""Compute (edge_length, interior_angle) for each vertex."""
function _compute_polygon_features(coords::AbstractVector{<:NTuple{2, <:Real}})
    n = length(coords)
    features = NTuple{2, Float64}[]
    
    for i in 1:n
        # Edge from vertex i to i+1
        p1 = coords[i]
        p2 = coords[mod1(i + 1, n)]
        edge_len = round(hypot(p2[1] - p1[1], p2[2] - p1[2]), digits=6)
        
        # Interior angle at vertex i (angle between edge i-1→i and edge i→i+1)
        p0 = coords[mod1(i - 1, n)]
        v1 = (p1[1] - p0[1], p1[2] - p0[2])  # incoming edge
        v2 = (p2[1] - p1[1], p2[2] - p1[2])  # outgoing edge
        
        # Angle via atan2 of cross and dot products
        cross = v1[1] * v2[2] - v1[2] * v2[1]
        dot = v1[1] * v2[1] + v1[2] * v2[2]
        angle = round(atan(cross, dot), digits=6)  # Signed angle (-π to π)
        
        push!(features, (edge_len, angle))
    end
    
    return features
end

"""
Find the lexicographically smallest rotation, checking both forward and reversed sequences.

Returns (canonical_sequence, start_index, is_reversed).
"""
function _find_canonical_form(features::AbstractVector{<:NTuple{2, <:Real}})
    n = length(features)
    
    # Try all rotations of forward sequence
    best_seq = features
    best_start = 1
    best_reversed = false
    
    for start in 1:n
        rotated = _circshift_features(features, start)
        if rotated < best_seq
            best_seq = rotated
            best_start = start
            best_reversed = false
        end
    end
    
    # Try all rotations of reversed sequence (handles reflection)
    # When reversed, edge i becomes edge n-i, and angles flip sign
    reversed_features = [(features[mod1(n - i + 1, n)][1], -features[mod1(n - i + 2, n)][2]) 
                         for i in 1:n]
    
    for start in 1:n
        rotated = _circshift_features(reversed_features, start)
        if rotated < best_seq
            best_seq = rotated
            best_start = start
            best_reversed = true
        end
    end
    
    # Convert to tuple for hashing
    canon_tuple = Tuple(round.(v, digits=6) for v in best_seq)
    return canon_tuple, best_start, best_reversed
end

"""Circular shift returning a new vector starting at index `start`."""
function _circshift_features(v::AbstractVector{<:NTuple{2, <:Real}}, start::Int)
    n = length(v)
    return [v[mod1(start + i - 1, n)] for i in 1:n]
end

"""
Find which edge index (1-based, CCW order) the span axis is most parallel to.

For one-way systems, the span direction is perpendicular to the supporting edges.
This returns the index of the edge that best aligns with the span direction.
"""
function _find_span_edge_index(struc::BuildingStructure, cell::Cell)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    v_indices = skel.face_vertex_indices[cell.face_idx]
    n = length(v_indices)
    
    axis = cell.spans.axis
    ax_norm = hypot(axis[1], axis[2])
    ax_norm < 1e-9 && return 0  # Isotropic, no meaningful edge
    
    ax_unit = (axis[1] / ax_norm, axis[2] / ax_norm)
    
    best_idx = 1
    best_alignment = -Inf
    
    for i in 1:n
        vi1 = v_indices[i]
        vi2 = v_indices[mod1(i + 1, n)]
        dx = vc[vi2, 1] - vc[vi1, 1]
        dy = vc[vi2, 2] - vc[vi1, 2]
        edge_len = hypot(dx, dy)
        edge_len < 1e-9 && continue
        
        alignment = abs(ax_unit[1] * dx/edge_len + ax_unit[2] * dy/edge_len)
        if alignment > best_alignment
            best_alignment = alignment
            best_idx = i
        end
    end
    
    return best_idx
end

"""Transform edge index through canonicalization (rotation + optional reversal)."""
function _canonicalize_edge_index(edge_idx::Int, canon_start::Int, is_reversed::Bool, n::Int)
    if is_reversed
        # Reversal maps edge i → edge (n - i + 1), then apply rotation
        reversed_idx = mod1(n - edge_idx + 1, n)
        return mod1(reversed_idx - canon_start + 1, n)
    else
        # Just rotation
        return mod1(edge_idx - canon_start + 1, n)
    end
end

# =============================================================================
# Tributary Area Computation
# =============================================================================

"""
    compute_cell_tributaries!(struc; floor_opts, tributary_axis=nothing)

Compute parametric tributary polygons for each cell and store in TributaryCache.

Uses one-way directed partitioning for one-way floor types (along span axis),
isotropic straight skeleton for two-way systems. The `tributary_axis` argument
can override the default behavior.

Results stored in `struc._tributary_caches.edge[key][cell_idx]` where key is derived
from (spanning_behavior, axis). Access via:
- `cell_edge_tributaries(struc, cell_idx)` → Vector{TributaryPolygon}
- `get_cached_edge_tributaries(struc, behavior, axis, cell_idx)` → CellTributaryResult

Note: Tributaries are computed per-cell (not shared via groups) because the
parametric `local_edge_idx` must match each cell's specific vertex order.
"""
function compute_cell_tributaries!(struc::BuildingStructure; 
                                    floor_opts::StructuralSizer.AbstractFloorOptions=StructuralSizer.FlatPlateOptions(),
                                    tributary_axis=nothing)
    skel = struc.skeleton
    for (cell_idx, cell) in enumerate(struc.cells)
        if cell.floor_type == :unknown || cell.floor_type == :grade
            continue
        end
        
        verts = [skel.vertices[i] for i in skel.face_vertex_indices[cell.face_idx]]
        
        ft = StructuralSizer.floor_type(cell.floor_type)
        behavior = StructuralSizer.spanning_behavior(ft)
        axis = StructuralSizer.resolve_tributary_axis(ft, cell.spans, tributary_axis)
        
        if has_cell_tributaries(struc, cell_idx, behavior, axis)
            continue
        end
        
        trib = if isnothing(axis)
            StructuralSizer.get_tributary_polygons_isotropic(verts)
        else
            StructuralSizer.get_tributary_polygons(verts; axis=collect(axis))
        end
        
        strips = nothing
        if behavior isa TwoWaySpanning || behavior isa BeamlessSpanning
            strips = StructuralSizer.compute_panel_strips(trib)
        end
        
        cache_edge_tributaries!(struc, behavior, axis, cell_idx, trib; strip_geometry=strips)
    end
end

"""Resolve a user-provided slab group ID at `idx`, returning `nothing` or `UInt64`."""
function _resolve_slab_group_id(slab_group_ids, idx::Int; tag::Symbol)
    isnothing(slab_group_ids) && return nothing
    length(slab_group_ids) >= idx || throw(ArgumentError("slab_group_ids too short: need at least $idx entries for $tag indexing"))
    v = slab_group_ids[idx]
    v === nothing && return nothing
    return UInt64(v)
end

"""Resolve the common group ID for a set of cells (errors if they disagree)."""
function _resolve_group_id_for_cell_set(slab_group_ids, cell_indices::Vector{Int})
    isnothing(slab_group_ids) && return nothing
    gids = UInt64[]
    for c_idx in cell_indices
        g = _resolve_slab_group_id(slab_group_ids, c_idx; tag=:cell)
        g === nothing && continue
        push!(gids, g)
    end
    isempty(gids) && return nothing
    all(g -> g == first(gids), gids) || throw(ArgumentError("Cells in a physical slab have inconsistent slab_group_ids: $(unique(gids))"))
    return first(gids)
end

# =============================================================================
# Sizing span conventions
# =============================================================================

"""
Pick the `span` passed into `_size_span_floor(ft, span, ...)`.

Uses SpanInfo to select the appropriate span for each floor system type:
- One-way systems: primary (short) span
- Two-way systems: isotropic span or max(primary, secondary)
"""
_sizing_span(::AbstractFloorSystem, si::SpanInfo) = si.primary

# ACI two-way / plate / waffle / PT thickness rules are based on the long span.
_sizing_span(::TwoWay, si::SpanInfo) = si.isotropic
_sizing_span(::FlatPlate, si::SpanInfo) = max(si.primary, si.secondary)
_sizing_span(::FlatSlab, si::SpanInfo) = max(si.primary, si.secondary)
_sizing_span(::PTBanded, si::SpanInfo) = max(si.primary, si.secondary)
_sizing_span(::Waffle, si::SpanInfo) = max(si.primary, si.secondary)

# =============================================================================
# Structural Effects Application
# =============================================================================

"""
Apply vault thrust effects to the building structure model.
Identifies support edges and applies outward horizontal LineLoads to ASAP members.
"""
function StructuralSizer.apply_effects!(::Vault, struc::BuildingStructure, slab::Slab)
    # Keep this method for compatibility, but delegate to the unified edge-load interface.
    _assert_rectangular_slab_face(struc, struc.cells[first(slab.cell_indices)].face_idx)

    for ll in slab_edge_line_loads(struc, slab)
        el = struc.asap_model.elements[ll.edge_idx]
        push!(struc.asap_model.loads, Asap.LineLoad(el, collect(ll.w)))
    end
end

"""Assert that `face_idx` is a 4-vertex orthogonal rectangle (required for vaults)."""
function _assert_rectangular_slab_face(struc::BuildingStructure, face_idx::Int; tol=1e-8)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    v_idx = skel.face_vertex_indices[face_idx]

    length(v_idx) == 4 || throw(ArgumentError("Vault requires a rectangular face (4 vertices); face $face_idx has $(length(v_idx)) vertices."))

    # Edge vectors in meters (Float64)
    vs = [(vc[v_idx[2], 1] - vc[v_idx[1], 1], vc[v_idx[2], 2] - vc[v_idx[1], 2]),
          (vc[v_idx[3], 1] - vc[v_idx[2], 1], vc[v_idx[3], 2] - vc[v_idx[2], 2]),
          (vc[v_idx[4], 1] - vc[v_idx[3], 1], vc[v_idx[4], 2] - vc[v_idx[3], 2]),
          (vc[v_idx[1], 1] - vc[v_idx[4], 1], vc[v_idx[1], 2] - vc[v_idx[4], 2])]

    norms = [hypot(v[1], v[2]) for v in vs]
    all(n -> n > tol, norms) || throw(ArgumentError("Vault face $face_idx is degenerate (zero-length edge)."))

    dot12 = abs((vs[1][1]*vs[2][1] + vs[1][2]*vs[2][2]) / (norms[1]*norms[2]))
    dot23 = abs((vs[2][1]*vs[3][1] + vs[2][2]*vs[3][2]) / (norms[2]*norms[3]))
    dot34 = abs((vs[3][1]*vs[4][1] + vs[3][2]*vs[4][2]) / (norms[3]*norms[4]))
    dot41 = abs((vs[4][1]*vs[1][1] + vs[4][2]*vs[1][2]) / (norms[4]*norms[1]))

    (dot12 < 1e-6 && dot23 < 1e-6 && dot34 < 1e-6 && dot41 < 1e-6) ||
        throw(ArgumentError("Vault requires an orthogonal rectangular face; face $face_idx is not orthogonal within tolerance."))
end

# =============================================================================
# Type-specific Default Kwargs
# =============================================================================

"""
Build kwargs for `_size_span_floor` with type-specific defaults.
"""
function _build_floor_kwargs(ft::AbstractFloorSystem, span, user_kwargs::NamedTuple)
    defaults = _default_floor_kwargs(ft, span, user_kwargs)
    return merge(defaults, user_kwargs)
end

"""Fallback: no additional kwargs for generic floor systems."""
_default_floor_kwargs(::AbstractFloorSystem, span, user_kwargs::NamedTuple) = NamedTuple()

# Vault: default lambda = 10 (span/rise = 10) unless user provides rise or lambda
function _default_floor_kwargs(::Vault, span, user_kwargs::NamedTuple)
    # Only add lambda if user hasn't provided rise or lambda
    has_rise = haskey(user_kwargs, :rise) && !isnothing(user_kwargs.rise)
    has_lambda = haskey(user_kwargs, :lambda) && !isnothing(user_kwargs.lambda)

    # Respect vault rise/lambda from VaultOptions if passed via `options`
    has_options_lambda = false
    has_options_rise = false
    if haskey(user_kwargs, :options) && user_kwargs.options isa StructuralSizer.VaultOptions
        vopt = user_kwargs.options
        has_options_lambda = !isnothing(vopt.lambda)
        has_options_rise = vopt.rise !== nothing
    end
    
    if !has_rise && !has_lambda && !has_options_lambda && !has_options_rise
        return (lambda=10.0,)
    end
    return NamedTuple()
end

# =============================================================================
# Slab Summary Output
# =============================================================================

"""
    slab_summary(design::BuildingDesign)
    slab_summary(struc::BuildingStructure; du=imperial)

Print a formatted summary of all designed slabs.

Shows:
- Floor type and thickness
- Span dimensions
- Design check results (punching shear, deflection)
- Reinforcement summary (for flat plates)
- Concrete volume

Display units are controlled by `du` (default: `imperial`).
When called with a `BuildingDesign`, uses `design.params.display_units`.
"""
function slab_summary(design::BuildingDesign)
    slab_summary(design.structure; du=design.params.display_units)
end

function slab_summary(struc::BuildingStructure; du::DisplayUnits=imperial)
    isempty(struc.slabs) && return println("No slabs. Call initialize_slabs!() first.")
    
    println("\n=== Slab Design Summary ===")
    println("─" ^ 70)
    
    total_concrete = 0.0u"m^3"
    total_area = 0.0u"m^2"
    
    for (i, slab) in enumerate(struc.slabs)
        r = slab.result
        n_cells = length(slab.cell_indices)
        
        # Calculate slab area from cells
        slab_area = sum(struc.cells[ci].area for ci in slab.cell_indices)
        total_area += slab_area
        
        println("Slab $i: $(slab.floor_type) ($n_cells cells)")
        println("  Area: $(fmt(du, :area, slab_area))")
        
        if r isa StructuralSizer.FlatPlatePanelResult
            println("  Thickness: $(fmt(du, :thickness, r.h))")
            println("  Spans: $(fmt(du, :span, r.l1)) × $(fmt(du, :span, r.l2))")
            println("  M₀ (static moment): $(fmt(du, :moment, r.M0))")
            
            # Moment detail (column strip governing)
            if !isempty(r.column_strip_reinf)
                cs_neg = r.column_strip_reinf[end]   # int_neg (last entry)
                cs_pos = r.column_strip_reinf[2]      # pos (second entry)
                println("  Mu (col strip): −$(fmt(du, :moment, cs_neg.Mu)), +$(fmt(du, :moment, cs_pos.Mu))")
            end
            if !isempty(r.middle_strip_reinf)
                ms_pos = r.middle_strip_reinf[1]
                println("  Mu (mid strip): +$(fmt(du, :moment, ms_pos.Mu))")
            end
            
            # Punching check
            if hasproperty(r, :punching_check) && !isnothing(r.punching_check)
                pc = r.punching_check
                status = pc.ok ? "✓ OK" : "✗ FAIL"
                println("  Punching shear: $status (max ratio=$(round(pc.max_ratio, digits=2)))")
            end
            
            # Deflection check
            if hasproperty(r, :deflection_check) && !isnothing(r.deflection_check)
                dc = r.deflection_check
                status = dc.ok ? "✓ OK" : "✗ FAIL"
                println("  Deflection: $status (Δ=$(fmt(du, :deflection, dc.Δ_total, digits=1)), limit=$(fmt(du, :deflection, dc.Δ_limit, digits=1)))")
            end
            
            # Reinforcement summary
            if !isempty(r.column_strip_reinf)
                cs = r.column_strip_reinf[1]
                println("  Column strip: #$(cs.bar_size) @ $(fmt(du, :spacing, cs.spacing, digits=1))")
            end
            if !isempty(r.middle_strip_reinf)
                ms = r.middle_strip_reinf[1]
                println("  Middle strip: #$(ms.bar_size) @ $(fmt(du, :spacing, ms.spacing, digits=1))")
            end
            
            # Concrete volume
            vol = r.h * slab_area
            total_concrete += vol
            println("  Concrete volume: $(fmt(du, :volume, vol))")
            
        elseif r isa StructuralSizer.VaultResult
            # Vault details
            println("  Thickness: $(fmt(du, :thickness, r.thickness))")
            println("  Rise: $(fmt(du, :thickness, r.rise, digits=1))")
            println("  λ (rise ratio): $(round(r.lambda, digits=1))")
            println("  Thrust: $(round(u"kN/m", StructuralSizer.total_thrust(r), digits=1))")
            
            vol = r.volume_per_area * slab_area
            total_concrete += vol
            println("  Concrete volume: $(fmt(du, :volume, vol))")
            
        elseif r isa StructuralSizer.CIPSlabResult
            # Standard one-way/two-way slab
            println("  Thickness: $(fmt(du, :thickness, r.thickness))")
            println("  Self-weight: $(fmt(du, :pressure, r.self_weight, digits=1))")
            
            vol = r.volume_per_area * slab_area
            total_concrete += vol
            println("  Concrete volume: $(fmt(du, :volume, vol))")
            
        elseif !isnothing(r)
            # Generic result with total_depth accessor
            h = StructuralSizer.total_depth(r)
            println("  Thickness: $(fmt(du, :thickness, h))")
            
            if hasproperty(r, :volume_per_area)
                vol = r.volume_per_area * slab_area
                total_concrete += vol
                println("  Concrete volume: $(fmt(du, :volume, vol))")
            end
        else
            println("  (not sized)")
        end
        
        println()
    end
    
    println("─" ^ 70)
    println("TOTALS:")
    println("  Slabs: $(length(struc.slabs))")
    println("  Total area: $(fmt(du, :area, total_area))")
    println("  Concrete volume: $(fmt(du, :volume, total_concrete))")
    println("  Concrete weight: $(fmt(du, :mass, total_concrete * 2400u"kg/m^3", digits=0))")
end

# =============================================================================
# Flat Plate Moment Comparison (DDM / EFM / FEA)
# =============================================================================

"""
    flat_plate_moment_comparison(struc, slab_idx; opts, column_opts, verbose)

Run DDM, EFM, and FEA moment analyses on a single slab and print a comparison table.

Useful for validating that FEA moments are consistent with analytical methods
on regular geometries, and for seeing where they diverge on irregular ones.

# Example
```julia
flat_plate_moment_comparison(struc, 1; verbose=false)
```
"""
function flat_plate_moment_comparison(
    struc::BuildingStructure,
    slab_idx::Int;
    opts::StructuralSizer.FlatPlateOptions = StructuralSizer.FlatPlateOptions(),
    column_opts = StructuralSizer.ConcreteColumnOptions(),
    verbose::Bool = false
)
    slab = struc.slabs[slab_idx]
    material = opts.material
    fc = material.concrete.fc′
    γ_concrete = material.concrete.ρ
    ν_concrete = material.concrete.ν
    wc_pcf = ustrip(StructuralSizer.pcf, γ_concrete)
    Ecs = StructuralSizer.Ec(fc, wc_pcf)

    slab_cell_indices = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_indices)
    isempty(columns) && return println("No supporting columns found for slab $slab_idx")

    # Initialize column sizes if needed
    ln_max = max(slab.spans.primary, slab.spans.secondary)
    c_min = StructuralSizer.estimate_column_size_from_span(ln_max)
    for col in columns
        if isnothing(col.c1) || col.c1 <= 0u"inch"
            col.c1 = c_min
            col.c2 = c_min
        end
    end

    has_edge = any(col.position != :interior for col in columns)
    h = StructuralSizer.min_thickness(StructuralSizer.FlatPlate(), ln_max; discontinuous_edge=has_edge)

    # Run each method (catch failures for inapplicable methods)
    methods = [
        ("DDM",  StructuralSizer.DDM()),
        ("EFM",  StructuralSizer.EFM()),
        ("FEA",  StructuralSizer.FEA()),
    ]

    results = Dict{String, Any}()
    for (name, method) in methods
        try
            r = StructuralSizer.run_moment_analysis(
                method, struc, slab, columns, h, fc, Ecs, γ_concrete;
                ν_concrete=ν_concrete, verbose=verbose
            )
            results[name] = r
        catch e
            results[name] = e
        end
    end

    # Print comparison table
    println("\n=== Flat Plate Moment Comparison — Slab $slab_idx ===")
    println("─" ^ 74)
    println("  Spans: $(round(u"ft", slab.spans.primary, digits=1)) × $(round(u"ft", slab.spans.secondary, digits=1))")
    println("  h = $(round(u"inch", h, digits=1)),  $(length(columns)) columns")
    println("─" ^ 74)
    @printf("  %-8s  %10s  %10s  %10s  %10s  %8s\n",
            "Method", "M₀", "M⁻_ext", "M⁻_int", "M⁺", "∑/M₀")
    println("  " * "─" ^ 64)

    for (name, _) in methods
        r = results[name]
        if r isa Exception
            @printf("  %-8s  %s\n", name, "N/A ($(typeof(r).name.name))")
        else
            M0  = ustrip(StructuralSizer.kip * u"ft", r.M0)
            Mne = ustrip(StructuralSizer.kip * u"ft", r.M_neg_ext)
            Mni = ustrip(StructuralSizer.kip * u"ft", r.M_neg_int)
            Mp  = ustrip(StructuralSizer.kip * u"ft", r.M_pos)
            check = (Mne + Mni) / 2 + Mp
            ratio = M0 > 0 ? check / M0 : 0.0
            @printf("  %-8s  %10.1f  %10.1f  %10.1f  %10.1f  %7.1f%%\n",
                    name, M0, Mne, Mni, Mp, ratio * 100)
        end
    end
    println("─" ^ 74)
    println("  Units: kip·ft.  ∑/M₀ = (M⁻_ext/2 + M⁻_int/2 + M⁺) / M₀")

    return results
end

# =============================================================================
# Slab Parallel Coloring (graph coloring for concurrent slab sizing)
# =============================================================================

"""
    slab_conflict_coloring(slab_column_sets::Vector{Set{Int}}) -> Vector{Vector{Int}}

Graph-color slabs by column conflict. Two slabs conflict if they share
any supporting column index. Returns batches of non-conflicting slab
indices (1-based) suitable for `Threads.@threads` execution.

Uses greedy coloring with largest-degree-first ordering.
"""
function slab_conflict_coloring(slab_column_sets::Vector{Set{Int}})
    n = length(slab_column_sets)
    n == 0 && return Vector{Int}[]

    # Build conflict adjacency (edge if two slabs share a column)
    neighbors = [Set{Int}() for _ in 1:n]
    for i in 1:n, j in (i+1):n
        if !isempty(intersect(slab_column_sets[i], slab_column_sets[j]))
            push!(neighbors[i], j)
            push!(neighbors[j], i)
        end
    end

    # Greedy coloring (largest-degree-first for fewer colors)
    colors = zeros(Int, n)
    order = sortperm([length(neighbors[i]) for i in 1:n], rev=true)

    for idx in order
        used = Set(colors[nb] for nb in neighbors[idx] if colors[nb] > 0)
        c = 1
        while c in used
            c += 1
        end
        colors[idx] = c
    end

    # Group by color → batches
    n_colors = maximum(colors; init=0)
    batches = [Int[] for _ in 1:n_colors]
    for (idx, c) in enumerate(colors)
        push!(batches[c], idx)
    end

    return batches
end

"""
    compute_slab_parallel_batches!(struc)

Build the slab conflict graph from slab–column tributary overlap and
graph-color it so that slabs in each batch share no columns.

Stores result in `struc.slab_parallel_batches` for reuse by `size_slabs!`.
"""
function compute_slab_parallel_batches!(struc)
    n_slabs = length(struc.slabs)
    if n_slabs == 0
        struc.slab_parallel_batches = Vector{Int}[]
        return struc
    end

    # Build slab → column set mapping via tributary cell overlap
    slab_column_sets = Vector{Set{Int}}(undef, n_slabs)
    for (s_idx, slab) in enumerate(struc.slabs)
        slab_cells = Set(slab.cell_indices)
        col_set = Set{Int}()
        for (c_idx, col) in enumerate(struc.columns)
            if !isempty(col.tributary_cell_indices) &&
               !isempty(intersect(col.tributary_cell_indices, slab_cells))
                push!(col_set, c_idx)
            end
        end
        slab_column_sets[s_idx] = col_set
    end

    struc.slab_parallel_batches = slab_conflict_coloring(slab_column_sets)
    return struc
end