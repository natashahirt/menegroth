"""
    _resolve_punching_failures!(punching_local, columns, all_fails, opts, column_opts,
                                 moment_results, secondary_results,                                  h, d, fc, h_increment;
                                 λ, φ_shear, verbose, recheck) -> (grew::Bool, h_new)

Handle punching shear failures using the configured punching strategy.

# Strategies (`opts.punching_strategy`)
- `:grow_columns`    — Only grow columns; bump h if maxed out (legacy `:never`)
- `:reinforce_last`  — Grow columns first, reinforce only if columns max out (legacy `:if_needed`)
- `:reinforce_first` — Try reinforcement first, grow columns if reinforcement fails (legacy `:always`)

# Reinforcement Types (`opts.punching_reinforcement`)
- `:headed_studs_generic`, `:headed_studs_incon`, `:headed_studs_ancon` — Headed shear studs (§11.11.5)
- `:closed_stirrups` — Closed stirrup reinforcement (§11.11.3)
- `:shear_caps` — Localized slab thickening at columns (§13.2.6)
- `:column_capitals` — Flared column head enlargement (§13.1.2)

# Fixed-demand sizing
Punching capacity is analytic, so column sizes are chosen against the demand of
the current analysis rather than one analysis per growth step. `recheck(i)`
re-runs the punching check for `columns[i]` at its current dimensions with the
current `Vu`/`Mub`; candidate sizes are scanned upward along the growth
direction from `solve_column_for_punching`, and the smallest size that passes is
kept (bare for `:grow_columns`/`:reinforce_last`, bare or reinforced for
`:reinforce_first`). The caller re-runs the analysis after any growth, since a
stiffer column attracts more moment, and re-checks every column. Without
`recheck`, the analytic estimate from `solve_column_for_punching` is used.

`punch_kwargs(i)` returns the keywords column `i`'s own punching check uses
(`punching_axis_kwargs`); shear caps and capitals check their sections with
them. Default: none.

# Flat slabs (`drop = (panel, h_total, d_total)`)
`check_punching` checks two sections (ACI 318-11 §11.11.1.2, page 200):
- At the drop-panel edge, in the slab depth. Column growth and reinforcement
  around the column do not change that section, so a failure there goes
  straight to a thicker slab.
- At the column face, inside the drop. Studs and stirrups are designed at
  the total depth `d_total`, and their lines stop where the section `d/2`
  past the last line would leave the drop. Shear caps and capitals assume
  the slab depth around the column and are not used with a drop panel.

Returns `(columns_grew, updated_h)`.
"""
function _resolve_punching_failures!(punching_local, columns, all_fails, opts, column_opts,
                                      moment_results, secondary_results,
                                      h, d, fc, h_increment;
                                      λ=1.0, φ_shear=0.75, verbose::Bool = false,
                                      recheck = nothing, punch_kwargs = i -> (;),
                                      drop = nothing)
    c_max = opts.max_column_size
    _shape_con = column_opts.shape_constraint
    _max_ar = column_opts.max_aspect_ratio
    _c_inc = column_opts.size_increment
    strategy = opts.punching_strategy
    reinforcement = opts.punching_reinforcement

    columns_grew = false

    for i in all_fails
        col = columns[i]
        pr = punching_local[i]
        if drop !== nothing && hasproperty(pr, :drop_section) && !pr.drop_section.ok
            h = round_up_thickness(h + h_increment, h_increment)
            @warn "Column $i: punching fails at the drop-panel edge. Increasing h → $h" position=col.position ratio=pr.drop_section.ratio
            return (true, h)
        end
        demand = (Vu = moment_results.column_shears[i],
                  Mub = moment_results.unbalanced_moments[i],
                  Muy = isnothing(secondary_results) ? nothing :
                        secondary_results.unbalanced_moments[i])

        _col_Mx = !isnothing(secondary_results) ? moment_results.column_moments[i] : nothing
        _col_My = !isnothing(secondary_results) ? secondary_results.column_moments[i] : nothing

        c1_req, c2_req = solve_column_for_punching(
            col, pr.ratio, pr.b0, d;
            shape_constraint = _shape_con, max_ar = _max_ar,
            Mx = _col_Mx, My = _col_My, increment = _c_inc,
        )
        grow = (target = (c1_req, c2_req), c_max = c_max, inc = _c_inc,
                shape = _shape_con, max_ar = _max_ar)
        reinforce(res) = drop === nothing ?
            _try_reinforcement(reinforcement, res.vu, fc, res.b0, d, h, col,
                               opts, moment_results, demand;
                               λ=λ, φ=φ_shear, punch_kwargs=punch_kwargs(i)) :
            _try_drop_reinforcement(reinforcement, res, fc, col, opts, moment_results,
                                    demand, drop; λ=λ, φ=φ_shear,
                                    punch_kwargs=punch_kwargs(i))

        if strategy === :reinforce_first
            # ── Try reinforcement first, grow columns only if reinforcement fails ──
            reinf_result = reinforce(pr)
            if reinf_result.ok
                punching_local[i] = _merge_reinforcement_result(pr, reinf_result)
                verbose && @info "Column $i ($(col.position)): $(reinf_result.description)"
                continue
            end
            found = _grow_to_passing!(col, i, grow, recheck) do res
                res.ok || reinforce(res).ok
            end
            if found
                columns_grew = true
                verbose && @warn "Column $i: reinforcement insufficient, grew to $(col.c1)×$(col.c2)"
            else
                h = round_up_thickness(h + h_increment, h_increment)
                @warn "Column $i stays $(col.c1)×$(col.c2); reinforcement and sizes within $c_max do not pass. Increasing h → $h"
                return (true, h)
            end

        elseif strategy === :reinforce_last
            # ── Grow columns first, reinforce only when columns max out ──
            if _grow_to_passing!(res -> res.ok, col, i, grow, recheck)
                columns_grew = true
                verbose && @warn "Column $i punching FAILED (ratio=$(round(pr.ratio, digits=2))). Grew to $(col.c1)×$(col.c2)"
                continue
            end
            reinf_result = reinforce(pr)
            if reinf_result.ok
                punching_local[i] = _merge_reinforcement_result(pr, reinf_result)
                verbose && @info "Column $i stays $(col.c1)×$(col.c2); $(reinf_result.description)"
            else
                h = round_up_thickness(h + h_increment, h_increment)
                @warn "Column $i: Max size and reinforcement insufficient. Increasing h → $h"
                return (true, h)
            end

        else  # :grow_columns (default)
            # ── Only grow columns; no reinforcement ──
            if _grow_to_passing!(res -> res.ok, col, i, grow, recheck)
                columns_grew = true
                verbose && @warn "Column $i punching FAILED (ratio=$(round(pr.ratio, digits=2))). Grew to $(col.c1)×$(col.c2)"
            else
                h = round_up_thickness(h + h_increment, h_increment)
                @warn "Column $i stays $(col.c1)×$(col.c2); no size within $c_max passes punching. Increasing h → $h" position=col.position ratio=pr.ratio
                return (true, h)
            end
        end
    end

    return (columns_grew, h)
end

"""
    _drop_depths(drop_panel, h, cover, bar_diameter) -> Union{Nothing, NamedTuple}

`(panel, h_total, d_total)` for `_resolve_punching_failures!`, or `nothing`
for a flat plate.
"""
function _drop_depths(drop_panel, h, cover, bar_diameter)
    drop_panel === nothing && return nothing
    h_total = total_depth_at_drop(h, drop_panel)
    return (panel = drop_panel, h_total = h_total,
            d_total = effective_depth(h_total; cover = cover, bar_diameter = bar_diameter))
end

"""
    _column_candidates(col, grow) -> Vector{Tuple}

Column sizes larger than the current one, in increasing order, up to
`grow.c_max`. Each step adds `grow.inc` to the dimension that grows most toward
`grow.target` and scales the other in proportion, so the scan follows the
direction chosen by `solve_column_for_punching` (aspect ratio from the column
moments, shape constraint) and continues past the target if needed.
"""
function _column_candidates(col, grow)
    c1_0, c2_0 = col.c1, col.c2
    Δ1 = max(grow.target[1] - c1_0, zero(c1_0))
    Δ2 = max(grow.target[2] - c2_0, zero(c2_0))
    Δmax = max(Δ1, Δ2)
    if Δmax ≤ zero(Δmax)
        Δ1 = Δ2 = Δmax = grow.inc
    end
    out = Tuple{typeof(c1_0), typeof(c2_0)}[]
    k = 1
    while true
        f = k * grow.inc / Δmax
        c1 = _round_up_to(c1_0 + f * Δ1, grow.inc)
        c2 = _round_up_to(c2_0 + f * Δ2, grow.inc)
        if grow.shape === :square
            c1 = c2 = max(c1, c2)
        elseif grow.shape === :bounded
            c1, c2 = _enforce_aspect_ratio!(c1, c2, grow.max_ar, grow.inc)
        end
        max(c1, c2) > grow.c_max && break
        (isempty(out) || out[end] != (c1, c2)) && push!(out, (c1, c2))
        k += 1
    end
    return out
end

"""
    _grow_to_passing!(accept, col, i, grow, recheck) -> Bool

Set `col` to the smallest candidate size for which `accept(recheck(i))` holds.
Without `recheck`, the analytic target is taken if it is within `grow.c_max`.
Returns `false` and leaves `col` unchanged when no candidate passes.
"""
function _grow_to_passing!(accept, col, i, grow, recheck)
    if isnothing(recheck)
        c1, c2 = grow.target
        max(c1, c2) > grow.c_max && return false
        col.c1 = c1; col.c2 = c2
        return true
    end
    c1_0, c2_0 = col.c1, col.c2
    for (c1, c2) in _column_candidates(col, grow)
        col.c1 = c1; col.c2 = c2
        accept(recheck(i)) && return true
    end
    col.c1 = c1_0; col.c2 = c2_0
    return false
end

"""
    _outer_section_demand(col, demand; span_axis=(1.0, 0.0)) -> NamedTuple

Column size and demand in the frame of `reinforcement_outer_section`, mapped the
same way as `check_punching_for_column`:
- The moment spanning along c1 varies the d/2 stress along c1, so it is the
  moment about y; the one spanning along c2 is about x. `Mub` spans along
  `span_axis`, `_span_along_c1` places it.
- Edge columns are oriented by `_orient_edge_column` (c1 perpendicular to the
  free edge). The moment about the axis parallel to the edge is `M_about_y`
  and the other is `M_about_x`, split by `_edge_moment_pairs` as in the
  column-face check (ACI 318-11 R11.11.7.2, pages 209–211). When the edge
  direction does not decide the split, both take the larger moment, which
  bounds either assignment.
- Circular edge/corner columns use the equivalent square; circular interior
  columns use the equivalent square for the polygonal outer section.

`span_axis` is the plan direction of `Mub`.
"""
function _outer_section_demand(col, demand; span_axis = (1.0, 0.0))
    c1, c2 = col.c1, col.c2
    if col_shape(col) == :circular
        c1 = c2 = equivalent_square_column(col.c1)
    end
    Mub = demand.Mub
    Muy = something(demand.Muy, zero(Mub))
    if col.position === :edge
        ori = _orient_edge_column(c1, c2, Mub, Muy;
                                  free_edge_parallel = _infer_free_edge_parallel(col))
        pairs = _edge_moment_pairs(col, Mub, Muy, span_axis)
        M_par, M_oth = if length(pairs) == 1
            abs(pairs[1].M_par), abs(pairs[1].M_oth)
        else
            M = max(abs(Mub), abs(Muy))
            M, M
        end
        return (c1 = ori.c1, c2 = ori.c2, Vu = demand.Vu,
                M_about_x = M_oth, M_about_y = M_par)
    end
    M_c1, M_c2 = _span_along_c1(col, span_axis) ? (Mub, Muy) : (Muy, Mub)
    return (c1 = c1, c2 = c2, Vu = demand.Vu, M_about_x = M_c2, M_about_y = M_c1)
end

"""
    _is_headed_stud_reinforcement(reinforcement::Symbol) -> Bool

Check if the reinforcement type is a headed stud variant (requires a catalog).
"""
_is_headed_stud_reinforcement(r::Symbol) =
    r === :headed_studs_generic || r === :headed_studs_incon || r === :headed_studs_ancon

"""
    _try_reinforcement(reinforcement, vu, fc, b0, d, h, col, opts, moment_results, demand;
                       λ, φ) -> NamedTuple

Dispatch to the appropriate reinforcement design function and check at the
column's current size. `demand = (Vu, Mub, Muy)` feeds the outer critical
section check of studs and stirrups, and both sections of a shear cap and
the capital's section, which also take the column's `punch_kwargs`.

Returns `(ok, ratio, description, studs, stirrups, shear_cap, capital, φvc)`.
"""
function _try_reinforcement(reinforcement::Symbol, vu, fc, b0, d, h,
                             col, opts, moment_results, demand;
                             λ::Float64 = 1.0, φ::Float64 = 0.75, punch_kwargs = (;),
                             max_extent = nothing)
    fyt = opts.stud_material.Fy
    β = punching_β(col.c1, col.c2; shape = col_shape(col) == :circular ? :circular : :rectangular)
    αs = punching_αs(col.position)

    if _is_headed_stud_reinforcement(reinforcement) || reinforcement === :closed_stirrups
        outer = _outer_section_demand(col, demand;
                                      span_axis = get(punch_kwargs, :span_axis, (1.0, 0.0)))
        # Extend the lines until the section d/2 past the last line passes
        # (studs §11.11.5.4, page 208; stirrups §11.11.7.2(b), page 210).
        # Neither clause cuts the zone off at a fraction of the span.
        geom = (c1 = outer.c1, c2 = outer.c2, qu = moment_results.qu, Vu = outer.Vu,
                M_about_x = outer.M_about_x, M_about_y = outer.M_about_y,
                max_extent = max_extent)
    end

    if _is_headed_stud_reinforcement(reinforcement)
        # ── Headed shear studs (§11.11.5) ──
        studs = design_shear_studs(vu, fc, β, αs, b0, d, col.position,
                                    fyt, opts.stud_diameter; λ=λ, φ=φ,
                                    catalog=stud_catalog(reinforcement), geom...)
        chk = check_punching_with_studs(vu, studs; φ=φ)
        desc = "Shear studs: $(studs.n_rails) rails × $(studs.n_studs_per_rail) studs ($(studs.catalog_name))"
        return (ok=chk.ok, ratio=chk.ratio, description=desc,
                studs=studs, stirrups=nothing, shear_cap=nothing, capital=nothing,
                φvc=φ * min(studs.vcs + studs.vs, studs.vc_max))

    elseif reinforcement === :closed_stirrups
        # ── Closed stirrups (§11.11.3) ──
        stirrups = design_closed_stirrups(vu, fc, β, αs, b0, d, col.position,
                                           fyt, opts.stirrup_bar_size; λ=λ, φ=φ, geom...)
        chk = check_punching_with_stirrups(vu, stirrups; φ=φ)
        desc = "Closed stirrups: #$(stirrups.bar_size), $(stirrups.n_legs) legs × $(stirrups.n_lines) lines"
        return (ok=chk.ok, ratio=chk.ratio, description=desc,
                studs=nothing, stirrups=stirrups, shear_cap=nothing, capital=nothing,
                φvc=φ * min(stirrups.vcs + stirrups.vs, stirrups.vc_max))

    elseif reinforcement === :shear_caps
        # ── Shear caps (§13.2.6) ──
        cap = design_shear_cap(col, demand.Vu, demand.Mub, fc, d, h;
                                Muy=demand.Muy, λ=λ, φ=φ, max_projection=h,
                                punch_kwargs=punch_kwargs)
        chk = check_punching_with_shear_cap(cap)
        desc = "Shear cap: h_cap=$(cap.h_cap), extent=$(cap.extent), governing $(cap.governing)"
        return (ok=chk.ok, ratio=chk.ratio, description=desc,
                studs=nothing, stirrups=nothing, shear_cap=cap, capital=nothing,
                φvc=0.0u"psi")  # capacity encoded in cap.ratio

    elseif reinforcement === :column_capitals
        # ── Column capitals (§13.1.2) ──
        capital = design_column_capital(col, demand.Vu, demand.Mub, fc, d, h;
                                         Muy=demand.Muy, λ=λ, φ=φ,
                                         punch_kwargs=punch_kwargs)
        chk = check_punching_with_capital(capital)
        desc = "Column capital: h_cap=$(capital.h_cap), c_eff=$(capital.c1_eff)×$(capital.c2_eff)"
        return (ok=chk.ok, ratio=chk.ratio, description=desc,
                studs=nothing, stirrups=nothing, shear_cap=nothing, capital=capital,
                φvc=0.0u"psi")  # capacity encoded in capital.ratio

    else
        error("Unknown punching_reinforcement: :$reinforcement. " *
              "Use :headed_studs_generic, :headed_studs_incon, :headed_studs_ancon, " *
              ":closed_stirrups, :shear_caps, or :column_capitals.")
    end
end

_reinforcement_not_ok(desc) =
    (ok=false, ratio=Inf, description=desc, studs=nothing, stirrups=nothing,
     shear_cap=nothing, capital=nothing, φvc=0.0u"psi")

"""
    _try_drop_reinforcement(reinforcement, res, fc, col, opts, moment_results, demand, drop;
                            λ, φ) -> NamedTuple

`_try_reinforcement` for a flat-slab column, from the two-section result `res`
of `check_punching`. The drop-edge section must already pass. Studs and
stirrups are designed for the column-face section at `drop.d_total` and
`drop.h_total`. The outermost line is limited so the section `d/2` beyond it
stays inside the drop on its shorter side, `min(a1, a2) − max(c1, c2)/2` from
the column face, where the depth is still `d_total`.
"""
function _try_drop_reinforcement(reinforcement::Symbol, res, fc, col, opts, moment_results,
                                 demand, drop; λ::Float64 = 1.0, φ::Float64 = 0.75,
                                 punch_kwargs = (;))
    res.drop_section.ok || return _reinforcement_not_ok("Punching fails at the drop-panel edge")
    if !(_is_headed_stud_reinforcement(reinforcement) || reinforcement === :closed_stirrups)
        return _reinforcement_not_ok(":$reinforcement is not used with a drop panel")
    end
    face = res.column_section
    reach = min(drop.panel.a_drop_1, drop.panel.a_drop_2) - max(col.c1, col.c2) / 2 -
            drop.d_total / 2
    reach > zero(reach) || return _reinforcement_not_ok("Drop panel too small for reinforcement")
    return _try_reinforcement(reinforcement, face.vu, fc, face.b0, drop.d_total, drop.h_total,
                              col, opts, moment_results, demand; λ = λ, φ = φ,
                              punch_kwargs = punch_kwargs, max_extent = reach)
end

"""
    _merge_reinforcement_result(pr, reinf_result) -> NamedTuple

Merge reinforcement design result into the punching_local entry.
"""
function _merge_reinforcement_result(pr, reinf_result)
    return (ok=true, ratio=reinf_result.ratio, vu=pr.vu,
            φvc=reinf_result.φvc, b0=pr.b0, Jc=pr.Jc,
            studs=reinf_result.studs,
            stirrups=reinf_result.stirrups,
            shear_cap=reinf_result.shear_cap,
            capital=reinf_result.capital,
            moment_transfer=get(pr, :moment_transfer, nothing))
end
