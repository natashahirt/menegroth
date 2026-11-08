# =============================================================================
# Flat Plate Design Pipeline
# =============================================================================
#
# Main orchestration for flat plate design per ACI 318-11.
# This file contains only the high-level workflow - all helper functions
# are in separate modules (helpers.jl, checks.jl, reinforcement.jl, results.jl).
#
# Two-Phase Design (mirrors engineering practice):
#   Phase A — Depth convergence: iterate h for deflection, one-way shear,
#             flexural adequacy, and column P-M.  No punching check.
#   Phase B — Punching resolution: at the converged h, resolve punching via
#             column growth and/or shear studs.  h is locked unless studs +
#             columns are both maxed (last resort).
#   Phase C — Final design: rebar detailing, transfer reinforcement,
#             integrity steel, result assembly.
#
# An outer loop ties A→B→C: if Phase B or C signals "need more depth",
# h is bumped and Phase A restarts with the new floor.
#
# Reference: ACI 318-11 Chapters 9, 10, 11, 13
#
# =============================================================================

using Logging

# =============================================================================
# Pipeline Helpers (extracted from size_flat_plate! for readability)
# =============================================================================

"""
    _column_span_minimum(ln_max, opts) -> Length

Smallest column the slab loop allows: span/15 clamped to `opts.max_column_size`,
or zero when `opts.column_span_minimum` is false.
"""
function _column_span_minimum(ln_max, opts)
    opts.column_span_minimum || return 0.0u"inch"
    return min(estimate_column_size_from_span(ln_max), opts.max_column_size)
end

"""
    _update_column_sizes!(columns, column_result, Pu, Mu, c_span_min, material, column_tol; Muy, verbose)

Update column dimensions from P-M design results. Returns `true` if any
column size changed by more than `column_tol`.

When a column is held larger than the catalog section, its bars are
redesigned for `Mu` and `Muy`. `Muy` defaults to zeros, which keeps the
uniaxial redesign.
"""
function _update_column_sizes!(columns, column_result, Pu, Mu, c_span_min, material, column_tol;
                                Muy = nothing, verbose::Bool = false)
    if !_rc_nlp_result_installable(column_result)
        @warn "Column NLP result is not a completed design; leaving column sizes unchanged" status=column_result.status
        return false
    end
    columns_changed = false
    for (i, col) in enumerate(columns)
        section = column_result.sections[i]
        bb = bounding_box(section)
        c1_pm = bb.width
        c2_pm = bb.depth
        c1_old = col.c1
        c2_old = col.c2

        col.c1 = max(c_span_min, c1_pm, c1_old)
        col.c2 = max(c_span_min, c2_pm, c2_old)

        if col.c1 ≈ c1_pm && col.c2 ≈ c2_pm
            col.base.section = section
        else
            muy = Muy === nothing ? 0.0 : Muy[i]
            col.base.section = resize_column_with_reinforcement(
                section, col.c1, col.c2, Pu[i], Mu[i], material; Muy = muy
            )
        end

        c1_in = ustrip(u"inch", col.c1)
        c1_old_in = ustrip(u"inch", c1_old)
        Δc1 = abs(c1_in - c1_old_in) / max(c1_old_in, 1.0)
        Δc1 > column_tol && (columns_changed = true)

        if verbose
            status = Δc1 > column_tol ? "CHANGED" : "unchanged"
            @debug "Column $i" pm_design=c1_pm final="$(col.c1)×$(col.c2)" ρg=round(col.base.section.ρg, digits=3) status=status
        end
    end
    return columns_changed
end

"""
    _flat_plate_column_pm_failure(column_result, h, iterations, drop_panel)

`column_pm_infeasible` result when an NLP column solve cannot be installed,
or `nothing` when the result may be written (including a discrete-MIP status).

`false` from [`_update_column_sizes!`](@ref) means the column size did not
change. A rejected NLP result is not that case. Callers must return this
tuple instead of continuing the flat-plate loop.
"""
function _flat_plate_column_pm_failure(column_result, h, iterations, drop_panel)
    _rc_nlp_result_installable(column_result) && return nothing
    @warn "Column NLP result is not a completed design" status=column_result.status h=h
    return (
        converged        = false,
        failure_reason   = "column_pm_infeasible",
        failing_check    = "column_pm",
        iterations       = iterations,
        h_final          = h,
        pattern_loading  = false,
        slab_result      = nothing,
        column_results   = nothing,
        drop_panel       = drop_panel,
        integrity        = nothing,
        integrity_check  = nothing,
        transfer_results = nothing,
        ρ_prime          = nothing,
    )
end

