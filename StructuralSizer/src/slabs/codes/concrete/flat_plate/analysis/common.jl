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

Compute shared quantities for any moment analysis method.

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
    qu = factored_pressure(default_combo, qD, qL)
    M0 = total_static_moment(qu, l2, ln)

    return (
        l1 = l1, l2 = l2, ln = ln,
        span_axis = span_axis,
        c1_avg = c1_avg,
        sw = sw, qD = qD, qL = qL, qu = qu,
        M0 = M0,
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
        # Fallback: simply-supported approximation
        # Conservative for interior columns, unconservative for edge columns
        return uconvert(kip, qu * l2 * ln / 2)
    end
end
