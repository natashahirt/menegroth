# Coupling beams of special structural walls.
#
# ACI 318-19 §18.10.7.1 (corpus: aci-318-19, PDF page 332) sends a beam with
# ℓn/h ≥ 4 to §18.6, and the wall boundary is read as a column. §18.10.7.3
# (PDF page 333) permits §18.6.3 through §18.6.5 for the beams in between.
# §18.10.7.2 and §18.10.7.4 are the diagonal route. The route itself is
# `coupling_beam_route`.

"""φ for shear of a diagonally reinforced coupling beam. §21.2.4.4, PDF page 398."""
const COUPLING_BEAM_DIAGONAL_PHI = 0.85

"""φ for beam shear. Table 21.2.1. Ve is built from Mpr, so Vn is above the shear at Mn and §21.2.4.1 stays at this value."""
const COUPLING_BEAM_SHEAR_PHI = 0.75

"""
    coupling_beam_grade(fy) -> Int

60 or 80. §18.6.3.1 and §18.6.4.4 state those two grades. Anything stronger
is refused rather than given a limit the clause does not state.

# Citation
ACI 318-19 §18.6.3.1 (corpus: aci-318-19, PDF page 303).
"""
function coupling_beam_grade(fy)
    fy_psi = ustrip(u"psi", fy)
    fy_psi > 0 || throw(ArgumentError("coupling beam: fy must be positive (got $fy)"))
    fy_psi <= 60_000 + 1 && return 60
    fy_psi <= 80_000 + 1 && return 80
    throw(ArgumentError(
        "coupling beam: §18.6.3.1 states the reinforcement ratio for Grade 60 and Grade 80 (got $fy)"))
end

"""0.025 for Grade 60 and 0.02 for Grade 80. §18.6.3.1, PDF page 303."""
function coupling_beam_rho_limit(fy)
    return coupling_beam_grade(fy) == 60 ? 0.025 : 0.02
end

"""
    coupling_beam_dimensions(ℓn, h, bw, d) -> NamedTuple

§18.6.2.1(a) and (b). The clear span is at least `4d`. The width is at
least the lesser of `0.3h` and 10 in. Equality passes. Item (c), the
projection past the supporting column, is not this function: a coupling
beam is the wall thickness, so it does not project past the wall.

# Citation
ACI 318-19 §18.6.2.1(a) and (b) (corpus: aci-318-19, PDF page 302).
"""
function coupling_beam_dimensions(ℓn::Length, h::Length, bw::Length, d::Length)
    ustrip(u"m", ℓn) > 0 || throw(ArgumentError("coupling beam: clear span must be positive"))
    ustrip(u"m", h) > 0 || throw(ArgumentError("coupling beam: depth must be positive"))
    ustrip(u"m", bw) > 0 || throw(ArgumentError("coupling beam: width must be positive"))
    ustrip(u"m", d) > 0 || throw(ArgumentError("coupling beam: effective depth must be positive"))
    # §18.6.2.1(a) and (b) (corpus: aci-318-19, PDF page 302).
    span_limit = 4 * d
    width_limit = min(0.3 * h, 10.0u"inch")
    return (span_ok = ustrip(u"m", ℓn) + 1e-9 >= ustrip(u"m", span_limit),
            width_ok = ustrip(u"m", bw) + 1e-9 >= ustrip(u"m", width_limit),
            span_limit = span_limit,
            width_limit = width_limit)
end

"""
    coupling_beam_hoop_spacing(d, db, grade) -> NamedTuple

Spacing of hoops where §18.6.4.1 requires them. The least of `d/4`, 6 in,
and `6db` for Grade 60 or `5db` for Grade 80. `db` is the smallest primary
flexural bar. The first hoop sits at most 2 in from the joint face; that
offset is `first_hoop` and is not a spacing.

# Citation
ACI 318-19 §18.6.4.4 (corpus: aci-318-19, PDF pages 304–305).
"""
function coupling_beam_hoop_spacing(d::Length, db::Length, grade::Int)
    ustrip(u"m", d) > 0 || throw(ArgumentError("coupling beam hoops: d must be positive"))
    ustrip(u"m", db) > 0 || throw(ArgumentError("coupling beam hoops: db must be positive"))
    grade == 60 || grade == 80 || throw(ArgumentError(
        "coupling beam hoops: grade is 60 or 80 (got $grade)"))
    # §18.6.4.4 (corpus: aci-318-19, PDF pages 304–305).
    from_depth = d / 4
    from_cap = 6.0u"inch"
    from_bar = (grade == 60 ? 6 : 5) * db
    return (spacing = min(from_depth, from_cap, from_bar),
            from_depth = from_depth,
            from_cap = from_cap,
            from_bar = from_bar,
            first_hoop = 2.0u"inch")
end

"""
True when §18.6.5.2 sets Vc = 0. The probable-moment shear is at least half
of Ve, and Pu is less than Ag f′c/20. Equality of the axial force keeps Vc.

# Citation
ACI 318-19 §18.6.5.2 (corpus: aci-318-19, PDF pages 305–306).
"""
function coupling_beam_concrete_omitted(V_eq, Ve, Pu, Ag, fc)
    ustrip(u"N", Ve) > 0 || return false
    half = ustrip(u"N", V_eq) + 1e-6 >= 0.5 * ustrip(u"N", Ve)
    cut = Ag * fc / 20
    return half && ustrip(u"N", Pu) < ustrip(u"N", cut)
end

"""
    coupling_beam_design_shear(Mpr_start, Mpr_end, ℓn, Vg) -> NamedTuple

Ve from probable moments of opposite sign at the two joint faces, plus the
factored gravity and vertical-earthquake shear `Vg` on the span.

# Citation
ACI 318-19 §18.6.5.1 (corpus: aci-318-19, PDF page 305). The commentary on
PDF page 306 takes the longitudinal stress as 1.25 fy.
"""
function coupling_beam_design_shear(Mpr_start, Mpr_end, ℓn::Length, Vg)
    ln = ustrip(u"m", ℓn)
    ln > 0 || throw(ArgumentError("coupling beam shear: clear span must be positive"))
    ustrip(u"N*m", Mpr_start) >= 0 || throw(ArgumentError("coupling beam shear: Mpr is non-negative"))
    ustrip(u"N*m", Mpr_end) >= 0 || throw(ArgumentError("coupling beam shear: Mpr is non-negative"))
    ustrip(u"N", Vg) >= 0 || throw(ArgumentError("coupling beam shear: Vg is non-negative"))
    # §18.6.5.1 (corpus: aci-318-19, PDF page 305).
    V_eq = (Mpr_start + Mpr_end) / ℓn
    return (Ve = V_eq + Vg, V_eq = V_eq, Vg = Vg)
end

"""
Nominal moment of a rectangular beam with the same area of steel at `d` and
at `d′`, and axial force `Nu` (compression positive).

`stress_factor` is 1 for Mn and 1.25 for Mpr. The steel stress is limited to
`stress_factor · fy` in tension and in compression. Returns `converged =
false` when `Nu` is outside the section.

# Citation
ACI 318-19 §22.2 for the stress block. Mpr is §18.6.5 with 1.25 fy
(corpus: aci-318-19, PDF page 306).
"""
function coupling_beam_section_moment(bw::Length, h::Length, d::Length, dp::Length,
                                     As, fc, fy, Es, Nu; stress_factor::Real=1.0)
    bw_m = ustrip(u"m", bw)
    h_m = ustrip(u"m", h)
    d_m = ustrip(u"m", d)
    dp_m = ustrip(u"m", dp)
    (bw_m > 0 && h_m > 0 && d_m > dp_m > 0 && d_m < h_m) || throw(ArgumentError(
        "coupling beam section: the steel must sit inside the depth"))
    as_m = ustrip(u"m^2", As)
    as_m > 0 || throw(ArgumentError("coupling beam section: As must be positive"))
    stress_factor > 0 || throw(ArgumentError("coupling beam section: the stress factor must be positive"))
    fc_pa = ustrip(u"Pa", fc)
    fy_pa = stress_factor * ustrip(u"Pa", fy)
    es_pa = ustrip(u"Pa", Es)
    nu = ustrip(u"N", Nu)
    β = beta1(fc)
    function forces(c)
        a = min(β * c, h_m)
        Cc = 0.85 * fc_pa * bw_m * a
        function bar(y)
            ε = 0.003 * (c - y) / c
            fs = clamp(es_pa * ε, -fy_pa, fy_pa)
            return as_m * (y < a && fs > 0 ? fs - 0.85 * fc_pa : fs)
        end
        Fc = bar(dp_m)
        Ft = bar(d_m)
        Pn = Cc + Fc + Ft
        mid = h_m / 2
        Mn = Cc * (mid - a / 2) + Fc * (mid - dp_m) + Ft * (mid - d_m)
        εt = 0.003 * (d_m - c) / c
        return Pn, abs(Mn), εt
    end
    lo = 1e-4 * h_m
    hi = 0.999 * h_m
    Plo, _, _ = forces(lo)
    Phi, _, _ = forces(hi)
    if nu > Phi + 1.0 || nu < Plo - 1.0
        return (Mn = 0.0u"N*m", εt = 0.0, converged = false)
    end
    c = (lo + hi) / 2
    Mn = 0.0
    εt = 0.0
    for _ in 1:60
        c = (lo + hi) / 2
        Pn, Mn, εt = forces(c)
        Pn > nu ? (hi = c) : (lo = c)
    end
    return (Mn = Mn * u"N*m", εt = εt, converged = true)
end

"Round a spacing down to the next half inch. An infinite spacing is unchanged."
function _coupling_half_inch(s::Length)
    inches = ustrip(u"inch", s)
    isfinite(inches) || return s
    return max(floor(inches * 2) / 2, 0.0) * u"inch"
end

"""
    design_special_coupling_beam(ℓn, h, bw, Mu, Nu_start, Nu_end, Vg, Pu,
                                 fc, fy, fyt, Es; λ=1, dimensions=false) -> NamedTuple

§18.6 for one coupling beam. The same bars go on the top and the bottom, so
§18.6.3.2 is met by symmetry. `dimensions` applies §18.6.2.1(a) and (b);
§18.10.7.3 does not.

`Vg` is the factored gravity and vertical-earthquake shear. `Pu` is the
largest factored compression. `Nu_start` and `Nu_end` are the compressions
Mpr is taken at.
"""
function design_special_coupling_beam(ℓn::Length, h::Length, bw::Length, Mu, Nu_start, Nu_end,
                                      Vg, Pu, fc, fy, fyt, Es; λ::Real=1.0, dimensions::Bool=false)
    blank = (ok = false, dimensions = nothing, flexure_ok = false, bars = nothing,
             d = 0.0u"m", As = 0.0u"m^2", ρ = 0.0, ρ_limit = 0.0,
             φMn = 0.0u"N*m", Mpr_start = 0.0u"N*m", Mpr_end = 0.0u"N*m",
             Ve = 0.0u"N", φVn = 0.0u"N", shear_ok = false,
             stirrup_bar = 0, stirrup_spacing = 0.0u"m", vc_omitted = false,
             reason = "")
    grade = coupling_beam_grade(fy)
    cover = 1.5u"inch"
    dst = 0.375u"inch"
    db = 0.5u"inch"
    designed_bars = nothing
    d = h
    As_face = 0.0u"m^2"
    for _ in 1:3
        d = h - cover - dst - db / 2
        dp = cover + dst + db / 2
        if ustrip(u"m", d) <= ustrip(u"m", dp)
            return merge(blank, (reason = "the depth does not hold two faces of bars",))
        end
        local sized
        try
            sized = design_beam_flexure(max(Mu, 1.0u"N*m"), bw, d, fc, fy, Es;
                                        cover=cover, d_stirrup=dst, d_agg=DEFAULT_AGGREGATE_SIZE)
        catch err
            err isa ErrorException || rethrow()
            return merge(blank, (d = d, reason = "the section cannot develop the moment",))
        end
        As_try = sized.doubly_reinforced ?
            max(sized.As_tension, sized.As_compression) : sized.As_design
        As_face = max(As_try, beam_min_reinforcement(bw, d, fc, fy))
        designed_bars = select_beam_bars(As_face, bw; cover=cover, d_stirrup=dst,
                                         d_agg=DEFAULT_AGGREGATE_SIZE, fy=fy)
        new_db = bar_diameter(designed_bars.bar_size)
        abs(ustrip(u"m", new_db - db)) < 1e-4 && break
        db = new_db
    end
    designed_bars === nothing && return merge(blank, (reason = "no bars were selected",))
    # §18.6.4.2 (corpus: aci-318-19, PDF page 304): supported bars at most 14 in apart.
    for _ in 1:8
        ustrip(u"inch", designed_bars.spacing) <= 14.0 + 1e-6 && break
        more = (designed_bars.n_bars + 1) * bar_area(designed_bars.bar_size)
        designed_bars = select_beam_bars(more, bw; cover=cover, d_stirrup=dst,
                                         d_agg=DEFAULT_AGGREGATE_SIZE, fy=fy)
    end
    d = h - cover - dst - db / 2
    dp = cover + dst + db / 2
    As_face = designed_bars.As_provided
    ρ_limit = coupling_beam_rho_limit(fy)
    ρ = ustrip(u"m^2", As_face) / (ustrip(u"m", bw) * ustrip(u"m", d))
    dims = dimensions ? coupling_beam_dimensions(ℓn, h, bw, d) : nothing
    supported = ustrip(u"inch", designed_bars.spacing) <= 14.0 + 1e-6 && designed_bars.n_bars >= 2
    if !supported || ρ > ρ_limit + 1e-9
        return merge(blank, (dimensions = dims, bars = designed_bars, d = d, As = As_face,
                             ρ = ρ, ρ_limit = ρ_limit,
                             reason = supported ? "ρ exceeds §18.6.3.1" : "the bars do not fit at 14 in"))
    end
    start = coupling_beam_section_moment(bw, h, d, dp, As_face, fc, fy, Es, Nu_start; stress_factor=1.25)
    finish = coupling_beam_section_moment(bw, h, d, dp, As_face, fc, fy, Es, Nu_end; stress_factor=1.25)
    nominal = coupling_beam_section_moment(bw, h, d, dp, As_face, fc, fy, Es, max(Nu_start, Nu_end))
    if !start.converged || !finish.converged || !nominal.converged
        return merge(blank, (dimensions = dims, bars = designed_bars, d = d, As = As_face,
                             ρ = ρ, ρ_limit = ρ_limit, reason = "the axial force is outside the section"))
    end
    φMn = flexure_phi(nominal.εt) * nominal.Mn
    flexure_ok = ustrip(u"N*m", Mu) <= ustrip(u"N*m", φMn) + 1.0
    shear = coupling_beam_design_shear(start.Mn, finish.Mn, ℓn, Vg)
    hoops = coupling_beam_hoop_spacing(d, db, grade)
    Ag = bw * h
    omitted = coupling_beam_concrete_omitted(shear.V_eq, shear.Ve, max(Pu, 0.0u"N"), Ag, fc)
    Nu_vc = max(Pu, 0.0u"N")
    Vc = omitted ? 0.0u"N" : Vc_beam(bw, d, fc; λ=λ, Nu=Nu_vc, Ag=Ag)
    Vs = Vs_required(shear.Ve, Vc; φ=COUPLING_BEAM_SHEAR_PHI)
    Vs_cap = Vs_max_beam(bw, d, fc)
    shear_section = ustrip(u"N", Vs) <= ustrip(u"N", Vs_cap) + 1.0
    avs_min = min_shear_reinforcement(bw, fc, fyt)
    chosen_bar = 3
    chosen_s = hoops.spacing
    φVn = 0.0u"N"
    for size in (3, 4, 5)
        stir = design_stirrups(max(Vs, 1.0u"N"), d, fyt; bar_size=size)
        s_shear = stir.s_required
        av = 2 * bar_area(size)
        s_min = av / avs_min
        s_raw = min(hoops.spacing, s_shear, s_min)
        s = _coupling_half_inch(s_raw)
        ustrip(u"inch", s) <= 0 && (s = 0.5u"inch")
        chosen_bar = size
        chosen_s = s
        Vs_have = av * fyt * d / s
        φVn = COUPLING_BEAM_SHEAR_PHI * (Vc + Vs_have)
        ustrip(u"inch", s) >= 1.0 && break
    end
    shear_ok = shear_section && ustrip(u"N", shear.Ve) <= ustrip(u"N", φVn) * (1 + 1e-9)
    dims_ok = dims === nothing || (dims.span_ok && dims.width_ok)
    return (ok = flexure_ok && shear_ok && dims_ok,
            dimensions = dims, flexure_ok = flexure_ok, bars = designed_bars,
            d = d, As = As_face, ρ = ρ, ρ_limit = ρ_limit, φMn = φMn,
            Mpr_start = start.Mn, Mpr_end = finish.Mn,
            Ve = shear.Ve, φVn = φVn, shear_ok = shear_ok,
            stirrup_bar = chosen_bar, stirrup_spacing = chosen_s,
            vc_omitted = omitted, reason = "")
end

"""
    design_diagonal_coupling_beam(ℓn, h, bw, Vu, fc, fy, fyt) -> NamedTuple

§18.10.7.4. Each diagonal group is at least four bars in at least two layers.
The group's cage is at least bw/2 parallel to the wall thickness and bw/5
the other way, and it sits inside the 1½ in cover, which fixes α. φ is 0.85.
Vn uses Eq. (18.10.7.4) and is not taken above 10√f′c Acw.

# Citation
ACI 318-19 §18.10.7.4 (corpus: aci-318-19, PDF pages 333–334).
ACI 318-19 §21.2.4.4 (PDF page 398): φ = 0.85.
ACI 318-19 Table 20.5.1.3.1 (PDF page 384): 1½ in cover.
"""
function design_diagonal_coupling_beam(ℓn::Length, h::Length, bw::Length, Vu, fc, fy, fyt;
                                      cover::Length=1.5u"inch")
    blank = (ok = false, α = 0.0u"rad", Avd = 0.0u"m^2", bars = 0, bar = 0, layers = 0,
             φVn = 0.0u"N", tie = 0, tie_spacing = 0.0u"m", reason = "")
    ustrip(u"m", ℓn) > 0 || throw(ArgumentError("diagonal coupling beam: clear span must be positive"))
    ustrip(u"N", Vu) >= 0 || throw(ArgumentError("diagonal coupling beam: Vu is non-negative"))
    # §18.10.7.4(c) (corpus: aci-318-19, PDF page 333): cage at least bw/2 by bw/5.
    cage_x = bw / 2
    cage_y = bw / 5
    inset = cover + cage_y / 2
    arm = h - 2 * inset
    if ustrip(u"m", arm) <= 0
        return merge(blank, (reason = "the two diagonal groups do not fit in the depth",))
    end
    α = atan(ustrip(u"m", arm), ustrip(u"m", ℓn)) * u"rad"
    Acw = bw * h
    probe = coupling_beam_diagonal_strength(1.0u"inch^2", fy, α, fc, Acw)
    φcap = COUPLING_BEAM_DIAGONAL_PHI * probe.cap
    if ustrip(u"N", Vu) > ustrip(u"N", φcap) * (1 + 1e-9)
        return merge(blank, (α = α, φVn = φcap, reason = "Vu exceeds φ times 10√f′c Acw"))
    end
    sinα = sin(ustrip(u"rad", α))
    sinα > 0 || return merge(blank, (α = α, reason = "the diagonal angle is zero"))
    Avd_req = Vu / (COUPLING_BEAM_DIAGONAL_PHI * 2 * fy * sinα)
    layout = _diagonal_bar_layout(Avd_req, bw, cover)
    layout === nothing && return merge(blank, (α = α, Avd = Avd_req,
                                              reason = "four diagonal bars do not fit"))
    strength = coupling_beam_diagonal_strength(layout.area, fy, α, fc, Acw)
    φVn = COUPLING_BEAM_DIAGONAL_PHI * strength.Vn
    tie = _diagonal_tie(layout, bw, h, fc, fyt, cover, cage_x, cage_y)
    ok = ustrip(u"N", Vu) <= ustrip(u"N", φVn) * (1 + 1e-9) && tie.ok
    return (ok = ok, α = α, Avd = layout.area, bars = layout.bars, bar = layout.bar,
            layers = layout.layers, φVn = φVn, tie = tie.bar, tie_spacing = tie.spacing,
            reason = ok ? "" : "the diagonal confinement does not fit")
end

"Smallest bar, at least four, in at least two layers, that provides `Avd`."
function _diagonal_bar_layout(Avd, bw, cover)
    clear_of(db) = max(1.0u"inch", db, (4 / 3) * DEFAULT_AGGREGATE_SIZE)
    inner = bw - 2 * cover - 2 * 0.375u"inch"
    ustrip(u"m", inner) <= 0 && return nothing
    for size in rebar_sizes()
        Ab = bar_area(size)
        db = bar_diameter(size)
        n = max(4, ceil(Int, ustrip(u"m^2", Avd) / ustrip(u"m^2", Ab)))
        for layers in 2:6
            per = ceil(Int, n / layers)
            count = per * layers
            count < 4 && continue
            need = per * db + (per - 1) * clear_of(db)
            ustrip(u"m", need) <= ustrip(u"m", inner) + 1e-9 || continue
            area = count * Ab
            ustrip(u"m^2", area) + 1e-12 >= ustrip(u"m^2", Avd) || continue
            return (bar = size, bars = count, layers = layers, area = area, per = per, db = db)
        end
    end
    return nothing
end

"Hoop around one diagonal group. Spacing satisfies §18.7.5.3(d) and 6db."
function _diagonal_tie(layout, bw, h, fc, fyt, cover, cage_x, cage_y)
    db = layout.db
    per = layout.per
    gap = max(1.0u"inch", db, (4 / 3) * DEFAULT_AGGREGATE_SIZE)
    bars_x = per * db + (per - 1) * gap
    bars_y = layout.layers * db + (layout.layers - 1) * gap
    core_x = max(cage_x, bars_x + 2 * 0.375u"inch")
    core_y = max(cage_y, bars_y + 2 * 0.375u"inch")
    Ag = (core_x + 2 * cover) * (core_y + 2 * cover)
    Ach = core_x * core_y
    amount = boundary_transverse_amount(Ag, Ach, fc, fyt)
    hx = per == 1 ? db : (bars_x - db) / (per - 1)
    so = transverse_spacing_so(hx).so
    # §18.10.7.4(c) (corpus: aci-318-19, PDF page 333): not exceeding 6db, and §18.7.5.3(d).
    s_limit = min(6 * db, so, 14.0u"inch")
    bc = max(core_x, core_y)
    for size in (3, 4, 5)
        Ash = 2 * bar_area(size)
        s_amount = Ash / (amount.required * bc)
        s = _coupling_half_inch(min(s_amount, s_limit, 12.0u"inch"))
        ustrip(u"inch", s) < 1.0 && continue
        # Perimeter steel in each direction at least 0.002 bw s, spacing ≤ 12 in.
        perim = 0.002 * bw * s
        Ash >= perim || continue
        return (ok = true, bar = size, spacing = s)
    end
    return (ok = false, bar = 0, spacing = 0.0u"m")
end
