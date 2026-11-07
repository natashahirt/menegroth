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

# Bars
- Column-strip top, every support: at least half the bars (rounded up)
  extend `max(0.30ℓn, 5d, ℓd)` past each face (0.33ℓn with drop panels). The
  rest extend `max(0.20ℓn, ℓd)`. At an exterior support the bars run to the
  slab edge less cover and end in a 90-degree standard hook (§8.7.4.1.1(b)).
- Column-strip bottom: continuous between exterior supports, 6 in. into each
  exterior support. Two bars pass through every column and are hooked at the
  exterior supports (§8.7.4.2.2). Runs above `stock` are lapped Class B
  (§8.7.4.2.1, Table 25.5.2.1).
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
                                direction::Symbol = :primary, prefix::AbstractString = "")
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
    function add!(role, bs, count, x0, x1, z; hook_start = false, hook_end = false,
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
        serial[] += 1
        push!(md.groups, BarGroup(; mark = "$(prefix)$(serial[])", role = role,
                                  direction = direction, bar_size = bs,
                                  count = count * n_lines, length = len * u"m",
                                  shape = shape, path = path, laps = laps, note = note))
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
            if j == 1
                add!(:top, bs, n_long, cov, xR[1] + e_long, zt; hook_start = true,
                     note = "column strip, exterior support, long")
                add!(:top, bs, n_rem, cov, xR[1] + e_rem, zt; hook_start = true,
                     note = "column strip, exterior support")
            else
                add!(:top, bs, n_long, xL[j] - e_long, total - cov, zt; hook_end = true,
                     note = "column strip, exterior support, long")
                add!(:top, bs, n_rem, xL[j] - e_rem, total - cov, zt; hook_end = true,
                     note = "column strip, exterior support")
            end
        else
            add!(:top, bs, n_long, xL[j] - e_long, xR[j] + e_long, zt;
                 note = "column strip, interior support, long")
            add!(:top, bs, n_rem, xL[j] - e_rem, xR[j] + e_rem, zt;
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
        run_int = (total - cov) - cov
        laps_int, _ = stock_splices(run_int * u"m", stock, lap * u"m")
        add!(:integrity, bs, n_int, cov, total - cov, zb; hook_start = true, hook_end = true,
             hook_dir = +1, laps = laps_int, lap_len = lap,
             note = "integrity bars through the column core (§8.7.4.2.2)")
        x0, x1 = xR[1] - embed(1), xL[n + 1] + embed(n + 1)
        laps_b, _ = stock_splices((x1 - x0) * u"m", stock, lap * u"m")
        add!(:bottom, bs, sb.n_bars - n_int, x0, x1, zb; laps = laps_b, lap_len = lap,
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
        if exterior
            check_edge_hook!(bs, j, "middle-strip top bars")
            j == 1 ? add!(:top, bs, sb.n_bars, cov, xR[1] + e, zt; hook_start = true,
                          note = "middle strip, exterior support") :
                     add!(:top, bs, sb.n_bars, xL[j] - e, total - cov, zt; hook_end = true,
                          note = "middle strip, exterior support")
        else
            add!(:top, bs, sb.n_bars, xL[j] - e, xR[j] + e, zt;
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
        six = m(_SIX_INCH)
        for i in 1:n
            x0 = i == 1 ? xR[1] - embed(1) : xc[i] - six
            x1 = i == n ? xL[n + 1] + embed(n + 1) : xc[i + 1] + six
            add!(:bottom, bs, n_full, x0, x1, zb; note = "middle strip, into supports")
            add!(:bottom, bs, n_cut, xc[i] + 0.15 * ℓn[i], xc[i + 1] - 0.15 * ℓn[i], zb;
                 note = "middle strip, 0.15ℓn cutback")
        end
    end

    push!(md.notes,
        "Middle-strip bottom bars into an interior support run 6 in. past its centerline; " *
        "the 0.15ℓn cutback is measured from the support centerline (reading of Fig. 8.7.4.1.3).")
    _record_strip_areas!(md, direction, :column, column_strip, n_lines)
    _record_strip_areas!(md, direction, :middle, middle_strip, n_lines)
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
    for (dir, tag, axis, csr, msr, csw, msw, l2, l1) in dirs
        if isempty(csr) && isempty(msr)
            push!(md.notes, "No $(dir) strip design is stored; $(dir) bars are not detailed.")
            continue
        end
        strip_w = m(csw) + m(msw)
        strip_w > 0 || continue
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
            layout(reinf, w) = StripLayout(_scaled_strip(reinf, :ext_neg, ratio),
                                           _scaled_strip(reinf, :pos, ratio),
                                           _scaled_strip(reinf, :int_neg, ratio), w * ratio)
            sub = detail_flat_plate_line(;
                clear_spans = ℓn .* u"m", supports = (2 .* half) .* u"m",
                column_strip = layout(csr, csw), middle_strip = layout(msr, msw),
                h = r.thickness, cover = cover, fc = fc, fy = fy, λ = λ, coating = coating,
                layer = dir === :primary ? :outer : :inner, outer_bar_size = outer_bs,
                drop_panel = drop, stock = stock, direction = dir, prefix = "$(tag)$(k)-")
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
    note_summed_areas!(md; source = "the strip design")
    push!(md.notes,
        "Each frame line carries the design strip's bars scaled by its tributary width. " *
        "Punching shear reinforcement and transfer bars are not detailed here.")
    return md
end
