# Strength checks for a vertical segment beside an opening.
#
# A segment longer than three times its thickness is the ordinary wall check,
# on the segment length and the segment clear height, at both end cuts.
# A shorter segment is a column. Slenderness is the neglect test only.
# Story second-order sway is already in the forces the caller passes, and
# this file does not magnify them again.
#
# The ordinary-wall stage calls this for a vertical segment. A horizontal
# segment longer than four times its depth is sent to the beam designers.
# A shorter one is one deep-beam strut and tie.

"""
    segment_end_strength(bottom, top; wind_bottom, wind_top, qe_bottom, qe_top, rho, SDS)

Strength combinations at the two ends of one segment.

Each end is combined by [`wall_strength_actions`](@ref), the same list a
solid pier uses. The end actions are whatever displacement the caller cut.
When that displacement was solved on the story stiffness, the sway
second-order effect is already in the combination. This function does not
apply a moment magnifier.
"""
function segment_end_strength(bottom::PierGravityActions, top::PierGravityActions;
                             wind_bottom::WallAction, wind_top::WallAction,
                             qe_bottom::WallAction, qe_top::WallAction,
                             rho::Real, SDS::Real)
    return (
        bottom=wall_strength_actions(bottom; wind=wind_bottom, qe=qe_bottom, rho, SDS),
        top=wall_strength_actions(top; wind=wind_top, qe=qe_top, rho, SDS),
    )
end

"""
    check_pier_segment(wall, segment, bottom, top; kwargs...) -> Vector{WallCheckRecord}

Check one vertical segment at both ends.

`bottom` and `top` are the strength combinations at those cuts. `wall` is
the stack's reference wall: its thickness, story height, and reinforcement
ratios are the section. A `:wall` segment raises those ratios when the
segment needs more than the wall already has, and does not lower them.

A `:column` segment requires `k` and `braced`. `k` is the effective-length
factor from ACI 318-19 §6.2.5 / Fig. R6.2.5.1 (corpus: `aci-318-19`, PDF
p. 70–71). This function does not choose it. `braced` is whether the column
is braced against sidesway for §6.2.5.1. Both axes use that one pair. When
`braced` is true, `M1_over_M2` is the end-moment ratio in the code's sign:
negative for single curvature, positive for double curvature (§6.2.5.1,
PDF p. 70).

`cover` is the caller's clear cover for the column section. It is not
taken from a table here.

A column segment's shear is the same tie design a frame column uses
([`design_column_shear`](@ref)). The section is built with `b` equal to the
wall thickness and `h` equal to the segment length, so in-plane shear is
`Vu_y` and out-of-plane shear is `Vu_x`. The ties are not drawn on the wall.

# Citations
ACI 318-19 §2.3 (corpus: `aci-318-19`, PDF p. 48): a wall has length /
thickness greater than 3. The other segment is a column.
ACI 318-19 §6.2.5.1 (PDF p. 70): slenderness effects may be neglected when
`kℓu/r` is within Eq. (6.2.5.1a) or Eqs. (6.2.5.1b) and (6.2.5.1c).
Fig. R6.2.5.3 (PDF p. 73): moment magnification and a second-order analysis
are separate paths. The forces here already include the story second-order
analysis, so the sway magnifier is not applied. Along-length magnification
is not applied either. A segment outside the neglect limit is withheld.
ACI 318-19 §10.6.1.1 (PDF p. 160): longitudinal reinforcement at least
`0.01Ag` and not more than `0.08Ag`.
ACI 318-19 §10.5.3.1 and §22.5 (PDF pp. 159 and 403–412).
"""
function check_pier_segment(wall::Wall, segment::WallSegment,
                           bottom::AbstractVector{CombinedWallAction},
                           top::AbstractVector{CombinedWallAction};
                           material,
                           wall_index::Int,
                           case::Symbol,
                           boundary::Symbol,
                           k::Union{Nothing, Real}=nothing,
                           braced::Union{Nothing, Bool}=nothing,
                           M1_over_M2::Union{Nothing, Real}=nothing,
                           cover::Union{Nothing, Unitful.Length}=nothing,
                           plan_axis::NTuple{2, Float64}=(1.0, 0.0),
                           Moop::Unitful.Quantity=0.0u"N*m")
    segment.kind === :vertical || throw(ArgumentError(
        "pier segment check: the segment is $(segment.kind). A horizontal " *
        "segment is not this check."))
    (isempty(bottom) || isempty(top)) && throw(ArgumentError(
        "pier segment check: both ends need a strength combination."))
    t = ustrip(u"m", wall.thickness)
    lw = segment.s1 - segment.s0
    hw = segment.z1 - segment.z0
    (lw > 0 && hw > 0 && t > 0) || throw(ArgumentError(
        "pier segment check: the segment has no length, height, or thickness."))
    route = _segment_design(:vertical, segment.s0, segment.s1, segment.z0, segment.z1, t)
    route === segment.design || throw(ArgumentError(
        "pier segment check: the segment is tagged :$(segment.design) and the " *
        "length-to-thickness ratio routes it to :$(route)."))
    if route === :wall
        L = wall_length(wall)
        share = L > 1e-9 ? min(max(segment.s1 - segment.s0, 0.0) / L, 1.0) : 1.0
        return _check_wall_pier_segment(
            wall, bottom, top; material, wall_index, case, boundary, plan_axis,
            lw=lw * u"m", hw=hw * u"m", Moop=Moop * share)
    end
    return _check_column_pier_segment(
        wall, segment, bottom, top; material, wall_index, case, boundary, plan_axis,
        k, braced, M1_over_M2, cover, lw, hw, t)
end

# ------------------------------------------------------------------------------
# Wall route
# ------------------------------------------------------------------------------

function _check_wall_pier_segment(wall, bottom, top; material, wall_index, case,
                                 boundary, plan_axis, lw, hw, Moop=0.0u"N*m")
    actions = CombinedWallAction[]
    append!(actions, bottom)
    append!(actions, top)
    select_ordinary_wall_reinforcement!(wall, actions, material; hw, lw, Moop)
    records = WallCheckRecord[]
    append!(records, _faced_records(:bottom, check_ordinary_wall(
        wall, bottom; material, wall_index, case, boundary, hw, lw, plan_axis, Moop)))
    append!(records, _faced_records(:top, check_ordinary_wall(
        wall, top; material, wall_index, case, boundary, hw, lw, plan_axis, Moop)))
    return records
end

function _faced_records(face::Symbol, records)
    out = WallCheckRecord[]
    for r in records
        push!(out, WallCheckRecord(
            r.wall_index, r.story, r.direction, r.case, r.combination, r.alternative,
            "$(face) $(r.check)", r.passed, r.ratio, r.demand, r.capacity, r.clause))
    end
    return out
end

# ------------------------------------------------------------------------------
# Column route
# ------------------------------------------------------------------------------

function _check_column_pier_segment(wall, segment, bottom, top; material, wall_index,
                                   case, boundary, plan_axis, k, braced, M1_over_M2,
                                   cover, lw, hw, t)
    k === nothing && throw(ArgumentError(
        "pier segment check: a column segment needs k, the effective-length " *
        "factor. ACI 318-19 Fig. R6.2.5.1 does not give one value for a wall pier."))
    braced isa Bool || throw(ArgumentError(
        "pier segment check: a column segment needs braced, true when the " *
        "column is braced against sidesway (§6.2.5.1)."))
    if braced && M1_over_M2 === nothing
        throw(ArgumentError(
            "pier segment check: a braced column needs M1_over_M2. Negative " *
            "is single curvature and positive is double curvature " *
            "(ACI 318-19 §6.2.5.1)."))
    end
    cover === nothing && throw(ArgumentError(
        "pier segment check: a column segment needs the clear cover. " *
        "No cover is assumed."))
    material isa ReinforcedConcreteMaterial || throw(ArgumentError(
        "pier segment check: material must be a ReinforcedConcreteMaterial."))
    direction = _pier_axis_direction(wall, plan_axis)
    records = WallCheckRecord[]
    section = RCColumnSection(;
        b=t * u"m", h=lw * u"m", bar_size=8, n_bars=4,
        cover=cover, tie_type=:tied)
    geom = ConcreteMemberGeometry(hw * u"m"; Lu=hw * u"m", k=Float64(k), braced=braced)
    m1 = braced ? Float64(M1_over_M2) : 0.0
    for (axis, label) in ((StrongAxis(), "in-plane"), (WeakAxis(), "out-of-plane"))
        slender = should_consider_slenderness(section, geom, axis; M1=m1, M2=1.0)
        ratio = slenderness_ratio(section, geom, axis)
        limit = _slenderness_limit(braced, m1)
        push!(records, WallCheckRecord(
            wall_index, wall.story, direction, case, :slenderness, :only,
            "$label slenderness", !slender,
            limit > 0 ? ratio / limit : Inf, ratio, limit,
            "ACI 318-19 §6.2.5.1"))
    end
    if any(r -> !r.passed, records)
        return records
    end
    actions = CombinedWallAction[]
    append!(actions, bottom)
    append!(actions, top)
    sized = _size_column_section(t, lw, cover, material, actions)
    if sized === nothing
        push!(records, WallCheckRecord(
            wall_index, wall.story, direction, case, first(actions).combination,
            first(actions).alternative, "axial-flexure", false, Inf, 0.0, 0.0,
            "ACI 318-19 §10.6.1.1"))
        return records
    end
    ρ = _column_rho(sized)
    push!(records, WallCheckRecord(
        wall_index, wall.story, direction, case, :reinforcement, :only,
        "longitudinal ratio", 0.01 - 1e-9 <= ρ <= 0.08 + 1e-9,
        ρ / 0.01, ρ, 0.01, "ACI 318-19 §10.6.1.1"))
    diagram = generate_PM_diagram(sized, material; n_intermediate=10)
    diagram_y = any(a -> abs(a.Mo) > 1.0, actions) ?
        generate_PM_diagram(sized, material, WeakAxis(); n_intermediate=10) : nothing
    for (face, set) in ((:bottom, bottom), (:top, top))
        for action in set
            _push_column_action!(records, wall, sized, diagram, diagram_y, material, action;
                                 face, wall_index, case, direction)
        end
    end
    return records
end

"""Neglect limit of ACI 318-19 §6.2.5.1. `m_ratio` is `M1/M2`."""
function _slenderness_limit(braced::Bool, m_ratio::Float64)
    # ACI 318-19 §6.2.5.1(a), Eq. (6.2.5.1a) (corpus: aci-318-19, PDF p. 70).
    braced || return 22.0
    # Eqs. (6.2.5.1b) and (6.2.5.1c), same page.
    return min(34.0 + 12.0 * m_ratio, 40.0)
end

function _column_rho(section::RCColumnSection)
    As = sum(ustrip(u"inch^2", bar.As) for bar in section.bars)
    Ag = ustrip(u"inch", section.b) * ustrip(u"inch", section.h)
    Ag > 0 || return Inf
    return As / Ag
end

function _size_column_section(t, lw, cover, material, actions)
    b = t * u"m"
    h = lw * u"m"
    order = sort(actions; by=a -> hypot(abs(a.N), abs(a.M)))
    for action in reverse(order)
        pu = ustrip(u"kip", action.N * u"N")
        mu = ustrip(u"kip*ft", action.M * u"N*m")
        sized = try
            design_column_reinforcement(b, h, pu, mu, material;
                                        cover=cover, tie_type=:tied,
                                        min_rho=0.01, max_rho=0.08)
        catch e
            e isa ErrorException || rethrow()
            nothing
        end
        sized === nothing && continue
        diagram = generate_PM_diagram(sized, material; n_intermediate=10)
        all(_column_pm_ok(diagram, a) for a in actions) && return sized
    end
    return nothing
end

function _column_pm_ok(diagram, action)
    pu = ustrip(u"kip", action.N * u"N")
    mu = ustrip(u"kip*ft", action.M * u"N*m")
    return check_PM_capacity(diagram, pu, mu).adequate
end

function _push_column_action!(records, wall, section, diagram, diagram_y, material, action;
                             face, wall_index, case, direction)
    pu = ustrip(u"kip", action.N * u"N")
    mu = ustrip(u"kip*ft", action.M * u"N*m")
    pm = check_PM_capacity(diagram, pu, mu)
    push!(records, WallCheckRecord(
        wall_index, wall.story, direction, case, action.combination, action.alternative,
        "$face axial-flexure", pm.adequate, pm.utilization,
        abs(mu), pm.φMn_at_Pu, "ACI 318-19 §22.2 / §22.4"))
    if abs(action.Mo) > 1.0
        diagram_y === nothing && throw(ArgumentError(
            "pier segment check: an out-of-plane moment has no weak-axis diagram."))
        muy = ustrip(u"kip*ft", action.Mo * u"N*m")
        bi = check_biaxial_capacity(diagram, diagram_y, pu, mu, muy)
        push!(records, WallCheckRecord(
            wall_index, wall.story, direction, case, action.combination, action.alternative,
            "$face biaxial", bi.adequate, bi.utilization,
            hypot(mu, muy), min(bi.φMnx_at_Pu, bi.φMny_at_Pu),
            "ACI 318-19 §22.4"))
    end
    # b = thickness, h = segment length. In-plane V is parallel to h (Vu_y).
    # Out-of-plane Vo is parallel to b (Vu_x). This mapping follows the
    # section that was built; it is not an axis guess.
    shear = design_column_shear(section, abs(action.Vo) * u"N", abs(action.V) * u"N",
                                action.N * u"N", material)
    _push_column_shear!(records, wall, action, shear;
                        face, wall_index, case, direction,
                        demand = abs(action.V), capacity = shear.ϕVn_y,
                        ratio = shear.ratio_y, limit = shear.ϕVn_limit_y,
                        name = "one-way shear")
    if abs(action.Vo) > 1.0
        _push_column_shear!(records, wall, action, shear;
                            face, wall_index, case, direction,
                            demand = abs(action.Vo), capacity = shear.ϕVn_x,
                            ratio = shear.ratio_x, limit = shear.ϕVn_limit_x,
                            name = "out-of-plane shear")
    end
    if shear.interaction_ratio > 0.0
        push!(records, WallCheckRecord(
            wall_index, wall.story, direction, case, action.combination, action.alternative,
            "$face biaxial shear", shear.interaction_ratio <= 1.0, shear.interaction_ratio,
            abs(action.V) + abs(action.Vo), 1.5,
            "ACI 318-19 Eq. (22.5.1.11)"))
    end
    return records
end

function _push_column_shear!(records, wall, action, shear;
                            face, wall_index, case, direction,
                            demand, capacity, ratio, limit, name)
    cap_N = ustrip(u"N", capacity)
    limit_N = ustrip(u"N", limit)
    push!(records, WallCheckRecord(
        wall_index, wall.story, direction, case, action.combination, action.alternative,
        "$face $name", ratio <= 1.0, ratio,
        demand, cap_N, shear.clause))
    push!(records, WallCheckRecord(
        wall_index, wall.story, direction, case, action.combination, action.alternative,
        "$face $name section", demand <= limit_N + 1.0,
        limit_N == 0 ? Inf : demand / limit_N,
        demand, limit_N, "ACI 318-19 Eq. (22.5.1.2)"))
    return records
end

"""
    column_one_way_shear_capacity(bw, d, Ag, fc, Nu; λ=1) -> NamedTuple

Concrete shear and the cross-section limit, in newtons.

`bw`, `d`, and `Ag` are metres and square metres. `fc` is pascals. `Nu` is
newtons, compression-positive. `λ` is the lightweight factor.

Equation (a) of Table 22.5.5.1, including the §22.5.3.1 cap on √f'c
(100 psi), the §22.5.5.1.2 cap on Nu/(6Ag) (0.05f'c), and the §22.5.5.1.1
ceiling Vc ≤ 5λ√f'c bw d. It is not equation (c). The arithmetic is
[`column_equation_a_pounds`](@ref).

# Citations
ACI 318-19 Table 22.5.5.1(a) (corpus: `aci-318-19`, PDF p. 406):
`Vc = (2λ√f'c + Nu/(6Ag)) bw d`, and `Vc` is not taken less than zero.
`Nu` is positive for compression.
ACI 318-19 §22.5.3.1 and §22.5.5.1.1–.2 (PDF pp. 405 and 407).
ACI 318-19 Eq. (22.5.1.2) (PDF p. 404): `Vu ≤ φ(Vc + 8√f'c bw d)`.
`φ` is [`WALL_PHI_SHEAR`](@ref).
"""
function column_one_way_shear_capacity(bw::Real, d::Real, Ag::Real, fc::Real, Nu::Real;
                                       λ::Real=1.0)
    (bw > 0 && d > 0 && Ag > 0) || throw(ArgumentError(
        "column shear: bw, d, and Ag must be positive."))
    pounds = column_equation_a_pounds(
        bw / Asap.IN_TO_M, d / Asap.IN_TO_M, Ag / (Asap.IN_TO_M^2),
        fc / Asap.PSI_TO_PA, Nu / Asap.LBF_TO_N; λ = λ)
    to_N = Asap.LBF_TO_N
    return (
        ϕVc = WALL_PHI_SHEAR * pounds.Vc_lb * to_N,
        ϕVn_limit = WALL_PHI_SHEAR * pounds.Vn_limit_lb * to_N,
    )
end

"""
    segment_end_moment_ratio(M_bottom, M_top) -> Float64

`M1/M2` for one axis of a vertical segment.

Both moments use the pier-base sign, the moment of the forces above that
cut. The same sign at both ends is one sense of bending along the segment,
which is single curvature. Opposite signs are double curvature. `M1` is
the end with the smaller absolute value. The ratio is negative for single
curvature and positive for double curvature. An end moment within 1 N·m
of zero contributes nothing, so the ratio is zero when the larger end is
that small.

# Citations
ACI 318-19 §6.2.5.1 (corpus: `aci-318-19`, PDF p. 70).
ACI 318-19 §6.6.4.5.3(a) (PDF p. 82) uses the same sign.
"""
function segment_end_moment_ratio(M_bottom::Real, M_top::Real)
    ab = abs(Float64(M_bottom))
    at = abs(Float64(M_top))
    big = max(ab, at)
    big <= 1.0 && return 0.0
    mag = min(ab, at) / big
    same = Float64(M_bottom) * Float64(M_top) > 0
    return same ? -mag : mag
end

"""
    story_end_moments_are_nonsway(first_bottom, first_top, second_bottom, second_top) -> Bool

Whether these end moments satisfy ACI 318-19 §6.6.4.3(a).

The second-order moment at each end, in plane and out of plane, must not
exceed the first-order moment by more than 5 percent. One newton-metre is
the noise floor on these cuts. A first-order moment near zero with a
second-order moment above that floor is not a nonsway end.

# Citation
ACI 318-19 §6.6.4.3(a) (corpus: `aci-318-19`, PDF p. 81).
"""
function story_end_moments_are_nonsway(first_bottom, first_top,
                                      second_bottom, second_top)
    n = length(first_bottom)
    (n == length(first_top) == length(second_bottom) == length(second_top)) ||
        throw(ArgumentError(
            "segment nonsway: the four end-moment lists do not have one length."))
    for i in 1:n
        _segment_end_grew(first_bottom[i].M, second_bottom[i].M) && return false
        _segment_end_grew(first_top[i].M, second_top[i].M) && return false
        _segment_end_grew(first_bottom[i].Mo, second_bottom[i].Mo) && return false
        _segment_end_grew(first_top[i].Mo, second_top[i].Mo) && return false
    end
    return true
end

"True when `m_second` is more than 5 percent above `m_first`, past 1 N·m."
function _segment_end_grew(m_first, m_second)
    return abs(Float64(m_second)) > 1.05 * abs(Float64(m_first)) + 1.0
end

"""A column segment whose story was not shown to be nonsway. Not a passing check."""
function withheld_column_segment(wall::Wall, wall_index::Int, direction::Symbol)
    return WallCheckRecord(
        wall_index, wall.story, direction, :slenderness, :withheld, :only,
        "column segment withheld", false, Inf, 0.0, 0.0,
        "ACI 318-19 6.6.4.3")
end

"""A segment the layout did not route to a wall, a column, a beam, or a deep beam."""
function unchecked_horizontal_segment(wall::Wall, wall_index::Int, direction::Symbol,
                                    design::Symbol)
    return WallCheckRecord(
        wall_index, wall.story, direction, :opening, :unchecked, :only,
        "horizontal segment unchecked", false, Inf, 0.0, 0.0,
        "ACI 318-19 9.9; routed :$design")
end

"""
    check_spandrel_deep_beam(wall, segment, at_start, at_end; kwargs...) -> Vector{WallCheckRecord}

Check one horizontal segment whose clear span does not exceed four times its depth.

The model is one diagonal strut from corner to corner of the band and one
horizontal tie. The couple arm is the overall depth `h`. The tie force is
the larger of the horizontal component of that strut and the end moment
divided by `h`. The strut width perpendicular to its axis is `h cos θ`,
on the member thickness. Each end node anchors that one tie, and its face
perpendicular to the strut is the strut area.

`ρl` is the reinforcement perpendicular to the span and `ρt` is the
reinforcement parallel to it. Each is raised to 0.0025 when it is lower.
Tie steel is the horizontal steel above that 0.0025, and `ρt` is raised
to provide it, not above 0.020.

# Citations
ACI 318-19 §9.9.1.1(a) and §9.9.1.3 (corpus: `aci-318-19`, PDF p. 154).
ACI 318-19 Eq. (9.9.2.1) (PDF p. 154): `Vu ≤ φ 10 √f′c bw d`.
ACI 318-19 §9.9.3.1 (PDF p. 154) and Table 23.5.1(a) (PDF p. 447): 0.0025
in each direction. §9.9.1.1(b), the spacing in §23.5.2, and the development
in §23.8 are not evaluated.
ACI 318-19 Eq. (23.4.1a) and Eq. (23.4.3) (PDF pp. 445–446):
`Fns = fce Acs`, `fce = 0.85 βs βc f′c`. `βc = 1` from Table 23.4.3(b)(c).
`βs = 0.75` from Table 23.4.3(a)(c) when Table 23.5.1 is met, otherwise
`βs = 0.4` from Table 23.4.3(a)(f).
ACI 318-19 Eq. (23.7.2) (PDF p. 449): `Fnt = Ats fy` for nonprestressed steel.
ACI 318-19 Eq. (23.9.1) and Eq. (23.9.2) (PDF p. 448), Table 23.9.2(b)
(PDF p. 451): a node anchoring one tie has `βn = 0.80`.
ACI 318-19 Table 21.2.1(b) and (g) (PDF p. 391): `φ = 0.75`.
"""
function check_spandrel_deep_beam(wall::Wall, segment::WallSegment,
                                at_start::AbstractVector{CombinedWallAction},
                                at_end::AbstractVector{CombinedWallAction};
                                material, wall_index::Int, direction::Symbol)
    segment.kind === :horizontal || throw(ArgumentError(
        "deep-beam spandrel: the segment is $(segment.kind)."))
    segment.design === :stm || throw(ArgumentError(
        "deep-beam spandrel: the segment is routed :$(segment.design)."))
    (isempty(at_start) || isempty(at_end)) && throw(ArgumentError(
        "deep-beam spandrel: both ends need a strength combination."))
    material isa ReinforcedConcreteMaterial || throw(ArgumentError(
        "deep-beam spandrel: material must be a ReinforcedConcreteMaterial."))
    ln = segment.s1 - segment.s0
    h = segment.z1 - segment.z0
    (ln > 0 && h > 0) || throw(ArgumentError(
        "deep-beam spandrel: the band has no span or no depth."))
    # ACI 318-19 Table 20.5.1.3.1, beam row: 1½ in. The tie is a #4 bar.
    cover = 1.5u"inch"
    db = 0.5u"inch"
    d = h * u"m" - cover - db / 2
    bw = wall.thickness
    fc = material.concrete.fc′
    fy = material.rebar.Fy
    # Table 21.2.1(b) for the shear limit and (g) for the strut, tie, and node.
    ϕ = 0.75
    records = WallCheckRecord[]
    shear_action = _governing_beam_action(at_start, at_end, :V)
    flexure_action = _governing_beam_action(at_start, at_end, :M)
    Vu = abs(shear_action.V)
    Mu = abs(flexure_action.M)
    push!(records, _deep_shear_record(
        wall_index, wall.story, direction, shear_action, Vu, bw, d, fc, ϕ))
    push!(records, _deep_side_record(wall, wall_index, direction))
    push!(records, _deep_strut_record(
        wall, wall_index, direction, shear_action, Vu, Mu, ln, h, bw, fc, ϕ))
    push!(records, _deep_tie_record(
        wall, wall_index, direction, flexure_action, Vu, Mu, ln, h, bw, fy, ϕ))
    push!(records, _deep_node_record(
        wall, wall_index, direction, shear_action, Vu, Mu, ln, h, bw, fc, ϕ))
    return records
end

"Eq. (9.9.2.1), with `√f′c` in psi and the product in pounds."
function _deep_shear_record(wall_index, story, direction, action, Vu, bw, d, fc, ϕ)
    if ustrip(u"m", d) <= 1e-4 || ustrip(u"m", bw) <= 1e-4
        return WallCheckRecord(
            wall_index, story, direction, :opening,
            action.combination, action.alternative,
            "deep-beam shear limit", false, Inf, Vu, 0.0, "ACI 318-19 9.9.2.1")
    end
    cap_lb = ϕ * 10 * sqrt(ustrip(u"psi", fc)) *
             ustrip(u"inch", bw) * ustrip(u"inch", d)
    demand = Vu
    capacity = ustrip(u"N", cap_lb * u"lbf")
    return WallCheckRecord(
        wall_index, story, direction, :opening,
        action.combination, action.alternative,
        "deep-beam shear limit", demand <= capacity + 1.0,
        capacity > 0 ? demand / capacity : Inf, demand, capacity,
        "ACI 318-19 9.9.2.1")
end

"§9.9.3.1 and Table 23.5.1(a). Each ratio is raised to 0.0025."
function _deep_side_record(wall, wall_index, direction)
    wall.ρl = max(wall.ρl, 0.0025)
    wall.ρt = max(wall.ρt, 0.0025)
    prov = min(wall.ρl, wall.ρt)
    return WallCheckRecord(
        wall_index, wall.story, direction, :opening, :D, :only,
        "deep-beam side reinforcement", prov + 1e-12 >= 0.0025,
        prov > 0 ? 0.0025 / prov : Inf, 0.0025, prov,
        "ACI 318-19 9.9.3.1; 23.5.1")
end

"Tie force, in newtons, for the corner-to-corner strut on arm `h`."
function _deep_tie_force(Vu, Mu, ln, h)
    return max(Vu * ln / h, Mu / h)
end

"Strut force, in newtons, matching the tie's horizontal component."
function _deep_strut_force(Vu, Mu, ln, h)
    hyp = hypot(ln, h)
    cosθ = ln / hyp
    return _deep_tie_force(Vu, Mu, ln, h) / cosθ
end

"`βs` from Table 23.4.3(a)(c) or (f)."
function _deep_beta_s(wall)
    return (wall.ρl + 1e-12 >= 0.0025 && wall.ρt + 1e-12 >= 0.0025) ? 0.75 : 0.4
end

"Strut area `bw * h * cos θ`, in m²."
function _deep_strut_area(bw, ln, h)
    cosθ = ln / hypot(ln, h)
    return ustrip(u"m", bw) * h * cosθ
end

function _deep_strut_record(wall, wall_index, direction, action, Vu, Mu, ln, h, bw, fc, ϕ)
    Fus = _deep_strut_force(Vu, Mu, ln, h)
    # Eq. (23.4.3). βc = 1 from Table 23.4.3(b)(c): no bearing surface.
    fce = 0.85 * _deep_beta_s(wall) * 1.0 * fc
    Acs = _deep_strut_area(bw, ln, h)
    capacity = ustrip(u"N", ϕ * fce * Acs * u"m^2")
    return WallCheckRecord(
        wall_index, wall.story, direction, :opening,
        action.combination, action.alternative,
        "deep-beam strut", Fus <= capacity + 1.0,
        capacity > 0 ? Fus / capacity : Inf, Fus, capacity,
        "ACI 318-19 23.4.1; 23.4.3")
end

function _deep_tie_record(wall, wall_index, direction, action, Vu, Mu, ln, h, bw, fy, ϕ)
    Fut = _deep_tie_force(Vu, Mu, ln, h) * u"N"
    # Eq. (23.7.2) with Atp = 0. The 0.0025 stays as the distributed grid.
    Ats = Fut / (ϕ * fy)
    bw_m = ustrip(u"m", bw)
    area = bw_m * h
    need = area > 0 ? 0.0025 + ustrip(u"m^2", Ats) / area : Inf
    need <= 0.0200 + 1e-12 && (wall.ρt = max(wall.ρt, need))
    prov = max(wall.ρt - 0.0025, 0.0) * area
    req = ustrip(u"m^2", Ats)
    return WallCheckRecord(
        wall_index, wall.story, direction, :opening,
        action.combination, action.alternative,
        "deep-beam tie", prov + 1e-9 >= req,
        prov > 0 ? req / prov : Inf, req, prov,
        "ACI 318-19 23.7.2")
end

function _deep_node_record(wall, wall_index, direction, action, Vu, Mu, ln, h, bw, fc, ϕ)
    Fus = _deep_strut_force(Vu, Mu, ln, h)
    # Table 23.9.2(b): one tie. The face perpendicular to the strut is Acs.
    fce = 0.85 * 1.0 * 0.80 * fc
    Anz = _deep_strut_area(bw, ln, h)
    capacity = ustrip(u"N", ϕ * fce * Anz * u"m^2")
    return WallCheckRecord(
        wall_index, wall.story, direction, :opening,
        action.combination, action.alternative,
        "deep-beam node", Fus <= capacity + 1.0,
        capacity > 0 ? Fus / capacity : Inf, Fus, capacity,
        "ACI 318-19 23.9.1; 23.9.2")
end

"""
    check_spandrel_beam(wall, segment, at_start, at_end; kwargs...) -> Vector{WallCheckRecord}

Check one horizontal segment whose clear span is longer than four times its depth.

Flexure and shear are the existing beam designers. The width is the wall
thickness. The depth is the band height `z1 − z0`. The effective depth
deducts the 1½ in beam cover, a #3 stirrup, and a ½ in bar, which is the
centroid `design_beam_flexure` uses for compression steel. Shear uses the
end force from the cut, and the axial force on that same combination.
Flexure uses the beam equation and does not include axial force.

A band that the section cannot reinforce is a recorded failure. A deep
beam is not this check.

# Citations
ACI 318-19 §9.9.1.1(a) (corpus: `aci-318-19`, PDF p. 154): the clear span
is longer than `4h`, so this is not the deep-beam route.
ACI 318-11 §10.2 and §10.5, as implemented by [`design_beam_flexure`](@ref).
ACI 318-11 §11.2 and §11.4, as implemented by [`design_beam_shear`](@ref).
ACI 318-19 Table 20.5.1.3.1 (PDF p. 384): 1½ in for a beam not exposed to
weather and not cast against ground. The beam designer uses that cover.
"""
function check_spandrel_beam(wall::Wall, segment::WallSegment,
                           at_start::AbstractVector{CombinedWallAction},
                           at_end::AbstractVector{CombinedWallAction};
                           material, wall_index::Int, direction::Symbol)
    segment.kind === :horizontal || throw(ArgumentError(
        "spandrel beam: the segment is $(segment.kind)."))
    segment.design === :beam || throw(ArgumentError(
        "spandrel beam: the segment is routed :$(segment.design). " *
        "A deep beam is not this check."))
    (isempty(at_start) || isempty(at_end)) && throw(ArgumentError(
        "spandrel beam: both ends need a strength combination."))
    material isa ReinforcedConcreteMaterial || throw(ArgumentError(
        "spandrel beam: material must be a ReinforcedConcreteMaterial."))
    h = (segment.z1 - segment.z0) * u"m"
    b = wall.thickness
    # ACI 318-19 Table 20.5.1.3.1, beam row. The stirrup and bar match the
    # centroid inside design_beam_flexure.
    cover = 1.5u"inch"
    d_stirrup = 0.375u"inch"
    db = 0.5u"inch"
    d = h - cover - d_stirrup - db / 2
    records = WallCheckRecord[]
    if ustrip(u"m", d) <= 1e-4 || ustrip(u"m", b) <= 1e-4
        push!(records, WallCheckRecord(
            wall_index, wall.story, direction, :opening, :only, :only,
            "spandrel flexure", false, Inf, 0.0, 0.0,
            "ACI 318-11 10.2; the band has no effective depth"))
        return records
    end
    flexure_action = _governing_beam_action(at_start, at_end, :M)
    shear_action = _governing_beam_action(at_start, at_end, :V)
    Mu = abs(flexure_action.M) * u"N*m"
    Vu = abs(shear_action.V) * u"N"
    Nu = shear_action.N * u"N"
    Ag = b * h
    fc = material.concrete.fc′
    fy = material.rebar.Fy
    Es = material.rebar.E
    fyt = material.transverse.Fy
    λ = material.concrete.λ
    push!(records, _spandrel_flexure_record(
        wall, wall_index, direction, flexure_action, Mu, b, d, fc, fy, Es))
    push!(records, _spandrel_shear_record(
        wall, wall_index, direction, shear_action, Vu, b, d, fc, fyt, λ, Nu, Ag))
    return records
end

"The action with the largest absolute `field` at either end."
function _governing_beam_action(at_start, at_end, field::Symbol)
    best = first(at_start)
    best_abs = abs(getfield(best, field))
    for action in Iterators.flatten((at_start, at_end))
        value = abs(getfield(action, field))
        value > best_abs || continue
        best = action
        best_abs = value
    end
    return best
end

function _spandrel_flexure_record(wall, wall_index, direction, action, Mu, b, d, fc, fy, Es)
    designed = try
        design_beam_flexure(Mu, b, d, fc, fy, Es)
    catch err
        err isa ErrorException || rethrow()
        return WallCheckRecord(
            wall_index, wall.story, direction, :opening,
            action.combination, action.alternative,
            "spandrel flexure", false, Inf,
            ustrip(u"N*m", Mu), 0.0,
            "ACI 318-11 10.2; " * sprint(showerror, err))
    end
    if designed.doubly_reinforced
        req = ustrip(u"m^2", designed.As_tension)
        prov = ustrip(u"m^2", designed.bars_tension.As_provided)
        comp_req = ustrip(u"m^2", designed.As_compression)
        comp_prov = ustrip(u"m^2", designed.bars_compression.As_provided)
        fits = prov + 1e-9 >= req && comp_prov + 1e-9 >= comp_req
        clause = "ACI 318-11 10.2; doubly reinforced"
    else
        req = ustrip(u"m^2", designed.As_design)
        prov = ustrip(u"m^2", designed.bars.As_provided)
        fits = prov + 1e-9 >= req
        clause = "ACI 318-11 10.2"
    end
    return WallCheckRecord(
        wall_index, wall.story, direction, :opening,
        action.combination, action.alternative,
        "spandrel flexure", fits, prov > 0 ? req / prov : Inf, req, prov, clause)
end

function _spandrel_shear_record(wall, wall_index, direction, action, Vu, b, d,
                              fc, fyt, λ, Nu, Ag)
    designed = design_beam_shear(Vu, b, d, fc, fyt; λ=λ, Nu=Nu, Ag=Ag)
    demand = ustrip(u"N", Vu)
    capacity = ustrip(u"N", designed.section_adequate ? designed.φVn : designed.φVc)
    return WallCheckRecord(
        wall_index, wall.story, direction, :opening,
        action.combination, action.alternative,
        "spandrel shear", designed.section_adequate,
        capacity > 0 ? demand / capacity : Inf, demand, capacity,
        "ACI 318-11 11.2")
end
