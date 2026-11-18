"""A `(x, y)` direction, or `nothing` for `:isotropic` and other non-directions."""
function _direction_axis(tax)
    tax isa NTuple{2, <:Real} || return nothing
    ax = (Float64(tax[1]), Float64(tax[2]))
    return hypot(ax...) < 1e-12 ? nothing : ax
end

function _build_slab_specs(struc, floor_type, cell_groupings, slab_group_ids;
                           cell_floor_types=nothing, cell_floor_opts=nothing, cell_floor_mats=nothing,
                           span_axis=nothing)
    slab_specs = NamedTuple[]

    if isnothing(cell_groupings)
        # Default: 1 slab per cell
        span_cache = Dict{Any, StructuralSizer.SpanInfo{Float64}}()
        for (cell_idx, cell) in enumerate(struc.cells)
            # Skip grade cells (ground floor doesn't need slab design)
            cell.floor_type == :grade && continue
            
            spans = cell.spans
            axis = _direction_axis(span_axis)
            ft_override = isnothing(cell_floor_types) ? nothing : cell_floor_types[cell_idx]
            # A direction forces one-way along that axis (ACI 318-19 R8.3.1.2
            # is the automatic rule when no direction is given). An explicit
            # floor type is left as given.
            if axis !== nothing && isnothing(ft_override) && floor_type == :auto
                spans = get_cell_spans(struc.skeleton, cell.face_idx; axis=axis, cache=span_cache)
                cell.spans = spans
            end
            ft_sym = isnothing(ft_override) ?
                (floor_type == :auto ? infer_floor_type(spans.primary, spans.secondary; axis=axis) : floor_type) :
                ft_override
            opts_override = isnothing(cell_floor_opts) ? nothing : cell_floor_opts[cell_idx]
            mat_override = isnothing(cell_floor_mats) ? nothing : cell_floor_mats[cell_idx]
            gid = _resolve_slab_group_id(slab_group_ids, cell_idx; tag=:cell)

            push!(slab_specs, (; cell_indices=[cell_idx],
                              spans_gov=spans,
                              sdl_gov=cell.sdl, live_gov=cell.live_load,
                              floor_type=ft_sym,
                              floor_opts_override=opts_override,
                              material_override=mat_override,
                              group_id=gid))
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

            # A grouped slab spans several cells, so no per-cell inference applies.
            ft_overrides = if isnothing(cell_floor_types)
                Symbol[]
            else
                unique(Symbol[x for x in (cell_floor_types[i] for i in filtered_indices) if !isnothing(x)])
            end
            length(ft_overrides) <= 1 ||
                throw(ArgumentError("Scoped overrides assign mixed floor types within one slab group: $ft_overrides"))
            if isempty(ft_overrides) && floor_type == :auto
                throw(ArgumentError(
                    "cells $filtered_indices are grouped into one slab, but floor_type is :auto. " *
                    "A grouped slab needs an explicit floor_type (e.g. :flat_plate)."))
            end
            ft_sym = isempty(ft_overrides) ? floor_type : only(ft_overrides)

            opts_overrides = if isnothing(cell_floor_opts)
                Any[]
            else
                unique([x for x in (cell_floor_opts[i] for i in filtered_indices) if !isnothing(x)])
            end
            length(opts_overrides) <= 1 ||
                throw(ArgumentError("Scoped overrides assign mixed floor options within one slab group."))
            opts_override = isempty(opts_overrides) ? nothing : only(opts_overrides)

            mat_overrides = if isnothing(cell_floor_mats)
                Concrete[]
            else
                unique([x for x in (cell_floor_mats[i] for i in filtered_indices) if !isnothing(x)])
            end
            length(mat_overrides) <= 1 ||
                throw(ArgumentError("Scoped overrides assign mixed floor materials within one slab group."))
            mat_override = isempty(mat_overrides) ? nothing : only(mat_overrides)

            # Group id: must be consistent across all cells participating in this physical slab
            gid = _resolve_group_id_for_cell_set(slab_group_ids, filtered_indices)

            push!(slab_specs, (; cell_indices=filtered_indices,
                              spans_gov=spans_gov,
                              sdl_gov=sdl_gov, live_gov=live_gov,
                              floor_type=ft_sym,
                              floor_opts_override=opts_override,
                              material_override=mat_override,
                              group_id=gid))
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
