# ==============================================================================
# AbstractNLPProblem Interface
# ==============================================================================

"""Flat plate optimization has 2 decision variables: `[h, c]`."""
n_variables(::FlatPlateNLPProblem) = 2

"""Return `(lb, ub)` bound vectors in inches for `[h, c]`."""
function variable_bounds(p::FlatPlateNLPProblem)
    lb = [p.h_bounds_in[1], p.c_bounds_in[1]]
    ub = [p.h_bounds_in[2], p.c_bounds_in[2]]
    return (lb, ub)
end

"""Return midpoint initial guess `[h₀, c₀]` in inches."""
function initial_guess(p::FlatPlateNLPProblem)
    h0 = (p.h_bounds_in[1] + p.h_bounds_in[2]) / 2
    c0 = (p.c_bounds_in[1] + p.c_bounds_in[2]) / 2
    return [h0, c0]
end

"""Return variable name strings for the flat plate optimization."""
variable_names(::FlatPlateNLPProblem) = ["h_in", "c_in"]

# ==============================================================================
# Objective Conversion
# ==============================================================================
# evaluate() returns the full composite objective (concrete + steel), so the
# grid solver's _convert_objective should be identity.

"""Identity conversion — `evaluate()` already returns the composite objective."""
_convert_objective(::MinVolume, ::FlatPlateNLPProblem, v::Float64) = v
_convert_objective(::MinWeight, ::FlatPlateNLPProblem, v::Float64) = v
_convert_objective(::MinCarbon, ::FlatPlateNLPProblem, v::Float64) = v
_convert_objective(::MinCost,   ::FlatPlateNLPProblem, v::Float64) = v

# ==============================================================================
# Core Evaluate (called at every grid point)
# ==============================================================================

"""
Transfer moment at NLP column `i` along `span_axis`.

With a stored building this is `_eq137_transfer_moment`: Eq. (13-7) where
the slab is continuous on both sides of the column in this direction,
0.3 M0 where it is not (ACI 318-11 §13.6.3.6, corpus: aci-318-11, page 255).
An edge column is exterior only perpendicular to the edge.

Without a stored building (positional constructor, `eq137 === nothing`)
the column `position` is the fallback: non-interior gets 0.3 M0 in both
directions, interior gets the equal-span Eq. (13-7) envelope.  The same
fallback is used for a column index beyond the stored columns.  Either
emits a `:fallback` trace event.  On the fallback, a negative service
`qD` / `qL` returns NaN with a `:failure` event (`negative_service_load`);
the geometry path does the same inside `_eq137_transfer_moment`.
`c_trial` is the decision-variable column size on the slab under design.
`maps` is the `_nlp_eq137_maps` snapshot `evaluate` took for this grid
point; its frozen `struc` and `columns` are the geometry read here.
"""
function _nlp_transfer_moment(p::FlatPlateNLPProblem, i::Int,
                              qD::Pressure, qL::Pressure, l2::Length, ln::Length,
                              span_axis, c_trial::Length, M0;
                              design_drop::Pressure = 0.0psf, tc = p.tc,
                              maps = _nlp_eq137_maps(p))
    if isnothing(p.eq137) || i > length(maps.columns)
        _nlp_trace_positional(p, i, "_nlp_transfer_moment", tc)
        if _eq137_negative_input(qD, qL)
            # ACI 318-11 §13.6.1.5 (corpus: aci-318-11, page 252): gravity
            # loads only.  Rejected like a non-finite demand.
            emit!(tc, :slab, "_nlp_transfer_moment", "nlp_col_$(i)", :failure;
                  reason = "negative_service_load")
            return NaN * kip * u"ft"
        end
        if p.column_positions[i] != :interior
            return 0.3 * M0
        end
        return governing_interior_unbalanced_moment(qD, qL, l2, ln, qD, qL, l2, ln)
    end
    return _eq137_transfer_moment(
        maps.struc, p.eq137.slab, maps.columns[i], span_axis,
        qD, qL, l2, ln, M0;
        c_override = c_trial, extra_columns = maps.columns,
        index = maps.index, vertex_column = maps.vertex_column,
        cell_slab = maps.cell_slab, partway = maps.partway,
        design_drop = design_drop, γ = p.γ_concrete, tc = tc,
    )
end

"""
Negative flexural moment at NLP column `i` along `span_axis`.

With a stored building this is `_ddm_support_moment`, the DDM flexural
assignment (ACI 318-11 §13.6.3.3, corpus: aci-318-11, page 254) classified
by the same panel geometry as `_nlp_transfer_moment`, including the
geometry/tag disagreement envelope.  Without one, the column `position` is
the fallback: non-interior is an exterior support.  As for the transfer
moment, the fallback emits a `:fallback` trace event.  `maps` is the
same per-grid-point snapshot (maps and geometry).
"""
function _nlp_support_moment(p::FlatPlateNLPProblem, i::Int, span_axis,
                             M_neg_ext, M_neg_int; tc = p.tc,
                             maps = _nlp_eq137_maps(p))
    if isnothing(p.eq137) || i > length(maps.columns)
        _nlp_trace_positional(p, i, "_nlp_support_moment", tc)
        return p.column_positions[i] != :interior ? M_neg_ext : M_neg_int
    end
    return _ddm_support_moment(maps.struc, maps.columns[i], span_axis,
                               M_neg_ext, M_neg_int; index = maps.index,
                               vertex_column = maps.vertex_column,
                               partway = maps.partway, tc = tc)
end

"""
    evaluate(p::FlatPlateNLPProblem, x) -> (feasible, objective, result)

Evaluate a single (h, c) grid point.  Runs DDM moments, punching shear,
one-way shear, an inner rebar sweep (with deflection check per bar size),
and returns the best feasible configuration.

Fallbacks raised here go to `p.tc`.  The grid search calls `evaluate` on
many threads, so each call buffers its events and merges them under
`p.trace_lock`, keeping one copy of each distinct event.  Stale Eq. (13-7)
maps are first replaced (`_nlp_check_eq137!`: a lock-free exact check,
the lock only to rebuild; skipped inside a frozen sweep,
`_nlp_frozen_sweep`); the point is then evaluated against one snapshot
(`_nlp_eq137_maps`) of the maps and of the frozen geometry they were built
from, so a mutation of `struc` during the call cannot mix old maps with
new coordinates, faces or column sizes, and Mub and Muy see the same
geometry.  Outside a frozen sweep the mutation is picked up by the next
call.
"""
function evaluate(p::FlatPlateNLPProblem, x::Vector{Float64})
    buf = isnothing(p.tc) ? nothing :
          TraceCollector(TraceEvent[], p.tc.enabled, p.tc.start_time)
    try
        _nlp_check_eq137!(p, buf)
        return _evaluate_point(p, x, buf, _nlp_eq137_maps(p))
    finally
        _nlp_flush_trace!(p, buf)
    end
end

"""Merge one `evaluate` call's buffered events into `p.tc`, dropping repeats."""
function _nlp_flush_trace!(p::FlatPlateNLPProblem, buf)
    (isnothing(buf) || isempty(buf.events)) && return nothing
    lock(p.trace_lock) do
        for e in buf.events
            key = (e.layer, e.stage, e.element_id, e.event_type, e.data)
            key in p.trace_seen && continue
            push!(p.trace_seen, key)
            push!(p.tc.events, e)
        end
    end
    return nothing
end

"""
`evaluate` body for one grid point; trace events go to `tc`, Eq. (13-7)
lookups use the `maps` snapshot.
"""
function _evaluate_point(p::FlatPlateNLPProblem, x::Vector{Float64}, tc, maps)
    h_in, c_in = x
    h = h_in * u"inch"
    c = c_in * u"inch"

    # ── Effective depth ──
    d = effective_depth(h; cover=p.cover, bar_diameter=p.bar_dia)
    if ustrip(u"inch", d) <= 0.5
        return (false, Inf, nothing)
    end

    # ── Loads ──
    sw  = slab_self_weight(h, p.γ_concrete)
    qD  = uconvert(psf, p.sdl) + sw
    qL  = uconvert(psf, p.qL)
    # Drop-panel projection is dead load on qD, factored with D.
    # Kept separately so a neighbour that falls back to trial self-weight
    # is not also charged the design slab's drop.
    # The drop is read from the `maps` snapshot, so a grid point sees the
    # drop that was current with the geometry it reads.
    q_drop = 0.0psf
    drop_panel = isnothing(maps) ? nothing : get(maps, :drop_panel, nothing)
    if !isnothing(drop_panel)
        q_drop = _eq137_drop_service(drop_panel, p.l1 * p.l2, p.γ_concrete)
        qD = uconvert(psf, qD + q_drop)
    end
    qu  = max(factored_pressure(default_combo, qD, qL),
              factored_pressure(strength_1_4D, qD, qL))

    # ── DDM moments ──
    l1 = uconvert(u"ft", p.l1)
    l2 = uconvert(u"ft", p.l2)
    c_ft = uconvert(u"ft", c)
    ln = clear_span(l1, c_ft)

    if ustrip(u"ft", ln) <= 0
        return (false, Inf, nothing)
    end

    M0        = total_static_moment(qu, l2, eq13_4_clear_span(l1, ln))
    M_neg_ext = p.c_neg_ext * M0
    M_neg_int = p.c_neg_int * M0
    M_pos     = p.c_pos * M0

    # Secondary-axis static moment: ACI 318-11 §13.6.2.2 Eq. (13-4)
    # (corpus: aci-318-11, page 253) with ℓ1 ↔ ℓ2 swapped.
    ln2 = clear_span(l2, c_ft)
    if ustrip(u"ft", ln2) <= 0
        return (false, Inf, nothing)
    end
    M0_y = total_static_moment(qu, l1, eq13_4_clear_span(l2, ln2))

    # ── Column-level demands (preallocated) ──
    n_col = length(p.column_positions)
    T_M = typeof(uconvert(kip * u"ft", M0))
    T_F = typeof(uconvert(kip, qu * l2 * ln / 2))

    col_moments = Vector{T_M}(undef, n_col)
    col_shears  = Vector{T_F}(undef, n_col)
    unbal_mom   = Vector{T_M}(undef, n_col)
    unbal_mom_y = Vector{T_M}(undef, n_col)

    # Primary axis of the panel.  Without stored geometry the NLP is one
    # panel and both directions use that panel's own spans.
    span_axis = isnothing(p.eq137) ? (1.0, 0.0) : p.eq137.span_axis
    span_axis_y = (-span_axis[2], span_axis[1])

    for i in 1:n_col
        # ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254): exterior-
        # negative at an exterior support, interior-negative at an interior
        # one.  Classified along this axis by the same panel geometry as the
        # transfer moment below, which is what DDM does.
        M   = _nlp_support_moment(p, i, span_axis, M_neg_ext, M_neg_int;
                                  tc = tc, maps = maps)
        # Transfer is direction-aware.  Eq. (13-7) (corpus: aci-318-11,
        # page 258) where the slab continues on both sides of this column
        # along the axis; §13.6.3.6 0.3 M0 (page 255) where it does not.
        # An edge column is exterior only perpendicular to the edge.
        # Without stored geometry, `position` is the fallback (a corner is
        # exterior both ways).  `c` is the trial column size.
        Mub = _nlp_transfer_moment(p, i, qD, qL, l2, ln, span_axis, c, M0;
                                   design_drop = q_drop, tc = tc, maps = maps)
        Muy = _nlp_transfer_moment(p, i, qD, qL, l1, ln2, span_axis_y, c, M0_y;
                                   design_drop = q_drop, tc = tc, maps = maps)

        A_trib_ft2 = p.column_trib_ft2[i]
        Vu = if A_trib_ft2 > 0
            uconvert(kip, qu * A_trib_ft2 * u"ft^2")
        else
            uconvert(kip, qu * l2 * ln / 2)
        end

        col_moments[i] = uconvert(kip * u"ft", M)
        col_shears[i]  = Vu
        unbal_mom[i]   = uconvert(kip * u"ft", Mub)
        unbal_mom_y[i] = uconvert(kip * u"ft", Muy)
    end
    Vu_max = uconvert(kip, qu * l2 * ln / 2)

    moment_results = MomentAnalysisResult(
        uconvert(kip * u"ft", M0),
        uconvert(kip * u"ft", M_neg_ext),
        uconvert(kip * u"ft", M_neg_int),
        uconvert(kip * u"ft", M_pos),
        qu, qD, qL,
        l1, l2, ln, c_ft,
        col_moments, col_shears, unbal_mom, Vu_max,
    )

    # ── Punching shear check (every column) ──
    for i in 1:n_col
        col_proxy = (c1=c, c2=c, position=p.column_positions[i])
        # Same §11.11.6 arguments as the design iteration. A problem with no
        # stored building has no openings, so the perimeter stays whole.
        open_kw = isnothing(p.eq137) ? (;) :
            column_opening_punching(p.eq137.struc, p.eq137.slab, p.eq137.columns[i])
        punch = check_punching_for_column(
            col_proxy, col_shears[i], unbal_mom[i], d, h, p.fc;
            λ=p.λ, φ_shear=p.φ_shear, Muy=unbal_mom_y[i],
            open_kw...,
        )
        if !punch.ok
            return (false, Inf, nothing)
        end
    end

    # ── One-way shear check ──
    shear = check_one_way_shear(moment_results, d, p.fc; h = h, fy = p.fy,
                                λ=p.λ, φ_shear=p.φ_shear)
    if !shear.ok
        return (false, Inf, nothing)
    end

    # ── Inner rebar sweep ──
    best_obj    = Inf
    best_result = nothing

    spans      = (primary=p.l1, secondary=p.l2)
    col_proxies = [(position=p.column_positions[i],) for i in 1:n_col]

    for bar_sz in p.bar_sizes
        rebar = _evaluate_rebar_for_size(p, moment_results, h, d, bar_sz, c, unbal_mom_y)
        if isinf(ustrip(u"inch^2", rebar.total_As))
            return (false, Inf, nothing)
        end

        # Deflection check with actual provided As
        defl = check_two_way_deflection(
            moment_results, h, d, p.fc, p.fy, p.Es, p.Ecs,
            spans, p.γ_concrete, col_proxies;
            λ = p.λ,
            limit_type = p.deflection_limit,
            As_provided = rebar.As_pos_cs,
        )

        if !defl.ok
            continue
        end

        obj = _flat_plate_objective(p, h, c, rebar)
        if obj < best_obj
            best_obj = obj
            best_result = (
                bar_size    = bar_sz,
                rebar       = rebar,
                deflection  = defl,
                objective   = obj,
            )
        end
    end

    if isnothing(best_result)
        return (false, Inf, nothing)
    end

    result = (
        h_in  = h_in,
        c_in  = c_in,
        h     = h,
        c     = c,
        d     = d,
        bar_size       = best_result.bar_size,
        total_As       = best_result.rebar.total_As,
        As_pos_cs      = best_result.rebar.As_pos_cs,
        deflection     = best_result.deflection,
        moment_results = moment_results,
        objective      = best_result.objective,
    )

    return (true, best_result.objective, result)
end

