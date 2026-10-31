"""
    _visualization_strip_along_x(struc, supp_indices) -> Bool

Whether a strip footing’s long axis runs along global X for viz/API.

Uses the same `_support_strip_axes` contract as design (deci-311bd2d0): SI-ulp
tie on Δx/Δy (not a construction tolerance) sizes both axes; unique longer
span maps to `:x` or `:y`. Named `c1` remains ∥ global X.

- `[:x]` → `true`
- `[:y]` → `false`
- `[:x, :y]` (tie) → `false` — do **not** silently prefer X via `Δx >= Δy`.
  Design keeps `_governing_strip_result`; governing `strip_axis` is not stored
  on `StripFootingResult`, so a :x-governing tie cannot be recovered here
  without re-sizing.
"""
function _visualization_strip_along_x(struc, supp_indices::Vector{Int})
    axes = _support_strip_axes(struc, supp_indices)
    return length(axes) == 1 && axes[1] === :x
end

"""Serialize foundation blocks for visualization in sized/original modes."""
function _serialize_visualization_foundations(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits)
    skel = struc.skeleton
    out = APIVisualizationFoundation[]

    # Use offsets captured at design time (survives restore!)
    col_offset_by_vertex = design.structural_offsets

    fdn_params = design.params.foundation_options
    fdn_mat_color = if !isnothing(fdn_params)
        _material_color_hex(fdn_params.concrete)
    else
        ""
    end

    for (fdn_idx, fdn) in enumerate(struc.foundations)
        fdn_result = get(design.foundations, fdn_idx, nothing)
        isnothing(fdn_result) && continue
        isempty(fdn.support_indices) && continue

        xs = Float64[]
        ys = Float64[]
        zs = Float64[]
        for sup_idx in fdn.support_indices
            sup_idx > length(struc.supports) && continue
            v_idx = struc.supports[sup_idx].vertex_idx
            v_idx > length(skel.vertices) && continue
            c = Meshes.coords(skel.vertices[v_idx])
            off = get(col_offset_by_vertex, v_idx, nothing)
            x_disp = _to_display_length(du, c.x + (isnothing(off) ? 0.0u"m" : off[1] * u"m"))
            y_disp = _to_display_length(du, c.y + (isnothing(off) ? 0.0u"m" : off[2] * u"m"))
            push!(xs, x_disp)
            push!(ys, y_disp)
            push!(zs, _to_display_length(du, c.z))
            @debug "Foundation $fdn_idx support" sup_idx v_idx x_disp y_disp off
        end
        isempty(xs) && continue

        cx = sum(xs) / length(xs)
        cy = sum(ys) / length(ys)
        z_top = minimum(zs)

        # Strip orientation: same `_support_strip_axes` rule as design (not display Δx >= Δy).
        strip_along_x = fdn.foundation_type == :strip && length(fdn.support_indices) >= 2 &&
            _visualization_strip_along_x(struc, collect(Int, fdn.support_indices))

        @debug "Foundation $fdn_idx center" type=fdn.foundation_type support_count=length(fdn.support_indices) cx cy z_top strip_along_x xs ys

        push!(out, APIVisualizationFoundation(
            foundation_id = fdn_idx,
            center = [_round_val(cx; digits=6), _round_val(cy; digits=6), _round_val(z_top; digits=6)],
            length = _round_val(_to_display_length(du, fdn_result.length); digits=4),
            width = _round_val(_to_display_length(du, fdn_result.width); digits=4),
            depth = _round_val(_to_display_length(du, fdn_result.depth); digits=4),
            utilization_ratio = _round_val(fdn_result.bearing_ratio),
            material_color_hex = fdn_mat_color,
            ok = fdn_result.ok,
            along_x = strip_along_x,
        ))
    end

    return out
end

"""Serialize drop panel footprint patches for slab visualization, trimmed to slab boundary."""
function _serialize_drop_panel_patches(slab_idx::Int, slab, struc::BuildingStructure, design::BuildingDesign, du::DisplayUnits)
    slab_result = get(design.slabs, slab_idx, nothing)
    dp = isnothing(slab_result) ? nothing : slab_result.drop_panel
    isnothing(dp) && return APIDropPanelPatch[]
    h_drop_ft = _to_display_length(du, dp.h_drop)
    h_drop_ft <= 0 && return APIDropPanelPatch[]

    a1_half_ft = _to_display_length(du, dp.a_drop_1)
    a2_half_ft = _to_display_length(du, dp.a_drop_2)

    # Slab bounding box in display units for edge trimming
    skel = struc.skeleton
    slab_xmin = slab_ymin =  Inf
    slab_xmax = slab_ymax = -Inf
    for ci in slab.cell_indices
        cell = struc.cells[ci]
        for vi in skel.face_vertex_indices[cell.face_idx]
            pt = Meshes.coords(skel.vertices[vi])
            x = _to_display_length(du, pt.x)
            y = _to_display_length(du, pt.y)
            x < slab_xmin && (slab_xmin = x)
            x > slab_xmax && (slab_xmax = x)
            y < slab_ymin && (slab_ymin = y)
            y > slab_ymax && (slab_ymax = y)
        end
    end

    centers = Set{Int}()
    slab_cells = Set(slab.cell_indices)
    for (col_idx, col) in enumerate(struc.columns)
        if !isempty(intersect(col.tributary_cell_indices, slab_cells))
            push!(centers, col_idx)
        end
    end

    if isempty(centers)
        slab_result = get(design.slabs, slab_idx, nothing)
        if !isnothing(slab_result) && hasproperty(slab_result, :punching_check)
            pc = getproperty(slab_result, :punching_check)
            if hasproperty(pc, :details)
                for (col_idx, _) in getproperty(pc, :details)
                    if col_idx isa Integer && 1 <= col_idx <= length(struc.columns)
                        push!(centers, Int(col_idx))
                    end
                end
            end
        end
    end

    patches = APIDropPanelPatch[]
    for col_idx in centers
        col = struc.columns[col_idx]
        v_idx = col.vertex_idx
        (v_idx < 1 || v_idx > length(skel.vertices)) && continue
        c = Meshes.coords(skel.vertices[v_idx])
        off = get(design.structural_offsets, v_idx, (0.0, 0.0))
        cx = _to_display_length(du, c.x + off[1] * u"m")
        cy = _to_display_length(du, c.y + off[2] * u"m")
        cz = _to_display_length(du, c.z)

        # Clamp drop panel rectangle to slab boundary
        x0 = max(cx - a1_half_ft, slab_xmin)
        x1 = min(cx + a1_half_ft, slab_xmax)
        y0 = max(cy - a2_half_ft, slab_ymin)
        y1 = min(cy + a2_half_ft, slab_ymax)
        eff_len = x1 - x0
        eff_wid = y1 - y0
        (eff_len <= 0 || eff_wid <= 0) && continue
        new_cx = (x0 + x1) / 2.0
        new_cy = (y0 + y1) / 2.0

        push!(patches, APIDropPanelPatch(
            center = [_round_val(new_cx; digits=6), _round_val(new_cy; digits=6), _round_val(cz; digits=6)],
            length = _round_val(eff_len; digits=4),
            width = _round_val(eff_wid; digits=4),
            extra_depth = _round_val(h_drop_ft; digits=4),
        ))
    end

    return patches
end

"""Compute average frame element length in display units for displacement scale calibration."""
function _compute_avg_element_length(model, du::DisplayUnits)
    isempty(model.frame_elements) && return 1.0
    total_length = sum(_to_display_length(du, elem.length) for elem in model.frame_elements)
    return total_length / length(model.frame_elements)
end

"""Compute the 2D convex hull of `points` via Graham scan."""
function _convex_hull_2d(points::Vector{NTuple{2, Float64}})
    length(points) <= 3 && return points
    
    # Sort by x, then y
    sorted = sort(points)
    
    # Lower hull
    lower = NTuple{2, Float64}[]
    for p in sorted
        while length(lower) >= 2 && _cross_product(lower[end-1], lower[end], p) <= 0
            pop!(lower)
        end
        push!(lower, p)
    end
    
    # Upper hull
    upper = NTuple{2, Float64}[]
    for p in reverse(sorted)
        while length(upper) >= 2 && _cross_product(upper[end-1], upper[end], p) <= 0
            pop!(upper)
        end
        push!(upper, p)
    end
    
    # Remove duplicates at ends
    pop!(lower)
    pop!(upper)
    
    return vcat(lower, upper)
end

"""2D cross product `(a - o) × (b - o)` for convex hull orientation tests."""
function _cross_product(o::NTuple{2, Float64}, a::NTuple{2, Float64}, b::NTuple{2, Float64})
    return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
end
