# =============================================================================
# Helper Functions
# =============================================================================

"""
    _efm_span(span_idx, l1, l2, ln, h, Ecs, c_par_l, c_tr_l, c_par_r, c_tr_r;
              drop_panel=nothing, drop_width=nothing)

One slab-beam span. `c_par` is the column face parallel to the span and
`c_tr` is the face transverse to it, which is what PCA Table A1 calls c1 and c2.

A flat slab takes k, COF, and the uniform-load m from PCA Tables A2–A5 at
the drop's h_drop/h. `Is_drop` is the gross composite section of the slab
strip `l2` and the drop of width `drop_width` (ACI 318-11 §13.7.3.2:
gross concrete area outside the joint). `drop_width` defaults to the full
drop, `2 a_drop_2`; a frame at a slab edge passes the clipped width.

ENGINEERING JUDGMENT: Tables A2–A5 assume drops of length l1/6 at both
ends. The ASAP solver models the actual drop extents.
"""
function _efm_span(span_idx, l1, l2, ln, h, Ecs, c_par_l, c_tr_l, c_par_r, c_tr_r;
                   drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
                   drop_width = nothing)
    slab_factors = if isnothing(drop_panel)
        pca_slab_beam_factors(c_par_l, l1, c_tr_l, l2)
    else
        np = pca_slab_beam_factors_np(c_par_l, l1, c_tr_l, l2, drop_panel.h_drop, h)
        (k = np.k, COF = np.COF, m = np.m_uniform)
    end
    Is = slab_moment_of_inertia(l2, h)
    Ksb = slab_beam_stiffness_Ksb(Ecs, Is, l1, c_par_l, c_tr_l; k_factor=slab_factors.k)
    Is_drop = isnothing(drop_panel) ? nothing :
        uconvert(unit(Is), gross_section_at_drop(l2, h, drop_panel;
            b_drop = something(drop_width, drop_extent_2(drop_panel))).Ig)
    return EFMSpanProperties{typeof(Is), typeof(Ksb)}(
        span_idx, span_idx, span_idx + 1,
        l1, l2, ln, h,
        c_par_l, c_tr_l, c_par_r, c_tr_r,
        Is, Ksb,
        slab_factors.m, slab_factors.COF, slab_factors.k,
        drop_panel, Is_drop,
    )
end

"""
    _frame_drop_width(drop_panel, l2, strip_extents) -> Length

Drop width across one equivalent frame: `a_drop_2` on each side of the
column line, cut at the frame's strip extents. A frame on a slab edge has
its outer extent at the edge, so the drop stops there too.
"""
function _frame_drop_width(drop_panel::DropPanelGeometry, l2::Length, strip_extents)
    a = drop_panel.a_drop_2
    strip_extents === nothing && return min(2a, l2)
    e_neg, e_pos = strip_extents
    e_neg === nothing && return min(2a, l2)
    return min(a, e_neg * u"m") + min(a, e_pos * u"m")
end

"""
    _frame_drop_loads(spans, columns, q_drop, b_drop) -> Vector or nothing

Factored drop line load on each span: `w = q_drop × b_drop` from each
column centre to the drop edge (`a_drop_1` along the span, at most half the
span). A wall support has no drop.
"""
function _frame_drop_loads(spans, columns, q_drop, b_drop)
    has_drop_panels(spans[1]) || return nothing
    w = uconvert(kip / u"ft", q_drop * b_drop)
    return map(eachindex(spans)) do s
        sp = spans[s]
        a = sp.drop.a_drop_1
        (w = w,
         a_left  = _is_wall_support(columns[s]) ? zero(a) : min(a, sp.l1 / 2),
         a_right = _is_wall_support(columns[s + 1]) ? zero(a) : min(a, sp.l1 / 2))
    end
end

"""
Spans of one column line. `proj_m` is the station of each column in meters
along `axis`, already sorted. The clear span is center-to-center minus the
two face projections.
"""
function _spans_from_projections(columns, proj_m::Vector{Float64}, axis, l2::Length, h, Ecs;
                                drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
                                drop_width = nothing)
    n = length(columns)
    n >= 2 || error("EFM frame line needs at least two columns")
    length(proj_m) == n || error("EFM frame line projections do not match its columns")
    perp = (-axis[2], axis[1])
    spans = Vector{EFMSpanProperties}(undef, n - 1)
    for i in 1:(n - 1)
        l1 = (proj_m[i + 1] - proj_m[i]) * u"m"
        half_l = _eq137_face_half(columns[i], axis)
        half_r = _eq137_face_half(columns[i + 1], axis)
        ln = l1 - half_l - half_r
        ln > 0u"m" || error(
            "EFM clear span is non-positive between columns $i and $(i + 1) " *
            "(center-to-center $l1, faces $(2 * half_l) and $(2 * half_r)). " *
            "Column projections are meters along the frame.")
        spans[i] = _efm_span(
            i, l1, l2, ln, h, Ecs,
            2 * half_l, 2 * _eq137_face_half(columns[i], perp),
            2 * half_r, 2 * _eq137_face_half(columns[i + 1], perp);
            drop_panel, drop_width,
        )
    end
    return spans
end

"""
Split column indices into column lines.

Stations are the coordinate transverse to the span. A gap larger than half
the median bay starts a new line, so a millimeter vertex mismatch stays on
its line and the next panel does not.
"""
function _cluster_transverse(t::Vector{Float64})
    order = sortperm(t)
    groups = Vector{Int}[]
    isempty(order) && return groups
    gaps = [t[order[i + 1]] - t[order[i]] for i in 1:(length(order) - 1)]
    positive = filter(>(0.05), gaps)
    bay = isempty(positive) ? Inf : 0.5 * sort(positive)[(end + 1) ÷ 2]
    current = Int[order[1]]
    for i in eachindex(gaps)
        if gaps[i] > bay
            push!(groups, current)
            current = Int[order[i + 1]]
        else
            push!(current, order[i + 1])
        end
    end
    push!(groups, current)
    return groups
end

"""
Half-widths of frame `k`, in metres, toward decreasing and increasing transverse station.

ACI 318-11 §13.7.2.4 (corpus: aci-318-11, page 259): an edge frame has slab
on one side only, so one half-width is zero.
"""
function _line_strip_extents(k::Int, n::Int, stations::Vector{Float64})
    neg = k == 1 ? 0.0 : (stations[k] - stations[k - 1]) / 2
    pos = k == n ? 0.0 : (stations[k + 1] - stations[k]) / 2
    return neg, pos
end

"""
Transverse span on each side of column line `k` of `n`, for the torsional
members (ACI 318-11 R13.7.4–R13.7.5, corpus: aci-318-11, pages 260–261).

A side with no neighbouring line has no adjacent panel, so its span is zero.
A lone line returns `nothing`; the joint positions then set the members.
"""
function _line_torsion_l2(k::Int, n::Int, stations::Vector{Float64})
    n == 1 && return nothing
    neg = k == 1 ? 0.0 : stations[k] - stations[k - 1]
    pos = k == n ? 0.0 : stations[k + 1] - stations[k]
    return (neg * u"m", pos * u"m")
end

"""
Tributary width of column line `k` of `n`, between the panel centerlines.

ACI 318-11 §13.7.2.2 (corpus: aci-318-11, page 259): an interior frame is
bounded by the panel centerline on each side of the column line. An edge
line gets half the bay here; [`_equivalent_frames`](@ref) adds the slab past
the line out to the slab edge (§13.7.2.4).

A single line is the panel strip the caller already measured.
"""
function _line_tributary_width(k::Int, n::Int, stations::Vector{Float64}, panel_l2::Length)
    n == 1 && return panel_l2
    left = k == 1 ? 0.0 : (stations[k] - stations[k - 1]) / 2
    right = k == n ? 0.0 : (stations[k + 1] - stations[k]) / 2
    width = (left + right) * u"m"
    width > 0u"m" || error("EFM frame line $k has a non-positive tributary width")
    return width
end

"""
Slab past an edge column line facing `dir`, in metres (ACI 318-11 §13.7.2.4).

The columns must all sit on one run of the floor's slab edge
([`slab_edge_width_at`](@ref)). Zero without skeleton geometry, or when the
line is not on a free slab edge.
"""
function _frame_edge_strip_m(struc, columns, dir::NTuple{2, Float64})
    _eq137_geometry_available(struc) || return 0.0
    hasproperty(struc, :columns) || return 0.0
    vis = [col_vertex_idx(c) for c in columns if col_vertex_idx(c) > 0]
    isempty(vis) && return 0.0
    z = _eq137_vertex_z(struc, first(vis))
    z === nothing && return 0.0
    pts = [_eq137_vertex_xy_m(struc.skeleton, vi) for vi in vis]
    return slab_edge_width_at(struc, z, pts, dir)
end

"""Column lines along `axis`, each sorted in the span direction."""
function _column_line_groups(columns, xy, axis, panel_l2::Length)
    axes = _eq137_unit_axes(axis)
    axes === nothing && error("EFM span axis has zero length")
    ax, perp = axes
    s = [xy[i][1] * ax[1] + xy[i][2] * ax[2] for i in eachindex(columns)]
    t = [xy[i][1] * perp[1] + xy[i][2] * perp[2] for i in eachindex(columns)]
    groups = _cluster_transverse(t)
    stations = [sum(t[i] for i in g) / length(g) for g in groups]
    lines = map(enumerate(groups)) do (k, g)
        idx = g[sortperm(s[g])]
        cols = [columns[i] for i in idx]
        neg, pos = _line_strip_extents(k, length(groups), stations)
        (
            columns = cols,
            projections = [s[i] for i in idx],
            width = _line_tributary_width(k, length(groups), stations, panel_l2),
            extent_neg = neg,
            extent_pos = pos,
            torsion_l2 = _line_torsion_l2(k, length(groups), stations),
            axis = ax,
        )
    end
    return lines
end

"""Meters, structural centerline. Without skeleton geometry the list is already one line at spacing `l1`."""
function _efm_xy(struc, columns, l1::Length, axis)
    if _eq137_geometry_available(struc) && all(c -> col_vertex_idx(c) > 0, columns)
        return [_eq137_structural_xy(struc, col) for col in columns]
    end
    axes = _eq137_unit_axes(axis)
    ax = axes === nothing ? (1.0, 0.0) : axes[1]
    step = ustrip(u"m", l1)
    return [((i - 1) * step * ax[1], (i - 1) * step * ax[2]) for i in eachindex(columns)]
end

"""
One entry per column line, in the shape `run_moment_analysis(::EFM, line, ...)` reads.

`column_projections` are meters along the span.
"""
function _equivalent_frames(struc, columns, setup; slab=nothing)
    grouped = _column_line_groups(
        columns,
        _efm_xy(struc, columns, setup.l1, setup.span_axis),
        setup.span_axis,
        setup.l2,
    )
    lines = NamedTuple[]
    n = length(grouped)
    for (k, g) in enumerate(grouped)
        # ACI 318-11 §13.7.2.4 (corpus: aci-318-11, page 259): a frame on an
        # edge is bounded by that edge, and the slab edge lies past the
        # outermost column line by the largest column face on that run.
        perp = (-g.axis[2], g.axis[1])
        out_neg = n > 1 && k == 1 ? _frame_edge_strip_m(struc, g.columns, (-perp[1], -perp[2])) : 0.0
        out_pos = n > 1 && k == n ? _frame_edge_strip_m(struc, g.columns, perp) : 0.0
        line = (
            columns = g.columns,
            projections = g.projections,
            width = g.width + (out_neg + out_pos) * u"m",
            extent_neg = g.extent_neg + out_neg,
            extent_pos = g.extent_pos + out_pos,
            torsion_l2 = g.torsion_l2,
            axis = g.axis,
        )
        append!(lines, _lines_with_wall_supports(struc, slab, line))
    end
    for line in lines
        length(line.columns) >= 2 || error(
            "EFM column line has a single column. ACI 318-11 §13.7.2.2 " *
            "(corpus: aci-318-11, page 259) requires a row of columns and slab-beam strips.")
    end
    return map(lines) do line
        (
            columns = line.columns,
            column_projections = line.projections,
            tributary_width = line.width,
            strip_extents = (line.extent_neg, line.extent_pos),
            torsion_l2 = line.torsion_l2,
            direction = line.axis,
        )
    end
end

"""
Place wall supports on one column line, and drop any span that crosses an opening.

ACI 318-11 R13.7.3.3 (corpus: aci-318-11, page 259): a wall is a support, and
R13.7.2 puts the frame on the support centerline. R13.1 (page 243): a wall
that supports the whole panel edge is a beam of infinite stiffness. Here the
panel edge is this frame's strip (§13.7.2.2, §13.7.2.4). The joint is fixed
only when the wall covers that strip. A wall that covers part of it is a
column whose transverse face is the covered length. §13.7.3.3 is singular
as c2/l2 → 1, so a covered fraction past one half is the same fixed joint.

A span whose midpoint is outside the slab, such as a shaft, is not a span.
Neither is a span that lies on a wall parallel to the frame: the slab bears
on that wall and has no span there.
"""
function _lines_with_wall_supports(struc, slab, line)
    slab === nothing && return [line]
    segs = supporting_wall_segments(struc, slab)
    isempty(segs) && return [line]
    placed = _line_transverse(struc, line)
    placed === nothing && return [line]
    t_line, perp = placed
    ax = line.axis
    cols = Any[col for col in line.columns]
    proj = collect(Float64, line.projections)
    height = _line_story_height(cols)
    for seg in segs
        station = _wall_station_on_line(seg, ax, perp, t_line)
        station === nothing && continue
        any(p -> abs(p - station) < 0.25, proj) && continue
        overlap, strip = _wall_strip_overlap(seg, perp, t_line, line.extent_neg, line.extent_pos)
        overlap < 0.05 && continue
        # The joint is fixed when the wall covers this strip. It is also fixed
        # past half the strip: c2/l2 would then exceed the §13.7.3.3 guard.
        # Exactly half stays a column.
        covers = strip > 0 && overlap >= strip - 0.05
        past_half = strip > 0 && overlap > 0.5 * strip + 1e-6
        fixed = covers || past_half
        thick = _wall_thickness(struc, seg)
        if fixed
            t = thick === nothing ? 0.0u"m" : thick
            push!(cols, _wall_support(t, t, ax; fixed=true, height=height, seg=seg))
        else
            thick === nothing && continue
            push!(cols, _wall_support(thick, overlap * u"m", ax; fixed=false, height=height,
                                      seg=seg))
        end
        push!(proj, station)
    end
    order = sortperm(proj)
    cols = cols[order]
    proj = proj[order]
    return _split_line_at_openings(struc, slab, cols, proj, ax, t_line, line.width, segs;
                                   torsion_l2 = line.torsion_l2,
                                   extent_neg = line.extent_neg, extent_pos = line.extent_pos)
end

"""Transverse coordinate of the real columns on a line, and the unit perpendicular."""
function _line_transverse(struc, line)
    ax = line.axis
    perp = (-ax[2], ax[1])
    ts = Float64[]
    for col in line.columns
        col_vertex_idx(col) > 0 || continue
        xy = _eq137_structural_xy(struc, col)
        push!(ts, xy[1] * perp[1] + xy[2] * perp[2])
    end
    isempty(ts) && return nothing
    return sum(ts) / length(ts), perp
end

"""Story height of a real column on the line. Wall joints copy it."""
function _line_story_height(cols)
    for col in cols
        hasproperty(col, :wall_fixed) && continue
        hasproperty(col, :base) && hasproperty(col.base, :L) && return col.base.L
    end
    return 0.0u"m"
end

"""
Station where a wall perpendicular to `ax` crosses the line, or `nothing`.
"""
function _wall_station_on_line(seg, ax, perp, t_line)
    wx = seg[2][1] - seg[1][1]
    wy = seg[2][2] - seg[1][2]
    wlen = hypot(wx, wy)
    wlen < 1e-3 && return nothing
    abs(wx * ax[1] + wy * ax[2]) / wlen > 0.35 && return nothing
    t1 = seg[1][1] * perp[1] + seg[1][2] * perp[2]
    t2 = seg[2][1] * perp[1] + seg[2][2] * perp[2]
    (t1 - t_line) * (t2 - t_line) > 1e-3 && min(abs(t1 - t_line), abs(t2 - t_line)) > 0.05 &&
        return nothing
    denom = t2 - t1
    frac = abs(denom) < 1e-9 ? 0.0 : (t_line - t1) / denom
    (frac < -0.02 || frac > 1.02) && return nothing
    frac = clamp(frac, 0.0, 1.0)
    s1 = seg[1][1] * ax[1] + seg[1][2] * ax[2]
    s2 = seg[2][1] * ax[1] + seg[2][2] * ax[2]
    return s1 + frac * (s2 - s1)
end

"""
A wall support. `c_parallel` is the face along the span and `c_transverse`
is the face across it. Local x follows the span so §13.7.3.3 uses
`c_parallel` as c1. `seg` is the wall it stands for, so the joint's
moment can be reported against that wall.
"""
function _wall_support(c_parallel, c_transverse, axis; fixed::Bool, height, seg = nothing)
    return (
        wall_seg = seg,
        c1 = c_parallel,
        c2 = c_transverse,
        θ = atan(axis[2], axis[1]),
        vertex_idx = 0,
        position = :edge,
        shape = :rectangular,
        wall_fixed = fixed,
        column_above = nothing,
        base = (L = height,),
    )
end

"""
Length of `seg` that lies inside this frame's strip, and the strip width.

Both are metres along the transverse axis. A wall that only touches the
line from outside the strip has no overlap.
"""
function _wall_strip_overlap(seg, perp, t_line, extent_neg, extent_pos)
    t1 = seg[1][1] * perp[1] + seg[1][2] * perp[2]
    t2 = seg[2][1] * perp[1] + seg[2][2] * perp[2]
    wlo, whi = minmax(t1, t2)
    slo, shi = t_line - extent_neg, t_line + extent_pos
    overlap = min(shi, whi) - max(slo, wlo)
    return max(overlap, 0.0), extent_neg + extent_pos
end

"""
True when a wall parallel to the frame covers more than half of the span.

The span then bears on the wall and is not a frame span.
"""
function _span_lies_on_wall(segs, ax, t_line, s0, s1)::Bool
    lo, hi = minmax(s0, s1)
    span = hi - lo
    span < 1e-3 && return false
    perp = (-ax[2], ax[1])
    for seg in segs
        _wall_parallel_to_axis(seg, ax) || continue
        t1 = seg[1][1] * perp[1] + seg[1][2] * perp[2]
        t2 = seg[2][1] * perp[1] + seg[2][2] * perp[2]
        max(abs(t1 - t_line), abs(t2 - t_line)) > 0.25 && continue
        a1 = seg[1][1] * ax[1] + seg[1][2] * ax[2]
        a2 = seg[2][1] * ax[1] + seg[2][2] * ax[2]
        overlap = min(hi, max(a1, a2)) - max(lo, min(a1, a2))
        overlap > 0.5 * span && return true
    end
    return false
end

"""
Columns with no remaining span in this direction because each span that
touches them lies on a parallel wall.

The span is not a frame span. The column's moment in this direction is
written as zero by the caller. A span removed because it leaves the slab
does not qualify.
"""
function _columns_carried_by_wall(struc, columns, setup; slab)
    ids = Set{UInt}()
    slab === nothing && return ids
    segs = supporting_wall_segments(struc, slab)
    isempty(segs) && return ids
    grouped = _column_line_groups(
        columns,
        _efm_xy(struc, columns, setup.l1, setup.span_axis),
        setup.span_axis,
        setup.l2,
    )
    for line in grouped
        _add_wall_borne_columns!(ids, struc, slab, line, segs)
    end
    return ids
end

function _add_wall_borne_columns!(ids, struc, slab, line, segs)
    placed = _line_transverse(struc, line)
    placed === nothing && return ids
    t_line, = placed
    cols = line.columns
    proj = line.projections
    ax = line.axis
    n = length(cols)
    n < 2 && return ids
    contains = _slab_plan_contains(struc, slab; boundary = true)
    perp = (-ax[2], ax[1])
    on_wall = falses(n - 1)
    off_slab = falses(n - 1)
    for i in 1:(n - 1)
        mid = (proj[i] + proj[i + 1]) / 2
        P = (mid * ax[1] + t_line * perp[1], mid * ax[2] + t_line * perp[2])
        on_wall[i] = _span_lies_on_wall(segs, ax, t_line, proj[i], proj[i + 1])
        off_slab[i] = !(contains === nothing || contains(P))
    end
    for i in 1:n
        touches = Int[]
        i > 1 && push!(touches, i - 1)
        i < n && push!(touches, i)
        isempty(touches) && continue
        all(s -> on_wall[s] && !off_slab[s], touches) || continue
        push!(ids, objectid(cols[i]))
    end
    return ids
end

"""One line per run of supports whose midpoints lie on the slab."""
function _split_line_at_openings(struc, slab, cols, proj, ax, t_line, width, segs=();
                                 torsion_l2 = nothing, extent_neg = nothing, extent_pos = nothing)
    contains = _slab_plan_contains(struc, slab; boundary = true)
    perp = (-ax[2], ax[1])
    ranges = UnitRange{Int}[]
    start = 1
    for i in 1:(length(cols) - 1)
        mid = (proj[i] + proj[i + 1]) / 2
        P = (mid * ax[1] + t_line * perp[1], mid * ax[2] + t_line * perp[2])
        on_slab = contains === nothing || contains(P)
        on_wall = _span_lies_on_wall(segs, ax, t_line, proj[i], proj[i + 1])
        if !on_slab || on_wall
            i >= start + 1 && push!(ranges, start:i)
            start = i + 1
        end
    end
    start < length(cols) && push!(ranges, start:length(cols))
    lines = NamedTuple[]
    for r in ranges
        length(r) < 2 && continue
        push!(lines, (
            columns = cols[r],
            projections = proj[r],
            width = width,
            extent_neg = extent_neg,
            extent_pos = extent_pos,
            torsion_l2 = torsion_l2,
            axis = ax,
        ))
    end
    return lines
end

"""
Drop the cached Asap model when this line is not the line that built it.
Section and load updates stay valid across a thickness change: span lengths
do not depend on `h`. A new drop panel moves the drop-edge nodes, so it
rebuilds too.
"""
function _reuse_line_model!(efm_cache, spans)
    isnothing(efm_cache) && return
    if efm_cache.initialized && !isnothing(efm_cache._last_spans)
        old = efm_cache._last_spans
        same = length(old) == length(spans) && all(eachindex(spans)) do i
            old[i].l1 == spans[i].l1 && old[i].ln == spans[i].ln && old[i].l2 == spans[i].l2 &&
                old[i].drop == spans[i].drop
        end
        same || (efm_cache.initialized = false)
    end
    if efm_cache.initialized && efm_cache.n_spans != length(spans)
        efm_cache.initialized = false
    end
    efm_cache._last_spans = spans
    return
end

"""
Solve one frame line. Hardy Cross and ASAP share this path, including the
pattern envelope. Returns the demand named tuple and whether a pattern was applied.
"""
function _solve_efm_line(method::EFM, spans, columns, joint_positions, struc,
                         Ecs, Ecc, qu, qD, qL;
                         ν_concrete::Float64 = 0.20,
                         ρ_concrete = 2380.0u"kg/m^3",
                         verbose::Bool = false,
                         efm_cache::Union{Nothing, EFMModelCache} = nothing,
                         col_I_factor::Float64 = 0.70,
                         torsion_l2 = nothing,
                         drop_loads = nothing,
                         drop_shears = nothing)
    l2 = spans[1].l2
    n_spans = length(spans)
    ln_avg = sum(sp.ln for sp in spans) / n_spans
    H = _get_column_height(columns)
    col_shape_val = _line_column_shape(columns)
    # ASAP cracked stubs take the caller's factor. Hardy Cross uses gross Ig;
    # its column stiffness is Kec. ACI 318-11 §10.10.4.1.
    incoming_col_I = col_I_factor
    col_I_factor = (method.solver == :asap && method.cracked_columns) ? incoming_col_I : 1.0
    use_kc_only = method.column_stiffness == :Kc

    jKec = method.solver == :hardy_cross ?
        _compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc;
                           column_shape=col_shape_val, use_kc_only=use_kc_only,
                           columns=columns, torsion_l2) :
        nothing
    kec_factors = method.solver == :asap ?
        _compute_kec_reduction_factors(spans, joint_positions, H, Ecs, Ecc;
                                       column_shape=col_shape_val, use_kc_only=use_kc_only,
                                       columns=columns, torsion_l2) :
        nothing

    _solve_once(qu_arg) = _with_face_moments(_solve_raw(qu_arg), spans, columns, qu_arg;
                                             drop_loads)

    function _solve_raw(qu_arg)
        if method.solver == :asap
            if !isnothing(efm_cache) && efm_cache.initialized
                _update_efm_sections_and_loads!(
                    efm_cache, spans, qu_arg, Ecs, Ecc,
                    ν_concrete, ρ_concrete, columns;
                    col_I_factor, kec_factors, drop_loads,
                )
                solve_efm_frame!(efm_cache.model; full_process=false, loads_only=false)
                return extract_span_moments(
                    efm_cache.model, efm_cache.span_elements, spans; qu=qu_arg, drop_loads)
            else
                model, span_elements, col_stubs = build_efm_asap_model(
                    spans, joint_positions, qu;
                    Ecs = Ecs, Ecc = Ecc,
                    ν_concrete = ν_concrete,
                    ρ_concrete = ρ_concrete,
                    columns = columns,
                    verbose = verbose,
                    col_I_factor = col_I_factor,
                    kec_factors = kec_factors,
                    drop_loads = drop_loads,
                )
                qu_arg isa Vector && _set_efm_slab_loads!(model, spans, qu_arg, drop_loads)
                solve_efm_frame!(model)
                sm = extract_span_moments(model, span_elements, spans; qu=qu_arg, drop_loads)
                !isnothing(efm_cache) && _populate_efm_cache!(
                    efm_cache, model, span_elements, col_stubs, spans)
                return sm
            end
        elseif method.solver == :hardy_cross
            return solve_moment_distribution(
                spans, jKec, joint_positions, qu_arg;
                verbose = verbose && !(qu_arg isa Vector),
                drop_loads,
            )
        else
            error("Unknown EFM solver: $(method.solver)")
        end
    end

    span_moments = _solve_once(qu)
    use_pattern = method.pattern_loading && requires_pattern_loading(qD, qL) && n_spans >= 2
    env = _efm_demands_with_pattern(
        span_moments, struc, columns, qu, qD, qL, l2, ln_avg;
        use_pattern, solve_once=_solve_once, drop_shears, drop_loads,
    )
    return env, use_pattern
end

"""
Solve every column line and write each column's demands back to its index
in `columns`. Strip moments are the largest absolute value among the lines.
`setup.M0`, `l1`, `l2`, and `ln` stay the panel design strip.

One `EFMModelCache` is one Asap model. It is used only when the floor is a
single line. Several lines would overwrite each other's topology.
"""
function _analyze_equivalent_frames(method::EFM, struc, columns, h, fc, Ecs, γ_concrete, setup;
                                   slab=nothing,
                                   ν_concrete::Float64 = 0.20,
                                   verbose::Bool = false,
                                   efm_cache::Union{Nothing, EFMModelCache} = nothing,
                                   drop_panel = nothing,
                                   col_I_factor::Float64 = 0.70,
                                   column_concrete = nothing)
    lines = _equivalent_frames(struc, columns, setup; slab=slab)
    isempty(lines) && error("EFM found no frame lines")
    Ecc = _column_Ec(columns, column_concrete, fc, γ_concrete)
    n = length(columns)
    MomentT = typeof(1.0kip * u"ft")
    ForceT = typeof(1.0kip)
    column_moments = Vector{MomentT}(undef, n)
    column_shears = Vector{ForceT}(undef, n)
    unbalanced_moments = Vector{MomentT}(undef, n)
    covered = falses(n)
    index_of = Dict{UInt, Int}(objectid(col) => i for (i, col) in enumerate(columns))
    M_neg_ext = M_neg_int = M_pos = M_wall_ext = M_wall_int = nothing
    M_neg_ext_face = M_neg_int_face = nothing
    wall_lists = Any[]
    face_lists = Any[]
    use_pattern = false
    one_line = length(lines) == 1
    for (k, line) in enumerate(lines)
        res = run_moment_analysis(
            method, line, struc, h, fc, Ecs, Ecc, setup.qu, setup.qD, setup.qL;
            ν_concrete, ρ_concrete = γ_concrete,
            verbose = verbose && k == 1,
            efm_cache = one_line ? efm_cache : nothing,
            drop_panel, col_I_factor,
        )
        use_pattern |= res.pattern_loading
        res.wall_transfer === nothing || push!(wall_lists, res.wall_transfer)
        push!(face_lists, res.wall_faces)
        M_neg_ext = isnothing(M_neg_ext) ? res.M_neg_ext : _raise_abs(M_neg_ext, res.M_neg_ext)
        M_neg_int = isnothing(M_neg_int) ? res.M_neg_int : _raise_abs(M_neg_int, res.M_neg_int)
        M_pos = isnothing(M_pos) ? res.M_pos : _raise_abs(M_pos, res.M_pos)
        M_wall_ext = isnothing(M_wall_ext) ? res.M_wall_ext : _raise_abs(M_wall_ext, res.M_wall_ext)
        M_wall_int = isnothing(M_wall_int) ? res.M_wall_int : _raise_abs(M_wall_int, res.M_wall_int)
        M_neg_ext_face = isnothing(M_neg_ext_face) ? res.M_neg_ext_face :
            _raise_abs(M_neg_ext_face, res.M_neg_ext_face)
        M_neg_int_face = isnothing(M_neg_int_face) ? res.M_neg_int_face :
            _raise_abs(M_neg_int_face, res.M_neg_int_face)
        for (j, col) in enumerate(line.columns)
            # A wall joint is not one of the floor's columns. Its moment
            # stays in the slab envelope.
            i = get(index_of, objectid(col), 0)
            i == 0 && continue
            covered[i] && error("A column lies on two EFM frame lines")
            column_moments[i] = uconvert(kip * u"ft", res.column_moments[j])
            column_shears[i] = uconvert(kip, res.column_shears[j])
            unbalanced_moments[i] = uconvert(kip * u"ft", res.unbalanced_moments[j])
            covered[i] = true
        end
    end
    # A column whose every span in this direction lies on a parallel wall has
    # no frame span. The slab bears on the wall. The column moment here is zero.
    # An opening that removes the column is still an error.
    borne = _columns_carried_by_wall(struc, columns, setup; slab)
    for i in 1:n
        covered[i] && continue
        objectid(columns[i]) in borne || continue
        column_moments[i] = zero(MomentT)
        column_shears[i] = zero(ForceT)
        unbalanced_moments[i] = zero(MomentT)
        covered[i] = true
    end
    n_missed = n - count(covered)
    if n_missed != 0
        pts = String[]
        for i in 1:n
            covered[i] && continue
            xy = _eq137_structural_xy(struc, columns[i])
            push!(pts, "($(round(xy[1]; digits=2)), $(round(xy[2]; digits=2)))")
        end
        error("EFM left $n_missed column(s) off every frame line: " * join(pts, ", "))
    end
    verbose && @debug "EFM frame lines" n_lines=length(lines) pattern=use_pattern
    return MomentAnalysisResult(
        uconvert(kip * u"ft", setup.M0),
        uconvert(kip * u"ft", M_neg_ext),
        uconvert(kip * u"ft", M_neg_int),
        uconvert(kip * u"ft", M_pos),
        setup.qu, setup.qD, setup.qL,
        uconvert(u"ft", setup.l1),
        uconvert(u"ft", setup.l2),
        uconvert(u"ft", setup.ln),
        uconvert(u"ft", setup.c1_avg),
        column_moments,
        column_shears,
        unbalanced_moments,
        uconvert(kip, setup.qu * setup.l2 * setup.ln / 2);
        pattern_loading = use_pattern,
        M_wall_ext = uconvert(kip * u"ft", something(M_wall_ext, zero(setup.M0))),
        M_wall_int = uconvert(kip * u"ft", something(M_wall_int, zero(setup.M0))),
        M_neg_ext_face = uconvert(kip * u"ft", M_neg_ext_face),
        M_neg_int_face = uconvert(kip * u"ft", M_neg_int_face),
        wall_transfer = _sum_wall_transfer(wall_lists),
        wall_faces = _sum_wall_faces(face_lists),
    )
end

"""
Pattern-on and pattern-off equivalent frames, both directions, with column
demands at the supporting-column index. FEA `:efm_amp` scales each shell
demand by the frame that owns that column.
"""
function _efm_pattern_baselines(struc, slab, columns, h, fc, Ecs, γ_concrete;
                               drop_panel = nothing,
                               col_I_factor::Float64 = 0.70,
                               ν_concrete::Float64 = 0.20,
                               column_concrete = nothing)
    on = EFM(solver=:hardy_cross, column_stiffness=:Kec, pattern_loading=true, cracked_columns=false)
    off = EFM(solver=:hardy_cross, column_stiffness=:Kec, pattern_loading=false, cracked_columns=false)
    kw = (; drop_panel, col_I_factor, ν_concrete, column_concrete, verbose=false)
    return (
        primary_on = run_moment_analysis(on, struc, slab, columns, h, fc, Ecs, γ_concrete; kw...),
        primary_off = run_moment_analysis(off, struc, slab, columns, h, fc, Ecs, γ_concrete; kw...),
        secondary_on = run_secondary_moment_analysis(on, struc, slab, columns, h, fc, Ecs, γ_concrete; kw...),
        secondary_off = run_secondary_moment_analysis(off, struc, slab, columns, h, fc, Ecs, γ_concrete; kw...),
    )
end


