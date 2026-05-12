# AISC 360-16 Table B4.1b — Slenderness Limits for Flexure
# AISC 360-16 §E7        — Members with Slender Elements (compression)
# Source: corpus aisc-360-16, pp. 36–41 (Table B4.1) and pp. 98–101 (§E7).

"""
    get_slenderness(s::ISymmSection, mat::Metal) -> NamedTuple

Flange and web slenderness classification for **flexure** per AISC 360-16
Table B4.1b (corpus aisc-360-16, pp. 40–41):

- Flange (Case 10, doubly-symmetric I-shape, flexure, unstiffened):
    `λp = 0.38 √(E/Fy)`,  `λr = 1.0 √(E/Fy)`.
- Web (Case 15, doubly-symmetric I-shape, flexure, stiffened):
    `λp = 3.76 √(E/Fy)`,  `λr = 5.70 √(E/Fy)`.

# Returns
- `λ_f`, `λp_f`, `λr_f`, `class_f`: Flange slenderness, limits, and class (Case 10)
- `λ_w`, `λp_w`, `λr_w`, `class_w`: Web slenderness, limits, and class (Case 15)
"""
function get_slenderness(s::ISymmSection, mat::Metal)
    λ_f, λ_w = s.λ_f, s.λ_w
    E, Fy = mat.E, mat.Fy

    # AISC 360-16 Table B4.1b Case 10 (flange in flexure, doubly-symmetric I).
    λp_f = 0.38 * sqrt(E / Fy)
    λr_f = 1.0  * sqrt(E / Fy)
    class_f = λ_f > λr_f ? :slender : (λ_f > λp_f ? :noncompact : :compact)

    # AISC 360-16 Table B4.1b Case 15 (web in flexure, doubly-symmetric I).
    λp_w = 3.76 * sqrt(E / Fy)
    λr_w = 5.70 * sqrt(E / Fy)
    class_w = λ_w > λr_w ? :slender : (λ_w > λp_w ? :noncompact : :compact)

    return (λ_f=λ_f, λp_f=λp_f, λr_f=λr_f, class_f=class_f,
            λ_w=λ_w, λp_w=λp_w, λr_w=λr_w, class_w=class_w)
end

# ──────────────────────────────────────────────────────────────────────────
# AISC 360-16 §E7 — effective-width / effective-area machinery
# Used by both `get_Pn` (with the actual member Fcr from §E3) and the
# legacy `get_compression_factors` wrapper (with Fcr = Fy as a conservative
# stand-in for downstream callers that don't yet thread Fcr).
# ──────────────────────────────────────────────────────────────────────────

"""
    _be_E7(b, λ, λr, c1, c2, Fcr, Fy) -> effective_width

Effective width `be` of a single compression plate element per AISC 360-16
§E7, Eqs. E7-2 and E7-3 (corpus aisc-360-16, pp. 99–100):

    λ ≤ λr · √(Fy/Fcr):     be = b                                  (Eq. E7-2)
    λ > λr · √(Fy/Fcr):     be = b · (1 − c1·√(Fel/Fcr)) · √(Fel/Fcr)  (Eq. E7-3)
    Fel = (c2 · λr/λ)² · Fy                                          (Eq. E7-5)

Table E7.1 calibrates `c1` and `c2` so that `be = b` exactly at the
threshold (`c1 c2² = c2 − 1`, AISC 360-16 Eq. E7-4), and `be ≤ b` for all
λ above it.

# Arguments
- `b`:   Element width (for an I-shape flange, the half-flange width
         `bf/2`; for the web, the clear height `h`)
- `λ`:   Element width-to-thickness ratio per §B4.1 (`b/t`)
- `λr`:  Limiting `b/t` from Table B4.1a (compression):
         flange unstiffened (Case 1): `0.56 √(E/Fy)`;
         I-shape web (Case 5):        `1.49 √(E/Fy)`.
- `c1`, `c2`: Imperfection factors from Table E7.1 (Case (a) `0.18, 1.31`
              for stiffened webs; Case (c) `0.22, 1.49` for I-shape flanges).
- `Fcr`: Member critical stress from §E3 (or `Fy` as a conservative
         stand-in when the §E3 Fcr is not yet known).
- `Fy`:  Specified minimum yield stress.
"""
function _be_E7(b, λ::Real, λr::Real, c1::Real, c2::Real, Fcr, Fy)
    # AISC 360-16 §E7-2 effective threshold accounts for global Fcr.
    threshold = λr * sqrt(Fy / Fcr)
    if λ <= threshold
        return b
    end
    # AISC 360-16 §E7-5 elastic local-buckling stress.
    Fel = (c2 * λr / λ)^2 * Fy
    # AISC 360-16 §E7-3 effective width.
    ratio = sqrt(Fel / Fcr)
    be = b * (1 - c1 * ratio) * ratio
    # Defensive clamp; the c1/c2 calibration in Table E7.1 (Eq. E7-4) keeps
    # be ≤ b in the valid range, but numerical edge cases can perturb this.
    return clamp(be, zero(b), b)
end

"""
    _compute_Ae_E7(s::ISymmSection, mat::Metal, Fcr) -> NamedTuple

Effective area `Ae` of a doubly-symmetric I-shape under axial compression,
per AISC 360-16 §E7-1 (corpus aisc-360-16, p. 98). Returns the breakdown:

- `Ae`:                 Effective area used in `Pn = Fcr · Ae` (Eq. E7-1)
- `flange_reduction`:   Total area subtracted from gross flanges
                        `= 4 · (b_f − be_f) · tf`  (4 half-flange elements)
- `web_reduction`:      Area subtracted from the web
                        `= (h − be_w) · tw`         (1 stiffened element)
- `be_f`, `be_w`:       Per-element effective widths

# Element treatment for a doubly-symmetric I-shape
- **Flanges**: 4 half-flange elements, each with `b = bf/2` and `t = tf`.
  Limit `λr = 0.56 √(E/Fy)` (Table B4.1a Case 1, unstiffened flange).
  Imperfection factors `c1 = 0.22`, `c2 = 1.49` (Table E7.1 Case (c),
  "all other elements").
- **Web**: 1 stiffened element with `b = h` (clear web height) and `t = tw`.
  Limit `λr = 1.49 √(E/Fy)` (Table B4.1a Case 5, stiffened web).
  Imperfection factors `c1 = 0.18`, `c2 = 1.31` (Table E7.1 Case (a)).
"""
function _compute_Ae_E7(s::ISymmSection, mat::Metal, Fcr)
    E, Fy = mat.E, mat.Fy
    Ag = s.A

    # ── Flange (4 half-flange elements, Table B4.1a Case 1; Table E7.1 Case (c))
    # Element width b = bf/2, with width-to-thickness λ = bf/(2 tf) = s.λ_f.
    bf, tf = s.bf, s.tf
    b_f = bf / 2
    λr_f_compr = 0.56 * sqrt(E / Fy)
    be_f = _be_E7(b_f, s.λ_f, λr_f_compr, 0.22, 1.49, Fcr, Fy)
    flange_reduction = 4 * (b_f - be_f) * tf  # 4 half-flange elements

    # ── Web (1 stiffened element, Table B4.1a Case 5; Table E7.1 Case (a))
    h, tw = s.h, s.tw
    λr_w_compr = 1.49 * sqrt(E / Fy)
    be_w = _be_E7(h, s.λ_w, λr_w_compr, 0.18, 1.31, Fcr, Fy)
    web_reduction = (h - be_w) * tw

    # AISC 360-16 §E7 User Note: Ae = Ag − Σ (b − be) · t.
    Ae = Ag - flange_reduction - web_reduction

    return (Ae=max(Ae, zero(Ae)),
            flange_reduction=flange_reduction,
            web_reduction=web_reduction,
            be_f=be_f, be_w=be_w)
end

"""
    get_compression_factors(s::ISymmSection, mat::Metal) -> NamedTuple(:Qs, :Qa, :Q)

Backward-compatible reduction factors for compression slender elements,
re-grounded in AISC 360-16 §E7. **Used only by legacy callers**; the
production `get_Pn` path uses `_compute_Ae_E7` directly with the actual
member `Fcr` from §E3.

# Re-grounded interpretation under AISC 360-16 §E7

In AISC 360-10 §E7 the slender-element reduction was a multiplicative
`Q = Qs · Qa`. AISC 360-16 §E7 instead reduces the *area*: `Ae < Ag`.
This function preserves the legacy `(Qs, Qa, Q)` tuple by re-projecting
the §E7 area reductions, evaluated at the conservative bound `Fcr = Fy`,
onto effective-area fractions:

- `Qs = (Ag − flange_reduction(Fy)) / Ag`   ← contribution from flange elements
- `Qa = (Ag − web_reduction(Fy))   / Ag`    ← contribution from web element
- `Q  = Ae(Fy) / Ag = Qs + Qa − 1`           (combined effective area; this
        is **not** `Qs · Qa` — that was the AISC 360-10 multiplicative form
        and is no longer the correct combination under §E7).

For the rolled-W catalog at `Fy ≤ 65 ksi`, all three values are 1.0
because there are no slender flanges and the catalog's slender webs are
relatively few; the production path is unaffected.

For a member that actually has slender elements, the new
production path (`get_Pn` calling `_compute_Ae_E7` with the §E3 `Fcr`)
will give a *less conservative* result than this fixed-`Fcr=Fy` summary —
that's expected, because §E7-2 lets long columns with `Fcr < Fy` recover
some effective width that is otherwise reduced at `Fcr = Fy`.
"""
function get_compression_factors(s::ISymmSection, mat::Metal)
    Fy = mat.Fy
    Ag = s.A

    # Evaluate §E7 reductions at the conservative bound Fcr = Fy (no global
    # buckling relief). This matches the legacy 360-10 fixed-stress evaluation.
    bd = _compute_Ae_E7(s, mat, Fy)

    Qs = 1 - bd.flange_reduction / Ag
    Qa = 1 - bd.web_reduction    / Ag
    Q  = bd.Ae / Ag                              # = Qs + Qa − 1
    return (Qs=Qs, Qa=Qa, Q=Q)
end

"""
    is_compact(s::ISymmSection, mat::Metal) -> Bool

Return `true` iff both the flange and the web are compact in flexure per
AISC 360-16 Table B4.1b (Cases 10 and 15).
"""
function is_compact(s::ISymmSection, mat::Metal)
    sl = get_slenderness(s, mat)
    return sl.class_f == :compact && sl.class_w == :compact
end
