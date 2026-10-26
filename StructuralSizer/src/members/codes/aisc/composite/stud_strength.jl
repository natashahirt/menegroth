# ==============================================================================
# Steel Headed Stud Anchor Strength — AISC 360-22 §I8
# ==============================================================================
# Eq. I8-1 and the §I8.2a Rg/Rp table were compared with AISC 360-16 and match.
# Cite 360-22 (corpus: aisc-360-22, PDF pp. 181–183). The same numbers are in
# 360-16 §I8 (corpus: aisc-360-16, PDF pp. 160–163). Channel anchors (§I8.2b)
# and composite components (§I8.3) are not implemented.
# Note: This module covers steel anchors in **composite beams** (§I8.2). Steel
# anchors in composite **components** (encased/filled columns, walls, coupling
# beams) follow §I8.3, which has *different* length and edge-distance rules and
# is not implemented here.

# ==============================================================================
# Single-Stud Nominal Shear Strength — §I8.2a (Eq. I8-1)
# ==============================================================================

"""
    get_Qn(anchor::HeadedStudAnchor, slab::SolidSlabOnBeam) -> Force

Nominal shear strength of one steel headed stud anchor in a **solid slab** per
AISC 360-16 §I8.2a, Eq. I8-1 (corpus aisc-360-16, p. 161):

    Qn = 0.5 · Asa · √(fc′ · Ec)  ≤  Rg · Rp · Asa · Fu

For solid slabs: `Rg = 1.0`, `Rp = 0.75` (§I8.2a User Note table, p. 163,
"No decking" row).
"""
function get_Qn(anchor::HeadedStudAnchor, slab::SolidSlabOnBeam)
    Asa = π / 4 * anchor.d_sa^2
    Rg, Rp = _Rg_Rp(anchor, slab)

    Qn_concrete = 0.5 * Asa * sqrt(slab.fc′ * slab.Ec)
    Qn_steel    = Rg * Rp * Asa * anchor.Fu
    return min(Qn_concrete, Qn_steel)
end

"""
    get_Qn(anchor::HeadedStudAnchor, slab::DeckSlabOnBeam) -> Force

Nominal shear strength of one steel headed stud anchor in a **formed-deck
composite slab** per AISC 360-16 §I8.2a, Eq. I8-1 (corpus aisc-360-16,
pp. 161–163). The deck modifies `Rg` and `Rp` via the §I8.2a User Note table.
"""
function get_Qn(anchor::HeadedStudAnchor, slab::DeckSlabOnBeam)
    Asa = π / 4 * anchor.d_sa^2
    Rg, Rp = _Rg_Rp(anchor, slab)

    Qn_concrete = 0.5 * Asa * sqrt(slab.fc′ * slab.Ec)
    Qn_steel    = Rg * Rp * Asa * anchor.Fu
    return min(Qn_concrete, Qn_steel)
end

# ==============================================================================
# Rg and Rp Factors — §I8.2a User Note table (corpus aisc-360-16, p. 163)
# ==============================================================================

"""`Rg = 1.0`, `Rp = 0.75` for headed studs in a solid slab welded directly to
the steel shape (§I8.2a User Note, "No decking" row)."""
function _Rg_Rp(::HeadedStudAnchor, ::SolidSlabOnBeam)
    return (1.0, 0.75)
end

"""
Rg and Rp for headed studs in a formed-deck composite slab, per the
AISC 360-16 §I8.2a User Note table (corpus aisc-360-16, p. 163):

- **Parallel deck**:
    `wr/hr ≥ 1.5` → `Rg = 1.00`, `Rp = 0.75`
    `wr/hr < 1.5` → `Rg = 0.85`, `Rp = 0.75`
- **Perpendicular deck** (studs per rib `n_per_row`):
    1 stud  → `Rg = 1.00`
    2 studs → `Rg = 0.85`
    ≥3 studs→ `Rg = 0.70`
    `Rp = 0.6` is used as the default (per User Note footnote [b], may be
    0.75 when `e_mid_ht ≥ 2 in.`); `e_mid_ht` is not currently modeled, so
    the conservative 0.6 is taken.
"""
function _Rg_Rp(anchor::HeadedStudAnchor, slab::DeckSlabOnBeam)
    if slab.deck_orientation === :parallel
        ratio = ustrip(slab.wr / slab.hr)
        return ratio >= 1.5 ? (1.0, 0.75) : (0.85, 0.75)
    else  # :perpendicular
        n = anchor.n_per_row
        # ENGINEERING JUDGMENT: Rp = 0.6 (perpendicular default). Footnote [b]
        # in the §I8.2a User Note allows 0.75 when e_mid_ht ≥ 2 in.; we don't
        # model e_mid_ht here, so we conservatively keep 0.6.
        Rp = 0.6
        Rg = n == 1 ? 1.0 :
             n == 2 ? 0.85 :
             0.7
        return (Rg, Rp)
    end
end

# ==============================================================================
# Stud Validation Checks — §I8.1, §I8.2, §I8.2d (corpus aisc-360-16, pp. 160–163)
# ==============================================================================

"""
    validate_stud_diameter(anchor::HeadedStudAnchor, tf) -> nothing

AISC 360-16 §I8.1 (corpus aisc-360-16, p. 160): the stud diameter `d_sa`
shall not be greater than 2.5 times the base-metal thickness to which the
stud is welded, **unless welded to a flange directly over a web**. Throws
`ArgumentError` if `d_sa > 2.5·tf` and the over-the-web exception is not
asserted.
"""
function validate_stud_diameter(anchor::HeadedStudAnchor, tf; slab=nothing)
    # AISC 360-22 §I8.1 (corpus: aisc-360-22, PDF p. 181). Same limit in
    # AISC 360-16 §I8.1 (corpus: aisc-360-16, PDF p. 160).
    d_in = ustrip(u"inch", uconvert(u"inch", anchor.d_sa))
    if d_in > 0.75 + 1e-6
        solid = slab isa SolidSlabOnBeam
        allowed = solid && (abs(d_in - 0.875) < 1e-3 || abs(d_in - 1.0) < 1e-3)
        allowed || throw(ArgumentError(
            "Stud diameter $(anchor.d_sa) exceeds 3/4 in. AISC 360-22 §I8.1 " *
            "permits 7/8 in. and 1 in. only for shear transfer in a solid slab."))
    end
    d_max = 2.5 * tf
    if anchor.d_sa > d_max
        throw(ArgumentError(
            "Stud diameter $(anchor.d_sa) exceeds 2.5·tf = $(d_max) " *
            "(AISC 360-22 §I8.1). Use a smaller stud or verify the stud is welded directly over the web."))
    end
    return nothing
end

"""
    validate_stud_length(anchor::HeadedStudAnchor, slab::AbstractSlabOnBeam) -> nothing

AISC 360-16 §I8.2 (corpus aisc-360-16, p. 161): for **steel anchors in
composite beams**, the stud length (base to top of head, after installation)
shall not be less than `4·d_sa`. Also enforces a `½ in. (13 mm)` minimum
clear concrete cover above the stud head, consistent with AISC §I3.2c
deck/cover guidance.

Note: §I8.3 (composite **components** — encased/filled columns, walls,
coupling beams) imposes longer minima (e.g. `5·d_sa` for shear-only in
normal-weight concrete, `7·d_sa` for lightweight, `8·d_sa` for tension).
Those rules do not apply to composite beams and are checked elsewhere.
"""
function validate_stud_length(anchor::HeadedStudAnchor, slab::AbstractSlabOnBeam)
    # §I8.2 (composite beams): l_sa ≥ 4·d_sa.
    min_length = 4 * anchor.d_sa
    if anchor.l_sa < min_length
        throw(ArgumentError(
            "Stud length $(anchor.l_sa) < 4·d_sa = $(min_length) (AISC 360-16 §I8.2)."))
    end
    # ENGINEERING JUDGMENT: ½-in. clear cover above stud head. Not an explicit
    # AISC 360-16 number for composite beams; matches common practice and is
    # consistent with ACI/AISC deck-cover guidance.
    min_cover = 0.5u"inch"
    available_depth = _available_embed_depth(slab)
    if anchor.l_sa + min_cover > available_depth
        throw(ArgumentError(
            "Stud length $(anchor.l_sa) + ½ in. cover exceeds available slab depth $(available_depth)."))
    end
    return nothing
end

_available_embed_depth(slab::SolidSlabOnBeam) = slab.t_slab
_available_embed_depth(slab::DeckSlabOnBeam)  = slab.t_slab + slab.hr  # concrete above deck + rib

"""
    check_stud_spacing(anchor::HeadedStudAnchor, slab::AbstractSlabOnBeam, n_studs, L_half) -> nothing

Verify steel-headed-stud longitudinal spacing for a composite **beam** per
AISC 360-16 §I8.2d (corpus aisc-360-16, p. 163):

- (d) **Minimum** center-to-center spacing is 4·d_sa in any direction. For
      composite beams **not** containing anchors located within formed steel
      deck oriented perpendicular to the beam span, an additional minimum of
      6·d_sa applies along the longitudinal axis of the beam.
- (e) **Maximum** center-to-center spacing of steel anchors shall not exceed
      `8 · (total slab thickness)` or `36 in. (900 mm)`. For deck slabs,
      "total slab thickness" is `hr + t_slab` (concrete above deck + rib),
      not just `t_slab`.

`n_studs` is the total studs on ONE side of the point of maximum moment;
`L_half` is the corresponding flexural span (e.g., half the simple-span beam
for symmetric loading).
"""
function check_stud_spacing(anchor::HeadedStudAnchor, slab::AbstractSlabOnBeam,
                            n_studs::Int, L_half)
    n_rows = n_studs <= 0 ? 0 : ceil(Int, n_studs / anchor.n_per_row)
    # One anchor has no neighbor. The shear span is then the center-to-center
    # gap that §I8.2d(e) limits, so a single stud on a long span does not pass.
    spacing = n_rows <= 0 ? L_half : L_half / n_rows

    # §I8.2d(d): minimum spacing.
    # Long-axis 6·d_sa applies when there's no perpendicular deck. Without
    # finer info we apply the longer 6·d_sa as the conservative default.
    s_min_long_axis = isa(slab, DeckSlabOnBeam) && slab.deck_orientation === :perpendicular ?
                      4 * anchor.d_sa : 6 * anchor.d_sa
    s_min = s_min_long_axis
    if spacing < s_min
        @warn "Stud longitudinal spacing $(spacing) < minimum $(s_min) " *
              "(AISC 360-22 §I8.2d(d)). Consider fewer studs or multi-row layout."
    end

    # §I8.2d(e): maximum spacing — uses TOTAL slab thickness, hr + t_slab for deck.
    s_max = min(8 * _total_slab_depth(slab), 36.0u"inch")
    if spacing > s_max
        @warn "Stud longitudinal spacing $(spacing) > maximum $(s_max) " *
              "(AISC 360-22 §I8.2d(e), 8·(total slab thickness) ≤ 36 in.). Add more studs."
    end

    return nothing
end

"""
    check_stud_edge_distance(section, anchor, slab) -> Bool

`true` when `anchor.n_per_row` studs can sit on the flange and meet AISC 360-22
§I8.2d(b) (corpus: aisc-360-22, PDF p. 183): at least 1 in. (25 mm) of lateral
concrete cover perpendicular to the shear force, except anchors installed in
the ribs of a formed steel deck.

`edge_dist_left` and `edge_dist_right` are distances from the beam centerline
to a transverse slab edge. §I8.2d(c) — 8 in. normal weight, 10 in. lightweight,
from the stud center to a free edge in the direction of the shear force — is a
longitudinal edge. This model has no such edge, so (c) is not applied here.
"""
function check_stud_edge_distance(section::ISymmSection, anchor::HeadedStudAnchor,
                                  slab::AbstractSlabOnBeam)
    return _transverse_studs_fit(section, anchor, slab)
end

"""
    check_stud_deck_projection(anchor::HeadedStudAnchor, slab::DeckSlabOnBeam) -> nothing

AISC 360-16 §I3.2c(b) (corpus aisc-360-16, p. 167): steel headed stud anchors
welded through formed steel deck shall extend not less than **1.5 in.
(38 mm) above the top of the steel deck after installation**. Emits a
`@warn` if the projection above the deck is less than this minimum.
"""
function check_stud_deck_projection(anchor::HeadedStudAnchor, slab::DeckSlabOnBeam)
    projection = anchor.l_sa - slab.hr
    min_projection = 1.5u"inch"
    if projection < min_projection
        @warn "Stud projection above deck $(projection) < §I3.2c(b) minimum $(min_projection). " *
              "Increase l_sa or use shallower deck."
    end
    return nothing
end

# Solid slabs are not subject to the deck-projection rule.
check_stud_deck_projection(::HeadedStudAnchor, ::SolidSlabOnBeam) = nothing

# ==============================================================================
# Anchor schedule — §I8.2c count, §I8.2d spacing, Commentary ductility
# ==============================================================================

"""Center-to-center limits, AISC 360-22 §I8.2d(d) and (e) (corpus: aisc-360-22,
PDF p. 183). The longitudinal minimum is 6 diameters unless the anchors sit in
deck ribs oriented perpendicular to the beam, in which case it is 4 diameters."""
function _stud_spacing_limits(anchor::HeadedStudAnchor, slab::AbstractSlabOnBeam)
    perpendicular = slab isa DeckSlabOnBeam && slab.deck_orientation === :perpendicular
    s_min = perpendicular ? 4 * anchor.d_sa : 6 * anchor.d_sa
    s_max = min(8 * _total_slab_depth(slab), 36.0u"inch")
    return (uconvert(u"m", s_min), uconvert(u"m", s_max))
end

"""Row bounds so center-to-center spacing `L / n` lies between `s_min` and `s_max`.

Uniform distribution over the shear span uses `n` equal spaces (§I8.2d(a),
PDF p. 183). That is the average spacing the commentary uses for the
16 kip/ft harbor. A single anchor is allowed only when the shear span itself
does not exceed `s_max`.
"""
function _row_bounds(L, s_min, s_max)
    Ls = ustrip(u"m", uconvert(u"m", L))
    smin = ustrip(u"m", uconvert(u"m", s_min))
    smax = ustrip(u"m", uconvert(u"m", s_max))
    n_max = smin > 0 ? floor(Int, Ls / smin) : typemax(Int) ÷ 4
    if n_max < 1
        n_max = Ls <= smax + 1e-9 ? 1 : 0
    end
    n_min = smax > 0 ? max(ceil(Int, Ls / smax), 1) : 1
    n_max == 1 && n_min > 1 && (n_max = 0)
    return (n_min, n_max)
end

function _combined_row_bounds(spans, s_min, s_max)
    n_min, n_max = 1, typemax(Int) ÷ 4
    for L in spans
        lo, hi = _row_bounds(L, s_min, s_max)
        n_min = max(n_min, lo)
        n_max = min(n_max, hi)
    end
    return (n_min, n_max)
end

"""
    shear_connection_ductile(L_beam, degree, q_avg; slip_checked=false) -> Bool

AISC 360-22 §I3.2d.1 requires the ductility (slip capacity) of the shear
connection to be considered (corpus: aisc-360-22, PDF p. 171). Commentary
§I3.2d (PDF p. 511) says a beam loaded uniformly, or by equally spaced
concentrated loads, need not be checked further when any one of these holds:

  (a) span not exceeding 30 ft (9.1 m);
  (b) degree of composite action at least 50%;
  (c) average nominal shear-connector capacity at least 16 kip/ft (230 kN/m)
      along the shear span.

`slip_checked` stands in for the commentary's direct nonlinear model. This
function does not run that model.
"""
function shear_connection_ductile(L_beam, degree::Real, q_avg; slip_checked::Bool=false)
    slip_checked && return true
    uconvert(u"m", L_beam) <= uconvert(u"m", 30.0u"ft") && return true
    degree >= 0.50 && return true
    return uconvert(u"N/m", q_avg) >= uconvert(u"N/m", 16.0u"kip" / u"ft")
end

"""Allowable transverse coordinates of a stud center, in meters, beam centerline
at zero, left negative.

AISC 360-22 §I8.2d(b) (corpus: aisc-360-22, PDF p. 183): 1 in. clear lateral
concrete cover perpendicular to the shear force, except anchors in the ribs of
formed steel deck. §I8.2d(d): centers at least four diameters apart. The cover
is clear distance to the concrete edge, not to the flange tip.

ENGINEERING JUDGMENT: the shank is welded to the flange, so a center lies at
least `d_sa/2` inside each flange tip. §I8.2d does not state that inset.
"""
function _stud_center_limits(section::ISymmSection, anchor::HeadedStudAnchor,
                             slab::AbstractSlabOnBeam)
    d = ustrip(u"m", anchor.d_sa)
    bf = ustrip(u"m", section.bf)
    y_lo = -bf / 2 + d / 2
    y_hi =  bf / 2 - d / 2
    if !(slab isa DeckSlabOnBeam)
        cover = ustrip(u"m", 1.0u"inch")
        if slab.edge_dist_left !== nothing
            ed = ustrip(u"m", slab.edge_dist_left)
            y_lo = max(y_lo, -ed + cover + d / 2)
        end
        if slab.edge_dist_right !== nothing
            ed = ustrip(u"m", slab.edge_dist_right)
            y_hi = min(y_hi, ed - cover - d / 2)
        end
    end
    return (y_lo, y_hi)
end

"""`n_per_row` studs fit on the flange at four diameters and, on a solid slab,
keep 1 in. clear cover to each transverse slab edge."""
function _transverse_studs_fit(section::ISymmSection, anchor::HeadedStudAnchor,
                               slab::AbstractSlabOnBeam)
    y_lo, y_hi = _stud_center_limits(section, anchor, slab)
    y_hi + 1e-9 >= y_lo || return false
    n = anchor.n_per_row
    n <= 1 && return true
    need = (n - 1) * 4 * ustrip(u"m", anchor.d_sa)
    return (y_hi - y_lo) + 1e-9 >= need
end

function _lowest_passing(lo::Int, hi::Int, pred)
    hi < lo && return nothing
    pred(lo) && return lo
    pred(hi) || return nothing
    while lo + 1 < hi
        mid = (lo + hi) ÷ 2
        if pred(mid)
            hi = mid
        else
            lo = mid
        end
    end
    return hi
end

"""
    design_shear_anchors(section, material, slab, anchor, b_eff, L_beam, Mu;
                         ϕMn_steel, shear_spans=nothing, slip_checked=false,
                         I_need=nothing, extra_ok=nothing, ϕ=0.9)
        -> NamedTuple

Smallest stud layout on one side of the maximum moment whose composite
strength meets `Mu`, whose center-to-center spacing meets §I8.2d, and whose
shear connection meets the commentary ductility harbors when the steel
section alone does not.

`shear_spans` is the distance from the maximum moment to the zero moment on
each side (§I8.2c, PDF p. 183). When it is omitted, both sides are `L_beam/2`.
That is the simple-span diagram. It is engineering judgment for any other
moment diagram.

The horizontal shear used in the strength is `min(n Qn, Cf)` (§I3.2d.1,
Eqs. I3-1a through I3-1c, PDF p. 171). The 16 kip/ft average uses `n Qn`
without that cap, because the commentary is counting connector capacity.
"""
function design_shear_anchors(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                              anchor::HeadedStudAnchor, b_eff, L_beam, Mu;
                              ϕMn_steel, shear_spans=nothing, slip_checked::Bool=false,
                              I_need=nothing, extra_ok=nothing, ϕ::Real=0.9)
    spans = shear_spans === nothing ?
        (uconvert(u"m", L_beam) / 2, uconvert(u"m", L_beam) / 2) :
        Tuple(uconvert(u"m", L) for L in shear_spans)
    Mu_N = uconvert(u"N*m", Mu)
    ϕMn_steel_N = uconvert(u"N*m", ϕMn_steel)
    blank = (; ok=false, reason=:strength, n_half=0, n_rows=0, spacing=0.0u"m",
             ΣQn=0.0u"N", Qn=0.0u"N", degree=0.0, ϕMn=0.0u"N*m",
             I_LB=section.Ix, ductile=false, n_rows_max=0)

    try
        validate_stud_diameter(anchor, section.tf; slab=slab)
    catch
        return (; blank..., reason=:diameter)
    end
    try
        validate_stud_length(anchor, slab)
    catch
        return (; blank..., reason=:length)
    end

    Qn = uconvert(u"N", get_Qn(anchor, slab))
    ustrip(u"N", Qn) > 0 || return (; blank..., reason=:strength, Qn=Qn)
    Cf = uconvert(u"N", _Cf_max(section, material, slab, b_eff))
    s_min, s_max = _stud_spacing_limits(anchor, slab)
    n_min, n_max = _combined_row_bounds(spans, s_min, s_max)
    L_long = maximum(spans)
    per = anchor.n_per_row

    function at(n_rows::Int)
        n_studs = n_rows * per
        Σ_nom = n_studs * Qn
        ΣQn = n_rows == 0 ? 0.0u"N" : min(Σ_nom, Cf)
        degree = ustrip(u"N", Cf) > 0 ? ustrip(u"N", ΣQn) / ustrip(u"N", Cf) : 0.0
        q_avg = ustrip(u"m", L_long) > 0 ? Σ_nom / L_long : 0.0u"N/m"
        ϕMn = 0.0u"N*m"
        if n_rows > 0 && ustrip(u"N", ΣQn) > 0 && ustrip(u"m", b_eff) > 1e-9
            try
                ϕMn = uconvert(u"N*m", get_ϕMn_composite(section, material, slab, b_eff, ΣQn; ϕ=ϕ).ϕMn)
            catch
                ϕMn = 0.0u"N*m"
            end
        end
        I_LB = ustrip(u"m", uconvert(u"m", b_eff)) > 1e-9 ?
            get_I_LB(section, material, slab, b_eff, ΣQn) : section.Ix
        spacing = n_rows <= 0 ? 0.0u"m" : maximum(L / n_rows for L in spans)
        uses_composite = ϕMn_steel_N < Mu_N
        ductile = !uses_composite || shear_connection_ductile(L_beam, degree, q_avg;
                                                              slip_checked=slip_checked)
        strength = max(ϕMn, ϕMn_steel_N) >= Mu_N
        return (; n_half=n_studs, n_rows=n_rows, spacing=uconvert(u"m", spacing),
                ΣQn=ΣQn, Qn=Qn, degree=degree, ϕMn=ϕMn, I_LB=I_LB, ductile=ductile,
                strength=strength, n_rows_max=n_max)
    end

    function passes(n_rows::Int)
        # No studs are placed when the steel section alone is enough, so the
        # transverse cover applies only to a layout that uses the anchor.
        if n_rows > 0 && !_transverse_studs_fit(section, anchor, slab)
            return false
        end
        n_rows == 0 || (n_min <= n_rows <= n_max) || return false
        lay = at(n_rows)
        lay.strength || return false
        lay.ductile || return false
        if I_need !== nothing && uconvert(u"m^4", lay.I_LB) < uconvert(u"m^4", I_need)
            return false
        end
        extra_ok === nothing || extra_ok(lay) || return false
        return true
    end

    if passes(0)
        lay = at(0)
        return (; lay..., ok=true, reason=:ok)
    end
    chosen = n_max >= max(n_min, 1) ? _lowest_passing(max(n_min, 1), n_max, passes) : nothing
    if chosen !== nothing
        lay = at(chosen)
        return (; lay..., ok=true, reason=:ok)
    end

    probe = n_max >= 1 ? at(min(max(n_max, 1), max(n_min, 1))) : at(0)
    reason = if !_transverse_studs_fit(section, anchor, slab)
        :transverse
    elseif n_max < max(n_min, 1) && n_max < 1
        :spacing
    elseif n_max >= 1 && !at(n_max).strength
        :strength
    elseif n_max >= max(n_min, 1) && !at(max(n_min, 1)).ductile && !at(n_max).ductile
        :ductility
    elseif I_need !== nothing && n_max >= 1 &&
           uconvert(u"m^4", at(n_max).I_LB) < uconvert(u"m^4", I_need)
        :deflection
    elseif n_min > n_max
        :spacing
    else
        :interaction
    end
    return (; probe..., ok=false, reason=reason)
end
