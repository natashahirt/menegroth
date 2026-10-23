# ==============================================================================
# Per-Station Composite Flexural Check — AISC 360-16 §I3.1a / §I3.2a / §I3.2b
# ==============================================================================
#
# The scalar composite path (`get_b_eff`, `get_ϕMn_composite`, `get_Mn_negative`)
# collapses a beam to ONE effective width and ONE moment. On irregular / skew /
# merged bays the §I3.1a effective width varies along the span, and under
# continuity the demand changes sign (sagging in the span, hogging at interior
# supports). This module evaluates the design check PER STATION `s ∈ [0, 1]`
# (normalized position from the start node) on the EXACT per-segment fields and
# locates the governing station by a grid-independent 1-D optimization.
#
# What is exact here:
#   • b_eff(s)   — piecewise-linear in `s`; §I3.1a caps applied PER SIDE at each
#                  station (one-eighth span cap + the local per-side tributary
#                  extent, which already embeds caps (b)/(c)). See §I3.1a text
#                  reproduced in effective_width.jl.
#   • DCR(s)     — the demand field M(s) and b_eff(s) are supplied as exact
#                  closed-form callables by the caller; ϕMn(b_eff(s)) is the
#                  nonlinear §I3.2a plastic-PNA capacity (no closed-form argmax),
#                  so the governing station is found numerically but on the exact
#                  fields — NOT by sampling a fixed grid.
#
# Reduction guarantee: for a constant b_eff and a parabolic (simply-supported)
# demand the governing station is midspan and every quantity is byte-identical
# to the scalar `get_b_eff` / `get_ϕMn_composite` path (see the reduction tests).
#
# Sign dispatch (continuity):
#   • M(s) ≥ 0 (sagging) → §I3.2a plastic positive composite, `get_ϕMn_composite`.
#   • M(s) < 0 (hogging) → §I3.2b: bare steel OR composite-with-slab-rebar,
#     `get_Mn_negative`, using the developed slab reinforcement `Asr` within
#     b_eff(s).
#
# Citations: AISC 360-16 §I3.1a (corpus: aisc-360-16, PDF p. 150), §I3.2a and
# §I3.2b (corpus: aisc-360-16, PDF p. 151). Verbatim text in effective_width.jl
# and flexure.jl.
# ==============================================================================

# ------------------------------------------------------------------------------
# Per-side tributary extent profile
# ------------------------------------------------------------------------------

"""
    SideExtentProfile

Piecewise-linear per-side tributary perpendicular extent `d(s)` along a composite
beam, with `s ∈ [0, 1]` the normalized position from the start node.

`extents_m` are the §I3.1a per-side governing distances in **meters**: for an
interior side `d = ½·(distance to the adjacent beam centerline)` (§I3.1a(b));
for a slab-edge side `d = distance to the slab edge` (§I3.1a(c)). Caps (b)/(c)
are therefore already embedded in `d` by the building's tributary geometry — only
the §I3.1a(a) `L/8` cap is applied on top (see [`b_eff_at_station`](@ref)).

# Fields
- `positions::Vector{Float64}`: breakpoints in `[0, 1]`, sorted, `positions[1] == 0`,
  `positions[end] == 1`.
- `extents_m::Vector{Float64}`: per-side extent `d` (m) at each breakpoint; linear
  between breakpoints; same length as `positions`.
"""
struct SideExtentProfile
    positions::Vector{Float64}
    extents_m::Vector{Float64}

    function SideExtentProfile(positions::Vector{Float64}, extents_m::Vector{Float64})
        n = length(positions)
        n >= 2 || throw(ArgumentError("SideExtentProfile requires ≥ 2 positions (got $n)"))
        length(extents_m) == n || throw(ArgumentError(
            "SideExtentProfile positions ($n) and extents ($(length(extents_m))) must match"))
        isapprox(positions[1], 0.0; atol = 1e-9) || throw(ArgumentError(
            "SideExtentProfile positions must start at 0.0 (got $(positions[1]))"))
        isapprox(positions[end], 1.0; atol = 1e-9) || throw(ArgumentError(
            "SideExtentProfile positions must end at 1.0 (got $(positions[end]))"))
        issorted(positions) || throw(ArgumentError(
            "SideExtentProfile positions must be nondecreasing"))
        all(d -> d >= 0.0, extents_m) || throw(ArgumentError(
            "SideExtentProfile extents must be non-negative"))
        return new(positions, extents_m)
    end
end

"""Constant per-side extent `d_m` (meters) spanning the whole beam."""
SideExtentProfile(d_m::Real) = SideExtentProfile([0.0, 1.0], Float64[d_m, d_m])

"""Per-side extent `d(s)` (meters) at normalized station `s`, clamped to `[0, 1]`
and linearly interpolated between breakpoints."""
function _sample_extent(p::SideExtentProfile, s::Real)
    sc = clamp(Float64(s), 0.0, 1.0)
    pos, ext = p.positions, p.extents_m
    sc <= pos[1] && return ext[1]
    sc >= pos[end] && return ext[end]
    i = clamp(searchsortedlast(pos, sc), 1, length(pos) - 1)
    p0, p1 = pos[i], pos[i + 1]
    p1 == p0 && return ext[i + 1]
    return ext[i] + (ext[i + 1] - ext[i]) * (sc - p0) / (p1 - p0)
end

# ------------------------------------------------------------------------------
# b_eff(s) — AISC 360-16 §I3.1a per station
# ------------------------------------------------------------------------------

"""
    b_eff_at_station(slab, L_beam, s; left=nothing, right=nothing) -> Length

Effective slab width at normalized station `s` per AISC 360-16 §I3.1a (corpus:
aisc-360-16, PDF p. 150): the sum over the two sides of the beam centerline of
the per-side effective width, each capped at `L/8` (§I3.1a(a)).

Each side's governing distance comes from its [`SideExtentProfile`](@ref) (the
local per-side tributary extent `d(s)`, which already embeds caps (b)/(c)); a
side passed as `nothing` falls back to the slab's scalar `beam_spacing_*` /
`edge_dist_*` fields. The per-side cap is applied through the SAME
[`_effective_half_width`](@ref) used by the scalar `get_b_eff`, with
`beam_spacing = 2·d(s)`, so that a constant profile with `d = spacing/2`
reduces BYTE-IDENTICALLY to the scalar path.
"""
function b_eff_at_station(slab::AbstractSlabOnBeam, L_beam, s::Real;
                          left::Union{SideExtentProfile, Nothing} = nothing,
                          right::Union{SideExtentProfile, Nothing} = nothing)
    bl = left === nothing ?
        _effective_half_width(L_beam, slab.beam_spacing_left, slab.edge_dist_left) :
        _effective_half_width(L_beam, 2 * _sample_extent(left, s) * u"m", nothing)
    br = right === nothing ?
        _effective_half_width(L_beam, slab.beam_spacing_right, slab.edge_dist_right) :
        _effective_half_width(L_beam, 2 * _sample_extent(right, s) * u"m", nothing)
    return bl + br
end

"""
    beff_breakpoints(left, right) -> Vector{Float64}

Union of the per-side profiles' breakpoints (plus the span ends `0` and `1`).
These are the positions where `b_eff(s)` can change slope; the governing-station
optimizer treats them as exact segment boundaries. (The additional kinks where a
side's extent crosses the `L/8` cap are handled by the per-segment search, which
brackets interior extrema — they need not be enumerated analytically.)
"""
function beff_breakpoints(left::Union{SideExtentProfile, Nothing},
                          right::Union{SideExtentProfile, Nothing})
    pts = Float64[0.0, 1.0]
    left  === nothing || append!(pts, left.positions)
    right === nothing || append!(pts, right.positions)
    return _unique_sorted(pts)
end

"""Sorted unique values with a small absolute tolerance (collapses near-duplicates)."""
function _unique_sorted(xs::AbstractVector{Float64}; atol::Float64 = 1e-9)
    ys = sort(collect(xs))
    out = Float64[]
    for y in ys
        (isempty(out) || abs(y - out[end]) > atol) && push!(out, y)
    end
    return out
end

# ------------------------------------------------------------------------------
# ϕMn(s) — sign-dispatched composite capacity (AISC 360-16 §I3.2a / §I3.2b)
# ------------------------------------------------------------------------------

"""
    phiMn_at_station(section, material, slab, b_eff, ΣQn, sagging;
                     Asr=0.0u"mm^2", Fysr=0.0u"MPa", d_rebar=0.0u"m", ϕ=0.9)
        -> NamedTuple(:ϕMn, :Mn, :sense)

Design flexural strength at a station, dispatched by the sign of the demand:

  • `sagging == true`  → AISC 360-16 §I3.2a (corpus: aisc-360-16, PDF p. 151):
    plastic positive composite strength `ϕ·Mn` from [`get_ϕMn_composite`] with
    this station's `b_eff` and shear transfer `ΣQn`.
  • `sagging == false` → AISC 360-16 §I3.2b (corpus: aisc-360-16, PDF p. 151):
    the available NEGATIVE flexural strength — bare steel `Mp` (Chapter F) when
    `Asr ≈ 0`, else the plastic composite-with-slab-reinforcement strength from
    [`get_Mn_negative`], using the developed slab reinforcement `Asr` within
    `b_eff` and its yield `Fysr`. `d_rebar` is the rebar centroid above the top
    of steel. The resistance factor `ϕb = 0.90` is per §I3.2b.

`sense` is `:positive` or `:negative`.
"""
function phiMn_at_station(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                          b_eff, ΣQn, sagging::Bool;
                          Asr = 0.0u"mm^2", Fysr = 0.0u"MPa",
                          d_rebar = 0.0u"m", ϕ = 0.9)
    if sagging
        r = get_ϕMn_composite(section, material, slab, b_eff, ΣQn; ϕ = ϕ)
        return (; ϕMn = r.ϕMn, Mn = r.Mn, sense = :positive)
    else
        # §I3.2b — negative flexural strength (plastic composite w/ slab rebar,
        # or bare-steel Mp when no developed parallel reinforcement is present).
        Mn = get_Mn_negative(section, material, Asr, Fysr; d_rebar = d_rebar)
        return (; ϕMn = ϕ * Mn, Mn = Mn, sense = :negative)
    end
end

# ------------------------------------------------------------------------------
# Grid-independent governing-station search
# ------------------------------------------------------------------------------

"""
    _golden_section_max(f, a, b; tol=1e-10, maxit=200) -> (x, f(x))

Golden-section search for the maximum of a unimodal `f` on `[a, b]`.
"""
function _golden_section_max(f, a::Float64, b::Float64; tol::Float64 = 1e-10, maxit::Int = 200)
    invφ = (sqrt(5.0) - 1.0) / 2.0        # 0.618…
    c = b - invφ * (b - a)
    d = a + invφ * (b - a)
    fc = f(c)
    fd = f(d)
    for _ in 1:maxit
        if fc < fd
            a = c; c = d; fc = fd
            d = a + invφ * (b - a); fd = f(d)
        else
            b = d; d = c; fd = fc
            c = b - invφ * (b - a); fc = f(c)
        end
        (b - a) < tol && break
    end
    xm = (a + b) / 2
    return (xm, f(xm))
end

"""
    governing_station(dcr_of_s, breakpoints; n_bracket=9, tol=1e-10)
        -> (s_star, dcr_star)

Locate the station `s* ∈ [0, 1]` that MAXIMIZES `dcr_of_s(s)` (a `Float64`),
grid-independently.

`breakpoints` are the exact segment boundaries of the underlying fields (union of
the demand and `b_eff` breakpoints, including `0` and `1`). Between consecutive
breakpoints `dcr_of_s` is smooth, so its maximum on each segment is found by
bracketing with `n_bracket` interior samples and refining the best bracket with a
golden-section search. The samples only BRACKET the extremum — the returned
`s*` is the continuously-refined optimum, so refining `breakpoints` (adding
stations) does not change the answer. This realizes the "local 1-D optimization
on the exact per-segment fields (grid-independent)" of the design: `Mn(b_eff)` is
nonlinear (plastic PNA solve) so `DCR(s)` has no closed-form argmax, but both
`M(s)` and `b_eff(s)` are exact per segment.
"""
function governing_station(dcr_of_s, breakpoints::AbstractVector{Float64};
                           n_bracket::Int = 9, tol::Float64 = 1e-10)
    bp = _unique_sorted(collect(Float64, breakpoints))
    (length(bp) >= 2) || (bp = [0.0, 1.0])

    s_star = bp[1]
    dcr_star = dcr_of_s(bp[1])

    @inbounds for k in 1:(length(bp) - 1)
        a, b = bp[k], bp[k + 1]
        (b - a) < tol && continue

        # Sample the segment (endpoints included) to bracket the extremum.
        best_j, best_val, best_s = 1, -Inf, a
        xs = range(a, b; length = max(n_bracket, 3))
        for (j, s) in enumerate(xs)
            v = dcr_of_s(s)
            if v > best_val
                best_val, best_j, best_s = v, j, s
            end
        end

        # Refine the bracket [xs[j-1], xs[j+1]] around the best sample.
        lo = xs[max(best_j - 1, 1)]
        hi = xs[min(best_j + 1, length(xs))]
        if hi - lo > tol
            s_ref, v_ref = _golden_section_max(dcr_of_s, Float64(lo), Float64(hi); tol = tol)
            if v_ref > best_val
                best_val, best_s = v_ref, s_ref
            end
        end

        if best_val > dcr_star
            dcr_star, s_star = best_val, best_s
        end
    end

    # Always consider the final breakpoint explicitly.
    v_end = dcr_of_s(bp[end])
    if v_end > dcr_star
        dcr_star, s_star = v_end, bp[end]
    end

    return (s_star, dcr_star)
end

# ------------------------------------------------------------------------------
# Assembled per-station composite DCR + governing-station check
# ------------------------------------------------------------------------------

"""
    composite_dcr_at_station(section, material, slab, L_beam, s, M_s, ΣQn;
        left=nothing, right=nothing, Asr=0.0u"mm^2", Fysr=0.0u"MPa",
        d_rebar=0.0u"m", ϕ=0.9) -> NamedTuple

Demand-to-capacity ratio at a single station. `M_s` is the SIGNED demand moment
at `s` (sagging positive, hogging negative). Returns `b_eff`, `ϕMn`, `sense`, and
`dcr = |M_s| / ϕMn` (dimensionless). A non-positive `ϕMn` yields `dcr = Inf`.
"""
function composite_dcr_at_station(section::ISymmSection, material,
                                  slab::AbstractSlabOnBeam, L_beam, s::Real, M_s, ΣQn;
                                  left::Union{SideExtentProfile, Nothing} = nothing,
                                  right::Union{SideExtentProfile, Nothing} = nothing,
                                  Asr = 0.0u"mm^2", Fysr = 0.0u"MPa",
                                  d_rebar = 0.0u"m", ϕ = 0.9)
    b_eff = b_eff_at_station(slab, L_beam, s; left = left, right = right)
    sagging = ustrip(u"N*m", uconvert(u"N*m", M_s)) >= 0.0
    cap = phiMn_at_station(section, material, slab, b_eff, ΣQn, sagging;
                           Asr = Asr, Fysr = Fysr, d_rebar = d_rebar, ϕ = ϕ)
    ϕMn_Nm = ustrip(u"N*m", uconvert(u"N*m", cap.ϕMn))
    M_Nm = abs(ustrip(u"N*m", uconvert(u"N*m", M_s)))
    dcr = ϕMn_Nm > 0.0 ? M_Nm / ϕMn_Nm : Inf
    return (; s = s, b_eff = b_eff, ϕMn = cap.ϕMn, Mn = cap.Mn, sense = cap.sense,
              M = M_s, dcr = dcr)
end

"""
    governing_composite_station(section, material, slab, L_beam, demand_of_s, ΣQn;
        left=nothing, right=nothing, Asr=0.0u"mm^2", Fysr=0.0u"MPa",
        d_rebar=0.0u"m", ϕ=0.9, extra_breakpoints=Float64[], n_bracket=9)
        -> NamedTuple

Governing (maximum-DCR) station for a composite beam under a continuity-correct,
sign-varying demand field.

`demand_of_s(s) -> Moment` is the EXACT signed demand at normalized station `s`
(sagging positive, hogging negative) — e.g. recovered from the FEM `TributaryLoad`
internal-force field. The governing station is found by [`governing_station`] over
the union of the `b_eff(s)` breakpoints and any `extra_breakpoints` the caller
supplies (the demand-field segment boundaries). Returns the full
[`composite_dcr_at_station`] record at `s*`, plus `s_star` and `dcr_max`.

Sign dispatch (§I3.2a vs §I3.2b) happens per station, so the governing check may
land at an interior support (hogging, §I3.2b) or in a span (sagging, §I3.2a),
whichever gives the larger DCR.
"""
function governing_composite_station(section::ISymmSection, material,
                                     slab::AbstractSlabOnBeam, L_beam, demand_of_s, ΣQn;
                                     left::Union{SideExtentProfile, Nothing} = nothing,
                                     right::Union{SideExtentProfile, Nothing} = nothing,
                                     Asr = 0.0u"mm^2", Fysr = 0.0u"MPa",
                                     d_rebar = 0.0u"m", ϕ = 0.9,
                                     extra_breakpoints::AbstractVector{Float64} = Float64[],
                                     n_bracket::Int = 9)
    dcr_of_s = s -> composite_dcr_at_station(section, material, slab, L_beam, s,
                                             demand_of_s(s), ΣQn;
                                             left = left, right = right,
                                             Asr = Asr, Fysr = Fysr,
                                             d_rebar = d_rebar, ϕ = ϕ).dcr

    bp = beff_breakpoints(left, right)
    isempty(extra_breakpoints) || (bp = _unique_sorted(vcat(bp, collect(Float64, extra_breakpoints))))

    s_star, dcr_max = governing_station(dcr_of_s, bp; n_bracket = n_bracket)
    rec = composite_dcr_at_station(section, material, slab, L_beam, s_star,
                                   demand_of_s(s_star), ΣQn;
                                   left = left, right = right, Asr = Asr, Fysr = Fysr,
                                   d_rebar = d_rebar, ϕ = ϕ)
    return (; s_star = s_star, dcr_max = dcr_max, rec...)
end
