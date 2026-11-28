# ==============================================================================
# Two-way slabs without beams — bar lengths from ACI 318-19 Fig. 8.7.4.1.3
# ==============================================================================
#
# Bars along one frame line in one direction: a column strip and a middle strip
# from the first exterior support to the last. Strip designs give bar size and
# count at the exterior negative, positive, and interior negative sections.
# ==============================================================================

"""
Bar size, count, and required area of one strip at one moment section.

`as_reqd_in2` is the governing design area for these bars, in in², already
scaled to this line. Zero means the caller gave a bar count and no separate
required area, so the reported ideal area is the placed area.
"""
struct StripBars
    bar_size::Int
    n_bars::Int
    as_reqd_in2::Float64
    StripBars(bar_size::Int, n_bars::Int, as_reqd_in2::Real = 0.0) =
        new(bar_size, n_bars, Float64(as_reqd_in2))
end

"""Bars of one strip at the three moment sections of a frame line."""
struct StripLayout
    ext_neg::StripBars
    pos::StripBars
    int_neg::StripBars
    width::_M
end

StripLayout(ext_neg, pos, int_neg, width::Length) =
    StripLayout(ext_neg, pos, int_neg, uconvert(u"m", width))

const _SIX_INCH = 6.0u"inch"

"""
Tension development length of a slab bar: Table 25.4.2.3 (corpus: aci-318-19,
printed pp. 471–472). The favorable row applies when clear spacing is at least
2d_b and clear cover at least d_b. ψt = 1.3 for a top bar with more than 12 in.
of fresh concrete below it.
"""
function _slab_ld(bar_size::Int, fc, fy, λ, coating; spacing::Length, cover::Length,
                  concrete_below::Length)
    db = bar_diameter(bar_size)
    favorable = spacing - db >= 2db && cover >= db
    ψt = concrete_below > 12.0u"inch" ? 1.3 : 1.0
    epoxy_close = cover < 3db || spacing - db < 6db
    return straight_development_length(bar_size, fc, fy, _detailing_λ(λ); ψt = ψt,
                                       coating = coating, epoxy_close = epoxy_close,
                                       favorable_cover = favorable)
end

"""
    detail_flat_plate_line(; kwargs...) -> MemberDetail

Bars of one frame line of a two-way slab without beams, both exterior ends
on columns at the slab edge. Lengths are ACI 318-19 Fig. 8.7.4.1.3 (corpus:
aci-318-19, PDF p. 119, printed p. 117) with §8.7.4.1.3(b): a top-bar
extension past an interior support is set by the longer adjacent clear span.

# Keywords
- `clear_spans`: clear span ℓn of each span, face to face (n values).
- `supports`: support width along the line at each support (n + 1 values).
- `column_strip`, `middle_strip`: [`StripLayout`](@ref) of the two strips.
- `h`, `cover`: slab thickness and clear cover.
- `fc`, `fy`, `λ`, `coating`: materials for development and laps.
- `layer`: `:outer` (bars nearest the faces) or `:inner`.
- `outer_bar_size`: bar size of the outer layer, used to seat the inner layer.
- `drop_panel`: column-strip top extension 0.33ℓn instead of 0.30ℓn.
- `stock`: stock bar length. Longer column-strip bottom runs are lapped.
- `n_lines`: frame lines with this layout; every count is multiplied by it.
- `direction`: `:primary` or `:secondary`, carried to each group.
- `prefix`: mark prefix.
- `core_half_width`: across the line, half the width of the region bounded
  by the longitudinal bars of the narrowest column on it. The two integrity
  bars are placed inside it. `nothing` places them nearest the line.
- `band`: `(y_lo, y_hi)` in meters, the slab on either side of the column
  line. Bars are spread inside it. `nothing` spreads them symmetrically
  about the line, half the strip each side.

# Bars
- Column-strip top, every support: at least half the bars (rounded up)
  extend `max(0.30ℓn, 5d, ℓd)` past each face (0.33ℓn with drop panels). The
  rest extend `max(0.20ℓn, ℓd)`. At an exterior support the bars run to the
  slab edge less cover and end in a 90-degree standard hook (§8.7.4.1.1(b)).
- Column-strip bottom: continuous between exterior supports, 6 in. into each
  exterior support. Two bars pass through every column, within the region
  bounded by its longitudinal bars, and are hooked at the exterior supports
  (§8.7.4.2.2; ACI 318-11 §13.3.8.5, PCA EB712 p. 543). Runs above `stock`
  are lapped Class B (§8.7.4.2.1, Table 25.5.2.1).
- Middle-strip top: `max(0.22ℓn, ℓd)` past each face; hooked at the slab edge.
- Middle-strip bottom: half the bars (rounded up) run 6 in. into each
  exterior support. The rest stop no more than 0.15ℓn from a support.

# Readings of the figure (ENGINEERING JUDGMENT, flagged for review)
- At an interior support the half of the middle-strip bottom bars that runs
  into the support is extended 6 in. past the support centerline from each
  side, which overlaps the bars of the two spans by 12 in.
- The 0.15ℓn cutback of the other middle-strip bottom bars is measured from
  the support centerline, the shorter of the two readings of the figure.
- ℓd is added as a lower bound on every top extension past the face, since
  the face of support is a critical section for the negative moment.
"""
function detail_flat_plate_line(; clear_spans::AbstractVector, supports::AbstractVector,
                                column_strip::StripLayout, middle_strip::StripLayout,
                                h::Length, cover::Length, fc, fy, λ::Real = 1.0,
                                coating::Symbol = :uncoated, layer::Symbol = :outer,
                                outer_bar_size::Int = 0, drop_panel::Bool = false,
                                stock::Length = 60.0u"ft", n_lines::Int = 1,
                                direction::Symbol = :primary, prefix::AbstractString = "",
                                core_half_width::Union{Nothing, Length} = nothing,
                                band::Union{Nothing, Tuple{Float64, Float64}} = nothing)
    n = length(clear_spans)
    n >= 1 || throw(ArgumentError("a frame line needs at least one span"))
    length(supports) == n + 1 || throw(ArgumentError(
        "a line of $n spans needs $(n + 1) support widths (got $(length(supports)))"))
    layer in (:outer, :inner) || throw(ArgumentError("layer must be :outer or :inner"))
    n_lines >= 0 || throw(ArgumentError("n_lines must be ≥ 0"))

    md = MemberDetail(:slab)
    m(x) = ustrip(u"m", x)
    ℓn = [m(s) for s in clear_spans]
    c = [m(s) for s in supports]
    h_m, cov = m(h), m(cover)
    all(>(0), ℓn) || throw(ArgumentError("clear spans must be positive"))

    # Support faces along the line. x = 0 is the slab edge at the first column.
    xL = zeros(n + 1)
    for j in 2:(n + 1)
        xL[j] = xL[j - 1] + c[j - 1] + ℓn[j - 1]
    end
    xR = xL .+ c
    xc = xL .+ c ./ 2
    total = xR[end]

    db_outer = outer_bar_size > 0 ? m(bar_diameter(outer_bar_size)) : 0.0
    seat(bs) = layer === :outer ? m(bar_diameter(bs)) / 2 :
                                  db_outer + m(bar_diameter(bs)) / 2
    z_top(bs) = h_m - cov - seat(bs)
    z_bot(bs) = cov + seat(bs)
    d_top(bs) = z_top(bs)  # effective depth of a top bar, from the bottom face

    serial = Ref(0)
    function add!(role, bs, count, x0, x1, z, ys = Float64[]; hook_start = false, hook_end = false,
                  hook_dir = -1, laps = 0, lap_len = 0.0, note = "")
        count <= 0 && return
        straight = x1 - x0
        straight > 0 || return
        hook = m(hook_centerline_length(bs; angle = 90))
        tail = m(standard_hook(bs; angle = 90).extension)
        room = hook_dir < 0 ? z - cov : (h_m - cov) - z
        path = NTuple{2, Float64}[]
        rotated = false
        if hook_start
            p, r = _hook_tail(x0, z, tail, room, hook_dir, +1)
            push!(path, p); rotated |= r
        end
        push!(path, (x0, z), (x1, z))
        if hook_end
            p, r = _hook_tail(x1, z, tail, room, hook_dir, -1)
            push!(path, p); rotated |= r
        end
        len = straight + (hook_start + hook_end) * hook + laps * lap_len
        shape = hook_start && hook_end ? :hook_both : hook_start ? :hook_start :
                hook_end ? :hook_end : :straight
        rotated && (note = isempty(note) ? "hook tail rotated to fit the slab" :
                                           note * "; hook tail rotated to fit the slab")
        placed = count * n_lines
        wires = isempty(ys) ? Vector{NTuple{3, Float64}}[] :
                repeat(_wires_at_y(path, ys), n_lines)
        serial[] += 1
        push!(md.groups, BarGroup(; mark = "$(prefix)$(serial[])", role = role,
                                  direction = direction, bar_size = bs,
                                  count = placed, length = len * u"m",
                                  shape = shape, path = path, laps = laps, note = note,
                                  centerlines = wires))
    end

    concrete_below(bs) = (z_top(bs) - m(bar_diameter(bs)) / 2) * u"m"
    ld(sb, strip) = m(_slab_ld(sb.bar_size, fc, fy, λ, coating;
                              spacing = strip.width / max(sb.n_bars, 1),
                              cover = cover, concrete_below = concrete_below(sb.bar_size)))
    span_for(j) = j == 1 ? ℓn[1] : j == n + 1 ? ℓn[n] : max(ℓn[j - 1], ℓn[j])

    # Hooked anchorage at the slab edge, §25.4.3 (corpus: aci-318-19, printed
    # pp. 474–475): the hook must be developed between the face and the edge.
    function check_edge_hook!(bs, j, what)
        avail = c[j] - cov
        ldh = m(hooked_bar_development_length(bs, fc, fy, _detailing_λ(λ); coating = coating))
        ldh <= avail + 1e-9 || push!(md.warnings,
            "$(what) at exterior support $(j): hooked development ℓdh = " *
            "$(round(ldh / 0.0254; digits = 1)) in. exceeds the $(round(avail / 0.0254; digits = 1)) in. " *
            "from the face to the slab edge (ACI 318-19 §8.7.4.1.1(b), §25.4.3)")
    end
    function check_bottom_embed!(j)
        c[j] - cov >= m(_SIX_INCH) - 1e-9 || push!(md.warnings,
            "bottom bars at exterior support $(j) cannot extend 6 in. into the support " *
            "within cover ($(round((c[j] - cov) / 0.0254; digits = 1)) in. available, Fig. 8.7.4.1.3)")
    end
    embed(j) = min(m(_SIX_INCH), c[j] - cov)
    cw = ustrip(u"m", column_strip.width)
    mw = ustrip(u"m", middle_strip.width)
    half_line = (cw + mw) / 2
    y_lo = band === nothing ? -half_line : band[1]
    y_hi = band === nothing ? half_line : band[2]
    y_hi + 1e-9 < y_lo && throw(ArgumentError(
        "a bar band runs from $y_lo m to $y_hi m"))
    function column_ys(n, bs)
        db = m(bar_diameter(bs)) / 2
        if band === nothing
            return _spread(n, -(cw / 2 - db), cw / 2 - db)
        end
        lo = max(y_lo, -cw / 2) + db
        hi = min(y_hi, cw / 2) - db
        hi + 1e-9 < lo && (lo = hi = (max(y_lo, -cw / 2) + min(y_hi, cw / 2)) / 2)
        return _spread(n, lo, hi)
    end
    function middle_ys(n, bs)
        db = m(bar_diameter(bs))
        inset = cov + db / 2
        inner = cw / 2 + db / 2
        if band === nothing
            nL = n ÷ 2
            return [_spread(nL, -half_line + inset, -inner);
                    _spread(n - nL, inner, half_line - inset)]
        end
        col_lo = max(y_lo, -cw / 2)
        col_hi = min(y_hi, cw / 2)
        regions = Tuple{Float64, Float64}[]
        y_lo < col_lo - 1e-8 && push!(regions, (y_lo + inset, col_lo - db / 2))
        col_hi < y_hi - 1e-8 && push!(regions, (col_hi + db / 2, y_hi - inset))
        regions = [(a, b) for (a, b) in regions if b > a + 1e-6]
        if isempty(regions)
            return column_ys(n, bs)
        elseif length(regions) == 1
            return _spread(n, regions[1]...)
        end
        nL = abs(regions[1][2] - regions[1][1] - (regions[2][2] - regions[2][1])) < 0.05 * half_line ?
             n ÷ 2 : clamp(round(Int, n * (regions[1][2] - regions[1][1]) /
                                      ((regions[1][2] - regions[1][1]) + (regions[2][2] - regions[2][1]))),
                           0, n)
        return [_spread(nL, regions[1]...); _spread(n - nL, regions[2]...)]
    end

    # ── Column strip, top ──────────────────────────────────────────────────
    long_frac = drop_panel ? 0.33 : 0.30
    for j in 1:(n + 1)
        exterior = j == 1 || j == n + 1
        sb = exterior ? column_strip.ext_neg : column_strip.int_neg
        sb.n_bars > 0 || continue
        bs = sb.bar_size
        ℓ = span_for(j)
        e_long = max(long_frac * ℓ, 5 * d_top(bs), ld(sb, column_strip))
        e_rem = max(0.20 * ℓ, ld(sb, column_strip))
        n_long = cld(sb.n_bars, 2)
        n_rem = sb.n_bars - n_long
        zt = z_top(bs)
        if exterior
            check_edge_hook!(bs, j, "column-strip top bars")
            row = column_ys(sb.n_bars, bs)
            if j == 1
                add!(:top, bs, n_long, cov, xR[1] + e_long, zt, row[1:n_long]; hook_start = true,
                     note = "column strip, exterior support, long")
                add!(:top, bs, n_rem, cov, xR[1] + e_rem, zt, row[(n_long + 1):end]; hook_start = true,
                     note = "column strip, exterior support")
            else
                add!(:top, bs, n_long, xL[j] - e_long, total - cov, zt, row[1:n_long]; hook_end = true,
                     note = "column strip, exterior support, long")
                add!(:top, bs, n_rem, xL[j] - e_rem, total - cov, zt, row[(n_long + 1):end]; hook_end = true,
                     note = "column strip, exterior support")
            end
        else
            row = column_ys(sb.n_bars, bs)
            add!(:top, bs, n_long, xL[j] - e_long, xR[j] + e_long, zt, row[1:n_long];
                 note = "column strip, interior support, long")
            add!(:top, bs, n_rem, xL[j] - e_rem, xR[j] + e_rem, zt, row[(n_long + 1):end];
                 note = "column strip, interior support")
        end
    end

    # ── Column strip, bottom ───────────────────────────────────────────────
    sb = column_strip.pos
    if sb.n_bars > 0
        bs = sb.bar_size
        zb = z_bot(bs)
        check_bottom_embed!(1); check_bottom_embed!(n + 1)
        lap = m(tension_lap_length(bs, fc, fy, _detailing_λ(λ); as_ratio = 1.0,
                                   percent_spliced = 100.0, coating = coating))
        n_int = min(2, sb.n_bars)
        row = column_ys(sb.n_bars, bs)
        order = sortperm(abs.(row))
        y_int = row[order[1:n_int]]
        if core_half_width !== nothing && n_int == 2
            db = m(bar_diameter(bs))
            y = min(maximum(abs, y_int), m(core_half_width) - db / 2)
            y_int = [-y, y]
            2y - db >= max(m(1.0u"inch"), db) - 1e-9 || push!(md.warnings,
                "the column core, $(round(2 * m(core_half_width) / 0.0254; digits = 1)) in. " *
                "between longitudinal bars, cannot fit two #$(bs) integrity bars at the " *
                "minimum clear spacing (ACI 318-11 §13.3.8.5, §7.6.1)")
        end
        if band !== nothing && n_int > 0
            db = m(bar_diameter(bs))
            lo = y_lo + db / 2
            hi = y_hi - db / 2
            y_int = [clamp(y, lo, hi) for y in y_int]
            if n_int == 2 && abs(y_int[2] - y_int[1]) < db
                y_int = [lo, min(hi, lo + max(db, m(1.0u"inch")))]
            end
        end
        run_int = (total - cov) - cov
        laps_int, _ = stock_splices(run_int * u"m", stock, lap * u"m")
        add!(:integrity, bs, n_int, cov, total - cov, zb, y_int;
             hook_start = true, hook_end = true, hook_dir = +1, laps = laps_int, lap_len = lap,
             note = "integrity bars through the column core (§8.7.4.2.2)")
        x0, x1 = xR[1] - embed(1), xL[n + 1] + embed(n + 1)
        laps_b, _ = stock_splices((x1 - x0) * u"m", stock, lap * u"m")
        add!(:bottom, bs, sb.n_bars - n_int, x0, x1, zb, row[order[(n_int + 1):end]];
             laps = laps_b, lap_len = lap,
             note = laps_b > 0 ? "continuous, Class B laps (§8.7.4.2.1)" : "continuous")
    end

    # ── Middle strip, top ──────────────────────────────────────────────────
    for j in 1:(n + 1)
        exterior = j == 1 || j == n + 1
        sb = exterior ? middle_strip.ext_neg : middle_strip.int_neg
        sb.n_bars > 0 || continue
        bs = sb.bar_size
        e = max(0.22 * span_for(j), ld(sb, middle_strip))
        zt = z_top(bs)
        ys = middle_ys(sb.n_bars, bs)
        if exterior
            check_edge_hook!(bs, j, "middle-strip top bars")
            j == 1 ? add!(:top, bs, sb.n_bars, cov, xR[1] + e, zt, ys; hook_start = true,
                          note = "middle strip, exterior support") :
                     add!(:top, bs, sb.n_bars, xL[j] - e, total - cov, zt, ys; hook_end = true,
                          note = "middle strip, exterior support")
        else
            add!(:top, bs, sb.n_bars, xL[j] - e, xR[j] + e, zt, ys;
                 note = "middle strip, interior support")
        end
    end

    # ── Middle strip, bottom ───────────────────────────────────────────────
    sb = middle_strip.pos
    if sb.n_bars > 0
        bs = sb.bar_size
        zb = z_bot(bs)
        n_full = cld(sb.n_bars, 2)
        n_cut = sb.n_bars - n_full
        row = middle_ys(sb.n_bars, bs)
        six = m(_SIX_INCH)
        for i in 1:n
            x0 = i == 1 ? xR[1] - embed(1) : xc[i] - six
            x1 = i == n ? xL[n + 1] + embed(n + 1) : xc[i + 1] + six
            add!(:bottom, bs, n_full, x0, x1, zb, row[1:n_full]; note = "middle strip, into supports")
            add!(:bottom, bs, n_cut, xc[i] + 0.15 * ℓn[i], xc[i + 1] - 0.15 * ℓn[i], zb,
                 row[(n_full + 1):end]; note = "middle strip, 0.15ℓn cutback")
        end
    end

    push!(md.notes,
        "Middle-strip bottom bars into an interior support run 6 in. past its centerline; " *
        "the 0.15ℓn cutback is measured from the support centerline (reading of Fig. 8.7.4.1.3).")
    _record_strip_areas!(md, direction, :column, column_strip, n_lines)
    _record_strip_areas!(md, direction, :middle, middle_strip, n_lines)
    md.solid = (0.0, total, y_lo, y_hi, 0.0, h_m)
    return md
end

"""
One area pair per moment section that has bars.

Placed area is the bar count times the catalog area, times `n_lines`. Ideal
area is the governing design area when the layout carries one, otherwise the
placed area. Integrity bars and the long/short split are parts of that count,
not extra steel, so the groups are not summed.
"""
function _record_strip_areas!(md, direction, strip, layout, n_lines)
    for (loc, bars) in (("extneg", layout.ext_neg), ("pos", layout.pos),
                        ("intneg", layout.int_neg))
        bars.n_bars > 0 || continue
        placed = bars.n_bars * n_lines * ustrip(u"inch^2", bar_area(bars.bar_size))
        ideal = bars.as_reqd_in2 > 0 ? bars.as_reqd_in2 * n_lines : placed
        record_steel_area!(md, "$(direction)_$(strip)_$(loc)", ideal, placed;
                           source = "the strip design")
    end
    return nothing
end

"""Strip bars of a flat plate result at one moment section, or none."""
function _strip_at(reinf, loc::Symbol)
    i = findfirst(r -> r.location === loc, reinf)
    i === nothing && return StripBars(0, 0)
    return StripBars(reinf[i].bar_size, reinf[i].n_bars)
end

"""
Bars of one section scaled to a frame line, with the governing design area.

The count is rounded up so the line is at least as heavy as the design strip.
The ideal area is `max(As_reqd, As_min)` times the same width ratio when that
area is finite and the section is adequate. An inadequate section leaves the
required area unset, and the reported ideal area is then the placed area.
"""
function _scaled_strip(reinf, loc, ratio)
    sb = _strip_at(reinf, loc)
    n = sb.n_bars > 0 ? ceil(Int, sb.n_bars * ratio - 1e-9) : 0
    i = findfirst(r -> r.location === loc, reinf)
    req = 0.0
    if n > 0 && i !== nothing && reinf[i].section_adequate
        gov = max(ustrip(u"inch^2", reinf[i].As_reqd), ustrip(u"inch^2", reinf[i].As_min))
        isfinite(gov) && (req = gov * ratio)
    end
    return StripBars(sb.bar_size, n, req)
end

"""
    detail_flat_plate_slab(struc, slab; cover, fc, fy, kwargs...) -> MemberDetail

Bars of a whole flat plate or flat slab, both directions, on the frame lines
the equivalent frame method uses ([`_equivalent_frames`](@ref) without the
edge strip): columns grouped into lines, wall supports placed, and lines split
at openings. Each line is detailed by [`detail_flat_plate_line`](@ref).

The strip designs are for one design strip of width `column_strip_width +
middle_strip_width`. A line carries that many bars times its tributary width
over the design strip width, rounded up, so the bar spacing is the design
spacing. Primary bars are the outer layer and secondary bars the inner layer.
A direction without a strip design is not detailed and is noted.
"""
function detail_flat_plate_slab(struc, slab; cover::Length, fc, fy, λ::Real = 1.0,
                                coating::Symbol = :uncoated, stock::Length = 60.0u"ft")
    r = slab.result
    r isa FlatPlatePanelResult || throw(ArgumentError(
        "detail_flat_plate_slab needs a FlatPlatePanelResult (got $(typeof(r)))"))
    md = MemberDetail(:slab)
    columns = find_supporting_columns(struc, Set(slab.cell_indices))
    if length(columns) < 2
        push!(md.notes, "Fewer than two supporting columns: no frame line to detail.")
        return md
    end
    axes = _eq137_unit_axes(slab.spans.axis)
    ax = axes === nothing ? (1.0, 0.0) : axes[1]
    perp = (-ax[2], ax[1])
    drop = hasproperty(slab, :drop_panel) && slab.drop_panel !== nothing
    outer_bs = maximum((x.bar_size for x in vcat(r.column_strip_reinf, r.middle_strip_reinf));
                       init = 0)
    m(x) = ustrip(u"m", x)

    dirs = ((:primary, "P", ax, r.column_strip_reinf, r.middle_strip_reinf,
             r.column_strip_width, r.middle_strip_width, slab.spans.secondary, slab.spans.primary),
            (:secondary, "S", perp, r.secondary_column_strip_reinf, r.secondary_middle_strip_reinf,
             r.secondary_column_strip_width, r.secondary_middle_strip_width,
             slab.spans.primary, slab.spans.secondary))
    unplaced = false
    for (dir, tag, axis, csr, msr, csw, msw, l2, l1) in dirs
        if isempty(csr) && isempty(msr)
            push!(md.notes, "No $(dir) strip design is stored; $(dir) bars are not detailed.")
            continue
        end
        strip_w = m(csw) + m(msw)
        strip_w > 0 || continue
        fallback = 0.0
        grouped = _column_line_groups(columns, _efm_xy(struc, columns, l1, axis), axis, l2)
        lines = NamedTuple[]
        for g in grouped
            append!(lines, _lines_with_wall_supports(struc, slab, g))
        end
        for (k, line) in enumerate(lines)
            cols = line.columns
            length(cols) >= 2 || continue
            half = [m(_eq137_face_half(c, axis)) for c in cols]
            proj = line.projections
            ℓn = [(proj[i + 1] - proj[i]) - half[i] - half[i + 1] for i in 1:(length(cols) - 1)]
            if any(<=(0), ℓn)
                push!(md.warnings, "$(dir) line $(k): a clear span is not positive; not detailed")
                continue
            end
            ratio = m(line.width) / strip_w
            cores = [_integrity_core_half(c, (-axis[2], axis[1]))
                     for c in cols if !hasproperty(c, :wall_fixed)]
            core = isempty(cores) || any(isnothing, cores) ? nothing : minimum(cores)
            if core === nothing
                note = "Integrity bars are placed nearest the frame line; columns without " *
                       "an RC section are not checked for passing within the column core."
                note in md.notes || push!(md.notes, note)
            end
            layout(reinf, w) = StripLayout(_scaled_strip(reinf, :ext_neg, ratio),
                                           _scaled_strip(reinf, :pos, ratio),
                                           _scaled_strip(reinf, :int_neg, ratio), w * ratio)
            sub = detail_flat_plate_line(;
                clear_spans = ℓn .* u"m", supports = (2 .* half) .* u"m",
                column_strip = layout(csr, csw), middle_strip = layout(msr, msw),
                h = r.thickness, cover = cover, fc = fc, fy = fy, λ = λ, coating = coating,
                layer = dir === :primary ? :outer : :inner, outer_bar_size = outer_bs,
                drop_panel = drop, stock = stock, direction = dir, prefix = "$(tag)$(k)-",
                core_half_width = core, band = _flat_plate_bar_band(struc, line))
            station = _line_transverse(struc, line)
            if station === nothing
                t0 = fallback
                fallback += m(line.width)
                unplaced = true
            else
                t0 = station[1]
            end
            _shift_line!(sub, axis, proj[1] - half[1], t0)
            _omit_bars_off_slab!(sub, struc, slab)
            _union_solid!(md, sub.solid)
            append!(md.groups, sub.groups)
            for w in sub.warnings
                occursin("placed area", w) && continue
                push!(md.warnings, "$(dir) line $(k): " * w)
            end
            for note in sub.notes
                occursin("in² placed", note) && continue
                note in md.notes || push!(md.notes, note)
            end
            for (key, value) in sub.areas
                md.areas[key] = get(md.areas, key, 0.0) + value
            end
        end
    end
    unplaced && push!(md.notes,
        "Frame lines without a plan station are laid out in order across the slab.")
    note_summed_areas!(md; source = "the strip design")
    push!(md.notes,
        "Each frame line carries the design strip's bars scaled by its tributary width. " *
        "Punching shear reinforcement and transfer bars are not detailed here.")
    return md
end

"""
    _integrity_core_half(col, perp) -> Union{Nothing, Length}

Half the width, measured along `perp`, of the region bounded by the
longitudinal bars of `col`'s section, through which integrity bars must pass
(ACI 318-11 §13.3.8.5; PCA EB712 p. 543). A rectangular section gives the
half-distance between its outer bar centres on the local axis along `perp`
(c1 is local x at `col.θ`), or the smaller of the two when `perp` is skew to
both. A circular section gives the inradius `r cos(π/n)` of its bar polygon.
`nothing` when the column has no RC section.
"""
function _integrity_core_half(col, perp)
    sec = hasproperty(col, :base) ? col.base.section : nothing
    if sec isa RCColumnSection
        xs = [b.x for b in sec.bars]
        ys = [b.y for b in sec.bars]
        hx = (maximum(xs) - minimum(xs)) / 2
        hy = (maximum(ys) - minimum(ys)) / 2
        θ = hasproperty(col, :θ) ? Float64(col.θ) : 0.0
        cx = abs(perp[1] * cos(θ) + perp[2] * sin(θ))
        cy = abs(-perp[1] * sin(θ) + perp[2] * cos(θ))
        cx > 0.995 && return hx
        cy > 0.995 && return hy
        return min(hx, hy)
    elseif sec isa RCCircularSection
        r = maximum(hypot(b.x, b.y) for b in sec.bars)
        return r * cos(π / length(sec.bars))
    end
    return nothing
end

"""
Slab on each side of a column line, in the line's transverse coordinate.

An interior line is left symmetric (`nothing`): the strip is already half a
bay each side. An edge line has a neighbour on one side only. The empty side
is the slab past the columns, from [`_frame_edge_strip_m`](@ref), so the bars
sit on the slab and not outboard of it. A lone line, whose extents are both
zero because its width is the whole panel, stays symmetric.
"""
function _flat_plate_bar_band(struc, line)
    hasproperty(line, :extent_neg) || return nothing
    neg = Float64(line.extent_neg)
    pos = Float64(line.extent_pos)
    (neg <= 1e-9 && pos <= 1e-9) && return nothing
    y_lo = -neg
    y_hi = pos
    ax = line.axis
    perp = (-ax[2], ax[1])
    if y_lo >= -1e-9
        y_lo = -_frame_edge_strip_m(struc, line.columns, (-perp[1], -perp[2]))
    end
    if y_hi <= 1e-9
        y_hi = _frame_edge_strip_m(struc, line.columns, perp)
    end
    return y_hi - y_lo < 1e-4 ? nothing : (y_lo, y_hi)
end

"""A bar polyline, sampled along each segment, lies on the slab."""
function _wire_in_slab(wire, contains)
    isempty(wire) && return false
    for i in 1:(length(wire) - 1)
        a, b = wire[i], wire[i + 1]
        for t in (0.0, 0.5, 1.0)
            x = a[1] + t * (b[1] - a[1])
            y = a[2] + t * (b[2] - a[2])
            contains((x, y)) || return false
        end
    end
    return true
end

"""
Drop bars whose centerline leaves the slab or crosses an opening.

`contains` is the plan test from [`_slab_plan_contains`](@ref), or a
`(x, y) -> Bool` predicate. A group that loses bars keeps the ones that
remain, and the count matches them.
"""
function _omit_bars_off_slab!(md::MemberDetail, contains)
    contains === nothing && return md
    dropped = 0
    for i in eachindex(md.groups)
        g = md.groups[i]
        isempty(g.centerlines) && continue
        wires = [w for w in g.centerlines if _wire_in_slab(w, contains)]
        n_drop = length(g.centerlines) - length(wires)
        n_drop == 0 && continue
        dropped += n_drop
        md.groups[i] = BarGroup(; mark = g.mark, role = g.role, direction = g.direction,
                                bar_size = g.bar_size, count = length(wires), length = g.length,
                                shape = g.shape, path = g.path, x_positions = g.x_positions,
                                z_positions = g.z_positions, laps = g.laps, note = g.note,
                                centerlines = wires)
    end
    filter!(g -> g.count > 0, md.groups)
    dropped > 0 && push!(md.warnings, "$dropped bars lie outside the slab and are not placed")
    return md
end

function _omit_bars_off_slab!(md::MemberDetail, struc, slab)
    contains = try
        _slab_plan_contains(struc, slab; boundary = true)
    catch
        nothing
    end
    return _omit_bars_off_slab!(md, contains)
end

"""Move a frame line from its own axes into the slab: `x` along `axis`, `y` across it."""
function _shift_line!(md::MemberDetail, axis, s0::Float64, t0::Float64)
    perp = (-axis[2], axis[1])
    mappt(p) = begin
        xy = (s0 + p[1]) .* axis .+ (t0 + p[2]) .* perp
        (xy[1], xy[2], p[3])
    end
    for i in eachindex(md.groups)
        g = md.groups[i]
        isempty(g.centerlines) && continue
        md.groups[i] = _with_centerlines(g, [[mappt(p) for p in wire] for wire in g.centerlines])
    end
    md.solid === nothing && return nothing
    box = md.solid
    corners = [mappt((box[a], box[b], box[c])) for a in (1, 2) for b in (3, 4) for c in (5, 6)]
    md.solid = (minimum(p[1] for p in corners), maximum(p[1] for p in corners),
                minimum(p[2] for p in corners), maximum(p[2] for p in corners),
                minimum(p[3] for p in corners), maximum(p[3] for p in corners))
    return nothing
end

function _union_solid!(parent::MemberDetail, child::NTuple{6, Float64})
    if parent.solid === nothing
        parent.solid = child
        return nothing
    end
    a = parent.solid
    parent.solid = (min(a[1], child[1]), max(a[2], child[2]),
                    min(a[3], child[3]), max(a[4], child[4]),
                    min(a[5], child[5]), max(a[6], child[6]))
    return nothing
end

_union_solid!(::MemberDetail, ::Nothing) = nothing

"""The strip with the larger required area. An inadequate strip loses to an adequate one."""
function _larger_topping_strip(a, b)
    a.section_adequate || return b
    b.section_adequate || return a
    return a.As_reqd >= b.As_reqd ? a : b
end

"""
    detail_rib_topping(; side, across, h, cover, along, across_bars, solid_head) -> MemberDetail

Place the rib-to-rib topping mat.

`along` is the unit-strip design for bars that run `side` and are spaced
across `across`. `across_bars` is the other direction, or `nothing`. Both
run the full panel, so a solid head does not interrupt them. Negative bars
are the larger of the two negative strips, full length: there is no cutoff
diagram. ACI 318-11 §13.3.7 is not used.

`along` is the outer layer, at `cover` from each face. `across_bars` sits
inside it, one `along` bar further in, which is the depth
[`one_way_topping_bars`](@ref) uses with `inner_layer = true`.
"""
function detail_rib_topping(; side::Length, across::Length, h::Length, cover::Length,
                            along, across_bars = nothing, solid_head::Bool = false,
                            placement_note::Union{Nothing, AbstractString} = nothing,
                            area_source::AbstractString = "rib-to-rib topping")
    md = MemberDetail(:slab)
    side_m = ustrip(u"m", side)
    across_m = ustrip(u"m", across)
    h_m = ustrip(u"m", h)
    cover_m = ustrip(u"m", cover)
    (side_m > 0 && across_m > 0 && h_m > 0) ||
        throw(ArgumentError("a topping mat needs a positive panel and thickness"))
    cover_m >= 0 || throw(ArgumentError("topping cover is not negative, got $cover"))
    serial = Ref(0)
    # Bar diameter already placed against each face, in metres.
    outer = Dict(:bottom => 0.0, :top => 0.0)
    function lay!(info, run, width, direction, axis)
        info === nothing && return
        bars = info.bars
        bars === nothing && return
        neg = _larger_topping_strip(bars.ext_neg, bars.int_neg)
        run_m = ustrip(u"m", run)
        width_m = ustrip(u"m", width)
        layer_db = Dict(:bottom => 0.0, :top => 0.0)
        for (strip, role, words) in ((bars.pos, :bottom, "bottom"), (neg, :top, "top"))
            strip.section_adequate || (push!(md.warnings,
                "$words topping bars do not fit the slab thickness"); continue)
            strip.spacing > zero(strip.spacing) || continue
            n = max(1, ceil(Int, width_m / ustrip(u"m", strip.spacing)))
            db = ustrip(u"m", bar_diameter(strip.bar_size))
            inset = cover_m + outer[role] + db / 2
            2 * inset <= h_m || (push!(md.warnings,
                "$words topping bars and their cover do not fit the slab thickness"); continue)
            layer_db[role] = db
            z = role === :bottom ? inset : h_m - inset
            a0 = min(db, width_m / 2)
            a1 = max(width_m - db, a0)
            stations = _spread(n, a0, a1)
            path = [(0.0, z), (run_m, z)]
            wires = axis === :x ? _wires_at_y(path, stations) :
                    [[(x, 0.0, z), (x, run_m, z)] for x in stations]
            serial[] += 1
            push!(md.groups, BarGroup(;
                mark = "T$(serial[])", role = role, direction = direction,
                bar_size = strip.bar_size, count = n, length = run_m * u"m",
                shape = :straight, path = path,
                note = "topping $words bars, full panel, $(info.analysis)",
                centerlines = wires))
            ideal = ustrip(u"inch^2", max(strip.As_reqd, strip.As_min) * (width / 1.0u"m"))
            placed = n * ustrip(u"inch^2", bar_area(strip.bar_size))
            record_steel_area!(md, string(direction) * "_" * words, ideal, placed;
                               source = area_source)
        end
        for reason in info.reasons
            push!(md.notes, reason)
        end
        for role in (:bottom, :top)
            outer[role] += layer_db[role]
        end
    end
    lay!(along, side, across, :primary, :x)
    lay!(across_bars, across, side, :secondary, :y)
    push!(md.notes, something(placement_note,
        "Topping bars span rib to rib (ACI 318-11 §8.13.6.2) and run the full panel."))
    push!(md.notes, "Negative topping bars are full length; no cutoff diagram is stored.")
    solid_head && push!(md.notes,
        "ACI 318-11 §13.3.7 was not used. The solid head does not reduce this reinforcement.")
    md.solid = (0.0, side_m, 0.0, across_m, 0.0, h_m)
    push!(md.outline, (0.0, side_m, 0.0, h_m))
    return md
end

"""
    detail_temperature_mat(; side, across, h, cover, along) -> MemberDetail

One mat, both directions at the same depth, in a thickness `h`.

Used for the temperature steel in the concrete above a composite deck.
The two directions cross in one layer, the way a wire sheet does, because
a 2 in topping cannot stack two bar layers at 3/4 in cover. Cover is
ACI 318-11 §7.7.1(c) (corpus: aci-318-11, page 97): 3/4 in for a No. 11
bar or smaller in a slab not exposed to weather or in contact with the
ground. The caller passes that cover.
"""
function detail_temperature_mat(; side::Length, across::Length, h::Length, cover::Length, along)
    md = MemberDetail(:slab)
    side_m = ustrip(u"m", side)
    across_m = ustrip(u"m", across)
    h_m = ustrip(u"m", h)
    cover_m = ustrip(u"m", cover)
    (side_m > 0 && across_m > 0 && h_m > 0) ||
        throw(ArgumentError("a temperature mat needs a positive panel and thickness"))
    strip = along.bars.pos
    for reason in along.reasons
        push!(md.notes, reason)
    end
    if !(strip.section_adequate) || strip.spacing <= zero(strip.spacing) || strip.n_bars <= 0
        push!(md.warnings, "temperature bars were not placed")
        return md
    end
    db = ustrip(u"m", bar_diameter(strip.bar_size))
    # One layer. Bottom and top cover both have to clear the bar.
    if h_m + 1e-9 < 2 * cover_m + db
        push!(md.warnings, "temperature bars and their cover do not fit the concrete above the deck")
        return md
    end
    z = cover_m + db / 2
    function lay!(run_m, width_m, direction, axis, mark)
        n = max(1, ceil(Int, width_m / ustrip(u"m", strip.spacing)))
        a0 = min(db, width_m / 2)
        a1 = max(width_m - db, a0)
        stations = _spread(n, a0, a1)
        path = [(0.0, z), (run_m, z)]
        wires = axis === :x ? _wires_at_y(path, stations) :
                [[(x, 0.0, z), (x, run_m, z)] for x in stations]
        push!(md.groups, BarGroup(;
            mark = mark, role = :bottom, direction = direction,
            bar_size = strip.bar_size, count = n, length = run_m * u"m",
            shape = :straight, path = path,
            note = "temperature bars, one layer, $(along.analysis)",
            centerlines = wires))
        ideal = n == 0 ? 0.0 : ustrip(u"inch^2", strip.As_reqd * (width_m * u"m" / 1.0u"m"))
        placed = n * ustrip(u"inch^2", bar_area(strip.bar_size))
        record_steel_area!(md, string(direction) * "_bottom", ideal, placed;
                           source = "SDI C-2017 §2.4.B.15.a.1")
    end
    lay!(side_m, across_m, :primary, :x, "TS1")
    lay!(across_m, side_m, :secondary, :y, "TS2")
    push!(md.notes, "The sheet is the positive flexural reinforcement. These bars are temperature steel only.")
    push!(md.notes, "ACI 318-11 §7.7.1(c): 3/4 in cover, No. 11 and smaller, slab not exposed to weather.")
    md.solid = (0.0, side_m, 0.0, across_m, 0.0, h_m)
    push!(md.outline, (0.0, side_m, 0.0, h_m))
    return md
end
