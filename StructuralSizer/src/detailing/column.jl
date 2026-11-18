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
True when the factored gravity axial exceeds 0.35P0.

P0 = 0.85f′c(Ag − Ast) + fy·Ast, the same expression as pure compression.
`Pu` is compression-positive. A missing force does not exceed the limit.

# Citation
ACI 318-19 §18.14.3.2(c) (corpus: aci-318-19, PDF pages 353–354).
"""
function _exceeds_35P0(sec, fc, fy, Pu)
    Pu === nothing && return false
    Ag = ustrip(u"inch^2", sec isa RCCircularSection ? π * sec.D^2 / 4 : sec.b * sec.h)
    As = ustrip(u"inch^2", sec.As_total)
    P0 = 0.85 * ustrip(u"psi", fc) * (Ag - As) + ustrip(u"psi", fy) * As
    return ustrip(u"lbf", Pu) > 0.35 * P0
end

"""
§18.14.3.2(b) and (c).

Returns whether (c) applies. The half-table amount is placed by
[`_detail_gravity_hoops!`](@ref) for rectilinear hoops and by
[`_add_spiral!`](@ref) for a spiral, not left as a warning.
"""
function _note_gravity_column_within!(md, sec, fc, fy, Pu_gravity; spiral::Bool = false)
    push!(md.notes,
        (spiral ? "spiral" : "hoops") *
        " over the full height at most the lesser of 6db and 6 in., " *
        "and §18.7.5.2(a) through (e) over ℓo (§18.14.3.2(b))")
    if Pu_gravity === nothing
        push!(md.notes,
            "factored gravity axial was not passed; §18.14.3.2(c) is not applied")
        return false
    end
    if _exceeds_35P0(sec, fc, fy, Pu_gravity)
        push!(md.notes,
            "factored gravity axial exceeds 0.35P0; half of Table 18.7.5.4 " *
            (spiral ? "(d) and (e)" : "(a) and (b)") * " is placed over ℓo (§18.14.3.2(c))")
        return true
    end
    push!(md.notes, "factored gravity axial does not exceed 0.35P0 (§18.14.3.2(c))")
    return false
end

"""
Spacing that supplies one-half of Table 18.7.5.4 (a) and (b).

The two expressions are the same ones [`boundary_transverse_amount`](@ref)
evaluates for Table 18.10.6.4(g). This call is Table 18.7.5.4. Parts (c)
and (f) are not in the §18.14.3.2(c) minimum. `nothing` when the core
area is not positive.

# Citation
ACI 318-19 §18.14.3.2(c) and Table 18.7.5.4 (corpus: aci-318-19, PDF
pages 353–354 and 311).
"""
function _half_table_hoop_spacing(sec, fc, fyt)
    cover = sec.cover
    core_x = sec.b - 2 * cover
    core_y = sec.h - 2 * cover
    (ustrip(u"m", core_x) > 0 && ustrip(u"m", core_y) > 0) || return nothing
    amount = boundary_transverse_amount(sec.b * sec.h, core_x * core_y, fc, fyt)
    ratio = 0.5 * amount.required
    ratio > 0 || return nothing
    legs = column_tie_legs(sec)
    Ash = min(legs.x, legs.y) * bar_area(sec.tie_bar_size)
    return Ash / (ratio * max(core_x, core_y))
end

"""
Hoops over ℓo at each joint face, through the middle of the column, and
through the joint.

# Citation
ACI 318-19 §18.7.5.1 and §18.7.5.3–§18.7.5.5 (corpus: aci-318-19, PDF pages 309–312).
ACI 318-19 §18.4.4.4 and §15.3.1.3 (PDF pages 297 and 159).
"""
function _detail_gravity_hoops!(md, sec, H, hs, s_ordinary, bs, tie_bar, cov, dt, fc, fy, fyt;
                               Pu, beam_depth, shear_end = nothing, shear_mid = nothing,
                               within::Bool = false, Pu_gravity = nothing)
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
    grade = coupling_beam_grade(fy)
    from_bar = (grade == 60 ? 6 : 5) * db
    # §18.14.3.2(b): lesser of 6db and 6 in. over the full height.
    # §18.14.3.2(c): half of Table 18.7.5.4 (a) and (b) over ℓo when the
    # factored gravity axial exceeds 0.35P0. That path does not use
    # §18.7.5.3 or Table 18.7.5.4(c). The §18.14.3.3 path does.
    over = within && _exceeds_35P0(sec, fc, fy, Pu_gravity)
    if within
        s_end = min(s_ordinary, m(6.0u"inch"), m(6 * db))
        if over
            s_half = _half_table_hoop_spacing(sec, fc, fyt)
            s_half === nothing || (s_end = min(s_end, m(s_half)))
        end
        s_mid = min(s_ordinary, m(6.0u"inch"), m(6 * db))
        end_clause = over ? "18.14.3.2(c)" : "18.14.3.2(b)"
    else
        # Shear spacing can only close the hoops. It does not relax §18.7.5.3.
        s_end = min(m(_special_hoop_spacing(sec, least * u"m", db, fy, hx, fc, fyt, Pu)), s_ordinary)
        s_mid = m(min(s_ordinary * u"m", 6.0u"inch", from_bar))
        end_clause = "18.7.5.3"
    end
    shear_end === nothing || (s_end = min(s_end, m(shear_end)))
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
    pitch = round(s_end / 0.0254; digits = 1)
    place("C2", bot, "hoops over ℓo above the lower joint, $(pitch) in. (§$(end_clause))")
    place("C2t", top, "hoops over ℓo below the upper joint, $(pitch) in. (§$(end_clause))")
    mid0 = isempty(bot) ? 0.0 : bot[end]
    mid1 = isempty(top) ? clear : top[1]
    mid = mid1 > mid0 + s_mid ? _spaced_positions(mid0 + s_mid, mid1 - s_mid, s_mid) : Float64[]
    mid_clause = within ? "18.14.3.2(b)" : "18.7.5.5"
    place("C3", mid, "hoops between the ℓo zones, $(round(s_mid / 0.0254; digits = 1)) in. (§$(mid_clause))")
    # §18.7.5.7, required by §18.14.3.2(c) when the gravity axial exceeds
    # 0.35P0. Cover outside the confining hoop is `sec.cover`. Above 4 in.,
    # a second hoop sits at 4 in. cover, at most 12 in. apart, over ℓo.
    if over && cov > m(4.0u"inch") + 1e-9
        _place_cover_hoops!(md, sec, bot, top, tie_bar, dt)
    end
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

"""
Additional hoops at 4 in. cover over ℓo, spacing at most 12 in.

The confining hoop is the one already placed at `sec.cover`. This set sits
outside it. A section that cannot hold a hoop at 4 in. cover keeps the
warning and does not get a crossing loop.

# Citation
ACI 318-19 §18.7.5.7 (corpus: aci-318-19, PDF page 312), required by
§18.14.3.2(c).
"""
function _place_cover_hoops!(md, sec, bot, top, tie_bar, dt)
    m(x) = ustrip(u"m", x)
    cov = m(4.0u"inch")
    w = m(sec.b)
    h = m(sec.h)
    if w <= 2cov + dt || h <= 2cov + dt
        push!(md.warnings,
            "cover outside the confining hoop exceeds 4 in., and the section " *
            "cannot hold the additional hoop at 4 in. cover (§18.7.5.7)")
        return nothing
    end
    s = m(12.0u"inch")
    w_cl = w - 2cov - dt
    h_cl = h - 2cov - dt
    len = _closed_loop_length(w_cl, h_cl, tie_bar; hook_angle = 135)
    path = [(0.0, -w / 2 + cov + dt / 2), (0.0, w / 2 - cov - dt / 2)]
    # One group per ℓo zone. The clear height between them is not this spacing.
    function place(mark, a, b)
        b >= a || return
        xs = _spaced_positions(a, b, s)
        push!(md.groups, BarGroup(; mark = mark, role = :tie, direction = :transverse,
                                  bar_size = tie_bar, count = length(xs), length = len * u"m",
                                  shape = :closed_tie, path = path, x_positions = xs,
                                  note = "additional hoops at 4 in. cover, 12 in. (§18.7.5.7)"))
    end
    isempty(bot) || place("C4", 0.0, bot[end])
    isempty(top) || place("C4t", top[1], top[end])
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
  design displacement were not calculated or they exceed the design strength,
  so §18.14.3.3 applies. Hoops follow §18.7.5 over ℓo and through the middle,
  the lap sits in the center half, and the joint is hooped under §18.4.4.
- `induced_within_strength`: those moments and shears were calculated and do
  not exceed the design strength, so §18.14.3.2 applies. Hoops run the full
  height at most the lesser of 6db and 6 in., and §18.7.5.2(a) through (e)
  over ℓo. The lap stays the ordinary lap. A circular column with a spiral
  takes the same pitch limit and §18.7.6 shear; a circular column with ties,
  or on the §18.14.3.3 path, keeps its ordinary transverse bars and a warning.
- `Pu`: largest factored compression, including earthquake, for the
  §18.7.5.4 amount on the §18.14.3.3 path. Omitted, it is taken as zero.
- `Pu_gravity`: factored gravity axial for the §18.14.3.2(c) trigger.
  This is the axial from the gravity combinations, including the vertical
  ground motion of §18.14.2.1, and not the earthquake shear. Omitted, (c)
  is not applied.
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
                       induced_within_strength::Bool = false,
                       Pu::Union{Nothing, Force} = nothing,
                       Pu_gravity::Union{Nothing, Force} = nothing,
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

    spiral = circular && sec.tie_type == :spiral
    # §18.14.3.2 with a spiral is detailed. §18.14.3.3 on a circular column,
    # and §18.14.3.2 with circular hoops, are not.
    spiral_within = induced_within_strength && !gravity_seismic && spiral
    if (gravity_seismic || induced_within_strength) && circular && !spiral_within
        push!(md.warnings, "gravity seismic detailing is placed for a rectangular column " *
                           "or a §18.14.3.2 spiral; this circular column keeps its ordinary " *
                           (spiral ? "spiral" : "ties"))
    end
    seismic = gravity_seismic && !circular
    within = induced_within_strength && !circular
    hooped = seismic || within

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
    if spiral
        s_shear = tie_spacing
        over = false
        if spiral_within
            ratio = ustrip(u"inch^2", sec.As_total) / ustrip(u"inch^2", π * sec.D^2 / 4)
            (0.01 - 1e-9 <= ratio <= 0.06 + 1e-9) || push!(md.warnings,
                "longitudinal ratio $(round(ratio; digits = 4)) is outside 0.01Ag to 0.06Ag (§18.7.4.1)")
            over = _note_gravity_column_within!(md, sec, fc, fy, Pu_gravity; spiral = true)
            if material !== nothing
                range = isempty(axials) && Pu !== nothing ? (Pu,) : axials
                designed = special_column_shear_design(sec, material, (H - hs) * u"m";
                                                       axials = range, Vu_x = Vu_x, Vu_y = Vu_y,
                                                       beam_shear = beam_shear)
                # One pitch runs the full height, so it takes the tighter of
                # the ℓo and middle spacings.
                s_design = min(designed.spacing, designed.spacing_middle)
                s_shear = s_shear === nothing ? s_design : min(s_shear, s_design)
                ve = round(ustrip(u"kip", max(designed.Ve_x, designed.Ve_y)); digits = 1)
                push!(md.notes, "design shear $(ve) kip, " *
                    (designed.concrete_omitted ? "Vc = 0 over ℓo" : "Vc counted") * " (§18.7.6)")
                designed.ok || push!(md.warnings,
                    "the section cannot provide the §18.7.6 shear; the spiral is at the closest pitch")
            else
                push!(md.warnings, "§18.7.6 shear is not computed until the column material is passed")
            end
            over && cov > m(4.0u"inch") + 1e-9 && push!(md.warnings,
                "cover outside the spiral exceeds 4 in.; the §18.7.5.7 additional " *
                "transverse reinforcement is not detailed for a circular column")
        end
        _add_spiral!(md, sec, H, top_limit, fc, fyt; cover = cov, db = db,
                     shear_spacing = s_shear, within = spiral_within, over = over)
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
        if hooped && material !== nothing
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
        elseif hooped
            push!(md.warnings, "§18.7.6 shear is not computed until the column material is passed")
        end
        if within
            _note_gravity_column_within!(md, sec, fc, fy, Pu_gravity)
        end
        if hooped
            _detail_gravity_hoops!(md, sec, H, hs, s, bs, tie_bar, cov, dt, fc, fy, fyt;
                                   Pu = Pu, beam_depth = beam_depth === nothing ? slab_above : beam_depth,
                                   shear_end = shear_end, shear_mid = shear_mid,
                                   within = within, Pu_gravity = Pu_gravity)
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
    isempty(groups) && isempty(specs) && return nothing
    # Each tie zone adds one crosstie group per supported face, in the same
    # order, so a seismic column repeats the face pattern once per zone.
    (!isempty(groups) && !isempty(specs) && length(groups) % length(specs) == 0) ||
        throw(ArgumentError(
            "$(length(groups)) crosstie groups and $(length(specs)) supported faces"))
    for (j, i) in enumerate(groups)
        along, coords, half = specs[mod1(j, length(specs))]
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

"""
One continuous spiral from the floor to the lowest slab bars above.

`within` is the §18.14.3.2(b) column: the pitch is at most the lesser of
6db and 6 in. over the full height. `over` adds §18.14.3.2(c): ρs is at
least one-half the greater of Table 18.7.5.4 (d) and (e). The code asks for
that amount over ℓo; the spiral keeps one pitch, so it runs the full height.

# Citation
ACI 318-19 §25.7.3 and Eq. (25.7.3.3); §18.14.3.2(b) and (c) and Table
18.7.5.4 (corpus: aci-318-19, PDF pages 353–354 and 311).
"""
function _add_spiral!(md, sec::RCCircularSection, H, top_limit, fc, fyt; cover, db,
                      shear_spacing = nothing, within::Bool = false, over::Bool = false)
    m(x) = ustrip(u"m", x)
    D = m(sec.D)
    Dc = D - 2cover                       # out-to-out of the spiral
    Ag = π * D^2 / 4
    Ach = π * Dc^2 / 4
    ρs = 0.45 * (Ag / Ach - 1) * ustrip(u"psi", fc) / ustrip(u"psi", fyt)   # Eq. (25.7.3.3)
    ρ_note = "Eq. 25.7.3.3"
    if over
        # Table 18.7.5.4 (d) and (e); boundary_transverse_amount evaluates the
        # same two spiral expressions.
        half = 0.5 * boundary_transverse_amount(Ag * u"m^2", Ach * u"m^2", fc, fyt;
                                                spiral = true).required
        if half > ρs
            ρs = half
            ρ_note = "§18.14.3.2(c), half of Table 18.7.5.4 (d) and (e)"
        end
    end
    s_cap = within ? min(m(6.0u"inch"), 6 * db) : Inf
    clear_min, clear_max = m(1.0u"inch"), m(3.0u"inch")
    chosen = nothing
    for bsp in 3:5
        dsp = m(bar_diameter(bsp))
        Asp = ustrip(u"m^2", bar_area(bsp))
        s_req = 4 * Asp / (Dc * ρs)
        s = min(s_req, clear_max + dsp, s_cap)
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
    cap_note = within && s >= s_cap - 1e-9 ? ", at most the lesser of 6db and 6 in. (§18.14.3.2(b))" : ""
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
                                     "($(ρ_note)), 1.5 extra turns each end$(cap_note)$(shear_note)"))
end
