# Punching at a solid head.
#
# Two sections, ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200):
# (a) d/2 from the column, through the solid head at its full depth, with
#     unbalanced-moment transfer (§11.11.7 and §13.5.3) on the existing
#     column path;
# (b) d/2 from the head edge. No code clause gives the shear area where that
#     perimeter crosses ribs. The area used here is the vendor equivalent
#     thickness of spSlab Eq. 2-14 (sp-de-two-way-waffle-slab-aci318-14,
#     reference text page 61):
#
#         d_v = (Σ b_w h) / (head width)
#
#     and v_u = V_u / (b_0 d_v). That is direct shear. The same example
#     computes a polar moment at this section and multiplies v_c by 1.10
#     under ACI 318-14 §9.8.1.5. Neither is applied: eccentric shear here is
#     not a code clause, and the joist increase is one-way shear only.
#
# This file does not call the joist factor.

"""
    rib_web_critical_section(head_x, head_y, d; position) -> NamedTuple

The section at `d/2` outside a solid head.

ACI 318-11 §11.11.1.2(b) (corpus: aci-318-11, page 200) places that section
at `d/2` from a change in slab thickness. `d` is the solid head's effective
depth. In the waffle example that offset is 15.88 in, and the equivalent
rib thickness is a different number used only for the stress.

`head_x` and `head_y` are the plan size the same geometry uses for a column:

- `:corner` — each is the distance from a slab edge to the inner face of the head
- `:edge` — `head_x` is the free-edge-to-face distance, `head_y` the full width
  parallel to the edge
- `:interior` — both are the full head widths

The enclosed area is `b1 * b2`, which is the area the example deducts
(`89.94 in × 159.88 in` on the exterior head).
"""
function rib_web_critical_section(head_x::Length, head_y::Length, d::Length;
                                  position::Symbol)
    position in (:interior, :edge, :corner) || throw(ArgumentError(
        "a rib-web section is :interior, :edge, or :corner, got :$position"))
    head_x > zero(head_x) || throw(ArgumentError(
        "the head extent head_x is positive, got $head_x"))
    head_y > zero(head_y) || throw(ArgumentError(
        "the head extent head_y is positive, got $head_y"))
    d > zero(d) || throw(ArgumentError(
        "the head's effective depth is positive, got $d"))
    geom = punching_geometry(head_x, head_y, d; position = position)
    b1, b2 = geom.b1, geom.b2
    return (
        b0 = geom.b0,
        b1 = b1,
        b2 = b2,
        side_long = max(b1, b2),
        side_short = min(b1, b2),
        section_area = b1 * b2,
        position = position,
    )
end

"""
    ribs_across_solid_head(n, solid_head) -> Int

Rib webs counted across one side of a solid head.

The waffle example counts one web per rib module the drop covers
(4 ribs across a 12 ft drop). `solid_head` is that coverage as a fraction
of the panel, and it is already a whole number of the `n` modules.
"""
function ribs_across_solid_head(n::Integer, solid_head::Real)
    n >= 1 || throw(ArgumentError("a rib grid needs at least one bay, got $n"))
    s = Float64(solid_head)
    (s > 0 && s < 0.5) || throw(ArgumentError(
        "the head covers a positive fraction below one half, got $s"))
    k = ceil(Int, s * n - 1e-9)
    abs(k / n - s) <= 1e-8 || throw(ArgumentError(
        "solid_head $s is not a whole number of the $n modules"))
    k >= 1 || throw(ArgumentError("the head covers no rib module"))
    return k
end

"""
    equivalent_rib_thickness(web_area, head_width) -> Length

spSlab Eq. 2-14 (sp-de-two-way-waffle-slab-aci318-14, reference text page 61).

`web_area` is the rib webs counted across `head_width` (Σ b_w h in the
example: 4 × 17 in × 7.32 in over 150 in, giving 3.32 in). The critical
perimeter then uses this thickness in place of the solid slab depth.
"""
function equivalent_rib_thickness(web_area::Area, head_width::Length)
    head_width > zero(head_width) || throw(ArgumentError(
        "the head width in the rib-web thickness is positive, got $head_width"))
    web_area > zero(web_area) || throw(ArgumentError(
        "the rib webs crossing the head width have positive area, got $web_area"))
    return web_area / head_width
end

"""
    check_rib_web_punching(Vu, b0, web_area, head_width, fc;
                           d_size, side_long, side_short, position, qu, section_area)
        -> NamedTuple

Direct shear on the section d/2 outside the solid head.

`Vu` is the column reaction. When `qu` and `section_area` are both passed,
the load inside the critical section is subtracted, which is the deduction
in the waffle example (reference text page 61). `side_long` and `side_short`
are the sides of that section and set β. `position` sets αs.

v_c is [`punching_capacity_stress`](@ref) at the equivalent thickness. The
size-effect factor λs (ACI 318-19 §22.5.5.1.3) is taken at `d_size`, the
member's effective depth, which is the depth the column section uses. The
smeared web thickness is not a member depth and would always give λs = 1.
The 1.10 joist increase is not applied. `eccentric_shear` is false: moment
transfer at this section is not covered by a code clause.
"""
function check_rib_web_punching(Vu::Force, b0::Length, web_area::Area, head_width::Length,
                                fc::Pressure;
                                d_size::Length,
                                side_long::Length, side_short::Length,
                                position::Symbol,
                                qu::Union{Nothing, Pressure} = nothing,
                                section_area::Union{Nothing, Area} = nothing,
                                λ::Float64 = 1.0, φ::Float64 = 0.75)
    position in (:interior, :edge, :corner) || throw(ArgumentError(
        "a rib-web punching section is :interior, :edge, or :corner, got :$position"))
    b0 > zero(b0) || throw(ArgumentError("the critical perimeter is positive, got $b0"))
    side_short > zero(side_short) || throw(ArgumentError(
        "the short side of the rib-web section is positive, got $side_short"))
    side_long >= side_short || throw(ArgumentError(
        "side_long ($side_long) is the longer side of the rib-web section, " *
        "and side_short is $side_short"))
    d_v = equivalent_rib_thickness(web_area, head_width)
    Vu_net = Vu
    if qu !== nothing || section_area !== nothing
        (qu !== nothing && section_area !== nothing) || throw(ArgumentError(
            "deducting the load inside the rib-web section needs both qu and the section area"))
        Vu_net = max(Vu - qu * section_area, zero(Vu))
    end
    # β = long / short. αs is §11.11.2.1(b): 40, 30, or 20.
    β = ustrip(u"inch", side_long) / ustrip(u"inch", side_short)
    αs = punching_αs(position)
    vu = uconvert(u"psi", Vu_net / (b0 * d_v))
    vc = punching_capacity_stress(fc, β, αs, b0, d_v; λ = λ, λs = size_effect_factor(d_size))
    φvc = φ * vc
    ratio = ustrip(u"psi", vu) / ustrip(u"psi", φvc)
    return (
        ok = vu <= φvc,
        ratio = ratio,
        vu = vu,
        φvc = φvc,
        b0 = b0,
        d_equivalent = d_v,
        Ac = b0 * d_v,
        Vu = Vu_net,
        eccentric_shear = false,
        eccentric_shear_note = "Eccentric shear at the rib-web section is not covered by a code clause.",
        joist_increase = false,
        section = :rib_web,
    )
end

"""
    check_solid_head_column_punching(col, Vu, Mub, d, h, fc; kwargs...)

Punching at d/2 from the column, through the solid head.

`d` and `h` are the full head. Moment transfer is the existing column check
(ACI 318-11 §11.11.7 and §13.5.3). The joist increase is not applied.
"""
function check_solid_head_column_punching(col, Vu, Mub, d, h, fc; kwargs...)
    chk = check_punching_for_column(col, Vu, Mub, d, h, fc; kwargs...)
    return merge(chk, (eccentric_shear = true, joist_increase = false, section = :column))
end
