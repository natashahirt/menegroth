function _eq137_storey_polys(struc, partway, vi::Int)
    zv = _eq137_vertex_z(struc, vi)
    out = Tuple{Int,Vector{NTuple{2,Float64}}}[]
    for ci in sort!(collect(keys(partway.polys)))
        any(w -> _eq137_z_agree(_eq137_vertex_z(struc, w), zv), _eq137_cell_vis(struc, ci)) ||
            continue
        push!(out, (ci, partway.polys[ci]))
    end
    return out
end

"""
Far support column of column vertex `vi` on one side of its frame line:
the nearest column ahead along `dir` that lies on the frame line.

Candidates are every column point of the neighbourhood index `partway`
(`colxy`, matched by coordinates, whatever the vertex indices) on the
storey of `vi`, at least `_EQ137_FAR_MIN_ALONG_M` ahead and on the frame
line (`_eq137_on_line`, the §13.6.1.4 predicate).  Faces play no part: a
slab meshed into sub-panels has the same far support as the merged panel.
Ties in distance go to the smaller perpendicular offset, then the smaller
vertex index.  Every column vertex whose point coincides with the winner
(`_EQ137_COINCIDE_M`) is grouped with it, and all their columns
(`vertex_column`) are returned, so two coincident columns are compared by
`_eq137_resolved_sides` whatever their vertex order.

Twin support: when the nearest column ahead (at `a₁`) is closer to the
column than `_DDM_OFFSET_TWIN_FRAC` × the distance from it to the next
column ahead on the frame line (at `a₂`: `a₁ < 0.25 (a₂ − a₁)`), the two
are one support group (twin or doubled columns) and the far support is
the column at `a₂`; the twin is returned in `twin` (same fields) so the
caller measures the clear span from the group (`_eq137_resolved_sides`).
With no column beyond it the near column stays the far support.

ENGINEERING JUDGMENT: `_DDM_OFFSET_TWIN_FRAC` is the twin ratio of the
§13.6.1.4 successor search (`_ddm_column_successors`), here taken against
the span the group supports rather than the median column spacing, which
twins themselves pull down on a small plan.  A twin is never the far
support, so a sub-twin-spacing clear span is never used.

Returns `(vertices, columns, along_m, xy, twin)` or `nothing`.
"""
function _eq137_far_group(struc, partway, vertex_column, vi::Int, frame, dir)
    zv = _eq137_vertex_z(struc, vi)
    perp = (-dir[2], dir[1])
    keys_ = Tuple{Float64,Float64,Int}[]
    for (v, xy) in partway.colxy
        v == vi && continue
        _eq137_coincide(xy, frame) && continue
        _eq137_z_agree(_eq137_vertex_z(struc, v), zv) || continue
        a, t = _eq137_local(xy, frame, dir, perp)
        a < _EQ137_FAR_MIN_ALONG_M && continue
        _eq137_on_line(a, t) || continue
        push!(keys_, (a, abs(t), v))
    end
    isempty(keys_) && return nothing
    sort!(keys_)
    function group(key)
        xy = partway.colxy[key[3]]
        verts = sort!([v for (v, p) in partway.colxy if _eq137_coincide(p, xy) &&
                       _eq137_z_agree(_eq137_vertex_z(struc, v), zv)])
        cols = Any[]
        for v in verts, c in get(vertex_column, v, Any[])
            any(d -> d === c, cols) || push!(cols, c)
        end
        return (vertices = verts, columns = cols, along_m = key[1], xy = xy)
    end
    first_ = keys_[1]
    k2 = findfirst(k -> k[1] - first_[1] >= _EQ137_FAR_MIN_ALONG_M &&
                        !_eq137_coincide(partway.colxy[k[3]], partway.colxy[first_[3]]), keys_)
    if k2 !== nothing && first_[1] < _DDM_OFFSET_TWIN_FRAC * (keys_[k2][1] - first_[1])
        return merge(group(keys_[k2]), (twin = group(first_),))
    end
    return merge(group(first_), (twin = nothing,))
end

"""
Far end of one side of column vertex `vi` along `dir`, from the column
layout and the slab coverage of the frame line.

1. The far support is the nearest column on the frame line, past a twin
   of the column (`_eq137_far_group`).
2. Continuity: the slab must cover the frame line from the column point
   and reach the far column (`_eq137_cover_pieces`, any meshing).
   Uncovered stretches in between do not end the span when coverage
   resumes past them: ℓn runs between supports (§13.6.2.5, corpus:
   aci-318-11, page 253).
3. Status:
   - `:column`: covered, or covered except for openings the slab closes
     around (`_eq137_gaps_enclosed`, `opening = true`), and no face near
     the far column neither adjoins it nor is explained by its faces
     (`partway.near`).  The span ends at the far column.  Across an
     opening `alts_m` also holds the coverage end before the first
     opening, so Eq. (13-7) is enveloped over both readings and is never
     below the column-span value.  Another column partway along one of
     the far column's faces (`_eq137_ambiguous` `by_cell`) does not move
     this support; it is the design column's own panels that
     `_eq137_support_class` checks for that.  A face that runs past the
     far column (the column partway along its edge or inside it) does not
     move the support: the column under the slab is a support and ℓn is
     measured to its face (§13.6.2.5).
   - `:ambiguous`: the coverage reaches the far column only across a gap
     shorter than `_EQ137_NEIGHBOURHOOD_M` (between faces or just before the
     column), or across a longer gap that is open on one side (a notch or
     joint: `alts_m` then also admits 0, the slab ending at the gap); or a
     face near the far column neither adjoins it nor is explained by its
     faces.  The nominal span still ends at the far column, and `alts_m`
     lists the other support positions the geometry admits: the coverage
     end and on-line face corners within `_EQ137_NEIGHBOURHOOD_M` of the
     far column that do not coincide with it.
   - `:boundary`: no far column, or the slab does not reach it (a gap of
     at least `_EQ137_NEIGHBOURHOOD_M` at either end of the segment) and
     the slab beside that gap does not meet the far column.  The span
     ends where the coverage ends (`end_m`), with no column at that end;
     `alts_m` adds the loosely bridged coverage end and the on-line
     reach of faces past it.  A frame-line slot whose slab still meets
     the far column's face keeps that column (`_eq137_slab_meets_support`,
     §13.6.2.5): ℓn = 0 is not the top of the envelope.

`end_m` and `alts_m` are along-`dir` distances from the column point;
`far` is the `_eq137_far_group` result, or `nothing` for `:boundary`.

ENGINEERING JUDGMENT: a gap in coverage shorter than the column
neighbourhood (`_EQ137_NEIGHBOURHOOD_M`, 0.35 m) cannot be told apart from
a mesh defect (an unmerged copy of the far column vertex, a sliver
between faces) or a real joint, so it is not taken as either; the caller
envelopes both readings (`_eq137_resolved_sides`, `_eq137_support_class`).
"""
function _eq137_far_support(struc, partway, vertex_column, vi::Int, frame, dir, polys)
    R = _EQ137_NEIGHBOURHOOD_M
    tol = _EQ137_COINCIDE_M
    perp = (-dir[2], dir[1])
    all_polys = [p for (_, p) in polys]
    far = _eq137_far_group(struc, partway, vertex_column, vi, frame, dir)
    alts = Float64[]
    if far === nothing
        D = 0.0
        for poly in all_polys, q in poly
            D = max(D, _eq137_local(q, frame, dir, perp)[1])
        end
        end_m = _eq137_cover_run(frame, dir, D, all_polys, tol)
        loose = _eq137_cover_run(frame, dir, D, all_polys, R)
        loose > end_m + tol && push!(alts, loose)
        # On-line reach of the faces on this side past the coverage end.
        for poly in all_polys
            _eq137_local(_eq137_centroid(poly), frame, dir, perp)[1] > 0.0 || continue
            d = _eq137_frame_depth_m(poly, frame, dir)
            d !== nothing && d > end_m + tol && push!(alts, d)
        end
        return (far = nothing, status = :boundary, end_m = end_m, alts_m = alts,
                opening = false)
    end
    seg = (far.xy[1] - frame[1], far.xy[2] - frame[2])
    len = hypot(seg...)
    u = (seg[1] / len, seg[2] / len)
    scale = far.along_m / len
    pieces = _eq137_cover_pieces(frame, u, len, all_polys)
    strict = _eq137_cover_run(frame, u, len, all_polys, tol)
    opening = false
    short = false
    if strict < len - tol
        # The slab must start at the column.  A gap of at least R at the
        # near end is a slab edge.  A gap of at least R at the far end is a
        # slab edge only when the slab beside it does not meet the far
        # column (§13.6.2.5, corpus: aci-318-11, page 253).
        near_gap = isempty(pieces) || pieces[1][1] > R
        far_gap = !isempty(pieces) && len - pieces[end][2] >= R
        meets = far_gap && !near_gap && _eq137_slab_meets_support(far, all_polys)
        if near_gap || (far_gap && !meets)
            return (far = nothing, status = :boundary, end_m = strict * scale,
                    alts_m = alts, opening = false)
        end
        push!(alts, strict * scale)
        gaps = [pieces[k+1][1] - pieces[k][2] for k in 1:length(pieces)-1]
        # The far-end opening that still meets the column is not a "short"
        # gap: ℓn runs to that column, and ℓn = 0 is not admitted.
        short = any(<=(R), gaps) || pieces[1][1] > tol ||
                (len - pieces[end][2] > tol && !meets)
        if any(>(R), gaps)
            if _eq137_gaps_enclosed(frame, u, len, pieces, all_polys)
                # Coverage resumes past every long gap and the slab closes
                # around each one: openings, not slab edges.  The far support
                # is still the column (§13.6.2.5, corpus: aci-318-11,
                # page 253).
                opening = true
            elseif meets
                # ENGINEERING JUDGMENT: the frame line is open, but the slab
                # beside the slot meets the far column, so that column stays
                # a support.  A clear span of 0 is not the upper end of the
                # Eq. (13-7) envelope.
                short = true
            else
                # Coverage resumes before the far column but a long gap is
                # open on one side (a notch or a joint across the line): the
                # slab may end at the gap, so a clear span down to 0 is
                # admitted, as at a slab edge.
                short = true
                push!(alts, 0.0)
            end
        end
        # The column the slab meets is a support even when the centerline
        # itself does not resume before it.
        meets && (opening = true)
    end
    end_m = far.along_m
    if any(v -> !isempty(get(partway.near, v, Int[])), far.vertices)
        for v in far.vertices, ci in get(partway.near, v, Int[])
            poly = get(partway.polys, ci, nothing)
            poly === nothing && continue
            for q in poly
                hypot(q[1] - far.xy[1], q[2] - far.xy[2]) <= R || continue
                _eq137_coincide(q, far.xy) && continue
                a, t = _eq137_local(q, frame, dir, perp)
                _eq137_on_line(a, t) && push!(alts, a)
            end
        end
        return (far = far, status = :ambiguous, end_m = end_m, alts_m = alts,
                opening = opening)
    end
    status = (isempty(alts) || (opening && !short)) ? :column : :ambiguous
    return (far = far, status = status, end_m = end_m, alts_m = alts, opening = opening)
end

"""
Transverse width of one side of column vertex `vi` from the column layout,
summed over every same-storey face on that side (any meshing).

The side's faces are those with area inside the span (each face clipped
to along `[0, end_m]`), whatever their centroid: a face that runs past the
far support, or a sliver at the column, enters with its part inside the
span.  A face that overlaps another same-storey face
(`_eq137_overlaps_other`) and whose centroid lies within the
perpendicular-neighbour cutoff (`_EQ137_PERP_ALONG_MIN_M`,
`_EQ137_PERP_ALONG_FRAC`) of the column's transverse line is a
perpendicular neighbour and is skipped.  On each perpendicular side of the
frame line:

- the next column line is the nearest column (`partway.colxy`, same storey)
  off the frame line (`_eq137_on_line`) between `_EQ137_FAR_MIN_ALONG_M`
  and the far end (plus the on-line tolerance there), other than the
  column and its far support.  Columns on the column's own transverse line
  are transverse neighbours, not the parallel line (ACI 318-11 §13.6.2.3,
  corpus: aci-318-11, page 253);
- the slab extent is the run from the frame line of the faces clipped to
  the span (along `[0, end_m]`).  Gaps up to `_EQ137_NEIGHBOURHOOD_M` are
  bridged.  A wider gap does not end the strip when a later face still
  lies inside the next column line: that face is the same transverse
  panel (§13.6.2.1, §13.6.2.3).  Past the column line, or with no column
  line, the first wider gap is the slab edge;
- the width is the covered run capped at the panel centerline
  (`min(run, line / 2)`): ACI 318-11 §13.6.2.1 bounds the strip by the panel
  centerline, §13.6.2.3 averages the adjacent transverse spans (half of the
  center-to-center `line`), and §13.6.2.4 substitutes the edge-to-centerline
  distance at an edge (corpus: aci-318-11, page 253).  A slab that stops
  short of the next column line but still covers the centerline keeps its
  full half-span; one that stops before the centerline keeps only its
  covered run (see the width computation for the governing judgment).

ℓ2 is the sum of the two widths.  Each face's tributary width (`tribs_m`,
for the line loads Σ q·ℓ2 of `_eq137_side_lines`) is ℓ2 times its share of
the face area inside the strip (along `[0, end_m]`, out to the width on
each perpendicular side), so the widths sum to ℓ2 whatever the meshing.

A face whose part inside the span has corners off the frame line on both
perpendicular sides crosses it.  If no next column line exists on one of
those sides, and that side still has a column somewhere off the frame
line, the half-to-half width there is unknown: `ArgumentError`
(ambiguous geometry, §13.6.9.2, page 258), never the full face width;
`_eq137_transfer_moment` turns it into NaN with a `:failure` trace event.
A side with no column anywhere off the frame line is the building edge.
A face that crosses only to include an overhang past that edge is not
ambiguous: the overhang is not a span (§13.6.2.4), and its width is 0.

`skip` are the plan points (the column and its far support) that are not
column lines.  Returns `(cells, tribs_m, l2_m, bridged_gap, overhang)`.
`bridged_gap` is true when a face past a gap wider than
`_EQ137_NEIGHBOURHOOD_M` was kept because it is still inside the next
column line.  `overhang` is true when a crossing face was kept as an
edge overhang.

"""
function _eq137_side_width(struc, partway, vi::Int, frame, dir, perp, end_m::Float64,
                           polys, skip)
    R = _EQ137_NEIGHBOURHOOD_M
    zv = _eq137_vertex_z(struc, vi)
    up = Inf
    dn = -Inf
    reach = end_m + _eq137_online_tol(end_m)
    for (v, xy) in partway.colxy
        any(s -> _eq137_coincide(xy, s), skip) && continue
        _eq137_z_agree(_eq137_vertex_z(struc, v), zv) || continue
        a, t = _eq137_local(xy, frame, dir, perp)
        (_EQ137_FAR_MIN_ALONG_M < a <= reach) || continue
        _eq137_on_line(a, t) && continue
        t > 0 ? (up = min(up, t)) : (dn = max(dn, t))
    end
    # A column anywhere off the frame line on side σ, not only inside this
    # span.  None means the side is outside the column grid (an edge).
    function has_column(σ::Int)::Bool
        for (v, xy) in partway.colxy
            _eq137_z_agree(_eq137_vertex_z(struc, v), zv) || continue
            a, t = _eq137_local(xy, frame, dir, perp)
            _eq137_on_line(a, t) && continue
            σ * t > 0 && return true
        end
        return false
    end
    col_up, col_dn = has_column(1), has_column(-1)
    # No next column line, and no column on that side of the frame line at
    # all: the slab past the line is an overhang, not a span (§13.6.2.4).
    overhang_up = !isfinite(up) && !col_up
    overhang_dn = !isfinite(dn) && !col_dn
    group = Tuple{Int,Vector{NTuple{2,Float64}}}[]
    crossed_overhang = false
    for (ci, poly) in polys
        lp = [_eq137_local(q, frame, dir, perp) for q in poly]
        span = _eq137_clip_halfplane(_eq137_clip_halfplane(lp, 1, 1), 1, -1, end_m)
        _eq137_poly_area(span) > 1e-9 || continue
        a, t = _eq137_local(_eq137_centroid(poly), frame, dir, perp)
        if abs(a) < max(_EQ137_PERP_ALONG_MIN_M, _EQ137_PERP_ALONG_FRAC * hypot(a, t)) &&
           _eq137_overlaps_other(ci, poly, polys)
            continue
        end
        off_up = any(q -> q[2] > 0 && !_eq137_on_line(q[1], q[2]), span)
        off_dn = any(q -> q[2] < 0 && !_eq137_on_line(q[1], q[2]), span)
        if off_up && off_dn && (!isfinite(up) || !isfinite(dn))
            # One side is an edge overhang and the other has its column
            # line: the overhang is not a span (§13.6.2.4, page 253).
            # Both sides outside the column grid, or a missing line that
            # still has a column somewhere, stays ambiguous.
            ambiguous = (!isfinite(up) && !overhang_up) || (!isfinite(dn) && !overhang_dn)
            if ambiguous || (overhang_up && overhang_dn)
                throw(ArgumentError(
                    "ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258): " *
                    "cell $ci crosses the frame line at column vertex $vi " *
                    "but has no column vertex on one side to fix the next column line, " *
                    "so its half-to-half tributary width (§13.6.2.3, page 253) is " *
                    "unknown.  This is ambiguous geometry for Eq. (13-7)."
                ))
            end
            crossed_overhang = true
        end
        push!(group, (ci, span))
    end
    width = Dict{Int,Float64}()
    bridged = false
    for σ in (1, -1)
        # ENGINEERING JUDGMENT: zero the overhang only when a face crossed
        # the frame line to include it.  A strip whose columns all lie on
        # the frame line still takes ℓ2 = run / 2 from the slab that is
        # there (§13.6.2.4, corpus: aci-318-11, page 253).  The cantilever
        # past an edge column line is not a span.
        if crossed_overhang && ((σ == 1 && overhang_up) || (σ == -1 && overhang_dn))
            width[σ] = 0.0
            continue
        end
        ivs = Tuple{Float64,Float64}[]
        for (_, span) in group
            piece = _eq137_clip_halfplane(span, 2, σ)
            _eq137_poly_area(piece) > 1e-9 || continue
            push!(ivs, (minimum(σ * q[2] for q in piece), maximum(σ * q[2] for q in piece)))
        end
        sort!(ivs)
        line = σ == 1 ? up : -dn
        run = 0.0
        for (lo, hi) in ivs
            if lo > run + R
                # ENGINEERING JUDGMENT: a gap wider than the neighbourhood is
                # still the same panel when the next face lies inside the
                # next column line (§13.6.2.1, §13.6.2.3, corpus:
                # aci-318-11, page 253).  Dropping it would silently shrink ℓ2.
                if isfinite(line) && lo < line - _EQ137_COINCIDE_M
                    bridged = true
                    run = max(run, hi)
                else
                    break
                end
            else
                run = max(run, hi)
            end
        end
        # ACI 318-11 §13.6.2.1 (corpus: aci-318-11, page 253): the static
        # moment is determined "in a strip bounded laterally by centerline of
        # panel on each side of centerline of supports," and ℓ2 (§13.6.2.3,
        # page 253) is the center-to-center transverse span.  When the slab
        # covers the centerline (run >= line / 2) the half-strip reaches it at
        # line / 2; taking line / 2 preserves the full-coverage result
        # (run >= line gives line / 2 = min(run, line) / 2) and restores the
        # full half-span for a panel that stops short of the next column line
        # but still covers the centerline.  §13.6.2.4 (page 253): with no next
        # column line the overhang branch stays run-based (run / 2).
        #
        # A panel whose slab is PRESENT but terminates BEFORE the panel
        # centerline (0 < run < line / 2) is not bounded by the centerline of
        # panel required by §13.6.2.1, so its ℓ2 is not the §13.6.2.3
        # center-to-center transverse span: the geometry is ambiguous for
        # Eq. (13-7).  Fail closed — throw the same §13.6.9.2 ArgumentError the
        # other ambiguous-geometry branches use rather than returning the
        # reduced, unconservative covered run.  `_eq137_transfer_moment` /
        # `_frameline_end_transfer` catch it and turn it into NaN with an
        # `adjoining_spans_unresolved` :failure trace, so the panel is handed
        # to the upstream fallback instead of sized on a shrunken ℓ2.  A side
        # with NO slab (run ≈ 0) is a different geometry — a free edge or
        # re-entrant corner with no panel, and so no tributary to transfer
        # (§13.6.2.4, page 253) — and keeps width 0, as before; the edge/corner
        # classification and the §13.6.3.6 0.3 M0 floor (page 255) govern it.
        if isfinite(line)
            if _EQ137_COINCIDE_M < run < line / 2 - _EQ137_COINCIDE_M
                throw(ArgumentError(
                    "ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258): " *
                    "on side $σ the slab covers only $(round(run; digits = 3)) m of " *
                    "the transverse span, but the panel centerline (§13.6.2.1, " *
                    "page 253) lies at $(round(line / 2; digits = 3)) m, so the strip " *
                    "stops short of the centerline and its center-to-center ℓ2 " *
                    "(§13.6.2.3, page 253) is unknown.  This is ambiguous geometry " *
                    "for Eq. (13-7)."
                ))
            end
            # run ≈ 0: no slab on this side -> width 0 (edge/re-entrant).
            # run >= line / 2: slab covers the centerline -> half-strip line / 2.
            width[σ] = run <= _EQ137_COINCIDE_M ? 0.0 : line / 2
        else
            width[σ] = run / 2
        end
    end
    # §13.6.2.4 (page 253): along an edge, ℓ2 runs from the edge to the panel
    # centerline. With no slab drawn past the column line on a building-edge
    # side, the edge is the slab edge, out by the strip to the column face.
    if zv !== nothing
        for σ in (1, -1)
            ((σ == 1 && overhang_up) || (σ == -1 && overhang_dn)) || continue
            width[σ] <= _EQ137_COINCIDE_M || continue
            width[σ] = slab_edge_width_at(struc, zv, (frame,), (σ * perp[1], σ * perp[2]))
        end
    end
    l2 = width[1] + width[-1]
    cells = Int[]
    areas = Float64[]
    for (ci, span) in group
        A = 0.0
        for σ in (1, -1)
            width[σ] > 0 || continue
            piece = _eq137_clip_halfplane(_eq137_clip_halfplane(span, 2, σ), 2, -σ,
                                          σ * width[σ])
            A += _eq137_poly_area(piece)
        end
        A > 1e-9 || continue
        push!(cells, ci)
        push!(areas, A)
    end
    total = sum(areas; init = 0.0)
    tribs = total > 0 ? [l2 * A / total for A in areas] : Float64[]
    return (cells = cells, tribs_m = tribs, l2_m = total > 0 ? l2 : 0.0,
            bridged_gap = bridged, overhang = crossed_overhang)
end

function _eq137_centroid(poly)
    n = length(poly)
    sx = 0.0
    sy = 0.0
    for p in poly
        sx += p[1]
        sy += p[2]
    end
    return (sx / n, sy / n)
end

"""
Sides (+1 / −1 along the unit axis `ax`) of the frame line through `frame`
on which cell `ci` carries the slab next to the column, as
`(side, cell_index, poly)` entries (none, one, or both sides).

The cell comes from the geometric adjoining set (a corner at the column
point), or from the column neighbourhood when an ambiguous column's
envelope counts the nearby faces as adjoining (`_eq137_transfer_moment`).
It carries the slab on a side when it covers at least `_EQ137_SIDE_MIN_M`
of the frame line within `_EQ137_NEIGHBOURHOOD_M` of the column point on
that side (`_eq137_cover_pieces`), probed on the axis and on the two rays
`_EQ137_FRAME_BAND_FRAC` off it.  This reads slab coverage, not face
corners or centroids, so a sliver face at the column or a face with the
column partway along its edge continues the frame line exactly like the
merged panel.  It only says which sides of the column the slab continues
on; the span and width of each side come from the column layout
(`_eq137_resolved_sides`).
"""
function _eq137_cell_sides(struc, ci::Int, frame, ax)
    out = NamedTuple[]
    poly = _eq137_cell_poly_m(struc, ci)
    (poly === nothing || length(poly) < 3) && return out
    all(p -> all(isfinite, p), poly) || return out
    f = _EQ137_FRAME_BAND_FRAC
    for side in (1, -1)
        d = (side * ax[1], side * ax[2])
        n = (-d[2], d[1])
        rays = (d, (d[1] + f * n[1], d[2] + f * n[2]), (d[1] - f * n[1], d[2] - f * n[2]))
        covers = any(rays) do r
            u = (r[1] / hypot(r...), r[2] / hypot(r...))
            pieces = _eq137_cover_pieces(frame, u, _EQ137_NEIGHBOURHOOD_M, (poly,))
            sum((b - a for (a, b) in pieces); init = 0.0) >= _EQ137_SIDE_MIN_M
        end
        covers && push!(out, (side = side, cell_index = ci, poly = poly))
    end
    return out
end

"""Throw when the columns at the far support point give different faces."""
function _eq137_reject_far_columns(col_vi::Int, side::Int, fars, ax)
    sizes = join((string(round(2 * ustrip(u"inch", _eq137_face_half(c, ax)); digits=2))
                  for c in fars), ", ")
    throw(ArgumentError(
        "ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258): the far " *
        "support of column vertex $col_vi on side $side has $(length(fars)) columns " *
        "recorded at one point with different faces along the span ([$sizes] in).  " *
        "The clear span (§13.6.2.5, page 253) is ambiguous geometry for Eq. (13-7)."
    ))
end

"""
    _eq137_resolved_sides(struc, slab, col, span_axis; kwargs...)

Panels on each side of `col` along `span_axis`.

Returns `nothing` when the skeleton cannot place the column.  Otherwise a
vector of 0, 1, or 2 sides.  A side exists where an adjoining panel lies
(`_eq137_side_panels`, the continuity test).  Its span comes from the
column layout, not from face corners, so any sub-panel meshing gives the
merged panel's answer:

- the far support is the nearest column on the frame line, and the slab
  must cover the frame line up to it (`_eq137_far_support`);
- `ℓ_cc` runs between the structural centers of the two columns and `ℓn`
  face to face of them (ACI 318-11 §13.6.2.5, corpus: aci-318-11, page 253:
  "Clear span ℓn shall extend from face to face of columns, capitals,
  brackets, or walls");
- `ℓ2` is the sum of the transverse widths to the panel centerlines, from
  the adjacent column lines, over every face on that side
  (`_eq137_side_width`, §13.6.2.1, §13.6.2.3, §13.6.2.4, page 253).

Each side also carries `status` (`_eq137_far_support`) and `ln_range`, the
smallest and largest clear span the geometry admits.  For `:column` both
are `ℓn`.  For `:ambiguous` (`:decision` trace event
`far_support_ambiguous`) they span `ℓn` and the alternative support
positions, with no far face deducted at an alternative.  For `:boundary`
(the slab ends before any column on the frame line: a slab edge, opening,
wall, or cantilever; `:fallback` trace event `far_support_not_column`),
`ℓn` and `ℓ_cc` run to the end of the slab with no far face deducted, as
before, and `ln_range` runs from 0 to that length.  An opening on the frame
line (`_eq137_far_support` `opening`, `:decision` trace event
`far_support_across_opening`) keeps the column span and adds the span to
the opening to `ln_range`.  A twin of the column ahead
(`_eq137_far_group` `twin`, `:decision` trace event `twin_support_group`)
is part of the column's support: the far support is the next column,
`ℓ_cc` runs to it, the nominal `ℓn` runs from the twin's outer face, and
`ln_range` also keeps `ℓn` from the column's own face.

ENGINEERING JUDGMENT (`:boundary`): with no column at the far end the
support there, if any, is unknown (§13.6.2.5 measures to the face of a
wall, which may stand anywhere inside the slab, and a cantilever has no
support).  Eq. (13-7) magnitude is convex in each ℓn², so its largest value
over the admitted range is at an end of it; `_eq137_transfer_moment` takes
the larger of both ends and of §13.6.3.6 0.3 M0 (page 255).  Running ℓn to
the slab end alone is not conservative when that side is the shorter,
dead-load-only span.

`ArgumentError` (§13.6.9.2) is thrown for a face crossing the line with no
column line on one side (`_eq137_side_width`) and for columns at the far
support point (across vertex indices, `_eq137_far_group`) whose faces
differ by more than `_EQ137_FACE_ATOL_IN` (plus `_EQ137_FACE_FLOAT_IN`).
Those are ambiguous geometry, not §13.6.1.3 successive-span violations.
A non-positive clear span to a far column also throws (column faces
consume the span); on a `:boundary` side (the slab ends within the column
face) ℓn is 0.  `_eq137_transfer_moment` and `_frameline_end_transfer`
turn every such `ArgumentError` into NaN with a `:failure` trace event.  A non-finite clear span (NaN or infinite column face or position)
is returned as NaN with a `:failure` trace event (`non_finite_clear_span`),
so Eq. (13-7) is NaN and the connection is rejected.

`partway` is the column neighbourhood index (`_eq137_partway_index`); far
supports, column lines and faces are read from its coordinates, so a
duplicated vertex is still read as its column.  `nothing` builds it for
the columns in `vertex_column`.
"""
function _eq137_resolved_sides(struc, slab, col, span_axis::NTuple{2,Float64};
                               c_override=nothing, extra_columns=(), index=nothing,
                               vertex_column=nothing, partway=nothing, tc=nothing)
    _eq137_geometry_available(struc) || return nothing
    vi = col_vertex_idx(col)
    vi > 0 || return nothing
    axes = _eq137_unit_axes(span_axis)
    axes === nothing && return nothing
    ax, perp = axes

    vcol = vertex_column === nothing ? _eq137_vertex_column_map(struc, extra_columns) : vertex_column
    # The column under analysis may not be in `struc.columns` (a duck that
    # passes it only as `extra_columns` is already in the map; a lone `col`
    # still needs an entry so a shared vertex resolves).
    if !haskey(vcol, vi)
        vcol = copy(vcol)
        vcol[vi] = Any[col]
    end
    pw = _eq137_partway_at(struc, col, vcol, partway)
    idx = index === nothing ? _eq137_vertex_cell_index(struc; partway = pw) : index
    design_verts = _eq137_design_vertices(struc, slab, pw)
    # ℓ2 and membership use the architectural vertex line.  ℓ_cc uses the
    # structural center so an inset shortens only the end span.
    frame = _eq137_vertex_xy_m(struc.skeleton, vi)
    origin = _eq137_structural_xy(struc, col)
    near_half = _eq137_face_half(col, ax; c_override, design_verts)

    raw = _eq137_side_panels(struc, col, span_axis, idx)
    polys = _eq137_storey_polys(struc, pw, vi)

    sides = NamedTuple[]
    for side in (1, -1)
        group = [p for p in raw if p.side == side]
        isempty(group) && continue
        dir = (side * ax[1], side * ax[2])
        fs = _eq137_far_support(struc, pw, vcol, vi, frame, dir, polys)
        far = fs.far
        inset = (origin[1] - frame[1]) * dir[1] + (origin[2] - frame[2]) * dir[2]
        if far === nothing
            # No column at the far end of the slab on this frame line.  No
            # far face is deducted: ℓn runs to the end of the slab.  ℓ_cc is
            # measured from the structural center, as between two columns.
            _eq137_trace_fallback(tc, col, :far_support_not_column;
                                  stage = "_eq137_resolved_sides")
            l_cc = (fs.end_m - inset) * u"m"
            far_half = 0.0u"inch"
        else
            fs.status == :ambiguous &&
                _eq137_trace_fallback(tc, col, :far_support_ambiguous;
                                      stage = "_eq137_resolved_sides", event = :decision)
            # ENGINEERING JUDGMENT: an opening on the frame line does not end
            # the span (§13.6.2.5, corpus: aci-318-11, page 253); Eq. (13-7)
            # is enveloped over the column span and the span to the opening.
            fs.opening &&
                _eq137_trace_fallback(tc, col, :far_support_across_opening;
                                      stage = "_eq137_resolved_sides", event = :decision)
            fars = far.columns
            function reach(fc)
                fxy = _eq137_structural_xy(struc, fc)
                along = (fxy[1] - origin[1]) * dir[1] + (fxy[2] - origin[2]) * dir[2]
                return along * u"m", _eq137_face_half(fc, ax; c_override, design_verts)
            end
            l_cc, far_half = reach(fars[1])
            # Columns at the far support point (one vertex or coincident
            # vertices) must give the same face (§13.6.2.5, corpus:
            # aci-318-11, page 253).  Neither a smaller nor a larger one is
            # conservative for Eq. (13-7) in general: a longer ℓn on the
            # shorter span lowers Mu.  So a disagreement throws, whatever
            # the vertex order.
            for other in fars[2:end]
                lo, ho = reach(other)
                if abs(ustrip(u"inch", (lo - ho) - (l_cc - far_half))) >
                   _EQ137_FACE_ATOL_IN + _EQ137_FACE_FLOAT_IN
                    _eq137_reject_far_columns(vi, side, fars, ax)
                end
            end
        end
        ln = uconvert(u"ft", l_cc - near_half - far_half)
        # Twin support (`_eq137_far_group`): the column and its twin are one
        # support, so ℓn also runs from the twin's outer face.
        ln_twin = nothing
        if far !== nothing && far.twin !== nothing
            _eq137_trace_fallback(tc, col, :twin_support_group;
                                  stage = "_eq137_resolved_sides", event = :decision)
            ln_twin = minimum(far.twin.columns; init = ln) do tcol
                ta, th = reach(tcol)
                uconvert(u"ft", l_cc - far_half - (ta + th))
            end
        end
        if !isfinite(ln)
            # A non-finite column face or position: ℓn (§13.6.2.5) is
            # undefined.  It is carried as NaN so Eq. (13-7) returns NaN and
            # `transfer_section_inadequate` rejects the connection.
            _eq137_trace_fallback(tc, col, :non_finite_clear_span;
                                  stage = "_eq137_resolved_sides", event = :failure)
            ln = NaN * u"ft"
        elseif ln <= 0.0u"ft" && fs.status == :boundary
            # The slab ends on the frame line within the column face (for
            # example a nearby face read as adjoining that the frame line
            # only grazes): no clear span on this side.  ℓn = 0 is the
            # admitted reading; the boundary range runs from it.
            ln = 0.0u"ft"
        elseif ln <= 0.0u"ft"
            throw(ArgumentError(
                "ACI 318-11 §13.6.2.5 and §13.6.9.2 (corpus: aci-318-11, pages 253 " *
                "and 258): clear span at column vertex $vi is non-positive " *
                "(ℓn = $(ln)).  Column faces consume the center-to-center span."
            ))
        end
        cands = [ln]
        if ln_twin !== nothing && isfinite(ln)
            # ENGINEERING JUDGMENT: the nominal ℓn runs from the group's
            # outer face; the range also keeps ℓn from the column's own face.
            ln = isfinite(ln_twin) ? max(0.0u"ft", ln_twin) : NaN * u"ft"
            isfinite(ln) || _eq137_trace_fallback(tc, col, :non_finite_clear_span;
                                                  stage = "_eq137_resolved_sides",
                                                  event = :failure)
            push!(cands, ln)
        end
        for a in fs.alts_m
            push!(cands, uconvert(u"ft", (a - inset) * u"m" - near_half))
        end
        fs.status == :boundary && push!(cands, 0.0u"ft")
        ln_range = isfinite(ln) ? (max(0.0u"ft", minimum(cands)), maximum(cands)) : (ln, ln)
        skip = far === nothing ? (frame,) : (frame, far.xy)
        width = _eq137_side_width(struc, pw, vi, frame, dir, perp, fs.end_m, polys, skip)
        # A later panel inside the next column line was kept across a gap
        # wider than the neighbourhood.  Eq. (13-7) must not silently drop it.
        width.bridged_gap &&
            _eq137_trace_fallback(tc, col, :transverse_panel_past_gap;
                                  stage = "_eq137_resolved_sides", event = :decision)
        # The face crosses the edge line only to include an overhang.  That
        # overhang is not a span (§13.6.2.4, corpus: aci-318-11, page 253).
        width.overhang &&
            _eq137_trace_fallback(tc, col, :edge_overhang_not_a_span;
                                  stage = "_eq137_resolved_sides", event = :decision)
        cells = isempty(width.cells) ? [p.cell_index for p in group] : width.cells
        rep = cells[1]
        if !isnothing(slab) && hasproperty(slab, :cell_indices)
            k = findfirst(ci -> ci in slab.cell_indices, cells)
            k === nothing || (rep = cells[k])
        end
        tribs = isempty(width.cells) ? fill(0.0u"ft", length(cells)) :
                [uconvert(u"ft", t * u"m") for t in width.tribs_m]
        push!(sides, (
            side = side,
            cell_index = rep,
            cell_indices = cells,
            tribs = tribs,
            l_cc = uconvert(u"ft", l_cc),
            ln = ln,
            l2 = sum(tribs),
            ln_range = ln_range,
            status = fs.status,
        ))
    end
    return sides
end

"""
Adjoining panels of `col` (the cells `index` lists at its vertex: for a
column vertex, every cell with a corner at the column point,
`_eq137_vertex_cell_index`) on either side of its frame line along
`span_axis` (`_eq137_cell_sides`), or `nothing` without geometry.

This is the continuity test shared by the transfer moment
(`_eq137_resolved_sides`) and the flexural assignment
(`_ddm_support_moment`).  It does not depend on column size.
"""
function _eq137_side_panels(struc, col, span_axis::NTuple{2,Float64}, index)
    _eq137_geometry_available(struc) || return nothing
    vi = col_vertex_idx(col)
    vi > 0 || return nothing
    axes = _eq137_unit_axes(span_axis)
    axes === nothing && return nothing
    ax = axes[1]
    frame = _eq137_vertex_xy_m(struc.skeleton, vi)
    raw = NamedTuple[]
    for ci in get(index, vi, Int[])
        append!(raw, _eq137_cell_sides(struc, ci, frame, ax))
    end
    return raw
end

"""
True when a side of `col` along `span_axis` that has an adjoining panel
(`_eq137_side_panels`) has a far support that is not a column the slab is
shown to reach (`_eq137_far_support` status `:ambiguous` or `:boundary`).
Independent of column size, so the flexural and transfer classifications
(`_eq137_support_class`) read the same answer.
"""
function _eq137_far_uncertain(struc, col, span_axis::NTuple{2,Float64}, index,
                              vertex_column, partway)::Bool
    _eq137_geometry_available(struc) || return false
    vi = col_vertex_idx(col)
    vi > 0 || return false
    axes = _eq137_unit_axes(span_axis)
    axes === nothing && return false
    ax = axes[1]
    vcol = vertex_column === nothing ? _eq137_vertex_column_map(struc, (col,)) : vertex_column
    pw = _eq137_partway_at(struc, col, vcol, partway)
    panels = _eq137_side_panels(struc, col, span_axis, index)
    panels === nothing && return false
    frame = _eq137_vertex_xy_m(struc.skeleton, vi)
    polys = _eq137_storey_polys(struc, pw, vi)
    for side in unique(p.side for p in panels)
        dir = (side * ax[1], side * ax[2])
        _eq137_far_support(struc, pw, vcol, vi, frame, dir, polys).status == :column ||
            return true
    end
    return false
end

"""Polygon area (absolute shoelace)."""
function _eq137_poly_area(poly)
    n = length(poly)
    n < 3 && return 0.0
    s = 0.0
    for i in 1:n
        a = poly[i]
        b = poly[mod1(i + 1, n)]
        s += a[1] * b[2] - b[1] * a[2]
    end
    return abs(s) / 2
end

"""Sutherland–Hodgman clip of `poly` to the half-plane `sgn * (p[k] - off) >= 0`."""
function _eq137_clip_halfplane(poly, k::Int, sgn::Int, off::Float64 = 0.0)
    out = NTuple{2,Float64}[]
    n = length(poly)
    for i in 1:n
        P = poly[i]
        Q = poly[mod1(i + 1, n)]
        dp = sgn * (P[k] - off)
        dq = sgn * (Q[k] - off)
        dp >= 0 && push!(out, P)
        if (dp >= 0) != (dq >= 0)
            t = dp / (dp - dq)
            push!(out, (P[1] + t * (Q[1] - P[1]), P[2] + t * (Q[2] - P[2])))
        end
    end
    return out
end

"""
How many quadrants around `col` its cells occupy.

Quadrants are taken in the frame of `span_axis` and its perpendicular, so a
plan rotated off the global axes counts the same as an aligned one.  Each
cell is clipped to each quadrant, so a cell that straddles the frame line
occupies every quadrant it covers.  Measured from the architectural vertex,
so a structural inset does not move a cell across the frame line.

ENGINEERING JUDGMENT: a quadrant counts when it holds at least
`_EQ137_QUADRANT_AREA_FRAC` of the cell's area.
"""
function _eq137_quadrant_count(struc, col, index, span_axis::NTuple{2,Float64})::Int
    vi = col_vertex_idx(col)
    vi <= 0 && return 0
    axes = _eq137_unit_axes(span_axis)
    axes === nothing && return 0
    ax, perp = axes
    origin = _eq137_vertex_xy_m(struc.skeleton, vi)
    quads = Set{Tuple{Int,Int}}()
    for ci in get(index, vi, Int[])
        poly = _eq137_cell_poly_m(struc, ci)
        (poly === nothing || length(poly) < 3) && continue
        loc = [((p[1] - origin[1]) * ax[1] + (p[2] - origin[2]) * ax[2],
                (p[1] - origin[1]) * perp[1] + (p[2] - origin[2]) * perp[2]) for p in poly]
        total = _eq137_poly_area(loc)
        total > 0 || continue
        for sa in (1, -1), sp in (1, -1)
            part = _eq137_clip_halfplane(_eq137_clip_halfplane(loc, 1, sa), 2, sp)
            if _eq137_poly_area(part) >= _EQ137_QUADRANT_AREA_FRAC * total
                push!(quads, (sa, sp))
            end
        end
    end
    return length(quads)
end

"""True when segment AB coincides with an edge of one of the polygons `own`."""
function _eq137_edge_in(A, B, own)::Bool
    for q in own
        m = length(q)
        for i in 1:m
            C = q[i]
            D = q[mod1(i + 1, m)]
            ((_eq137_coincide(A, C) && _eq137_coincide(B, D)) ||
             (_eq137_coincide(A, D) && _eq137_coincide(B, C))) && return true
        end
    end
    return false
end

"""True when point X coincides with a corner of one of the polygons `own`."""
_eq137_corner_in(X, own)::Bool = any(q -> any(c -> _eq137_coincide(c, X), q), own)

"""
True when a face `poly` near the column point `P` that does not adjoin it
is explained by the column's adjoining faces `own` (polygons):

- it does not contain `P`;
- each of its corners within `_EQ137_NEIGHBOURHOOD_M` of `P` coincides with
  a corner of an adjoining face (a mesh vertex the column's faces reach,
  for example the far end of a short edge or an opening corner); and
- each of its edges that passes within that radius either coincides with
  an edge of an adjoining face (the two faces are continuous across it,
  geometrically) or comes nearest to `P` at such a corner.

Otherwise the face is a T-junction, an unmerged near-duplicate, an
overlap, or a slab across a gap, and the geometry cannot say whether it
continues the column's slab.
"""
function _eq137_neighbourhood_explained(P, poly, own)::Bool
    _eq137_point_in_poly(P, poly) && return false
    R = _EQ137_NEIGHBOURHOOD_M
    n = length(poly)
    for k in 1:n
        A = poly[k]
        B = poly[mod1(k + 1, n)]
        if hypot(A[1] - P[1], A[2] - P[2]) <= R && !_eq137_corner_in(A, own)
            return false
        end
        Q, d = _eq137_seg_nearest(P, A, B)
        d <= R || continue
        _eq137_edge_in(A, B, own) && continue
        at_corner(X) = _eq137_coincide(Q, X) && _eq137_corner_in(X, own)
        (at_corner(A) || at_corner(B)) || return false
    end
    return true
end

"""
Column neighbourhood index for the column vertices in `verts`, from
coordinates only (never from shared vertex indices), so a mesh whose faces
carry their own copies of a vertex reads like the merged mesh.  Only
same-storey faces count: a face is off the storey when every corner has a
known z more than `_EQ137_STOREY_DZ_M` from the column's.

Fields (a NamedTuple):
- `adjoin[v]`: faces with a corner that coincides with the column point
  (`_eq137_coincide`, same storey at that corner).  The §13.6.3.3 class
  (corpus: aci-318-11, page 254) and Eq. (13-7) (§13.6.9.2, page 258) read
  the panels at the column from this set (`_eq137_vertex_cell_index`).
- `merged`: column vertices with an adjoining face that does not list the
  column's vertex index (a duplicated or nudged vertex), traced
  `duplicate_vertex_merged`.
- `near[v]`: faces within `_EQ137_NEIGHBOURHOOD_M` of the column point
  (plan distance, 0 inside the face) that do not adjoin it and are not
  explained by its adjoining faces (`_eq137_neighbourhood_explained`).
  `by_cell[ci]` lists the column vertices for which face `ci` is such a
  face.  Both make a column ambiguous (`_eq137_ambiguous`).
- `nonfinite`: column vertices whose own XY or z is not finite, or whose
  storey holds a non-finite slab-face corner or column point.
- `colxy`, `colgrid`: finite column points and their spatial hash
  (`_eq137_columns_at`).
- `polys[ci]`: plan polygon (meters) of every slab face whose corners are
  all finite (XY and z), read by the far-support and transverse-width
  search (`_eq137_far_support`, `_eq137_side_width`).

ENGINEERING JUDGMENT (non-finite): a NaN coordinate can stand for any
point, so it cannot be shown to lie outside a column's neighbourhood, to
not be its far support, or to not be a panel at it.  A NaN z can stand for
any storey.  Every column on that storey (every storey when the bad vertex
has no finite z, which includes a NaN z) is flagged, and
`_eq137_transfer_moment` / `_ddm_support_class` reject it before reading
any geometry.  The geometric tests below then read finite faces only.

Every vertex in `verts` with `v > 0` has an `adjoin` and a `near` entry,
so a missing key means the vertex was not indexed.  Built once per
analysis (`_eq137_context`); each cell is tested only against the column
points in the spatial buckets its radius-expanded bounding box touches.
"""
function _eq137_partway_index(struc, verts)
    adjoin = Dict{Int,Vector{Int}}()
    near = Dict{Int,Vector{Int}}()
    by_cell = Dict{Int,Vector{Int}}()
    merged = Set{Int}()
    nonfinite = Set{Int}()
    colxy = Dict{Int,NTuple{2,Float64}}()
    colgrid = Dict{NTuple{2,Int},Vector{Int}}()
    polys = Dict{Int,Vector{NTuple{2,Float64}}}()
    out = (adjoin = adjoin, near = near, by_cell = by_cell, merged = merged,
           nonfinite = nonfinite, colxy = colxy, colgrid = colgrid, polys = polys)
    _eq137_geometry_available(struc) || return out
    skel = struc.skeleton
    R = _EQ137_NEIGHBOURHOOD_M
    bad_z = Float64[]
    bad_any_storey = Ref(false)
    function taint!(ws)
        for w in ws
            z = _eq137_vertex_z(struc, w)
            if z === nothing || !isfinite(z)
                bad_any_storey[] = true
            else
                push!(bad_z, z)
            end
        end
    end
    finite_z(w) = (z = _eq137_vertex_z(struc, w); z === nothing || isfinite(z))
    cells = _eq137_slab_cells(struc, nothing)
    for ci in cells
        vis = _eq137_cell_vis(struc, ci)
        isempty(vis) && continue
        poly = [_eq137_vertex_xy_m(skel, w) for w in vis]
        if all(p -> all(isfinite, p), poly) && all(finite_z, vis)
            polys[ci] = poly
        else
            taint!(vis)
        end
    end
    for v in verts
        v > 0 || continue
        adjoin[v] = Int[]
        near[v] = Int[]
        p = _eq137_vertex_xy_m(skel, v)
        if all(isfinite, p) && finite_z(v)
            colxy[v] = p
            push!(get!(colgrid, (_eq137_bucket(p[1]), _eq137_bucket(p[2])), Int[]), v)
        else
            taint!((v,))
            append!(adjoin[v], [ci for ci in cells if v in _eq137_cell_vis(struc, ci)])
        end
    end
    for v in keys(adjoin)
        zv = _eq137_vertex_z(struc, v)
        if !haskey(colxy, v) || bad_any_storey[] || any(z -> _eq137_z_agree(z, zv), bad_z)
            push!(nonfinite, v)
        end
    end
    cand = Dict{Int,Vector{Int}}()
    for ci in cells
        poly = get(polys, ci, nothing)
        poly === nothing && continue
        vis = _eq137_cell_vis(struc, ci)
        zs = [_eq137_vertex_z(struc, w) for w in vis]
        bx0 = _eq137_bucket(minimum(p[1] for p in poly) - R)
        bx1 = _eq137_bucket(maximum(p[1] for p in poly) + R)
        by0 = _eq137_bucket(minimum(p[2] for p in poly) - R)
        by1 = _eq137_bucket(maximum(p[2] for p in poly) + R)
        for bx in bx0:bx1, by in by0:by1, v in get(colgrid, (bx, by), Int[])
            zv = _eq137_vertex_z(struc, v)
            any(z -> _eq137_z_agree(z, zv), zs) || continue
            P = colxy[v]
            if any(k -> _eq137_coincide(poly[k], P) && _eq137_z_agree(zs[k], zv), eachindex(poly))
                push!(adjoin[v], ci)
                v in vis || push!(merged, v)
            elseif _eq137_poly_dist(P, poly) <= R
                push!(get!(cand, v, Int[]), ci)
            end
        end
    end
    for (v, cs) in cand
        own = [polys[ci] for ci in adjoin[v]]
        for ci in cs
            _eq137_neighbourhood_explained(colxy[v], polys[ci], own) && continue
            push!(near[v], ci)
            push!(get!(by_cell, ci, Int[]), v)
        end
    end
    return out
end

"""
Column vertices of the neighbourhood index `partway` whose point coincides
with skeleton vertex `w` (`_eq137_coincide`) on the same storey, including
`w` itself when it is an indexed column vertex.  Empty for a non-finite
`w`: a non-finite vertex flags its storey (`partway.nonfinite`), which the
callers reject first.
"""
function _eq137_columns_at(struc, partway, w::Int)
    out = Int[]
    p = _eq137_vertex_xy_m(struc.skeleton, w)
    all(isfinite, p) || return out
    zw = _eq137_vertex_z(struc, w)
    bx, by = _eq137_bucket(p[1]), _eq137_bucket(p[2])
    for i in -1:1, j in -1:1, u in get(partway.colgrid, (bx + i, by + j), Int[])
        _eq137_coincide(partway.colxy[u], p) || continue
        _eq137_z_agree(_eq137_vertex_z(struc, u), zw) || continue
        push!(out, u)
    end
    return out
end

"""
`partway` (a `_eq137_partway_index`) when it indexes `col`'s vertex;
otherwise the index built here for the column vertices of `vertex_column`
(`nothing`: every column of `struc`) plus `col`.
"""
function _eq137_partway_at(struc, col, vertex_column, partway)
    vi = col_vertex_idx(col)
    (partway !== nothing && haskey(partway.adjoin, vi)) && return partway
    vcol = vertex_column === nothing ? _eq137_vertex_column_map(struc, (col,)) : vertex_column
    verts = Set{Int}(keys(vcol))
    push!(verts, vi)
    return _eq137_partway_index(struc, verts)
end

"""
True when the neighbourhood of column vertex `vi` is ambiguous
(`_eq137_partway_index`): a nearby face that does not adjoin it is not
explained by its adjoining faces (`near`), or one of its adjoining faces is
such a face for another column (`by_cell`, for example a column partway
along that face's edge, so the face is not a proper panel there).
"""
function _eq137_ambiguous(partway, vi::Int)::Bool
    isempty(get(partway.near, vi, Int[])) || return true
    return any(ci -> any(!=(vi), get(partway.by_cell, ci, Int[])),
               get(partway.adjoin, vi, Int[]))
end

"""
True when the slab around `col` is read without ambiguity: every
same-storey face in the column neighbourhood adjoins it or is explained by
the faces that do (`_eq137_ambiguous`).  `index` is accepted for call-site
compatibility; the adjoining set is the neighbourhood index's.  `partway`
is the precomputed `_eq137_partway_index`; it is looked up, not rebuilt
(`_eq137_partway_at`).
"""
function _eq137_mesh_conforms(struc, col, index, vertex_column; partway = nothing)::Bool
    vi = col_vertex_idx(col)
    vi > 0 || return false
    return !_eq137_ambiguous(_eq137_partway_at(struc, col, vertex_column, partway), vi)
end

"""
True when the neighbourhood index flags `col` (`partway.nonfinite`): its
own XY, or a slab-face corner or column point on its storey, is not
finite.  Checked before any geometry is read.
"""
_eq137_nonfinite_at(partway, col)::Bool = col_vertex_idx(col) in partway.nonfinite

"""Position fallback used only when geometry cannot see the column."""
function _eq137_position_exterior(col, span_axis)::Bool
    return is_exterior_support(col, span_axis)
end

"""
Service drop pressure spread over `panel_area`.

The projection is dead load.  It is added to service `qD` so the §9.2.1
factor (1.2 or 1.4) is applied with the rest of D, not as a flat 1.2 on
`qu` only.  ACI 318-11 §9.2.1 (corpus: aci-318-11, page 123).
"""
function _eq137_drop_service(drop_panel, panel_area, γ)
    (isnothing(drop_panel) || isnothing(γ)) && return 0.0psf
    w_drop = uconvert(psf, drop_panel.h_drop * γ * GRAVITY)
    A_drop = uconvert(u"ft^2", drop_extent_1(drop_panel) * drop_extent_2(drop_panel))
    A_panel = uconvert(u"ft^2", panel_area)
    A_panel <= 0.0u"ft^2" && return 0.0psf
    return uconvert(psf, w_drop * (A_drop / A_panel))
end

"""Add drop dead load to service `qD`, then refactor `qu` and `M0`."""
function _eq137_with_drop(qD, qL, l2, ln, drop_panel, panel_area, γ)
    qD2 = uconvert(psf, qD + _eq137_drop_service(drop_panel, panel_area, γ))
    # ACI 318-11 §9.2.1 Eq. (9-1) and Eq. (9-2) (corpus: aci-318-11, page 123).
    qu2 = max(factored_pressure(default_combo, qD2, qL),
              factored_pressure(strength_1_4D, qD2, qL))
    return qD2, qu2, total_static_moment(qu2, l2, ln)
end

"""Owning-slab result thickness as a service pressure, or `nothing`."""
function _eq137_sw_from_result(struc, cell_index::Int, γ; cell_slab=nothing)
    isnothing(γ) && return nothing
    sl = _eq137_owning_slab(cell_slab, struc, cell_index)
    sl === nothing && return nothing
    res = hasproperty(sl, :result) ? sl.result : nothing
    (res === nothing || !hasproperty(res, :thickness)) && return nothing
    h = res.thickness
    h isa Length || return nothing
    return uconvert(psf, slab_self_weight(h, γ))
end

"""
Self-weight of a neighbour cell.

`cell.self_weight` is written only after sizing converges, so during moment
analysis it can be zero or left from a previous thickness.  Prefer the
owning slab's result thickness when that exists.  If the stored value and
the thickness disagree, warn and use the thickness.  If neither exists,
warn and use the design panel's trial self-weight.  Both fallbacks also
emit a `:fallback` trace event on `tc` (`stale_self_weight`,
`missing_neighbour_sw`), keyed by the neighbour cell.
"""
function _eq137_neighbour_sw(struc, cell_index::Int, sw_trial::Pressure, γ;
                            cell_slab=nothing, design_drop::Pressure=0.0psf,
                            tc=nothing)
    stage = "_eq137_neighbour_sw"
    cell = struc.cells[cell_index]
    sw_stored = if hasproperty(cell, :self_weight) && !iszero(cell.self_weight)
        uconvert(psf, cell.self_weight)
    else
        nothing
    end
    sw_h = _eq137_sw_from_result(struc, cell_index, γ; cell_slab=cell_slab)
    if sw_h !== nothing && sw_stored !== nothing &&
       !isapprox(ustrip(psf, sw_h), ustrip(psf, sw_stored); atol=1.0)
        # ENGINEERING JUDGMENT: 1 psf is the float tolerance for "these two
        # pressures are the same self-weight".
        _eq137_warn_once(:stale_self_weight,
            "Neighbour cell.self_weight disagrees with the owning slab result thickness; using the thickness. cell.self_weight is written only after sizing converges and can be stale during moment analysis.")
        emit!(tc, :slab, stage, "cell_$(cell_index)", :fallback;
              reason = "stale_self_weight")
        return sw_h
    end
    sw_h !== nothing && return sw_h
    sw_stored !== nothing && return sw_stored
    _eq137_warn_once(:missing_neighbour_sw,
        "Neighbour cell has no self-weight and its slab has no result thickness; using the design panel trial self-weight without the design slab's drop. cell.self_weight is assigned only after sizing converges.")
    emit!(tc, :slab, stage, "cell_$(cell_index)", :fallback;
          reason = "missing_neighbour_sw")
    # `sw_trial` is qD − sdl, and qD already includes the design slab's drop.
    # Subtract that drop so the neighbour is not charged for it twice (once
    # here and again by `_eq137_neighbour_drop` when the neighbour has its own).
    return uconvert(psf, sw_trial) - uconvert(psf, design_drop)
end

"""Drop dead load of a neighbour slab, 0 when this cell is the design slab."""
function _eq137_neighbour_drop(struc, cell_index::Int, design_slab, γ; cell_slab=nothing)
    isnothing(γ) && return 0.0psf
    sl = _eq137_owning_slab(cell_slab, struc, cell_index)
    sl === nothing && return 0.0psf
    sl === design_slab && return 0.0psf
    dp = hasproperty(sl, :drop_panel) ? sl.drop_panel : nothing
    isnothing(dp) && return 0.0psf
    hasproperty(sl, :spans) || return 0.0psf
    area = sl.spans.primary * sl.spans.secondary
    return _eq137_drop_service(dp, area, γ)
end

"""
Service line loads `Σ q·ℓ2` on one side of the column.

ENGINEERING JUDGMENT: panels on the same side of a frame line may each be
uniform (§13.6.1.5, page 252, is per panel) and still differ from each
other.  Eq. (13-7)'s `q ℓ2` terms are line loads, so the side is the
tributary-width-weighted sum, not a throw.
"""
function _eq137_side_lines(struc, slab, side, sw_trial::Pressure, γ;
                          cell_slab=nothing, design_drop::Pressure=0.0psf,
                          tc=nothing)
    wD = 0.0psf * 0.0u"ft"
    wL = 0.0psf * 0.0u"ft"
    for (ci, trib) in zip(side.cell_indices, side.tribs)
        cell = struc.cells[ci]
        sdl = uconvert(psf, cell.sdl)
        qL = uconvert(psf, cell.live_load)
        in_design = !isnothing(slab) && hasproperty(slab, :cell_indices) &&
                    ci in slab.cell_indices
        if in_design
            # Design qD already includes this slab's drop and trial self-weight.
            # Do not add the drop again.
            sw = sw_trial
            q_drop = 0.0psf
        else
            sw = _eq137_neighbour_sw(struc, ci, sw_trial, γ;
                                     cell_slab=cell_slab, design_drop=design_drop,
                                     tc=tc)
            q_drop = _eq137_neighbour_drop(struc, ci, slab, γ; cell_slab=cell_slab)
        end
        wD += uconvert(psf, sdl + sw + q_drop) * trib
        wL += qL * trib
    end
    return wD, wL
end

"""
Trial self-weight implied by the design panel `qD`.

`qD` is the largest cell SDL plus self-weight (`_flat_plate_uniform_pressures`),
so the same largest SDL is removed here.
"""
function _eq137_sw_trial(struc, slab, qD::Pressure)::Pressure
    if isnothing(struc) || isnothing(slab) || !hasproperty(slab, :cell_indices) ||
       isempty(slab.cell_indices) || !hasproperty(struc, :cells)
        return zero(uconvert(psf, qD))
    end
    all(i -> hasproperty(struc.cells[i], :sdl), slab.cell_indices) ||
        return zero(uconvert(psf, qD))
    sdl_max = maximum(uconvert(psf, struc.cells[i].sdl) for i in slab.cell_indices)
    return uconvert(psf, qD) - sdl_max
end

"""ACI 318-11 §13.6.3.6 transfer, 0.3 M0 (corpus: aci-318-11, page 255)."""
function _eq137_edge_moment(M0)
    isnothing(M0) && return 0.0kip * u"ft"
    return 0.3 * M0
end

"""
`:fallback` and `:decision` are registered event types (`size_flat_plate!`).
Reused here so an Eq. (13-7) or §13.6.3.3 classification choice is a trace
event, not only a warning.  `emit!(::Nothing, ...)` is a no-op when the
caller is not tracing.
"""
function _eq137_trace_fallback(tc, col, reason::Symbol;
                               stage::String = "_eq137_transfer_moment",
                               event::Symbol = :fallback)
    vi = col_vertex_idx(col)
    emit!(tc, :slab, stage, "col_v$(vi)", event; reason = String(reason))
end

"""
True when any service load (or length) in `xs` is negative.

ACI 318-11 §13.6.1.5 (corpus: aci-318-11, page 252): DDM loads are due to
gravity only and uniformly distributed.  A negative service dead or live
load is invalid input, rejected like a non-finite one.  Zero is valid.
"""
_eq137_negative_input(xs...)::Bool = any(x -> x < zero(x), xs)

"""
`:failure` trace event (`negative_service_load`) at `col` and a NaN transfer
moment, which `transfer_section_inadequate` rejects.
"""
function _eq137_negative_load_failure(tc, col, stage::String)
    _eq137_trace_fallback(tc, col, :negative_service_load; stage = stage, event = :failure)
    return NaN * kip * u"ft"
end

TRACE_REGISTRY[(:_eq137_transfer_moment, :slab)] = TracedFunctionMeta(
    :_eq137_transfer_moment, :slab, [:fallback, :decision, :failure], nothing,
    @__FILE__, @__LINE__,
)

TRACE_REGISTRY[(:_ddm_support_moment, :slab)] = TracedFunctionMeta(
    :_ddm_support_moment, :slab, [:fallback, :decision, :failure], nothing,
    @__FILE__, @__LINE__,
)

TRACE_REGISTRY[(:_eq137_resolved_sides, :slab)] = TracedFunctionMeta(
    :_eq137_resolved_sides, :slab, [:fallback, :decision, :failure], nothing,
    @__FILE__, @__LINE__,
)

TRACE_REGISTRY[(:_eq137_neighbour_sw, :slab)] = TracedFunctionMeta(
    :_eq137_neighbour_sw, :slab, [:fallback], nothing, @__FILE__, @__LINE__,
)

"""
True for an exterior, edge, or corner column, including a column tagged
`:interior` whose cells occupy one or two quadrants.

A corner or an edge must not receive the equal-span pattern.  Four
quadrants (or no geometry at all) are not edge-like.
"""
function _eq137_edge_like(struc, col, span_axis, idx)::Bool
    _eq137_position_exterior(col, span_axis) && return true
    pos = hasproperty(col, :position) ? col.position : :interior
    pos in (:edge, :corner, :exterior) && return true
    nquad = idx === nothing ? 0 : _eq137_quadrant_count(struc, col, idx, span_axis)
    return 0 < nquad <= 2
end

"""
How far panel geometry is trusted at `col`.

`geom_exterior` is the geometry's answer (slab on one side, or on neither).
Two-sided geometry with an interior tag (`_eq137_position_exterior`) is
`:agree` without a check.  Otherwise the neighbourhood is checked
(`_eq137_mesh_conforms`) whatever the tag says: a T-junction hides a panel,
and a tag derived from the same faces (for example single-face edges at a
T-junction or along a duplicated column line) agrees with the wrong
one-sided answer.  Conforming: `:agree` when the tag matches, `:geometry`
when it does not.  Non-conforming: `:envelope`.

USER DECISION / ENGINEERING JUDGMENT: in an ambiguous neighbourhood the
panel geometry cannot be shown to be continuous or discontinuous, so the
caller takes the larger of the interior and exterior moments.  Otherwise
the geometry is the better witness than a global tag.
"""
function _eq137_tag_trust(struc, col, span_axis, idx, vertex_column, geom_exterior::Bool;
                          partway = nothing)
    tag_exterior = _eq137_position_exterior(col, span_axis)
    !geom_exterior && !tag_exterior && return :agree
    vcol = vertex_column === nothing ? _eq137_vertex_column_map(struc, (col,)) : vertex_column
    _eq137_mesh_conforms(struc, col, idx, vcol; partway = partway) || return :envelope
    return geom_exterior == tag_exterior ? :agree : :geometry
end

"""
Trace reason for a non-conforming envelope, keyed by the geometry and the
tag, so a reader can tell which disagreement (if any) triggered it.
"""
function _eq137_nonconforming_reason(col, span_axis, nsides::Int)::Symbol
    tag_exterior = _eq137_position_exterior(col, span_axis)
    nsides == 2 && return :exterior_tag_nonconforming
    nsides == 1 && return tag_exterior ? :one_sided_nonconforming :
                                         :one_sided_interior_nonconforming
    return :exterior_no_panel_nonconforming
end

"""
Continuity class of `col` along `span_axis` from panel geometry:
`:interior`, `:exterior`, or `:envelope` (the larger of the two answers).

`nsides` is the number of sides of the frame line with a panel
(`_eq137_side_panels`).  The flexural (`_ddm_support_moment`) and transfer
(`_eq137_transfer_moment`) moments both use this one rule, so they agree on
which columns are continuous in this direction.

- Ambiguous neighbourhood (`_eq137_partway_index` `near`: a same-storey
  face within `_EQ137_NEIGHBOURHOOD_M` that neither adjoins the column nor
  is explained by the faces that do): `:envelope`, `:decision`
  (`ambiguous_neighbourhood_envelope`), whatever the sides and the tag.
- Two sides, three quadrants (re-entrant corner): `:envelope`, `:decision`.
- Two sides, a far support that is not a column the slab is shown to reach
  (`_eq137_far_uncertain`): `:envelope`, `:decision`
  (`uncertain_far_support_envelope`).
- Two sides: `:interior`.  An exterior tag is checked (`_eq137_tag_trust`).
- One side: `:exterior` on a conforming mesh, whatever the tag.
- No side, edge-like column (`_eq137_edge_like`): `:exterior` on a
  conforming mesh (`exterior_no_panel`).
- No side, no edge evidence: `:envelope` (`zero_sides`).
- An adjoining face that is ambiguous for another column (for example a
  column partway along its edge) in any of the checked cases: `:envelope`.

Adjoining faces are found by coordinates (`_EQ137_COINCIDE_M`), so faces
on a duplicated or nudged copy of the column vertex count as adjoining;
that emits a `duplicate_vertex_merged` `:decision`.  No structural joint
is inferred from vertex indices: a nearby face that shares no vertex with
the column's faces is ambiguous, not a separate slab.

Every choice that is not plain agreement emits a trace event at `stage`.
"""
