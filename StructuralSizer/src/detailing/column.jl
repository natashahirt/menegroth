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
Lap the continuing bars in the center half of the clear height.

# Citation
ACI 318-19 §18.7.4.4 (corpus: aci-318-19, PDF page 309).
"""
function _gravity_center_lap!(md, sec, H, hs, cs, z_bar, bs, n, fc, fy; continues, λ, coating)
    m(x) = ustrip(u"m", x)
    clear = H - hs
    if bs > 11
        push!(md.warnings, "No. $(bs) column bars cannot be lap spliced (§25.5.1.1); " *
                           "a mechanical splice is needed and is not detailed")
        push!(md.groups, BarGroup(; mark = "C1", role = :longitudinal, direction = :along,
                                  bar_size = bs, count = n, length = H * u"m",
                                  path = [(0.0, z_bar), (H, z_bar)],
                                  note = "no lap; a mechanical splice is required"))
        return nothing
    end
    lap = m(column_lap_length(sec, fc, fy; λ = λ, coating = coating))
    # §18.7.4.4 (corpus: aci-318-19, PDF page 309): the lap is a tension lap
    # and it lies in the center half of the member.
    zone0, zone1 = clear / 4, 3 * clear / 4
    if lap > clear / 2 + 1e-6
        push!(md.warnings, "the tension lap of $(round(lap / 0.0254; digits = 1)) in. " *
                           "is longer than the center half of the clear height (§18.7.4.4)")
    end
    lap_end = min(zone0 + lap, zone1)
    db = m(bar_diameter(bs))
    if continues
        path = [(zone0, z_bar), (H, z_bar)]
        shape = :straight
        story = H - zone0
        note = "story bars, lapped in the center half (§18.7.4.4)"
    else
        top = H - cs - db / 2
        tail = m(standard_hook(bs; angle = 90).extension)
        path = [(zone0, z_bar), (top, z_bar), (top, z_bar - tail)]
        shape = :hook_end
        story = (top - zone0) + m(hook_centerline_length(bs; angle = 90))
        note = "story bars, lapped in the center half and hooked into the roof (§18.7.4.4)"
    end
    push!(md.groups, BarGroup(; mark = "C1", role = :longitudinal, direction = :along,
                              bar_size = bs, count = n, length = story * u"m",
                              shape = shape, path = path, laps = 1, note = note))
    push!(md.groups, BarGroup(; mark = "C1b", role = :longitudinal, direction = :along,
                              bar_size = bs, count = n, length = (lap_end - zone0) * u"m",
                              path = [(zone0, z_bar), (lap_end, z_bar)],
                              note = "lap from the story below, $(round((lap_end - zone0) / 0.0254; digits = 1)) in."))
    return nothing
end

"""
Hoops over ℓo at each joint face, through the middle of the column, and
through the joint.

# Citation
ACI 318-19 §18.7.5.1 and §18.7.5.3–§18.7.5.5 (corpus: aci-318-19, PDF pages 309–312).
ACI 318-19 §18.4.4.4 and §15.3.1.3 (PDF pages 297 and 159).
"""
function _detail_gravity_hoops!(md, sec, H, hs, s_ordinary, bs, tie_bar, cov, dt, fc, fy, fyt;
                               Pu, beam_depth, shear_end = nothing, shear_mid = nothing)
    m(x) = ustrip(u"m", x)
    Ag = sec.b * sec.h
    ratio = ustrip(u"inch^2", sec.As_total) / ustrip(u"inch^2", Ag)
    (0.01 - 1e-9 <= ratio <= 0.06 + 1e-9) || push!(md.warnings,
        "longitudinal ratio $(round(ratio; digits = 4)) is outside 0.01Ag to 0.06Ag (§18.7.4.1)")
    clear = H - hs
    ℓd = m(tension_development_length(bs, fc, fy, _detailing_λ(1.0); ψt = 1.0))
    1.25 * ℓd <= clear / 2 + 1e-6 || push!(md.warnings,
        "1.25ℓd = $(round(1.25 * ℓd / 0.0254; digits = 1)) in. exceeds half the clear height (§18.7.4.3)")
    least = min(m(sec.b), m(sec.h))
    db = bar_diameter(bs)
    hx = _column_face_hx(sec)
    hx_in = ustrip(u"inch", hx)
    if hx_in > 14
        push!(md.warnings, "hx = $(round(hx_in; digits = 1)) in. exceeds 14 in. (§18.7.5.2)")
    end
    ℓo = min(m(special_column_hoop_length(least * u"m", clear * u"m")), clear)
    # Shear spacing can only close the hoops. It does not relax §18.7.5.3.
    s_end = min(m(_special_hoop_spacing(sec, least * u"m", db, fy, hx, fc, fyt, Pu)), s_ordinary)
    shear_end === nothing || (s_end = min(s_end, m(shear_end)))
    grade = coupling_beam_grade(fy)
    from_bar = (grade == 60 ? 6 : 5) * db
    s_mid = m(min(s_ordinary * u"m", 6.0u"inch", from_bar))
    shear_mid === nothing || (s_mid = min(s_mid, m(shear_mid)))
    # §18.4.3.3(a)–(c), which §18.4.4.4 applies inside the joint (PDF page 296).
    joint_bar = grade == 60 ? min(8 * db, 8.0u"inch") : min(6 * db, 6.0u"inch")
    s_joint = m(min(joint_bar, least * u"m" / 2))
    w_cl = m(sec.b) - 2cov - dt
    h_cl = m(sec.h) - 2cov - dt
    len = _closed_loop_length(w_cl, h_cl, tie_bar; hook_angle = 135)
    path = [(0.0, -m(sec.b) / 2 + cov + dt / 2), (0.0, m(sec.b) / 2 - cov - dt / 2)]
    function place(mark, xs, note)
        isempty(xs) && return
        push!(md.groups, BarGroup(; mark = mark, role = :tie, direction = :transverse,
                                  bar_size = tie_bar, count = length(xs), length = len * u"m",
                                  shape = :closed_tie, path = path, x_positions = xs, note = note))
        _add_crossties!(md, sec, xs, tie_bar, cov, dt; mark_base = mark)
    end
    bot = _spaced_positions(0.0, ℓo, s_end)
    top0 = clear - ℓo
    top = top0 <= ℓo + 1e-9 ? Float64[] : _spaced_positions(top0, clear, s_end)
    place("C2", bot, "hoops over ℓo above the lower joint, $(round(s_end / 0.0254; digits = 1)) in. (§18.7.5.3)")
    place("C2t", top, "hoops over ℓo below the upper joint, $(round(s_end / 0.0254; digits = 1)) in. (§18.7.5.3)")
    mid0 = isempty(bot) ? 0.0 : bot[end]
    mid1 = isempty(top) ? clear : top[1]
    mid = mid1 > mid0 + s_mid ? _spaced_positions(mid0 + s_mid, mid1 - s_mid, s_mid) : Float64[]
    place("C3", mid, "hoops between the ℓo zones, $(round(s_mid / 0.0254; digits = 1)) in. (§18.7.5.5)")
    depth = m(beam_depth)
    joint0 = H - hs
    joint1 = joint0 + min(depth, hs)
    joint = _spaced_positions(joint0, joint1, s_joint)
    if length(joint) < 2 && joint1 > joint0
        joint = [joint0, joint1]
        push!(md.warnings, "the joint is shallower than the §18.4.4.4 spacing; " *
                           "two hoop layers are placed at its faces (§15.3.1.3)")
    end
    place("J1", joint, "joint hoops, $(round(s_joint / 0.0254; digits = 1)) in. (§18.4.4.4, §15.3.1.3)")
    return nothing
end

"Largest center-to-center gap of bars on one column face."
function _column_face_hx(sec::RCColumnSection)
    pts = section_rebar_positions(sec)
    isempty(pts) && return max(sec.b, sec.h)
    ys = [p[1] for p in pts]
    zs = [p[2] for p in pts]
    ymin, ymax = extrema(zs)
    xmin, xmax = extrema(ys)
    tol = 1e-4
    function gap(sel, coord)
        xs = sort(Float64[coord[i] for i in eachindex(coord) if sel(i)])
        length(xs) < 2 && return 0.0
        return maximum(xs[i + 1] - xs[i] for i in 1:(length(xs) - 1))
    end
    hx = maximum((
        gap(i -> abs(zs[i] - ymin) <= tol, ys),
        gap(i -> abs(zs[i] - ymax) <= tol, ys),
        gap(i -> abs(ys[i] - xmin) <= tol, zs),
        gap(i -> abs(ys[i] - xmax) <= tol, zs),
    ))
    return max(hx, 1e-6) * u"m"
end

"""
Spacing of special-column hoops over ℓo. The least of §18.7.5.3 and the
spacing that supplies Table 18.7.5.4.
"""
function _special_hoop_spacing(sec, least, db, fy, hx, fc, fyt, Pu)
    grade = coupling_beam_grade(fy)
    from_bar = (grade == 60 ? 6 : 5) * db
    so = transverse_spacing_so(hx).so
    # §18.7.5.3 (corpus: aci-318-19, PDF pages 310–311).
    s = min(least / 4, from_bar, so)
    cover = sec.cover
    core_x = sec.b - 2 * cover
    core_y = sec.h - 2 * cover
    Ag = sec.b * sec.h
    Ach = core_x * core_y
    amount = boundary_transverse_amount(Ag, Ach, fc, fyt)
    ratio = amount.required
    fc_psi = ustrip(u"psi", fc)
    pu = Pu === nothing ? 0.0 : ustrip(u"lbf", Pu)
    ag = ustrip(u"inch^2", Ag)
    if pu > 0.3 * ag * fc_psi || fc_psi > 10_000
        kf = max(fc_psi / 25_000 + 0.6, 1.0)
        nl = length(sec.bars)
        if nl > 2 && Pu !== nothing
            kn = nl / (nl - 2)
            # Table 18.7.5.4(c) (corpus: aci-318-19, PDF page 311).
            extra = 0.2 * kf * kn * ustrip(u"N", Pu) /
                    (ustrip(u"Pa", fyt) * ustrip(u"m^2", Ach))
            ratio = max(ratio, extra)
        end
    end
    legs = column_tie_legs(sec)
    Ash = min(legs.x, legs.y) * bar_area(sec.tie_bar_size)
    bc = max(core_x, core_y)
    s_ash = Ash / (ratio * bc)
    return min(s, s_ash)
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
- `gravity_seismic`: the column is outside the seismic force-resisting
  system in Seismic Design Category D, E, or F, and the moments from the
  design displacement are not calculated, so §18.14.3.3 applies. Hoops follow
  §18.7.5 over ℓo and through the middle, the lap sits in the center half,
  and the joint is hooped under §18.4.4.
- `Pu`: largest factored compression, including earthquake, for the
  §18.7.5.4 amount. Omitted, it is taken as zero.
- `material` and `axials`: with these, the hoops are spaced for the
  probable-moment shear of §18.7.6. `Vu_x` and `Vu_y` are the factored
  shears from analysis. `beam_shear` is the cap from the beams at the joint.

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
                       tie_spacing::Union{Nothing, Length} = nothing,
                       gravity_seismic::Bool = false,
                       Pu::Union{Nothing, Force} = nothing,
                       beam_depth::Union{Nothing, Length} = nothing,
                       material::Union{Nothing, ReinforcedConcreteMaterial} = nothing,
                       axials = (),
                       Vu_x = 0.0u"N", Vu_y = 0.0u"N",
                       beam_shear = nothing)
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

    if gravity_seismic && circular
        push!(md.warnings, "gravity seismic detailing is placed for a rectangular column; " *
                           "this circular column keeps the ordinary spiral")
    end
    seismic = gravity_seismic && !circular

    # ── Longitudinal bars ──────────────────────────────────────────────────
    z_bar = width / 2 - cov - dt - db / 2
    if seismic
        _gravity_center_lap!(md, sec, H, hs, cs, z_bar, bs, n, fc, fy;
                             continues = continues, λ = λ, coating = coating)
    elseif continues
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
    story = findfirst(g -> g.mark == "C1", md.groups)
    checked = story === nothing ? md.groups[end] : md.groups[story]
    checked.length > stock && push!(md.warnings,
        "column bars of $(round(m(checked.length); digits = 2)) m exceed the " *
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
        shear_end = shear_mid = nothing
        if seismic && material !== nothing
            range = isempty(axials) && Pu !== nothing ? (Pu,) : axials
            designed = special_column_shear_design(sec, material, (H - hs) * u"m";
                                                   axials = range, Vu_x = Vu_x, Vu_y = Vu_y,
                                                   beam_shear = beam_shear)
            shear_end = designed.spacing
            shear_mid = designed.spacing_middle
            ve = round(ustrip(u"kip", max(designed.Ve_x, designed.Ve_y)); digits = 1)
            vc = designed.concrete_omitted ? "Vc = 0 over ℓo" : "Vc counted"
            push!(md.notes, "design shear $(ve) kip, $vc (§18.7.6)")
            designed.ok || push!(md.warnings,
                "the section cannot provide the §18.7.6 shear; the hoops are at the closest spacing")
        elseif seismic
            push!(md.warnings, "§18.7.6 shear is not computed until the column material is passed")
        end
        if seismic
            _detail_gravity_hoops!(md, sec, H, hs, s, bs, tie_bar, cov, dt, fc, fy, fyt;
                                   Pu = Pu, beam_depth = beam_depth === nothing ? slab_above : beam_depth,
                                   shear_end = shear_end, shear_mid = shear_mid)
        else
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
    placed = seismic ? _placed_area_in2(md, :longitudinal; mark = "C1") :
                       _placed_area_in2(md, :longitudinal)
    record_steel_area!(md, "longitudinal", ustrip(u"inch^2", sec.As_total),
                       placed; source = "the section As")
    _locate_column!(md, sec, cov, dt)
    if gravity_seismic
        mats = special_moment_frame_materials(fc, fy; lightweight = λ < 1)
        append!(md.warnings, mats.warnings)
        append!(md.notes, mats.notes)
        append!(md.notes, special_frame_splice_notes())
    end
    return md
end

"""
Centerlines in the section frame: `x` up from the floor, `y` and `z` the
centroid axes of the section (`y` across `b`). A hooked bar turns toward the
centroid by the same tail the elevation draws. Ties are the closed loop at
each station. Crossties cross the section at the bars §25.7.2.3 supports
between the corners.
"""
function _locate_column!(md::MemberDetail, sec, cov::Float64, dt::Float64)
    m(x) = ustrip(u"m", x)
    circular = sec isa RCCircularSection
    b = circular ? m(sec.D) : m(sec.b)
    h = circular ? m(sec.D) : m(sec.h)
    positions = section_rebar_positions(sec)
    for i in eachindex(md.groups)
        g = md.groups[i]
        if g.role === :longitudinal
            md.groups[i] = _with_centerlines(g, _column_long_wires(g.path, positions))
        elseif g.role === :spiral
            md.groups[i] = _with_centerlines(g, [_spiral_wire(g.path, g.x_positions)])
        elseif g.role === :tie
            loop = circular ? _circle_loop(b / 2 - cov - dt / 2) : _column_tie_loop(sec)
            md.groups[i] = _with_centerlines(g, _wires_at_x(loop, g.x_positions))
        end
    end
    _locate_crossties!(md, sec, cov, dt)
    shaft = md.outline[1]
    md.solid = (shaft[1], shaft[2], -b / 2, b / 2, -h / 2, h / 2)
    return nothing
end

function _column_long_wires(path, positions)
    length(path) >= 2 || return Vector{NTuple{3, Float64}}[]
    hooked = length(path) >= 3 && abs(path[end][1] - path[end - 1][1]) < 1e-9
    x0 = path[1][1]
    x1 = hooked ? path[end - 1][1] : path[end][1]
    tail = hooked ? abs(path[end][2] - path[end - 1][2]) : 0.0
    wires = Vector{NTuple{3, Float64}}[]
    for (y, z) in positions
        if !hooked
            push!(wires, [(x0, y, z), (x1, y, z)])
            continue
        end
        r = hypot(y, z)
        tip = r < 1e-8 ? (x1, y, z) : (x1, y * max(r - tail, 0.0) / r, z * max(r - tail, 0.0) / r)
        push!(wires, [(x0, y, z), (x1, y, z), tip])
    end
    return wires
end

function _column_tie_loop(sec::RCColumnSection)
    tr = section_transverse(sec)
    tr === nothing && return NTuple{2, Float64}[]
    return tr.loop
end

function _circle_loop(radius::Float64)
    return [(radius * cos(t), radius * sin(t)) for t in range(0, 2π; length = 25)]
end

function _spiral_wire(path, xs)
    isempty(path) && return NTuple{3, Float64}[]
    R = maximum(abs(p[2]) for p in path)
    x1 = maximum(p[1] for p in path)
    pitch = length(xs) >= 2 ? abs(xs[2] - xs[1]) : max(x1, 1e-6)
    turns = x1 / pitch
    n = max(16, round(Int, turns * 16))
    return [(x1 * i / n, R * sin(2π * turns * i / n), R * cos(2π * turns * i / n)) for i in 0:n]
end

"Supported bars strictly between the two corners, at the same stations §25.7.2.3 uses."
function _interior_supported(positions::Vector{Float64}, db::Float64, limit::Float64)
    n = length(positions)
    n <= 2 && return Float64[]
    supported = falses(n)
    supported[1] = supported[n] = true
    for i in 3:2:(n - 1)
        supported[i] = true
    end
    for i in 2:(n - 1)
        supported[i] && continue
        gap = minimum(abs(positions[i] - positions[k]) for k in 1:n if supported[k]) - db
        gap > limit + 1e-9 && (supported[i] = true)
    end
    return [positions[i] for i in 2:(n - 1) if supported[i]]
end

function _locate_crossties!(md::MemberDetail, sec::RCCircularSection, cov, dt)
    return nothing
end

function _locate_crossties!(md::MemberDetail, sec::RCColumnSection, cov::Float64, dt::Float64)
    m(x) = ustrip(u"m", x)
    pts = section_rebar_positions(sec)
    isempty(pts) && return nothing
    ys = [p[1] for p in pts]
    zs = [p[2] for p in pts]
    ymin, ymax = extrema(ys)
    zmin, zmax = extrema(zs)
    tol = 1e-4
    face(sel, coord) = sort(Float64[coord[i] for i in eachindex(coord) if sel(i)])
    bottom = face(i -> abs(zs[i] - zmin) <= tol, ys)
    top = face(i -> abs(zs[i] - zmax) <= tol, ys)
    left = face(i -> abs(ys[i] - ymin) <= tol, zs)
    right = face(i -> abs(ys[i] - ymax) <= tol, zs)
    bs = _column_bar_size(sec)
    db = m(bar_diameter(bs))
    limit = m(6.0u"inch")
    across_y = length(_interior_supported(bottom, db, limit)) >= length(_interior_supported(top, db, limit)) ?
               _interior_supported(bottom, db, limit) : _interior_supported(top, db, limit)
    across_z = length(_interior_supported(left, db, limit)) >= length(_interior_supported(right, db, limit)) ?
               _interior_supported(left, db, limit) : _interior_supported(right, db, limit)
    half_y = m(sec.b) / 2 - cov - dt / 2
    half_z = m(sec.h) / 2 - cov - dt / 2
    specs = Tuple{Symbol, Vector{Float64}, Float64}[]
    length(across_y) > 0 && push!(specs, (:z, across_y, half_z))
    length(across_z) > 0 && push!(specs, (:y, across_z, half_y))
    groups = findall(g -> g.role === :crosstie, md.groups)
    length(groups) == length(specs) || throw(ArgumentError(
        "$(length(groups)) crosstie groups and $(length(specs)) supported faces"))
    for (i, (along, coords, half)) in zip(groups, specs)
        g = md.groups[i]
        wires = Vector{NTuple{3, Float64}}[]
        for x in g.x_positions, c in coords
            push!(wires, along === :z ? [(x, c, -half), (x, c, half)] :
                                        [(x, -half, c), (x, half, c)])
        end
        md.groups[i] = _with_centerlines(g, wires)
    end
    return nothing
end

function _add_crossties!(md, sec::RCColumnSection, xs, tie_bar, cov, dt; mark_base = "C")
    m(x) = ustrip(u"m", x)
    hook = m(hook_centerline_length(tie_bar; angle = 135, role = :stirrup))
    # The same leg count design_column_shear used for Av.
    legs = column_tie_legs(sec)
    n_v = legs.y - 2
    n_h = legs.x - 2
    for (k, (nct, across)) in enumerate(((n_v, m(sec.h) - 2cov - dt), (n_h, m(sec.b) - 2cov - dt)))
        nct > 0 || continue
        mark = mark_base == "C" ? "C$(2 + k)" : "$(mark_base)$(k == 1 ? "v" : "h")"
        push!(md.groups, BarGroup(; mark = mark, role = :crosstie, direction = :transverse,
                                  bar_size = tie_bar, count = nct * length(xs),
                                  length = (across + 2hook) * u"m", shape = :crosstie,
                                  x_positions = xs,
                                  note = "$(nct) per tie set, 135-degree hooks both ends (§25.7.2.3)"))
    end
end

function _add_spiral!(md, sec::RCCircularSection, H, top_limit, fc, fyt; cover, db,
                      shear_spacing = nothing)
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
