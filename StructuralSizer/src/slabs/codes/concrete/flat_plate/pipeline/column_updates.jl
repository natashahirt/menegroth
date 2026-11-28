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
    _initialize_unsized_columns!(columns, Pu, ln_max, opts, column_opts)

Give a starting size to each column that nothing sized before the slab
loop. Column sizing only grows, so this start is the smallest column the
loop can return.

- With `opts.column_span_minimum`, span/15.
- Otherwise the square tied column that carries `Pu[i]` (kip, this slab's
  factored load) by ACI 318-11 Eq. (10-2) at ρg = 0.01
  ([`tied_column_area_for_axial`](@ref)), and at least 14". This is the
  `start = :axial` estimate of the building pipeline, with this slab's
  load in place of the load of every floor above, which a standalone slab
  does not know.

Either start is rounded up to the inch and clamped to `opts.max_column_size`.
"""
function _initialize_unsized_columns!(columns, Pu, ln_max, opts, column_opts)
    fc = column_opts.material.fc′
    fy = column_opts.rebar_material.Fy
    for (i, col) in enumerate(columns)
        (isnothing(col.c1) || col.c1 <= 0u"inch") || continue
        c = if opts.column_span_minimum
            estimate_column_size_from_span(ln_max)
        else
            Ag = tied_column_area_for_axial(Pu[i] * kip, fc; fy = fy)
            max(ceil(ustrip(u"inch", sqrt(Ag))) * u"inch", 14.0u"inch")
        end
        col.c1 = col.c2 = min(c, opts.max_column_size)
    end
    return columns
end

"""
    _reseed_columns_for_thickness!(columns, Pu, ln_max, opts, column_opts)

Drop the sizes chosen at the previous slab thickness and start again.
Punching and the §13.6.9.2 moment split both depend on `h`. A column
continuing from the story above keeps that story's size as a floor, then
the same start as [`_initialize_unsized_columns!`](@ref) is applied.
"""
function _reseed_columns_for_thickness!(columns, Pu, ln_max, opts, column_opts)
    floors = map(columns) do col
        above = hasproperty(col, :column_above) ? col.column_above : nothing
        if above === nothing || isnothing(above.c1) || above.c1 <= 0u"inch"
            (0.0u"inch", 0.0u"inch")
        else
            (above.c1, something(above.c2, above.c1))
        end
    end
    for col in columns
        col.c1 = 0.0u"inch"
        col.c2 = 0.0u"inch"
    end
    _initialize_unsized_columns!(columns, Pu, ln_max, opts, column_opts)
    for (col, (a1, a2)) in zip(columns, floors)
        col.c1 = max(col.c1, a1)
        col.c2 = max(col.c2, a2)
    end
    return columns
end

"""
    _update_column_sizes!(columns, column_result, Pu, Mu, c_span_min, column_opts, column_tol;
                          Muy, verbose)

Update column dimensions from P-M design results. Returns `true` if either
plan dimension of any column changed by more than `column_tol` (relative).

When a column is held larger than the catalog section, its bars are
redesigned for `Mu` and `Muy`, magnified for slenderness with `geometries`
(the §10.10.5 designation and alignment-chart k). The redesign
uses the same concrete, rebar, and `βdns` as the catalog check
(`column_opts`), not the slab's. `Muy` defaults to zeros. A rectangular
redesign then checks `Mu` about both section axes, since the span direction
is not tied to the section's strong axis.
"""
function _update_column_sizes!(columns, column_result, Pu, Mu, c_span_min, column_opts, column_tol;
                                Muy = nothing, verbose::Bool = false,
                                geometries = nothing)
    material = _column_rc_material(column_opts)
    βdns = column_opts.βdns
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
            geometry = geometries === nothing ?
                ConcreteMemberGeometry(col.base.L; Lu = col.base.L,
                                      kx = 1.0, ky = 1.0, braced = col.braced) :
                geometries[i]
            # The slab moment bends the column in the span direction, which
            # can be either section axis, so a lone Mu is checked about both.
            axis_kw = section isa RCColumnSection ? (both_orientations = true,) : (;)
            col.base.section = resize_column_with_reinforcement(
                section, col.c1, col.c2, Pu[i], Mu[i], material; Muy = muy, geometry, βdns,
                axis_kw...
            )
        end

        rel_change(new, old) = abs(ustrip(u"inch", new) - ustrip(u"inch", old)) /
                               max(ustrip(u"inch", old), 1.0)
        changed = max(rel_change(col.c1, c1_old), rel_change(col.c2, c2_old)) > column_tol
        changed && (columns_changed = true)

        if verbose
            status = changed ? "CHANGED" : "unchanged"
            @debug "Column $i" pm_design=c1_pm final="$(col.c1)×$(col.c2)" ρg=round(col.base.section.ρg, digits=3) status=status
        end
    end
    return columns_changed
end

"""Column concrete and rebar from `column_opts`, as one material for the bar redesign."""
_column_rc_material(column_opts) = ReinforcedConcreteMaterial(
    column_opts.material, column_opts.rebar_material,
    something(column_opts.transverse_rebar_material, column_opts.rebar_material))

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

