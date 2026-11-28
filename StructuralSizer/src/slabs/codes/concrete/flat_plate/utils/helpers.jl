# =============================================================================
# Flat Plate Design Helpers
# =============================================================================
#
# Support functions for the flat plate design pipeline:
# - Column finding and ordering
# - Frame line construction
# - Axial load computation
# - Asap model updates
#
# Note: This file is included in StructuralSizer, inheriting Logging, Meshes, etc.
# =============================================================================

# =============================================================================
# Column Accessor Functions
# =============================================================================
# These provide a stable interface for column properties that may or may not
# exist on the input object (e.g., NamedTuple from standalone tests vs. a full
# Column struct from StructuralSynthesizer).

"""Column cross-section shape (`:rectangular` or `:circular`)."""
col_shape(col)::Symbol = hasproperty(col, :shape) ? col.shape : :rectangular

"""Skeleton vertex index for the column (0 = not available)."""
col_vertex_idx(col)::Int = hasproperty(col, :vertex_idx) ? col.vertex_idx : 0

"""Story index for the column (default 1)."""
col_story(col)::Int = hasproperty(col, :story) ? col.story : 1

"""Boundary edge directions for the column (empty = interior)."""
col_boundary_edge_dirs(col) = hasproperty(col, :boundary_edge_dirs) ? col.boundary_edge_dirs : NTuple{2, Float64}[]

"""Column orientation angle in radians (CCW from global X). 0.0 = axis-aligned."""
col_orientation(col)::Float64 = hasproperty(col, :θ) ? Float64(col.θ) : 0.0

# =============================================================================
# Analysis Method Utilities
# =============================================================================

"""Display name for DDM analysis method."""
method_name(method::DDM) = method.variant == :simplified ? "MDDM (Simplified)" : "DDM (ACI 318-11 §13.6)"

"""Display name for EFM analysis method."""
function method_name(method::EFM)
    solver_str = method.solver == :asap ? "ASAP FEM" : "Hardy Cross"
    stiff_str  = method.column_stiffness == :Kc ? ", Kc" : ""
    crack_str  = method.cracked_columns ? ", cracked" : ""
    return "EFM (ACI 8.11, $(solver_str)$(stiff_str)$(crack_str))"
end

"""Display name for FEA analysis method."""
function method_name(method::FEA)
    # Design approach
    da = method.design_approach
    da_str = da == :frame ? "frame" :
             da == :strip ? "strip" :
             da == :area  ? "area" : string(da)

    # Sub-knobs (only shown when relevant)
    parts = String[]

    if da in (:strip, :area)
        mt = method.moment_transform
        mt == :wood_armer && push!(parts, "W-A")
        mt == :no_torsion && push!(parts, "no-Mxy")
    end

    if da == :strip
        fs = method.field_smoothing
        fs != :element && push!(parts, string(fs))

        cm = method.cut_method
        cm != :delta_band && push!(parts, string(cm))

        if cm == :isoparametric && method.iso_alpha != 1.0
            push!(parts, "α=$(method.iso_alpha)")
        end
    end

    if method.sign_treatment != :signed
        push!(parts, "sep-faces")
    end

    if !isnothing(method.rebar_direction)
        push!(parts, "θ=$(round(rad2deg(method.rebar_direction), digits=0))°")
    end

    if method.pattern_loading && method.pattern_mode != :efm_amp
        push!(parts, "pat=$(method.pattern_mode)")
    end

    knob_str = isempty(parts) ? "" : ", " * join(parts, "/")
    edge_str = isnothing(method.target_edge) ? "auto" : string(method.target_edge)
    return "FEA ($(da_str)$(knob_str), edge=$(edge_str))"
end

"""Display name for RuleOfThumb analysis method."""
method_name(::RuleOfThumb) = "ACI Min"

"""
    round_up_thickness(h, increment) -> Length

Round slab thickness up to the nearest increment.

# Example
```julia
round_up_thickness(7.3u"inch", 0.5u"inch")  # → 7.5u"inch"
```
"""
function round_up_thickness(h::Length, increment::Length)
    h_val = ustrip(u"inch", h)
    inc_val = ustrip(u"inch", increment)
    h_rounded = ceil(h_val / inc_val) * inc_val
    return h_rounded * u"inch"
end

# =============================================================================
# Column Finding
# =============================================================================

"""
    find_supporting_columns(struc, slab_cell_indices) -> Vector{Column}

Find columns whose tributary area includes any of the slab's cells.

Uses `col.tributary_cell_indices` (populated by `compute_vertex_tributaries!`).
"""
function find_supporting_columns(struc, slab_cell_indices::Set{Int})
    supporting = typeof(struc.columns)()
    for col in struc.columns
        if !isempty(col.tributary_cell_indices)
            if any(cell_idx in slab_cell_indices for cell_idx in col.tributary_cell_indices)
                push!(supporting, col)
            end
        end
    end
    return supporting
end

"""
    supporting_wall_segments(struc, slab)
        -> Vector{Tuple{NTuple{2,Float64},NTuple{2,Float64}}}

Plan segments, in metres, of walls that meet this slab. A wall's plan line
is at its story elevation and the pier runs up to the next story, so the
wall meets the slab at either end. Stacked piers on the same line are one
segment. Empty when the structure has no walls or the skeleton has no stories.

A floor that already carries `wall_segments` (the design kernel, which has
no wall objects) returns that list. The building resolves the list.
"""
function supporting_wall_segments(struc, slab)
    empty = Tuple{NTuple{2,Float64},NTuple{2,Float64}}[]
    hasproperty(slab, :wall_segments) && return slab.wall_segments
    hasproperty(struc, :walls) || return empty
    walls = struc.walls
    isempty(walls) && return empty
    skel = struc.skeleton
    hasproperty(skel, :stories) || return empty
    hasproperty(skel, :geometry) || return empty
    skel.geometry === nothing && return empty
    z = _slab_elevation_m(struc, slab)
    z === nothing && return empty
    out = Tuple{NTuple{2,Float64},NTuple{2,Float64}}[]
    seen = Set{NTuple{4,Int}}()
    for w in walls
        hasproperty(w, :x1) || continue
        any(zw -> abs(zw - z) <= 0.1, _wall_end_elevations_m(skel, w.story)) || continue
        seg = ((Float64(w.x1), Float64(w.y1)), (Float64(w.x2), Float64(w.y2)))
        key = _segment_key(seg)
        key in seen && continue
        push!(seen, key)
        push!(out, seg)
    end
    return out
end

"""Unit vector of a span axis, or `nothing` when the axis has no length."""
function _span_unit_axis(span_axis)
    span_axis === nothing && return nothing
    length(span_axis) == 2 || return nothing
    L = hypot(Float64(span_axis[1]), Float64(span_axis[2]))
    L < 1e-9 && return nothing
    return (span_axis[1] / L, span_axis[2] / L)
end

"""True when a wall segment lies along `ax` rather than across it."""
function _wall_parallel_to_axis(seg, ax)
    dx = seg[2][1] - seg[1][1]
    dy = seg[2][2] - seg[1][2]
    L = hypot(dx, dy)
    L < 1e-6 && return false
    return abs(dx * ax[2] - dy * ax[1]) / L < 0.05
end

"""
Thickness of the wall on `seg`, or `nothing` when the model has only the
plan line. A design kernel carries segments and no wall objects.
"""
function _wall_thickness(struc, seg)
    hasproperty(struc, :walls) || return nothing
    for w in struc.walls
        hasproperty(w, :thickness) || continue
        hasproperty(w, :x1) || continue
        ends = ((Float64(w.x1), Float64(w.y1)), (Float64(w.x2), Float64(w.y2)))
        same = (_segment_key((ends[1], ends[2])) == _segment_key(seg))
        same || continue
        t = w.thickness
        return t isa Unitful.Quantity ? t : t * u"m"
    end
    return nothing
end

"""A story elevation as metres. A bare number is already metres."""
_story_elevation_m(x) = x isa Unitful.Quantity ? ustrip(u"m", x) : Float64(x)

"""Story elevation and the next story that has faces, in metres."""
function _wall_end_elevations_m(skel, story)::Vector{Float64}
    haskey(skel.stories, story) || return Float64[]
    zs = Float64[_story_elevation_m(skel.stories[story].elevation)]
    above = nothing
    for k in sort!(collect(keys(skel.stories)))
        k <= story && continue
        if !isempty(skel.stories[k].faces)
            above = k
            break
        end
    end
    above === nothing || push!(zs, _story_elevation_m(skel.stories[above].elevation))
    return zs
end

"""
Distance, in metres, from `z_slab` down to the base of `wall`, or `nothing`
when this wall does not support that slab.

The slab sits on the top of the pier. A skeleton with a story above the
wall's own story measures the pier as the distance between those elevations.
A skeleton with only the slab's story uses the wall's own height, which is
the pier below that slab.
"""
function _wall_drop_below_slab(skel, wall, z_slab::Float64)
    hasproperty(wall, :story) || return nothing
    ends = _wall_end_elevations_m(skel, wall.story)
    isempty(ends) && return nothing
    if length(ends) >= 2
        abs(ends[2] - z_slab) > 0.1 && return nothing
        drop = ends[2] - ends[1]
    else
        abs(ends[1] - z_slab) > 0.1 && return nothing
        L = wall.base.L
        drop = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
    end
    return drop > 1e-4 ? drop : nothing
end

"""
Piers that support `slab`, with thickness and the height below the slab.

A floor that already carries `wall_piers` returns that list. Otherwise the
walls on `struc` are measured. Empty when there is no wall to join the slab to.
"""
function flat_plate_wall_piers(struc, slab)
    hasproperty(slab, :wall_piers) && return slab.wall_piers
    empty = FlatPlateWallPier[]
    hasproperty(struc, :walls) || return empty
    isempty(struc.walls) && return empty
    skel = struc.skeleton
    hasproperty(skel, :stories) || return empty
    z = _slab_elevation_m(struc, slab)
    z === nothing && return empty
    out = FlatPlateWallPier[]
    seen = Set{NTuple{4, Int}}()
    for w in struc.walls
        hasproperty(w, :x1) || continue
        hasproperty(w, :thickness) || continue
        drop = _wall_drop_below_slab(skel, w, z)
        drop === nothing && continue
        t = w.thickness
        t_m = t isa Unitful.Quantity ? ustrip(u"m", t) : Float64(t)
        t_m > 0 || continue
        seg = ((Float64(w.x1), Float64(w.y1)), (Float64(w.x2), Float64(w.y2)))
        key = _segment_key(seg)
        key in seen && continue
        push!(seen, key)
        push!(out, FlatPlateWallPier(seg[1][1], seg[1][2], seg[2][1], seg[2][2], t_m, drop))
    end
    return out
end

function _segment_key(seg)
    a = (round(Int, 1e3 * seg[1][1]), round(Int, 1e3 * seg[1][2]))
    b = (round(Int, 1e3 * seg[2][1]), round(Int, 1e3 * seg[2][2]))
    return a <= b ? (a..., b...) : (b..., a...)
end

"""Elevation (metres) of the slab's cells. `nothing` when a cell has no face."""
function _slab_elevation_m(struc, slab)
    hasproperty(slab, :cell_indices) || return nothing
    isempty(slab.cell_indices) && return nothing
    skel = struc.skeleton
    cell = struc.cells[first(slab.cell_indices)]
    hasproperty(cell, :face_idx) || return nothing
    vis = skel.face_vertex_indices[cell.face_idx]
    isempty(vis) && return nothing
    return skel.geometry.vertex_coords[first(vis), 3]
end

"""
    slab_discontinuous_edge(struc, slab, columns) -> Bool

True when ACI 318-11 Table 9.5(c) uses the exterior-without-edge-beams
thickness (corpus: aci-318-11, page 134).

A column that is not interior is that case. So is a wall that lies on the
slab outline, including a courtyard. A wall is not footnote §'s edge beam.
An interior wall, or a free edge with only interior columns and no wall on
it, leaves the interior column.
"""
function slab_discontinuous_edge(struc, slab, columns)
    any(c -> hasproperty(c, :position) && c.position != :interior, columns) && return true
    return _wall_on_slab_boundary(struc, slab)
end

function _wall_on_slab_boundary(struc, slab)
    segs = supporting_wall_segments(struc, slab)
    isempty(segs) && return false
    edges = _slab_outline_edges(struc, slab)
    isempty(edges) && return false
    for (a, b) in segs
        hypot(b[1] - a[1], b[2] - a[2]) < 1e-3 && continue
        mid = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
        on(p) = any(e -> _point_on_segment(p, e[1], e[2]), edges)
        on(a) && on(b) && on(mid) && return true
    end
    return false
end

"""Boundary edges of the slab outline, in metres, exterior and courtyards."""
function _slab_outline_edges(struc, slab)
    hasproperty(struc, :skeleton) || return NTuple{2, NTuple{2, Float64}}[]
    hasproperty(struc, :cells) || return NTuple{2, NTuple{2, Float64}}[]
    exterior, _, _, holes = _slab_boundary_topology(struc, slab)
    skel = struc.skeleton
    edges = NTuple{2, NTuple{2, Float64}}[]
    function add(loop)
        n = length(loop)
        n < 2 && return
        for i in 1:n
            a = _vertex_xy_m(skel, loop[i])
            b = _vertex_xy_m(skel, loop[mod1(i + 1, n)])
            push!(edges, (a, b))
        end
    end
    add(exterior)
    for hole in holes
        add(hole)
    end
    return edges
end

"""True when `pt` is within `tol` metres of segment `a`–`b`."""
function _point_on_segment(pt::NTuple{2,Float64}, a::NTuple{2,Float64}, b::NTuple{2,Float64};
                           tol::Float64 = 1e-3)
    abx, aby = b[1] - a[1], b[2] - a[2]
    len2 = abx * abx + aby * aby
    if len2 == 0
        return hypot(pt[1] - a[1], pt[2] - a[2]) <= tol
    end
    s = clamp(((pt[1] - a[1]) * abx + (pt[2] - a[2]) * aby) / len2, 0.0, 1.0)
    return hypot(pt[1] - (a[1] + s * abx), pt[2] - (a[2] + s * aby)) <= tol
end

# =============================================================================
# Column Moment Distribution (ACI 318-11 §13.6.9.2)
# =============================================================================

"""
    _col_Ec_ksi(col, Ec_default_ksi) -> Float64

Return Ec in ksi for a column. Uses the column's own `concrete` field when
available (for mixed-strength buildings); otherwise falls back to the default.
"""
function _col_Ec_ksi(col, Ec_default_ksi::Float64)::Float64
    hasproperty(col, :concrete) || return Ec_default_ksi
    conc = col.concrete
    isnothing(conc) && return Ec_default_ksi
    wc = ustrip(pcf, conc.ρ)
    return ustrip(ksi, Ec(conc.fc′, wc))
end

"""
    _col_moment_of_inertia(col, span_axis) -> Float64

Gross moment of inertia (in⁴) of a column section for bending in the
vertical plane that contains the plan direction `span_axis`, i.e. about the
horizontal axis perpendicular to `span_axis`.

- Circular: π·D⁴/64.
- Rectangular with `span_axis` along the column's `c1` side (local x):
  c2·c1³/12, the depth c1 in the span direction, as the EFM column
  (`column_moment_of_inertia`, ACI 318-11 §13.7.4). Along `c2`: c1·c2³/12.
- A rectangle turned at an angle φ to `span_axis` uses the second moment
  about the rotated axis, (c2·c1³·cos²φ + c1·c2³·sin²φ)/12. This is section
  mechanics (the principal axes have no product of inertia), not an ACI
  provision, and it reduces to the two cases above at φ = 0° and 90°.
"""
function _col_moment_of_inertia(col, span_axis)::Float64
    c1 = ustrip(u"inch", col.c1)
    c2 = ustrip(u"inch", col.c2)
    if col_shape(col) === :circular
        D = max(c1, c2)           # c1 = c2 = D for circular
        return π * D^4 / 64
    end
    axes = _eq137_unit_axes((Float64(span_axis[1]), Float64(span_axis[2])))
    axes === nothing && throw(ArgumentError("span_axis has zero length: $span_axis"))
    ax = axes[1]
    # Span direction in the column's local frame (local x along c1).
    θ = col_orientation(col)
    cos_φ = cos(θ) * ax[1] + sin(θ) * ax[2]
    sin_φ = -sin(θ) * ax[1] + cos(θ) * ax[2]
    return (c2 * c1^3 * cos_φ^2 + c1 * c2^3 * sin_φ^2) / 12
end

"""
    _col_flexural_stiffness(col, Ec_default_ksi, span_axis) -> Float64

Flexural stiffness K = 4·Ec·Ig / L (kip·in units) of a single column for
bending in the plane of `span_axis` (`_col_moment_of_inertia`).
Uses per-column concrete when available; otherwise `Ec_default_ksi`.
"""
function _col_flexural_stiffness(col, Ec_default_ksi::Float64, span_axis)::Float64
    L = ustrip(u"inch", col.base.L)
    L > 0 || return 0.0
    Ec_ksi = _col_Ec_ksi(col, Ec_default_ksi)
    return 4 * Ec_ksi * _col_moment_of_inertia(col, span_axis) / L
end

"""
    column_moment_distribution_factors(struc, columns, column_opts; span_axis)
        -> NamedTuple{(:primary, :secondary), Tuple{Vector{Float64}, Vector{Float64}}}

Fraction of the joint unbalanced moment assigned to the column below the
slab, for each bending direction:

- `primary`: moments of the slab's primary analysis, spanning along
  `span_axis`. Column stiffness for bending in that plane.
- `secondary`: moments of the perpendicular analysis, spanning along the
  axis turned 90° from `span_axis`.

A rectangular column has a different stiffness in each direction, so one
factor must not be applied to both.

ACI 318-11 §13.6.9.2 (Eq. 13-7; corpus: aci-318-11, page 258): at an
interior support, the columns above and below the slab resist the moment
from Eq. (13-7) in direct proportion to their stiffnesses, unless a
general analysis is made.

    K = 4·E·I / L    (far-end fixed)

Factor = K_below / (K_below + K_above). The factor is 1 when no column
exists above (roof or a single story) and about 1/2 for equal stories.
A column that still has no `c1` or `c2` also keeps 1, because its
stiffness is not known yet.

§13.5.3.2 is the slab width that takes γ_f M_u in flexure (corpus:
aci-318-11, page 250). It is not this split.

ENGINEERING JUDGMENT: the same factor is also applied to an edge or
corner column, including the §13.6.3.6 exterior transfer 0.3 M0 (corpus:
aci-318-11, page 255). §13.6.9.2 states the split for an interior support.

A shell analysis does not use this factor. The moment in the stub below
the slab is read directly (`column_design_moment`). §13.6.9.2 allows
that: the stiffness split applies unless a general analysis is made.

# Arguments
- `struc`: BuildingStructure with all columns
- `columns`: Supporting columns for this slab (below the slab)
- `column_opts`: ConcreteColumnOptions (provides default concrete grade for Ec)
- `span_axis` (keyword, required): the slab's primary span direction in plan
  (`_get_span_axis(slab)`)
"""
function column_moment_distribution_factors(struc, columns, column_opts; span_axis)
    n = length(columns)
    primary = ones(Float64, n)
    secondary = ones(Float64, n)
    axes = _eq137_unit_axes((Float64(span_axis[1]), Float64(span_axis[2])))
    axes === nothing && throw(ArgumentError("span_axis has zero length: $span_axis"))
    ax, ax_perp = axes

    # Default column Ec from column_opts (used when col.concrete is nothing)
    fc_default = column_opts.material.fc′
    wc_default = ustrip(pcf, column_opts.material.ρ)
    Ec_default = ustrip(ksi, Ec(fc_default, wc_default))  # ksi

    share(below, above, dir) = begin
        K_below = _col_flexural_stiffness(below, Ec_default, dir)
        K_above = _col_flexural_stiffness(above, Ec_default, dir)
        K_total = K_below + K_above
        K_total > 0 ? K_below / K_total : 1.0
    end

    for (i, col_below) in enumerate(columns)
        col_above = col_below.column_above
        isnothing(col_above) && continue  # no column above → factors stay 1.0

        # Guard: skip if either column lacks cross-section dimensions
        (isnothing(col_below.c1) || isnothing(col_below.c2)) && continue
        (isnothing(col_above.c1) || isnothing(col_above.c2)) && continue

        # Stiffness K = 4·Ec·I / L — each column uses its own Ec if available
        primary[i] = share(col_below, col_above, ax)
        secondary[i] = share(col_below, col_above, ax_perp)
    end

    return (primary = primary, secondary = secondary)
end

"""
    column_design_moment(results, i, dist) -> Float64

Moment, in kip·ft, that the column below the slab is designed for.

`results.stub_moments_below[i]` is that moment when a shell analysis
stored the end moment of the stub below the slab. The joint moment stays
in `unbalanced_moments` for punching (ACI 318-11 §13.5.3.1, corpus:
aci-318-11, page 250).

DDM and EFM leave the field unset. The column's share is then
`unbalanced_moments[i] * dist`, with `dist` from
[`column_moment_distribution_factors`](@ref).
"""
function column_design_moment(results, i::Int, dist::Real)
    below = stub_moments(results)
    below === nothing || return ustrip(kip * u"ft", below.below[i])
    return ustrip(kip * u"ft", results.unbalanced_moments[i]) * dist
end

"""
    stub_moments(results) -> Union{Nothing, NamedTuple{(:below, :above)}}

Moments in the column stubs below and above the slab, when a shell
analysis stored them on `results` (a `MomentAnalysisResult` or its
`secondary` NamedTuple). `nothing` otherwise.
"""
function stub_moments(results)
    results === nothing && return nothing
    hasproperty(results, :stub_moments_below) || return nothing
    below = getproperty(results, :stub_moments_below)
    below === nothing && return nothing
    return (below = below, above = getproperty(results, :stub_moments_above))
end

# =============================================================================
# Frame Line Construction
# =============================================================================

"""
    build_frame_line(struc, columns, l2, direction::Symbol=:x) -> FrameLine

Build a FrameLine from columns and tributary width for EFM analysis.

# Arguments
- `struc`: BuildingStructure with skeleton for column positions
- `columns`: Vector of Column objects
- `l2`: Tributary width (panel width perpendicular to frame)
- `direction`: Frame direction (:x or :y)
"""
function build_frame_line(struc, columns, l2, direction::Symbol=:x)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    # Position accessor: structural centerline (applies inward offset for edge/corner)
    function get_position(col)
        off = hasproperty(col, :structural_offset) ? col.structural_offset : (0.0, 0.0)
        # vertex_coords and structural_offset are meters. Carry the unit so
        # FrameLine subtracts column widths as lengths.
        ((vc[col.vertex_idx, 1] + off[1]) * u"m",
         (vc[col.vertex_idx, 2] + off[2]) * u"m")
    end
    
    # Width accessor: returns column width in frame direction
    function get_width(col, dir::NTuple{2, Float64})
        if abs(dir[1]) > abs(dir[2])
            return col.c1  # X-direction
        else
            return col.c2  # Y-direction
        end
    end
    
    return FrameLine(direction, columns, l2, get_position, get_width)
end

"""
    build_frame_lines_both_directions(struc, columns, slab) -> (fl_primary, fl_secondary)

Build frame lines for analysis in both directions (for crossing beam deflection method).
"""
function build_frame_lines_both_directions(struc, columns, slab)
    l1 = slab.spans.primary
    l2 = slab.spans.secondary
    
    fl_primary = build_frame_line(struc, columns, l2, :x)
    fl_secondary = build_frame_line(struc, columns, l1, :y)
    
    return (fl_primary, fl_secondary)
end

# =============================================================================
# Load Computation
# =============================================================================

"""
    compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate;
                               drop_weights=nothing) -> Vector{Float64}

Compute factored axial loads Pu (in kips) for each column from tributary areas.

Uses `col.tributary_cell_areas` which maps cell_idx → area in m².
`drop_weights` is the unfactored drop-panel self-weight at each column (see
[`column_drop_panel_weights`](@ref)). It is dead load and enters both
ASCE 7 §2.3.1 combinations.
"""
function compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate;
                                    drop_weights = nothing)::Vector{Float64}
    n_cols = length(columns)
    Pu = Vector{Float64}(undef, n_cols)

    for (i, col) in enumerate(columns)
        load = 0.0kip
        dead = 0.0kip

        for (cell_idx, area_m2) in col.tributary_cell_areas
            cell_idx in slab_cell_indices || continue
            cell = struc.cells[cell_idx]
            area = area_m2 * u"m^2"

            sw = iszero(cell.self_weight) ? sw_estimate : cell.self_weight
            qD = cell.sdl + sw
            qL = cell.live_load
            # Governing of 1.2D+1.6L vs 1.4D (ASCE 7 §2.3.1)
            q_factored = max(qD * 1.2 + qL * 1.6, qD * 1.4)

            load += q_factored * area
            dead += qD * area
        end

        if !isnothing(drop_weights)
            # The per-cell maximum already bounds 1.2D + 1.6L. 1.4D is checked
            # again on the total, because the drop raises D alone.
            Wd = uconvert(kip, drop_weights[i])
            load = max(load + 1.2 * Wd, 1.4 * (dead + Wd))
        end

        Pu[i] = ustrip(kip, load)
    end

    return Pu
end

"""
    column_drop_panel_areas(columns, drop_panel, span_axis) -> Vector{Area}

Plan area of the clipped drop outline at each column, the outline the FEA
patch and the punching check use ([`_column_drop_outline`](@ref)). Wall
supports carry no drop. Without a drop panel every area is zero.
"""
function column_drop_panel_areas(columns, drop_panel, span_axis)
    A = zeros(typeof(1.0u"m^2"), length(columns))
    isnothing(drop_panel) && return A
    for (i, col) in enumerate(columns)
        hasproperty(col, :wall_fixed) && continue
        A[i] = _shoelace(_column_drop_outline(col, drop_panel, span_axis).polygon) * u"m^2"
    end
    return A
end

"""
    column_drop_panel_weights(columns, drop_panel, γ_concrete, span_axis) -> Vector{Force}

Unfactored self-weight of the drop projection at each column,
`h_drop × γ × A`, with `A` from [`column_drop_panel_areas`](@ref).
"""
function column_drop_panel_weights(columns, drop_panel, γ_concrete, span_axis)
    T = typeof(1.0kip)
    isnothing(drop_panel) && return zeros(T, length(columns))
    w = drop_panel_dead_pressure(drop_panel, γ_concrete)
    return T[uconvert(kip, w * A) for A in column_drop_panel_areas(columns, drop_panel, span_axis)]
end

"""
    slab_column_axial_loads(struc, slab, columns, slab_cell_indices, sw_estimate,
                            drop_panel, γ_concrete) -> Vector{Float64}

[`compute_column_axial_loads`](@ref) with the drop-panel self-weight of the
current `drop_panel` (none for a flat plate).
"""
function slab_column_axial_loads(struc, slab, columns, slab_cell_indices, sw_estimate,
                                 drop_panel, γ_concrete)
    drop_weights = isnothing(drop_panel) ? nothing :
        column_drop_panel_weights(columns, drop_panel, γ_concrete, _get_span_axis(slab))
    return compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate;
                                      drop_weights)
end

"""
    column_drop_panel_shears(columns, drop_panel, γ_concrete, span_axis, qD, qL) -> Vector{Force}

Factored drop-panel self-weight at each column. The dead factor is the one
of the combination that sets `qu` ([`governing_dead_factor`](@ref)), so the
drop adds to the slab's tributary shear in that same combination.
"""
function column_drop_panel_shears(columns, drop_panel, γ_concrete, span_axis, qD, qL)
    W = column_drop_panel_weights(columns, drop_panel, γ_concrete, span_axis)
    isnothing(drop_panel) && return W
    return governing_dead_factor(qD, qL) .* W
end

# =============================================================================
# Asap Model Updates
# =============================================================================

"""
    update_asap_column_sections!(struc, columns, material::Concrete; I_factor=0.70)

Propagate final column geometry to Asap model after design converges.

Updates Asap elements with final column sections so subsequent structural 
analyses reflect the actual column sizes.  `I_factor` is the cracking
reduction per ACI 318-11 §10.10.4.1 (default 0.70 for columns).
"""
function update_asap_column_sections!(struc, columns, material::Concrete;
                                      I_factor::Real = 0.70,
                                      reprocess::Bool = true)
    model = struc.asap_model
    
    for col in columns
        section = col.base.section
        isnothing(section) && continue
        
        asap_sec = to_asap_section(section, material; I_factor=I_factor)
        
        for seg_idx in col.base.segment_indices
            edge_idx = struc.segments[seg_idx].edge_idx
            if edge_idx > 0 && edge_idx <= length(model.frame_elements)
                model.frame_elements[edge_idx].section = asap_sec
            end
        end
    end
    
    # Re-process model with updated sections. Callers that sync the building
    # model immediately afterward pass reprocess=false; the section
    # assignments above are the only input that sync reads.
    if reprocess && model.processed
        Asap.process!(model)
    end
end

# =============================================================================
# Method Applicability Checks
# =============================================================================

"""
    check_pattern_loading_requirement(moment_results; verbose=false, threshold=0.75)

Check if pattern loading may be required per ACI 318-11 §13.7.6.

When L/D > 0.75, pattern loading can increase peak moments by up to 15%.
Issues a warning if the ratio exceeds the threshold.
"""
function check_pattern_loading_requirement(moment_results; verbose::Bool=false, threshold::Float64=0.75)
    qL = moment_results.qL
    qD = moment_results.qD
    
    qD_val = ustrip(qD)
    if qD_val < 1e-10
        return  # No dead load, skip check
    end
    
    ratio = ustrip(qL) / qD_val
    
    if ratio > threshold
        if hasproperty(moment_results, :pattern_loading) && moment_results.pattern_loading
            verbose && @debug "Pattern loading applied (ACI 13.7.6)" L_D=round(ratio, digits=2)
        else
            @warn "L/D = $(round(ratio, digits=2)) > $threshold. " *
                  "Pattern loading required per ACI 318-11 §13.7.6 but not applied " *
                  "(DDM assumes uniform loading)." qL qD
        end
    elseif verbose
        @debug "Pattern loading check" L_D_ratio=round(ratio, digits=2) threshold=threshold status="OK"
    end
end

TRACE_REGISTRY[(:resolve_analysis_method, :slab)] =
    TracedFunctionMeta(:resolve_analysis_method, :slab,
                       [:fallback, :failure], nothing, @__FILE__, @__LINE__)

"""
    resolve_analysis_method(method, struc, slab, columns, on_inapplicable;
                            ρ_concrete, verbose=false, tc=nothing, slab_id="",
                            caller="size_flat_plate!")
        -> (method_used, reasons::Vector{String})

Analysis method actually used for `slab`, and why it differs from `method`.

Runs `enforce_method_applicability(method, ...)`.  When DDM (ACI 318-11
§13.6.1) or EFM (§13.7) is not permitted for the layout (corpus: aci-318-11,
page 252):

- `on_inapplicable = :fallback` — returns `FEA()` with the applicability
  violations as `reasons`, keeps the `@warn`, and emits a `:fallback` trace
  event (`reason = "method_not_applicable"`) carrying the requested and used
  methods and every violation.  ACI 318-11 §13.5.1 permits any procedure
  satisfying equilibrium and geometric compatibility; the FEA shell model is
  that general analysis.
- `on_inapplicable = :error` — emits a `:failure` trace event with the same
  data and rethrows the `DDMApplicabilityError` / `EFMApplicabilityError`.

A permitted method is returned unchanged with empty `reasons`.  `caller`
names the entry point in the trace data.
"""
function resolve_analysis_method(method, struc, slab, columns, on_inapplicable::Symbol;
                                 ρ_concrete::Density = NWC_4000.ρ,
                                 verbose::Bool = false,
                                 tc = nothing,
                                 slab_id::AbstractString = "",
                                 caller::AbstractString = "size_flat_plate!")
    _validate_on_inapplicable(on_inapplicable)
    try
        enforce_method_applicability(method, struc, slab, columns;
                                     verbose = verbose, ρ_concrete = ρ_concrete)
    catch e
        (e isa DDMApplicabilityError || e isa EFMApplicabilityError) || rethrow()
        requested = method_name(method)
        reasons = copy(e.violations)
        if on_inapplicable === :error
            emit!(tc, :slab, "resolve_analysis_method", slab_id, :failure;
                  reason = "method_not_applicable", caller = caller,
                  method_requested = requested, on_inapplicable = "error",
                  violations = reasons, n_violations = length(reasons))
            rethrow()
        end
        # A non-rectangular panel goes to the area shell. The frame fallback
        # reads moments at cell centroids and would miss a re-entrant bay.
        irregular = any(r -> startswith(r, "irregular panel:"), reasons)
        fallback = irregular ? panel_shell() : FEA()
        via = fallback isa FEA ? "$(method_name(fallback)) ($(fallback.design_approach))" : method_name(fallback)
        @warn "$(requested) not applicable — falling back to $(via)" violations = join(reasons, "; ")
        emit!(tc, :slab, "resolve_analysis_method", slab_id, :fallback;
              reason = "method_not_applicable", caller = caller,
              method_requested = requested, method_used = method_name(fallback),
              violations = reasons, n_violations = length(reasons))
        enforce_method_applicability(fallback, struc, slab, columns;
                                     verbose = verbose, ρ_concrete = ρ_concrete)
        return fallback, reasons
    end
    # ACI 318-11 §13.4.1 (corpus: aci-318-11, page 248): an opening that is
    # outside §13.4.2 is shown by analysis. That analysis is the area shell.
    # A frame reads moments at cell centroids and would carry the opening as
    # solid panel.
    if !(method isa FEA)
        opening_reasons = _flat_plate_opening_reasons(struc, slab)
        if !isempty(opening_reasons)
            fallback = panel_shell()
            @warn "Openings require analysis — falling back to the area shell" violations = join(opening_reasons, "; ")
            emit!(tc, :slab, "resolve_analysis_method", slab_id, :fallback;
                  reason = "openings_require_analysis", caller = caller,
                  method_requested = method_name(method), method_used = method_name(fallback),
                  violations = opening_reasons, n_violations = length(opening_reasons))
            return fallback, opening_reasons
        end
    end
    return method, String[]
end

function _flat_plate_opening_reasons(struc, slab)
    reasons = String[]
    for ci in slab.cell_indices
        face = struc.cells[ci].face_idx
        pts = [_vertex_xy_m(struc.skeleton, Int(vi))
               for vi in struc.skeleton.face_vertex_indices[face]]
        holes = slab_opening_loops(struc, slab; face_idx = face)
        needs, rs = two_way_opening_needs_analysis(pts, holes; has_beams = false)
        needs && append!(reasons, rs)
    end
    return unique(reasons)
end

"""
    enforce_method_applicability(method::DDM, struc, slab, columns; verbose=false)

Enforce that DDM is valid for the given geometry. Throws if not applicable.
"""
function enforce_method_applicability(method::DDM, struc, slab, columns; verbose::Bool=false, ρ_concrete::Density = NWC_4000.ρ)
    if verbose
        @debug "───────────────────────────────────────────────────────────────────"
        @debug "CHECKING DDM APPLICABILITY (ACI 318-11 §13.6.1)"
        @debug "───────────────────────────────────────────────────────────────────"
    end
    
    result = check_ddm_applicability(struc, slab, columns; throw_on_failure=true, ρ_concrete=ρ_concrete)
    
    if verbose && result.ok
        @debug "DDM applicability check: ✓ PASSED"
    end
end

"""
    enforce_method_applicability(method::EFM, struc, slab, columns; verbose=false)

Enforce that EFM is valid for the given geometry. Throws if not applicable.
"""
function enforce_method_applicability(method::EFM, struc, slab, columns; verbose::Bool=false, kwargs...)
    if verbose
        @debug "───────────────────────────────────────────────────────────────────"
        @debug "CHECKING EFM APPLICABILITY (ACI 318-11 §13.7)"
        @debug "───────────────────────────────────────────────────────────────────"
    end
    
    result = check_efm_applicability(struc, slab, columns; throw_on_failure=true)
    
    if verbose && result.ok
        @debug "EFM applicability check: ✓ PASSED"
    end
end


"""
    enforce_method_applicability(method::FEA, struc, slab, columns; verbose=false)

FEA shell model has no geometric restrictions — always applicable.
However, the post-processing design approach may have assumptions that
are violated for certain geometries.  This function issues warnings
(not errors) for approach-specific concerns.
"""
function enforce_method_applicability(method::FEA, struc, slab, columns; verbose::Bool=false, kwargs...)
    n_cols = length(columns)
    if n_cols < 2
        error("FEA requires at least 2 supporting columns; found $n_cols")
    end

    # ── Approach-specific guardrails (warnings, not hard errors) ──
    _check_fea_approach_applicability(method, struc, slab, columns; verbose=verbose)

    if verbose
        @debug "───────────────────────────────────────────────────────────────────"
        @debug "FEA APPLICABILITY: ✓ Shell model always valid"
        @debug "  $(n_cols) columns, target edge = $(method.target_edge)"
        @debug "  design_approach = $(method.design_approach)"
        @debug "───────────────────────────────────────────────────────────────────"
    end
end

# =============================================================================
# FEA Approach-Specific Guardrails
# =============================================================================

"""
    _check_fea_approach_applicability(method::FEA, struc, slab, columns; verbose=false)

Issue warnings when the chosen FEA design approach has assumptions that may
be violated by the slab geometry.  The FEA solve itself always proceeds —
these are advisory, not blocking.

# Checks by `design_approach`

## `:frame` — Frame-Level + ACI Fractions (§13.6.4–§13.6.6)
Splits frame moments into column and middle strips with the §13.6.4 tables.
ACI 318-11 §13.7.7.5 permits that split on equivalent-frame moments when
§13.6.1.6 is satisfied, so the other §13.6.1 direct-design limits are not
reasons to drop it. [`_frame_fraction_stretches`](@ref) notes a one-way panel,
a non-rectangular panel, and a stiff-row fraction held at the end of the table.

## `:strip` — Design Strip Integration
- Non-quad cells cannot use isoparametric section cuts (falls back to δ-band)
- Non-convex cells cannot use any isoparametric mapping

## `:area` — Per-Element Design
- `:projection` moment transform is unconservative (ignores twisting moment
  envelope); `:wood_armer` is recommended for area-based design.
"""
function _check_fea_approach_applicability(
    method::FEA, struc, slab, columns;
    verbose::Bool = false,
)
    da = method.design_approach

    # ── :frame — §13.7.7.5 permits the split; note where the panel or the table is outside its range ──
    if da == :frame
        stretches = _frame_fraction_stretches(struc, slab, columns)
        if !isempty(stretches)
            @warn "FEA design_approach=:frame distributes frame moments to the column and " *
                  "middle strips by ACI 318-11 §13.6.4. §13.7.7.5 permits that split:\n    • " *
                  join(stretches, "\n    • ")
        elseif verbose
            @debug "FEA :frame guardrails — §13.6.4 tables cover this slab"
        end
    end

    # ── :strip — isoparametric cuts require quad (or convex) cells ──
    if da == :strip
        skel = struc.skeleton
        non_quad = 0
        for ci in slab.cell_indices
            cell = struc.cells[ci]
            n_v = length(skel.face_vertex_indices[cell.face_idx])
            n_v != 4 && (non_quad += 1)
        end
        n_cells = length(slab.cell_indices)
        if non_quad > 0
            @warn "FEA strip: $(non_quad)/$(n_cells) cell(s) are non-quad. " *
                  "Wachspress mapping handles convex N-gons; non-convex " *
                  "cells fall back to δ-band integration."
        end
        if verbose && non_quad == 0
            @debug "FEA :strip guardrails — all cells are quad"
        end
    end

    # ── :area — projection/no_torsion is refused (constructor coerces to Wood–Armer)
    if da == :area && method.moment_transform in (:projection, :no_torsion)
        error("FEA design_approach=:area with moment_transform=:$(method.moment_transform) " *
              "is refused — unconservative for twisting. Use :wood_armer.")
    end

    return nothing
end

"""
    _frame_fraction_stretches(struc, slab, columns) -> Vector{String}

Notes on applying the §13.6.4 column-strip fractions to this slab.
Empty when the panel is rectangular, the longer span is at most twice the
shorter, and no stiff-row fraction is held past the table.

ACI 318-11 §13.7.7.5 (corpus: aci-318-11, page 262) permits the §13.6.4–§13.6.6
distribution on frame moments if §13.6.1.6 is satisfied. A failed three-span,
successive-span, offset, or L/D limit is therefore not listed. What is listed:

- A panel that is not rectangular (§13.6.1.2, page 252). The strip widths are
  read from one ℓ2.
- Longer span / shorter span greater than 2. R13.6.1.2 (page 252) says that
  panel resists the moment in the shorter span essentially as a one-way slab.
  Read per panel from the column layout when that layout is available, since
  the slab's stored spans are the maximum of each direction and can hide a
  long panel. Otherwise the slab spans are used, once. The αf1 = 0 row of
  §13.6.4.1 is the same at every ℓ2/ℓ1, so the split is still used.
- The αf1·ℓ2/ℓ1 ≥ 1 row, which a wall parallel to the span selects, at ℓ2/ℓ1
  outside 0.5–2.0. §13.6.4.1 (page 255) tabulates ℓ2/ℓ1 = 0.5, 1.0, 2.0 and
  interpolates between them; [`aci_column_strip_fractions`](@ref) holds the end
  value beyond. Each span direction is checked on the row its own split uses.

§13.6.1.6 governs panels with beams between supports on all sides. These slabs
have no beams, so it is not evaluated.
"""
function _frame_fraction_stretches(struc, slab, columns)
    out = String[]
    l1 = slab.spans.primary
    l2 = slab.spans.secondary
    span_axis = _get_span_axis(slab)

    # §13.6.1.2 (corpus: aci-318-11, page 252), with the same manual
    # `is_rectangular` override as `check_ddm_applicability`.
    rect_override = hasproperty(slab, :is_rectangular) ? slab.is_rectangular : nothing
    if rect_override === false
        push!(out, "§13.6.1.2: slab is marked non-rectangular (is_rectangular = false)")
    elseif rect_override !== true
        append!(out, _panel_rectangularity_violations(struc, slab, span_axis; columns))
    end

    (l1 > zero(l1) && l2 > zero(l2)) || return out
    # §13.6.1.2 and R13.6.1.2 (corpus: aci-318-11, page 252). The column
    # layout names each panel. The stored spans are one pair, the maximum
    # of each direction, so they are the fallback and the ratio the split uses.
    panel_aspect = _panel_aspect_violations(struc, slab, columns, span_axis)
    append!(out, panel_aspect)
    panel_ratio = ustrip(u"m", max(l1, l2)) / ustrip(u"m", min(l1, l2))
    if isempty(panel_aspect) && panel_ratio > 2.0
        push!(out, "R13.6.1.2: longer / shorter span = $(round(panel_ratio, digits=2)) > 2, " *
                   "so the slab resists the moment in the shorter span essentially " *
                   "as a one-way slab. The §13.6.4 flat-plate row does not change " *
                   "with ℓ2/ℓ1, and that split is still used (corpus: aci-318-11, page 252)")
    elseif !isempty(panel_aspect)
        push!(out, "R13.6.1.2: such a panel resists the moment in the shorter span " *
                   "essentially as a one-way slab. The §13.6.4 flat-plate row does " *
                   "not change with ℓ2/ℓ1, and that split is still used " *
                   "(corpus: aci-318-11, page 252)")
    end
    perp = (-span_axis[2], span_axis[1])
    for (name, axis, la, lb) in (("primary", span_axis, l1, l2),
                                 ("secondary", perp, l2, l1))
        _column_strip_row(struc, slab, axis, lb).stiff || continue
        ratio = ustrip(u"m", lb) / ustrip(u"m", la)
        # §13.6.4.1 (corpus: aci-318-11, page 255): columns ℓ2/ℓ1 = 0.5, 1.0, 2.0.
        0.5 <= ratio <= 2.0 && continue
        push!(out, "§13.6.4.1: $name direction uses the αf1·ℓ2/ℓ1 ≥ 1 row " *
                   "(wall parallel to the span) at ℓ2/ℓ1 = $(round(ratio, digits=2)), " *
                   "outside the tabulated 0.5–2.0; the end value is used")
    end
    return out
end
