# ─────────────────────────────────────────────────────────────────────────────
# ACI 421.1R-99 Appendix B — Properties of critical sections of GENERAL shape
# ─────────────────────────────────────────────────────────────────────────────
#
# The closed-form rectangular Jc expressions above apply only to right-angle
# interior/edge/corner columns. For non-orthogonal (e.g. 60°) and re-entrant
# (L-shape inside) corners, ACI 421.1R-99 Appendix B (corpus: aci-421-1r-99,
# p. 421.1R-11..13) gives the properties of a critical section whose perimeter
# is a chain of straight segments, by summation:
#
#   Ac = d · Σ l                                            (B-1)
#   Ix = Σ (d·l/3)(y_i² + y_i·y_j + y_j²)                   (B-2)
#   Iy = Σ (d·l/3)(x_i² + x_i·x_j + x_j²)                   (B-3)
#
# where (x_i,y_i),(x_j,y_j) are a segment's endpoints in CENTROIDAL coordinates
# and l is its length. The polar-moment analogs are approximated by the in-plane
# second moments: Jx ≈ Ix, Jy ≈ Iy (App. B, stated explicitly). This drops the
# out-of-plane self term that the exact rectangular Eq. (3.4) keeps (e.g. the
# b1·d³/6 of an interior column), so the general method is slightly CONSERVATIVE
# (smaller J → higher stress) relative to `polar_moment_Jc_interior/edge/corner`
# — the behavior the code sanctions for "sections of general shape".
#
# TRUE PRINCIPAL AXES: Eq. (3.2) assumes `x,y` are the section's principal axes
# (no product-of-inertia coupling). Rather than require a symmetric section, we
# also sum the product of inertia Ixy and rotate to the frame where Ixy→0, then
# apply Eq. (3.2) there. This keeps the method exact (within `J≈I`) for
# asymmetric sections (e.g. an L-notch) — the standard-mechanics generalization
# of what 421.1R writes for the aligned case. A rotated rectangle therefore
# gives the same vu as the unrotated one (invariance), which the tests assert.
#
# This one polygon path covers every support shape: rectangular/edge/corner,
# non-orthogonal wedges, re-entrant L-notches, circular (ring discretized by
# `circular_critical_section`), and I-/odd shapes (pass the effective loaded-area
# polygon per ACI 421.3R-15 §4.8).
#
# CONVENTION (ACI 421.1R-99 Eq. 3.2, corpus p. 421.1R-4): `Mux` is the moment
# ABOUT the centroidal x-axis; its shear stress varies with the y-coordinate.
# `Muy` is about the y-axis. This is the OPPOSITE labeling to the rectangular
# `punching_check` path above (which treats `Mux` as the moment whose stress
# varies in x); callers must map into this convention explicitly.

"""
    critical_section_segments(points; closed=true) -> Vector{Tuple{Int,Int}}

Index pairs of the straight segments of a critical-section perimeter defined by
ordered `points`. `closed=true` (interior column, full loop) appends the closing
segment `(n, 1)`; `closed=false` leaves the perimeter open (edge/corner, where
the critical section stops at free slab edges).
"""
function critical_section_segments(points::AbstractVector; closed::Bool = true)
    n = length(points)
    n ≥ 2 || throw(ArgumentError("need ≥ 2 points for a critical section; got $n"))
    seg = [(i, i + 1) for i in 1:(n - 1)]
    closed && n ≥ 3 && push!(seg, (n, 1))
    return seg
end

"""
    critical_section_properties(points, d; closed=true) -> NamedTuple

ACI 421.1R-99 Appendix B properties of the critical section whose perimeter is
the polyline/polygon through `points` (each a `(x, y)` `Tuple` of `Length` in
the slab plane, in any consistent frame — typically centered on the column).
`closed=true` adds the closing segment (4-sided interior / full ring);
`closed=false` keeps the perimeter open (edge/corner with free edges).

Second moments are evaluated by the Appendix B segment summation, extended to
the product of inertia so the section's **true principal axes** can be found —
ACI 421.1R-99 Eq. (3.2) is the special case in which `x,y` are already
principal. For a straight segment with centroidal endpoints `(xi,yi),(xj,yj)`
and length `l`:

    Ix = Σ (d·l/3)(yi² + yi·yj + yj²)                       (B-2)
    Iy = Σ (d·l/3)(xi² + xi·xj + xj²)                       (B-3)
    Ixy = Σ (d·l/6)(2·xi·yi + xi·yj + xj·yi + 2·xj·yj)      (standard line ∫xy ds)

The principal angle is `θp = ½·atan2(−2·Ixy, Ix−Iy)` (where `Ixy'→0`), with
principal second moments `J1 ≈ Ix'`, `J2 ≈ Iy'` re-summed in the rotated frame
(so `Jx≈Ix`, `Jy≈Iy` per App. B, but now on the principal axes).

Returns `(Ac, b0, xc, yc, Ix, Iy, Ixy, θp, J1, J2, l1, l2, e1, e2)`:
- `Ac = d·Σl`, `b0 = Σl`                                   (Eq. B-1)
- `(xc, yc)`: length-weighted centroid in the INPUT frame
- `Ix, Iy, Ixy`: centroidal second moments in the INPUT frame
- `θp`: principal-axis rotation (rad); `e1, e2`: principal unit vectors
- `J1, J2`: principal second moments (≈ polar-moment analogs)
- `l1, l2`: section projections on the principal axes (Fig. B2), for γv.

All dimensional quantities are Unitful.

Reference: ACI 421.1R-99 Appendix B, Eq. (B-1)–(B-3) (corpus: aci-421-1r-99,
p. 421.1R-11); principal-axis rotation is standard mechanics.
"""
function critical_section_properties(points::AbstractVector, d::Length;
                                     closed::Bool = true, segments=nothing)
    xs = [ustrip(u"inch", p[1]) for p in points]
    ys = [ustrip(u"inch", p[2]) for p in points]
    dd = ustrip(u"inch", d)
    seg = segments === nothing ? critical_section_segments(points; closed = closed) : segments

    # (B-1): perimeter b0 and the length-weighted (uniform-strip) centroid.
    b0 = 0.0
    sx = 0.0
    sy = 0.0
    for (i, j) in seg
        l = hypot(xs[j] - xs[i], ys[j] - ys[i])
        b0 += l
        sx += l * (xs[i] + xs[j]) / 2
        sy += l * (ys[i] + ys[j]) / 2
    end
    b0 > 0 || throw(ArgumentError("degenerate critical section (zero perimeter)"))
    xc = sx / b0
    yc = sy / b0

    # Second moments about the centroidal axes of the INPUT frame (per unit d),
    # including the product of inertia Ixy needed for the principal axes.
    Ix = 0.0
    Iy = 0.0
    Ixy = 0.0
    for (i, j) in seg
        xi = xs[i] - xc
        yi = ys[i] - yc
        xj = xs[j] - xc
        yj = ys[j] - yc
        l = hypot(xj - xi, yj - yi)
        Ix += dd * l / 3 * (yi^2 + yi * yj + yj^2)
        Iy += dd * l / 3 * (xi^2 + xi * xj + xj^2)
        Ixy += dd * l / 6 * (2xi * yi + xi * yj + xj * yi + 2xj * yj)
    end

    # Principal axes: rotate to the frame where the product of inertia vanishes.
    # Both θp and θp±90° are valid principal choices; normalize to (−45°, 45°] so
    # axis 1 stays aligned with the input x-axis for (near-)axis-aligned sections.
    # This only fixes which principal axis is labeled "1" vs "2" — the stress
    # result is invariant to the choice (the moment vector and vertex coordinates
    # are resolved with the same θp).
    θp = 0.5 * atan(-2 * Ixy, Ix - Iy)
    if θp > π / 4
        θp -= π / 2
    elseif θp ≤ -π / 4
        θp += π / 2
    end
    c = cos(θp)
    s = sin(θp)

    # Re-sum J1≈Ix', J2≈Iy' and the projections in the principal frame, reusing
    # the App. B summation on the rotated vertices (x' = x·c + y·s, y' = −x·s + y·c).
    J1 = 0.0
    J2 = 0.0
    for (i, j) in seg
        xi = xs[i] - xc; yi = ys[i] - yc
        xj = xs[j] - xc; yj = ys[j] - yc
        xi1 = xi * c + yi * s; yi1 = -xi * s + yi * c
        xj1 = xj * c + yj * s; yj1 = -xj * s + yj * c
        l = hypot(xj1 - xi1, yj1 - yi1)
        J1 += dd * l / 3 * (yi1^2 + yi1 * yj1 + yj1^2)
        J2 += dd * l / 3 * (xi1^2 + xi1 * xj1 + xj1^2)
    end
    x1 = [(xs[k] - xc) * c + (ys[k] - yc) * s for k in eachindex(xs)]
    y1 = [-(xs[k] - xc) * s + (ys[k] - yc) * c for k in eachindex(xs)]
    l1 = maximum(x1) - minimum(x1)
    l2 = maximum(y1) - minimum(y1)

    return (Ac = dd * b0 * u"inch^2", b0 = b0 * u"inch",
            xc = xc * u"inch", yc = yc * u"inch",
            Ix = Ix * u"inch^4", Iy = Iy * u"inch^4", Ixy = Ixy * u"inch^4",
            θp = θp, J1 = J1 * u"inch^4", J2 = J2 * u"inch^4",
            l1 = l1 * u"inch", l2 = l2 * u"inch",
            e1 = (c, s), e2 = (-s, c))
end

"""
    gamma_v_general(l1, l2) -> (γv1, γv2)

Moment-transfer fractions by eccentricity of shear for a general-shape critical
section, ACI 421.1R-99 Eq. (3.3) / Fig. B2 (corpus: aci-421-1r-99, p. 421.1R-4):

    γv1 = 1 − 1/(1 + (2/3)√(l2/l1))
    γv2 = 1 − 1/(1 + (2/3)√(l1/l2))

`l1`, `l2` are the section's projections on its principal axes. `γv1` pairs with
the moment about principal axis 1 (stress ∝ the axis-2 coordinate); `γv2` with
the moment about principal axis 2.
"""
function gamma_v_general(l1::Length, l2::Length)
    r1 = ustrip(u"inch", l2) / ustrip(u"inch", l1)
    r2 = ustrip(u"inch", l1) / ustrip(u"inch", l2)
    γv1 = 1.0 - 1.0 / (1.0 + (2.0 / 3.0) * sqrt(r1))
    γv2 = 1.0 - 1.0 / (1.0 + (2.0 / 3.0) * sqrt(r2))
    return (γv1, γv2)
end

"""
    punching_stress_general(Vu, Mux, Muy, points, d; closed=true) -> NamedTuple

Maximum factored punching shear stress on a critical section of general shape,
ACI 421.1R-99 Eq. (3.2) with γv from Eq. (3.3), evaluated on the section's
**true principal axes** so it is exact (within the App. B `J≈I` approximation)
for asymmetric sections too. `Mux`/`Muy` are the unbalanced moments about the
centroidal x/y axes of the INPUT frame (`Mux` about x, `Muy` about y); they are
resolved into principal components `(M1, M2)` internally:

!!! warning "Moment convention differs from `punching_check`"
    This engine follows the standard-mechanics / ACI 421.1R convention: `Mux`
    is the moment **about the x-axis**, so it drives stress variation in **y**
    (at `θp=0`, the term is `γv1·Mux·y/J1`); `Muy` (about y) drives stress in
    **x**. The closed-form [`punching_check`](@ref) names its arguments by the
    *direction of stress variation* instead — its `Mux` drives stress in **x**.
    So mapping a moment between the two is a swap: `punching_check` `Mux`
    (stress in x) ≡ this engine's `Muy`, and vice-versa. Callers bridging the
    two (e.g. the re-entrant corner path in `check_punching_for_column`) must
    map explicitly; a convention-lock test pins this against the closed form.

    vu = Vu/Ac + γv1·M1·s2/J1 + γv2·M2·s1/J2

where `(s1, s2)` are a vertex's coordinates on the principal axes. The stress is
evaluated at every vertex and the governing value returned; the moment term is
taken in absolute value before adding the always-additive `Vu/Ac`, matching the
closed-form practice of evaluating at the farthest fiber. `vu` is that value.

`direction` is the unit vector from the section centroid to the single vertex
where the signed moment term is largest, and only when that positive peak
equals the absolute term added into `vu`. Two vertices within tolerance, a
zero moment, a positive peak smaller than the absolute term, or either
principal moment under 2% of `Vu/Ac` (`moment_names_a_face`) leave
`direction` as `nothing`. A positive moment and its negative name opposite
vertices and the same `vu`.

Returns `(vu, Ac, b0, J1, J2, θp, γv1, γv2, props, direction)`.

Reference: ACI 421.1R-99 Eq. (3.2)–(3.3), Appendix B (corpus: aci-421-1r-99,
p. 421.1R-4, 11).
"""
function punching_stress_general(Vu::Force, Mux::Torque, Muy::Torque,
                                 points::AbstractVector, d::Length;
                                 closed::Bool = true, segments=nothing)
    p = critical_section_properties(points, d; closed = closed, segments = segments)
    c = cos(p.θp)
    s = sin(p.θp)

    # Resolve the applied moment vector (Mux about x, Muy about y) onto the
    # principal axes with the same rotation used for the geometry.
    M1 = Mux * c + Muy * s
    M2 = -Mux * s + Muy * c
    γv1, γv2 = gamma_v_general(p.l1, p.l2)

    v_direct = uconvert(u"psi", Vu / p.Ac)

    # vu adds the absolute moment term (the farthest fiber). The face is the
    # vertex where that term is positive. ACI 421.1R-99 Eq. (3.2).
    v_abs = 0.0u"psi"
    v_pos = 0.0u"psi"
    m1_peak = 0.0
    m2_peak = 0.0
    terms = Vector{Float64}(undef, length(points))
    for (k, pt) in enumerate(points)
        x = pt[1] - p.xc
        y = pt[2] - p.yc
        s1 = x * c + y * s        # coordinate on principal axis 1
        s2 = -x * s + y * c       # coordinate on principal axis 2
        t1 = uconvert(u"psi", γv1 * M1 * s2 / p.J1)
        t2 = uconvert(u"psi", γv2 * M2 * s1 / p.J2)
        term = t1 + t2
        terms[k] = ustrip(u"psi", term)
        m1_peak = max(m1_peak, abs(ustrip(u"psi", t1)))
        m2_peak = max(m2_peak, abs(ustrip(u"psi", t2)))
        v_abs = max(v_abs, abs(term))
        v_pos = max(v_pos, term)
    end

    # Either principal moment under 2% of Vu/Ac does not name a face. The
    # stress above still adds both. moment_names_a_face is that judgment.
    direct_psi = abs(ustrip(u"psi", v_direct))
    named = moment_names_a_face(m1_peak, direct_psi) &&
            moment_names_a_face(m2_peak, direct_psi)
    direction = named ?
        _unique_vertex_direction(points, terms, p.xc, p.yc, v_abs, v_pos) :
        nothing
    return (vu = v_direct + v_abs, Ac = p.Ac, b0 = p.b0,
            J1 = p.J1, J2 = p.J2, θp = p.θp, γv1 = γv1, γv2 = γv2, props = p,
            direction = direction)
end

"""
Unit vector from the centroid to the one vertex whose signed moment term
equals the absolute term added into `vu`, or `nothing`.

ACI 421.1R-99 Eq. (3.2) (corpus: aci-421-1r-99, p. 421.1R-4). The reported
stress adds `|moment term|` to `Vu/Ac`. That fiber is the vertex where the
signed term is positive and equal to the absolute peak. A second vertex
within tolerance, a moment below `1e-4 psi`, or a positive peak smaller than
the absolute term names no face.
"""
function _unique_vertex_direction(points, terms_psi, xc, yc, v_abs, v_pos)
    abs_psi = ustrip(u"psi", v_abs)
    pos_psi = ustrip(u"psi", v_pos)
    abs_psi > 1e-4 || return nothing
    abs(pos_psi - abs_psi) <= max(1e-3, 1e-4 * abs_psi) || return nothing
    tol = max(1e-4, 1e-6 * abs_psi)
    winners = Int[]
    for k in eachindex(terms_psi)
        terms_psi[k] >= pos_psi - tol && push!(winners, k)
    end
    length(winners) == 1 || return nothing
    pt = points[winners[1]]
    dx = ustrip(u"inch", pt[1] - xc)
    dy = ustrip(u"inch", pt[2] - yc)
    L = hypot(dx, dy)
    L > 1e-8 || return nothing
    return (dx / L, dy / L)
end

"""
    circular_critical_section(D, d; n=64, center=(0u"inch", 0u"inch")) -> Vector

Vertices of the punching critical section for a **circular** column/loaded area
of diameter `D`: the ring at `d/2` from the column face, i.e. a circle of
diameter `D + d`, discretized into `n` straight segments for the general-shape
method. Pass to `punching_stress_general`/`critical_section_properties` with
`closed=true`. Converges to the analytic ring (`b0 = π(D+d)`, `J1 = J2 =
d·π·r³`, `r = (D+d)/2`) as `n` grows; `n=64` is well within ~0.1%.

For an **I-shaped or other odd support**, pass the effective loaded-area polygon
(ACI 421.3R-15 §4.8: the minimum-perimeter area enclosing the actual shape)
directly as `points` instead — no special case is needed.

Reference: ACI 318-11 §11.11.1.2 critical section at d/2 (corpus: aci-318-11);
general-shape treatment ACI 421.1R-99 Appendix B (corpus: aci-421-1r-99).
"""
function circular_critical_section(D::Length, d::Length; n::Int = 64,
                                   center = (0.0u"inch", 0.0u"inch"))
    n ≥ 8 || throw(ArgumentError("need n ≥ 8 segments to approximate a circle; got $n"))
    r = (D + d) / 2
    return [(center[1] + r * cos(2π * k / n), center[2] + r * sin(2π * k / n))
            for k in 0:(n - 1)]
end

"""
    rectangular_critical_section(c1, c2, d; position=:interior) -> (points, closed)

Vertices (and open/closed flag) of the orthogonal rectangular critical section at
`d/2` from the faces of a `c1×c2` column, for the general-shape engine. The
column is centered at the origin with faces aligned to x/y.

- `:interior` — the full `(c1+d)×(c2+d)` loop (4 sides, `closed=true`).
- `:edge` — free edge along `x = +c1/2` (slab on `x ≤ c1/2`); open 3-sided U.
- `:corner` — convex outside corner, free edges at `x=+c1/2` and `y=+c2/2`
  (slab in the `−x,−y` quadrant); open 2-sided L.

These reproduce the closed-form `b0`/`cAB` geometry while routing through the
Appendix B engine (used to test the general path against the closed forms).

Reference: ACI 318-11 §11.11.1.2, critical section at d/2 where slab exists
(corpus: aci-318-11, pages 200, 209).
"""
function rectangular_critical_section(c1::Length, c2::Length, d::Length;
                                      position::Symbol = :interior)
    ax = c1 / 2 + d / 2   # offset half-width (x)
    ay = c2 / 2 + d / 2   # offset half-width (y)
    fx = c1 / 2           # free-edge location (x) when present
    fy = c2 / 2           # free-edge location (y) when present
    if position === :interior
        return ([(ax, ay), (-ax, ay), (-ax, -ay), (ax, -ay)], true)
    elseif position === :edge
        # Open U: free edge at x = +c1/2, slab on x ≤ c1/2.
        return ([(fx, ay), (-ax, ay), (-ax, -ay), (fx, -ay)], false)
    elseif position === :corner
        # Open L: free edges at x=+c1/2 and y=+c2/2, slab in −x,−y quadrant.
        return ([(fx, -ay), (-ax, -ay), (-ax, fy)], false)
    else
        throw(ArgumentError("position must be :interior, :edge, or :corner; got :$position"))
    end
end

"""
    wall_end_critical_section(t, L, d) -> (points, closed)

Three-sided critical section at the free end of a wall of thickness `t` and
length `L`. The wall continues past the far end, so the section does not
cross that face. Slab is on the free end and on both long faces.

This is the edge-column section of ACI 318-11 §11.11.1.2 (corpus: aci-318-11,
page 200): straight sides parallel to the reaction rectangle at `d/2`.
`b0 = 2(L + d/2) + (t + d)`, the same perimeter as
[`punching_geometry_edge`](@ref) with the length perpendicular to the
continuing face.
"""
function wall_end_critical_section(t::Length, L::Length, d::Length)
    return rectangular_critical_section(L, t, d; position = :edge)
end

"""
    wall_face_critical_section(t, L, d) -> (points, closed)

Three-sided critical section for a wall of thickness `t` and length `L` with
slab on one face and on both free ends. The back face has no slab (a shaft
or a slab edge). 

`b0 = 2(t + d/2) + (L + d)`: the long side is `d/2` past each end, and each
end return stops at the back face. ACI 318-11 §11.11.1.2 (corpus: aci-318-11,
page 200).
"""
function wall_face_critical_section(t::Length, L::Length, d::Length)
    return rectangular_critical_section(t, L, d; position = :edge)
end

"""
    reentrant_wall_corner_section(tx, Lx, ty, Ly, d) -> (points, closed)

Critical section in the re-entrant corner where two walls meet and the slab
fills the inside of the L.

The leg of thickness `tx` runs a centerline length `Lx` along x. The leg of
thickness `ty` runs `Ly` along y. They meet at the origin. The section is
two straight lines, each `d/2` outside the slab-side face (§11.11.1.2,
page 200), meeting at `d/2` from both faces:

    b0 = (Lx − ty/2 − d/2) + (Ly − tx/2 − d/2)

The lines end at each leg's far end, which is `d/2` from that end corner.
Open polyline (`closed=false`). Properties go through ACI 421.1R-99
Appendix B (corpus: aci-421-1r-99).
"""
function reentrant_wall_corner_section(tx::Length, Lx::Length, ty::Length, Ly::Length, d::Length)
    ox = ty / 2 + d / 2
    oy = tx / 2 + d / 2
    (Lx > ox && Ly > oy) || throw(ArgumentError(
        "re-entrant wall corner: each leg must extend past the d/2 corner; " *
        "got Lx=$Lx, Ly=$Ly, offset ($ox, $oy)"))
    return ([(Lx, oy), (ox, oy), (ox, Ly)], false)
end

"""
    convex_wall_corner_section(tx, Lx, ty, Ly, d) -> (points, closed)

Critical section on the outside of an L of two walls (the slab is in the
quadrant opposite the legs). Same leg convention as
[`reentrant_wall_corner_section`](@ref).

    b0 = (Lx + ty/2 + d/2) + (Ly + tx/2 + d/2)

ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200).
"""
function convex_wall_corner_section(tx::Length, Lx::Length, ty::Length, Ly::Length, d::Length)
    ox = ty / 2 + d / 2
    oy = tx / 2 + d / 2
    return ([(Lx, -oy), (-ox, -oy), (-ox, Ly)], false)
end

"""
    closed_wall_loop_section(Wx, Wy, t, d) -> (points, closed)

Critical section around a closed rectangular wall loop (a shaft). `Wx` and
`Wy` are the centerline dimensions. The slab is outside the loop, so the
section is the rectangle `t/2 + d/2` outside each centerline.

    b0 = 2(Wx + Wy + 2t + 2d)

ACI 318-11 §11.11.1.2 and §11.11.1.3 (corpus: aci-318-11, pages 200–201):
four straight sides at `d/2` from the reaction.
"""
function closed_wall_loop_section(Wx::Length, Wy::Length, t::Length, d::Length;
                                 outward::Bool = true)
    s = outward ? 1 : -1
    a = Wx + s * (t + d)
    b = Wy + s * (t + d)
    (a > zero(a) && b > zero(b)) || throw(ArgumentError(
        "closed wall loop section is degenerate (Wx=$Wx, Wy=$Wy, t=$t, d=$d)"))
    return ([(a / 2, b / 2), (-a / 2, b / 2), (-a / 2, -b / 2), (a / 2, -b / 2)], true)
end

"""
    reentrant_critical_section(c1, c2, d; notch=(1, 1)) -> (points, closed)

Vertices of the critical section at a **re-entrant** (L-shape inside) corner: a
`c1×c2` column seated in the inside corner of an L, with one empty quadrant
(`notch`, a sign pair like `(+1,+1)`). Per ACI 318-11 §11.11.1.2 the critical
section follows the `d/2` offset wherever slab exists and terminates at the two
free edges bounding the notch. The resisting section is therefore the full
offset loop **minus** the two `d/2` notch edges (which lie along the free edges
and carry no shear): an **open** polyline with

    b0 = 2(c1 + c2) + 3d.

This is `d` less than the full 4-sided `2(c1+d)+2(c2+d)` — only the resisting
perimeter is counted — and far more than the legacy 2-sided `:corner` section,
which severely under-counts a re-entrant corner.

Thin wrapper over [`corner_critical_section`](@ref) with `kind=:reentrant` and
the orthogonal inward normals implied by `notch` (single source of truth for the
clipped geometry).

Reference: ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200); free-edge
effective-perimeter treatment ACI 421.3R-15 §4.6.2 (corpus: aci-421-3r-15).
"""
function reentrant_critical_section(c1::Length, c2::Length, d::Length;
                                    notch::Tuple{Int,Int} = (1, 1))
    sx, sy = sign(notch[1]), sign(notch[2])
    (sx != 0 && sy != 0) ||
        throw(ArgumentError("notch must be a nonzero sign pair, e.g. (1,1); got $notch"))
    # Inward normals point from each free edge toward the slab, i.e. away from
    # the empty notch quadrant: −sign(notch) on each axis.
    normals = [(-float(sx), 0.0), (0.0, -float(sy))]
    return corner_critical_section(c1, c2, d, :reentrant, normals)
end

"""
    corner_critical_section(c1, c2, d, kind, inward_normals; θ=0.0) -> (points, closed)

Effective punching critical section for a corner column of **any free-edge
angle**, built by offsetting the `c1×c2` column rectangle by `d/2` and clipping
the offset perimeter to the slab region defined by the two free edges. Returns an
**open** polyline (`closed=false`) of the resisting, slab-facing perimeter; the
free-edge cuts carry no shear and are excluded.

- `kind=:convex` — outside corner. Slab is the wedge = intersection of the two
  inward half-planes; the offset perimeter is kept only where it faces slab on
  *both* edges.
- `kind=:reentrant` — inside (L) corner. Slab is the complement of the notch =
  union of the two inward half-planes; the perimeter is kept everywhere except
  the notch corner (both edges' void side).

`inward_normals` are the two unit normals pointing from each free edge **into**
the slab (need not be unit; they are normalized). The free-edge lines pass
through the column's void-side corner along the edge directions (the column is
seated in the corner with its faces tangent to the edges). `θ` rotates the
column. All lengths internally reduced to inches.

Exact reductions (orthogonal edges `[(-1,0),(0,-1)]`):
- `:convex`    → 2-sided L, `b0 = (c1+d/2)+(c2+d/2)` (matches
  `rectangular_critical_section(:corner)`).
- `:reentrant` → `b0 = 2(c1+c2)+3d` — the full offset loop **minus** the two
  `d/2` notch edges, which lie along the free edges and do not resist. (This is
  `d` less than the closed 6-vertex `reentrant_critical_section`, correcting an
  unconservative over-count of the resisting perimeter.)

Reference: ACI 318-11 §11.11.1.2 — critical section at `d/2` wherever slab
exists (corpus: aci-318-11, page 200); general-shape App. B engine
(corpus: aci-421-1r-99); free-edge effective-perimeter ACI 421.3R-15 §4.6.2.
"""
function corner_critical_section(c1::Length, c2::Length, d::Length, kind::Symbol,
                                 inward_normals::AbstractVector; θ::Float64 = 0.0)
    length(inward_normals) == 2 ||
        throw(ArgumentError("a corner has exactly 2 free edges; got $(length(inward_normals))"))
    kind in (:convex, :reentrant) ||
        throw(ArgumentError("kind must be :convex or :reentrant; got :$kind"))
    ax = ustrip(u"inch", c1) / 2 + ustrip(u"inch", d) / 2   # offset half-width x
    ay = ustrip(u"inch", c2) / 2 + ustrip(u"inch", d) / 2   # offset half-width y
    hx = ustrip(u"inch", c1) / 2                            # column half-width x
    hy = ustrip(u"inch", c2) / 2                            # column half-width y
    cθ = cos(θ); sθ = sin(θ)
    rot(x, y) = (x * cθ - y * sθ, x * sθ + y * cθ)
    # Offset rectangle corners, CCW, in the (rotated) global frame.
    V = [rot(ax, -ay), rot(ax, ay), rot(-ax, ay), rot(-ax, -ay)]
    # Normalize the inward normals.
    N = map(inward_normals) do n
        m = hypot(float(n[1]), float(n[2]))
        m == 0 && throw(ArgumentError("inward normal must be nonzero; got $n"))
        (n[1] / m, n[2] / m)
    end
    # Void direction ≈ −(sum of inward normals); the void-side column corner is
    # the column-rectangle corner farthest along it. Both free edges pass through
    # this corner.
    svx = -(N[1][1] + N[2][1]); svy = -(N[1][2] + N[2][2])
    colV = [rot(hx, -hy), rot(hx, hy), rot(-hx, hy), rot(-hx, -hy)]
    vc = colV[argmax([cc[1] * svx + cc[2] * svy for cc in colV])]
    # Signed slab-side distance of point p from free edge k (≥ 0 ⇒ slab side).
    g(p, k) = (p[1] - vc[1]) * N[k][1] + (p[2] - vc[2]) * N[k][2]
    tol = 1e-9 * max(ax, ay)
    keep(p) = kind === :reentrant ? (g(p, 1) ≥ -tol || g(p, 2) ≥ -tol) :
                                    (g(p, 1) ≥ -tol && g(p, 2) ≥ -tol)
    # Walk the closed offset perimeter, inserting the constraint-line crossings
    # so every resulting segment is wholly kept or wholly dropped.
    nV = length(V)
    aug = Tuple{Float64,Float64}[]
    for i in 1:nV
        A = V[i]; B = V[mod1(i + 1, nV)]
        push!(aug, A)
        ts = Float64[]
        for k in 1:2
            gA = g(A, k); gB = g(B, k)
            if (gA < 0) != (gB < 0) && gA != gB
                t = gA / (gA - gB)
                (0 < t < 1) && push!(ts, t)
            end
        end
        sort!(ts)
        for t in ts
            push!(aug, (A[1] + t * (B[1] - A[1]), A[2] + t * (B[2] - A[2])))
        end
    end
    m = length(aug)
    # Classify each segment aug[i]→aug[i+1] by its midpoint.
    kept = [keep(((aug[i][1] + aug[mod1(i + 1, m)][1]) / 2,
                  (aug[i][2] + aug[mod1(i + 1, m)][2]) / 2)) for i in 1:m]
    any(kept) || throw(ArgumentError("corner clip produced an empty critical section"))
    d0 = findfirst(!, kept)           # a dropped (free-edge) segment
    if d0 === nothing
        # Fully enclosed (no free edge cuts the offset) — return the closed loop.
        pts = [(v[1] * u"inch", v[2] * u"inch") for v in V]
        return (pts, true)
    end
    # Advance to the first kept segment after the drop, then collect one run so the
    # open ends sit at the free-edge terminations.
    i = d0
    while !kept[mod1(i, m)]; i += 1; end
    j = mod1(i, m)
    chain = [aug[j]]
    cnt = 0
    while kept[j] && cnt < m
        push!(chain, aug[mod1(j + 1, m)])
        j = mod1(j + 1, m); cnt += 1
    end
    # Drop consecutive duplicates, then collinear interior points.
    uniq = Tuple{Float64,Float64}[]
    for p in chain
        if isempty(uniq) ||
           hypot(p[1] - uniq[end][1], p[2] - uniq[end][2]) > tol
            push!(uniq, p)
        end
    end
    simp = Tuple{Float64,Float64}[]
    for (idx, p) in enumerate(uniq)
        if 1 < idx < length(uniq)
            a = simp[end]; b = p; cc = uniq[idx + 1]
            cross = (b[1] - a[1]) * (cc[2] - a[2]) - (b[2] - a[2]) * (cc[1] - a[1])
            abs(cross) ≤ tol * max(ax, ay) && continue   # b is collinear with a–c
        end
        push!(simp, p)
    end
    out = [(p[1] * u"inch", p[2] * u"inch") for p in simp]
    return (out, false)
end

"""
    section_symmetry(points, props; rtol=1e-6) -> (sym1, sym2)

Whether the critical section's vertex set is symmetric about principal axis 1
and/or axis 2 (reflection invariance in the principal frame from `props`). Used
to flag sections with no axis of symmetry, where the γv (Fig. B2) and
farthest-fiber evaluation of Eq. (3.2) are approximate.
"""
function section_symmetry(points::AbstractVector, props; rtol::Float64 = 1e-6)
    c = cos(props.θp); s = sin(props.θp)
    xc = props.xc; yc = props.yc
    s1 = Float64[]; s2 = Float64[]
    for pt in points
        x = ustrip(u"inch", pt[1] - xc)
        y = ustrip(u"inch", pt[2] - yc)
        push!(s1, x * c + y * s)
        push!(s2, -x * s + y * c)
    end
    scale = max(maximum(abs, s1; init = 0.0), maximum(abs, s2; init = 0.0), 1.0)
    tol = rtol * scale
    _has(set1, set2, a, b) = any(i -> abs(set1[i] - a) ≤ tol && abs(set2[i] - b) ≤ tol,
                                 eachindex(set1))
    # Symmetry about axis 1 (s1-axis): (s1, s2) → (s1, −s2).
    sym1 = all(k -> _has(s1, s2, s1[k], -s2[k]), eachindex(s1))
    # Symmetry about axis 2 (s2-axis): (s1, s2) → (−s1, s2).
    sym2 = all(k -> _has(s1, s2, -s1[k], s2[k]), eachindex(s1))
    return (sym1, sym2)
end

"""
    punching_check_general(Vu, Mux, Muy, d, fc, points; ...) -> NamedTuple

Full punching check for a critical section of **general shape** (non-orthogonal,
re-entrant, circular, I-/odd supports), combining the ACI 421.1R-99 Appendix B
demand stress (`punching_stress_general`) with the §11.11.2.1 capacity stress.

`Mux`/`Muy` follow the 421.1R convention (`Mux` about x, `Muy` about y). Pass the
critical-section `points` (e.g. from `rectangular_critical_section`,
`reentrant_critical_section`, `circular_critical_section`, or a building-derived
polygon) and `closed`. `β` and `αs` feed the capacity (ACI 318-11 §11.11.2.1);
supply them from the column / section side-count (defaults: `β=1`, `αs=40`).
`λs` is the ACI 318-19 size effect factor; the default 1.0 keeps ACI 318-11.

Returns `(ok, utilization, vu, ϕvc, b0, J1, J2, θp, asymmetric, sym1, sym2,
props, direction)`. `direction` is the peak face from `punching_stress_general`,
or `nothing` when that face is not unique. `asymmetric=true` (no principal axis
of symmetry) flags that γv and the peak-stress point are approximate and an
FEA cross-check is advised.

Reference: ACI 421.1R-99 Eq. (3.2)/(3.3), Appendix B (corpus: aci-421-1r-99);
capacity ACI 318-11 §11.11.2.1 (corpus: aci-318-11).
"""
function punching_check_general(Vu::Force, Mux::Torque, Muy::Torque,
                                d::Length, fc::Pressure, points::AbstractVector;
                                closed::Bool = true, segments=nothing,
                                β::Float64 = 1.0, αs::Int = 40,
                                λ::Float64 = 1.0, λs::Float64 = 1.0, ϕ::Float64 = 0.75)
    res = punching_stress_general(Vu, Mux, Muy, points, d; closed = closed, segments = segments)
    vc = punching_capacity_stress(fc, β, αs, res.b0, d; λ = λ, λs = λs)
    ϕvc = ϕ * vc
    sym1, sym2 = section_symmetry(points, res.props)
    ok = res.vu ≤ ϕvc
    utilization = ustrip(u"psi", res.vu) / max(ustrip(u"psi", ϕvc), 1e-10)
    return (ok = ok, utilization = utilization, vu = res.vu, ϕvc = ϕvc,
            b0 = res.b0, J1 = res.J1, J2 = res.J2, θp = res.θp,
            asymmetric = !(sym1 || sym2), sym1 = sym1, sym2 = sym2,
            props = res.props, direction = res.direction)
end

