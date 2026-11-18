# Cell and Slab initialization from skeleton faces

# =============================================================================
# Geometry Helpers
# =============================================================================

"""
    get_cell_spans(skel, face_idx; axis=nothing, plan_axis=(1.0, 0.0), cache=nothing) -> SpanInfo{T}

Compute SpanInfo for a skeleton face. Slab openings overlapping the face
([`face_opening_loops`](@ref)) are voids: no span crosses them.

## Arguments
- `skel`: BuildingSkeleton
- `face_idx`: Face index
- `axis`: Optional primary span direction as `(x, y)` tuple. If `nothing`, auto-detects
  the short axis.
- `plan_axis`: First plan axis of the building. Auto-detection compares the span
  along it with the span along it turned 90° counterclockwise and keeps the shorter
  (the first on a tie). `(1.0, 0.0)` leaves the choice to `SpanInfo`, which uses
  the face's orthogonal edge frame and falls back to global X/Y when the edges
  do not share one.
- `cache`: Optional `Dict` shared across calls. Faces with the same plan shape and
  openings (up to translation, see [`_span_shape_key`](@ref)) reuse one span calculation.

## Returns
- `SpanInfo{T}`: Span info with values in skeleton's length type (with units)
"""
function get_cell_spans(skel::BuildingSkeleton{T}, face_idx::Int; 
                        axis::Union{Nothing, NTuple{2,Float64}}=nothing,
                        plan_axis::NTuple{2, <:Real}=(1.0, 0.0),
                        cache::Union{Nothing, AbstractDict}=nothing) where T
    verts = [skel.vertices[i] for i in skel.face_vertex_indices[face_idx]]
    holes = face_opening_loops(skel, face_idx)
    e1 = unit_plan_axis(plan_axis)
    global_axes = isnothing(axis) && e1 == (1.0, 0.0)

    # Compute SpanInfo (returns Float64 in meters)
    function compute()
        (!isnothing(axis) || global_axes) &&
            return StructuralSizer.SpanInfo(verts; axis=axis, holes=holes)
        along_1 = StructuralSizer.SpanInfo(verts; axis=e1, holes=holes)
        along_2 = StructuralSizer.SpanInfo(verts; axis=(-e1[2], e1[1]), holes=holes)
        return along_1.primary <= along_2.primary ? along_1 : along_2
    end
    key_axis = global_axes || !isnothing(axis) ? axis : (:plan_axis, e1)
    si = cache === nothing ? compute() : get!(compute, cache, _span_shape_key(verts, key_axis, holes))
    
    # Convert to Quantity with meter units
    StructuralSizer.SpanInfo{T}(
        si.primary * u"m",
        si.secondary * u"m",
        si.axis,
        si.isotropic * u"m"
    )
end

"""
    _span_shape_key(verts, axis, holes=()) -> Tuple

Plan outline in micrometres, shifted so its lowest-left vertex is at the origin
and listed from that vertex, plus the opening outlines (meters) shifted by the
same amount, paired with `axis`. Spans depend only on shape, openings, and
direction, so repeated bays (every story of a typical floor) share one key.
"""
function _span_shape_key(verts, axis, holes=())
    µm(c) = round(Int, 1e6 * c)
    xy = [(µm(ustrip(u"m", Meshes.coords(v).x)), µm(ustrip(u"m", Meshes.coords(v).y))) for v in verts]
    k = argmin(xy)
    x0, y0 = xy[k]
    m = length(xy)
    shape = [(xy[mod1(k + i, m)][1] - x0, xy[mod1(k + i, m)][2] - y0) for i in 0:m-1]
    voids = [[(µm(p[1]) - x0, µm(p[2]) - y0) for p in h] for h in holes]
    return (shape, voids, axis)
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
    initialize_cells!(struc; loads=GravityLoads(), plan_axis=(1.0, 0.0))

Initialize cells from skeleton faces with service-level SDL and LL.
A face whose openings cover it gets no cell.

Loads are taken from the `GravityLoads` struct.  In the `design_building`
pipeline, `params.loads` is passed here automatically.

`plan_axis` is the building's first plan axis. Each cell's short span is
auto-detected along it or its perpendicular (see [`get_cell_spans`](@ref)), so a
grid rotated off global X/Y spans the same way as the unrotated grid.

See also: [`GravityLoads`](@ref), [`initialize!`](@ref)
"""
function initialize_cells!(struc::BuildingStructure{T, A, P};
                           loads::GravityLoads = GravityLoads(),
                           plan_axis::NTuple{2, <:Real} = (1.0, 0.0)) where {T, A, P}
    skel = struc.skeleton
    empty!(struc.cells)
    
    lmap = load_map(loads)   # [:grade => (LL, SDL), :floor => ..., :roof => ...]
    
    processed_faces = Set{Int}()
    span_cache = Dict{Any, StructuralSizer.SpanInfo{Float64}}()
    
    for (grp_name, (ll, sdl)) in lmap
        face_indices = get(skel.groups_faces, grp_name, Int[])
        
        for face_idx in face_indices
            face_idx in processed_faces && continue
            push!(processed_faces, face_idx)
            
            area_raw = face_net_area(skel, face_idx)
            # A face its openings fill is a void: no slab, no load, no sizing.
            ustrip(u"m^2", area_raw) <= OPENING_OVERLAP_TOL_M2 && continue
            area = convert(A, area_raw)   # ensure area matches BuildingStructure type A
            spans = get_cell_spans(skel, face_idx; plan_axis, cache=span_cache)
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
- `:building_wide`: Group all cells into one slab
- `Vector{Vector{Int}}`: Explicit cell index groupings

# Examples

```julia
# Use default from FlatPlateOptions (grouping = :by_floor)
initialize!(struc; floor_type = :flat_plate)

# Override to individual slabs per cell
initialize!(struc; floor_type = :flat_plate, cell_groupings = :individual)

# Explicit groupings (a grouped slab needs an explicit floor_type)
initialize!(struc; floor_type = :flat_plate, cell_groupings = [[1,2,3], [4,5,6]])
```

A slab whose floor type the building-wide `floor_opts` do not describe (an
inferred `:one_way` cell, or `floor_type = :vault` with the default flat-plate
options) is sized with that type's default options; see
[`_default_floor_options`](@ref).

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
                           slab_group_ids::Union{Nothing, AbstractVector}=nothing,
                           scoped_floor_overrides::Vector{ScopedFloorOverride}=ScopedFloorOverride[],
                           col_I_factor::Real = 0.70,  # ACI 318-11 §10.10.4.1
                           topping_span = nothing,
                           rib_bays = nothing,
                           joists_planned::Bool = false) where T
    empty!(struc.slabs)
    empty!(struc.slab_parallel_batches)
    
    # Clear stale cell groups and tributary cache
    empty!(struc.cell_groups)
    clear_geometry_caches!(struc)
    # Explicit span directions, before slab specs read `cell.spans`. A scoped
    # axis replaces the building direction on the cells it matches.
    _apply_explicit_span_axes!(struc, tributary_axis, scoped_floor_overrides)
    
    # Resolve cell_groupings to actual indices
    resolved_groupings = _resolve_cell_groupings(struc, cell_groupings, floor_type, floor_opts)
    effective_group_ids = slab_group_ids
    cell_floor_types = nothing
    cell_floor_opts = nothing
    cell_floor_mats = nothing

    if !isempty(scoped_floor_overrides)
        resolved_groupings, effective_group_ids, cell_floor_types, cell_floor_opts, cell_floor_mats =
            _resolve_scoped_floor_overrides(struc, scoped_floor_overrides, resolved_groupings)
    end
    
    # 1. Build per-slab "specs"
    slab_specs = _build_slab_specs(struc, floor_type, resolved_groupings, effective_group_ids;
                                   cell_floor_types=cell_floor_types,
                                   cell_floor_opts=cell_floor_opts,
                                   cell_floor_mats=cell_floor_mats,
                                   span_axis=tributary_axis)

    # 2. Assign fallback deterministic group IDs
    _assign_deterministic_group_ids!(slab_specs)
    # A :two_way panel with no beams is a flat plate. An interior gap throws.
    slab_specs = _apply_two_way_supports!(struc, slab_specs, floor_opts;
                                          joists_planned=joists_planned)

    # 3. Group specs by ID
    groups = _group_slab_specs(slab_specs)

    # 4. Size once per slab group
    group_results, group_sw, group_spans, group_material, group_toppings, group_opts = _size_slab_groups(
        groups, slab_specs, struc, material, floor_opts;
        col_I_factor=col_I_factor, topping_span=topping_span, rib_bays=rib_bays)

    # 5. Fan out results to cells and create Slab objects (with volumes)
    _apply_slab_results!(struc, slab_specs, group_results, group_sw, group_spans, group_material,
                         group_opts; group_toppings=group_toppings)

    # 6. Finalize grouping structure
    build_slab_groups!(struc)

    # 7. Compute tributary areas
    compute_cell_tributaries!(struc; floor_opts=floor_opts, tributary_axis=tributary_axis)

    @debug "Initialized $(length(struc.slabs)) slabs from $(length(struc.cells)) cells"
end

