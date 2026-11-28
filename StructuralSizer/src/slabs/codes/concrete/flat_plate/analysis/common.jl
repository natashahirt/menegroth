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
    _flat_plate_uniform_pressures(struc, slab, h, γ_concrete) -> (sw, qD, qL, qu)

Uniform pressures (psf) applied over the whole slab panel by the moment
analyses: self-weight `sw`, service dead `qD = SDL + sw`, service live `qL`,
and factored `qu = max(1.2D + 1.6L, 1.4D)` (ASCE 7 §2.3.1).

SDL and live load are each the largest over the slab's cells
(`_slab_service_pressures`), the same governing values the other slab types
use.

ENGINEERING JUDGMENT: DDM, EFM and the shell model load the panel with one
uniform pressure. Where cells carry different loads, the largest SDL and the
largest live load are applied over the whole panel. Every moment, shear and
deflection these analyses produce increases with the uniform pressure, so
this bounds the mixed-load panel from above. It is not a load-pattern
analysis of the individual cells.
"""
function _flat_plate_uniform_pressures(struc, slab, h, γ_concrete)
    sdl, live = _slab_service_pressures(struc, slab, "(flat plate)")
    sw = slab_self_weight(h, γ_concrete)
    qD = uconvert(psf, sdl) + sw
    qL = uconvert(psf, live)
    qu = max(factored_pressure(default_combo, qD, qL),     # 1.2D + 1.6L
             factored_pressure(strength_1_4D, qD, qL))     # 1.4D + 0·L
    return sw, qD, qL, qu
end

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
    # Face-to-face width along the span, including rectangular rotation
    # (ACI 318-11 §13.6.2.5, corpus: aci-318-11, page 253).  The same
    # projection is used for Eq. (13-7).  Axis-aligned columns reproduce
    # the previous mean of `c1`.
    c1_avg = _mean_support_width(columns, span_axis)
    ln = clear_span(l1, c1_avg)

    sw, qD, qL, qu = _flat_plate_uniform_pressures(struc, slab, h, γ_concrete)
    M0 = total_static_moment(qu, l2, eq13_4_clear_span(l1, ln))

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
    # Same face projection as the primary setup, along the swapped axis
    # (ACI 318-11 §13.6.2.5, corpus: aci-318-11, page 253).
    c2_avg = _mean_support_width(columns, span_axis_sec)
    ln_sec = clear_span(l1_sec, c2_avg)

    # Loads are direction-independent
    sw, qD, qL, qu = _flat_plate_uniform_pressures(struc, slab, h, γ_concrete)
    M0_sec = total_static_moment(qu, l2_sec, eq13_4_clear_span(l1_sec, ln_sec))

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

Compute column shear using the support's normalized tributary-area map,
otherwise fall back to a position-scaled tributary `qu × l2 × ln` (interior).

Used by both DDM and EFM analysis methods.
"""
function _compute_column_shear(struc, col, qu, l2, ln)
    Atrib = nothing
    if hasproperty(col, :tributary_cell_areas) && !isempty(col.tributary_cell_areas)
        Atrib = sum(values(col.tributary_cell_areas); init = 0.0) * u"m^2"
    end

    if !isnothing(Atrib) && ustrip(u"m^2", Atrib) > 0
        return uconvert(kip, qu * Atrib)
    else
        # Fallback: position-aware tributary approximation
        # Interior:          half a span on each side → l2 × (ln/2 + ln/2) = l2 × ln
        # Edge:              half of interior          → l2 × ln / 2
        # Convex corner:     one quadrant              → l2 × ln / 4
        # Re-entrant corner: THREE quadrants (inside corner of an L) ⇒ 3× a
        #   convex corner. A flat quarter-tributary would understate Vu ~3×,
        #   which is unsafe for punching; scale by corner kind. The primary
        #   per-incident-cell Voronoi path already captures this exactly — this
        #   only guards the degenerate no-cache fallback.
        # ENGINEERING JUDGMENT: the fallback uses the clear span ln, so it is
        # below the center-to-center tributary l2 × l1 by the strip l2 × c1.
        pos = hasproperty(col, :position) ? col.position : :interior
        A_base = l2 * ln   # interior tributary
        if pos == :edge
            A_trib = A_base / 2
        elseif pos == :corner
            ckind = hasproperty(col, :corner_kind) ? getfield(col, :corner_kind) : :convex
            A_trib = ckind == :reentrant ? 3 * A_base / 4 : A_base / 4
        else
            A_trib = A_base
        end
        @debug "Shear fallback (no Voronoi cache)" position=pos A_trib=A_trib
        return uconvert(kip, qu * A_trib)
    end
end
