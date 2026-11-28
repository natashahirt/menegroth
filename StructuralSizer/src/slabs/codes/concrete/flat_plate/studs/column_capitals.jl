# =============================================================================
# Column Capital Design for Punching Shear — ACI 318-11 §13.1.2
# =============================================================================
#
# A column capital is a flared enlargement of the column head. The effective
# support area is defined by the intersection of the slab soffit with the
# largest right circular cone / right pyramid / tapered wedge whose surfaces
# are within the column and capital, oriented ≤ 45° to the column axis.
#
# 45° Rule (§13.1.2):
#   A capital projecting h_cap below the slab flares h_cap beyond each column
#   face that has slab beyond it. At a slab edge it stops at the edge.
#
# The critical section is at d/2 from the effective support (§11.11.1.2(a)),
# in the slab depth d.
#
# =============================================================================

using Unitful
using Unitful: @u_str
using Asap: Length, Pressure, Force, Moment, Area

"""
    design_column_capital(col, Vu, Mub, fc, d, h; Muy=nothing, λ=1.0, φ=0.75,
                          max_projection=nothing, h_increment=0.5u"inch",
                          punch_kwargs=(;)) -> ColumnCapitalDesign

Smallest capital, in steps of `h_increment` up to `max_projection` (default
the shorter column side), whose effective support passes punching at d/2
under `Vu`, `Mub` (spanning along `punch_kwargs.span_axis`) and `Muy`.

The effective support is the 45° footprint ([`_support_footprint`](@ref)
with extent `h_cap`), the loaded area for β; the edge and corner centroid
shift is taken from the column centre. The check is
[`check_punching_for_column`](@ref) (Eq. 13-1 transfer). Skew or re-entrant
corners, and edge or corner columns with slab openings, return a design that
is not ok.

# Reference
- ACI 318-11 §13.1.2, §11.11.1.2
"""
function design_column_capital(col, Vu::Force, Mub::Moment, fc::Pressure, d::Length, h::Length;
                               Muy::Union{Moment, Nothing} = nothing,
                               λ::Float64 = 1.0, φ::Float64 = 0.75,
                               max_projection::Union{Length, Nothing} = nothing,
                               h_increment::Length = 0.5u"inch",
                               punch_kwargs = (;))
    max_proj = something(max_projection, min(col.c1, col.c2))
    _enlarged_support_supported(col, punch_kwargs) ||
        return ColumnCapitalDesign(required = true, ratio = Inf, ok = false)
    edge_par = get(punch_kwargs, :free_edge_parallel, nothing)
    kw = (; λ = λ, φ_shear = φ, Muy = Muy, punch_kwargs...)

    function attempt(h_cap)
        fp = _support_footprint(col, h_cap; free_edge_parallel = edge_par)
        chk = check_punching_for_column(_support_proxy(col, fp), Vu, Mub, d, h, fc;
                                        kw..., centroid_dims = fp.centroid_dims)
        return ColumnCapitalDesign(
            required = true,
            h_cap = uconvert(u"inch", h_cap),
            c1_eff = uconvert(u"inch", fp.c1),
            c2_eff = uconvert(u"inch", fp.c2),
            b0_eff = uconvert(u"inch", chk.b0),
            ratio = chk.ratio,
            ok = chk.ratio <= 1.0,
            shape = fp.shape,
        )
    end

    best = nothing
    h_cap = h_increment
    while h_cap <= max_proj
        best = attempt(h_cap)
        best.ok && return best
        h_cap += h_increment
    end
    return something(best, attempt(max_proj))
end

"""
    check_punching_with_capital(capital::ColumnCapitalDesign) -> NamedTuple

`(ok, ratio, message)` of a designed column capital.
"""
function check_punching_with_capital(capital::ColumnCapitalDesign)
    if !capital.required
        return (ok=false, ratio=Inf, message="Column capital not designed")
    end
    msg = capital.ok ?
        "OK (capital h=$(capital.h_cap)): ratio=$(round(capital.ratio, digits=3))" :
        "NG (capital h=$(capital.h_cap)): ratio=$(round(capital.ratio, digits=3)) > 1.0"
    return (ok=capital.ok, ratio=capital.ratio, message=msg)
end
