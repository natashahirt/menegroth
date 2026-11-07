# ==============================================================================
# ACI 318-19 column shear — ties sized so φVn ≥ Vu
# ==============================================================================
# One design for a tied or spiral column. Ordinary frame columns and the
# wall segments that ACI 318-19 §2.3 calls columns both call it. The section
# is not grown: a demand past Eq. (22.5.1.2) is a failed check.
#
# Citations are ACI 318-19, corpus source_id `aci-318-19`:
#   §21.2.1            p. 395   φ = 0.75 for shear
#   §10.5.1.1, §10.5.3.1 p. 159 φVn ≥ Vu for each factored combination
#   §10.6.2.1          p. 160   Av,min where Vu > 0.5φVc
#   §10.6.2.2          p. 160   Av,min = max(0.75√f'c, 50) bw s / fyt
#   §10.7.6.5.1–.2 and Table 10.7.6.5.2 p. 165
#   §22.5.1.1          p. 403   Vn = Vc + Vs
#   §22.5.1.2          p. 404   Vu ≤ φ(Vc + 8√f'c bw d)
#   Eq. (22.5.1.11)    p. 405   when both axes exceed 0.5, the sum ≤ 1.5
#   §22.5.2.2          p. 405   circular: bw = D, d = 0.8D
#   §22.5.3.1          p. 405   √f'c used for Vc shall not exceed 100 psi
#   §22.5.3.3          p. 405   fyt used for Vs shall not exceed §20.2.2.4
#                               (R22.5.3.3: 60,000 psi)
#   Table 22.5.5.1     p. 406   (a) when Av ≥ Av,min, (c) otherwise
#   §22.5.5.1.1–.3     p. 407   Vc ≤ 5λ√f'c bw d; Nu/(6Ag) ≤ 0.05f'c;
#                               λs = √(2/(1+d/10)) ≤ 1, d in inches
#   §22.5.8.5.3        p. 412   Vs = Av fyt d / s
#   §22.5.8.5.5–.6     p. 412   Av is the legs inside s; a circular tie or
#                               spiral counts two bar areas
#   §25.7.2.1          printed p. 499   tie spacing
#   §25.7.2.3          printed p. 499   crossties
# Torsion is not added. Commentary R10.5.4 says it is negligible for a
# building column, and no torsion demand is stored on the column result.
# Equation (b) of Table 22.5.5.1 is the optional detailed form. Equation (a)
# is the one used wherever Av ≥ Av,min.
# ==============================================================================

"""φ for column shear (ACI 318-19 §21.2.1, PDF p. 395)."""
const COLUMN_PHI_SHEAR = 0.75

"""Upper bound on fyt used to compute Vs (ACI 318-19 §22.5.3.3 and R22.5.3.3, PDF p. 405)."""
const _COLUMN_FYT_CAP_PSI = 60_000.0

"""
Bars between the corner bars that need their own crosstie.

`positions` and `db` are in one length unit. `clear_limit` is 6 in. in that
same unit (ACI 318-19 §25.7.2.3, printed p. 499): every corner and every
alternate bar, plus any bar more than 6 in. clear from a supported bar.
Returns how many supported bars sit strictly between the two corners.
"""
function _bars_needing_crosstie(positions::Vector{Float64}, db::Float64, clear_limit::Float64)
    n = length(positions)
    n <= 2 && return 0
    supported = falses(n)
    supported[1] = supported[n] = true
    for i in 3:2:(n - 1)
        supported[i] = true
    end
    for i in 2:(n - 1)
        supported[i] && continue
        gap = minimum(abs(positions[i] - positions[k]) for k in 1:n if supported[k]) - db
        gap > clear_limit + 1e-9 && (supported[i] = true)
    end
    return count(supported) - 2
end

"""
    column_tie_legs(section) -> NamedTuple

Legs of the tie set inside one spacing, `(x, y)`.

`x` resists shear parallel to the section width `b` (the horizontal legs).
`y` resists shear parallel to the depth `h` (the vertical legs). The
perimeter tie contributes two legs each way (ACI 318-19 §22.5.8.5.5, PDF
p. 412). Crossties across the width add to `x`; crossties across the depth
add to `y` (§25.7.2.3).
"""
function column_tie_legs(sec::RCColumnSection)
    bx = [ustrip(u"inch", bar.x) for bar in sec.bars]
    by = [ustrip(u"inch", bar.y) for bar in sec.bars]
    db = ustrip(u"inch", bar_diameter(infer_bar_size(first(sec.bars).As)))
    tol = 0.01
    xmin, xmax = extrema(bx)
    ymin, ymax = extrema(by)
    face(sel, coord) = Float64[coord[i] for i in eachindex(bx) if sel(i)]
    left = sort(face(i -> abs(bx[i] - xmin) <= tol, by))
    right = sort(face(i -> abs(bx[i] - xmax) <= tol, by))
    bottom = sort(face(i -> abs(by[i] - ymin) <= tol, bx))
    top = sort(face(i -> abs(by[i] - ymax) <= tol, bx))
    # Crossties across the depth (from the top and bottom faces) are vertical
    # legs. Crossties across the width are horizontal legs.
    n_v = max(_bars_needing_crosstie(bottom, db, 6.0), _bars_needing_crosstie(top, db, 6.0))
    n_h = max(_bars_needing_crosstie(left, db, 6.0), _bars_needing_crosstie(right, db, 6.0))
    return (x = 2 + n_h, y = 2 + n_v)
end

# √f'c for Vc is capped; Nu/(6Ag) is capped high and is not raised when the
# column is in tension (§22.5.3.1, §22.5.5.1.2).
function _shear_stress_caps(fc_psi::Float64, Nu_lb::Float64, Ag_in2::Float64)
    sqrt_raw = sqrt(max(fc_psi, 0.0))
    sqrt_cap = min(sqrt_raw, 100.0)
    nu = Nu_lb / (6.0 * Ag_in2)
    nu = min(nu, 0.05 * max(fc_psi, 0.0))
    return (sqrt_raw = sqrt_raw, sqrt_cap = sqrt_cap, nu = nu)
end

# Vc in pounds after the zero floor and the §22.5.5.1.1 ceiling.
function _vc_pounds(vc_psi::Float64, λ::Float64, sqrt_cap::Float64, bw::Float64, d::Float64)
    capped = min(max(vc_psi, 0.0), 5.0 * λ * sqrt_cap)
    return capped * bw * d
end

"""
Equation (a) of Table 22.5.5.1, in pounds, with the §22.5.3.1 and §22.5.5.1
limits. `Vn_limit_lb` is `Vc + 8√f'c bw d` from Eq. (22.5.1.2). The 8√f'c
term is outside Vc, so it keeps the uncapped root. The §22.5.3.2 exception
that lets √f'c exceed 100 psi is for beams and joists, not columns.
"""
function column_equation_a_pounds(bw_in::Real, d_in::Real, Ag_in2::Real, fc_psi::Real,
                                  Nu_lb::Real; λ::Real = 1.0)
    (bw_in > 0 && d_in > 0 && Ag_in2 > 0) || throw(ArgumentError(
        "column shear: bw, d, and Ag must be positive."))
    caps = _shear_stress_caps(Float64(fc_psi), Float64(Nu_lb), Float64(Ag_in2))
    lam = Float64(λ)
    Vc = _vc_pounds(2.0 * lam * caps.sqrt_cap + caps.nu, lam, caps.sqrt_cap,
                    Float64(bw_in), Float64(d_in))
    # Eq. (22.5.1.2). √f'c here is not the Vc term §22.5.3.1 caps.
    limit = Vc + 8.0 * caps.sqrt_raw * Float64(bw_in) * Float64(d_in)
    return (Vc_lb = Vc, Vn_limit_lb = limit)
end

# Equation (c): Av below Av,min. λs uses d in inches (§22.5.5.1.3).
function _vc_equation_c(bw, d, λ, ρw, caps)
    λs = min(sqrt(2.0 / (1.0 + d / 10.0)), 1.0)
    vc_psi = 8.0 * λ * λs * cbrt(max(ρw, 0.0)) * caps.sqrt_cap + caps.nu
    return _vc_pounds(vc_psi, λ, caps.sqrt_cap, bw, d)
end

# As in the third of the depth farthest from one face, then the smaller of
# the two faces. Commentary to §22.5.5.1 (PDF p. 407) allows that As when the
# compression face is not known. `along` is :x for the width and :y for the depth.
function _rho_w(section, along::Symbol, bw::Float64, d::Float64)
    depth = section isa RCCircularSection ? ustrip(u"inch", section.D) :
            ustrip(u"inch", along === :x ? section.b : section.h)
    third = depth / 3.0
    low = 0.0
    high = 0.0
    for bar in section.bars
        p = ustrip(u"inch", along === :x ? bar.x : bar.y)
        A = ustrip(u"inch^2", bar.As)
        p < third && (low += A)
        p > 2.0 * third && (high += A)
    end
    return min(low, high) / (bw * d)
end

# Loosest spiral pitch that meets Eq. (25.7.3.3) with 1 in. to 3 in. clear
# (§25.7.3). Returns `(bar, pitch_in)`, or nothing when no No. 3–No. 5 does.
function _spiral_pitch(sec::RCCircularSection, fc_psi::Float64, fyt_psi::Float64)
    D = ustrip(u"inch", sec.D)
    cover = ustrip(u"inch", sec.cover)
    Dc = D - 2.0 * cover
    (Dc > 0 && fyt_psi > 0) || return nothing
    Ag = π * D^2 / 4
    Ach = π * Dc^2 / 4
    Ach > 0 && Ag > Ach || return nothing
    ρs = 0.45 * (Ag / Ach - 1.0) * fc_psi / fyt_psi
    ρs > 0 || return nothing
    for bsp in 3:5
        dsp = ustrip(u"inch", bar_diameter(bsp))
        Asp = ustrip(u"inch^2", bar_area(bsp))
        s = min(4.0 * Asp / (Dc * ρs), 3.0 + dsp)
        s - dsp >= 1.0 - 1e-9 && return (bar = bsp, pitch = s)
    end
    return nothing
end

struct _ColShearAxis
    bw::Float64
    d::Float64
    Av::Float64
    av_s::Float64          # Av,min / s  (in²/in)
    Vc_a::Float64          # pounds
    Vc_c::Float64
    Vs_coeff::Float64      # Av fyt d, so Vs = Vs_coeff / s
    Vs_max::Float64        # 8√f'c bw d, pounds
    sqrt_raw::Float64
    Vu::Float64            # pounds
end

function _axis_at(ax::_ColShearAxis, s::Float64)
    # A tighter spacing meets Av,min. Equation (a) is then the applicable Vc.
    meets = ax.Av / s + 1e-12 >= ax.av_s
    Vc = meets ? ax.Vc_a : ax.Vc_c
    Vs = min(ax.Vs_coeff / s, ax.Vs_max)
    return (
        Vc = Vc,
        Vs = Vs,
        ϕVn = COLUMN_PHI_SHEAR * (Vc + Vs),
        ϕVlimit = COLUMN_PHI_SHEAR * (Vc + ax.Vs_max),
        meets = meets,
    )
end

# Table 10.7.6.5.2. The 4√f'c threshold is not the Vc root that §22.5.3.1 caps.
function _table_smax(ax::_ColShearAxis, s::Float64)
    Vs = min(ax.Vs_coeff / s, ax.Vs_max)
    if Vs <= 4.0 * ax.sqrt_raw * ax.bw * ax.d
        return min(ax.d / 2.0, 24.0)
    else
        return min(ax.d / 4.0, 12.0)
    end
end

function _apply_table(axes, s::Float64)
    cap = s
    for ax in axes
        cap = min(cap, _table_smax(ax, s))
    end
    return cap
end

# Eq. (22.5.1.11): only when EACH axis exceeds one half. Force ratios equal
# the stress ratios the equation is written in.
function _governed_ratio(axes, s::Float64)
    rs = ntuple(i -> axes[i].Vu / _axis_at(axes[i], s).ϕVn, length(axes))
    r = maximum(rs)
    if all(>(0.5), rs)
        r = max(r, sum(rs) / 1.5)
    end
    return (ratio = r, rx = rs[1], ry = rs[2])
end

function _design_spacing(axes, s_support::Float64)
    s = s_support
    section_ok = true
    # §10.6.2.1 uses the Vc of the equation that applies at the spacing we
    # would otherwise use. Below Av,min that is equation (c). A demand past
    # half of it has to reach Av,min, and equation (a) then applies. The
    # requirement is judged on that first Vc: once the ties are required,
    # Table 10.7.6.5.2 still applies after equation (a) raises Vc.
    shear_required = false
    for ax in axes
        meets = ax.Av / s_support + 1e-12 >= ax.av_s
        Vc0 = meets ? ax.Vc_a : ax.Vc_c
        if ax.Vu > 0.5 * COLUMN_PHI_SHEAR * Vc0
            shear_required = true
            meets || (s = min(s, ax.Av / ax.av_s))
        end
    end
    for ax in axes
        st = _axis_at(ax, s)
        if ax.Vu > st.ϕVlimit
            section_ok = false
            s = min(s, ax.Vs_coeff / ax.Vs_max)
        elseif ax.Vu > st.ϕVn
            Vs_req = ax.Vu / COLUMN_PHI_SHEAR - st.Vc
            s = min(s, ax.Vs_coeff / Vs_req)
        end
    end
    # Table 10.7.6.5.2 sizes shear reinforcement. §10.7.6.5.1 applies it
    # when that reinforcement is required. §10.6.2.1 requires it where
    # Vu > 0.5φVc of the equation in use. Below that, the ties are the
    # §25.7.2.1 bar-support ties and this table does not close them up.
    # Vs and the table limit depend on each other, so the pass is repeated
    # once a larger Vs crosses 4√f'c bw d.
    if shear_required
        s = _apply_table(axes, s)
        s = _apply_table(axes, s)
    end
    governed = _governed_ratio(axes, s)
    if governed.rx > 0.5 && governed.ry > 0.5 && governed.ratio > 1.0
        s_floor = min(s, minimum(ax.Vs_coeff / ax.Vs_max for ax in axes))
        if _governed_ratio(axes, s_floor).ratio > 1.0
            s = s_floor
            section_ok = false
        else
            # Largest spacing that still satisfies the sum. `lo` is known
            # to pass and `hi` is known to fail, so a passing midpoint moves
            # the loose bound up.
            lo, hi = s_floor, s
            for _ in 1:48
                mid = (lo + hi) / 2
                if _governed_ratio(axes, mid).ratio <= 1.0
                    lo = mid
                else
                    hi = mid
                end
            end
            s = lo
        end
        shear_required && (s = _apply_table(axes, s))
    end
    return (s = max(s, 1e-6), section_ok = section_ok)
end

"""
    design_column_shear(section, Vu_x, Vu_y, Nu, material) -> NamedTuple

Size the tie (or spiral) spacing so both axes satisfy ACI 318-19 §10.5.3.1.

`Vu_x` is the factored shear parallel to the section width `b`. `Vu_y` is
parallel to the depth `h`. For a circle the two widths are the diameter and
`d = 0.8D` (§22.5.2.2). `Nu` is compression-positive.

The spacing starts at §25.7.2.1 (and, for a spiral, the Eq. 25.7.3.3 pitch)
and is tightened for Av,min (§10.6.2), for Vs = Av fyt d / s (§22.5.8.5.3),
for Table 10.7.6.5.2 when that shear reinforcement is required, and for
Eq. (22.5.1.11) when both axes exceed one half.
`ok` is false when the demand is past φ(Vc + 8√f'c bw d). The concrete
section is left as it was given.

`ratio` is the largest of the two axis ratios and, when both exceed one
half, `(ratio_x + ratio_y) / 1.5`. `clause` names the tie size and the
spacing, in inches, so a later note can quote it.
"""
function design_column_shear(section::Union{RCColumnSection, RCCircularSection},
                              Vu_x, Vu_y, Nu, material::ReinforcedConcreteMaterial)
    isempty(section.bars) && throw(ArgumentError(
        "column shear: the section has no longitudinal bars."))
    fc_psi = ustrip(u"psi", material.concrete.fc′)
    fyt_psi = ustrip(u"psi", material.transverse.Fy)
    fyt_psi > 0 || throw(ArgumentError("column shear: fyt must be positive."))
    # §22.5.3.3 caps the fyt that Vs is allowed to use. The same cap is used
    # in Av,min so a grade above 60 ksi does not shrink the minimum.
    fyt_vs = min(fyt_psi, _COLUMN_FYT_CAP_PSI)
    λ = Float64(material.concrete.λ)
    Nu_lb = ustrip(u"lbf", Nu)
    Vu_x_lb = abs(ustrip(u"lbf", Vu_x))
    Vu_y_lb = abs(ustrip(u"lbf", Vu_y))

    long_bar = infer_bar_size(first(section.bars).As)
    circular = section isa RCCircularSection
    tie = circular ? (long_bar >= 11 ? 4 : 3) : section.tie_bar_size
    db_long = ustrip(u"inch", bar_diameter(long_bar))
    least = circular ? ustrip(u"inch", section.D) :
            min(ustrip(u"inch", section.b), ustrip(u"inch", section.h))
    # §25.7.2.1, duplicated here because the detailing copy is loaded later.
    s_support = min(16.0 * db_long, 48.0 * ustrip(u"inch", bar_diameter(tie)), least)
    if circular && section.tie_type === :spiral
        pitch = _spiral_pitch(section, fc_psi, fyt_psi)
        if pitch !== nothing
            tie = pitch.bar
            s_support = min(s_support, pitch.pitch)
        end
    end
    s_support > 0 || throw(ArgumentError("column shear: the tie spacing is not positive."))
    Ab = ustrip(u"inch^2", bar_area(tie))

    if circular
        D = ustrip(u"inch", section.D)
        bw_x = bw_y = D
        d_x = d_y = 0.8 * D                 # §22.5.2.2
        Av_x = Av_y = 2.0 * Ab              # §22.5.8.5.6
        Ag = π * D^2 / 4
    else
        b = ustrip(u"inch", section.b)
        h = ustrip(u"inch", section.h)
        # Shear parallel to b is carried across the depth h, and d is the
        # effective depth measured along b. Shear parallel to h swaps them.
        bw_x = h
        d_x = ustrip(u"inch", effective_depth(section; axis = :y))
        bw_y = b
        d_y = ustrip(u"inch", effective_depth(section; axis = :x))
        legs = column_tie_legs(section)
        Av_x = legs.x * Ab
        Av_y = legs.y * Ab
        Ag = b * h
    end
    (d_x > 0 && d_y > 0 && Ag > 0) || throw(ArgumentError(
        "column shear: the section has no effective depth."))

    caps = _shear_stress_caps(fc_psi, Nu_lb, Ag)
    function axis(bw, d, Av, along, Vu)
        Vc_a = column_equation_a_pounds(bw, d, Ag, fc_psi, Nu_lb; λ = λ).Vc_lb
        Vc_c = _vc_equation_c(bw, d, λ, _rho_w(section, along, bw, d), caps)
        av_s = max(0.75 * caps.sqrt_raw, 50.0) * bw / fyt_vs
        Vs_max = 8.0 * caps.sqrt_raw * bw * d
        return _ColShearAxis(bw, d, Av, av_s, Vc_a, Vc_c, Av * fyt_vs * d, Vs_max,
                             caps.sqrt_raw, Vu)
    end
    axes = (
        axis(bw_x, d_x, Av_x, :x, Vu_x_lb),
        axis(bw_y, d_y, Av_y, :y, Vu_y_lb),
    )
    chosen = _design_spacing(axes, s_support)
    s = chosen.s
    gov = _governed_ratio(axes, s)
    st_x = _axis_at(axes[1], s)
    st_y = _axis_at(axes[2], s)
    section_ok = chosen.section_ok &&
                 Vu_x_lb <= st_x.ϕVlimit + 1e-4 &&
                 Vu_y_lb <= st_y.ϕVlimit + 1e-4
    ratio = gov.ratio
    ok = section_ok && ratio <= 1.0 + 1e-8
    eq = if st_x.meets && st_y.meets
        "(a)"
    elseif !st_x.meets && !st_y.meets
        "(c)"
    else
        "(a)/(c)"
    end
    clause = "ACI 318-19 §10.5.3.1 / Table 22.5.5.1$(eq); No. $(tie) ties at $(round(s; digits = 2)) in"
    if !section_ok
        clause *= "; section exceeds Eq. (22.5.1.2)"
    elseif !ok
        clause *= "; Eq. (22.5.1.11)"
    end
    to_N = u"lbf"
    return (
        ok = ok,
        section_ok = section_ok,
        ratio = ratio,
        ratio_x = gov.rx,
        ratio_y = gov.ry,
        interaction_ratio = (gov.rx > 0.5 && gov.ry > 0.5) ? (gov.rx + gov.ry) / 1.5 : 0.0,
        ϕVn_x = st_x.ϕVn * to_N,
        ϕVn_y = st_y.ϕVn * to_N,
        ϕVn_limit_x = st_x.ϕVlimit * to_N,
        ϕVn_limit_y = st_y.ϕVlimit * to_N,
        spacing = s * u"inch",
        tie_bar_size = tie,
        clause = clause,
    )
end
