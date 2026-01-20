# Cell and Slab initialization from skeleton faces

# =============================================================================
# Geometry Helpers
# =============================================================================

"""
    get_cell_spans(skel, face_idx)

Return `(span_x, span_y)` as the axis-aligned bounding-box spans of a face.
This assumes the slab bay is roughly aligned to global X/Y (good enough for sizing).
"""
function get_cell_spans(skel::BuildingSkeleton{T}, face_idx::Int) where T
    polygon = skel.faces[face_idx]
    pts = Meshes.vertices(polygon)
    
    xs = [Meshes.coords(p).x for p in pts]
    ys = [Meshes.coords(p).y for p in pts]
    
    span_x = maximum(xs) - minimum(xs)
    span_y = maximum(ys) - minimum(ys)
    
    return span_x, span_y
end

"""Initialize cells from skeleton faces (geometry + service SDL/LL)."""
function initialize_cells!(struc::BuildingStructure{T, A, P}) where {T, A, P}
    skel = struc.skeleton
    empty!(struc.cells)
    
    load_map = [
        :grade => (Constants.LL_GRADE, Constants.SDL_FLOOR),
        :floor => (Constants.LL_FLOOR, Constants.SDL_FLOOR),
        :roof  => (Constants.LL_ROOF,  Constants.SDL_ROOF)
    ]
    
    processed_faces = Set{Int}()
    
    for (grp_name, loads) in load_map
        face_indices = get(skel.groups_faces, grp_name, Int[])
        ll, sdl = loads
        
        for face_idx in face_indices
            face_idx in processed_faces && continue
            push!(processed_faces, face_idx)
            
            polygon = skel.faces[face_idx]
            area = Meshes.measure(polygon)
            span_x, span_y = get_cell_spans(skel, face_idx)
            
            # Store service loads
            cell = Cell(face_idx, area, span_x, span_y, sdl, ll)
            push!(struc.cells, cell)
        end
    end
    
    @debug "Initialized $(length(struc.cells)) cells"
end

"""
Initialize slabs from cells using `StructuralSizer.size_floor`.

Notes:
- `Cell` stores **service** `sdl`/`live_load`. Slab sizing computes service self-weight.
- The `span` passed to `size_floor(ft, span, ...)` depends on floor type; see `_sizing_span`.
"""
function initialize_slabs!(struc::BuildingStructure{T};
                           material::AbstractMaterial=NWC_4000,
                           floor_type::Symbol=:auto,
                           floor_kwargs::NamedTuple=NamedTuple(),
                           cell_groupings::Union{Nothing, Vector{Vector{Int}}}=nothing,
                           slab_group_ids::Union{Nothing, AbstractVector}=nothing) where T
    empty!(struc.slabs)
    
    # 1. Build per-slab "specs"
    slab_specs = _build_slab_specs(struc, floor_type, cell_groupings, slab_group_ids)

    # 2. Assign fallback deterministic group IDs if needed
    _assign_deterministic_group_ids!(slab_specs)

    # 3. Group specs by ID
    groups = _group_slab_specs(slab_specs)

    # 4. Size once per slab group
    group_results, group_sw = _size_slab_groups(groups, slab_specs, struc, material, floor_kwargs)

    # 5. Fan out results to cells and create Slab objects
    _apply_slab_results!(struc, slab_specs, group_results, group_sw)

    # 6. Finalize grouping structure in BuildingStructure
    groups = build_slab_groups!(struc)

    for sg in values(groups)
        sg.material = material
    end


    @debug "Initialized $(length(struc.slabs)) slabs from $(length(struc.cells)) cells"
end

# =============================================================================
# Initialization Helpers
# =============================================================================

function _build_slab_specs(struc, floor_type, cell_groupings, slab_group_ids)
    slab_specs = NamedTuple[]

    if isnothing(cell_groupings)
        # Default: 1 slab per cell
        for (cell_idx, cell) in enumerate(struc.cells)
            span_x, span_y = cell.span_x, cell.span_y

            ft_sym = floor_type == :auto ? infer_floor_type(span_x, span_y) : floor_type
            gid = _resolve_slab_group_id(slab_group_ids, cell_idx; tag=:cell)

            span_axis = span_x <= span_y ? (1.0, 0.0, 0.0) : (0.0, 1.0, 0.0)
            push!(slab_specs, (; cell_indices=[cell_idx],
                              span_x_gov=span_x, span_y_gov=span_y,
                              sdl_gov=cell.sdl, live_gov=cell.live_load,
                              floor_type=ft_sym, span_axis=span_axis, group_id=gid))
        end
    else
        # Explicit groupings: combine cells into physical slabs (PT, etc.)
        for cell_indices in cell_groupings
            cells = [struc.cells[i] for i in cell_indices]

            span_x_gov = maximum(c.span_x for c in cells)
            span_y_gov = maximum(c.span_y for c in cells)
            sdl_gov = maximum(c.sdl for c in cells)
            live_gov = maximum(c.live_load for c in cells)

            # For grouped slabs, default to :pt_banded unless specified
            ft_sym = floor_type == :auto ? :pt_banded : floor_type

            # Group id: must be consistent across all cells participating in this physical slab
            gid = _resolve_group_id_for_cell_set(slab_group_ids, cell_indices)

            push!(slab_specs, (; cell_indices=cell_indices,
                              span_x_gov=span_x_gov, span_y_gov=span_y_gov,
                              sdl_gov=sdl_gov, live_gov=live_gov,
                              floor_type=ft_sym, span_axis=nothing, group_id=gid))
        end
    end
    return slab_specs
end

function _assign_deterministic_group_ids!(slab_specs)
    for (i, spec) in enumerate(slab_specs)
        if spec.group_id === nothing
            # Create a new named tuple with the assigned group_id
            # Note: slab_specs is a Vector{NamedTuple}, so we replace the entry
            slab_specs[i] = merge(spec, (; group_id=UInt64(hash((:singleton_slab_group, i)))))
        end
    end
end

function _group_slab_specs(slab_specs)
    groups = Dict{UInt64, Vector{Int}}()
    for (i, spec) in enumerate(slab_specs)
        push!(get!(groups, spec.group_id, Int[]), i)
    end
    return groups
end

function _size_slab_groups(groups, slab_specs, struc, material, floor_kwargs)
    group_results = Dict{UInt64, AbstractFloorResult}()
    group_sw = Dict{UInt64, Any}()  # pressure units vary by input type/units

    for (gid, spec_idxs) in groups
        specs = slab_specs[spec_idxs]
        result, sw_service = _process_single_slab_group(gid, specs, struc, material, floor_kwargs)
        
        group_results[gid] = result
        group_sw[gid] = sw_service
    end

    return group_results, group_sw
end

function _process_single_slab_group(gid, specs, struc, material, floor_kwargs)
    # Enforce consistent type per group (caller-defined groups should be "similar slabs").
    ft_syms = unique(getfield.(specs, :floor_type))
    length(ft_syms) == 1 || throw(ArgumentError("Slab group $gid has mixed floor types: $(ft_syms). Provide a consistent `floor_type` or use separate `slab_group_ids`."))

    ft_sym = only(ft_syms)
    ft = StructuralSizer.floor_type(ft_sym)

    # Disallow physical multi-cell vault slabs (still OK to have multiple *slabs* in a vault group).
    if ft isa Vault
        for s in specs
            length(s.cell_indices) == 1 || throw(ArgumentError("Vault slabs must be a single rectangular face; got a slab with $(length(s.cell_indices)) cells in group $gid."))
            cell = struc.cells[only(s.cell_indices)]
            _assert_rectangular_slab_face(struc, cell.face_idx)
        end
    end

    span_x_gov = maximum(getfield.(specs, :span_x_gov))
    span_y_gov = maximum(getfield.(specs, :span_y_gov))
    sdl_gov = maximum(getfield.(specs, :sdl_gov))
    live_gov = maximum(getfield.(specs, :live_gov))

    span_for_sizing = _sizing_span(ft, span_x_gov, span_y_gov)
    kwargs = _build_floor_kwargs(ft, span_for_sizing, floor_kwargs)

    result = size_floor(ft, span_for_sizing, sdl_gov, live_gov; material=material, kwargs...)
    sw_service = StructuralSizer.self_weight(result)

    return result, sw_service
end

function _apply_slab_results!(struc, slab_specs, group_results, group_sw)
    for spec in slab_specs
        gid = spec.group_id
        result = group_results[gid]
        sw_service = group_sw[gid]

        # Propagate structural data to cells
        for c_idx in spec.cell_indices
            cell = struc.cells[c_idx]
            cell.self_weight = sw_service
            cell.span_axis = spec.span_axis
            cell.floor_type = spec.floor_type
        end

        slab = Slab(spec.cell_indices, result; floor_type=spec.floor_type, span_axis=spec.span_axis, group_id=gid)
        push!(struc.slabs, slab)
    end
end

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

Group cells by (geometry_hash, span_axis, floor_type) for tributary computation.
Cells in the same group share identical tributary polygons (computed once).
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

"""Hash cell by geometry signature + direction."""
function _cell_group_hash(struc::BuildingStructure, cell::Cell)
    # Geometry: normalized vertex offsets (translation-invariant)
    geom_sig = _cell_geometry_signature(struc, cell)
    # Direction + floor type
    return UInt64(hash((geom_sig, cell.span_axis)))
end

"""Compute translation-invariant geometry signature for a cell."""
function _cell_geometry_signature(struc::BuildingStructure, cell::Cell)
    poly = struc.skeleton.faces[cell.face_idx]
    pts = Meshes.vertices(poly)
    
    # Get 2D coords, strip units
    coords = [(Float64(ustrip(u"m", Meshes.coords(p).x)),
               Float64(ustrip(u"m", Meshes.coords(p).y))) for p in pts]
    
    # Translate to origin (first vertex)
    x0, y0 = first(coords)
    normalized = [(x - x0, y - y0) for (x, y) in coords]
    
    # Round to avoid floating-point noise in hash
    return Tuple(round.(v, digits=6) for v in normalized)
end

# =============================================================================
# Tributary Area Computation
# =============================================================================

"""
    compute_cell_tributaries!(struc::BuildingStructure)

Compute tributary polygons for all cells, using CellGroups to avoid redundant work.
Results are stored in `cell.tributary`.
"""
function compute_cell_tributaries!(struc::BuildingStructure)
    # Ensure cell groups exist
    isempty(struc.cell_groups) && build_cell_groups!(struc)

    for cg in values(struc.cell_groups)
        # Compute once for canonical cell
        canonical_idx = first(cg.cell_indices)
        canonical_cell = struc.cells[canonical_idx]
        
        trib = _compute_cell_tributary(struc, canonical_cell)
        
        # Apply to all cells in group
        for c_idx in cg.cell_indices
            struc.cells[c_idx].tributary = trib
        end
    end
end

"""
Compute tributary polygons for a single cell using straight skeleton algorithm.
Returns Vector{TributaryPolygon}, one per edge.
"""
function _compute_cell_tributary(struc::BuildingStructure, cell::Cell)::Vector{TributaryPolygon}
    skel = struc.skeleton
    edge_ids = skel.face_edge_indices[cell.face_idx]
    vert_indices = skel.face_vertex_indices[cell.face_idx]
    vertices = [skel.vertices[i] for i in vert_indices]
    
    # Use straight skeleton algorithm (DCEL-based)
    results = StructuralSizer.get_tributary_polygons_isotropic_dcel(vertices)
    
    # Convert TributaryResult → TributaryPolygon with correct edge indices
    return [TributaryPolygon(edge_ids[r.edge_idx], r.vertices, r.area, r.fraction) 
            for r in results]
end

function _resolve_slab_group_id(slab_group_ids, idx::Int; tag::Symbol)
    isnothing(slab_group_ids) && return nothing
    length(slab_group_ids) >= idx || throw(ArgumentError("slab_group_ids too short: need at least $idx entries for $tag indexing"))
    v = slab_group_ids[idx]
    v === nothing && return nothing
    return UInt64(v)
end

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
Pick the `span` passed into `size_floor(ft, span, ...)`.

- Default: short span (`min(span_x, span_y)`)
- Two-way/plate/PT/waffle ACI thickness rules: long span (`max(span_x, span_y)`)
"""
_sizing_span(::AbstractFloorSystem, span_x, span_y) = min(span_x, span_y)

# ACI two-way / plate / waffle / PT thickness rules are based on the long span.
_sizing_span(::TwoWay, span_x, span_y) = max(span_x, span_y)
_sizing_span(::FlatPlate, span_x, span_y) = max(span_x, span_y)
_sizing_span(::FlatSlab, span_x, span_y) = max(span_x, span_y)
_sizing_span(::PTBanded, span_x, span_y) = max(span_x, span_y)
_sizing_span(::Waffle, span_x, span_y) = max(span_x, span_y)

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

# --- Vault geometry guard ---
function _assert_rectangular_slab_face(struc::BuildingStructure, face_idx::Int; tol=1e-8)
    skel = struc.skeleton
    poly = skel.faces[face_idx]
    pts = Meshes.vertices(poly)

    length(pts) == 4 || throw(ArgumentError("Vault requires a rectangular face (4 vertices); face $face_idx has $(length(pts)) vertices."))

    cs = Meshes.coords.(pts)
    vs = [(cs[2].x - cs[1].x, cs[2].y - cs[1].y),
          (cs[3].x - cs[2].x, cs[3].y - cs[2].y),
          (cs[4].x - cs[3].x, cs[4].y - cs[3].y),
          (cs[1].x - cs[4].x, cs[1].y - cs[4].y)]

    norms = [sqrt(v[1]^2 + v[2]^2) for v in vs]
    # `norms` carries length units (Unitful); interpret `tol` in the same length unit.
    # (Default `tol=1e-8` means ~1e-8 of the coordinate length unit, typically meters.)
    norm_unit = unit(first(norms))
    tol_len = tol * norm_unit
    all(n -> n > tol_len, norms) || throw(ArgumentError("Vault face $face_idx is degenerate (zero-length edge)."))

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
Build kwargs for size_floor with type-specific defaults.
"""
function _build_floor_kwargs(ft::AbstractFloorSystem, span, user_kwargs::NamedTuple)
    defaults = _default_floor_kwargs(ft, span, user_kwargs)
    return merge(defaults, user_kwargs)
end

# Default: no extra kwargs needed
_default_floor_kwargs(::AbstractFloorSystem, span, user_kwargs::NamedTuple) = NamedTuple()

# Vault: default lambda = 10 (span/rise = 10) unless user provides rise or lambda
function _default_floor_kwargs(::Vault, span, user_kwargs::NamedTuple)
    # Only add lambda if user hasn't provided rise or lambda
    has_rise = haskey(user_kwargs, :rise) && !isnothing(user_kwargs.rise)
    has_lambda = haskey(user_kwargs, :lambda) && !isnothing(user_kwargs.lambda)

    # If caller passes `options=FloorOptions(...)`, respect vault rise/lambda there too.
    has_options_lambda = false
    has_options_rise = false
    if haskey(user_kwargs, :options) && user_kwargs.options isa StructuralSizer.FloorOptions
        vopt = user_kwargs.options.vault
        has_options_lambda = !isnothing(vopt.lambda)
        has_options_rise = vopt.rise !== nothing
    end
    
    if !has_rise && !has_lambda && !has_options_lambda && !has_options_rise
        return (lambda=10.0,)
    end
    return NamedTuple()
end
