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
    `Rp = 0.75` when `slab.e_mid_ht ≥ 2 in. (50 mm)`, else `0.6`. An unknown
    `e_mid_ht` (`nothing`) takes 0.6 (AISC 360-22 §I8.2a, corpus:
    aisc-360-22, PDF pp. 181–182).
- **Skewed deck** takes the perpendicular values, with `n_per_row` the studs
  in one rib crossing. AISC gives no skewed-rib values; see
  [`DeckSlabOnBeam`](@ref) for the basis.
"""
function _Rg_Rp(anchor::HeadedStudAnchor, slab::DeckSlabOnBeam)
    if slab.deck_orientation === :parallel
        ratio = ustrip(slab.wr / slab.hr)
        return ratio >= 1.5 ? (1.0, 0.75) : (0.85, 0.75)
    else  # :perpendicular or :skewed
        n = anchor.n_per_row
        e = slab.e_mid_ht
        Rp = (e !== nothing && e >= 2.0u"inch") ? 0.75 : 0.6
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
    # ½ in. (13 mm) of specified cover above the stud: AISC 360-22 §I3.2c(b)
    # (corpus: aisc-360-22, PDF p. 170) for deck. Applied to solid slabs too
    # as engineering judgment; §I8.2 states no cover for a solid slab.
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

"""
    deck_limit_failures(slab, anchor) -> (failures::Vector{String}, unchecked::Vector{String})

Formed-deck limits of AISC 360-22 §I3.2c(1) (corpus: aisc-360-22, PDF p. 170):

- (a) `hr ≤ 3 in. (75 mm)`; `wr ≥ 2 in. (50 mm)`.
- (b) stud extends `≥ 1½ in. (38 mm)` above the deck after installation, with
  `≥ ½ in. (13 mm)` of cover above the stud.
- (c) slab above the deck `≥ 2 in. (50 mm)`.
- (d) deck anchored to the supporting member at `≤ 18 in. (450 mm)`.

§I3.2c(3): parallel deck with nominal depth `≥ 1½ in.` needs
`wr ≥ 2 in. + 4 d_sa` for each stud after the first in a transverse row.

`wr` is taken as given. §I3.2c(a) caps `wr` in calculations at the minimum
clear width near the top of the deck; that width is the caller's input.
(d) needs `slab.anchorage_spacing`. When it is `nothing`, (d) is listed in
`unchecked`, not in `failures`. A solid slab returns two empty lists.
"""
function deck_limit_failures(slab::DeckSlabOnBeam, anchor::HeadedStudAnchor)
    fails = String[]
    unchecked = String[]
    tol = 1e-9u"m"
    slab.hr <= 3.0u"inch" + tol ||
        push!(fails, "I3.2c(a): hr = $(round(u"inch", slab.hr; digits=3)) > 3 in.")
    slab.wr >= 2.0u"inch" - tol ||
        push!(fails, "I3.2c(a): wr = $(round(u"inch", slab.wr; digits=3)) < 2 in.")
    proj = anchor.l_sa - slab.hr
    proj >= 1.5u"inch" - tol ||
        push!(fails, "I3.2c(b): stud extends $(round(u"inch", proj; digits=3)) above deck < 1.5 in.")
    cover = slab.hr + slab.t_slab - anchor.l_sa
    cover >= 0.5u"inch" - tol ||
        push!(fails, "I3.2c(b): cover above stud $(round(u"inch", cover; digits=3)) < 0.5 in.")
    slab.t_slab >= 2.0u"inch" - tol ||
        push!(fails, "I3.2c(c): slab above deck $(round(u"inch", slab.t_slab; digits=3)) < 2 in.")
    if slab.anchorage_spacing === nothing
        push!(unchecked, "I3.2c(d): deck anchorage spacing not supplied")
    elseif slab.anchorage_spacing > 18.0u"inch" + tol
        push!(fails, "I3.2c(d): deck anchorage spacing " *
                     "$(round(u"inch", slab.anchorage_spacing; digits=3)) > 18 in.")
    end
    if slab.deck_orientation === :parallel && slab.hr >= 1.5u"inch" - tol
        wr_min = 2.0u"inch" + 4 * (anchor.n_per_row - 1) * anchor.d_sa
        slab.wr >= wr_min - tol ||
            push!(fails, "I3.2c(3): wr = $(round(u"inch", slab.wr; digits=3)) < " *
                         "$(round(u"inch", wr_min; digits=3)) for $(anchor.n_per_row) studs per row")
    end
    return (failures = fails, unchecked = unchecked)
end

deck_limit_failures(::SolidSlabOnBeam, ::HeadedStudAnchor) =
    (failures = String[], unchecked = String[])

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
keep 1 in. clear cover to each transverse slab edge.

On perpendicular or skewed deck the studs of one row share a rib crossing, so
they are placed along the rib centerline. The length of that line over the
usable flange width is `(y_hi - y_lo) / sin θ`. At `θ = π/2` it is the flange
width, as for a transverse row."""
function _transverse_studs_fit(section::ISymmSection, anchor::HeadedStudAnchor,
                               slab::AbstractSlabOnBeam)
    y_lo, y_hi = _stud_center_limits(section, anchor, slab)
    y_hi + 1e-9 >= y_lo || return false
    n = anchor.n_per_row
    n <= 1 && return true
    need = (n - 1) * 4 * ustrip(u"m", anchor.d_sa)
    avail = y_hi - y_lo
    if slab isa DeckSlabOnBeam && slab.deck_orientation !== :parallel
        avail /= sin(slab.rib_angle)
    end
    return avail + 1e-9 >= need
end

"""
    rib_crossing_spacing(slab) -> Union{Length, Nothing, Symbol}

Distance along the beam between successive low-flute crossings of the flange,
`rib_pitch / sin θ`, for perpendicular or skewed deck. `nothing` for a solid
slab or parallel deck, where studs are not tied to rib crossings. `:unknown`
when the deck is not parallel and `rib_pitch` was not given.
"""
rib_crossing_spacing(::SolidSlabOnBeam) = nothing
function rib_crossing_spacing(slab::DeckSlabOnBeam)
    slab.deck_orientation === :parallel && return nothing
    slab.rib_pitch === nothing && return :unknown
    return uconvert(u"m", slab.rib_pitch / sin(slab.rib_angle))
end

"""
    rib_row_bounds(L, p_cross, s_min, s_max) -> (n_min, n_max)

Row bounds over a shear span `L` when rows can only sit at rib crossings
`p_cross` apart. The span holds at least `N = ⌊L / p_cross⌋` crossings
whatever their phase, so `n_max = N` (also capped by the §I8.2d(d) minimum
`s_min`). Using every `k`-th crossing, with `k = ⌊s_max / p_cross⌋`, keeps the
center-to-center spacing within the §I8.2d(e) maximum `s_max` (corpus:
aisc-360-22, PDF p. 183), so `n_min = ⌈N / k⌉`. `k = 0`, crossings farther
apart than `s_max`, returns `(1, 0)`: no layout exists.
"""
function rib_row_bounds(L, p_cross, s_min, s_max)
    Ls = ustrip(u"m", uconvert(u"m", L))
    p = ustrip(u"m", uconvert(u"m", p_cross))
    k = floor(Int, ustrip(u"m", uconvert(u"m", s_max)) / p + 1e-9)
    k == 0 && return (1, 0)
    N = floor(Int, Ls / p + 1e-9)
    smin = ustrip(u"m", uconvert(u"m", s_min))
    smin > 0 && (N = min(N, floor(Int, Ls / smin + 1e-9)))
    N == 0 && return (1, 0)
    return (cld(N, k), N)
end

"""Rib-crossing row bounds that hold on every shear span."""
function _combined_rib_row_bounds(spans, p_cross, s_min, s_max)
    n_min, n_max = 1, typemax(Int) ÷ 4
    for L in spans
        lo, hi = rib_row_bounds(L, p_cross, s_min, s_max)
        n_min = max(n_min, lo)
        n_max = min(n_max, hi)
    end
    return (n_min, n_max)
end

"""
    deck_rib_note(slab) -> String

One line for the anchor check clause on perpendicular or skewed deck: the rib
angle, the rib crossing spacing, and, when skewed, that the perpendicular
`Rg`/`Rp` were used. Empty for a solid slab or parallel deck.
"""
deck_rib_note(::SolidSlabOnBeam) = ""
function deck_rib_note(slab::DeckSlabOnBeam)
    slab.deck_orientation === :parallel && return ""
    θ = round(rad2deg(slab.rib_angle); digits=1)
    p = rib_crossing_spacing(slab)
    cross = p === :unknown ? "rib pitch not supplied, crossings unchecked" :
        "rib crossings every $(round(u"inch", p; digits=2)) along beam"
    slab.deck_orientation === :perpendicular && return "deck ribs at $(θ)°; $cross"
    return "deck ribs skewed $(θ)° to beam; $cross; perpendicular Rg/Rp and " *
           "no rib concrete used (AISC 360-22 I3.2c/I8.2a cover 0° and 90° only)"
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
    deck_ok = isempty(deck_limit_failures(slab, anchor).failures)

    Qn = uconvert(u"N", get_Qn(anchor, slab))
    ustrip(u"N", Qn) > 0 || return (; blank..., reason=:strength, Qn=Qn)
    Cf = uconvert(u"N", _Cf_max(section, material, slab, b_eff))
    s_min, s_max = _stud_spacing_limits(anchor, slab)
    p_cross = rib_crossing_spacing(slab)
    rib_reason = nothing
    if p_cross isa Unitful.Length
        n_min, n_max = _combined_rib_row_bounds(spans, p_cross, s_min, s_max)
        n_max < max(n_min, 1) && (rib_reason = :rib_spacing)
    else
        # A skewed rib with no pitch has no known crossing positions. A
        # perpendicular rib without pitch keeps the plain §I8.2d limits.
        p_cross === :unknown && slab.deck_orientation === :skewed &&
            (rib_reason = :rib_pitch_unknown)
        n_min, n_max = _combined_row_bounds(spans, s_min, s_max)
    end
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
    # §I3.2c applies to composite construction on deck. When it fails, only
    # the steel section alone (no studs counted) can be used.
    deck_ok || return (; at(0)..., ok=false, reason=:deck_limits)
    # Rib crossings farther apart than the §I8.2d(e) maximum, or unknown on a
    # skewed rib: no compliant stud layout exists, so the steel acts alone.
    rib_reason === nothing || return (; at(0)..., ok=false, reason=rib_reason)
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

# ==============================================================================
# Anchor positions — the schedule `design_shear_anchors` counted
# ==============================================================================

"""
Positions of the headed studs [`design_shear_anchors`](@ref) counted.

`s` is the distance in metres from station 0 of the beam. `y` is the offset
in metres from the beam centerline, in the flange-width direction. `z_flange`
is the top of steel in the centroid frame of [`section_polygon`](@ref), metres,
positive toward the slab. The shank runs from that point a distance `l_sa`
in the same direction. One entry of `s` and `y` per stud. `mass` and `ec`
cover every stud in `s`.
"""
struct ShearAnchorLayout
    s::Vector{Float64}
    y::Vector{Float64}
    d_sa::typeof(1.0u"m")
    l_sa::typeof(1.0u"m")
    z_flange::Float64
    mass::typeof(1.0u"kg")
    ec::CarbonMassQuantity
end

ShearAnchorLayout() = ShearAnchorLayout(Float64[], Float64[], 0.0u"m", 0.0u"m", 0.0,
                                        0.0u"kg", 0.0u"kgCO2e")

"""
    studs_on_interval(layout, s0, s1; include_end=false)
        -> Vector of (s_local, y)

Studs whose station lies in `[s0, s1)`, or in `[s0, s1]` when `include_end`.
`s_local` is the station minus `s0`. Stations are metres.
"""
function studs_on_interval(layout::ShearAnchorLayout, s0::Real, s1::Real;
                           include_end::Bool=false)
    out = Tuple{Float64, Float64}[]
    for i in eachindex(layout.s)
        s = layout.s[i]
        inside = include_end ? (s0 - 1e-8 <= s <= s1 + 1e-8) :
                               (s0 - 1e-8 <= s < s1 - 1e-8)
        inside && push!(out, (s - s0, layout.y[i]))
    end
    return out
end

"""
    place_shear_anchors(section, anchor, slab, regions, layouts, L)
        -> ShearAnchorLayout

Stations and flange offsets for one layout per sagging region.

Each shear span — the peak moment to one adjacent zero, AISC 360-22 §I8.2c
(corpus: aisc-360-22, PDF p. 183) — gets `layout.n_rows` rows. A side shorter
than 0.1 mm is not a span, matching [`region_shear_spans`](@ref).

# ENGINEERING JUDGMENT
§I8.2d(a) (PDF p. 183) distributes the anchors uniformly between the maximum
moment and the zero. `n` rows on a span of length `L` sit at the centers of
`n` equal spaces, so the center-to-center pitch is `L/n`, the spacing
[`design_shear_anchors`](@ref) checks, and the end margins are half a space.

On perpendicular or skewed deck the rows also have to sit at rib crossings.
The sheet's position along the beam is not in the model. Crossings are taken
at half a pitch, then every pitch, measured from station 0. The `n` crossings
inside the span are an even subsample of that grid.

Across the flange, `n_per_row` studs are spaced equally between the center
limits of [`_stud_center_limits`](@ref): §I8.2d(b) cover, §I8.2d(d) four
diameters, and the shank held `d_sa/2` inside each flange tip. One stud sits
on the centerline when the centerline is inside those limits. On a skewed
rib the studs of one row share the rib, so a transverse offset `y` moves the
station by `y · cot θ`.
"""
function place_shear_anchors(section::ISymmSection, anchor::HeadedStudAnchor,
                             slab::AbstractSlabOnBeam, regions, layouts, L)
    L_m = ustrip(u"m", uconvert(u"m", L isa Unitful.Quantity ? L : L * u"m"))
    ys = _stud_transverse_ordinates(section, anchor, slab)
    pitch = rib_crossing_spacing(slab)
    p = pitch isa Unitful.Length ? ustrip(u"m", uconvert(u"m", pitch)) : nothing
    shift = _stud_station_shift(ys, slab)
    ss = Float64[]
    yy = Float64[]
    for (region, lay) in zip(regions, layouts)
        (lay.ok && lay.n_rows > 0) || continue
        for (side_lo, side_hi) in _shear_span_ends(region, L_m)
            rows = p === nothing ?
                _uniform_row_stations(side_lo, side_hi, lay.n_rows) :
                _rib_row_stations(side_lo, side_hi, lay.n_rows, p)
            for s_row in rows, (k, y) in enumerate(ys)
                push!(ss, s_row + shift[k])
                push!(yy, y)
            end
        end
    end
    n = length(ss)
    mass = n * stud_mass(anchor)
    # Top of the top flange. The I-shape polygon puts that fibre at +d/2.
    z_flange = ustrip(u"m", section_depth(section)) / 2
    return ShearAnchorLayout(ss, yy, uconvert(u"m", anchor.d_sa),
                             uconvert(u"m", anchor.l_sa), z_flange,
                             mass, uconvert(u"kgCO2e", mass * anchor.ecc))
end

"""Transverse ordinates, metres, one per stud in a row."""
function _stud_transverse_ordinates(section::ISymmSection, anchor::HeadedStudAnchor,
                                    slab::AbstractSlabOnBeam)
    y_lo, y_hi = _stud_center_limits(section, anchor, slab)
    n = anchor.n_per_row
    n <= 1 && return [clamp(0.0, y_lo, y_hi)]
    return [y_lo + (i - 1) * (y_hi - y_lo) / (n - 1) for i in 1:n]
end

"""Along-beam station change, metres, for each transverse ordinate on a skewed rib. Zeros otherwise."""
_stud_station_shift(section_ys::Vector{Float64}, ::AbstractSlabOnBeam) = zeros(length(section_ys))

function _stud_station_shift(section_ys::Vector{Float64}, slab::DeckSlabOnBeam)
    slab.deck_orientation === :parallel && return zeros(length(section_ys))
    rib_crossing_spacing(slab) isa Unitful.Length || return zeros(length(section_ys))
    θ = slab.rib_angle
    abs(sin(θ)) < 1e-6 && return zeros(length(section_ys))
    cotθ = cos(θ) / sin(θ)
    return [y * cotθ for y in section_ys]
end

function _shear_span_ends(region, L_m::Float64)
    spans = Tuple{Float64, Float64}[]
    lo = region.s_left * L_m
    peak = region.s_peak * L_m
    hi = region.s_right * L_m
    peak - lo > 1e-4 && push!(spans, (lo, peak))
    hi - peak > 1e-4 && push!(spans, (peak, hi))
    return spans
end

"Centers of `n` equal spaces on `[span_lo, span_hi]`."
function _uniform_row_stations(span_lo::Float64, span_hi::Float64, n::Int)
    s = (span_hi - span_lo) / n
    return [span_lo + (i - 0.5) * s for i in 1:n]
end

"""
Even subsample of the rib crossings inside `(span_lo, span_hi)`.

Crossings lie at `(k + 1/2) · pitch` from station 0.
"""
function _rib_row_stations(span_lo::Float64, span_hi::Float64, n::Int, pitch::Float64)
    k_first = ceil(Int, span_lo / pitch - 0.5 + 1e-9)
    k_last = floor(Int, span_hi / pitch - 0.5 - 1e-9)
    k_last < k_first && return Float64[]
    xs = [(k + 0.5) * pitch for k in k_first:k_last]
    n_use = min(n, length(xs))
    n_use <= 0 && return Float64[]
    if n_use == 1
        mid = (span_lo + span_hi) / 2
        return [xs[argmin(abs.(xs .- mid))]]
    end
    idx = [1 + round(Int, (i - 1) * (length(xs) - 1) / (n_use - 1)) for i in 1:n_use]
    return xs[unique!(idx)]
end
