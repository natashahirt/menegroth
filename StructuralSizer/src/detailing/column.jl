# ==============================================================================
# Reinforced concrete columns — bars, splices, ties, spirals (ACI 318-19 Ch. 10, 25)
# ==============================================================================
#
# One story of one column, measured from the top of the floor below (x = 0)
# to the top of the floor above (x = height). Elevation paths use x along the
# column axis and z across the section.
# ==============================================================================

"""Bar size of an RC column section, from the area of its first bar."""
_column_bar_size(sec) = infer_bar_size(first(sec.bars).As)

"""
Tie spacing, ACI 318-19 §25.7.2.1(b) (corpus: aci-318-19, printed p. 499):
the least of 16 longitudinal bar diameters, 48 tie diameters, and the least
dimension of the member.
"""
function column_tie_spacing(long_bar::Int, tie_bar::Int, least_dim::Length)
    s = min(16 * bar_diameter(long_bar), 48 * bar_diameter(tie_bar), least_dim)
    return uconvert(u"m", s)
end

"""
    column_lap_length(sec, fc, fy; λ=1, coating=:uncoated) -> Length

Lap of the longitudinal bars of an RC column: the longer of the compression
lap (§25.5.5.1) and the Class B tension lap (Table 25.5.2.1). The bar forces
are not kept, so the tension lap is not ruled out. Ties are at least the code
minimum and §25.2.3 keeps clear spacing at least 1.5d_b, so the first row of
Table 25.4.2.3 applies when the clear cover to the bar is at least d_b.
"""
function column_lap_length(sec::Union{RCColumnSection, RCCircularSection}, fc, fy;
                           λ::Real = 1.0, coating::Symbol = :uncoated)
    bs = _column_bar_size(sec)
    bs <= 11 || throw(ArgumentError("No. $(bs) bars cannot be lap spliced (§25.5.1.1)"))
    lam = _detailing_λ(λ)
    tie_bar = sec isa RCCircularSection ? (bs >= 11 ? 4 : 3) : sec.tie_bar_size
    fav = sec.cover + bar_diameter(tie_bar) >= bar_diameter(bs)
    return uconvert(u"m", max(compression_lap_length(bs, fc, fy; λ = lam, coating = coating),
                              tension_lap_length(bs, fc, fy, lam; as_ratio = 1.0,
                                                 percent_spliced = 100.0, coating = coating,
                                                 epoxy_close = true, favorable_cover = fav)))
end

"""
Bars on one face that need a tie corner or crosstie, ACI 318-19 §25.7.2.3
(corpus: aci-318-19, printed p. 499): every corner bar and every alternate bar,
and any other bar farther than 6 in. clear along the tie from a supported bar.
`positions` are bar centers along the face, corners first and last, meters.
Returns the number of supported bars between the two corners.
"""
function _face_crossties(positions::Vector{Float64}, db::Float64)
    n = length(positions)
    n <= 2 && return 0
    supported = falses(n)
    supported[1] = supported[n] = true
    for i in 3:2:(n - 1)
        supported[i] = true
    end
    six = ustrip(u"m", 6.0u"inch")
    for i in 2:(n - 1)
        supported[i] && continue
        gap = minimum(abs(positions[i] - positions[k]) for k in 1:n if supported[k]) - db
        gap > six + 1e-9 && (supported[i] = true)
    end
    return count(supported) - 2
end

"""
    detail_column(sec; height, slab_above, fc, fy, kwargs...) -> MemberDetail

Bars of one story of a rectangular or circular RC column.

# Keywords
- `height`: floor-to-floor height, top of slab below to top of slab above.
- `slab_above`: thickness of the slab (or the deepest beam) at the top.
- `slab_cover`: clear cover of the slab bars at the top (seats the top tie).
- `continues`: `true` when a column of the story above splices onto these
  bars; `false` at the roof, where the bars end in a 90-degree hook.
- `fc`, `fy`, `fyt`, `λ`, `coating`: materials.

# Bars
- Longitudinal: from the floor to the floor above plus a lap when the column
  continues. The lap is the longer of the compression lap (§25.5.5.1) and the
  Class B tension lap (Table 25.5.2.1). §10.7.5.2 allows the compression lap
  only where the factored bar force is compression; the bar stresses are not
  kept, so the longer lap is used.
- Ties (§25.7.2.1, §10.7.6.2): closed ties with 135-degree hooks at the
  §25.7.2.1(b) spacing, the bottom tie at half a spacing above the floor and
  the top tie half a spacing below the lowest slab bars above. Crossties
  follow §25.7.2.3.
- Spirals (§25.7.3): pitch from Eq. (25.7.3.3) with clear spacing from 1 in.
  to 3 in., No. 3 or larger (§25.7.3.2), 1.5 extra turns at each end
  (Fig. R25.7.3.4). The spiral runs from the floor to the lowest slab bars.
"""
function detail_column(sec::Union{RCColumnSection, RCCircularSection}; height::Length,
                       slab_above::Length, slab_cover::Length = 0.75u"inch",
                       continues::Bool = true, fc, fy, fyt = fy, λ::Real = 1.0,
                       coating::Symbol = :uncoated, stock::Length = 60.0u"ft")
    md = MemberDetail(:column)
    m(x) = ustrip(u"m", x)
    lam = _detailing_λ(λ)
    isempty(sec.bars) && return md
    H, hs, cs = m(height), m(slab_above), m(slab_cover)
    H > hs || throw(ArgumentError("column height $(height) is not above the slab $(slab_above)"))
    cov = m(sec.cover)
    bs = _column_bar_size(sec)
    db = m(bar_diameter(bs))
    n = length(sec.bars)
    circular = sec isa RCCircularSection
    width = circular ? m(sec.D) : m(sec.b)
    least = circular ? m(sec.D) : min(m(sec.b), m(sec.h))
    tie_bar = circular ? (bs >= 11 ? 4 : 3) : sec.tie_bar_size   # §25.7.2.2
    dt = m(bar_diameter(tie_bar))

    # ── Longitudinal bars ──────────────────────────────────────────────────
    z_bar = width / 2 - cov - dt - db / 2
    if continues
        if bs > 11
            push!(md.warnings, "No. $(bs) column bars cannot be lap spliced (§25.5.1.1); " *
                               "a mechanical splice is needed and is not detailed")
            lap = 0.0
        else
            lap = m(column_lap_length(sec, fc, fy; λ = λ, coating = coating))
        end
        len = H + lap
        path = [(0.0, z_bar), (H + lap, z_bar)]
        push!(md.groups, BarGroup(; mark = "C1", role = :longitudinal, direction = :along,
                                  bar_size = bs, count = n, length = len * u"m", path = path,
                                  laps = 1, note = "lap $(round(lap / 0.0254; digits = 1)) in. above the floor"))
    else
        top = H - cs - db / 2
        hook = m(hook_centerline_length(bs; angle = 90))
        tail = m(standard_hook(bs; angle = 90).extension)
        push!(md.groups, BarGroup(; mark = "C1", role = :longitudinal, direction = :along,
                                  bar_size = bs, count = n, length = (top + hook) * u"m",
                                  shape = :hook_end,
                                  path = [(0.0, z_bar), (top, z_bar), (top, z_bar - tail)],
                                  note = "90-degree hook into the roof slab"))
        ldc = m(compression_development_length(bs, fc, fy, lam))
        ldc <= hs - cs + 1e-9 || push!(md.warnings,
            "roof: column bars need ℓdc = $(round(ldc / 0.0254; digits = 1)) in. " *
            "and the slab gives $(round((hs - cs) / 0.0254; digits = 1)) in. (§25.4.9)")
    end
    stock_m = m(stock)
    md.groups[end].length > stock && push!(md.warnings,
        "column bars of $(round(m(md.groups[end].length); digits = 2)) m exceed the " *
        "$(round(stock_m; digits = 2)) m stock length")

    # ── Transverse bars ────────────────────────────────────────────────────
    top_limit = H - hs + cs            # lowest slab bars above
    if circular && sec.tie_type == :spiral
        _add_spiral!(md, sec, H, top_limit, fc, fyt; cover = cov, db = db)
    else
        s = m(column_tie_spacing(bs, tie_bar, least * u"m"))
        xs = _spaced_positions(s / 2, top_limit - s / 2, s)
        if circular
            dcl = width - 2cov - dt
            len = π * dcl + 2 * m(hook_centerline_length(tie_bar; angle = 135, role = :stirrup))
            shape = :closed_tie
        else
            w_cl = m(sec.b) - 2cov - dt
            h_cl = m(sec.h) - 2cov - dt
            len = _closed_loop_length(w_cl, h_cl, tie_bar; hook_angle = 135)
            shape = :closed_tie
        end
        push!(md.groups, BarGroup(; mark = "C2", role = :tie, direction = :transverse,
                                  bar_size = tie_bar, count = length(xs), length = len * u"m",
                                  shape = shape, path = [(0.0, -width / 2 + cov + dt / 2),
                                                         (0.0, width / 2 - cov - dt / 2)],
                                  x_positions = xs,
                                  note = "at $(round(s / 0.0254; digits = 1)) in. (§25.7.2.1)"))
        if !circular
            _add_crossties!(md, sec, xs, tie_bar, cov, dt, db)
        end
    end

    # Column to the underside of the slab, the slab (drawn one column width past
    # each face), and the column above as far as the lapped bars run.
    push!(md.outline, (0.0, H - hs, -width / 2, width / 2),
          (H - hs, H, -1.5width, 1.5width))
    ext = _path_extent(md)
    continues && ext !== nothing && ext[2] > H &&
        push!(md.outline, (H, ext[2] + cov, -width / 2, width / 2))
    # Ties and spirals are a spacing, not one area. The longitudinal pair is
    # the section's As against the bars placed.
    record_steel_area!(md, "longitudinal", ustrip(u"inch^2", sec.As_total),
                       _placed_area_in2(md, :longitudinal); source = "the section As")
    return md
end

function _add_crossties!(md, sec::RCColumnSection, xs, tie_bar, cov, dt, db)
    m(x) = ustrip(u"m", x)
    bx = [m(b.x) for b in sec.bars]
    by = [m(b.y) for b in sec.bars]
    tol = 1e-4
    xmin, xmax, ymin, ymax = minimum(bx), maximum(bx), minimum(by), maximum(by)
    face(sel, coord) = sort([coord[i] for i in eachindex(bx) if sel(i)])
    left = face(i -> abs(bx[i] - xmin) < tol, by)
    right = face(i -> abs(bx[i] - xmax) < tol, by)
    bottom = face(i -> abs(by[i] - ymin) < tol, bx)
    top = face(i -> abs(by[i] - ymax) < tol, bx)
    hook = m(hook_centerline_length(tie_bar; angle = 135, role = :stirrup))
    # Crossties across the depth hold bars on the bottom and top faces.
    n_v = max(_face_crossties(bottom, db), _face_crossties(top, db))
    n_h = max(_face_crossties(left, db), _face_crossties(right, db))
    for (k, (nct, across)) in enumerate(((n_v, m(sec.h) - 2cov - dt), (n_h, m(sec.b) - 2cov - dt)))
        nct > 0 || continue
        push!(md.groups, BarGroup(; mark = "C$(2 + k)", role = :crosstie, direction = :transverse,
                                  bar_size = tie_bar, count = nct * length(xs),
                                  length = (across + 2hook) * u"m", shape = :crosstie,
                                  x_positions = xs,
                                  note = "$(nct) per tie set, 135-degree hooks both ends (§25.7.2.3)"))
    end
end

function _add_spiral!(md, sec::RCCircularSection, H, top_limit, fc, fyt; cover, db)
    m(x) = ustrip(u"m", x)
    D = m(sec.D)
    Dc = D - 2cover                       # out-to-out of the spiral
    Ag = π * D^2 / 4
    Ach = π * Dc^2 / 4
    ρs = 0.45 * (Ag / Ach - 1) * ustrip(u"psi", fc) / ustrip(u"psi", fyt)   # Eq. (25.7.3.3)
    clear_min, clear_max = m(1.0u"inch"), m(3.0u"inch")
    chosen = nothing
    for bsp in 3:5
        dsp = m(bar_diameter(bsp))
        Asp = ustrip(u"m^2", bar_area(bsp))
        s_req = 4 * Asp / (Dc * ρs)
        s = min(s_req, clear_max + dsp)
        if s - dsp >= clear_min - 1e-9
            chosen = (bsp, dsp, s)
            break
        end
    end
    if chosen === nothing
        push!(md.warnings, "spiral: no No. 3 to No. 5 spiral meets ρs with at least 1 in. clear (§25.7.3)")
        return
    end
    bsp, dsp, s = chosen
    Dsp = Dc - dsp
    turns = top_limit / s + 3.0           # 1.5 extra turns at each end
    per_turn = sqrt((π * Dsp)^2 + s^2)
    n_pts = 16
    path = [(i / n_pts * top_limit, Dsp / 2 * cos(2π * i / n_pts * top_limit / s)) for i in 0:n_pts]
    push!(md.groups, BarGroup(; mark = "C2", role = :spiral, direction = :transverse,
                              bar_size = bsp, count = 1, length = turns * per_turn * u"m",
                              shape = :spiral, path = path,
                              x_positions = collect(0.0:s:top_limit),
                              note = "pitch $(round(s / 0.0254; digits = 2)) in., ρs ≥ $(round(ρs; digits = 4)) " *
                                     "(Eq. 25.7.3.3), 1.5 extra turns each end"))
end
