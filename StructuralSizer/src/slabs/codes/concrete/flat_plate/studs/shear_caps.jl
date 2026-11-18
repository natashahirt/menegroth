# =============================================================================
# Shear Cap Design for Punching Shear — ACI 318-11 §13.2.6 / §11.11.1.2
# =============================================================================
#
# A shear cap is a localized projection below the slab at the column.
#
# Geometry (§13.2.6, corpus: aci-318-11, page 244):
#   The cap extends horizontally from the column face at least the
#   projection below the slab soffit: extent ≥ h_cap. At a slab edge the cap
#   stops at the edge, so it grows only toward the slab interior there.
#
# Critical sections (§11.11.1.2, page 200; R11.11.1.2, page 200: "For slabs
# with changes in thickness, such as the edge of drop panels or shear caps,
# it is necessary to check shear at several sections"):
#   (a) d/2 from the column face, through the cap: depth d + h_cap.
#   (b) d/2 outside the cap edge, in the slab: depth d.
#   The worse ratio governs.
#
# =============================================================================

using Unitful
using Unitful: @u_str
using Asap: Length, Pressure, Force, Moment, Area

"""
    _support_footprint(col, ext; free_edge_parallel=nothing) -> NamedTuple

Plan footprint of a support enlarged by `ext` from each column face that has
slab beyond it: both sides at an interior column, one side perpendicular to
the free edge and both sides along it at an edge column, one side each way
at a corner. Returns `(c1, c2, shape, centroid_dims)` in the column's named
axes; `centroid_dims` is the column itself, which carries `Vu` and the
moments. Circular edge and corner columns use the equivalent square, as the
punching check does.
"""
function _support_footprint(col, ext; free_edge_parallel = nothing)
    pos = col.position
    if col_shape(col) == :circular
        if pos == :interior
            D = col.c1 + 2ext
            return (c1 = D, c2 = D, shape = :circular, centroid_dims = (col.c1, col.c1))
        end
        c1 = c2 = equivalent_square_column(col.c1)
    else
        c1, c2 = col.c1, col.c2
    end
    ctr = (c1, c2)
    if pos == :interior
        return (c1 = c1 + 2ext, c2 = c2 + 2ext, shape = :rectangular, centroid_dims = ctr)
    elseif pos == :edge
        edge_par = something(free_edge_parallel, _infer_free_edge_parallel(col))
        # :c2 — the free edge runs along c2, so c1 is perpendicular to it.
        Δ1, Δ2 = edge_par === :c2 ? (ext, 2ext) : (2ext, ext)
        return (c1 = c1 + Δ1, c2 = c2 + Δ2, shape = :rectangular, centroid_dims = ctr)
    end
    return (c1 = c1 + ext, c2 = c2 + ext, shape = :rectangular, centroid_dims = ctr)
end

"""
    _enlarged_support_supported(col, punch_kwargs) -> Bool

`false` where the closed-form footprint above does not describe the support:
skew or re-entrant corners (the punching check builds their section from the
column polygon) and edge or corner columns with slab openings (the opening
section is built about the column centre).
"""
function _enlarged_support_supported(col, punch_kwargs)
    if col.position == :corner && hasproperty(col, :corner_kind)
        kind = getfield(col, :corner_kind)
        angle = hasproperty(col, :corner_angle) ? Float64(getfield(col, :corner_angle)) : NaN
        kind == :reentrant && return false
        kind == :convex && !isnan(angle) && !isapprox(angle, π / 2; atol = 0.12) && return false
    end
    ops = get(punch_kwargs, :openings, nothing)
    has_openings = ops !== nothing && !isempty(ops) && get(punch_kwargs, :column_xy, nothing) !== nothing
    return !(has_openings && col.position != :interior)
end

"""Column-like stand-in for an enlarged support, keeping the column's orientation data."""
function _support_proxy(col, fp)
    base = (position = col.position, c1 = fp.c1, c2 = fp.c2, shape = fp.shape)
    hasproperty(col, :θ) && (base = merge(base, (θ = getfield(col, :θ),)))
    hasproperty(col, :boundary_edge_dirs) &&
        (base = merge(base, (boundary_edge_dirs = getfield(col, :boundary_edge_dirs),)))
    return base
end

"""
    design_shear_cap(col, Vu, Mub, fc, d, h; Muy=nothing, λ=1.0, φ=0.75,
                     max_projection=nothing, h_increment=0.25u"inch",
                     punch_kwargs=(;)) -> ShearCapDesign

Smallest shear cap, in steps of `h_increment` up to `max_projection`
(default `h`), for which both §11.11.1.2 critical sections pass under the
demand `Vu`, `Mub` (spanning along `punch_kwargs.span_axis`) and `Muy`:

- (a) at d/2 from the column face, depth `d + h_cap`;
- (b) at d/2 outside the cap, slab depth `d`, with the cap footprint as the
  loaded area (β from the footprint) and the edge and corner centroid shift
  taken from the column centre.

Both sections use [`check_punching_for_column`](@ref) (Eq. 13-1 transfer;
the §13.5.3.3 increase is not applied). `punch_kwargs` are the same keywords
the column's own punching check uses (`punching_axis_kwargs`).

The extent from the column face equals `h_cap`, the §13.2.6 minimum. Skew or
re-entrant corners, and edge or corner columns with slab openings, return a
design that is not ok: the footprint is not modelled there.

# Reference
- ACI 318-11 §13.2.6 (corpus: aci-318-11, page 244), §11.11.1.2 (page 200)
"""
function design_shear_cap(col, Vu::Force, Mub::Moment, fc::Pressure, d::Length, h::Length;
                          Muy::Union{Moment, Nothing} = nothing,
                          λ::Float64 = 1.0, φ::Float64 = 0.75,
                          max_projection::Union{Length, Nothing} = nothing,
                          h_increment::Length = 0.25u"inch",
                          punch_kwargs = (;))
    max_proj = something(max_projection, h)
    _enlarged_support_supported(col, punch_kwargs) ||
        return ShearCapDesign(required = true, ratio = Inf, ok = false, governing = :unsupported)
    edge_par = get(punch_kwargs, :free_edge_parallel, nothing)
    kw = (; λ = λ, φ_shear = φ, Muy = Muy, punch_kwargs...)

    function attempt(h_cap)
        face = check_punching_for_column(col, Vu, Mub, d + h_cap, h + h_cap, fc; kw...)
        fp = _support_footprint(col, h_cap; free_edge_parallel = edge_par)
        edge = check_punching_for_column(_support_proxy(col, fp), Vu, Mub, d, h, fc;
                                         kw..., centroid_dims = fp.centroid_dims)
        ratio = max(face.ratio, edge.ratio)
        return ShearCapDesign(
            required = true,
            h_cap = uconvert(u"inch", h_cap),
            extent = uconvert(u"inch", h_cap),
            d_eff = uconvert(u"inch", d + h_cap),
            b0_cap = uconvert(u"inch", edge.b0),
            c1_cap = uconvert(u"inch", fp.c1),
            c2_cap = uconvert(u"inch", fp.c2),
            ratio = ratio,
            ok = ratio <= 1.0,
            governing = face.ratio >= edge.ratio ? :column_face : :cap_edge,
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
    check_punching_with_shear_cap(cap::ShearCapDesign) -> NamedTuple

`(ok, ratio, message)` of a designed shear cap.
"""
function check_punching_with_shear_cap(cap::ShearCapDesign)
    if !cap.required
        return (ok=false, ratio=Inf, message="Shear cap not designed")
    end
    msg = cap.ok ? "OK (shear cap h=$(cap.h_cap)): ratio=$(round(cap.ratio, digits=3))" :
                   "NG (shear cap h=$(cap.h_cap), $(cap.governing)): ratio=$(round(cap.ratio, digits=3)) > 1.0"
    return (ok=cap.ok, ratio=cap.ratio, message=msg)
end
