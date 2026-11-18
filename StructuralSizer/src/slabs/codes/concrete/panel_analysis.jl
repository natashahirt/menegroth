# =============================================================================
# Solid-panel analysis — coefficients, or the existing shell
# =============================================================================
#
# A regular one-way bay may use the ACI 318-11 §8.3.3 coefficients. Any other
# panel uses the flat-plate shell with per-element (area) design. That shell
# already meshes an arbitrary polygon and sizes every element, which is what
# a skewed, trapezoidal, or otherwise non-rectangular panel needs.
#
# ACI 318-11 §8.3.1 requires elastic analysis except where §8.3.3 (or §8.4)
# applies (corpus: aci-318-11, pages 112–113). §8.3.3 is one-way only.

"""Coefficient design of a continuous one-way member. Not a shell."""
struct OneWayMomentCoefficients end

"""
    panel_shell() -> FEA

The existing flat-plate shell, set up for a panel that is not a regular
rectangle.

`design_approach=:area` sizes each element from its own moment tensor, so
the reinforcement follows the polygon instead of a column strip.
`moment_transform=:wood_armer` keeps the twisting moment. `pattern_mode=
:fea_resolve` re-solves the shell for each live-load pattern instead of
scaling it by a one-dimensional frame ratio.

The shell is supported on columns, the same model the two-way slab already
uses. A courtyard hole is still one boundary loop in that mesher.
"""
function panel_shell()
    # ACI 318-11 §8.3.1 — elastic analysis where §8.3.3 does not apply
    # (corpus: aci-318-11, pages 112–113). The area shell is that analysis
    # and already accepts a non-rectangular plan.
    return FEA(
        design_approach = :area,
        moment_transform = :wood_armer,
        pattern_loading = true,
        pattern_mode = :fea_resolve,
    )
end

"""
    is_rectangular_panel(pts) -> Bool

`pts` is a closed face as `(x, y)` pairs, one corner each, without repeating
the first point. A rectangle has four corners, perpendicular adjacent edges,
and equal opposite edges.
"""
function is_rectangular_panel(pts)
    n = length(pts)
    n == 4 || return false
    edges = ntuple(i -> (pts[mod1(i + 1, n)][1] - pts[i][1],
                         pts[mod1(i + 1, n)][2] - pts[i][2]), n)
    lengths = ntuple(i -> hypot(edges[i]...), n)
    any(L -> L <= 1e-9, lengths) && return false
    for i in 1:n
        j = mod1(i + 1, n)
        dot = edges[i][1] * edges[j][1] + edges[i][2] * edges[j][2]
        abs(dot) / (lengths[i] * lengths[j]) > 1e-3 && return false
    end
    opposite = max(abs(lengths[1] - lengths[3]) / lengths[1],
                   abs(lengths[2] - lengths[4]) / lengths[2])
    return opposite <= 1e-3
end

"""
    _spans_within_20_percent(spans) -> Bool

ACI 318-11 §8.3.3(b) (corpus: aci-318-11, page 112): the larger of two
adjacent spans is not greater than the shorter by more than 20 percent.
Exactly 20 percent is permitted.
"""
function _spans_within_20_percent(spans)
    length(spans) < 2 && return false
    for i in 1:(length(spans) - 1)
        a, b = spans[i], spans[i + 1]
        short, long = min(a, b), max(a, b)
        short > zero(short) || return false
        (long - short) / short > 0.20 + 1e-8 && return false
    end
    return true
end

"""
    coefficients_permitted(; n_spans, clear_spans, live, dead,
                            rectangular, uniform, prismatic) -> (ok, reasons)

ACI 318-11 §8.3.3(a)–(e) (corpus: aci-318-11, page 112), plus a rectangle
check.

# ENGINEERING JUDGMENT
§8.3.3 writes every moment as `wu·ln²` for one clear span of a prismatic
member. It does not define `ln` on a non-rectangular face. A face that is
not a rectangle is sent to the shell. That is narrower than the sentence
of §8.3.3, and it is the general analysis §8.3.1 already requires.
"""
function coefficients_permitted(;
    n_spans::Int,
    clear_spans,
    live,
    dead,
    rectangular::Bool = true,
    uniform::Bool = true,
    prismatic::Bool = true,
)
    reasons = String[]
    # ACI 318-11 §8.3.3(a), page 112.
    n_spans >= 2 || push!(reasons, "§8.3.3(a): fewer than two spans")
    # ACI 318-11 §8.3.3(b), page 112.
    _spans_within_20_percent(clear_spans) ||
        push!(reasons, "§8.3.3(b): adjacent spans differ by more than 20 percent")
    # ACI 318-11 §8.3.3(c), page 112.
    uniform || push!(reasons, "§8.3.3(c): load is not uniform")
    # ACI 318-11 §8.3.3(d), page 112. Unfactored L and D.
    if !(dead > zero(dead))
        push!(reasons, "§8.3.3(d): dead load is not positive")
    elseif live / dead > 3.0 + 1e-8
        push!(reasons, "§8.3.3(d): unfactored live load exceeds three times dead load")
    end
    # ACI 318-11 §8.3.3(e), page 112.
    prismatic || push!(reasons, "§8.3.3(e): member is not prismatic")
    rectangular || push!(reasons,
        "face is not a rectangle, so there is no single clear span ln for §8.3.3")
    return isempty(reasons), reasons
end

"""
    select_panel_analysis(::OneWay; kwargs...) -> (method, reasons)
    select_panel_analysis(::TwoWay; kwargs...) -> (method, reasons)

`OneWayMomentCoefficients` when [`coefficients_permitted`](@ref) passes.
Otherwise [`panel_shell`](@ref). A two-way panel is never a §8.3.3 slab.
"""
function select_panel_analysis(::OneWay; kwargs...)
    ok, reasons = coefficients_permitted(; kwargs...)
    return ok ? (OneWayMomentCoefficients(), String[]) : (panel_shell(), reasons)
end

function select_panel_analysis(::TwoWay; kwargs...)
    return panel_shell(), String[
        "ACI 318-11 §8.3.3 is for one-way slabs. A two-way panel uses the shell.",
    ]
end

"""
    _slab_is_rectangular(struc, slab) -> Bool

Every cell face of `slab` is a rectangle. A missing face is not one.
"""
function _slab_is_rectangular(struc, slab)
    skel = struc.skeleton
    for ci in slab.cell_indices
        cell = struc.cells[ci]
        vis = skel.face_vertex_indices[cell.face_idx]
        pts = [_vertex_xy_m(skel, Int(vi)) for vi in vis]
        is_rectangular_panel(pts) || return false
    end
    return true
end

"""
    two_way_opening_needs_analysis(panel, openings; has_beams=false)
        -> (needs::Bool, reasons)

Whether an opening in a two-way panel requires the analysis of ACI 318-11
§13.4.1 instead of the §13.4.2 rules that skip it.

§13.4.2 (corpus: aci-318-11, page 248) is for slabs without beams:
- §13.4.2.1 any opening in the intersection of the middle strips, provided the
  reinforcement required for the panel without the opening is kept;
- §13.4.2.2 at most one-eighth of a column-strip width, in either span, where
  the column strips intersect;
- §13.4.2.3 at most one-quarter of the reinforcement in either strip where a
  column strip meets a middle strip.

The column-strip half-width is `min(0.25 l1, 0.25 l2)` (§13.2.1, page 244).

# ENGINEERING JUDGMENT
§13.4.2.2 and §13.4.2.3 limit interrupted reinforcement. With bars spaced
uniformly, that fraction is the fraction of the strip width the opening
covers, and that is what is tested. `l1` and `l2` are the panel side lengths.
The code's spans are centerline to centerline; the face outline is what this
check has.
"""
function two_way_opening_needs_analysis(panel, openings; has_beams::Bool = false)
    isempty(openings) && return (false, String[])
    if has_beams
        return (true, String[
            "ACI 318-11 §13.4.2 is for slabs without beams. §13.4.1 requires analysis (corpus: aci-318-11, page 248).",
        ])
    end
    if !is_rectangular_panel(panel)
        return (true, String[
            "ACI 318-11 §13.4.2 strip limits are for a panel bounded by column centerlines. A non-rectangular panel is analyzed under §13.4.1 (corpus: aci-318-11, page 248).",
        ])
    end
    o = panel[1]
    ex, ey = panel[2][1] - o[1], panel[2][2] - o[2]
    Lx = hypot(ex, ey)
    ux, uy = ex / Lx, ey / Lx
    nx, ny = -uy, ux
    along(p) = (p[1] - o[1]) * nx + (p[2] - o[2]) * ny
    if maximum(along(p) for p in panel) < 0
        nx, ny = -nx, -ny
    end
    loc(p) = ((p[1] - o[1]) * ux + (p[2] - o[2]) * uy,
              (p[1] - o[1]) * nx + (p[2] - o[2]) * ny)
    Ly = maximum(loc(p)[2] for p in panel)
    # ACI 318-11 §13.2.1 (corpus: aci-318-11, page 244): half-width on each
    # side of a column centerline. The full strip is twice that.
    w = 0.25 * min(Lx, Ly)
    col_width = 2w
    overlap(a0, a1, b0, b1) = max(0.0, min(a1, b1) - max(a0, b0))
    needs = false
    reasons = String[]
    for op in openings
        xs = [loc(p)[1] for p in op]
        ys = [loc(p)[2] for p in op]
        x0, x1 = minimum(xs), maximum(xs)
        y0, y1 = minimum(ys), maximum(ys)
        if x0 >= w - 1e-8 && x1 <= Lx - w + 1e-8 && y0 >= w - 1e-8 && y1 <= Ly - w + 1e-8
            # §13.4.2.1. The bar total is a detailing requirement, not a method change.
            continue
        end
        ix = overlap(x0, x1, 0.0, w) + overlap(x0, x1, Lx - w, Lx)
        iy = overlap(y0, y1, 0.0, w) + overlap(y0, y1, Ly - w, Ly)
        if ix > 1e-8 && iy > 1e-8
            if ix > col_width / 8 + 1e-8 || iy > col_width / 8 + 1e-8
                needs = true
                push!(reasons, "ACI 318-11 §13.4.2.2: an opening interrupts more than one-eighth of a column strip (corpus: aci-318-11, page 248).")
            end
        else
            mx = overlap(x0, x1, w, Lx - w)
            my = overlap(y0, y1, w, Ly - w)
            if ix > col_width / 4 + 1e-8 || iy > col_width / 4 + 1e-8 ||
                    mx > (Lx - col_width) / 4 + 1e-8 || my > (Ly - col_width) / 4 + 1e-8
                needs = true
                push!(reasons, "ACI 318-11 §13.4.2.3: an opening interrupts more than one-quarter of a column or middle strip (corpus: aci-318-11, page 248).")
            end
        end
    end
    return (needs, unique(reasons))
end

"""
    assign_panel_analysis!(floor, struc, slab, dead, live)

Choose the panel analysis and, when the slab has `design_details`, record
it as planned, not run: `analysis_status = :not_analyzed`, plus
`analysis_planned` and `analysis_reasons`.

The fields are not named `method_used`, so a building result does not
report a method that never solved anything.

This slab object is one panel, so it does not carry a continuous line of
spans. §8.3.3(a) therefore fails until a caller passes two or more clear
spans to [`select_panel_analysis`](@ref).
"""
function assign_panel_analysis!(floor::Union{OneWay, TwoWay}, struc, slab, dead, live)
    rectangular = try
        _slab_is_rectangular(struc, slab)
    catch
        false
    end
    method, reasons = select_panel_analysis(floor;
        n_spans = 1,
        clear_spans = [slab.spans.primary],
        live = live,
        dead = dead,
        rectangular = rectangular,
    )
    openings = slab_opening_loops(struc, slab)
    if !isempty(openings)
        if floor isa TwoWay
            for ci in slab.cell_indices
                face = struc.cells[ci].face_idx
                pts = [_vertex_xy_m(struc.skeleton, Int(vi))
                       for vi in struc.skeleton.face_vertex_indices[face]]
                holes = slab_opening_loops(struc, slab; face_idx = face)
                needs, rs = two_way_opening_needs_analysis(pts, holes; has_beams = true)
                needs || continue
                method = panel_shell()
                append!(reasons, rs)
            end
        else
            # ENGINEERING JUDGMENT: §8.3.3 has no opening rule, and §13.4 is a
            # two-way provision. An opening sends the one-way panel to analysis.
            method = panel_shell()
            push!(reasons, "An opening has no §8.3.3 coefficient. The panel is analyzed.")
        end
    end
    if hasproperty(slab, :design_details)
        existing = slab.design_details
        already = existing !== nothing && hasproperty(existing, :column_results)
        if !already
            planned = (
                analysis_status = :not_analyzed,
                analysis_planned = method,
                analysis_reasons = reasons,
            )
            slab.design_details = existing isa NamedTuple ? merge(existing, planned) : planned
        end
    end
    return method, reasons
end

# =============================================================================
# ACI 318-11 §8.3.3 moments and shears (corpus: aci-318-11, page 113)
# =============================================================================
#
# `wu` is the factored uniform load. For a beam it is force per length and
# the results are a moment and a shear. For a slab strip it is force per
# area and the results are a moment and a shear per unit width. `ln` is the
# clear span. For a negative moment, pass the average of the adjacent clear
# spans as `ln_neg` (§8.3.3, page 112).

"""
    approximate_one_way_moments(wu, ln; span, discontinuous, n_spans,
                                 support_face, ln_neg, short_slab)

Moments and shears from ACI 318-11 §8.3.3 (corpus: aci-318-11, page 113).

# Arguments
- `span`: `:end` or `:interior`
- `discontinuous`: restraint of the discontinuous end, `:unrestrained`,
  `:spandrel`, or `:column`. Ignored for an interior span.
- `n_spans`: two, or more than two. Sets the first-interior negative moment.
- `support_face`: `:first_interior` or `:other_interior`
- `ln_neg`: clear span used in the negative-moment coefficients. Defaults
  to `ln`. Pass the average of the adjacent clear spans.
- `short_slab`: `true` when every span is at most 10 ft. Negative moments
  at the faces of all supports are then `wu·ln²/12`.

# Returns
`(M_pos, M_neg_exterior, M_neg_interior, V_exterior, V_first_interior)`
"""
function approximate_one_way_moments(wu, ln;
                                    span::Symbol,
                                    discontinuous::Symbol = :unrestrained,
                                    n_spans::Int = 2,
                                    support_face::Symbol = :first_interior,
                                    ln_neg = ln,
                                    short_slab::Bool = false)
    span in (:end, :interior) ||
        throw(ArgumentError("span must be :end or :interior, got :$span"))
    discontinuous in (:unrestrained, :spandrel, :column) ||
        throw(ArgumentError("discontinuous must be :unrestrained, :spandrel, or :column"))
    n_spans >= 2 ||
        throw(ArgumentError("§8.3.3 requires two or more spans, got $n_spans"))
    support_face in (:first_interior, :other_interior) ||
        throw(ArgumentError("support_face must be :first_interior or :other_interior"))

    # Positive moment. ACI 318-11 §8.3.3, page 113.
    M_pos = if span === :interior
        wu * ln^2 / 16
    elseif discontinuous === :unrestrained
        wu * ln^2 / 11
    else
        # Discontinuous end integral with the support.
        wu * ln^2 / 14
    end

    # Negative moment at the interior face of the exterior support.
    # Zero when that end is not built integrally with the support, and on
    # an interior span (both ends are interior supports).
    M_neg_exterior = if span === :interior || discontinuous === :unrestrained
        zero(wu * ln_neg^2)
    elseif short_slab
        wu * ln_neg^2 / 12
    elseif discontinuous === :spandrel
        wu * ln_neg^2 / 24
    else
        wu * ln_neg^2 / 16
    end

    # Negative moment at an interior support face.
    M_neg_interior = if short_slab
        wu * ln_neg^2 / 12
    elseif support_face === :other_interior
        wu * ln_neg^2 / 11
    elseif n_spans == 2
        wu * ln_neg^2 / 9
    else
        wu * ln_neg^2 / 10
    end

    # Shear at the face of a support. The 1.15 factor is only the end
    # member at the first interior support.
    V_other = wu * ln / 2
    V_first = span === :end ? 1.15 * V_other : V_other

    return (
        M_pos = M_pos,
        M_neg_exterior = M_neg_exterior,
        M_neg_interior = M_neg_interior,
        V_exterior = V_other,
        V_first_interior = V_first,
    )
end

"""
Shrinkage and temperature ratio of a slab, ACI 318-11 §7.12.2.1
(corpus: aci-318-11, page 106).

Grade 40 and Grade 50 use 0.0020. Grade 60 uses 0.0018. Above 60 ksi the
ratio is `0.0018 × 60 ksi / fy`, and not less than 0.0014. A yield strength
below 60 ksi that is not Grade 40 or 50 still uses 0.0020, the same reading
already used for footings.
"""
function shrinkage_temperature_ratio(fy)
    fy_psi = ustrip(u"psi", fy)
    # ACI 318-11 §7.12.2.1(a)–(c), page 106.
    return fy_psi < 60_000.0 ? 0.0020 :
           fy_psi == 60_000.0 ? 0.0018 :
           max(0.0014, 0.0018 * 60_000.0 / fy_psi)
end

"""
    elastic_strip_moments(wu, spans) -> (M_pos, M_neg)

Sagging and hogging moments, per unit width, of a prismatic strip under a
uniform pressure. Both are positive.

ACI 318-11 §8.3.1 (corpus: aci-318-11, page 112) requires elastic analysis
where §8.3.3 does not apply. The support moments come from the three-moment
equation. That equation is beam theory, not an ACI coefficient.

# ENGINEERING JUDGMENT
The outer ends are pinned. This strip does not include the torsional
stiffness of the ribs it lands on.
"""
function elastic_strip_moments(wu, spans)
    L = collect(spans)
    n = length(L)
    n >= 1 || throw(ArgumentError("an elastic strip needs a span"))
    for (i, s) in enumerate(L)
        s > zero(s) || throw(ArgumentError("span $i is not positive, got $s"))
    end
    wu > zero(wu) || throw(ArgumentError("the strip pressure is not positive, got $wu"))
    if n == 1
        return (M_pos = wu * L[1]^2 / 8, M_neg = zero(wu * L[1]^2))
    end
    # Lengths in metres, pressure in N/m². A unit-width strip then has moments
    # in N·m per metre of width, which is a number of newtons.
    Lm = [ustrip(u"m", s) for s in L]
    w = ustrip(u"N/m^2", wu)
    M_pos, M_neg = _three_moment_strip(fill(w, n), Lm)
    unit = wu * L[1]^2 / (w * Lm[1]^2)
    return (M_pos = M_pos * unit, M_neg = M_neg * unit)
end

"""
    patterned_strip_moments(wD, wL, spans) -> (M_pos, M_neg)

[`elastic_strip_moments`](@ref) enveloped over live-load arrangements.

ACI 318-11 §8.11.2 (corpus: aci-318-11, pages 118–119) permits the live load
to be limited to combinations of (a) factored dead load on all spans with full
factored live load on two adjacent spans, and (b) factored dead load on all
spans with full factored live load on alternate spans. Both are enveloped
here, with full live load on every span as well. `wD` and `wL` are the
factored dead and live pressures.
"""
function patterned_strip_moments(wD, wL, spans)
    L = collect(spans)
    n = length(L)
    n >= 1 || throw(ArgumentError("an elastic strip needs a span"))
    for (i, s) in enumerate(L)
        s > zero(s) || throw(ArgumentError("span $i is not positive, got $s"))
    end
    wD > zero(wD) || throw(ArgumentError("the factored dead pressure is not positive, got $wD"))
    wL >= zero(wL) || throw(ArgumentError("the factored live pressure is negative, got $wL"))
    n == 1 && return elastic_strip_moments(wD + wL, L)
    Lm = [ustrip(u"m", s) for s in L]
    d = ustrip(u"N/m^2", wD)
    l = ustrip(u"N/m^2", wL)
    arrangements = Vector{Vector{Bool}}()
    push!(arrangements, fill(true, n))
    push!(arrangements, [isodd(i) for i in 1:n])
    push!(arrangements, [iseven(i) for i in 1:n])
    for i in 1:(n - 1)
        push!(arrangements, [j == i || j == i + 1 for j in 1:n])
    end
    M_pos = 0.0
    M_neg = 0.0
    for loaded in arrangements
        p, q = _three_moment_strip([d + (on ? l : 0.0) for on in loaded], Lm)
        M_pos = max(M_pos, p)
        M_neg = max(M_neg, q)
    end
    w = wD + wL
    unit = w * L[1]^2 / (ustrip(u"N/m^2", w) * Lm[1]^2)
    return (M_pos = M_pos * unit, M_neg = M_neg * unit)
end

"""
Peak sagging and hogging moments (N·m per metre) of a continuous strip with
pinned outer ends, from the three-moment equation with pressure `w[i]` (N/m²)
on span `i` of `Lm[i]` metres. Both are positive.
"""
function _three_moment_strip(w::Vector{Float64}, Lm::Vector{Float64})
    n = length(Lm)
    m = n - 1
    diag = Vector{Float64}(undef, m)
    upper = Vector{Float64}(undef, m)
    rhs = Vector{Float64}(undef, m)
    for i in 1:m
        Li, Lj = Lm[i], Lm[i + 1]
        diag[i] = 2 * (Li + Lj)
        upper[i] = i == m ? 0.0 : Lj
        rhs[i] = -0.25 * (w[i] * Li^3 + w[i + 1] * Lj^3)
    end
    for i in 2:m
        t = Lm[i] / diag[i - 1]
        diag[i] -= t * upper[i - 1]
        rhs[i] -= t * rhs[i - 1]
    end
    support = zeros(n + 1)
    support[n] = rhs[m] / diag[m]
    for i in (m - 1):-1:1
        support[i + 1] = (rhs[i] - upper[i] * support[i + 2]) / diag[i]
    end

    M_pos = 0.0
    for i in 1:n
        ML, MR = support[i], support[i + 1]
        wL2 = w[i] * Lm[i]^2
        ξ = 0.5 - (ML - MR) / wL2
        peak = if 0.0 < ξ < 1.0
            ML * (1 - ξ) + MR * ξ + 0.5 * wL2 * ξ * (1 - ξ)
        else
            max(ML, MR)
        end
        M_pos = max(M_pos, peak)
    end
    M_neg = maximum(-s for s in support)
    return max(M_pos, 0.0), max(M_neg, 0.0)
end

"""One topping strip. The area is at least §7.12. `max_spacing` is the caller's limit."""
function _topping_strip(location::Symbol, m_per_width, b, d, h, fc, fy; max_spacing)
    # ACI 318-11 §7.12.2.1, page 106. Area of the  unit strip.
    As_temp = shrinkage_temperature_ratio(fy) * b * h
    Mu = m_per_width * b
    As_req = Mu > zero(Mu) ?
        required_reinforcement(Mu, b, d, fc, fy; εt_min = tension_controlled_strain(fy)) :
        zero(As_temp)
    if !isfinite(ustrip(u"m^2", As_req))
        return StripReinforcement(location, to_newton_meters(Mu) * u"N*m",
            Inf * u"m^2", uconvert(u"m^2", As_temp), Inf * u"m^2",
            0, 0.0u"m", 0, false)
    end
    As = max(As_req, As_temp)
    bars = select_bars(As, b; max_spacing = max_spacing)
    return StripReinforcement(location, to_newton_meters(Mu) * u"N*m",
        uconvert(u"m^2", As_req), uconvert(u"m^2", As_temp),
        uconvert(u"m^2", bars.As_provided), bars.bar_size,
        uconvert(u"m", bars.spacing), bars.n_bars, true)
end

"""
    one_way_topping_bars(h, ln, dead, live, concrete, rebar; n_spans, cover, bar_size, inner_layer=false)

Flexural bars for a unit strip of the slab that spans from rib to rib.

`ln` is that span. The caller passes the center-to-center rib spacing, which
is not shorter than the clear span. `dead` and `live` are unfactored
pressures. ACI 318-11 §8.13.6.2 (corpus: aci-318-11, page 120) requires this
steel for flexure, and not less than §7.12.

When the rib-to-rib spans meet §8.3.3, the moments are those coefficients
(page 113), including `wu·ln²/12` where every span is at most 10 ft. The
discontinuous end is integral with the edge rib. Otherwise the moments are
[`patterned_strip_moments`](@ref), the elastic strip enveloped over the
§8.11.2 live-load arrangements. The §7.12 mat is placed either way.

`inner_layer = true` is the direction placed inside the other one, so its
effective depth is one `bar_size` diameter less.

`max_spacing` defaults to five times the thickness and 18 in, which is
§7.12.2.2 (page 106). §7.6.5's three-thickness limit is for slabs other than
joist construction (page 96), so a joist topping does not use it. A solid
slab passes that tighter limit itself. `span`, `discontinuous`, and
`support_face` are the §8.3.3 arguments; the defaults are an end span built
into a spandrel.
"""
function one_way_topping_bars(h, ln, dead, live, concrete, rebar;
                              n_spans::Int, cover, bar_size::Int, inner_layer::Bool = false,
                              max_spacing = nothing, span::Symbol = :end,
                              discontinuous::Symbol = :spandrel,
                              support_face::Symbol = :first_interior)
    n_spans >= 1 || throw(ArgumentError("a topping needs at least one span, got $n_spans"))
    ln > zero(ln) || throw(ArgumentError("the rib-to-rib span is not positive, got $ln"))
    spans = fill(ln, n_spans)
    ok, reasons = coefficients_permitted(;
        n_spans = n_spans, clear_spans = spans,
        live = live, dead = dead, rectangular = true)
    wu = factored_pressure(default_combo, dead, live)
    if ok
        analysis = :coefficients
        short_slab = ln <= 10.0u"ft"
        moms = approximate_one_way_moments(wu, ln;
            span = span, discontinuous = discontinuous, n_spans = n_spans,
            support_face = support_face, short_slab = short_slab)
        m_pos, m_ext, m_int = moms.M_pos, moms.M_neg_exterior, moms.M_neg_interior
    else
        analysis = :elastic
        push!(reasons, "ACI 318-11 §8.3.1: elastic strip, outer ends pinned; " *
                       "live load patterned per §8.11.2")
        elastic = patterned_strip_moments(default_combo.D * dead, default_combo.L * live, spans)
        m_pos, m_ext, m_int = elastic.M_pos, zero(elastic.M_neg), elastic.M_neg
    end
    db = bar_diameter(bar_size)
    d = effective_depth(h; cover = cover, bar_diameter = db, two_way = false) -
        (inner_layer ? db : zero(db))
    b = 1.0u"m"
    fc = concrete.fc′
    fy = rebar.Fy
    # Joist default: ACI 318-11 §7.12.2.2, page 106. Not §7.6.5 (page 96).
    s_max = something(max_spacing, min(5 * h, 18.0u"inch"))
    strip(location, m) = _topping_strip(location, m, b, d, h, fc, fy; max_spacing = s_max)
    return (
        bars = (pos = strip(:pos, m_pos), ext_neg = strip(:ext_neg, m_ext),
                int_neg = strip(:int_neg, m_int)),
        reasons = reasons,
        analysis = analysis,
    )
end

"""
    shrinkage_topping_bars(h, rebar) -> NamedTuple

The topping direction that does not span rib to rib, such as the direction
parallel to one-way joists. It carries no flexure, so it is the ACI 318-11
§7.12 mat only (corpus: aci-318-11, page 106): area §7.12.2.1, spacing
§7.12.2.2. Same shape as [`one_way_topping_bars`](@ref); the negative strips
are empty.
"""
function shrinkage_topping_bars(h, rebar)
    b = 1.0u"m"
    As_temp = shrinkage_temperature_ratio(rebar.Fy) * b * h
    bars = select_bars(As_temp, b; max_spacing = min(5 * h, 18.0u"inch"))
    As = uconvert(u"m^2", As_temp)
    mat = StripReinforcement(:pos, 0.0u"N*m", 0.0u"m^2", As,
        uconvert(u"m^2", bars.As_provided), bars.bar_size,
        uconvert(u"m", bars.spacing), bars.n_bars, true)
    none = StripReinforcement(:neg, 0.0u"N*m", 0.0u"m^2", 0.0u"m^2", 0.0u"m^2",
        bars.bar_size, 0.0u"m", 0, true)
    return (bars = (pos = mat, ext_neg = none, int_neg = none),
            reasons = ["ACI 318-11 §7.12: shrinkage and temperature only, parallel to the ribs"],
            analysis = :shrinkage)
end

"""
    solid_slab_spacing(h) -> Length

Primary flexural spacing in a solid slab, not joist construction.

ACI 318-11 §7.6.5 (corpus: aci-318-11, page 96): not farther apart than
three times the slab thickness, nor farther apart than 18 in.
"""
solid_slab_spacing(h::Length) = min(3 * h, 18.0u"inch")

"""
    area_direction_bars(As_bot, As_top; max_spacing, reason) -> NamedTuple

One bar direction from required areas per metre of width.

`As_bot` and `As_top` are bare m²/m. Bottom steel is the positive strip.
Top steel is the interior negative strip. The same shape as
[`one_way_topping_bars`](@ref), so [`detail_rib_topping`](@ref) can place it.
A non-positive area leaves that face empty.
"""
function area_direction_bars(As_bot::Real, As_top::Real; max_spacing, reason::AbstractString)
    bot = _area_strip(:pos, As_bot, max_spacing)
    top = _area_strip(:int_neg, As_top, max_spacing)
    none = _area_strip(:ext_neg, 0.0, max_spacing)
    return (bars = (pos = bot, ext_neg = none, int_neg = top),
            reasons = [String(reason)],
            analysis = :shell)
end

"A face with no required area. Spacing zero so the placer skips it."
function _area_strip(location::Symbol, as_per_m::Real, max_spacing)
    b = 1.0u"m"
    As = max(float(as_per_m), 0.0) * u"m^2"
    if ustrip(As) <= 0
        return StripReinforcement(location, 0.0u"N*m", 0.0u"m^2", 0.0u"m^2",
            0.0u"m^2", 4, 0.0u"m", 0, true)
    end
    bars = select_bars(As, b; max_spacing = max_spacing)
    return StripReinforcement(location, 0.0u"N*m", uconvert(u"m^2", As), 0.0u"m^2",
        uconvert(u"m^2", bars.As_provided), bars.bar_size,
        uconvert(u"m", bars.spacing), bars.n_bars, true)
end
