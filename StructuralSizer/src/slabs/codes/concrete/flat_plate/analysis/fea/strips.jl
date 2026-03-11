# =============================================================================
# Geometry-Agnostic Strip Classification
# =============================================================================

"""
    _build_cs_polygons_abs(cell_poly; span_axis=nothing, rebar_axis=nothing,
                           drop_panel_half_widths=nothing)
        -> Vector{Vector{NTuple{2,Float64}}}

Compute column-strip polygons in absolute (x, y) coordinates for a cell.

Uses the skeleton-derived tributary polygons and ACI half-depth rule:
- `get_tributary_polygons_isotropic(verts)` → straight-skeleton tributaries
- `compute_panel_strips(tribs)` → column / middle strip split at d_max/2

When `rebar_axis` is provided, the tributary partitioning is **directed**
along the rebar axis using `get_tributary_polygons(verts; axis=rebar_axis)`.
This ensures the CS/MS classification is aligned with the reinforcement
direction, which is essential for consistent moment projection when
`rebar_direction` is set.

When `span_axis` (or `rebar_axis`) is provided, only CS polygons whose edge
is approximately **perpendicular** to that axis are returned.  This matches
the ACI definition: for a given direction, the column strip is the band
centered on the column line (which runs transverse to that direction).

## Drop Panel Widening (Pacoste §4.2.1, Fig 4.4)

When `drop_panel_half_widths` is provided as `(w_span, w_perp)` in meters,
the column strip polygon is widened so its transverse extent is at least
the drop panel half-extent in the perpendicular direction.  This ensures
the distribution width covers the stiffened drop panel zone.

The minimum CS half-width becomes `max(d_max/2, drop_panel_half_width)`,
where `d_max/2` is the standard ACI rule and `drop_panel_half_width` is
the drop panel half-extent perpendicular to the span.

Returns a vector of absolute-coordinate polygons.
"""
function _build_cs_polygons_abs(cell_poly::Vector{NTuple{2,Float64}};
                                span_axis::Union{Nothing, NTuple{2,Float64}} = nothing,
                                rebar_axis::Union{Nothing, NTuple{2,Float64}} = nothing,
                                drop_panel_half_widths::Union{Nothing, NTuple{2,Float64}} = nothing)
    n_verts = length(cell_poly)
    n_verts < 3 && return Vector{NTuple{2,Float64}}[]

    mesh_pts = [Meshes.Point(v[1], v[2]) for v in cell_poly]

    # Use directed partitioning when rebar_axis is set, otherwise isotropic
    tribs = if !isnothing(rebar_axis)
        get_tributary_polygons(mesh_pts; axis=collect(rebar_axis))
    else
        get_tributary_polygons_isotropic(mesh_pts)
    end

    # When a drop panel is present, widen the column strips to cover the
    # drop panel zone.  Pacoste §4.2.1 point 2 / Fig 4.4: the distribution
    # width must encompass the drop panel, with θ ≥ 30° from drop edge.
    # ACI 318-14 §8.4.1.5 already uses l₂/4 column strip; we enforce that
    # the strip is at least as wide as the drop panel half-extent.
    if !isnothing(drop_panel_half_widths)
        tribs = _widen_tributaries_for_drop(tribs, drop_panel_half_widths, span_axis)
    end

    strips = compute_panel_strips(tribs)

    # Perpendicularity filter always uses span_axis (identifies column lines).
    # The rebar_axis only affects tributary partitioning, not edge selection.
    # When rebar_axis is set but span_axis is not, skip the filter entirely —
    # the directed partitioning already handles the geometry correctly.
    filter_axis = span_axis

    cs_polys = Vector{NTuple{2,Float64}}[]
    for cs in strips.column_strips
        isempty(cs.s) && continue
        idx = cs.local_edge_idx
        beam_start = cell_poly[idx]
        beam_end   = cell_poly[mod1(idx + 1, n_verts)]

        # Filter: keep only edges approximately perpendicular to the span axis.
        # This identifies column lines (transverse to span direction).
        if !isnothing(filter_axis)
            ex = beam_end[1] - beam_start[1]
            ey = beam_end[2] - beam_start[2]
            elen = hypot(ex, ey)
            if elen > 1e-9
                cos_angle = abs(ex * filter_axis[1] + ey * filter_axis[2]) / elen
                cos_angle > 0.5 && continue
            end
        end

        abs_verts = vertices(cs, beam_start, beam_end)
        isempty(abs_verts) && continue
        push!(cs_polys, abs_verts)
    end
    return cs_polys
end

"""
    _widen_tributaries_for_drop(tribs, drop_half_widths, span_axis) -> Vector{TributaryPolygon}

Widen tributary polygons so that `d_max/2` (the column strip half-width) is
at least the drop panel half-extent in the perpendicular direction.

For each tributary whose beam edge is approximately perpendicular to the span
axis (i.e., a column-line edge), the relevant drop panel half-width is the
perpendicular-to-span dimension (`drop_half_widths[2]`).  For edges parallel
to the span axis, it's `drop_half_widths[1]`.

The widening is achieved by scaling the `d` values so that `d_max/2 ≥ w_drop`.
This means `d_max ≥ 2 * w_drop`, so we scale: `d_new = d * max(1, 2*w_drop/d_max)`.

Pacoste et al. (2012) §4.2.1 point 2, Fig 4.4.
"""
function _widen_tributaries_for_drop(
    tribs::Vector{<:Asap.TributaryPolygon},
    drop_half_widths::NTuple{2, Float64},
    span_axis::Union{Nothing, NTuple{2, Float64}},
)
    w_span, w_perp = drop_half_widths  # half-extents in span and perp directions

    out = similar(tribs)
    for (i, trib) in enumerate(tribs)
        d_max = isempty(trib.d) ? 0.0 : maximum(trib.d)
        if d_max < 1e-9
            out[i] = trib
            continue
        end

        # Determine which drop panel half-width applies to this edge.
        # Edges perpendicular to span axis → column lines → use w_perp.
        # Edges parallel to span axis → use w_span.
        # Without span_axis, use the larger of the two (conservative).
        w_drop = max(w_span, w_perp)  # fallback: conservative
        if !isnothing(span_axis)
            # Check edge orientation vs span_axis using the tributary's
            # beam-edge direction (s=0 to s=1 runs along the edge).
            # For a tributary, the beam edge is the cell edge it belongs to.
            # The d values are perpendicular to this edge.
            # If the edge is ⊥ to span → this is a column line → use w_perp
            # If the edge is ∥ to span → this is a span edge → use w_span
            # We approximate by checking the first/last s,d points.
            # Since s runs along the edge and d is perpendicular, the edge
            # direction is encoded in the tributary's local_edge_idx.
            # For simplicity, we use the conservative max (both directions).
            # The perpendicularity filter in _build_cs_polygons_abs already
            # selects only the relevant edges for negative moments.
            w_drop = max(w_span, w_perp)
        end

        # Column strip half-width = d_max/2.
        # We need d_max/2 ≥ w_drop, i.e., d_max ≥ 2*w_drop.
        min_d_max = 2.0 * w_drop
        if d_max >= min_d_max
            out[i] = trib
        else
            # Scale d values uniformly so d_max reaches min_d_max.
            # This preserves the shape of the tributary while widening it.
            scale = min_d_max / d_max
            # Pacoste §4.2.1 point 1: δ = m_av/m_max ≥ 0.6.
            # A large scale factor means the strip is much wider than the
            # standard ACI half-depth rule, increasing the risk that the
            # averaged moment drops below 60% of the peak.
            if scale > 1.5
                @debug "Drop panel widening: tributary $(trib.local_edge_idx) " *
                       "scaled by $(round(scale, digits=2))×. " *
                       "Verify m_av/m_max ≥ 0.6 (Pacoste §4.2.1)."
            end
            new_d = trib.d .* scale
            new_cell_depths = isempty(trib.cell_depths) ? trib.cell_depths : trib.cell_depths .* scale
            out[i] = Asap.TributaryPolygon(
                trib.local_edge_idx, trib.s, new_d,
                trib.area * scale, trib.fraction,
                trib.cell_depths_s, new_cell_depths,
                trib.l2_stiff * scale,
                trib.cell_depth_max * scale,
                trib.cell_depth_s_max,
            )
        end
    end
    return out
end

"""
    _drop_panel_half_widths_m(drop_panel) -> NTuple{2, Float64}

Extract drop panel half-extents in meters as `(a_drop_1_m, a_drop_2_m)`.
Returns `nothing` if `drop_panel` is `nothing`.
"""
function _drop_panel_half_widths_m(dp::DropPanelGeometry)
    return (ustrip(u"m", dp.a_drop_1), ustrip(u"m", dp.a_drop_2))
end
"""Return `nothing` when no drop panel is present."""
_drop_panel_half_widths_m(::Nothing) = nothing

"""
    _point_in_simple_polygon_vec(pt, poly) -> Bool

Winding-number point-in-polygon test for arbitrary (possibly non-convex)
polygons.  `poly` is `Vector{NTuple{2,Float64}}`, `pt` is `(x, y)`.
"""
function _point_in_simple_polygon_vec(pt::NTuple{2,Float64},
                                       poly::Vector{NTuple{2,Float64}})
    n = length(poly)
    n < 3 && return false
    x, y = pt
    winding = 0
    @inbounds for i in 1:n
        j = mod1(i + 1, n)
        yi = poly[i][2]; yj = poly[j][2]
        if yi ≤ y
            if yj > y
                cross = (poly[j][1] - poly[i][1]) * (y - yi) -
                        (x - poly[i][1]) * (yj - yi)
                cross > 0 && (winding += 1)
            end
        else
            if yj ≤ y
                cross = (poly[j][1] - poly[i][1]) * (y - yi) -
                        (x - poly[i][1]) * (yj - yi)
                cross < 0 && (winding -= 1)
            end
        end
    end
    return winding != 0
end

"""
    _is_in_column_strip(px, py, cs_polys) -> Bool

Test whether point (px, py) falls inside any column-strip polygon.
Uses winding-number test (works for non-convex strip polygons).
"""
function _is_in_column_strip(px::Float64, py::Float64,
                              cs_polys::Vector{Vector{NTuple{2,Float64}}})
    for poly in cs_polys
        _point_in_simple_polygon_vec((px, py), poly) && return true
    end
    return false
end

"""
    _classify_triangles(element_data, tri_indices, cs_polys)
        -> (cs_indices, ms_indices)

Split a cell's triangle indices into column-strip and middle-strip subsets
using point-in-polygon classification against the column-strip polygons.
"""
function _classify_triangles(
    element_data::Vector{FEAElementData},
    tri_indices::Vector{Int},
    cs_polys::Vector{Vector{NTuple{2,Float64}}},
)
    cs_idx = Int[]
    ms_idx = Int[]
    @inbounds for k in tri_indices
        ed = element_data[k]
        if _is_in_column_strip(ed.cx, ed.cy, cs_polys)
            push!(cs_idx, k)
        else
            push!(ms_idx, k)
        end
    end
    return (cs_idx, ms_idx)
end
