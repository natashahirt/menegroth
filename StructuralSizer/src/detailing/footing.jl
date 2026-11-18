# ==============================================================================
# Spread footings — bottom mat and column dowels (ACI 318-19 Ch. 13, 16)
# ==============================================================================
#
# Elevation paths are drawn along the long side: x from one edge, z up from
# the bottom of the footing.
# ==============================================================================

"""
    detail_spread_footing(; B, L, D, bar_size, n_bars, column, column_bars, kwargs...)
        -> MemberDetail

Bottom mat of a two-way isolated footing and the dowels into its column.

# Keywords
- `B`, `L`: plan sides with `L ≥ B`. `D`: thickness.
- `bar_size`, `n_bars`: the sizing result's bars, `n_bars` in each direction.
- `column`: `(c_long, c_short)` column dimensions along `L` and `B`.
- `column_bars`: `(bar_size, n_bars)` of the column above, or `nothing`.
- `column_Ag`: gross area of the column, for §16.3.4.1.
- `column_lap`: lap of the dowels with the column bars.
- `cover`: clear cover, 3 in. by default for concrete cast against earth.
- `fc`, `fy`, `λ`, `coating`: materials.

# Bars
- Long bars span `L` and are spaced uniformly over `B` (§13.3.3.3(a)).
- Short bars span `B`. On a square footing they are uniform (§13.3.3.2). On
  a rectangular footing `γs = 2/(β + 1)` of them sit in a band of width `B`
  centered on the column and the rest outside it (§13.3.3.3(b),
  Eq. 13.3.3.3).
- A bar is straight when ℓd fits between the column face and the edge less
  cover; otherwise both ends get a 90-degree hook and ℓdh is checked.
- Dowels match the column bars, sit on the mat with a 90-degree hook, and
  lap with the column bars above. Their area is checked against 0.005Ag
  (§16.3.4.1) and their straight embedment against compression ℓdc (§25.4.9).
"""
function detail_spread_footing(; B::Length, L::Length, D::Length, bar_size::Int,
                               n_bars::Int, column::Tuple, column_bars = nothing,
                               column_Ag = nothing, column_lap = nothing,
                               cover::Length = 3.0u"inch", fc, fy, λ::Real = 1.0,
                               coating::Symbol = :uncoated)
    md = MemberDetail(:footing)
    m(x) = ustrip(u"m", x)
    lam = _detailing_λ(λ)
    Bm, Lm, Dm, cov = m(B), m(L), m(D), m(cover)
    Lm >= Bm - 1e-9 || throw(ArgumentError("L must be the long side (L = $L, B = $B)"))
    n_bars > 0 || return md
    db = m(bar_diameter(bar_size))
    cl, cs = m(column[1]), m(column[2])

    spacing = n_bars > 1 ? (Bm - 2cov - db) / (n_bars - 1) : Bm
    favorable = spacing - db >= 2db && cov >= db
    epoxy_close = cov < 3db || spacing - db < 6db
    ld = m(straight_development_length(bar_size, fc, fy, lam; coating = coating,
                                       epoxy_close = epoxy_close, favorable_cover = favorable))
    ldh = m(hooked_bar_development_length(bar_size, fc, fy, lam; coating = coating))
    hook = m(hook_centerline_length(bar_size; angle = 90))
    tail = m(standard_hook(bar_size; angle = 90).extension)

    function bars!(mark, dir, span, c, count, z; note = "")
        count > 0 || return
        avail = (span - c) / 2 - cov
        hooked = ld > avail + 1e-9
        hooked && ldh > avail + 1e-9 && push!(md.warnings,
            "$(dir) bars: neither ℓd = $(round(ld / 0.0254; digits = 1)) in. nor " *
            "ℓdh = $(round(ldh / 0.0254; digits = 1)) in. fits the " *
            "$(round(avail / 0.0254; digits = 1)) in. from the column face to the edge (§25.4)")
        straight = span - 2cov
        room = Dm - cov - z
        path = NTuple{2, Float64}[]
        hooked && push!(path, first(_hook_tail(cov, z, tail, room, +1, +1)))
        push!(path, (cov, z), (span - cov, z))
        hooked && push!(path, first(_hook_tail(span - cov, z, tail, room, +1, -1)))
        push!(md.groups, BarGroup(; mark = mark, role = :bottom, direction = dir,
                                  bar_size = bar_size, count = count,
                                  length = (straight + 2hooked * hook) * u"m",
                                  shape = hooked ? :hook_both : :straight, path = path,
                                  note = note))
    end

    z_long = cov + db / 2
    z_short = cov + db + db / 2
    bars!("F1", :long, Lm, cl, n_bars, z_long; note = "uniform across B (§13.3.3.3(a))")
    β = Lm / Bm
    if β <= 1 + 1e-6
        bars!("F2", :short, Bm, cs, n_bars, z_short; note = "uniform (§13.3.3.2)")
    else
        γs = 2 / (β + 1)
        n_band = min(n_bars, ceil(Int, γs * n_bars - 1e-9))
        bars!("F2", :short, Bm, cs, n_band, z_short;
              note = "central band of width B, γs = $(round(γs; digits = 3)) (Eq. 13.3.3.3)")
        bars!("F3", :short, Bm, cs, n_bars - n_band, z_short; note = "outside the central band")
    end

    if column_bars !== nothing
        bsd, nd = Int(column_bars[1]), Int(column_bars[2])
        ddb = m(bar_diameter(bsd))
        if column_Ag !== nothing
            As = nd * ustrip(u"m^2", bar_area(bsd))
            As >= 0.005 * ustrip(u"m^2", column_Ag) - 1e-12 || push!(md.warnings,
                "dowels: As = $(round(As * 1e6; digits = 0)) mm² is below 0.005Ag (§16.3.4.1)")
        end
        seat = cov + 2db + ddb / 2
        embed = Dm - seat
        ldc = m(compression_development_length(bsd, fc, fy, lam))
        embed + 1e-9 >= ldc || push!(md.warnings,
            "dowels: straight embedment $(round(embed / 0.0254; digits = 1)) in. is less than " *
            "ℓdc = $(round(ldc / 0.0254; digits = 1)) in. (§25.4.9); hooks do not count in compression")
        lap = column_lap === nothing ? 0.0 : m(column_lap)
        dhook = m(hook_centerline_length(bsd; angle = 90))
        dtail = m(standard_hook(bsd; angle = 90).extension)
        x = Lm / 2 - cl / 2 + cov
        push!(md.groups, BarGroup(; mark = "F4", role = :dowel, direction = :along,
                                  bar_size = bsd, count = nd,
                                  length = (embed + lap + dhook) * u"m", shape = :hook_start,
                                  path = [(x + dtail, seat), (x, seat), (x, Dm + lap)],
                                  note = "lap $(round(lap / 0.0254; digits = 1)) in. with the column bars"))
    end

    # Footing, then the column stub above it as far as the dowels run.
    push!(md.outline, (0.0, Lm, 0.0, Dm))
    z_top = maximum((p[2] for g in md.groups for p in g.path); init = Dm)
    push!(md.outline, (Lm / 2 - cl / 2, Lm / 2 + cl / 2, Dm, max(z_top + cov, 1.5Dm)))
    _report_footing_areas!(md, bar_size, n_bars, column_bars, column_Ag)
    _locate_footing!(md, Bm, Lm, Dm, cov, db, cl, cs)
    return md
end

"""
Centerlines in the footing frame: `x` along the long side from one edge, `y`
along the short side, `z` up from the bottom. Long bars are uniform across the
short side. On a rectangle the short bars pack into the central band of width
`B` and the rest sit outside it, the split already chosen above.
"""
function _locate_footing!(md::MemberDetail, B, L, D, cov, db, cl, cs)
    inset = cov + db / 2
    long = findfirst(g -> g.direction === :long && g.role === :bottom, md.groups)
    if long !== nothing
        g = md.groups[long]
        ys = _spread(g.count, inset, B - inset)
        md.groups[long] = _with_centerlines(g, _wires_at_y(g.path, ys))
    end
    shorts = findall(g -> g.direction === :short && g.role === :bottom, md.groups)
    if length(shorts) == 1
        g = md.groups[shorts[1]]
        banded = occursin("central band", g.note)
        x0 = banded ? max((L - B) / 2, inset) : inset
        x1 = banded ? min((L + B) / 2, L - inset) : L - inset
        md.groups[shorts[1]] = _with_centerlines(g, _wires_swap(g.path, _spread(g.count, x0, x1)))
    elseif length(shorts) == 2
        band = findfirst(i -> occursin("central band", md.groups[i].note), shorts)
        outside = findfirst(i -> occursin("outside", md.groups[i].note), shorts)
        (band === nothing || outside === nothing) && throw(ArgumentError(
            "a rectangular footing needs a central band and the bars outside it"))
        x0, x1 = (L - B) / 2, (L + B) / 2
        gb, go = md.groups[shorts[band]], md.groups[shorts[outside]]
        band_x = _spread(gb.count, max(x0, inset), min(x1, L - inset))
        half = cld(go.count, 2)
        left = _spread(half, inset, x0)
        right = _spread(go.count - half, x1, L - inset)
        md.groups[shorts[band]] = _with_centerlines(gb, _wires_swap(gb.path, band_x))
        md.groups[shorts[outside]] = _with_centerlines(go, _wires_swap(go.path, [left; right]))
    end
    dowel = findfirst(g -> g.role === :dowel, md.groups)
    if dowel !== nothing
        g = md.groups[dowel]
        y0, y1 = (B - cs) / 2 + cov, (B + cs) / 2 - cov
        md.groups[dowel] = _with_centerlines(g, _wires_at_y(g.path, _spread(g.count, y0, y1)))
    end
    md.solid = (0.0, L, 0.0, B, 0.0, D)
    return nothing
end

"""
    detail_mat(; B, L, D, cover, bar_size_x, bar_size_y, As_x_bot, As_x_top, As_y_bot, As_y_top)
        -> MemberDetail

Four flexural layers of a mat, in the counts [`mat_flexure_bar_counts`](@ref)
uses for the steel volume. `x` runs along `L`, `y` along `B`, and `z` up
from the soffit. x-bars run along `B` and y-bars along `L`. The x layer is
the outer bottom layer and the inner top layer, so the outer bar is the one
`d` is measured to: the distance from the extreme compression fiber to the
centroid of the longitudinal tension reinforcement (ACI 318-11 §2.2,
corpus: aci-318-11, page 37). Wall dowels are not drawn.
"""
function detail_mat(; B::Length, L::Length, D::Length, cover::Length,
                    bar_size_x::Int, bar_size_y::Int,
                    As_x_bot, As_x_top, As_y_bot, As_y_top)
    md = MemberDetail(:footing)
    Bm, Lm, Dm = ustrip(u"m", B), ustrip(u"m", L), ustrip(u"m", D)
    cov = ustrip(u"m", cover)
    (Bm > 0 && Lm > 0 && Dm > 0) || return md
    opts = (bar_size_x = bar_size_x, bar_size_y = bar_size_y, cover = cover)
    bars = mat_flexure_bar_counts(B, L, D, As_x_bot, As_x_top, As_y_bot, As_y_top, opts)
    dbx = ustrip(u"m", bar_diameter(bar_size_x))
    dby = ustrip(u"m", bar_diameter(bar_size_y))
    zxb = cov + dbx / 2
    zyb = zxb + dbx / 2 + dby / 2
    zyt = Dm - cov - dby / 2
    zxt = zyt - dby / 2 - dbx / 2
    function layer!(mark, bar_role, across, n, along, stations, z, size, note)
        n > 0 || return
        along > 2cov || return
        0 < z < Dm || return
        path = [(cov, z), (along - cov, z)]
        wires = across === :x ? _wires_swap(path, stations) : _wires_at_y(path, stations)
        length(wires) == n || return
        push!(md.groups, BarGroup(; mark = mark, role = bar_role,
                                  direction = across === :x ? :short : :long,
                                  bar_size = size, count = n, length = (along - 2cov) * u"m",
                                  path = path, note = note, centerlines = wires))
    end
    # x-bars run along B and are stationed across L. y-bars run along L.
    layer!("MXB", :bottom, :x, bars.n_xb, Bm, _spread(bars.n_xb, cov, Lm - cov), zxb,
           bar_size_x, "bottom bars along the width")
    layer!("MYB", :bottom, :y, bars.n_yb, Lm, _spread(bars.n_yb, cov, Bm - cov), zyb,
           bar_size_y, "bottom bars along the length")
    layer!("MYT", :top, :y, bars.n_yt, Lm, _spread(bars.n_yt, cov, Bm - cov), zyt,
           bar_size_y, "top bars along the length")
    layer!("MXT", :top, :x, bars.n_xt, Bm, _spread(bars.n_xt, cov, Lm - cov), zxt,
           bar_size_x, "top bars along the width")
    md.outline = [(0.0, Lm, 0.0, Dm)]
    md.solid = (0.0, Lm, 0.0, Bm, 0.0, Dm)
    push!(md.notes, "Mat bars use the same count as the steel volume. " *
                    "Wall dowels are not drawn.")
    return md
end

"""A bar whose elevation runs along `y`, stationed at each `x`."""
function _wires_swap(path, xs::Vector{Float64})
    return [[(x, p[1], p[2]) for p in path] for x in xs]
end

"""
Long and short mat areas, plus dowels when the column bars are known.

Each mat's ideal area is the bar count the sizing passed in. A band split
still totals that count. Dowel ideal area is the larger of the column bar
area and 0.005Ag (§16.3.4.1) when the column area is known.
"""
function _report_footing_areas!(md, bar_size, n_bars, column_bars, column_Ag)
    ab = ustrip(u"inch^2", bar_area(bar_size))
    record_steel_area!(md, "long", n_bars * ab, _placed_area_in2(md, :bottom; direction = :long);
                       source = "the footing bars")
    record_steel_area!(md, "short", n_bars * ab, _placed_area_in2(md, :bottom; direction = :short);
                       source = "the footing bars")
    column_bars === nothing && return nothing
    placed = _placed_area_in2(md, :dowel)
    code_min = column_Ag === nothing ? 0.0 : 0.005 * ustrip(u"inch^2", column_Ag)
    source = column_Ag === nothing ? "the column bars" :
             "the larger of the column bars and 0.005Ag"
    record_steel_area!(md, "dowel", max(placed, code_min), placed; source = source)
    return nothing
end
