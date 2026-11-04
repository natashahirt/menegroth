# =============================================================================
# Outer Critical Section for Punching Shear Reinforcement
# =============================================================================
#
# Shared by headed studs (ACI 318-11 §11.11.5) and closed stirrups (§11.11.3).
#
# Requirement: the shear stress due to factored shear and moment shall not
# exceed φ·2λ√f'c at the critical section d/2 outside the outermost peripheral
# line of reinforcement.
#   - Studs:     ACI 318-11 §11.11.5.4 (corpus: aci-318-11, page 208)
#   - Stirrups:  ACI 318-11 §11.11.7.2(b) (corpus: aci-318-11, page 210)
#
# Geometry: reinforcement lines (rails / stirrup legs) run perpendicular to each
# column face, with one at each end of every face. The critical section d/2
# beyond the line tips is the polygonal section of ACI 318-11 R11.11.5 (page
# 207) and ACI 421.1R-99 Fig. 3.1(b): straight sides parallel to the column
# faces, joined by 45° chamfers across the corners. Offsetting the octagon of
# line tips by d/2 extends each straight side by (d/2)·tan(22.5°) at both ends.
# This reproduces the ACI 421.1R-99 Ch. 7 example (page 421.1R-8): 12×20 in.
# column, distance αd = 22.5 in. → l_x1 = 14.3, l_y1 = 22.3, l = 30.2,
# b_o = 194.0 in.
#
# Stress (ACI 421.1R-99 Eq. 3.2, page 421.1R-4):
#     v_u = V_u/A_c + γ_vx·M_ux·y/J_x + γ_vy·M_uy·x/J_y
# with γ_v from the d/2 section side lengths (Eq. 3.3 defines l_x1, l_y1 "at
# d/2 from column face"; the Ch. 7 example reuses γ_v = 0.36 at the outer
# section). A_c, J_x, J_y of the polygon follow Appendix B (J ≈ I).
#
# Frame: column centred at the origin, c1 along x, c2 along y. Edge columns
# have their free edge at x = +c1/2 (slab on x ≤ c1/2); corner columns have
# free edges at x = +c1/2 and y = +c2/2. This matches
# `rectangular_critical_section`.
# =============================================================================

"""Hard cap on peripheral lines of shear reinforcement per rail.

ACI 318-11 §11.11.5.4 (corpus: aci-318-11, page 208) does not limit how far
the studs extend: the outer section d/2 past the last line must pass. This
cap only stops a search that never passes.
"""
const MAX_REINFORCEMENT_LINES = 20

"""
    reinforcement_lines_per_face(face, d) -> Int

Number of reinforcement lines (stud rails or stirrup legs) along one column face
of length `face`, with a line at each end of the face and spacing between
adjacent lines on the first peripheral line not exceeding 2d.

Reference: ACI 318-11 §11.11.5.3 (studs, page 208) and §11.11.3.3 (stirrups,
page 204).
"""
function reinforcement_lines_per_face(face::Length, d::Length)
    gaps = ceil(Int, ustrip(u"inch", face) / (2 * ustrip(u"inch", d)) - 1e-9)
    return max(2, gaps + 1)
end

"""
    reinforcement_line_count(c1, c2, d, position) -> Int

Total reinforcement lines around the column: faces at `y = ±c2/2` have length
`c1`, faces at `x = ±c1/2` have length `c2`. Edge columns omit the free face at
`x = +c1/2`; corner columns also omit `y = +c2/2`.
"""
function reinforcement_line_count(c1::Length, c2::Length, d::Length, position::Symbol)
    n1 = reinforcement_lines_per_face(c1, d)
    n2 = reinforcement_lines_per_face(c2, d)
    position === :interior && return 2n1 + 2n2
    position === :edge && return 2n1 + n2
    return n1 + n2
end

"""
    reinforcement_outer_section(c1, c2, d, extent; position=:interior)
        -> (points, closed, area)

Critical section `d/2` outside the outermost peripheral line of shear
reinforcement, where `extent` is the distance from the column face to that line.
Returns the section vertices (`(x, y)` tuples of `Length`), whether the section
is closed, and the plan area it encloses (including the column, bounded by the
free edges for edge and corner columns).
"""
function reinforcement_outer_section(c1::Length, c2::Length, d::Length, extent::Length;
                                     position::Symbol = :interior)
    a = ustrip(u"inch", extent) + ustrip(u"inch", d) / 2
    t = ustrip(u"inch", d) / 2 * tan(π / 8)
    fx = ustrip(u"inch", c1) / 2
    fy = ustrip(u"inch", c2) / 2
    X = fx + a
    Y = fy + a
    hx = fx + t
    hy = fy + t
    raw, closed, outline = if position === :interior
        pts = [(X, -hy), (X, hy), (hx, Y), (-hx, Y), (-X, hy), (-X, -hy), (-hx, -Y), (hx, -Y)]
        (pts, true, pts)
    elseif position === :edge
        pts = [(fx, Y), (-hx, Y), (-X, hy), (-X, -hy), (-hx, -Y), (fx, -Y)]
        (pts, false, pts)
    elseif position === :corner
        pts = [(fx, -Y), (-hx, -Y), (-X, -hy), (-X, fy)]
        (pts, false, vcat(pts, [(fx, fy)]))
    else
        throw(ArgumentError("position must be :interior, :edge, or :corner; got :$position"))
    end
    points = [(p[1] * u"inch", p[2] * u"inch") for p in raw]
    return (points = points, closed = closed, area = _shoelace(outline) * u"inch^2")
end

"""
    outer_section_check(c1, c2, d, extent, fc, position; Vu, M_about_x, M_about_y,
                        qu=nothing, λ=1.0, φ=0.75) -> NamedTuple

Shear stress at the critical section `d/2` outside the outermost peripheral
line of reinforcement, checked against `φ·2λ√f'c`.

- `Vu`: factored shear transferred at the column.
- `M_about_x`, `M_about_y`: unbalanced moments about the column-centred x and y
  axes (ACI 421.1R convention: `M_about_y` varies the stress in x). For edge
  and corner columns these are shifted to the outer section centroid as
  `|M| − V_u,out·e`, floored at zero, matching the d/2 section practice of
  ACI 318-11 R11.11.7.2 (page 210) with the reduced outer shear.
- `qu`: factored slab pressure. When given, `V_u,out = Vu − qu·A_enclosed`
  (ACI 421.1R-99 Ch. 7 Step 5, page 421.1R-8).

Returns `(ok, vu, φvn, b0, Ac, Vu_out, ratio)`.
"""
function outer_section_check(c1::Length, c2::Length, d::Length, extent::Length,
                             fc::Pressure, position::Symbol;
                             Vu::Force, M_about_x::Moment, M_about_y::Moment,
                             qu::Union{Pressure, Nothing} = nothing,
                             λ::Float64 = 1.0, φ::Float64 = 0.75)
    sec = reinforcement_outer_section(c1, c2, d, extent; position = position)
    props = critical_section_properties(sec.points, d; closed = sec.closed)

    Vu_out = isnothing(qu) ? Vu : max(Vu - qu * sec.area, zero(Vu))

    Mx = _shift_moment(M_about_x, Vu_out, props.yc)
    My = _shift_moment(M_about_y, Vu_out, props.xc)

    # ACI 421.1R-99 Eq. (3.3): γv from the side lengths of the d/2 section.
    edge_x = position === :interior ? d : d / 2
    edge_y = position === :corner ? d / 2 : d
    lx1 = c1 + edge_x
    ly1 = c2 + edge_y
    γvy = gamma_v(lx1, ly1)
    γvx = gamma_v(ly1, lx1)

    # Moment directions are unknown, so the two terms are added in absolute value
    # at each vertex, as in the closed-form d/2 checks.
    v_moment = 0.0u"psi"
    for p in sec.points
        x = abs(p[1] - props.xc)
        y = abs(p[2] - props.yc)
        term = uconvert(u"psi", γvy * abs(My) * x / props.Iy + γvx * abs(Mx) * y / props.Ix)
        v_moment = max(v_moment, term)
    end
    vu = uconvert(u"psi", Vu_out / props.Ac) + v_moment
    φvn = φ * punching_capacity_outer(fc, d; λ = λ)
    return (ok = vu ≤ φvn, vu = vu, φvn = φvn, b0 = props.b0, Ac = props.Ac,
            Vu_out = Vu_out, ratio = ustrip(u"psi", vu) / ustrip(u"psi", φvn))
end

"""
    max_reinforcement_lines(s0, s; max_extent=nothing) -> Int

Most peripheral lines that fit within `max_extent` from the column face
(`s0 + (n−1)s ≤ max_extent`), capped at `MAX_REINFORCEMENT_LINES`.
"""
function max_reinforcement_lines(s0::Length, s::Length; max_extent = nothing)
    isnothing(max_extent) && return MAX_REINFORCEMENT_LINES
    n = floor(Int, ustrip(u"inch", max_extent - s0) / ustrip(u"inch", s) + 1e-9) + 1
    return clamp(n, 0, MAX_REINFORCEMENT_LINES)
end

"""
    _outer_section_inputs(vu, b0, d, position, c1, c2, Vu, M_about_x, M_about_y)

Resolve the geometry and demand for the outer section check. When the column
size is unknown, a square column with the same d/2 perimeter is used. When `Vu`
is unknown, `vu·b0·d` is used as the shear with no moment: the moment stress
decays faster than the direct stress with distance from the column, so this
bounds the outer stress from above.
"""
function _outer_section_inputs(vu, b0, d, position, c1, c2, Vu, M_about_x, M_about_y)
    if isnothing(c1) || isnothing(c2)
        c = max(_solve_square_b0(position, b0, d), 0.0u"inch")
        c1 = c2 = c
    end
    if isnothing(Vu)
        Vu = uconvert(u"lbf", vu * b0 * d)
        M_about_x = M_about_y = 0.0u"lbf*inch"
    end
    Mx = something(M_about_x, 0.0u"lbf*inch")
    My = something(M_about_y, 0.0u"lbf*inch")
    return (c1 = c1, c2 = c2, Vu = Vu, Mx = Mx, My = My)
end

"""
    design_outer_lines(s0, s, d, fc, position, inputs; qu, λ, φ, n_min=2, n_max)
        -> (n, ok, check)

Smallest number of peripheral lines `n ∈ n_min:n_max` for which the outer
critical section passes. `n_min = 2` follows ACI 421.1R-99 §3.4 Step 4 (page
421.1R-6: each line count "must be ≥ 2"). Returns the last trial when none pass.
"""
function design_outer_lines(s0::Length, s::Length, d::Length, fc::Pressure,
                            position::Symbol, inputs;
                            qu = nothing, λ::Float64 = 1.0, φ::Float64 = 0.75,
                            n_min::Int = 2, n_max::Int = MAX_REINFORCEMENT_LINES)
    chk = nothing
    n_max < n_min && return (n = 0, ok = false, check = chk)
    for n in n_min:n_max
        chk = outer_section_check(inputs.c1, inputs.c2, d, s0 + (n - 1) * s, fc, position;
                                  Vu = inputs.Vu, M_about_x = inputs.Mx, M_about_y = inputs.My,
                                  qu = qu, λ = λ, φ = φ)
        chk.ok && return (n = n, ok = true, check = chk)
    end
    return (n = n_max, ok = false, check = chk)
end
