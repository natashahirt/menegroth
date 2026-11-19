# =============================================================================
# ACI 318-11 Spread (Isolated) Footing Design
# =============================================================================
#
# Full 7-step StructurePoint workflow:
#   1. Preliminary sizing (service loads → required area)
#   2. Two-way (punching) shear → minimum thickness
#   3. One-way (beam) shear → minimum thickness
#   4. Flexural reinforcement at face of column
#   5. Development length check
#   6. Column-footing bearing check (ACI 22.8)
#   7. Dowel design if bearing is insufficient
#
# Fully Unitful throughout — only strips at ACI √f'c formula boundaries.
# Uses shared punching_check() with biaxial unbalanced moment transfer.
# Reference: StructurePoint ACI 318-11, Wight 7th Ed. Ex 15-2.
# =============================================================================

# =============================================================================
# Solver Trace Contract (manual registry; function is documented)
# =============================================================================
TRACE_REGISTRY[(:design_footing, :checker)] =
    TracedFunctionMeta(:design_footing, :checker,
                       [:enter, :exit, :decision, :iteration, :failure], nothing,
                       @__FILE__, @__LINE__)

# ─────────────────────────────────────────────────────────────────────────────
# Internal Unitful helpers (also used by strip & mat footings)
# ─────────────────────────────────────────────────────────────────────────────

"""
    _eccentric_soil_pressure(P, Mux, Muy, B, L) → (q_max, q_min, qu, ex, ey)

ACI 336.2R §3.2.1 Eq. (3-1) (corpus: aci-336-combined-footings-mats, page 6)
and §4.1 (page 7) linear rigid-body contact pressure:

    q_max,min = P/(B L) (1 ± 6 |ex|/L ± 6 |ey|/B)

The ± in Eq. (3-1) (`q_max,min = (P/A)(1 ± 6e/Z)`) means the peak uses the
sum of absolute eccentricities: `q_max` is always the pressed-edge corner
and `q_min` the opposite.  `ex = Mux/P`, `ey = Muy/P` are returned signed;
`L` along x (Mux), `B` along y (Muy).  `qu = P/(B L)` is the concentric
average.

§3.2.1 states Eq. (3-1) applies only when "all portions of the foundation
contact area are in compression" (`q_min ≥ 0`, resultant in the kern).
A negative `q_min` means Eq. (3-1) is outside its stated range — do not
size from `q_max` as if the base were in full contact.  Callers grow the
plan until `q_min ≥ 0` (and `q_max ≤ qa`) or refuse.  §3.2.2 triangular
partial-contact formulas are not implemented (stay in the kern).
"""
function _eccentric_soil_pressure(P::Force, Mux::Torque, Muy::Torque,
                                  B::Length, L::Length)
    A = B * L
    qu = P / A
    P_abs = abs(P)
    if P_abs ≤ zero(P_abs)
        z = zero(qu)
        return (q_max = z, q_min = z, qu = z, ex = zero(L), ey = zero(B))
    end
    ex = Mux / P
    ey = Muy / P
    # ACI 336.2R §3.2.1 Eq. (3-1) (corpus: aci-336-combined-footings-mats,
    # page 6): q_max,min = (P/A)(1 ± 6e/Z).  Peak uses |e| so a negative
    # Mux cannot label the unloaded edge as q_max.
    ex_abs = abs(ex)
    ey_abs = abs(ey)
    kern = 1 + 6 * ustrip(u"m", ex_abs) / ustrip(u"m", L) +
               6 * ustrip(u"m", ey_abs) / ustrip(u"m", B)
    kern_min = 1 - 6 * ustrip(u"m", ex_abs) / ustrip(u"m", L) -
                   6 * ustrip(u"m", ey_abs) / ustrip(u"m", B)
    return (q_max = qu * kern, q_min = qu * kern_min, qu = qu, ex = ex, ey = ey)
end

"""True when Eq. (3-1) is inside its §3.2.1 range (`q_min ≥ 0`).

A relative floor of `1e-12` on `q_min/qu` absorbs Float64 residue at the
kern edge `e = L/6` (not a construction tolerance).
"""
function _eccentric_in_kern(qe)
    qe.q_min ≥ zero(qe.q_min) && return true
    qe.qu == zero(qe.qu) && return true
    return ustrip(Unitful.NoUnits, qe.q_min / qe.qu) ≥ -1e-12
end

"""
Minimum square side so a rigid rectangular footing stays in the kern.

ACI 336.2R §3.2.1 (corpus: aci-336-combined-footings-mats, page 6): Eq. (3-1)
requires the resultant in the middle third on each principal axis.  For a
square `B = L`, `6|ex|/B + 6|ey|/B ≤ 1` ⇒ `B ≥ 6(|ex| + |ey|)`.
"""
function _kern_min_square_side(P::Force, Mux::Torque, Muy::Torque)
    P_abs = abs(P)
    P_abs ≤ zero(P_abs) && return 0.0u"m"
    return 6 * (abs(Mux / P) + abs(Muy / P))
end

"""
    _footing_tension_As(Mu, b, d, fc, fy, ϕf) -> Area

Tension steel for width `b` from the Whitney block (`required_reinforcement`
with `φ = ϕf`). `Inf` when the section is inadequate or εt < 0.005
(ACI 318-11 §10.3.4, corpus: aci-318-11, page 142), so a depth search can
add thickness.
"""
function _footing_tension_As(Mu::Torque, b::Length, d::Length,
                             fc::Pressure, fy::Pressure, ϕf::Float64)
    to_kipft(Mu) ≤ 0.0 && return 0.0u"inch^2"
    ustrip(fy) > 0 || throw(ArgumentError("fy must be positive"))
    ustrip(fc) > 0 || throw(ArgumentError("fc must be positive"))
    ustrip(b) > 0 || throw(ArgumentError("b must be positive"))
    ustrip(d) > 0 || throw(ArgumentError("d must be positive"))
    return uconvert(u"inch^2", required_reinforcement(Mu, b, d, fc, fy; φ = ϕf))
end

"""
    _footing_flexure_ok(pairs, d, fc, fy, ϕf) -> Bool

True when every `(Mu, b)` in `pairs` is tension-controlled at depth `d`.
Footing depth searches include this with their shear checks.
"""
_footing_flexure_ok(pairs, d::Length, fc::Pressure, fy::Pressure, ϕf::Float64) =
    all(isfinite(_footing_tension_As(Mu, b, d, fc, fy, ϕf)) for (Mu, b) in pairs)

"""
    _flexural_steel_footing(Mu, b, d, fc, fy, ϕf) -> Area

Required flexural reinforcement for a rectangular footing section of width
`b`. Throws when the section is not tension-controlled; the depth searches
call `_footing_flexure_ok` first, so this only fires if a search ended
without a passing thickness.
"""
function _flexural_steel_footing(Mu::Torque, b::Length, d::Length,
                                  fc::Pressure, fy::Pressure, ϕf::Float64)
    As = _footing_tension_As(Mu, b, d, fc, fy, ϕf)
    isfinite(As) || error("Footing flexure is not tension-controlled at d = $d " *
                          "(ACI 318-11 §10.3.4, εt ≥ 0.005): Mu = $Mu over b = $b. " *
                          "The depth search ended without a thickness that passes flexure.")
    return As
end

"""
Minimum shrinkage/temperature reinforcement area for a footing strip of
width `b` and thickness `h`.

Per ACI 318-11 §7.12.2.1 (corpus: aci-318-11, page 106):
- (a) Grade 40 or 50 deformed bars              → ρ_min = 0.0020
- (b) Grade 60 deformed bars or welded wire     → ρ_min = 0.0018
- (c) reinforcement with fy > 60,000 psi        → ρ_min = max(0.0014, 0.0018·60,000/fy)

Yield strengths between Grade 50 and Grade 60 are uncommon in practice;
when they do occur (e.g. some imported reinforcement) the conservative
0.0020 value from clause (a) is applied because §7.12.2.1(b) explicitly
restricts itself to "Grade 60 deformed bars or welded wire reinforcement".
"""
function _min_steel_footing(b::Length, h::Length, fy::Pressure)
    fy_psi = ustrip(u"psi", fy)
    ρ_min = fy_psi <  60_000.0 ? 0.0020 :        # ACI 318-11 §7.12.2.1(a)
            fy_psi == 60_000.0 ? 0.0018 :        # ACI 318-11 §7.12.2.1(b)
            max(0.0014, 0.0018 * 60_000.0 / fy_psi)  # ACI 318-11 §7.12.2.1(c)
    return ρ_min * b * h
end

"""√f′c in psi, not above 100. ACI 318-11 §12.1.2 (corpus: aci-318-11, page 213)."""
function _sqrt_fc_chapter12(fc::Pressure)
    return min(sqrt(ustrip(u"psi", fc)), 100.0)
end

"""
Straight tension development length, ACI 318-11 Eq. (12-1) (corpus:
aci-318-11, page 214).

Ktr = 0. (cb + Ktr)/db is not taken above 2.5. ψt, ψe, and ψs are §12.2.4
(page 215): bottom bars have ψt = 1, uncoated bars have ψe = 1, and ψs is
0.8 for No. 6 and smaller. The product ψt·ψe is not taken above 1.7. §12.2.5
is not applied. ld is at least 12 in (§12.2.1).

`clear_cover` is the clear side or bottom cover. cb is the smaller of the
cover to the bar center and half the center-to-center `spacing`. Omitting
`spacing` means the bars are placed so spacing does not reduce cb.
`top_bar` sets ψt = 1.3 (§12.2.4(a)).
"""
function _development_length_footing(bar_size::Int, fc::Pressure, fy::Pressure,
                                      λ::Float64, db::Length;
                                      clear_cover::Union{Length, Nothing} = nothing,
                                      spacing::Union{Length, Nothing} = nothing,
                                      top_bar::Bool = false)
    sqrt_fc = _sqrt_fc_chapter12(fc)
    fy_psi = ustrip(u"psi", fy)
    db_in = ustrip(u"inch", db)
    ψt = top_bar ? 1.3 : 1.0
    ψe = 1.0
    ψs = bar_size <= 6 ? 0.8 : 1.0
    ψ = min(ψt * ψe, 1.7) * ψs
    cb_over_db = 1.0
    if clear_cover !== nothing
        cb = ustrip(u"inch", clear_cover) + db_in / 2
        if spacing !== nothing
            cb = min(cb, ustrip(u"inch", spacing) / 2)
        end
        cb_over_db = min(cb / db_in, 2.5)
    end
    ld_in = ((3 / 40) * fy_psi * ψ / (λ * sqrt_fc * cb_over_db)) * db_in
    return max(ld_in, 12.0) * u"inch"
end

"""
Development length of a 90-degree standard hook, ACI 318-11 §12.5.2
(corpus: aci-318-11, page 217).

ldh is at least 8 db and 6 in. §12.5.3(a) multiplies by 0.7 for No. 11 and
smaller when the side cover is at least 2.5 in and the cover beyond the tail
is at least 2 in. Ties (§12.5.3(b), (c)) and the excess-reinforcement factor
are not applied. Hooks do not develop compression (§12.5.5).
"""
function _hooked_development_length(bar_size::Int, fc::Pressure, fy::Pressure,
                                     λ::Float64, db::Length;
                                     side_cover::Length, tail_cover::Length)
    sqrt_fc = _sqrt_fc_chapter12(fc)
    db_in = ustrip(u"inch", db)
    ldh = (0.02 * ustrip(u"psi", fy) / (λ * sqrt_fc)) * db_in
    if bar_size <= 11 && ustrip(u"inch", side_cover) >= 2.5 &&
            ustrip(u"inch", tail_cover) >= 2.0
        ldh *= 0.7
    end
    return max(ldh, 8 * db_in, 6.0) * u"inch"
end

"""
Height from the soffit to the outside of a 90-degree hook tail.

The bend is Table 7.2 (corpus: aci-318-11, page 94) and the tail is §7.1.2
(page 93): 12 db past the bend. The centerline radius is half the inside
diameter plus half the bar diameter.
"""
function _hook_top(bar_size::Int, clear_cover::Length)
    db = bar_diameter(bar_size)
    bend = bar_size <= 8 ? 6db : bar_size <= 11 ? 8db : 10db
    radius = (bend + db) / 2
    return clear_cover + db / 2 + radius + 12db + db / 2
end

"""Center-to-center spacing of `n` bars across `width`, inset by cover and db/2."""
function _bar_spacing(n::Int, width::Length, clear_cover::Length, db::Length)
    n <= 1 && return width
    clear_span = width - 2 * (clear_cover + db / 2)
    clear_span <= zero(clear_span) && return db
    return clear_span / (n - 1)
end

"""
How the bottom bars of one plan develop from each column face.

Straight Eq. (12-1) first, at this bar and then at smaller bars. A 90-degree
hook is tried before the plan grows. §15.6.3 (corpus: aci-318-11, page 274):
each direction is measured from its own face.
"""
function _spread_anchorage(bar_size, As_gov, B, h, cover, fc, fy, λ,
                           avail_x, avail_y, max_s)
    for size in bar_size:-1:3
        db = bar_diameter(size)
        n = max(ceil(Int, As_gov / bar_area(size)), 2, ceil(Int, B / max_s))
        spacing = _bar_spacing(n, B, cover, db)
        ld = _development_length_footing(size, fc, fy, λ, db;
                                          clear_cover = cover, spacing = spacing)
        straight_x = ld <= avail_x
        straight_y = ld <= avail_y
        if straight_x && straight_y
            how = size == bar_size ? :straight : :smaller_bar
            return (ok = true, size = size, how = how)
        end
        tail_room = h - _hook_top(size, cover)
        ldh = _hooked_development_length(size, fc, fy, λ, db;
                                          side_cover = cover, tail_cover = tail_room)
        function dir_ok(straight, avail)
            straight && return true
            return tail_room >= zero(tail_room) && ldh <= avail
        end
        if dir_ok(straight_x, avail_x) && dir_ok(straight_y, avail_y)
            return (ok = true, size = size, how = :hook)
        end
    end
    return (ok = false, size = bar_size, how = :larger_plan)
end

"""
Whether one direction's bars develop in `avail` beyond the column face.

Straight Eq. (12-1) at `bar_size`, then a smaller bar, then a 90-degree
hook whose tail fits in `h`. `width` is the width those bars are spaced
across. ACI 318-11 §15.6.3 and §12.5 (corpus: aci-318-11, pages 274 and 217).
"""
function _one_way_anchorage(bar_size, As, width, h, cover, fc, fy, λ, avail, max_s)
    for size in bar_size:-1:3
        db = bar_diameter(size)
        n = max(ceil(Int, As / bar_area(size)), 2, ceil(Int, width / max_s))
        spacing = _bar_spacing(n, width, cover, db)
        ld = _development_length_footing(size, fc, fy, λ, db;
                                          clear_cover = cover, spacing = spacing)
        if ld <= avail
            how = size == bar_size ? :straight : :smaller_bar
            return (ok = true, size = size, how = how)
        end
        tail_room = h - _hook_top(size, cover)
        tail_room < zero(tail_room) && continue
        ldh = _hooked_development_length(size, fc, fy, λ, db;
                                          side_cover = cover, tail_cover = tail_room)
        if ldh <= avail
            return (ok = true, size = size, how = :hook)
        end
    end
    return (ok = false, size = bar_size, how = :larger_plan)
end

"""ACI 318-11 §10.14.1 — bearing check at column-footing interface (corpus: aci-318-11, page 162). Circular diameter is named `c1`. `col_along` / `col_across` are column-center stations on `Lf` and `B` (default: centered on the canonical `Lf` / `B`)."""
function _bearing_check_footing(Pu::Force, c1::Length, c2::Length,
                                 B::Length, Lf::Length, h::Length,
                                 fc::Pressure, fc_col::Pressure,
                                 fy::Pressure, ϕb::Float64,
                                 pier_shape::Symbol;
                                 col_along::Union{Length, Nothing} = nothing,
                                 col_across::Union{Length, Nothing} = nothing)
    # Inch *before* mixed arithmetic. Convert every unit after ustrip(inch),
    # including already-tagged inch/ft: production leftover is inch-tagged
    # after SI round-trip (`uconvert(inch, uconvert(m, 1ft))` ≈ 12 +
    # 1.78e-15), so a tag bypass lets `left > 0` open ACI 318-11 §10.14.1
    # (corpus: aci-318-11, page 162) and doubles Bn. Do not grid-round the
    # station onto leftover (`round(x/1e-12)*1e-12` sends 12+6e-13 to
    # 12+1e-12). Re-canonicalize Lf/2 and B/2 defaults so a column that
    # fills Lf is re-snapped. SI residuals are snapped on the four
    # overhangs after face subtraction. Not an ε-not-wider rule: 0.01 in
    # leftover stays leftover and still clips A2 per face.
    c1 = _canonical_inch(c1)
    c2 = _canonical_inch(c2)
    B  = _canonical_inch(B)
    Lf = _canonical_inch(Lf)
    h  = _canonical_inch(h)
    col_along  = _canonical_inch(col_along === nothing ? Lf / 2 : col_along)
    col_across = _canonical_inch(col_across === nothing ? B / 2 : col_across)

    A1 = pier_shape == :circular ? π * (c1 / 2)^2 : c1 * c2

    # Face overhangs from the loaded area to the support edges. ACI 318-11
    # §10.14.1 (corpus: aci-318-11, page 162) permits √(A2/A1) ≤ 2 only when
    # the supporting surface is wider on all sides than the loaded area
    # (R10.14.1: surrounding concrete confines the bearing area). Overall
    # L > c_along is not sufficient (end-flush strip). |overhang| ≤ 1e-12 in
    # is SI-conversion ulp only (inclusive: (12+1e-12)inch is flush) — treat
    # as 0 for the gate and that face's A2 clip. Do not invent a
    # construction tolerance.
    half_along  = c1 / 2
    half_across = (pier_shape == :circular ? c1 : c2) / 2
    left         = _snap_si_overhang(col_along - half_along)
    right        = _snap_si_overhang(Lf - col_along - half_along)
    across_minus = _snap_si_overhang(col_across - half_across)
    across_plus  = _snap_si_overhang(B - col_across - half_across)
    z = zero(left)
    wider_all_sides =
        left > z && right > z && across_minus > z && across_plus > z

    # ACI 318-11 notation A2 (corpus: aci-318-11, page 24): area of the lower
    # base of the largest frustum of a pyramid, cone, or tapered wedge
    # contained wholly within the support, upper base = loaded area, side
    # slopes 1 vertical to 2 horizontal. R10.14.1 / Fig. R10.14 (pages 162–
    # 163) apply the frustum to find A2. 1V:2H over thickness h ⇒ 2h
    # horizontal per unobstructed face (c+4h when both sides have ≥2h).
    # Clip each face independently — do not substitute the centered box
    # min(c+4h, Lf)×min(c+4h, B), which overstates A2 near an edge.
    two_h = 2 * h
    left_p  = max(left, z)
    right_p = max(right, z)
    am_p    = max(across_minus, z)
    ap_p    = max(across_plus, z)
    if pier_shape == :circular
        # Largest cone wholly in the support. The source gives no closed
        # form for a circle clipped by a rectangular edge, so the lower-base
        # radius is min(c1/2 + 2h, distance from center to nearest edge).
        # Edge distances use snapped overhangs so a SI-ulp face clips to
        # half-width (named c1), not a 1e-12 leftover radius.
        r_A2 = min(half_along + two_h,
                   half_along + left, half_along + right,
                   half_across + across_minus, half_across + across_plus)
        A2 = π * r_A2^2
    else
        A2 = (c1 + min(two_h, left_p) + min(two_h, right_p)) *
             (c2 + min(two_h, am_p) + min(two_h, ap_p))
    end

    # ustrip before min(..., 2): A2/A1 can be a NoDims Quantity when B, Lf, h
    # are SI metres and c1 is inches; min(Quantity, 2.0) is not a Float64.
    sqA = wider_all_sides ? min(ustrip(Unitful.NoUnits, sqrt(A2 / A1)), 2.0) : 1.0
    Bn_footing = ϕb * min(0.85 * fc * A1 * sqA, 2 * 0.85 * fc * A1)
    Bn_column  = ϕb * 0.85 * fc_col * A1

    need_dowels = Pu > Bn_column
    As_dowels = 0.0u"inch^2"
    if need_dowels
        As_dowels = max((Pu - Bn_column) / (ϕb * fy), 0.005 * A1)
    end

    return (Bn_footing = Bn_footing, Bn_column = Bn_column,
            need_dowels = need_dowels, As_dowels = As_dowels,
            footing_ok = Pu ≤ Bn_footing, sqA = sqA)
end

"""
    _spread_depth_index(min_depth, depth_increment, h_target) → Int

Grid index `k ∈ 0:59` of the first thickness

    h_k = min_depth + k * depth_increment

at or above `h_target`. A target at or below `min_depth` returns 0, so
the search still opens on `h_0`. A target above `h_59` clamps to 59.
"""
function _spread_depth_index(min_depth, depth_increment, h_target)
    tol = 1e-6u"inch"
    h = min_depth
    h_target <= h + tol && return 0
    for k in 1:59
        h += depth_increment
        h + tol >= h_target && return k
    end
    return 59
end

"""
    _spread_punching_depth_seed(qu, B, Lf, c1, c2, shape, fc, λ, ϕ, cover, db) → Length

Closed-form thickness *start* from direct two-way shear. Not a design
result and not a lower bound.

ACI 318-11 §11.11.2.1(c) Eq. (11-33) (corpus: aci-318-11, page 201):

    Vc = 4 λ √f'c · b0 · d

with φ for shear from §9.3.2.3 (corpus: aci-318-11, page 128). Rearranged,

    d ≈ Vu / (b0 · φ · 4 λ √f'c).

Only Eq. (11-33) is used — not the lesser of Eq. (11-31) and (11-32) —
and unbalanced-moment transfer (§11.11.7) is omitted. The critical
perimeter is the section at d/2 from the column (§11.11.1.2, page 200;
straight sides permitted by §11.11.1.3, page 201), so both `b0` and `Vu`
depend on `d`. The value below is the fixed point of that direct-shear
estimate. The grid search still accepts or rejects the thickness.
"""
function _spread_punching_depth_seed(qu, B, Lf, c1, c2, shape, fc, λ, ϕ, cover, db)
    cover_db = cover + db / 2
    s = ϕ * 4.0 * λ * sqrt(max(ustrip(u"psi", fc), 0.0))
    (s <= 0 || !isfinite(s)) && return cover_db
    qu_psi = ustrip(u"psi", qu)
    qu_psi <= 0 && return cover_db
    A = ustrip(u"inch", B) * ustrip(u"inch", Lf)
    A <= 0 && return cover_db
    d_in = if shape == :circular
        _circular_direct_punch_d(ustrip(u"inch", c1), qu_psi, A, s)
    else
        _rect_direct_punch_d(ustrip(u"inch", c1), ustrip(u"inch", c2), qu_psi, A, s)
    end
    (!isfinite(d_in) || d_in <= 0) && return cover_db
    return d_in * u"inch" + cover_db
end

# Fixed point of Eq. (11-33) for an interior rectangular section:
# b0 = 2(c1 + c2 + 2d), Vu = qu (A − (c1 + d)(c2 + d)). Start only.
function _rect_direct_punch_d(c1, c2, qu, A, s)
    rhs = qu * (A - c1 * c2)
    rhs <= 0 && return 0.0
    P = c1 + c2
    a = 4.0 * s + qu
    b = P * (2.0 * s + qu)
    a <= 0 && return 0.0
    disc = b * b + 4.0 * a * rhs
    disc < 0 && return 0.0
    d = (-b + sqrt(disc)) / (2.0 * a)
    return isfinite(d) ? max(d, 0.0) : 0.0
end

# Same fixed point for a circular column: b0 = π(D + d),
# Ac = π(D + d)²/4. Start only.
function _circular_direct_punch_d(D, qu, A, s)
    a = (s + qu / 4.0) * π
    b = -s * π * D
    c = -qu * A
    a <= 0 && return 0.0
    disc = b * b - 4.0 * a * c
    disc < 0 && return 0.0
    u = (-b + sqrt(disc)) / (2.0 * a)
    d = u - D
    return isfinite(d) ? max(d, 0.0) : 0.0
end

"""
    _smallest_spread_footing_depth(min_depth, depth_increment, passes; k_seed=0)

Smallest thickness on the spread-footing depth grid

    h_k = min_depth + k * depth_increment,   k = 0, 1, …, 59

for which `passes(h_k)` is true. `passes(h)` returns a named tuple
`(ok, punch, ow_ok)`. Each `h_k` is built by adding `depth_increment`
exactly `k` times, which is the thickness the linear scan tested at
that step (binary rounding included). The result is always one of
those grid points.

On a fixed plan the predicate improves with thickness: the effective-depth
gate, punching shear, and one-way shear. The search brackets that
predicate and bisects for the lowest passing index. `k_seed` is only the
first index evaluated. A passing seed is bisected down to `h_0`; a
failing seed is bisected up toward `h_59`. The accepted index is the
same one a search from `k = 0` returns. If `h_0` already passes, it is
returned without searching further.

When no point through `k = 59` passes, `ok` is false, `h` is one
increment past `h_59` (the scan's thickness after 60 increments), and
`punch` / `ow_ok` are the `k = 59` evaluation. A point that never
reached the shear checks because `d < 4 in` reports `punch === nothing`
and `ow_ok = false`.
"""
function _smallest_spread_footing_depth(min_depth, depth_increment, passes;
                                         k_seed::Int=0)
    function h_at(k::Int)
        h = min_depth
        for _ in 1:k
            h += depth_increment
        end
        return h
    end

    k_seed = clamp(k_seed, 0, 59)
    h_seed = h_at(k_seed)
    st_seed = passes(h_seed)
    if st_seed.ok
        if k_seed == 0
            return (ok = true, h = h_seed, punch = st_seed.punch, ow_ok = st_seed.ow_ok)
        end
        st0 = passes(h_at(0))
        if st0.ok
            return (ok = true, h = h_at(0), punch = st0.punch, ow_ok = st0.ow_ok)
        end
        lo = 0
        hi = k_seed
        best_h = h_seed
        best = st_seed
    else
        if k_seed >= 59
            return (ok = false, h = h_seed + depth_increment,
                    punch = st_seed.punch, ow_ok = st_seed.ow_ok)
        end
        h_last = h_at(59)
        st_last = passes(h_last)
        if !st_last.ok
            return (ok = false, h = h_last + depth_increment,
                    punch = st_last.punch, ow_ok = st_last.ow_ok)
        end
        lo = k_seed
        hi = 59
        best_h = h_last
        best = st_last
    end

    while hi - lo > 1
        mid = (lo + hi) ÷ 2
        h_mid = h_at(mid)
        st = passes(h_mid)
        if st.ok
            hi = mid
            best_h = h_mid
            best = st
        else
            lo = mid
        end
    end
    return (ok = true, h = best_h, punch = best.punch, ow_ok = best.ow_ok)
end

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

"""
    _spread_plan_for_actions(service, strength, qa, min_B, si, c1, c2)
        -> (B, L, cases)

Square plan on which every allowable-stress action has `q_max ≤ qa` and
`q_min ≥ 0`, and every compressive strength action stays in the kern.

Each case keeps that combination's own axial force and moment. The peak
pressure is ACI 336.2R §3.2.1 Eq. (3-1). A resultant outside the kern is
not converted to a partial-contact block.

# Citations
ASCE 7-22 §2.4.1 and §12.13.6 (corpus: asce-7-22, PDF pages 69 and 196):
the allowable pressure is not increased. ACI 336.2R §3.2.1 (corpus:
aci-336-combined-footings-mats, page 6).
"""
function _spread_plan_for_actions(service_actions, strength_actions, qa,
                                  min_B, si, c1, c2)
    any(a.P > 0 for a in strength_actions) || throw(ArgumentError(
        "spread footing: every strength combination is in uplift, so there " *
        "is no compressive contact pressure to size. ACI 336.2R §3.2.1 " *
        "Eq. (3-1) applies while the contact area is in compression " *
        "(corpus: aci-336-combined-footings-mats, page 6)."))
    B = min_B
    for a in service_actions
        a.P <= 0 && continue
        P = a.P * u"N"
        B = max(B, sqrt(P / qa))
        B = max(B, _kern_min_square_side(P, a.Mx * u"N*m", a.My * u"N*m"))
    end
    for a in strength_actions
        a.P <= 0 && continue
        P = a.P * u"N"
        B = max(B, _kern_min_square_side(P, a.Mx * u"N*m", a.My * u"N*m"))
    end
    B = ceil(ustrip(u"inch", B) / ustrip(u"inch", si)) * si
    B = max(B, min_B)
    Lf = B
    cases = nothing
    for _ in 1:80
        built = _spread_action_cases(strength_actions, B, Lf, c1, c2)
        service_ok = all(_service_action_ok(a, B, Lf, qa) for a in service_actions)
        strength_ok = all(c.in_kern for c in built)
        if service_ok && strength_ok && !isempty(built)
            cases = built
            break
        end
        B += si
        Lf = B
    end
    cases === nothing && error(
        "Spread footing plan did not keep every ASCE 7-22 combination in the " *
        "ACI 336.2R §3.2.1 kern with service q_max ≤ qa after 80 size " *
        "increments (B=$B). Eq. (3-1) is not applied as full contact when " *
        "q_min < 0 (corpus: aci-336-combined-footings-mats, page 6; " *
        "asce-7-22, PDF pages 69–70).")
    return B, Lf, cases
end

function _spread_action_cases(actions, B, Lf, c1, c2)
    out = NamedTuple[]
    for a in actions
        a.P <= 0 && continue
        P = a.P * u"N"
        Mx = a.Mx * u"N*m"
        My = a.My * u"N*m"
        qe = _eccentric_soil_pressure(P, Mx, My, B, Lf)
        arm_x = (Lf - c1) / 2
        arm_y = (B - c2) / 2
        push!(out, (
            qu = qe.q_max,
            in_kern = _eccentric_in_kern(qe),
            Mux = Mx,
            Muy = My,
            Mu_x = qe.q_max * B * arm_x^2 / 2,
            Mu_y = qe.q_max * Lf * arm_y^2 / 2,
            Pu = P,
        ))
    end
    return out
end

"""True when this allowable-stress action is inside the kern and at most `qa`."""
function _service_action_ok(a::FootingAction, B, Lf, qa)
    a.P <= 0 && return true
    P = a.P * u"N"
    qe = _eccentric_soil_pressure(P, a.Mx * u"N*m", a.My * u"N*m", B, Lf)
    return _eccentric_in_kern(qe) && qe.q_max ≤ qa
end

"""`q_max / qa` for one allowable-stress action. Uplift contributes nothing."""
function _service_pressure_ratio(a::FootingAction, B, Lf, qa)
    a.P <= 0 && return 0.0
    P = a.P * u"N"
    qe = _eccentric_soil_pressure(P, a.Mx * u"N*m", a.My * u"N*m", B, Lf)
    return ustrip(u"kPa", qe.q_max) / ustrip(u"kPa", qa)
end

"""
    design_footing(::SpreadFooting, demand, soil; opts,
                   service_actions, strength_actions) → SpreadFootingResult

Design a spread (isolated) footing per ACI 318-11. Unbalanced-moment
punching transfer is §11.11.7.2 (corpus: aci-318-11, page 210).
ACI 318-19 §8.4.4.2 is the later number for the same stress.

Empty `service_actions` keeps the single `(Pu, Ps, Mux, Muy)` on `demand`.
A filled list sizes the plan from every allowable-stress action and the
concrete from every strength action. ASCE 7-22 §2.3 and §2.4 (corpus:
asce-7-22, PDF pages 68–70). The allowable pressure is not increased.

# Arguments
- `demand::FoundationDemand`: `Pu`, `Ps`, and column geometry `c1`, `c2`,
  `shape`. `Mux` and `Muy` are the punching moments when the action lists
  are empty.
- `soil::Soil`: `qa` is the net allowable bearing pressure.

# Keyword Arguments
- `opts::SpreadParams`: Material, cover, depth and size increments.
  Column dimensions come from `demand`.
- `service_actions`, `strength_actions`: one [`FootingAction`](@ref) per
  combination. Both empty, or both filled.

# Example
```julia
d = FoundationDemand(1; Pu=912.0kip, Ps=670.0kip, c1=18u"inch", c2=18u"inch", shape=:rectangular)
s = Soil(5.37ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
opts = SpreadParams(material=RC_3000_60)
result = design_footing(SpreadFooting(), d, s; opts)
```
"""
function design_footing(::SpreadFooting,
    demand::FoundationDemand,
    soil::Soil;
    opts::SpreadParams = SpreadParams(),
    tc::Union{Nothing, TraceCollector} = nothing,
    # Empty: the single (Pu, Ps, Mux, Muy) on `demand` is used.
    # Filled: every allowable-stress action sizes the plan against qa, and
    # every strength action sizes the concrete. ASCE 7-22 §2.4 / §2.3
    # (corpus: asce-7-22, PDF pages 68–70) and §12.13.6 (PDF page 196).
    service_actions::Vector{FootingAction}=FootingAction[],
    strength_actions::Vector{FootingAction}=FootingAction[],
)
    demand.Pu isa Unitful.Quantity ||
        throw(ArgumentError("ACI spread footing Pu must be Unitful; bare Real is rejected"))
    StructuralSizer.emit!(tc, :checker, "design_footing_spread_aci", "foundation_group_$(demand.group_idx)", :enter;
                          qa_kPa=Float64(ustrip(u"kPa", soil.qa)),
                          Pu_kN=Float64(ustrip(u"kN", demand.Pu)),
                          Ps_kN=Float64(ustrip(u"kN", demand.Ps)),
                          c1_in=Float64(ustrip(u"inch", demand.c1)),
                          c2_in=Float64(ustrip(u"inch", demand.c2)),
                          shape=string(demand.shape),
                          min_depth_in=Float64(ustrip(u"inch", opts.min_depth)),
                          depth_increment_in=Float64(ustrip(u"inch", opts.depth_increment)),
                          size_increment_in=Float64(ustrip(u"inch", opts.size_increment)))
    # Column geometry: single source of truth is FoundationDemand (ACI 318-11)
    c1     = demand.c1
    c2     = demand.c2
    col_shape = demand.shape
    # Material / option extraction
    fc     = opts.material.concrete.fc′
    fy     = opts.material.rebar.Fy
    λ      = something(opts.λ, opts.material.concrete.λ)
    fc_col = something(opts.fc_col, fc)
    cover  = opts.cover
    db     = bar_diameter(opts.bar_size)
    Ab     = bar_area(opts.bar_size)
    ϕf     = opts.ϕ_flexure
    ϕv     = opts.ϕ_shear
    ϕb     = opts.ϕ_bearing
    Ps     = demand.Ps
    Pu     = demand.Pu
    qa     = soil.qa

    # =====================================================================
    # Step 1: Preliminary Sizing
    # =====================================================================
    # ACI 336.2R §3.2.1 Eq. (3-1) (corpus: aci-336-combined-footings-mats,
    # page 6): for a rectangular rigid footing with the resultant along a
    # principal axis, q_max,min = (P/A)(1 ± 6e/Z).  §4.1 (page 7) applies
    # the same linear rigid-body distribution when the resultant is
    # eccentric about the centroid.  Superposition on both principal axes
    # uses |e| so q_max is the peak corner:
    #   q_max,min = P/(B L) (1 ± 6 |ex|/L ± 6 |ey|/B)
    # with ex = Mux/P, ey = Muy/P.  Size the plan from q_max ≤ qa (service).
    si = opts.size_increment
    # Minimum projection each side (6")
    min_B = max(c1, c2) + 2 * 6.0u"inch"
    P_abs = abs(Pu)
    action_cases = nothing
    if isempty(service_actions)
        # One (Pu, Ps, Mux, Muy). Eccentricity is Mux/Pu. That equals the
        # service eccentricity only when Ms/Ps = Mux/Pu.
        A_req = Ps / qa
        B = sqrt(A_req)
        B = ceil(ustrip(u"inch", B) / ustrip(u"inch", si)) * si
        B = max(B, min_B)
        Lf = B
        plan_ok = true
        if P_abs > zero(P_abs)
            B = max(B, _kern_min_square_side(Pu, demand.Mux, demand.Muy))
            B = ceil(ustrip(u"inch", B) / ustrip(u"inch", si)) * si
            B = max(B, min_B)
            Lf = B
            plan_ok = false
            for _ in 1:80
                qe = _eccentric_soil_pressure(Pu, demand.Mux, demand.Muy, B, Lf)
                q_max_s = (Ps / (B * Lf)) * (qe.q_max / qe.qu)
                if _eccentric_in_kern(qe) && q_max_s ≤ qa
                    plan_ok = true
                    break
                end
                B += si
                Lf = B
            end
            if !plan_ok
                StructuralSizer.emit!(tc, :checker, "design_footing_spread_aci", "foundation_group_$(demand.group_idx)", :failure;
                                      reason="kern_or_bearing_plan_nonconvergence",
                                      B_in=Float64(ustrip(u"inch", B)))
                error("Spread footing plan did not stay in the ACI 336.2R §3.2.1 kern " *
                      "(q_min ≥ 0) with q_max ≤ qa after 80 size increments (B=$B). " *
                      "Increase size_increment budget or reduce eccentricity; Eq. (3-1) " *
                      "is not applied as full contact when q_min < 0 (corpus: " *
                      "aci-336-combined-footings-mats, page 6).")
            end
        end
    else
        # Each combination keeps its own axial force and moment. Wind and
        # earthquake factors do not cancel between service and strength.
        isempty(strength_actions) && throw(ArgumentError(
            "spread footing: service combinations were passed without the " *
            "strength combinations. ASCE 7-22 §2.3 sizes the concrete and " *
            "§2.4 sizes the soil pressure (corpus: asce-7-22, PDF pages 68–70)."))
        B, Lf, action_cases = _spread_plan_for_actions(
            service_actions, strength_actions, qa, min_B, si, c1, c2)
    end

    # Thickness, flexure, then development. A bar that does not develop
    # steps down, then a 90-degree hook, then a larger plan. Each larger
    # plan repeats punching, one-way shear, and flexure.
    bar_size = opts.bar_size
    anchorage = :straight
    h = opts.min_depth
    punch = nothing
    d = h - cover - db / 2
    n_bars = 2
    As_provided = Ab
    developed = false
    for attempt in 1:40
        db = bar_diameter(bar_size)
        Ab = bar_area(bar_size)
        if action_cases === nothing
            # Factored net soil pressure — size structural checks from q_max
            # only after the plan is in the kern (ACI 336.2R §3.2.1 / §4.1).
            q_u = _eccentric_soil_pressure(Pu, demand.Mux, demand.Muy, B, Lf)
            if P_abs > zero(P_abs) && !_eccentric_in_kern(q_u)
                error("Spread footing Eq. (3-1) q_min < 0 at B=$B (ACI 336.2R §3.2.1, " *
                      "corpus: aci-336-combined-footings-mats, page 6); refuse rather than " *
                      "treat partial uplift as full-contact pressure.")
            end
            qu = q_u.q_max
        else
            # Each strength combination at this plan. A larger plan only
            # moves the resultant further inside the kern.
            action_cases = _spread_action_cases(strength_actions, B, Lf, c1, c2)
            all(c.in_kern for c in action_cases) || error(
                "Spread footing Eq. (3-1) q_min < 0 at B=$B for a strength combination " *
                "(ACI 336.2R §3.2.1, corpus: aci-336-combined-footings-mats, page 6).")
            qu = maximum(c.qu for c in action_cases)
        end

        # Effective depth d per ACI 318-11 §2.2 (corpus: aci-318-11, page 37):
        # d = h − cover − db/2 for one layer. The depth grid is
        # h_k = min_depth + k·depth_increment, k = 0..59.
        arm_x = (Lf - c1) / 2
        arm_y = (B  - c2) / 2
        Mu_x = qu * B  * arm_x^2 / 2
        Mu_y = qu * Lf * arm_y^2 / 2

        function _case_depth_ok(h_try, qu_c, Mux_c, Muy_c, Mu_x_c, Mu_y_c)
            d_try = h_try - cover - db / 2
            d_try < 4.0u"inch" && return (ok = false, punch = nothing, ow_ok = false)
            _footing_flexure_ok(((Mu_x_c, B), (Mu_y_c, Lf)), d_try, fc, fy, ϕf) ||
                return (ok = false, punch = nothing, ow_ok = false)

            # Two-way (punching) shear with biaxial moments
            Ac = col_shape == :circular ?
                 π * (c1 + d_try)^2 / 4 : (c1 + d_try) * (c2 + d_try)
            Vu_p = qu_c * (B * Lf - Ac)
            punch_try = punching_check(Vu_p, Mux_c, Muy_c, d_try, fc, c1, c2;
                                        position = :interior, shape = col_shape,
                                        λ = λ, ϕ = ϕv)

            # One-way shear in both directions
            ϕVc = ϕv * one_way_shear_capacity(fc, B, d_try; λ = λ)
            cant_x = (Lf - c1) / 2 - d_try
            cant_y = (B  - c2) / 2 - d_try
            ow_ok = true
            if cant_x > 0u"inch"
                Vu_x = uconvert(u"lbf", qu_c * B * cant_x)
                ow_ok = ow_ok && Vu_x ≤ ϕVc
            end
            if cant_y > 0u"inch"
                Vu_y = uconvert(u"lbf", qu_c * Lf * cant_y)
                ow_ok = ow_ok && Vu_y ≤ ϕVc
            end
            return (ok = punch_try.ok && ow_ok, punch = punch_try, ow_ok = ow_ok)
        end

        function _depth_passes(h_try)
            # One gravity demand: the factored pressure and its end moments.
            # Several combinations: each strength combination, with its own
            # pressure and moment. ASCE 7-22 §2.3.1 (corpus: asce-7-22, PDF page 68).
            if action_cases === nothing
                return _case_depth_ok(h_try, qu, demand.Mux, demand.Muy, Mu_x, Mu_y)
            end
            punch_c = nothing
            ow_ok = true
            for c in action_cases
                r = _case_depth_ok(h_try, c.qu, c.Mux, c.Muy, c.Mu_x, c.Mu_y)
                r.punch === nothing || (punch_c = r.punch)
                ow_ok = ow_ok && r.ow_ok
                r.ok || return (ok = false, punch = punch_c, ow_ok = ow_ok)
            end
            return (ok = true, punch = punch_c, ow_ok = ow_ok)
        end

        h_seed = _spread_punching_depth_seed(qu, B, Lf, c1, c2, col_shape, fc, λ, ϕv, cover, db)
        k_seed = _spread_depth_index(opts.min_depth, opts.depth_increment, h_seed)
        selected = _smallest_spread_footing_depth(opts.min_depth, opts.depth_increment,
                                                   _depth_passes; k_seed = k_seed)
        if !selected.ok
            StructuralSizer.emit!(tc, :checker, "design_footing_spread_aci",
                                  "foundation_group_$(demand.group_idx)", :failure;
                                  reason = "depth_iteration_nonconvergence",
                                  h_in = Float64(ustrip(u"inch", selected.h)),
                                  last_punch_ok = selected.punch !== nothing && selected.punch.ok,
                                  last_punch_ratio = selected.punch === nothing ? nothing :
                                                     Float64(selected.punch.utilization),
                                  last_one_way_ok = Bool(selected.ow_ok))
            error("Spread footing depth did not converge after 60 iterations (h=$(selected.h)). " *
                  "Check bearing pressure, column dimensions, or increase max depth.")
        end
        h = selected.h
        punch = selected.punch
        d = h - cover - db / 2

        # Step 4: flexural reinforcement at the column face, the worst
        # strength combination when there are several.
        if action_cases === nothing
            As_x = max(_flexural_steel_footing(Mu_x, B, d, fc, fy, ϕf),
                       _min_steel_footing(B, h, fy))
            As_y = max(_flexural_steel_footing(Mu_y, Lf, d, fc, fy, ϕf),
                       _min_steel_footing(Lf, h, fy))
        else
            As_x = maximum(max(_flexural_steel_footing(c.Mu_x, B, d, fc, fy, ϕf),
                               _min_steel_footing(B, h, fy)) for c in action_cases)
            As_y = maximum(max(_flexural_steel_footing(c.Mu_y, Lf, d, fc, fy, ϕf),
                               _min_steel_footing(Lf, h, fy)) for c in action_cases)
        end
        As_gov = max(As_x, As_y)
        # Spacing ≤ min(3h, 18 in.): ACI 318-11 §7.6.5 (corpus: aci-318-11, page 96).
        max_s = min(3h, 18.0u"inch")
        n_bars = max(ceil(Int, As_gov / Ab), 2, ceil(Int, B / max_s))
        As_provided = n_bars * Ab

        if !opts.check_development
            anchorage = attempt == 1 ? :straight : :larger_plan
            developed = true
            break
        end
        fit = _spread_anchorage(opts.bar_size, As_gov, B, h, cover, fc, fy, λ,
                                arm_x - cover, arm_y - cover, max_s)
        if fit.ok
            if fit.size != bar_size
                bar_size = fit.size
                db = bar_diameter(bar_size)
                Ab = bar_area(bar_size)
                n_bars = max(ceil(Int, As_gov / Ab), 2, ceil(Int, B / max_s))
                As_provided = n_bars * Ab
                d = h - cover - db / 2
            end
            anchorage = attempt == 1 ? fit.how : :larger_plan
            developed = true
            break
        end
        B += si
        Lf = B
    end
    if !developed
        error("Spread footing reinforcement does not develop from the column " *
              "face within 40 plan increments (B=$B). ACI 318-11 §15.6.3 " *
              "(corpus: aci-318-11, page 274).")
    end

    # =====================================================================
    # Step 6 & 7: Bearing & Dowels (ACI 22.8)
    # =====================================================================
    if opts.check_bearing
        Pu_col = action_cases === nothing ? Pu : maximum(c.Pu for c in action_cases)
        bearing = _bearing_check_footing(Pu_col, c1, c2, B, Lf, h,
                                          fc, fc_col, fy, ϕb, col_shape)
        bearing.need_dowels && opts.check_dowels &&
            @info "Dowels required: As_dowels = $(bearing.As_dowels)"
    end

    # =====================================================================
    # Utilization
    # =====================================================================
    util_bearing = if action_cases === nothing
        to_kip(Ps) / to_kip(qa * B * Lf)
    else
        maximum(_service_pressure_ratio(a, B, Lf, qa) for a in service_actions)
    end
    utilization  = max(punch.utilization, util_bearing)

    # =====================================================================
    # Result (SI output)
    # =====================================================================
    V_conc  = uconvert(u"m^3", B * Lf * h)
    bar_len = B - 2cover
    V_steel = uconvert(u"m^3", 2 * n_bars * Ab * bar_len)

    result = SpreadFootingResult{typeof(uconvert(u"m", B)),
                               typeof(V_conc),
                               typeof(Pu)}(
        uconvert(u"m", B),
        uconvert(u"m", Lf),
        uconvert(u"m", h),
        uconvert(u"m", d),
        uconvert(u"m", As_provided / B),   # As per unit width (m²/m = m)
        n_bars,
        uconvert(u"m", db),
        V_conc,
        V_steel,
        utilization,
        FoundationUtilizations(; bearing = Float64(util_bearing),
                               punching = Float64(punch.utilization)),
    )
    StructuralSizer.emit!(tc, :checker, "design_footing_spread_aci", "foundation_group_$(demand.group_idx)", :exit;
                          B_m=Float64(ustrip(u"m", result.B)),
                          L_m=Float64(ustrip(u"m", result.L_ftg)),
                          D_m=Float64(ustrip(u"m", result.D)),
                          utilization=Float64(result.utilization),
                          anchorage=String(anchorage),
                          bar_size=bar_size)
    return result
    # (unreachable) — kept to avoid accidentally placing emit! after return
end
