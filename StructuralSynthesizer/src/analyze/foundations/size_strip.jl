"""Return `:x` or `:y` for a unique longer plan span.

When Δx and Δy are equal within SI ulp (`1e-12` m, not a construction
tolerance) this throws — callers must size both axes via
`_support_strip_axes`. Named `c1` is ∥ global X (deci-311bd2d0).
"""
function _support_strip_axis(struc, supp_indices::Vector{Int})
    axes = _support_strip_axes(struc, supp_indices)
    length(axes) == 1 && return axes[1]
    throw(ArgumentError(
        "support Δx=Δy within SI ulp; size both axes via _support_strip_axes " *
        "(do not default to :x)"))
end

"""Plan spans Δx, Δy in metres from support vertices."""
function _support_span_xy_m(struc, supp_indices::Vector{Int})
    skel = struc.skeleton
    pts = [skel.vertices[struc.supports[i].vertex_idx] for i in supp_indices]
    length(pts) <= 1 && return (0.0, 0.0)
    xs = [ustrip(u"m", Meshes.coords(p).x) for p in pts]
    ys = [ustrip(u"m", Meshes.coords(p).y) for p in pts]
    return (maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
end

"""True when Δx and Δy match within a tight SI/ulp length, not construction.

`1e-12` m is on the order of Float64 metre round-trip residue, not a
1-inch / 1-ft layout tolerance.
"""
_strip_spans_tied(Δx::Float64, Δy::Float64) =
    abs(Δx - Δy) <= max(1e-12, 4 * max(eps(Δx), eps(Δy), eps(1.0)))

"""Axes to size for a strip: `[:x]`, `[:y]`, or `[:x, :y]` when Δx=Δy.

Named `c1` remains ∥ global X; `:y` remaps across/along (deci-311bd2d0).
Coincident supports (both spans ~0) stay `[:x]`.
"""
function _support_strip_axes(struc, supp_indices::Vector{Int})
    Δx, Δy = _support_span_xy_m(struc, supp_indices)
    if _strip_spans_tied(Δx, Δy)
        abs(Δx) <= 1e-12 && abs(Δy) <= 1e-12 && return Symbol[:x]
        return Symbol[:x, :y]
    end
    return Δx > Δy ? Symbol[:x] : Symbol[:y]
end

"""Keep the worse of two (or more) strip designs: higher utilization, then D, then volume."""
function _governing_strip_result(results)
    length(results) == 1 && return results[1]
    foldl(results) do a, b
        ua = StructuralSizer.utilization(a)
        ub = StructuralSizer.utilization(b)
        ua > ub + 1e-12 && return a
        ub > ua + 1e-12 && return b
        da = ustrip(u"m", StructuralSizer.footing_depth(a))
        db = ustrip(u"m", StructuralSizer.footing_depth(b))
        da > db + 1e-12 && return a
        db > da + 1e-12 && return b
        va = ustrip(u"m^3", StructuralSizer.concrete_volume(a))
        vb = ustrip(u"m^3", StructuralSizer.concrete_volume(b))
        return va ≥ vb ? a : b
    end
end

"""Extract support positions along `axis` (`:x` or `:y`) for strip layout."""
function _support_positions_along_axis(struc, supp_indices::Vector{Int}, axis::Symbol)
    skel = struc.skeleton
    pts = [skel.vertices[struc.supports[i].vertex_idx] for i in supp_indices]
    if length(pts) <= 1
        return [0.0u"m"]
    end
    xs = [ustrip(u"m", Meshes.coords(p).x) for p in pts]
    ys = [ustrip(u"m", Meshes.coords(p).y) for p in pts]
    axis === :x || axis === :y ||
        throw(ArgumentError("strip axis must be :x or :y; got :$axis"))
    coords = axis === :x ? xs : ys
    origin = minimum(coords)
    return [(c - origin) * u"m" for c in coords]
end

"""Extract support positions along the unique longer axis (errors if Δx=Δy)."""
function _support_positions_along_axis(struc, supp_indices::Vector{Int})
    axes = _support_strip_axes(struc, supp_indices)
    length(axes) == 1 || throw(ArgumentError(
        "support Δx=Δy within SI ulp; pass strip_axis explicitly (do not default to :x)"))
    return _support_positions_along_axis(struc, supp_indices, axes[1])
end

