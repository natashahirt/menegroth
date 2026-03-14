# =============================================================================
# Section Cuts — Line-Integral Moment Extraction via Isoparametric Mapping
# =============================================================================
#
# Defines section cuts as iso-ξ lines through a cell's isoparametric panel,
# then integrates the smoothed nodal moment field along each cut.
#
# The isoparametric mapping (reused from waffle/geometry.jl) maps any convex
# quadrilateral cell to a unit square [0,1]².  ξ runs along the span, η runs
# transverse.  Section cuts at constant ξ are lines perpendicular to the
# span in parametric space — they curve naturally for skewed/trapezoidal cells.
#
# For rectangular cells, iso-ξ cuts reduce to straight vertical lines
# (identical to the global-parallel-cuts approach).
#
# Key advantage over δ-band integration: no bandwidth parameter.  The cut
# is a true line integral through the smoothed field.
#
# =============================================================================

# =============================================================================
# Cell Panel Construction
# =============================================================================

"""
    CellPanel

An isoparametric panel for a cell, with column positions mapped to parametric
coordinates.  ξ runs along `span_axis`, η runs transverse.

For **quad cells** (4 vertices): uses `IsoParametricPanel` (bilinear, exact).
For **N-gon cells** (N ≠ 4): uses `WachspressPanel{N}` with `auto_params`
parametric assignment.  Wachspress{4} is identical to bilinear.

# Fields
- `panel`:      `IsoParametricPanel` or `WachspressPanel{N}`
- `col_ξη`:     Parametric (ξ, η) of each column vertex in the cell
- `span_axis`:  Unit vector of the span direction
- `n_verts`:    Number of polygon vertices (4 = quad, >4 = N-gon)
"""
struct CellPanel{P}
    panel::P
    col_ξη::Vector{NTuple{2, Float64}}
    span_axis::NTuple{2, Float64}
    n_verts::Int
end

"""
    build_cell_panel(cell_poly, cell_cols, span_axis, skel) -> Union{CellPanel, Nothing}

Construct a parametric panel for a cell polygon.

For **quad cells** (4 vertices): uses `IsoParametricPanel` (bilinear map).
Corner ordering is chosen so that ξ increases along `span_axis`.

For **convex N-gon cells** (N ≠ 4): uses `WachspressPanel{N}` with
`auto_params` parametric assignment.  Vertices are reordered so that
the vertex with the smallest span-axis projection comes first (ξ ≈ 0).

For **non-convex cells**: returns `nothing` (δ-band fallback).

# Arguments
- `cell_poly`:   Cell polygon vertices `[(x,y), ...]` in meters (CCW)
- `cell_cols`:   Columns touching this cell
- `span_axis`:   Unit span direction `(ax, ay)`
- `skel`:        Skeleton (for column vertex positions)
"""
function build_cell_panel(
    cell_poly::Vector{NTuple{2, Float64}},
    cell_cols::Vector,
    span_axis::NTuple{2, Float64},
    skel,
)::Union{CellPanel, Nothing}
    n_verts = length(cell_poly)
    n_verts < 3 && return nothing

    if n_verts == 4
        return _build_quad_panel(cell_poly, cell_cols, span_axis, skel)
    else
        return _build_ngon_panel(cell_poly, cell_cols, span_axis, skel)
    end
end

"""Build a `CellPanel` for a 4-vertex cell using bilinear `IsoParametricPanel`."""
function _build_quad_panel(
    cell_poly::Vector{NTuple{2, Float64}},
    cell_cols::Vector,
    span_axis::NTuple{2, Float64},
    skel,
)::Union{CellPanel, Nothing}
    tx, ty = span_axis
    nx, ny = -ty, tx

    projections = [(tx * v[1] + ty * v[2], nx * v[1] + ny * v[2]) for v in cell_poly]
    s_vals = [p[1] for p in projections]
    t_vals = [p[2] for p in projections]
    s_mid = (minimum(s_vals) + maximum(s_vals)) / 2
    t_mid = (minimum(t_vals) + maximum(t_vals)) / 2

    corner_idx = zeros(Int, 4)
    scores = [(s_vals[i] < s_mid ? 0 : 1) + (t_vals[i] < t_mid ? 0 : 2) for i in 1:4]
    score_to_corner = Dict(0 => 1, 1 => 2, 3 => 3, 2 => 4)

    for i in 1:4
        c = get(score_to_corner, scores[i], 0)
        c == 0 && return nothing
        corner_idx[c] != 0 && return nothing
        corner_idx[c] = i
    end
    any(==(0), corner_idx) && return nothing

    corners = ntuple(i -> cell_poly[corner_idx[i]], 4)
    panel = IsoParametricPanel(corners)

    col_ξη = _map_columns_to_parametric(panel, cell_cols, skel)
    return CellPanel(panel, col_ξη, span_axis, 4)
end

"""Build a `CellPanel` for an N-gon cell using `WachspressPanel` with `auto_params`."""
function _build_ngon_panel(
    cell_poly::Vector{NTuple{2, Float64}},
    cell_cols::Vector,
    span_axis::NTuple{2, Float64},
    skel,
)::Union{CellPanel, Nothing}
    n = length(cell_poly)

    # Convexity check — Wachspress requires a convex polygon
    tup = ntuple(i -> cell_poly[i], n)
    is_convex_polygon(tup) || return nothing

    # Reorder vertices so that the one with the smallest span-axis projection
    # comes first.  This aligns ξ ≈ 0 with the "start" of the span direction,
    # giving a consistent parametric orientation.
    tx, ty = span_axis
    s_vals = [tx * v[1] + ty * v[2] for v in cell_poly]
    start_idx = argmin(s_vals)

    # Rotate the polygon so start_idx is first (preserving CCW order)
    ordered = vcat(cell_poly[start_idx:end], cell_poly[1:start_idx-1])

    params = auto_params(ordered)
    panel = WachspressPanel(ordered, params)

    col_ξη = _map_columns_to_parametric(panel, cell_cols, skel)
    return CellPanel(panel, col_ξη, span_axis, n)
end

"""Map column vertex positions into parametric (ξ, η) coordinates of `panel`."""
function _map_columns_to_parametric(panel, cell_cols::Vector, skel)
    col_ξη = NTuple{2, Float64}[]
    for col in cell_cols
        px, py = _column_xy_m(skel, col)
        try
            ξη = parametric_coords(panel, px, py)
            push!(col_ξη, ξη)
        catch
            push!(col_ξη, (0.5, 0.5))
        end
    end
    return col_ξη
end

# =============================================================================
# Cut Line Generation
# =============================================================================

"""
    CutLine

A section cut at parametric position ξ through a cell panel.

# Fields
- `ξ`:        Parametric span position of the cut
- `points`:   Physical (x, y) polyline of the cut, sampled at `n_pts` points
- `region`:   `:column_face` or `:midspan`
"""
struct CutLine
    ξ::Float64
    points::Vector{NTuple{2, Float64}}
    region::Symbol
end

"""
    generate_cut_lines(cp::CellPanel, cell_cols, span_axis, skel;
                       n_cuts=40, n_pts=30, iso_alpha=1.0) -> Vector{CutLine}

Generate a family of section cuts at uniform ξ spacing through the cell panel.

Each cut is a polyline from the bottom edge (η=0) to the top edge (η=1) of
the panel.  The `iso_alpha` parameter controls the cut line shape:

- `iso_alpha = 0.0` (contour-following): Pure isoparametric cuts.  For
  rectangular panels these are straight lines; for skewed/trapezoidal panels
  they curve to follow the panel geometry exactly.
- `iso_alpha = 1.0` (straight, default): Straight lines perpendicular to the
  span axis.  Ignores panel skew — standard approach for regular panels.
- `0 < iso_alpha < 1`: Linear blend between isoparametric and straight.
  Useful for mildly irregular panels where some contour-following is desired
  but full isoparametric mapping introduces too much curvature.

The blending formula at each sample point is:
    p = (1 - α) × p_iso + α × p_straight

where `p_iso` is the isoparametric point and `p_straight` is the
corresponding point on the straight line through the same panel edges.

Cut classification uses the **actual column dimensions** to define column
bands in parametric space:
- `:column_face` — within the column face offset of any column's ξ position
- `:midspan` — outside all column bands (the true midspan region)
"""
function generate_cut_lines(
    cp::CellPanel,
    cell_cols::Vector,
    span_axis::NTuple{2, Float64},
    skel;
    n_cuts::Int = 40,
    n_pts::Int = 30,
    iso_alpha::Float64 = 1.0,
)
    panel = cp.panel

    # ── Build column bands in parametric space ──
    L_span = _panel_span_length(panel, span_axis)
    col_bands = NTuple{2, Float64}[]
    for (j, col) in enumerate(cell_cols)
        col_ξ = cp.col_ξη[j][1]
        face_m = _column_face_offset_m(col, span_axis)
        Δξ_face = L_span > 0 ? face_m / L_span : 0.05
        Δξ = max(2 * Δξ_face, 0.05)
        push!(col_bands, (col_ξ - Δξ, col_ξ + Δξ))
    end

    if cp.n_verts == 4
        return _generate_quad_cuts(panel, col_bands, span_axis, n_cuts, n_pts, iso_alpha)
    else
        return _generate_ngon_cuts(panel, col_bands, n_cuts, n_pts)
    end
end

"""Generate uniform ξ-sweep cut lines for a quad panel with `iso_alpha` blending."""
function _generate_quad_cuts(
    panel, col_bands, span_axis, n_cuts, n_pts, iso_alpha,
)
    cuts = Vector{CutLine}(undef, n_cuts)

    for i in 1:n_cuts
        ξ = (i - 0.5) / n_cuts

        p_bot_iso = physical_coords(panel, ξ, 0.0)
        p_top_iso = physical_coords(panel, ξ, 1.0)

        pts = Vector{NTuple{2, Float64}}(undef, n_pts)
        for j in 1:n_pts
            η = (j - 1) / (n_pts - 1)
            p_iso = physical_coords(panel, ξ, η)

            if iso_alpha ≈ 0.0
                pts[j] = p_iso
            elseif iso_alpha ≈ 1.0
                pts[j] = (
                    (1 - η) * p_bot_iso[1] + η * p_top_iso[1],
                    (1 - η) * p_bot_iso[2] + η * p_top_iso[2],
                )
            else
                p_straight = (
                    (1 - η) * p_bot_iso[1] + η * p_top_iso[1],
                    (1 - η) * p_bot_iso[2] + η * p_top_iso[2],
                )
                α = iso_alpha
                pts[j] = (
                    (1 - α) * p_iso[1] + α * p_straight[1],
                    (1 - α) * p_iso[2] + α * p_straight[2],
                )
            end
        end

        near_col = any(lo ≤ ξ ≤ hi for (lo, hi) in col_bands)
        region = near_col ? :column_face : :midspan
        cuts[i] = CutLine(ξ, pts, region)
    end
    return cuts
end

"""Generate iso-ξ cut lines for an N-gon panel via Wachspress boundary crossings."""
function _generate_ngon_cuts(
    panel::WachspressPanel{N}, col_bands, n_cuts, n_pts,
) where {N}
    # Parametric ξ range from vertex params
    ξ_vals = [panel.params[i][1] for i in 1:N]
    ξ_min, ξ_max = extrema(ξ_vals)

    cuts = CutLine[]
    sizehint!(cuts, n_cuts)

    for i in 1:n_cuts
        ξ = ξ_min + (ξ_max - ξ_min) * (i - 0.5) / n_cuts

        # Find where this iso-ξ line crosses the polygon boundary
        cx = _boundary_crossings(panel, 1, ξ)
        length(cx) < 2 && continue

        # Trace the isoline from first crossing to last crossing
        pts = _trace_isoline(panel, 1, ξ,
            cx[1][1], cx[1][2], cx[end][1], cx[end][2]; n_pts=n_pts)

        near_col = any(lo ≤ ξ ≤ hi for (lo, hi) in col_bands)
        region = near_col ? :column_face : :midspan
        push!(cuts, CutLine(ξ, pts, region))
    end
    return cuts
end

"""
    _panel_span_length(panel, span_axis) -> Float64

Estimate the physical span length of a panel along `span_axis`
by measuring the distance between the ξ=0 and ξ=1 midlines.

Works for both `IsoParametricPanel` and `WachspressPanel`.
"""
function _panel_span_length(panel, span_axis::NTuple{2, Float64})::Float64
    p0 = physical_coords(panel, 0.0, 0.5)
    p1 = physical_coords(panel, 1.0, 0.5)
    dx, dy = p1[1] - p0[1], p1[2] - p0[2]
    return abs(dx * span_axis[1] + dy * span_axis[2])
end

# =============================================================================
# Line Integration Along a Cut
# =============================================================================

"""
    _find_element_at(cache, px, py, tri_indices) -> Int

Find the element index (into `cache.element_data`) containing point (px, py).
Searches only elements in `tri_indices`.  Returns 0 if not found.
"""
function _find_element_at(
    cache::FEAModelCache,
    field::NodalMomentField,
    px::Float64, py::Float64,
    tri_indices::Vector{Int},
)::Int
    @inbounds for k in tri_indices
        ed = cache.element_data[k]
        # Bounding-radius pre-check: circumradius of equilateral tri with same area
        # r ≈ √(4A / √3) ≈ 1.52 √A; use 2.0√A for safety margin
        r = 2.0 * sqrt(ed.area)
        (abs(px - ed.cx) > r || abs(py - ed.cy) > r) && continue

        nids = field.tri_node_ids[k]
        n1, n2, n3 = nids
        λ1, λ2, λ3 = _barycentric_coords(
            px, py,
            field.node_x[n1], field.node_y[n1],
            field.node_x[n2], field.node_y[n2],
            field.node_x[n3], field.node_y[n3],
        )
        tol = -0.01  # small tolerance for edge cases
        if λ1 ≥ tol && λ2 ≥ tol && λ3 ≥ tol
            return k
        end
    end
    return 0
end

"""
    integrate_cut_Mn(cache, field, cut, tri_indices, span_axis;
                     include_torsion=true) -> Float64

Integrate the span-direction moment Mₙ along a section cut line using
the smoothed nodal field.

The integral is computed via trapezoidal rule along the cut polyline:
    M_total = ∫ Mₙ(s) ds ≈ Σ (Mₙᵢ + Mₙᵢ₊₁)/2 × Δsᵢ

where `s` is the arc length along the cut and `Mₙ(s)` is the Mohr's circle
projection of the interpolated (Mxx, Myy, Mxy) onto the span axis.

When `include_torsion=false`, the Mxy cross-term is dropped.

Returns the total moment crossing the cut (N·m).
"""
function integrate_cut_Mn(
    cache::FEAModelCache,
    field::NodalMomentField,
    cut::CutLine,
    tri_indices::Vector{Int},
    span_axis::NTuple{2, Float64};
    include_torsion::Bool = true,
)::Float64
    pts = cut.points
    n = length(pts)
    n < 2 && return 0.0

    # Evaluate Mₙ at each cut point
    Mn_vals = Vector{Float64}(undef, n)
    for i in 1:n
        px, py = pts[i]
        elem_k = _find_element_at(cache, field, px, py, tri_indices)
        if elem_k > 0
            Mn_vals[i] = interpolate_Mn(field, elem_k, px, py, span_axis;
                                        include_torsion=include_torsion)
        else
            Mn_vals[i] = 0.0  # point outside mesh (edge of polygon)
        end
    end

    # Trapezoidal integration
    M_total = 0.0
    for i in 1:(n - 1)
        ds = hypot(pts[i+1][1] - pts[i][1], pts[i+1][2] - pts[i][2])
        M_total += 0.5 * (Mn_vals[i] + Mn_vals[i+1]) * ds
    end

    return M_total
end

"""
    integrate_cut_Mn_split(cache, field, cut, tri_indices, span_axis, cs_polys;
                           include_torsion=true) -> (M_cs, M_ms)

Integrate Mₙ along a section cut, splitting the integral into column-strip
and middle-strip contributions based on the CS polygon classification.

When `include_torsion=false`, the Mxy cross-term is dropped.

Returns `(M_cs, M_ms)` in N·m.
"""
function integrate_cut_Mn_split(
    cache::FEAModelCache,
    field::NodalMomentField,
    cut::CutLine,
    tri_indices::Vector{Int},
    span_axis::NTuple{2, Float64},
    cs_polys::Vector{Vector{NTuple{2, Float64}}};
    include_torsion::Bool = true,
)::NTuple{2, Float64}
    pts = cut.points
    n = length(pts)
    n < 2 && return (0.0, 0.0)

    # Evaluate Mₙ and strip classification at each cut point
    Mn_vals = Vector{Float64}(undef, n)
    is_cs   = Vector{Bool}(undef, n)
    for i in 1:n
        px, py = pts[i]
        elem_k = _find_element_at(cache, field, px, py, tri_indices)
        Mn_vals[i] = elem_k > 0 ?
            interpolate_Mn(field, elem_k, px, py, span_axis;
                           include_torsion=include_torsion) : 0.0
        is_cs[i] = _is_in_column_strip(px, py, cs_polys)
    end

    # Trapezoidal integration, split by strip via segment midpoint
    M_cs = 0.0
    M_ms = 0.0
    for i in 1:(n - 1)
        ds = hypot(pts[i+1][1] - pts[i][1], pts[i+1][2] - pts[i][2])
        Mn_avg = 0.5 * (Mn_vals[i] + Mn_vals[i+1])
        dM = Mn_avg * ds
        mid_x = 0.5 * (pts[i][1] + pts[i+1][1])
        mid_y = 0.5 * (pts[i][2] + pts[i+1][2])
        if _is_in_column_strip(mid_x, mid_y, cs_polys)
            M_cs += dM
        else
            M_ms += dM
        end
    end

    return (M_cs, M_ms)
end
