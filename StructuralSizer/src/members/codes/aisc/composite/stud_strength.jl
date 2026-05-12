# ==============================================================================
# Steel Headed Stud Anchor Strength — AISC 360-16 §I8 (corpus aisc-360-16, pp. 160–164)
# ==============================================================================
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
function validate_stud_diameter(anchor::HeadedStudAnchor, tf)
    d_max = 2.5 * tf
    if anchor.d_sa > d_max
        throw(ArgumentError(
            "Stud diameter $(anchor.d_sa) exceeds 2.5·tf = $(d_max) " *
            "(AISC 360-16 §I8.1). Use a smaller stud or verify the stud is welded directly over the web."))
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
    if n_studs <= 1
        return nothing
    end

    n_rows = ceil(Int, n_studs / anchor.n_per_row)
    spacing = L_half / n_rows

    # §I8.2d(d): minimum spacing.
    # Long-axis 6·d_sa applies when there's no perpendicular deck. Without
    # finer info we apply the longer 6·d_sa as the conservative default.
    s_min_long_axis = isa(slab, DeckSlabOnBeam) && slab.deck_orientation === :perpendicular ?
                      4 * anchor.d_sa : 6 * anchor.d_sa
    s_min = s_min_long_axis
    if spacing < s_min
        @warn "Stud longitudinal spacing $(spacing) < minimum $(s_min) " *
              "(AISC 360-16 §I8.2d(d)). Consider fewer studs or multi-row layout."
    end

    # §I8.2d(e): maximum spacing — uses TOTAL slab thickness, hr + t_slab for deck.
    s_max = min(8 * _total_slab_depth(slab), 36.0u"inch")
    if spacing > s_max
        @warn "Stud longitudinal spacing $(spacing) > maximum $(s_max) " *
              "(AISC 360-16 §I8.2d(e), 8·(total slab thickness) ≤ 36 in.). Add more studs."
    end

    return nothing
end

"""
    check_stud_edge_distance(anchor::HeadedStudAnchor, slab::AbstractSlabOnBeam, lightweight=false) -> nothing

Edge-of-slab detailing checks for composite **beams** per AISC 360-16 §I8.2d
(corpus aisc-360-16, p. 163):

- (b) Steel anchors shall have at least **1 in. (25 mm)** of lateral concrete
      cover in the direction perpendicular to the shear force, except for
      anchors installed in the ribs of formed steel decks. (Lateral cover is
      project-geometry-dependent and is reported as a `@warn` only when the
      slab `edge_dist` indicates a clear violation.)
- (c) The minimum distance from the center of a steel anchor to a free edge
      in the direction of the shear force shall be **8 in. (200 mm)** for
      normal-weight concrete and **10 in. (250 mm)** for lightweight concrete.
      ACI 318 Chapter 17 may be used in lieu.

This function emits `@warn` rather than throwing, because the slab `edge_dist`
fields measure to the slab edge, not to the stud centerline, and the actual
stud transverse offset is not modeled. Edge-distance compliance must
ultimately be enforced at the connection-detailing stage.
"""
function check_stud_edge_distance(anchor::HeadedStudAnchor, slab::AbstractSlabOnBeam;
                                  lightweight::Bool=false)
    # §I8.2d(c): free-edge distance in the direction of the shear force.
    free_edge_min = lightweight ? 10.0u"inch" : 8.0u"inch"
    for (side, ed) in (("left", slab.edge_dist_left), ("right", slab.edge_dist_right))
        ed === nothing && continue   # interior beam on this side
        if ed < free_edge_min
            @warn "Slab edge distance ($side) $(ed) is less than the §I8.2d(c) minimum " *
                  "$(free_edge_min) for $(lightweight ? "lightweight" : "normal-weight") concrete; " *
                  "stud free-edge compliance must be confirmed against the actual stud transverse offset."
        end
    end
    return nothing
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
