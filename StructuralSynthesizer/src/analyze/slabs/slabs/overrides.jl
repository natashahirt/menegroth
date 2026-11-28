# =============================================================================
# Initialization Helpers
# =============================================================================

"""
Resolve scoped floor overrides into explicit cell groupings and per-cell floor option overrides.

- Each scoped override forms one physical slab group (all matched cells).
- Unmatched cells stay in the baseline grouping (`resolved_groupings` from
  `_resolve_cell_groupings`), with matched cells removed. A flat plate stays
  one slab per floor. `nothing` means one slab per cell.
- Last override wins for overlapping cells.
"""
function _resolve_scoped_floor_overrides(struc::BuildingStructure,
                                        scoped_overrides::Vector{ScopedFloorOverride},
                                        baseline_groupings)
    n_cells = length(struc.cells)
    owner = fill(0, n_cells)
    cell_floor_types = Vector{Union{Nothing, Symbol}}(undef, n_cells)
    fill!(cell_floor_types, nothing)
    cell_floor_opts = Vector{Any}(undef, n_cells)
    fill!(cell_floor_opts, nothing)
    cell_floor_mats = Vector{Union{Nothing, Concrete}}(undef, n_cells)
    fill!(cell_floor_mats, nothing)

    for (ov_idx, ov) in enumerate(scoped_overrides)
        matched = _match_override_cells(struc, ov)
        isempty(matched) && throw(ArgumentError("Scoped override $ov_idx did not match any slab cells."))

        ov_opts = _scoped_override_floor_opts(ov)
        for c_idx in matched
            owner[c_idx] = ov_idx
            cell_floor_types[c_idx] = ov.floor_type
            cell_floor_opts[c_idx] = ov_opts
            cell_floor_mats[c_idx] = ov.concrete
        end
    end

    override_groups = Dict{Int, Vector{Int}}()
    for c_idx in eachindex(owner)
        struc.cells[c_idx].floor_type == :grade && continue
        oid = owner[c_idx]
        oid > 0 || continue
        push!(get!(override_groups, oid, Int[]), c_idx)
    end

    resolved_groupings = Vector{Vector{Int}}()
    slab_group_ids = Vector{Union{Nothing, UInt64}}(undef, n_cells)
    fill!(slab_group_ids, nothing)

    for oid in sort(collect(keys(override_groups)))
        cells = sort(unique(override_groups[oid]))
        isempty(cells) && continue
        gid = UInt64(hash((:scoped_floor_override, oid)))
        for c_idx in cells
            slab_group_ids[c_idx] = gid
        end
        push!(resolved_groupings, cells)
    end

    # Cells the override did not claim keep the baseline floor grouping, so a
    # flat plate remains one slab per floor instead of one slab per cell.
    if baseline_groupings === nothing
        for c_idx in 1:n_cells
            struc.cells[c_idx].floor_type == :grade && continue
            owner[c_idx] > 0 && continue
            push!(resolved_groupings, [c_idx])
        end
    else
        for group in baseline_groupings
            left = Int[]
            for c_idx in group
                struc.cells[c_idx].floor_type == :grade && continue
                owner[c_idx] > 0 && continue
                push!(left, c_idx)
            end
            isempty(left) && continue
            push!(resolved_groupings, left)
        end
    end

    return resolved_groupings, slab_group_ids, cell_floor_types, cell_floor_opts, cell_floor_mats
end

"""
Point every cell that has an explicit span direction at that direction.

A direction `tributary_axis` applies to every non-grade cell. A
`ScopedFloorOverride.span_axis` then replaces it on the cells that override
matches. Both recompute `SpanInfo` along the direction and record it in
`TributaryCache.cell_axes`, which load routing reads. `:isotropic` and
`nothing` do not set a direction.
"""
function _apply_explicit_span_axes!(struc::BuildingStructure, tributary_axis, overrides)
    empty!(struc._tributary_caches.cell_axes)
    axis = _direction_axis(tributary_axis)
    if axis !== nothing
        for cell_idx in eachindex(struc.cells)
            _set_cell_span_direction!(struc, cell_idx, axis)
        end
    end
    for ov in overrides
        d = _direction_axis(ov.span_axis)
        d === nothing && continue
        for cell_idx in _match_override_cells(struc, ov)
            _set_cell_span_direction!(struc, cell_idx, d)
        end
    end
    return struc
end

"""Recompute one cell's spans along `axis` and record the direction."""
function _set_cell_span_direction!(struc, cell_idx, axis)
    cell = struc.cells[cell_idx]
    cell.floor_type == :grade && return nothing
    ax = _direction_axis(axis)
    ax === nothing && return nothing
    n = hypot(ax[1], ax[2])
    ax = (ax[1] / n, ax[2] / n)
    cell.spans = get_cell_spans(struc.skeleton, cell.face_idx; axis=ax)
    struc._tributary_caches.cell_axes[cell_idx] = cell.spans.axis
    return ax
end

"""Build typed floor options for a scoped override."""
function _scoped_override_floor_opts(ov::ScopedFloorOverride)
    method = _resolve_analysis_method(ov.method, ov.target_edge_m)
    defl = _resolve_scoped_deflection_limit(ov.deflection_limit)
    punch = _resolve_scoped_punching_strategy(ov.punching_strategy)

    if ov.floor_type == :vault
        return StructuralSizer.VaultOptions(lambda=something(ov.vault_lambda, DEFAULT_VAULT_LAMBDA))
    elseif ov.floor_type == :flat_plate
        return StructuralSizer.FlatPlateOptions(
            method=method, deflection_limit=defl, punching_strategy=punch)
    elseif ov.floor_type == :flat_slab
        return StructuralSizer.FlatSlabOptions(
            base=StructuralSizer.FlatPlateOptions(
                method=method, deflection_limit=defl, punching_strategy=punch))
    elseif ov.floor_type == :one_way
        return StructuralSizer.OneWayOptions()
    elseif ov.floor_type == :two_way
        return StructuralSizer.TwoWayOptions()
    end
    return nothing
end

"""Resolve analysis method for scoped overrides."""
function _resolve_analysis_method(method::String, target_edge_m::Union{Nothing, Float64}=nothing)
    s = uppercase(strip(method))
    if s == "FEA"
        te = isnothing(target_edge_m) ? nothing : target_edge_m * u"m"
        return StructuralSizer.FEA(target_edge=te)
    elseif s == "DDM"
        return StructuralSizer.DDM()
    elseif s == "DDM_SIMPLIFIED"
        return StructuralSizer.DDM(:simplified)
    elseif s == "EFM"
        return StructuralSizer.EFM()
    elseif s == "EFM_HARDY_CROSS"
        return StructuralSizer.EFM(solver=:hardy_cross)
    end
    @warn "Unknown scoped override analysis_method '$method' — defaulting to DDM"
    return StructuralSizer.DDM()
end

"""Resolve deflection limit for scoped overrides."""
function _resolve_scoped_deflection_limit(s::String)
    key = uppercase(strip(s))
    if key == "L_240"
        return :L_240
    elseif key == "L_360"
        return :L_360
    elseif key == "L_480"
        return :L_480
    end
    @warn "Unknown scoped override deflection_limit '$s' — defaulting to L_360"
    return :L_360
end

"""Resolve punching strategy for scoped overrides."""
function _resolve_scoped_punching_strategy(s::String)
    key = lowercase(strip(s))
    if key == "grow_columns"
        return :grow_columns
    elseif key == "reinforce_last"
        return :reinforce_last
    elseif key == "reinforce_first"
        return :reinforce_first
    end
    @warn "Unknown scoped override punching_strategy '$s' — defaulting to grow_columns"
    return :grow_columns
end

"""Match scoped override selector polygons to slab cells via face centroid-in-polygon tests."""
function _match_override_cells(struc::BuildingStructure, ov::ScopedFloorOverride)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords

    face_to_story = Dict{Int, Int}()
    for (story_idx, story) in skel.stories
        for face_idx in story.faces
            face_to_story[face_idx] = story_idx
        end
    end

    matched = Set{Int}()
    for poly in ov.faces
        length(poly) >= 3 || continue
        z = poly[1][3]
        story_idx = _nearest_story_idx(skel, z)
        poly_xy = [(p[1], p[2]) for p in poly]

        for (cell_idx, cell) in enumerate(struc.cells)
            cell.floor_type == :grade && continue
            get(face_to_story, cell.face_idx, typemin(Int)) == story_idx || continue

            vis = skel.face_vertex_indices[cell.face_idx]
            cx = sum(vc[vi, 1] for vi in vis) / length(vis)
            cy = sum(vc[vi, 2] for vi in vis) / length(vis)
            _point_in_polygon_cells_2d(cx, cy, poly_xy) && push!(matched, cell_idx)
        end
    end

    return sort(collect(matched))
end

"""Find nearest story index to the provided Z coordinate (meters)."""
function _nearest_story_idx(skel::BuildingSkeleton, z::Float64)
    best_story = 0
    best_dist = Inf
    for (i, sz) in enumerate(skel.stories_z)
        d = abs(ustrip(sz) - z)
        if d < best_dist
            best_dist = d
            best_story = i - 1
        end
    end
    return best_story
end

"""2D point-in-polygon test with boundary-inclusive tolerance."""
function _point_in_polygon_cells_2d(x::Float64, y::Float64, poly::Vector{Tuple{Float64, Float64}})
    n = length(poly)
    n < 3 && return false

    inside = false
    j = n
    for i in 1:n
        xi, yi = poly[i]
        xj, yj = poly[j]

        if _point_on_segment_cells_2d(x, y, xi, yi, xj, yj)
            return true
        end

        intersects = ((yi > y) != (yj > y)) &&
                     (x < (xj - xi) * (y - yi) / (yj - yi + 1e-16) + xi)
        inside = intersects ? !inside : inside
        j = i
    end
    return inside
end

"""Boundary check helper for point-in-polygon."""
function _point_on_segment_cells_2d(px, py, x1, y1, x2, y2; tol=1e-8)
    dx = x2 - x1
    dy = y2 - y1
    seg_len_sq = dx^2 + dy^2
    seg_len_sq <= tol^2 && return hypot(px - x1, py - y1) <= tol

    t = ((px - x1) * dx + (py - y1) * dy) / seg_len_sq
    (t < -tol || t > 1 + tol) && return false

    qx = x1 + clamp(t, 0.0, 1.0) * dx
    qy = y1 + clamp(t, 0.0, 1.0) * dy
    return hypot(px - qx, py - qy) <= tol
end

"""Build per-slab specification tuples from cells and grouping options."""
