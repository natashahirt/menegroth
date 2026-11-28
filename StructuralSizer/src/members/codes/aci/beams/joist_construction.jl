# ACI 318-11 §8.13 — Joist construction
#
# Corpus: aci-318-11, PDF pages 120–121 (printed pages 116–117).
# §8.13.1 separates the ribs from the top slab, and §8.13.2 limits the rib
# depth. That depth is the stem: bottom of the rib to the underside of the
# slab. The slab thickness is checked on its own (§8.13.5.2 or §8.13.6.1).
# ACI 318-19 §9.8.1.3 names the same 3.5 limit "overall depth of ribs"
# (corpus: aci-318-19, PDF page 153). A worked waffle example applying that
# sentence uses a 14 in rib and a separate 3 in slab, 17 in total
# (sp-de-two-way-waffle-slab-aci318-14, PDF pages 12–13).

"""
    JoistConstruction

Monolithic joist construction of ACI 318-11 §8.13.1: regularly spaced ribs and
a top slab spanning in one direction (`:one_way`) or two orthogonal directions
(`:two_orthogonal`).

`rib_width` is the minimum width of the rib. `rib_depth` is the stem, from the
bottom of the rib to the underside of the slab. `clear_spacing` is the clear
distance between ribs. `slab_thickness` is the thickness of the top slab.

`permanent_structural_filler = false` selects removable forms, or fillers that
do not meet §8.13.5, so the slab-thickness limit is §8.13.6.1. `true` asserts
that the filler meets §8.13.5, including a unit compressive strength at least
equal to ``f'c`` of the joists, so the slab-thickness limit is §8.13.5.2.
"""
struct JoistConstruction
    direction::Symbol
    rib_width::typeof(1.0u"inch")
    rib_depth::typeof(1.0u"inch")
    clear_spacing::typeof(1.0u"inch")
    slab_thickness::typeof(1.0u"inch")
    permanent_structural_filler::Bool
end

_as_inches(x) = float(ustrip(u"inch", x)) * u"inch"

function JoistConstruction(direction::Symbol, rib_width, rib_depth,
                           clear_spacing, slab_thickness;
                           permanent_structural_filler::Bool = false)
    direction in (:one_way, :two_orthogonal) || throw(ArgumentError(
        "JoistConstruction direction must be :one_way or :two_orthogonal " *
        "(ACI 318-11 §8.13.1); got :$direction"))
    return JoistConstruction(direction, _as_inches(rib_width), _as_inches(rib_depth),
                             _as_inches(clear_spacing), _as_inches(slab_thickness),
                             permanent_structural_filler)
end

"""
    JoistConstruction(section::RCTBeamSection, center_spacing, direction; ...)

Rib stem `h − hf`, slab thickness `hf`, and clear spacing `center_spacing − bw`
for a prismatic rib. `h` is the total depth and `hf` is the flange thickness
on [`RCTBeamSection`](@ref). A tapered rib has to use the positional
constructor with its minimum width and its maximum clear spacing.
"""
function JoistConstruction(section::RCTBeamSection, center_spacing, direction::Symbol;
                           permanent_structural_filler::Bool = false)
    stem = section.h - section.hf
    clear = center_spacing - section.bw
    ustrip(u"inch", clear) > 0 || throw(ArgumentError(
        "center-to-center spacing must be greater than the rib width"))
    return JoistConstruction(direction, section.bw, stem, clear, section.hf;
                             permanent_structural_filler)
end

"""
    joist_topping_thickness(center_spacing; rib_width=4inch) -> Length or nothing

Top-slab thickness of joist construction with removable forms.

ACI 318-11 §8.13.6.1 (corpus: aci-318-11, page 120): not less than one-twelfth
the clear distance between ribs, and not less than 2 in. The clear distance
is `center_spacing` minus `rib_width`. The default width is the §8.13.2
minimum, 4 in, which gives the largest clear distance and so the thickest
minimum. Returns `nothing` when that clear distance exceeds the §8.13.3
limit of 30 in: §8.13.4 then requires slabs and beams, and this thickness
does not apply.
"""
function joist_topping_thickness(center_spacing::Length; rib_width::Length = 4.0u"inch")
    clear = uconvert(u"inch", center_spacing - rib_width)
    ustrip(u"inch", clear) > 0 || throw(ArgumentError(
        "the rib spacing is not wider than the rib, got $center_spacing with $rib_width"))
    ustrip(u"inch", clear) <= 30 || return nothing
    return max(clear / 12, 2.0u"inch")
end

"""
    check_joist_construction(joist) -> NamedTuple

ACI 318-11 §8.13.2–§8.13.6 limits (corpus: aci-318-11, PDF page 120).

`vc_increase_permitted` is true when §8.13.2 and §8.13.3 are met. §8.13.4
requires anything else to be designed as slabs and beams, so §8.13.8's 10
percent increase in ``Vc`` does not apply. Slab thickness is reported separately:
it is required by §8.13.5.2 or §8.13.6.1, and it does not gate the shear increase.
"""
function check_joist_construction(joist::JoistConstruction)
    width_in = ustrip(u"inch", joist.rib_width)
    depth_in = ustrip(u"inch", joist.rib_depth)
    clear_in = ustrip(u"inch", joist.clear_spacing)
    slab_in = ustrip(u"inch", joist.slab_thickness)

    # ACI 318-11 §8.13.2 — rib width at least 4 in.
    width_ok = width_in >= 4.0
    # ACI 318-11 §8.13.2 — rib depth not more than 3-1/2 times the minimum
    # rib width. The depth is the stem below the slab (see the file header).
    depth_ok = depth_in <= 3.5 * width_in
    # ACI 318-11 §8.13.3 — clear spacing between ribs not more than 30 in.
    spacing_ok = clear_in <= 30.0
    # ACI 318-11 §8.13.5.2 (permanent filler) or §8.13.6.1 (removable forms):
    # slab thickness at least one-twelfth the clear distance, and at least
    # 1-1/2 in. or 2 in.
    slab_floor_in = joist.permanent_structural_filler ? 1.5 : 2.0
    slab_ok = slab_in >= max(clear_in / 12, slab_floor_in)

    return (
        width_ok = width_ok,
        depth_ok = depth_ok,
        spacing_ok = spacing_ok,
        slab_ok = slab_ok,
        vc_increase_permitted = width_ok && depth_ok && spacing_ok,
        ok = width_ok && depth_ok && spacing_ok && slab_ok,
    )
end

# ACI 318-11 §8.13.8 (corpus: aci-318-11, PDF page 121): one-way `Vc` may be
# 10 percent more than Chapter 11. ACI 318-19 §8.8.1.5 (corpus: aci-318-19,
# PDF page 127) limits that increase to the one-way values in §22.5, so
# punching never receives it. This is the only copy of the factor.
const JOIST_ONE_WAY_VC_FACTOR = 1.10

"""
    Vc_joist(joist, bw, d, fc; kwargs...) -> Force

Chapter 11 one-way ``Vc`` from [`Vc_beam`](@ref), increased by
[`JOIST_ONE_WAY_VC_FACTOR`](@ref) when [`check_joist_construction`](@ref)
permits it. The factor comes from [`_joist_vc_factor`](@ref), the same helper
`design_beam_shear` uses, so the two paths cannot drift.

ACI 318-11 §8.13.8 (corpus: aci-318-11, PDF page 121). §8.13.4 withholds the
increase when §8.13.2 or §8.13.3 is not met. `bw` is the web width used in
Chapter 11, which need not equal the minimum rib width. Two-way shear does
not call this function.
"""
function Vc_joist(joist::JoistConstruction, bw::Length, d::Length, fc::Pressure;
                  kwargs...)
    return _joist_vc_factor(joist) * Vc_beam(bw, d, fc; kwargs...)
end

"""
    joist_rib_line(widths, stems) -> NamedTuple

ACI 318-11 §8.13.2 for one rib made of prismatic pieces (corpus: aci-318-11,
PDF page 120). Every piece is at least 4 in wide, and no piece's stem is more
than 3-1/2 times the least width of that rib. `widths` and `stems` are
lengths, or bare numbers in inches. The stem is the rib below the slab.
"""
function joist_rib_line(widths, stems)
    length(widths) == length(stems) || throw(ArgumentError(
        "each piece of a rib needs a width and a stem"))
    isempty(widths) && throw(ArgumentError("a rib line needs a piece"))
    w = Float64[_rib_inches(x) for x in widths]
    s = Float64[_rib_inches(x) for x in stems]
    all(>(0), w) && all(>=(0), s) || throw(ArgumentError(
        "a rib width is positive and a stem is not negative"))
    least = minimum(w)
    deepest = maximum(s)
    return (
        width_ok = all(>=(4.0), w),
        depth_ok = deepest <= 3.5 * least + 1e-9,
        bw_min_in = least,
        stem_max_in = deepest,
        bw_required_in = deepest / 3.5,
    )
end

_rib_inches(x::Number) = x isa Unitful.Quantity ? ustrip(u"inch", x) : Float64(x)

"""
One-way shear-increase factor for a joist passed into `design_beam_shear`.

Returns [`JOIST_ONE_WAY_VC_FACTOR`](@ref) when `joist` meets §8.13.2 and
§8.13.3, and `1.0` for `nothing` or a joist §8.13.4 excludes. Punching checks
do not call this.
"""
function _joist_vc_factor(joist)
    joist === nothing && return 1.0
    return check_joist_construction(joist).vc_increase_permitted ?
        JOIST_ONE_WAY_VC_FACTOR : 1.0
end
