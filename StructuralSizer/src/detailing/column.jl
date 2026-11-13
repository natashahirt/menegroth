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
    # Same count the shear design uses, so the drawn crossties are the legs
    # that Av was computed from. Positions here are metres.
    return _bars_needing_crosstie(positions, db, ustrip(u"m", 6.0u"inch"))
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
- `tie_spacing`: shear spacing from [`design_column_shear`](@ref). The ties
  are placed at the lesser of this and §25.7.2.1. A larger value does not
  relax the code spacing.

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
                       coating::Symbol = :uncoated, stock::Length = 60.0u"ft",
                       tie_spacing::Union{Nothing, Length} = nothing)
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
        _add_spiral!(md, sec, H, top_limit, fc, fyt; cover = cov, db = db,
                     shear_spacing = tie_spacing)
    else
        s_code = m(column_tie_spacing(bs, tie_bar, least * u"m"))
        s = s_code
        # Shear may need the ties closer. It cannot space them farther than
        # §25.7.2.1.
        if tie_spacing !== nothing
            s_shear = m(tie_spacing)
            s_shear > 1e-9 && (s = min(s, s_shear))
        end
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
                                  note = s < s_code - 1e-6 ?
                                      "at $(round(s / 0.0254; digits = 1)) in. (§25.7.2.1, §10.7.6.5.2)" :
                                      "at $(round(s / 0.0254; digits = 1)) in. (§25.7.2.1)"))
        if !circular
            _add_crossties!(md, sec, xs, tie_bar, cov, dt)
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

function _add_crossties!(md, sec::RCColumnSection, xs, tie_bar, cov, dt)
    m(x) = ustrip(u"m", x)
    hook = m(hook_centerline_length(tie_bar; angle = 135, role = :stirrup))
    # The same leg count design_column_shear used for Av.
    legs = column_tie_legs(sec)
    n_v = legs.y - 2
    n_h = legs.x - 2
    for (k, (nct, across)) in enumerate(((n_v, m(sec.h) - 2cov - dt), (n_h, m(sec.b) - 2cov - dt)))
        nct > 0 || continue
        push!(md.groups, BarGroup(; mark = "C$(2 + k)", role = :crosstie, direction = :transverse,
                                  bar_size = tie_bar, count = nct * length(xs),
                                  length = (across + 2hook) * u"m", shape = :crosstie,
                                  x_positions = xs,
                                  note = "$(nct) per tie set, 135-degree hooks both ends (§25.7.2.3)"))
    end
end

"""
Spiral from ACI 318-19 Eq. (25.7.3.3) before any shear pitch.

Returns `(bar_size, pitch, wire_per_turn, ρs)` in metres, or `nothing` when
no No. 3 to No. 5 bar keeps the clear spacing of §25.7.3 between 1 in. and
3 in. The 1.5 extra turns at each end are not in `wire_per_turn`.
"""
function _spiral_confinement(D::Length, cover::Length, fc, fyt)
    Dm = ustrip(u"m", D)
    cov = ustrip(u"m", cover)
    Dc = Dm - 2cov
    (Dc > 0) || return nothing
    Ag = π * Dm^2 / 4
    Ach = π * Dc^2 / 4
    (Ach > 0) || return nothing
    ρs = 0.45 * (Ag / Ach - 1) * ustrip(u"psi", fc) / ustrip(u"psi", fyt)
    (ρs > 0) || return nothing
    clear_min, clear_max = ustrip(u"m", 1.0u"inch"), ustrip(u"m", 3.0u"inch")
    for bsp in 3:5
        dsp = ustrip(u"m", bar_diameter(bsp))
        Asp = ustrip(u"m^2", bar_area(bsp))
        s = min(4 * Asp / (Dc * ρs), clear_max + dsp)
        if s - dsp >= clear_min - 1e-9
            Dsp = Dc - dsp
            per_turn = sqrt((π * Dsp)^2 + s^2)
            return (bar_size = bsp, pitch = s, wire_per_turn = per_turn, ρs = ρs)
        end
    end
    return nothing
end

function _add_spiral!(md, sec::RCCircularSection, H, top_limit, fc, fyt; cover, db,
                      shear_spacing = nothing)
    m(x) = ustrip(u"m", x)
    chosen = _spiral_confinement(sec.D, cover * u"m", fc, fyt)
    if chosen === nothing
        push!(md.warnings, "spiral: no No. 3 to No. 5 spiral meets ρs with at least 1 in. clear (§25.7.3)")
        return
    end
    bsp = chosen.bar_size
    s = chosen.pitch
    ρs = chosen.ρs
    dsp = m(bar_diameter(bsp))
    clear_min = m(1.0u"inch")
    Dc = m(sec.D) - 2cover
    shear_note = ""
    if shear_spacing !== nothing
        s_sh = m(shear_spacing)
        if s_sh + 1e-12 < s
            if s_sh - dsp < clear_min - 1e-9
                push!(md.warnings,
                    "shear needs a spiral pitch of $(round(s_sh / 0.0254; digits = 2)) in., " *
                    "tighter than the 1 in. clear of §25.7.3; the confinement pitch is kept")
            else
                s = s_sh
                shear_note = ", closed to the shear spacing (§22.5)"
            end
        end
    end
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
                                     "(Eq. 25.7.3.3), 1.5 extra turns each end$(shear_note)"))
end

"""
    transverse_steel_per_length(sec, concrete, rebar) -> Area

Volume of tie, crosstie, or spiral steel per unit length of the member,
at the spacing the detailing uses when shear does not close it up.

Rectangular and circular ties use ACI 318-19 §25.7.2.1(b) and the §25.7.2.3
crossties. A spiral uses Eq. (25.7.3.3); the extra turns at the ends are
not in this per-length quantity. Shear can only place the steel closer.
"""
function transverse_steel_per_length(sec::RCCircularSection, concrete, rebar)
    if sec.tie_type == :spiral
        chosen = _spiral_confinement(sec.D, sec.cover, concrete.fc′, rebar.Fy)
        chosen === nothing && return zero(sec.Ag)
        return bar_area(chosen.bar_size) * (chosen.wire_per_turn * u"m") / (chosen.pitch * u"m")
    end
    return _tie_steel_per_length(sec, rebar)
end

function transverse_steel_per_length(sec::RCColumnSection, concrete, rebar)
    return _tie_steel_per_length(sec, rebar)
end

function _tie_steel_per_length(sec, rebar)
    bs = _column_bar_size(sec)
    circular = sec isa RCCircularSection
    tie_bar = circular ? (bs >= 11 ? 4 : 3) : sec.tie_bar_size
    least = circular ? sec.D : min(sec.b, sec.h)
    s = column_tie_spacing(bs, tie_bar, least)
    cov = sec.cover
    dt = bar_diameter(tie_bar)
    hook = hook_centerline_length(tie_bar; angle = 135, role = :stirrup)
    if circular
        dcl = sec.D - 2cov - dt
        dcl > zero(dcl) || return zero(sec.Ag)
        len = π * dcl + 2 * hook
        return bar_area(tie_bar) * len / s
    end
    w_cl = sec.b - 2cov - dt
    h_cl = sec.h - 2cov - dt
    (w_cl > zero(w_cl) && h_cl > zero(h_cl)) || return zero(sec.Ag)
    len = _closed_loop_length(ustrip(u"m", w_cl), ustrip(u"m", h_cl), tie_bar) * u"m"
    legs = column_tie_legs(sec)
    extra = zero(len)
    n_v, n_h = legs.y - 2, legs.x - 2
    n_v > 0 && (extra += n_v * (h_cl + 2 * hook))
    n_h > 0 && (extra += n_h * (w_cl + 2 * hook))
    return bar_area(tie_bar) * (len + extra) / s
end
