# =============================================================================
# DDM Applicability Check - ACI 318-11 §13.6.1
# =============================================================================

"""
    DDMApplicabilityError <: Exception

Error thrown when DDM is not applicable for the given geometry/loading.

# Fields
- `violations`: List of ACI 318-11 §13.6.1 conditions that are violated
- `alternatives`: List of alternative methods that ARE valid for this geometry
"""
struct DDMApplicabilityError <: Exception
    violations::Vector{String}
    alternatives::Vector{String}
end

"""Construct a `DDMApplicabilityError` with an empty alternatives list."""
DDMApplicabilityError(violations::Vector{String}) = DDMApplicabilityError(violations, String[])

"""Print a human-readable error listing the violated conditions and suggested alternatives."""
function Base.showerror(io::IO, e::DDMApplicabilityError)
    # A throw that is only Eq. (13-7) geometry is not a §13.6.1
    # applicability failure.  Mixed violations keep the §13.6.1 header.
    # A non-positive clear span is its own failure, not ambiguous geometry.
    geom_only = !isempty(e.violations) && all(v ->
        occursin("13.6.9.2", v) && !occursin("13.6.1", v), e.violations)
    is_clear_span(v) = occursin("non-positive", v)
    if geom_only && all(is_clear_span, e.violations)
        println(io, "DDM cannot evaluate Eq. (13-7): column faces consume the clear span (ACI 318-11 §13.6.2.5 and §13.6.9.2, corpus: aci-318-11, pages 253 and 258):")
    elseif geom_only && any(is_clear_span, e.violations)
        println(io, "DDM cannot evaluate Eq. (13-7): frame-line geometry is ambiguous and column faces consume a clear span (ACI 318-11 §13.6.2.5 and §13.6.9.2, corpus: aci-318-11, pages 253 and 258):")
    elseif geom_only
        println(io, "DDM cannot evaluate Eq. (13-7): frame-line geometry is ambiguous (ACI 318-11 §13.6.9.2, corpus: aci-318-11, page 258):")
    else
        println(io, "DDM (Direct Design Method) is not permitted for this slab per ACI 318-11 §13.6.1:")
    end
    for (i, v) in enumerate(e.violations)
        println(io, "  $i. $v")
    end
    
    if !isempty(e.alternatives)
        println(io, "\nConsider using one of the following methods instead:")
        for alt in e.alternatives
            println(io, "  • $alt")
        end
    else
        # FEA is always valid as the most general method
        println(io, "\nConsider using FEA (Finite Element Analysis) instead, which has no geometric restrictions.")
    end
end

"""
ACI 318-11 §13.6.1.3 (corpus: aci-318-11, page 252) violations.

Successive span lengths center-to-center of supports in each direction
shall not differ by more than one-third the longer span.  Pairs come
from the same per-column panel lookup as Eq. (13-7); only sides that end
at a far column are spans, so a slab overhang or cantilever beyond an edge
column (`:boundary` side) is not compared.  Returns an empty
vector when geometry is unavailable (nothing to compare).  Ambiguous
frame-line geometry keeps its §13.6.9.2 message; it is not relabeled as
a §13.6.1.3 violation.
"""
function _successive_span_violations(struc, slab, columns)::Vector{String}
    out = String[]
    _eq137_geometry_available(struc) || return out
    (isnothing(slab) || !hasproperty(slab, :spans)) && return out
    span_axis = _get_span_axis(slab)
    perp_axis = (-span_axis[2], span_axis[1])
    seen = Set{Tuple{Int,Int}}()
    ctx = _eq137_context(struc, columns)
    index = ctx.index
    for col in columns
        col_vertex_idx(col) > 0 || continue
        for ax in (span_axis, perp_axis)
            sides = try
                _eq137_resolved_sides(struc, slab, col, ax;
                                      extra_columns=columns, index=index,
                                      vertex_column=ctx.vertex_column,
                                      partway=ctx.partway)
            catch e
                if e isa ArgumentError
                    # Honest Eq. (13-7) message.  Do not prefix §13.6.1.3.
                    push!(out, sprint(showerror, e))
                    continue
                end
                rethrow()
            end
            sides === nothing && continue
            # Spans are center-to-center of supports: a side with no far
            # column (`:boundary` — slab edge overhang or cantilever) is not a span.
            spans = [s for s in sides if s.status !== :boundary]
            length(spans) < 2 && continue
            la, lb = spans[1].l_cc, spans[2].l_cc
            # ACI 318-11 §13.6.1.3 (corpus: aci-318-11, page 252):
            # successive center-to-center spans shall not differ by more
            # than one-third the longer span.
            longer = max(la, lb)
            diff = abs(la - lb)
            diff > longer / 3 || continue
            key = (
                round(Int, ustrip(u"ft", min(la, lb)) * 100),
                round(Int, ustrip(u"ft", max(la, lb)) * 100),
            )
            key in seen && continue
            push!(seen, key)
            push!(out,
                "§13.6.1.3: Successive span lengths center-to-center differ by " *
                "$(round(ustrip(u"ft", diff), digits=2)) ft > one-third of the longer span " *
                "($(round(ustrip(u"ft", longer / 3), digits=2)) ft) " *
                "[$(round(ustrip(u"ft", la), digits=2)) ft vs $(round(ustrip(u"ft", lb), digits=2)) ft] " *
                "(corpus: aci-318-11, page 252)")
        end
    end
    return out
end

# ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252): offset limit as a
# fraction of the span.  Commentary R13.6.1.4 (page 252) adds a cumulative
# 20% limit; that is not checked here.
const _DDM_OFFSET_LIMIT_FRAC = 0.10

# ENGINEERING JUDGMENT: column-line membership for §13.6.1.4 (page 252).
# A column ahead of column `i` along an axis is measured against the
# transverse column-line spacing `s` on its side of `i` (the perpendicular
# distance to the nearest column across from `i`, `_ddm_line_spacing_m`).
# At |perp| < 0.25·s it is on `i`'s column line; at 0.25·s to 0.75·s it lies
# between two lines without clearly belonging to either, and it is still
# treated as on `i`'s line (fail closed: its offset is checked, so DDM is
# not applicable when that offset exceeds 10% of the span); beyond 0.75·s it
# is on the adjacent column line and is checked against that line instead.
# A column offset from its own line is therefore seen whatever the size of
# the offset.  When `i` has no column across from it on that side (the outer
# line of the plan) the spacing on its other side is used; with none on
# either side (a single line) `s` is the span from `i` to the nearest column
# ahead, i.e. a square panel: a column more than 75% of that span off the
# line is then a lone column of another line (a missing column or an L-plan
# end, a §13.6.1.3 span matter), not an offset.
const _DDM_LINE_MEMBER_FRAC = 0.25
const _DDM_LINE_OTHER_FRAC = 0.75

# ENGINEERING JUDGMENT: columns closer in plan than 0.25 × the typical
# column spacing (median nearest-neighbour distance) form one support group
# (twin or doubled columns, e.g. at an expansion joint) and are never each
# other's successive column.  §13.6.1.2 and §13.6.1.3 (page 252) keep every
# DDM span above about one third of the typical spacing, so a genuine span
# is not grouped.
const _DDM_OFFSET_TWIN_FRAC = 0.25

"""
Span (meters) against which a §13.6.1.4 offset is measured, for two
successive columns whose structural centerlines differ by `s` (meters),
along the unit axis `ax`.

ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252): "a maximum of 10
percent of the span (in direction of offset)".  Read here as the
center-to-center distance between the successive columns measured along
the frame line (`ax`), as before.  The alternative reading (the span in the
direction of the offset, i.e. perpendicular to the frame line) is an open
question with the user; switch it here only.
"""
_ddm_offset_span_m(s::NTuple{2,Float64}, ax::NTuple{2,Float64}) =
    abs(s[1] * ax[1] + s[2] * ax[2])

"""
    _ddm_column_successors(struc, columns, span_axis)

Successive column of every column along `span_axis` and along its
perpendicular, from structural centerlines (meters), for the §13.6.1.4
offset check (`_column_offset_violations`) and the §13.6.1.2 panel spans
(`_panel_aspect_violations`).  ENGINEERING JUDGMENT, see the constants
above:

- Support groups: columns closer in plan than `_DDM_OFFSET_TWIN_FRAC` ×
  the median nearest-neighbour spacing (neighbours under
  `_EQ137_FAR_MIN_ALONG_M` are the same support and are not counted) are
  one support group (twins).  A twin is never the successive column; each
  twin is still checked against its own successive column, so grouping
  cannot hide an offset.
- Candidates are at least `_EQ137_FAR_MIN_ALONG_M` ahead along the axis.
  A candidate whose perpendicular offset exceeds `_DDM_LINE_OTHER_FRAC` ×
  the transverse column-line spacing on its side (`_ddm_line_spacing_m`;
  else the spacing on the other side; else the span to the nearest column
  ahead) is on the adjacent column line; every other candidate is on this line,
  including one between lines (`_DDM_LINE_MEMBER_FRAC` to
  `_DDM_LINE_OTHER_FRAC` of the spacing, fail closed).
- The successive column is the nearest (plan distance) candidate on this
  line.

Returns `nothing` for a degenerate axis.  Otherwise `(sxy, ok, lines)`:
`ok` are the columns with finite coordinates, and each entry of `lines`
is `(ax, perp, succ)` with `succ[i] = (j, spacing_m, between)` for every
column `i` that has a successive column `j`; `between` is true for a
column between lines.
"""
function _ddm_column_successors(struc, columns, span_axis)
    axes = _eq137_unit_axes((Float64(span_axis[1]), Float64(span_axis[2])))
    axes === nothing && return nothing
    sxy = [_eq137_structural_xy(struc, c) for c in columns]
    ok = [k for k in eachindex(columns) if all(isfinite, sxy[k])]
    dist(a, b) = hypot(sxy[b][1] - sxy[a][1], sxy[b][2] - sxy[a][2])
    nn = Float64[]
    for a in ok
        dmin = minimum((dist(a, b) for b in ok if dist(a, b) >= _EQ137_FAR_MIN_ALONG_M);
                       init = Inf)
        isfinite(dmin) && push!(nn, dmin)
    end
    twin_m = isempty(nn) ? 0.0 : _DDM_OFFSET_TWIN_FRAC * sort(nn)[(length(nn) + 1) ÷ 2]
    group = Dict(a => [b for b in ok if b == a || dist(a, b) < twin_m] for a in ok)
    lines = Tuple{NTuple{2,Float64},NTuple{2,Float64},Dict{Int,Tuple{Int,Float64,Bool}}}[]
    for ax in (axes[1], axes[2])
        perp = (-ax[2], ax[1])
        along_of(a, b) = (sxy[b][1] - sxy[a][1]) * ax[1] + (sxy[b][2] - sxy[a][2]) * ax[2]
        perp_of(a, b) = (sxy[b][1] - sxy[a][1]) * perp[1] + (sxy[b][2] - sxy[a][2]) * perp[2]
        succ = Dict{Int,Tuple{Int,Float64,Bool}}()
        for i in ok
            ahead = [j for j in ok if !(j in group[i]) && along_of(i, j) >= _EQ137_FAR_MIN_ALONG_M]
            isempty(ahead) && continue
            span_m = minimum(along_of(i, j) for j in ahead)
            spacing = Dict(σ => _ddm_line_spacing_m(i, σ, ok, group, along_of, perp_of, dist)
                           for σ in (1, -1))
            side_spacing(σ) = !isnan(spacing[σ]) ? spacing[σ] :
                              !isnan(spacing[-σ]) ? spacing[-σ] : span_m
            best = (Inf, 0, 0.0, false)
            for j in ahead
                p = perp_of(i, j)
                s = side_spacing(p >= 0 ? 1 : -1)
                abs(p) > _DDM_LINE_OTHER_FRAC * s && continue
                d = dist(i, j)
                d < best[1] && (best = (d, j, s, abs(p) >= _DDM_LINE_MEMBER_FRAC * s))
            end
            best[2] > 0 && (succ[i] = (best[2], best[3], best[4]))
        end
        push!(lines, (ax, perp, succ))
    end
    return (sxy = sxy, ok = ok, lines = lines)
end

"""
Transverse column-line spacing (meters) on side `σ` (±1 along the
perpendicular) of column `i`: the perpendicular distance to the nearest
(plan distance) column across from `i`, i.e. at least
`_EQ137_FAR_MIN_ALONG_M` off on that side and more across than along
(|perp| > |along|), twins excluded.  `NaN` when there is none.  A column
offset by less than its span from a line is never across from that line's
columns, so it does not shorten the spacing it is measured against.
"""
function _ddm_line_spacing_m(i, σ, ok, group, along_of, perp_of, dist)::Float64
    best_d = Inf
    s = NaN
    for k in ok
        k in group[i] && continue
        p = perp_of(i, k)
        σ * p >= _EQ137_FAR_MIN_ALONG_M || continue
        abs(p) > abs(along_of(i, k)) || continue
        d = dist(i, k)
        d < best_d && (best_d = d; s = abs(p))
    end
    return s
end

"""
ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252) violations: "Offset of
columns by a maximum of 10 percent of the span (in direction of offset)
from either axis between centerlines of successive columns shall be
permitted."

Successive columns along `span_axis` and its perpendicular come from
`_ddm_column_successors` (column-line membership by the transverse
column-line spacing).  The pair is flagged when its offset exceeds 10% of
the span (`_ddm_offset_span_m`); a column between two column lines says
so in the message.  No successive column (a line end, or a missing column
with no in-line column further ahead) is not an offset: span regularity is
§13.6.1.3 (`_successive_span_violations`).
"""
function _column_offset_violations(struc, columns, span_axis)::Vector{String}
    out = String[]
    res = _ddm_column_successors(struc, columns, span_axis)
    res === nothing && return out
    sxy = res.sxy
    for (ax, perp, succ) in res.lines, i in res.ok
        haskey(succ, i) || continue
        j, spacing, between = succ[i]
        d = sxy[j] .- sxy[i]
        span = _ddm_offset_span_m(d, ax)
        offset = abs(d[1] * perp[1] + d[2] * perp[2])
        limit = _DDM_OFFSET_LIMIT_FRAC * span
        offset > limit || continue
        note = between ?
            "; it lies between column lines ($(round(100 * offset / spacing, digits=1))% " *
            "of the $(round(spacing, digits=2)) m transverse spacing) and is checked " *
            "against this line" : ""
        push!(out,
            "§13.6.1.4: Column $(j) offset $(round(offset, digits=2)) m " *
            "($(round(100 * offset / span, digits=1))% of the $(round(span, digits=2)) m span) " *
            "from the axis through column $(i) > 10% of the span " *
            "($(round(limit, digits=2)) m)$(note) (corpus: aci-318-11, page 252)")
    end
    return out
end

"""
    _guarded_offset_violations(check) -> Vector{String}

Run the §13.6.1.4 offset `check` (a zero-argument function returning
violations). If it throws, the offset limit is unverified, and that is
returned as a violation so DDM is not used, the same as an ambiguous panel.
"""
function _guarded_offset_violations(check)
    try
        return check()
    catch e
        @warn "DDM §13.6.1.4: column offset could not be checked — coordinate lookup failed" exception=(e, catch_backtrace())
        return ["§13.6.1.4: column offset could not be verified " *
                "(coordinate lookup failed: $(sprint(showerror, e))) " *
                "(corpus: aci-318-11, page 252)"]
    end
end

# ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252): "ratio of longer to
# shorter span center-to-center of supports within a panel not greater
# than 2."  The 1e-9 relative allowance is float tolerance only, so a
# panel at exactly 2 built from rounded coordinates is not rejected.
const _DDM_PANEL_ASPECT_MAX = 2.0
const _DDM_PANEL_ASPECT_RTOL = 1e-9

"""
ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252) panel aspect-ratio
violations from the column layout: "Panels shall be rectangular, with a
ratio of longer to shorter span center-to-center of supports within a
panel not greater than 2."

The panel at column `i` is bounded by `i`, its successive column along the
span axis and its successive column along the perpendicular
(`_ddm_column_successors`).  Its spans are the center-to-center distances
to those columns measured along each axis (`_ddm_offset_span_m`).  A panel
is checked only when its center lies inside one of the slab's cells, so a
void (courtyard, re-entrant corner) between columns is not a panel.
Empty without skeleton geometry; the slab-span check in
`check_ddm_applicability` still applies.
"""
function _panel_aspect_violations(struc, slab, columns, span_axis)::Vector{String}
    out = String[]
    _eq137_geometry_available(struc) || return out
    hasproperty(slab, :cell_indices) || return out
    res = _ddm_column_successors(struc, columns, span_axis)
    res === nothing && return out
    polys = [p for p in (_eq137_cell_poly_m(struc, ci) for ci in slab.cell_indices)
             if p !== nothing && length(p) >= 3]
    isempty(polys) && return out
    (ax, _, succ_a), (pax, _, succ_p) = res.lines
    sxy = res.sxy
    seen = Set{Tuple{Int,Int}}()
    for i in res.ok
        (haskey(succ_a, i) && haskey(succ_p, i)) || continue
        ja, jp = succ_a[i][1], succ_p[i][1]
        la = _ddm_offset_span_m(sxy[ja] .- sxy[i], ax)
        lp = _ddm_offset_span_m(sxy[jp] .- sxy[i], pax)
        centre = (sxy[i][1] + (la * ax[1] + lp * pax[1]) / 2,
                  sxy[i][2] + (la * ax[2] + lp * pax[2]) / 2)
        any(p -> _eq137_point_in_poly(centre, p), polys) || continue
        ratio = max(la, lp) / min(la, lp)
        ratio > _DDM_PANEL_ASPECT_MAX * (1 + _DDM_PANEL_ASPECT_RTOL) || continue
        key = (round(Int, 100 * min(la, lp)), round(Int, 100 * max(la, lp)))
        key in seen && continue
        push!(seen, key)
        push!(out,
            "§13.6.1.2: Panel at column $(i): longer / shorter span center-to-center = " *
            "$(round(ratio, digits=2)) > 2 [$(round(la, digits=2)) m × $(round(lp, digits=2)) m] " *
            "(corpus: aci-318-11, page 252)")
    end
    return out
end

"""
Why polygon `poly` (meters) is not a rectangular panel, or `nothing`.

ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252): "Panels shall be
rectangular".  ENGINEERING JUDGMENT, tolerance consistent with §13.6.1.4
(page 252), which permits offsets of columns up to 10% of the span between
successive columns: a panel is rectangular when it has four corners
(vertices turning by at least 45°; collinear mesh vertices are not corners)
of one turning sense and, in some orthogonal frame, every corner-to-corner
edge alternates between the frame's two directions with every vertex along
it within 10% of the edge length (`_DDM_OFFSET_LIMIT_FRAC`) of the line
through its start corner.  So a panel whose corners are within the
permitted offsets is not also rejected here; one beyond them is both an
offset (§13.6.1.4) and a non-rectangular panel (§13.6.1.2).  The frames
tried are `ax` (the span axis) and the best-fit orientation of the corner
edges (circular mean of their directions modulo 90°), so the test does not
depend on the panel's orientation in plan.  Commentary R13.6.1.4 (page 252)
describes the permitted offsets as "from a regular rectangular array", so
the frame is the array's; as a consequence an interior angle may differ
from 90° by up to 2·atan(0.10) ≈ 11.4° (e.g. a 10° parallelogram, every
edge 8.7% off the array rotated by 5°).  The §13.6.1.4 offset check itself
measures against the span axis and still sees such a skew there.
"""
function _ddm_panel_not_rectangular(poly, ax::NTuple{2,Float64})
    pts = NTuple{2,Float64}[]
    for p in poly
        (isempty(pts) || !_eq137_coincide(p, pts[end])) && push!(pts, (Float64(p[1]), Float64(p[2])))
    end
    length(pts) > 1 && _eq137_coincide(pts[1], pts[end]) && pop!(pts)
    n = length(pts)
    n >= 3 || return "degenerate polygon ($(n) distinct vertices)"
    turn = map(1:n) do k
        a, b, c = pts[mod1(k - 1, n)], pts[k], pts[mod1(k + 1, n)]
        u = (b[1] - a[1], b[2] - a[2])
        v = (c[1] - b[1], c[2] - b[2])
        atan(u[1] * v[2] - u[2] * v[1], u[1] * v[1] + u[2] * v[2])
    end
    corners = [k for k in 1:n if abs(turn[k]) >= π / 4]
    length(corners) == 4 || return "it has $(length(corners)) corners, not 4"
    allequal(sign(turn[k]) for k in corners) || return "it has a re-entrant corner"
    edges = [(corners[e], corners[mod1(e + 1, 4)]) for e in 1:4]
    θs = [atan(pts[b][2] - pts[a][2], pts[b][1] - pts[a][1]) for (a, b) in edges]
    φ = atan(sum(sin(4θ) for θ in θs), sum(cos(4θ) for θ in θs)) / 4
    worst = Inf
    for f in (ax, (cos(φ), sin(φ)))
        g = (-f[2], f[1])
        dirs = Int[]
        frame_worst = 0.0
        for (a, b) in edges
            d = (pts[b][1] - pts[a][1], pts[b][2] - pts[a][2])
            df, dg = abs(d[1] * f[1] + d[2] * f[2]), abs(d[1] * g[1] + d[2] * g[2])
            main, other = df >= dg ? (f, g) : (g, f)
            push!(dirs, df >= dg ? 1 : 2)
            len = max(df, dg)
            k = a
            while true
                k = mod1(k + 1, n)
                q = (pts[k][1] - pts[a][1], pts[k][2] - pts[a][2])
                frame_worst = max(frame_worst, abs(q[1] * other[1] + q[2] * other[2]) / len)
                k == b && break
            end
        end
        all(e -> dirs[e] != dirs[mod1(e + 1, 4)], 1:4) || (frame_worst = Inf)
        worst = min(worst, frame_worst)
    end
    worst <= _DDM_OFFSET_LIMIT_FRAC && return nothing
    isfinite(worst) || return "its edges do not alternate between two orthogonal directions"
    return "a corner or edge vertex is $(round(100 * worst, digits=1))% of the edge length " *
           "off the line through the edge's start corner (> 10%, §13.6.1.4 tolerance)"
end

"""
Column-bounded panels of the layout that are rectangular
(`_ddm_panel_not_rectangular`), as corner polygons (meters).

ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252) speaks of panels
bounded by the supports ("span center-to-center of supports within a
panel"), not of the mesh faces that discretize them.  The panel at column
`i` has corners `i`, its successive column `ja` along the span axis, its
successive column `jp` along the perpendicular (`_ddm_column_successors`),
and the fourth corner `jd`, which must be both the successive column of
`ja` along the perpendicular and of `jp` along the span axis.  Without that
closing column the four columns do not bound one panel and none is
returned for `i`.
"""
function _ddm_rectangular_column_panels(struc, columns, span_axis)
    out = Vector{NTuple{2,Float64}}[]
    res = _ddm_column_successors(struc, columns, span_axis)
    res === nothing && return out
    (ax, _, succ_a), (_, _, succ_p) = res.lines
    sxy = res.sxy
    for i in res.ok
        (haskey(succ_a, i) && haskey(succ_p, i)) || continue
        ja, jp = succ_a[i][1], succ_p[i][1]
        (haskey(succ_p, ja) && haskey(succ_a, jp)) || continue
        jd = succ_p[ja][1]
        jd == succ_a[jp][1] || continue
        poly = [sxy[i], sxy[ja], sxy[jd], sxy[jp]]
        _ddm_panel_not_rectangular(poly, ax) === nothing && push!(out, poly)
    end
    return out
end

"""True when plan point `P` is inside `poly` or within `_EQ137_COINCIDE_M` of its boundary."""
function _ddm_point_in_or_on(P, poly)::Bool
    _eq137_point_in_poly(P, poly) && return true
    n = length(poly)
    return any(_eq137_seg_nearest(P, poly[k], poly[mod1(k + 1, n)])[2] <= _EQ137_COINCIDE_M
               for k in 1:n)
end

"""
ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252) rectangular-panel
violations.  Empty without skeleton geometry.

The verdict does not depend on how the panels are meshed: a slab cell
lying wholly (every corner in or on the boundary) inside a rectangular
column-bounded panel (`_ddm_rectangular_column_panels`, from `columns`) is
part of that panel and is not tested on its own, so a triangulated or
sub-divided regular bay passes as its quad mesh does.  Every other cell
(not inside such a panel, e.g. a panel whose four columns are not
rectangular, a polygonal face with no four-column panel around it, or a
slab overhang beyond the edge columns) must itself be a rectangular panel
(`_ddm_panel_not_rectangular`); one violation is reported per cell that is
not.
"""
function _panel_rectangularity_violations(struc, slab, span_axis;
                                          columns = ())::Vector{String}
    out = String[]
    _eq137_geometry_available(struc) || return out
    hasproperty(slab, :cell_indices) || return out
    axes = _eq137_unit_axes((Float64(span_axis[1]), Float64(span_axis[2])))
    ax = axes === nothing ? (1.0, 0.0) : axes[1]
    panels = length(columns) >= 2 && all(col_vertex_idx(c) > 0 for c in columns) ?
        _ddm_rectangular_column_panels(struc, columns, span_axis) :
        Vector{NTuple{2,Float64}}[]
    for ci in slab.cell_indices
        poly = _eq137_cell_poly_m(struc, ci)
        poly === nothing && continue
        any(pn -> all(p -> _ddm_point_in_or_on(p, pn), poly), panels) && continue
        why = _ddm_panel_not_rectangular(poly, ax)
        why === nothing && continue
        push!(out, "§13.6.1.2: Panel (cell $(ci)) is not rectangular: $(why) " *
                   "(corpus: aci-318-11, page 252)")
    end
    return out
end

"""
    _ddm_continuous_span_counts(struc, columns, span_axis) -> Union{Nothing,NTuple{2,Int}}

Continuous spans along `span_axis` and along its perpendicular.

ACI 318-11 §13.6.1.1 (corpus: aci-318-11, page 252): "There shall be a
minimum of three continuous spans in each direction."  A span is one step
from a column to its successive column on the same line
(`_ddm_column_successors`).  A frame is one connected line of those steps.
The count in a direction is the shortest frame, not the longest run and
not the number of columns: a long frame does not cover a short one.
`nothing` when the skeleton cannot place the columns.
"""
function _ddm_continuous_span_counts(struc, columns, span_axis; slab=nothing)::Union{Nothing,NTuple{2,Int}}
    _eq137_geometry_available(struc) || return nothing
    isempty(columns) && return (0, 0)
    all(c -> col_vertex_idx(c) > 0, columns) || return nothing
    res = _ddm_column_successors(struc, columns, span_axis)
    res === nothing && return nothing
    if slab !== nothing
        for (ax, perp, succ) in res.lines
            _ddm_add_wall_end_spans!(succ, res.sxy, res.ok, ax, perp, struc, slab, columns)
        end
    end
    return ntuple(k -> _shortest_frame_spans(res.lines[k][3], res.ok), 2)
end

"""
Add a span at a wall that crosses a column line.

R13.1 (corpus: aci-318-11, page 243): a wall on the whole panel edge and a
shorter wall are both supports. A wall between two columns splits that step
when both pieces lie on the slab. A step that crosses an opening ends at
the wall instead of being counted across the void. A wall ahead of a line
end, or behind a line start, adds one span.
"""
function _ddm_add_wall_end_spans!(succ, sxy, ok, ax, perp, struc, slab, columns)
    segs = supporting_wall_segments(struc, slab)
    isempty(segs) && return succ
    next_id = 0
    for seg in segs
        # A full-edge wall and a shorter wall are both supports. The shorter
        # one is a column (R13.1); either way the frame gains the span.
        wx = seg[2][1] - seg[1][1]
        wy = seg[2][2] - seg[1][2]
        wlen = hypot(wx, wy)
        wlen < 1e-3 && continue
        abs(wx * ax[1] + wy * ax[2]) / wlen > 0.35 && continue
        t1 = seg[1][1] * perp[1] + seg[1][2] * perp[2]
        t2 = seg[2][1] * perp[1] + seg[2][2] * perp[2]
        tlo, thi = minmax(t1, t2)
        s_wall = 0.5 * ((seg[1][1] + seg[2][1]) * ax[1] + (seg[1][2] + seg[2][2]) * ax[2])
        for i in ok
            ti = sxy[i][1] * perp[1] + sxy[i][2] * perp[2]
            tlo - 0.05 <= ti <= thi + 0.05 || continue
            si = sxy[i][1] * ax[1] + sxy[i][2] * ax[2]
            gap = s_wall - si
            abs(gap) < 0.3 && continue
            between = false
            for j in ok
                j == i && continue
                tj = sxy[j][1] * perp[1] + sxy[j][2] * perp[2]
                abs(tj - ti) > 0.5 && continue
                sj = sxy[j][1] * ax[1] + sxy[j][2] * ax[2]
                lo, hi = minmax(si, s_wall)
                if sj > lo + 0.3 && sj < hi - 0.05
                    between = true
                    break
                end
            end
            between && continue
            if gap > 0
                if haskey(succ, i) && succ[i][1] > 0
                    j = succ[i][1]
                    sj = sxy[j][1] * ax[1] + sxy[j][2] * ax[2]
                    lo, hi = minmax(si, sj)
                    if lo + 0.3 < s_wall < hi - 0.3
                        ti = sxy[i][1] * perp[1] + sxy[i][2] * perp[2]
                        contains = _slab_plan_contains(struc, slab)
                        at(s) = (s * ax[1] + ti * perp[1], s * ax[2] + ti * perp[2])
                        near = contains === nothing || contains(at((si + s_wall) / 2))
                        far = contains === nothing || contains(at((sj + s_wall) / 2))
                        # Both pieces on the slab: one column step is two spans.
                        # Only the near piece: the step was crossing an opening,
                        # so it ends at the wall instead.
                        if near && far
                            next_id -= 1
                            succ[next_id] = (j, abs(sj - s_wall), false)
                        elseif near && !far
                            next_id -= 1
                            succ[i] = (next_id, s_wall - si, false)
                        end
                    end
                    continue
                end
                if haskey(succ, i) && succ[i][2] <= gap
                    continue
                end
                next_id -= 1
                succ[i] = (next_id, gap, false)
            else
                started = !any(succ) do (a, spec)
                    spec[1] == i && a > 0
                end
                started || continue
                dist = -gap
                farther = Int[]
                for (a, spec) in succ
                    a < 0 && spec[1] == i || continue
                    spec[2] <= dist && (dist = -1.0)
                    push!(farther, a)
                end
                dist < 0 && continue
                for a in farther
                    delete!(succ, a)
                end
                next_id -= 1
                succ[next_id] = (i, -gap, false)
            end
        end
    end
    return succ
end

"""Fewest successor steps on any one frame. A line with no span counts as 0."""
function _shortest_frame_spans(succ, members)::Int
    parent = Dict{Int,Int}()
    function find(x)
        haskey(parent, x) || (parent[x] = x)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    for i in members
        parent[i] = i
    end
    isempty(succ) && return 0
    for (i, spec) in succ
        j = spec[1]
        ri, rj = find(i), find(j)
        ri != rj && (parent[rj] = ri)
    end
    counts = Dict{Int,Int}()
    for (i, _) in succ
        r = find(i)
        counts[r] = get(counts, r, 0) + 1
    end
    return minimum(values(counts))
end

# Same station `_ddm_add_wall_end_spans!` treats as the column itself.
const _WALL_AT_COLUMN_M = 0.3
# A column this close to the wall line, measured across the line, is on it.
const _WALL_ON_LINE_M = 0.05

"""
Stations of `columns` on the line through `seg`.

`along` is metres from the first end toward the second. `perp` is metres
to the left of that direction. A column with no vertex is omitted.
"""
function _wall_column_stations(struc, columns, seg)
    dx = seg[2][1] - seg[1][1]
    dy = seg[2][2] - seg[1][2]
    L = hypot(dx, dy)
    L < 1e-3 && return nothing
    ux, uy = dx / L, dy / L
    stations = Tuple{Int, Float64, Float64}[]
    for (i, col) in enumerate(columns)
        col_vertex_idx(col) > 0 || continue
        x, y = _eq137_structural_xy(struc, col)
        rx = x - seg[1][1]
        ry = y - seg[1][2]
        push!(stations, (i, rx * ux + ry * uy, -rx * uy + ry * ux))
    end
    return (L = L, stations = stations)
end

"""
True when `seg` runs from one column to another.

ACI 318-11 R13.1 (aci-318-11, page 243): a wall that supports the entire
length of a panel edge is a beam of infinite stiffness (§13.2.3). A wall
shorter than that edge is a column, and §13.6.1.3 then applies to the
spans on either side. An end within `_WALL_AT_COLUMN_M` of a column
center, and within `_WALL_ON_LINE_M` of that column's line, is that column.
"""
function wall_is_fully_restrained(struc, _slab, seg, columns)
    frame = _wall_column_stations(struc, columns, seg)
    frame === nothing && return false
    at_end(s, target) =
        abs(s[2] - target) <= _WALL_AT_COLUMN_M && abs(s[3]) <= _WALL_ON_LINE_M
    ids0 = Int[s[1] for s in frame.stations if at_end(s, 0.0)]
    idsL = Int[s[1] for s in frame.stations if at_end(s, frame.L)]
    return !isempty(ids0) && any(i -> i ∉ ids0, idsL)
end

"""
Center-to-center distances from a short wall to the nearest column on each side.

The two distances are the successive spans of ACI 318-11 §13.6.1.3
(aci-318-11, page 252). `nothing` when either side has no column. A column
on the wall line is an end of the wall, not a span beside it.
"""
function _columns_off_wall(struc, columns, seg)
    frame = _wall_column_stations(struc, columns, seg)
    frame === nothing && return nothing
    left = Inf
    right = Inf
    for (_, _, perp) in frame.stations
        abs(perp) <= _WALL_AT_COLUMN_M && continue
        if perp > 0
            left = min(left, perp)
        else
            right = min(right, -perp)
        end
    end
    (isfinite(left) && isfinite(right)) || return nothing
    return (pairs = [(left,), (right,)],)
end

"""
§13.6.1.3 for a wall shorter than the panel edge. The two center-to-center
distances from the wall to the columns on either side are successive spans.
"""
function _short_wall_span_violations(struc, slab, columns)::Vector{String}
    out = String[]
    _eq137_geometry_available(struc) || return out
    for seg in supporting_wall_segments(struc, slab)
        wall_is_fully_restrained(struc, slab, seg, columns) && continue
        sides = _columns_off_wall(struc, columns, seg)
        sides === nothing && continue
        length(sides.pairs) < 2 && continue
        la, lb = sides.pairs[1][1], sides.pairs[2][1]
        longer = max(la, lb)
        longer > 0 || continue
        abs(la - lb) > longer / 3 || continue
        push!(out,
            "§13.6.1.3: successive spans on either side of a wall differ by more than " *
            "one-third of the longer span (corpus: aci-318-11, page 252)")
        break
    end
    return out
end

"""
    check_ddm_applicability(struc, slab, columns; throw_on_failure=true)

Check if DDM is applicable per ACI 318-11 §13.6.1.

# ACI 318-11 §13.6.1 Limitations (DDM shall be permitted only when):

Clause numbers are ACI 318-11 (corpus: aci-318-11, page 252).

1. **§13.6.1.1** - At least 3 continuous spans in each direction
2. **§13.6.1.2** - Panels are rectangular, longer / shorter span center-to-center ≤ 2
   (from the slab spans and, with skeleton geometry, per panel from the column
   layout and the cell faces: `_panel_aspect_violations`,
   `_panel_rectangularity_violations`)
3. **§13.6.1.3** - Successive span lengths (center-to-center) differ by ≤ 1/3 of the longer span
4. **§13.6.1.4** - Columns are not offset > 10% of span from column lines
5. **§13.6.1.5** - All loads are due to gravity only, uniformly distributed;
   unfactored L ≤ 2 × unfactored D
6. **§13.6.1.6** - For slabs with beams: Eq. (13-2), 0.2 ≤ αf1·l2² / (αf2·l1²) ≤ 5.0

# Arguments
- `struc`: BuildingStructure (for building-level span information)
- `slab`: Slab being designed.  Optional manual override: a Bool field
  `is_rectangular` replaces the geometric rectangular-panel test —
  `false` records a §13.6.1.2 violation, `true` asserts the panels are
  rectangular and skips `_panel_rectangularity_violations` (the user takes
  responsibility).  The aspect-ratio checks always run.
- `columns`: Vector of supporting columns
- `throw_on_failure`: If true, throw DDMApplicabilityError; if false, return result

# Returns
Named tuple with:
- `ok::Bool`: true if DDM is applicable
- `violations::Vector{String}`: list of violated conditions with code references

# Throws
`DDMApplicabilityError` if any condition is violated and `throw_on_failure=true`
"""
function check_ddm_applicability(struc, slab, columns; throw_on_failure::Bool = true, ρ_concrete::Density = NWC_4000.ρ)
    violations = String[]
    
    l1 = slab.spans.primary
    l2 = slab.spans.secondary
    
    # -------------------------------------------------------------------------
    # Minimum clear span check (practical limit for two-way behavior)
    # -------------------------------------------------------------------------
    # Two-way slab analysis assumes slenderness; spans < 4 ft behave more like
    # thick plates where shear governs over flexure
    if !isempty(columns)
        c1_avg = sum(isnothing(col.c1) ? 0.0u"inch" : col.c1 for col in columns) / length(columns)
        ln = clear_span(l1, c1_avg)
        
        ln_min = 4.0u"ft"
        if ln < ln_min
            push!(violations, "Clear span ln = $(round(ustrip(u"ft", ln), digits=2)) ft < $(ustrip(u"ft", ln_min)) ft minimum for two-way slab behavior")
        end
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.2 - Panels shall be rectangular (corpus: aci-318-11, page 252)
    # -------------------------------------------------------------------------
    # Verify valid rectangular geometry (positive orthogonal spans)
    zero_len = 0.0 * unit(l1)
    span_axis = _get_span_axis(slab)
    
    if l1 <= zero_len || l2 <= zero_len
        push!(violations, "§13.6.1.2: Panel must be rectangular; invalid span dimensions l₁=$(l1), l₂=$(l2) (corpus: aci-318-11, page 252)")
    end
    
    # Geometric test of every cell face, unless the slab carries the manual
    # `is_rectangular` override (see the docstring).
    rect_override = hasproperty(slab, :is_rectangular) ? slab.is_rectangular : nothing
    if rect_override === false
        push!(violations, "§13.6.1.2: Panel must be rectangular; slab is marked non-rectangular (is_rectangular = false) (corpus: aci-318-11, page 252)")
    elseif rect_override !== true
        append!(violations, _panel_rectangularity_violations(struc, slab, span_axis;
                                                             columns = columns))
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.2 - Longer / shorter span center-to-center ≤ 2 (page 252)
    # -------------------------------------------------------------------------
    if l1 > zero_len && l2 > zero_len
        ratio = l2 / l1  # dimensionless
        if ratio > 2.0
            push!(violations, "§13.6.1.2: Panel aspect ratio l₂/l₁ = $(round(ratio, digits=2)) > 2.0 (corpus: aci-318-11, page 252)")
        elseif ratio < 0.5
            push!(violations, "§13.6.1.2: Panel aspect ratio l₂/l₁ = $(round(ratio, digits=2)) < 0.5 (inverse > 2.0) (corpus: aci-318-11, page 252)")
        end
    end
    # Per panel from the column layout (center-to-center of supports).
    if length(columns) >= 2 && all(col_vertex_idx(col) > 0 for col in columns)
        append!(violations, _panel_aspect_violations(struc, slab, columns, span_axis))
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.5 - Unfactored L ≤ 2 × unfactored D (corpus: aci-318-11, page 252)
    # -------------------------------------------------------------------------
    # D = SDL + self-weight. At this point we don't have the final slab thickness,
    # so we estimate self-weight using the minimum thickness for the longest span.
    # This gives a conservative (lower) estimate of D, making L/D appear higher.
    # ENGINEERING JUDGMENT: where the slab's cells carry different loads, the
    # largest cell L/D is checked.
    # Estimate self-weight from ACI minimum thickness (Table 8.3.1.1)
    γ_concrete = ρ_concrete * GRAVITY
    ln_max = max(l1, l2)
    h_min_estimate = min_thickness(FlatPlate(), ln_max)
    sw_estimate = uconvert(psf, h_min_estimate * γ_concrete)

    LD_ratio = 0.0
    for ci in slab.cell_indices
        cell = struc.cells[ci]
        qD = uconvert(psf, cell.sdl + sw_estimate)  # Include self-weight estimate
        iszero(qD) && continue
        LD_ratio = max(LD_ratio, ustrip(psf, cell.live_load) / ustrip(psf, qD))
    end

    if LD_ratio > 2.0
        push!(violations, "§13.6.1.5: Live/Dead ratio L/D = $(round(LD_ratio, digits=2)) > 2.0 (using estimated h_min for self-weight) (corpus: aci-318-11, page 252)")
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.1 - Minimum 3 continuous spans in each direction (page 252)
    # -------------------------------------------------------------------------
    # Count successive columns along a line (`_ddm_continuous_span_counts`),
    # not the number of columns.  Four columns can be one span each way.
    counts = _ddm_continuous_span_counts(struc, columns, span_axis; slab=slab)
    if counts === nothing
        push!(violations, "§13.6.1.1: DDM requires a minimum of three continuous spans in each direction; column lines could not be read from this slab (corpus: aci-318-11, page 252)")
    elseif counts[1] < 3 || counts[2] < 3
        push!(violations, "§13.6.1.1: DDM requires a minimum of three continuous spans in each direction, on every frame; the shortest frame has $(counts[1]) spans along the span axis and $(counts[2]) transversely (corpus: aci-318-11, page 252)")
    end

    # A wall shorter than the panel edge is a column (R13.1, page 243).
    # Its two sides are successive spans when columns stand on both sides.
    append!(violations, _short_wall_span_violations(struc, slab, columns))
    
    # -------------------------------------------------------------------------
    # §13.6.1.3 — Successive span lengths, center-to-center of supports,
    # in each direction, shall not differ by more than one-third the
    # longer span (corpus: aci-318-11, page 252).
    # -------------------------------------------------------------------------
    # Same geometry lookup as Eq. (13-7).  Skipped only when the skeleton
    # cannot identify adjoining panels.  A violation is recorded on the same
    # list as the other §13.6.1 checks; it does not introduce a new
    # exception type.  Ambiguous panels are a violation here too — the
    # moment path still throws ArgumentError if analysis is attempted.
    append!(violations, _successive_span_violations(struc, slab, columns))
    
    # -------------------------------------------------------------------------
    # §13.6.1.4 - Column offset ≤ 10% of span (corpus: aci-318-11, page 252)
    # -------------------------------------------------------------------------
    # Successive columns come from column-line membership by the transverse
    # column-line spacing (`_ddm_column_successors`), so an offset from a
    # column's own line is seen whatever its size; twins and columns on
    # another column line are not successive columns.  A missing column is a
    # span-length matter, left to the §13.6.1.3 check above.  The R13.6.1.4
    # cumulative 20% limit (commentary) is not checked.
    if length(columns) >= 2 && all(col_vertex_idx(col) > 0 for col in columns)
        append!(violations, _guarded_offset_violations(
            () -> _column_offset_violations(struc, columns, span_axis)))
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.5 - Gravity loads only, uniformly distributed (page 252)
    # -------------------------------------------------------------------------
    # We assume this is satisfied since our load model is uniform
    # Lateral loads would be handled by a separate system
    
    # -------------------------------------------------------------------------
    # §13.6.1.6 - Eq. (13-2) beam stiffness ratio (slabs with beams, page 252)
    # -------------------------------------------------------------------------
    # For flat plates (no beams), αf = 0, so this doesn't apply
    # This check would be added for two-way slabs with beams
    
    ok = isempty(violations)
    
    if !ok && throw_on_failure
        # Compute valid alternatives
        alternatives = _compute_ddm_alternatives(struc, slab, columns)
        throw(DDMApplicabilityError(violations, alternatives))
    end
    
    return (ok=ok, violations=violations)
end

"""
Compute list of alternative methods that ARE valid for this geometry.
FEA is always valid (most general). EFM is checked for applicability.
"""
function _compute_ddm_alternatives(struc, slab, columns)
    alternatives = String[]
    
    # Check if EFM is valid (import check function from efm.jl)
    # Note: check_efm_applicability is defined in efm.jl which is included after ddm.jl
    # We use a try-catch to handle the case where EFM check might fail
    try
        efm_result = check_efm_applicability(struc, slab, columns; throw_on_failure=false)
        if efm_result.ok
            push!(alternatives, "EFM (Equivalent Frame Method): method=EFM() — fewer geometric restrictions than DDM")
        end
    catch e
        @warn "DDM: EFM applicability check failed — cannot suggest EFM as alternative" exception=(e, catch_backtrace())
    end
    
    # FEA is always valid - it's the most general method with no geometric restrictions
    push!(alternatives, "FEA (Finite Element Analysis): method=FEA() — no geometric restrictions, handles any layout")
    
    return alternatives
end

"""
    enforce_ddm_applicability(struc, slab, columns)

Enforce DDM applicability, throwing an error if not permitted.
This is called automatically by `run_moment_analysis(::DDM, ...)`.
"""
function enforce_ddm_applicability(struc, slab, columns; ρ_concrete::Density = NWC_4000.ρ)
    check_ddm_applicability(struc, slab, columns; throw_on_failure=true, ρ_concrete=ρ_concrete)
end

