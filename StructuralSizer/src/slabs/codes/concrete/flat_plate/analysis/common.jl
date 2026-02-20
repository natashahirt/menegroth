# =============================================================================
# Shared Setup for Moment Analysis (DDM / EFM / FEA)
# =============================================================================
#
# Common preamble used by all three analysis methods to compute:
#   l1, l2, span_axis, n_cols, c1_avg, ln, sw, qD, qL, qu, M0
#
# Avoids copy-pasting the same 15 lines in each run_moment_analysis method.
# =============================================================================

"""
    _moment_analysis_setup(struc, slab, columns, h, γ_concrete)

Compute shared quantities for any moment analysis method (primary direction).

Returns a NamedTuple:
- `l1`, `l2`, `ln` (ft)
- `span_axis` (unitless direction)
- `c1_avg` (Length)
- `sw`, `qD`, `qL`, `qu` (psf)
- `M0` (Moment)
"""
function _moment_analysis_setup(struc, slab, columns, h, γ_concrete)
    l1 = uconvert(u"ft", slab.spans.primary)
    l2 = uconvert(u"ft", slab.spans.secondary)
    span_axis = _get_span_axis(slab)

    n_cols = length(columns)
    c1_avg = sum(isnothing(c.c1) ? 0.0u"inch" : c.c1 for c in columns) / n_cols
    ln = clear_span(l1, c1_avg)

    cell = struc.cells[first(slab.cell_indices)]
    sw = slab_self_weight(h, γ_concrete)
    qD = uconvert(psf, cell.sdl) + sw
    qL = uconvert(psf, cell.live_load)
    # ACI / ASCE 7 §2.3.1: use governing of 1.2D+1.6L and 1.4D
    qu_1 = factored_pressure(default_combo, qD, qL)     # 1.2D + 1.6L
    qu_2 = factored_pressure(strength_1_4D, qD, qL)     # 1.4D + 0·L
    qu = max(qu_1, qu_2)
    M0 = total_static_moment(qu, l2, ln)

    return (
        l1 = l1, l2 = l2, ln = ln,
        span_axis = span_axis,
        c1_avg = c1_avg,
        sw = sw, qD = qD, qL = qL, qu = qu,
        M0 = M0,
    )
end

"""
    _secondary_moment_analysis_setup(struc, slab, columns, h, γ_concrete)

Compute shared quantities for the **secondary (perpendicular) direction**.

Swaps l1↔l2 and uses c2 for clear span, with the perpendicular span axis.
Factored loads (qu, qD, qL) are direction-independent so they're reused.

Returns the same NamedTuple shape as `_moment_analysis_setup`.
"""
function _secondary_moment_analysis_setup(struc, slab, columns, h, γ_concrete)
    # Swap: secondary span becomes the "span" direction, primary becomes tributary width
    l1_sec = uconvert(u"ft", slab.spans.secondary)
    l2_sec = uconvert(u"ft", slab.spans.primary)

    # Perpendicular span axis: rotate 90° CCW
    ax = _get_span_axis(slab)
    span_axis_sec = (-ax[2], ax[1])

    n_cols = length(columns)
    # Use c2 for clear span in secondary direction
    c2_avg = sum(isnothing(c.c2) ? 0.0u"inch" : c.c2 for c in columns) / n_cols
    ln_sec = clear_span(l1_sec, c2_avg)

    # Loads are direction-independent
    cell = struc.cells[first(slab.cell_indices)]
    sw = slab_self_weight(h, γ_concrete)
    qD = uconvert(psf, cell.sdl) + sw
    qL = uconvert(psf, cell.live_load)
    qu_1 = factored_pressure(default_combo, qD, qL)
    qu_2 = factored_pressure(strength_1_4D, qD, qL)
    qu = max(qu_1, qu_2)
    M0_sec = total_static_moment(qu, l2_sec, ln_sec)

    return (
        l1 = l1_sec, l2 = l2_sec, ln = ln_sec,
        span_axis = span_axis_sec,
        c1_avg = c2_avg,
        sw = sw, qD = qD, qL = qL, qu = qu,
        M0 = M0_sec,
    )
end

# =============================================================================
# Shared Column Shear Computation
# =============================================================================

"""
    _compute_column_shear(struc, col, qu, l2, ln)

Compute column shear using tributary area (if `struc` has `_tributary_caches`),
otherwise fall back to a simply-supported approximation `qu × l2 × ln / 2`.

Used by both DDM and EFM analysis methods.
"""
function _compute_column_shear(struc, col, qu, l2, ln)
    Atrib = nothing
    vidx = col_vertex_idx(col)
    if !isnothing(struc) && hasproperty(struc, :_tributary_caches) && vidx > 0
        caches = struc._tributary_caches
        story = col_story(col)
        if haskey(caches.vertex, story) && haskey(caches.vertex[story], vidx)
            Atrib = caches.vertex[story][vidx].total_area
        end
    end

    if !isnothing(Atrib) && ustrip(u"m^2", Atrib) > 0
        return uconvert(kip, qu * Atrib)
    else
        # Fallback: position-aware tributary approximation
        # Interior: full tributary on both sides → l2 × ln/2
        # Edge:     tributary on one side only   → l2/2 × ln/2
        # Corner:   quarter tributary            → l2/2 × ln/2 (from each direction)
        pos = hasproperty(col, :position) ? col.position : :interior
        A_base = l2 * ln / 2   # interior tributary
        if pos == :edge
            A_trib = A_base / 2
        elseif pos == :corner
            A_trib = A_base / 4
        else
            A_trib = A_base
        end
        @debug "Shear fallback (no Voronoi cache)" position=pos A_trib=A_trib
        return uconvert(kip, qu * A_trib)
    end
end
