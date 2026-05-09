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
    _update_column_sizes!(columns, column_result, Pu, Mu, c_span_min, material, column_tol; verbose)

Update column dimensions from P-M design results. Returns `true` if any
column size changed by more than `column_tol`.
"""
function _update_column_sizes!(columns, column_result, Pu, Mu, c_span_min, material, column_tol;
                                verbose::Bool = false)
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
            col.base.section = resize_column_with_reinforcement(
                section, col.c1, col.c2, Pu[i], Mu[i], material
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
    _resolve_punching_failures!(punching_local, columns, all_fails, opts, column_opts,
                                 moment_results, secondary_results, h, d, fc, h_increment;
                                 verbose) -> (grew::Bool, h_new)

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

Returns `(columns_grew, updated_h)`.
"""
function _resolve_punching_failures!(punching_local, columns, all_fails, opts, column_opts,
                                      moment_results, secondary_results,
                                      h, d, fc, h_increment;
                                      λ=1.0, φ_shear=0.75, verbose::Bool = false)
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
        ratio = pr.ratio
        vu = pr.vu

        c1_in = ustrip(u"inch", col.c1)
        c2_in = ustrip(u"inch", col.c2)
        β = max(c1_in, c2_in) / max(min(c1_in, c2_in), 1.0)
        αs = punching_αs(col.position)
        b0 = pr.b0

        _col_Mx = !isnothing(secondary_results) ? moment_results.column_moments[i] : nothing
        _col_My = !isnothing(secondary_results) ? secondary_results.column_moments[i] : nothing

        c1_req, c2_req = solve_column_for_punching(
            col, ratio, b0, d;
            shape_constraint = _shape_con, max_ar = _max_ar,
            Mx = _col_Mx, My = _col_My, increment = _c_inc,
        )
        _exceeds_max = max(c1_req, c2_req) > c_max

        if strategy === :reinforce_first
            # ── Try reinforcement first, grow columns only if reinforcement fails ──
            reinf_result = _try_reinforcement(reinforcement, vu, fc, β, αs, b0, d, h,
                                               col, opts, moment_results; λ=λ, φ=φ_shear)

            if reinf_result.ok
                punching_local[i] = _merge_reinforcement_result(pr, vu, b0, reinf_result)
                verbose && @info "Column $i ($(col.position)): $(reinf_result.description)"
            else
                if _exceeds_max
                    h = round_up_thickness(h + h_increment, h_increment)
                    @warn "Column $i: Reinforcement and columns at max. Increasing h → $h"
                    return (true, h)
                else
                    c1_old = col.c1
                    grow_column!(col, col.c1 + _c_inc;
                                 shape_constraint = _shape_con,
                                 max_ar = _max_ar, increment = _c_inc)
                    columns_grew = true
                    verbose && @warn "Column $i: Reinforcement insufficient, growing column: $c1_old → $(col.c1)×$(col.c2)"
                end
            end

        elseif strategy === :reinforce_last
            # ── Grow columns first, reinforce only when columns max out ──
            c1_original = col.c1; c2_original = col.c2

            if !_exceeds_max
                col.c1 = c1_req; col.c2 = c2_req
                columns_grew = true
                verbose && @warn "Column $i punching FAILED (ratio=$(round(ratio, digits=2))). Growing: $c1_original → $(col.c1)×$(col.c2)"
            else
                col.c1 = c1_original; col.c2 = c2_original
                reinf_result = _try_reinforcement(reinforcement, vu, fc, β, αs, b0, d, h,
                                                   col, opts, moment_results; λ=λ, φ=φ_shear)

                if reinf_result.ok
                    punching_local[i] = _merge_reinforcement_result(pr, vu, b0, reinf_result)
                    verbose && @info "Column $i at max size — $(reinf_result.description)"
                else
                    h = round_up_thickness(h + h_increment, h_increment)
                    @warn "Column $i: Max size and reinforcement insufficient. Increasing h → $h"
                    return (true, h)
                end
            end

        else  # :grow_columns (default)
            # ── Only grow columns; no reinforcement ──
            if _exceeds_max
                h = round_up_thickness(h + h_increment, h_increment)
                @warn "Column $i at max size ($c_max), punching_strategy=:grow_columns. Increasing h → $h" position=col.position ratio=ratio
                return (true, h)
            end
            col.c1 = c1_req; col.c2 = c2_req
            columns_grew = true
            verbose && @warn "Column $i punching FAILED (ratio=$(round(ratio, digits=2))). Growing → $(col.c1)×$(col.c2)"
        end
    end

    return (columns_grew, h)
end

"""
    _is_headed_stud_reinforcement(reinforcement::Symbol) -> Bool

Check if the reinforcement type is a headed stud variant (requires a catalog).
"""
_is_headed_stud_reinforcement(r::Symbol) =
    r === :headed_studs_generic || r === :headed_studs_incon || r === :headed_studs_ancon

"""
    _try_reinforcement(reinforcement, vu, fc, β, αs, b0, d, h, col, opts, moment_results;
                       λ, φ) -> NamedTuple

Dispatch to the appropriate reinforcement design function and check.

Returns `(ok, ratio, description, studs, stirrups, shear_cap, capital, φvc)`.
"""
function _try_reinforcement(reinforcement::Symbol, vu, fc, β, αs, b0, d, h,
                             col, opts, moment_results;
                             λ::Float64 = 1.0, φ::Float64 = 0.75)
    fyt = opts.stud_material.Fy

    if _is_headed_stud_reinforcement(reinforcement)
        # ── Headed shear studs (§11.11.5) ──
        cat = stud_catalog(reinforcement)
        studs = design_shear_studs(vu, fc, β, αs, b0, d, col.position,
                                    fyt, opts.stud_diameter; λ=λ, φ=φ,
                                    c1=col.c1, c2=col.c2, qu=moment_results.qu,
                                    catalog=cat)
        chk = check_punching_with_studs(vu, studs; φ=φ)
        desc = "Shear studs: $(studs.n_rails) rails × $(studs.n_studs_per_rail) studs ($(studs.catalog_name))"
        return (ok=chk.ok, ratio=chk.ratio, description=desc,
                studs=studs, stirrups=nothing, shear_cap=nothing, capital=nothing,
                φvc=studs.vcs + studs.vs)

    elseif reinforcement === :closed_stirrups
        # ── Closed stirrups (§11.11.3) ──
        stirrups = design_closed_stirrups(vu, fc, β, αs, b0, d, col.position,
                                           fyt, opts.stirrup_bar_size; λ=λ, φ=φ,
                                           c1=col.c1, c2=col.c2, qu=moment_results.qu)
        chk = check_punching_with_stirrups(vu, stirrups; φ=φ)
        desc = "Closed stirrups: #$(stirrups.bar_size), $(stirrups.n_legs) legs × $(stirrups.n_lines) lines"
        return (ok=chk.ok, ratio=chk.ratio, description=desc,
                studs=nothing, stirrups=stirrups, shear_cap=nothing, capital=nothing,
                φvc=stirrups.vcs + stirrups.vs)

    elseif reinforcement === :shear_caps
        # ── Shear caps (§13.2.6) ──
        # Use Vu and Mub from moment_results for combined stress check
        Vu_force = moment_results.column_shears[1]   # placeholder — per-column below
        Mub_force = moment_results.unbalanced_moments[1]
        cap = design_shear_cap(vu, fc, d, h, col.position, col.c1, col.c2;
                                λ=λ, φ=φ, max_projection=h)
        chk = check_punching_with_shear_cap(cap)
        desc = "Shear cap: h_cap=$(cap.h_cap), extent=$(cap.extent)"
        return (ok=chk.ok, ratio=chk.ratio, description=desc,
                studs=nothing, stirrups=nothing, shear_cap=cap, capital=nothing,
                φvc=0.0u"psi")  # capacity encoded in cap.ratio

    elseif reinforcement === :column_capitals
        # ── Column capitals (§13.1.2) ──
        capital = design_column_capital(vu, fc, d, h, col.position, col.c1, col.c2;
                                         λ=λ, φ=φ)
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

"""
    _merge_reinforcement_result(pr, vu, b0, reinf_result) -> NamedTuple

Merge reinforcement design result into the punching_local entry.
"""
function _merge_reinforcement_result(pr, vu, b0, reinf_result)
    return (ok=true, ratio=reinf_result.ratio, vu=vu,
            φvc=reinf_result.φvc, b0=b0, Jc=pr.Jc,
            studs=reinf_result.studs,
            stirrups=reinf_result.stirrups,
            shear_cap=reinf_result.shear_cap,
            capital=reinf_result.capital)
end

"""
    _run_final_design(method, struc, slab, columns, moment_results, secondary_results,
                       h, d, fc, fy, cover, sw_estimate, n_cols, punching_local,
                       local_to_global, column_opts, column_result, Pu, opts, iter,
                       deflection_result, ρ_prime_est, drop_panel; verbose) -> NamedTuple

Phase 6: post-convergence final design — face-of-support reduction, rebar,
transfer reinforcement, integrity, result building.
"""
function _run_final_design(method, struc, slab, columns, moment_results, secondary_results,
                            h, d, fc, fy, cover, sw_estimate, n_cols, punching_local,
                            local_to_global, column_opts, column_result, Pu, opts, iter,
                            deflection_result, ρ_prime_est, drop_panel, slab_sw, γ_concrete,
                            material;
                            verbose::Bool = false,
                            analysis_cache = nothing)
    # ─── Face-of-Support Moment Reduction (ACI 8.11.6.1) ───
    if method isa EFM
        _c1_ext_min = typemax(typeof(columns[1].c1))
        _c1_int_min = typemax(typeof(columns[1].c1))
        _c2_ext_min = typemax(typeof(columns[1].c2))
        _c2_int_min = typemax(typeof(columns[1].c2))
        _has_ext = false; _has_int = false
        for _col in columns
            if _col.position == :interior
                _col.c1 < _c1_int_min && (_c1_int_min = _col.c1)
                _col.c2 < _c2_int_min && (_c2_int_min = _col.c2)
                _has_int = true
            else
                _col.c1 < _c1_ext_min && (_c1_ext_min = _col.c1)
                _col.c2 < _c2_ext_min && (_c2_ext_min = _col.c2)
                _has_ext = true
            end
        end
        c1_ext = _has_ext ? _c1_ext_min : moment_results.c_avg
        c1_int = _has_int ? _c1_int_min : moment_results.c_avg
        Vu_face = moment_results.Vu_max
        M_unit = unit(moment_results.M0)
        
        # Primary direction reduction (span l1)
        M_neg_ext_reduced = uconvert(M_unit, face_of_support_moment(
            moment_results.M_neg_ext, Vu_face, c1_ext, moment_results.l1))
        M_neg_int_reduced = uconvert(M_unit, face_of_support_moment(
            moment_results.M_neg_int, Vu_face, c1_int, moment_results.l1))

        # For EFM, the frame analysis already produces a consistent set of moments
        # (M_neg_left, M_pos, M_neg_right) that satisfy equilibrium based on centerline
        # geometry. When we reduce support moments to face-of-support, we should NOT
        # recalculate M_pos from M0 because:
        #   1. M0 in MomentAnalysisResult uses clear span (ln) per ACI 8.10.3.2
        #   2. The frame analysis uses centerline span (l1) internally
        #   3. Re-deriving M_pos from clear-span M0 breaks the frame's equilibrium
        # The original M_pos from the frame analysis remains valid and conservative.
        # (ACI 8.11.6.1 only permits reducing support moments, not increasing span moments.)

        verbose && @debug "FACE-OF-SUPPORT MOMENT REDUCTION (ACI 8.11.6.1)" c1_ext=c1_ext c1_int=c1_int M_neg_ext_cl=moment_results.M_neg_ext M_neg_ext_face=M_neg_ext_reduced M_neg_int_cl=moment_results.M_neg_int M_neg_int_face=M_neg_int_reduced

        moment_results = MomentAnalysisResult(
            moment_results.M0, M_neg_ext_reduced, M_neg_int_reduced,
            moment_results.M_pos, moment_results.qu, moment_results.qD, moment_results.qL,
            moment_results.l1, moment_results.l2, moment_results.ln, moment_results.c_avg,
            moment_results.column_moments, moment_results.column_shears,
            moment_results.unbalanced_moments, moment_results.Vu_max;
            pattern_loading = moment_results.pattern_loading,
        )

        # Secondary direction reduction (span l2)
        if !isnothing(secondary_results)
            # Use column dimensions in the secondary span direction (c2)
            c2_ext = _has_ext ? _c2_ext_min : secondary_results.c_avg
            c2_int = _has_int ? _c2_int_min : secondary_results.c_avg
            Vu_face_sec = secondary_results.Vu_max
            
            M_neg_ext_reduced_sec = uconvert(M_unit, face_of_support_moment(
                secondary_results.M_neg_ext, Vu_face_sec, c2_ext, secondary_results.l1))
            M_neg_int_reduced_sec = uconvert(M_unit, face_of_support_moment(
                secondary_results.M_neg_int, Vu_face_sec, c2_int, secondary_results.l1))
            
            # Same reasoning as primary direction: keep original M_pos from frame analysis
            secondary_results = MomentAnalysisResult(
                secondary_results.M0, M_neg_ext_reduced_sec, M_neg_int_reduced_sec,
                secondary_results.M_pos, secondary_results.qu, secondary_results.qD, secondary_results.qL,
                secondary_results.l1, secondary_results.l2, secondary_results.ln, secondary_results.c_avg,
                secondary_results.column_moments, secondary_results.column_shears,
                secondary_results.unbalanced_moments, secondary_results.Vu_max;
                pattern_loading = secondary_results.pattern_loading,
            )
        end
    end

    # ─── Strip Reinforcement Design ───
    verbose && @debug "REINFORCEMENT DESIGN"
    _fea_direct_mode = method isa FEA && method.design_approach != :frame &&
                       analysis_cache isa FEAModelCache && analysis_cache.initialized

    # Per-element rebar field (populated when design_approach == :area)
    _element_rebar_field = nothing

    # Lightweight concrete factor — shared by torsion discount in both directions
    _λ_val = _fea_direct_mode ? Float64(isnothing(opts.λ) ? material.concrete.λ : opts.λ) : 1.0

    rebar_design = if _fea_direct_mode
        # FEA direct extraction — extract CS/MS moments from the shell model.
        _setup = _moment_analysis_setup(struc, slab, columns, h, γ_concrete)
        # Resolve rebar axis (differs from span_axis when rebar_direction is set)
        _rebar_ax = !isnothing(method.rebar_direction) ?
            _resolve_rebar_axis(method, _setup.span_axis) : nothing
        _td = if method.concrete_torsion_discount && method.moment_transform == :wood_armer
            (h_m  = ustrip(u"m", h),
             d_m  = ustrip(u"m", d),
             fc_Pa = ustrip(u"Pa", fc),
             λ     = Float64(_λ_val))
        else
            nothing
        end

        _fea_strips = if method.design_approach == :area
            # Area-based: per-element design → bridge to strip envelope
            _area_moms = _extract_area_design_moments(
                analysis_cache, method, _setup.span_axis;
                torsion_discount=_td, verbose=verbose)

            # Per-element rebar sizing — full field
            _element_rebar_field = _build_element_rebar_field(
                _area_moms, h, d, fc, fy, method.moment_transform;
                verbose=verbose)

            _area_to_strip_envelope(
                _area_moms, analysis_cache, struc, slab, columns,
                _setup.span_axis; rebar_axis=_rebar_ax, verbose=verbose)
        else
            # Strip-based: dispatch to appropriate strip extraction method
            _dispatch_fea_strip_extraction(
                method, analysis_cache, struc, slab, columns,
                _setup.span_axis; rebar_axis=_rebar_ax,
                torsion_discount=_td, verbose=verbose)
        end
        design_strip_reinforcement_fea(_fea_strips, _setup.l2, h, d, fc, fy, cover;
                                        verbose=verbose)
    else
        design_strip_reinforcement(moment_results, columns, h, d, fc, fy, cover; verbose=verbose)
    end

    # Check for inadequate section (Whitney block solution failed)
    if !rebar_design.section_adequate
        verbose && @warn "Rebar design failed: section inadequate for moment demand"
        return (
            converged        = false,
            failure_reason   = "section_inadequate",
            failing_check    = "reinforcement_design",
            h_current        = h,
            needs_more_depth = true,
        )
    end

    # ─── Secondary Direction Reinforcement ───
    _db_inner = 0.625u"inch"
    d_inner = d - _db_inner
    _secondary_element_rebar_field = nothing

    secondary_rebar_design = if !isnothing(secondary_results) && d_inner > 0.0u"inch"
        if _fea_direct_mode
            _sec_setup = _secondary_moment_analysis_setup(struc, slab, columns, h, γ_concrete)
            _sec_rebar_ax = !isnothing(method.rebar_direction) ?
                _resolve_rebar_axis(method, _sec_setup.span_axis) : nothing

            # Torsion discount for secondary direction (uses d_inner)
            _td_sec = if method.concrete_torsion_discount && method.moment_transform == :wood_armer
                (h_m  = ustrip(u"m", h),
                 d_m  = ustrip(u"m", d_inner),
                 fc_Pa = ustrip(u"Pa", fc),
                 λ     = Float64(_λ_val))
            else
                nothing
            end

            _sec_fea_strips = if method.design_approach == :area
                _sec_area_moms = _extract_area_design_moments(
                    analysis_cache, method, _sec_setup.span_axis;
                    torsion_discount=_td_sec, verbose=verbose)

                # Per-element rebar sizing — secondary direction
                _secondary_element_rebar_field = _build_element_rebar_field(
                    _sec_area_moms, h, d_inner, fc, fy, method.moment_transform;
                    verbose=verbose)

                _area_to_strip_envelope(
                    _sec_area_moms, analysis_cache, struc, slab, columns,
                    _sec_setup.span_axis; rebar_axis=_sec_rebar_ax, verbose=verbose)
            else
                _dispatch_fea_strip_extraction(
                    method, analysis_cache, struc, slab, columns,
                    _sec_setup.span_axis; rebar_axis=_sec_rebar_ax,
                    torsion_discount=_td_sec, verbose=verbose)
            end
            design_strip_reinforcement_fea(_sec_fea_strips, _sec_setup.l2, h, d_inner, fc, fy, cover;
                                            verbose=verbose)
        else
            design_strip_reinforcement(secondary_results, columns, h, d_inner, fc, fy, cover; verbose=verbose)
        end
    else
        nothing
    end

    # Check secondary direction for inadequate section
    if !isnothing(secondary_rebar_design) && !secondary_rebar_design.section_adequate
        verbose && @warn "Secondary rebar design failed: section inadequate for moment demand"
        return (
            converged        = false,
            failure_reason   = "section_inadequate",
            failing_check    = "reinforcement_design_secondary",
            h_current        = h,
            needs_more_depth = true,
        )
    end

    # ─── Moment Transfer Reinforcement (ACI 8.4.2.3) ───
    transfer_results = Union{Nothing, NamedTuple}[nothing for _ in 1:n_cols]
    for (i, col) in enumerate(columns)
        Mub_i = moment_results.unbalanced_moments[i]
        abs(ustrip(kip * u"ft", Mub_i)) < 1e-6 && continue

        bb = col.c2 + 3 * h
        b1 = col.c1 + d; b2 = col.c2 + d
        γf_val = gamma_f(b1, b2)
        As_transfer = transfer_reinforcement(abs(Mub_i), γf_val, bb, d, fc, fy)

        # Check for inadequate section in transfer reinforcement
        if isinf(As_transfer)
            verbose && @warn "Transfer reinforcement failed: section inadequate at column $i"
            return (
                converged        = false,
                failure_reason   = "section_inadequate",
                failing_check    = "transfer_reinforcement",
                h_current        = h,
                needs_more_depth = true,
            )
        end

        cs_neg_idx = col.position == :interior ? 3 : 1
        As_provided_cs = rebar_design.column_strip_reinf[cs_neg_idx].As_provided
        selected = select_bars(As_provided_cs, rebar_design.column_strip_width)
        Ab = bar_area(selected.bar_size)

        transfer = additional_transfer_bars(As_transfer, As_provided_cs, bb,
                                            rebar_design.column_strip_width, Ab)
        transfer_results[i] = transfer
        if verbose && transfer.n_bars_additional > 0
            @debug "MOMENT TRANSFER (ACI 8.4.2.3) — Column $i ($(col.position))" Mub=Mub_i γf=round(γf_val, digits=3) bb=bb As_transfer=As_transfer As_within_bb=transfer.As_within_bb n_additional=transfer.n_bars_additional
        end
    end

    # ─── Structural Integrity Reinforcement (ACI 8.7.4.2) ───
    cell = struc.cells[first(slab.cell_indices)]
    integrity = integrity_reinforcement(cell.area, cell.sdl + sw_estimate, cell.live_load, fy)
    cs_pos_reinf = rebar_design.column_strip_reinf[2]
    integrity_check = check_integrity_reinforcement(cs_pos_reinf.As_provided, integrity.As_integrity)

    verbose && @debug "INTEGRITY REINFORCEMENT (ACI 8.7.4.2)" As_integrity=integrity.As_integrity As_bottom=cs_pos_reinf.As_provided ok=integrity_check.ok utilization=round(integrity_check.utilization, digits=2)

    if !integrity_check.ok
        cs_width = rebar_design.column_strip_width
        bumped = select_bars(integrity.As_integrity, cs_width)
        rebar_design.column_strip_reinf[2] = StripReinforcement(
            :pos, cs_pos_reinf.Mu, cs_pos_reinf.As_reqd, cs_pos_reinf.As_min,
            uconvert(u"m^2", bumped.As_provided), bumped.bar_size,
            uconvert(u"m", bumped.spacing), bumped.n_bars,
            true  # section_adequate
        )
        verbose && @debug "Integrity reinforcement governs — bumped midspan bottom steel" As_before=cs_pos_reinf.As_provided As_after=bumped.As_provided As_integrity=integrity.As_integrity bar_size=bumped.bar_size n_bars=bumped.n_bars
    end

    # ─── Update Cell Self-Weights ───
    sw_final = slab_sw(h)
    for cell_idx in slab.cell_indices
        struc.cells[cell_idx].self_weight = sw_final
    end

    # ─── Update Asap Model ───
    update_asap_column_sections!(struc, columns, column_opts.material)

    if verbose
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "DESIGN CONVERGED ✓"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Final slab" h=h sw=sw_final method=method_name(method)
        @debug "Final columns" sizes=["$(c.c1)×$(c.c2)" for c in columns]
        @debug "Iterations" n=iter
    end

    punching_results = Dict{Int, NamedTuple}(
        local_to_global[i] => punching_local[i] for i in 1:n_cols
    )

    slab_result = build_slab_result(
        h, sw_final, moment_results, rebar_design,
        deflection_result, punching_results;
        γ_concrete = γ_concrete * GRAVITY,
        secondary_rebar_design = secondary_rebar_design,
    )

    column_results = build_column_results(
        struc, columns, column_result,
        Pu, moment_results.unbalanced_moments, punching_results
    )

    return (
        converged=true, failure_reason="", failing_check="",
        iterations=iter, h_final=h,
        pattern_loading=moment_results.pattern_loading,
        slab_result=slab_result, column_results=column_results,
        drop_panel=drop_panel, integrity=integrity,
        integrity_check=integrity_check, transfer_results=transfer_results,
        ρ_prime=ρ_prime_est,
        element_rebar_field=_element_rebar_field,
        secondary_element_rebar_field=_secondary_element_rebar_field,
    )
end

# =============================================================================
# Main Pipeline Function
# =============================================================================

# Register trace contract for size_flat_plate!
TRACE_REGISTRY[(:size_flat_plate!, :slab)] =
    TracedFunctionMeta(:size_flat_plate!, :slab,
                       [:enter, :exit, :decision, :iteration, :fallback, :failure], nothing,
                       @__FILE__, @__LINE__)

"""
    size_flat_plate!(struc, slab, column_opts; method, opts, max_iterations, verbose)

Design a flat plate slab with integrated column P-M design.

# Analysis Methods
- `DDM()` - Direct Design Method (ACI 318 coefficient-based) - default
- `DDM(:simplified)` - Modified DDM with simplified coefficients
- `EFM()` - Equivalent Frame Method (ASAP stiffness analysis)

# Two-Phase Design Workflow (mirrors engineering practice)
1. Setup: identify columns, compute Pu, initial h from ACI Table 8.3.1.1
2. **Phase A — Depth convergence** (iterate until stable):
   a. Moment analysis (DDM/EFM/FEA) → MomentAnalysisResult
   b. Column P-M design → update column sizes → re-analyse if changed
   c. Two-way deflection check → bump h if failed
   d. One-way shear check → bump h if failed
   e. Flexural adequacy check → bump h if failed
3. **Phase B — Punching resolution** (at converged h):
   a. Punching shear check at each column
   b. Resolve failures via strategy (:grow_columns / :reinforce_last / :reinforce_first)
   c. Re-analyse if columns grew; bump h only as last resort
4. **Phase C — Final design**: rebar detailing, transfer reinforcement, integrity steel

An outer loop ties A→B→C: if Phase B or C signals "need more depth",
h is bumped and Phase A restarts with the new floor.

# Arguments
- `struc::BuildingStructure`: Structure with skeleton, cells, columns
- `slab::Slab`: Slab to design (references cells via cell_indices)
- `column_opts::ConcreteColumnOptions`: Options for column P-M optimization

# Keyword Arguments
- `method::FlatPlateAnalysisMethod = DDM()`: Analysis method
- `opts::FlatPlateOptions = FlatPlateOptions()`: Design options
- `max_iterations::Int = 10`: Maximum iterations per phase (each phase gets full budget)
- `column_tol::Float64 = 0.05`: Column size change tolerance
- `h_increment::Length = 0.5u"inch"`: Thickness rounding increment
- `verbose::Bool = false`: Enable debug logging

# Returns
Named tuple with fields:
- `slab_result::FlatPlatePanelResult`: Panel design result (thickness, reinforcement, deflection)
- `column_results::Dict`: Column P-M results keyed by global column index
- `drop_panel::Union{Nothing, DropPanelGeometry}`: Drop panel geometry (if flat slab)
- `integrity`: Structural integrity reinforcement demand (ACI 8.7.4.2)
- `integrity_check`: Pass/fail for integrity reinforcement vs provided bottom steel
- `transfer_results::Vector{Union{Nothing, NamedTuple}}`: Moment transfer reinforcement at each column (ACI 8.4.2.3)
- `ρ_prime::Float64`: Estimated compression reinforcement ratio for long-term deflection

# Example
```julia
result = size_flat_plate!(struc, slab, ConcreteColumnOptions())
result = size_flat_plate!(struc, slab, col_opts; method=EFM(), verbose=true)
```
"""
function size_flat_plate!(
    struc,
    slab,
    column_opts;
    method::FlatPlateAnalysisMethod = DDM(),
    opts::FlatPlateOptions = FlatPlateOptions(),
    max_iterations::Int = 10,
    column_tol::Float64 = 0.05,
    h_increment::Length = 0.5u"inch",
    verbose::Bool = false,
    _col_cache = nothing,
    slab_idx::Int = 0,
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    fire_rating::Real = 0.0,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    # ─── PixelFrame: rejected same as steel (validation + design_workflow should catch first) ───
    if column_opts isa PixelFrameColumnOptions
        throw(ArgumentError(
            "Flat plate/slab requires reinforced concrete columns. " *
            "PixelFrame columns are not supported for beamless slab systems."))
    end

    # ─── RuleOfThumb dispatch: single-pass at ACI min thickness ───
    if method isa RuleOfThumb
        return check_flat_plate_at_thickness!(struc, slab, column_opts;
            method=method, opts=opts, verbose=verbose,
            _col_cache=_col_cache, slab_idx=slab_idx, drop_panel=drop_panel)
    end

    # =========================================================================
    # PHASE 1: SETUP
    # =========================================================================
    
    # Extract material parameters
    material = opts.material
    fc = material.concrete.fc′
    fy = material.rebar.Fy
    γ_concrete = material.concrete.ρ
    cover = opts.cover
    bar_size = opts.bar_size
    φ_flexure = opts.φ_flexure
    φ_shear = opts.φ_shear
    λ = isnothing(opts.λ) ? material.concrete.λ : opts.λ
    Es = material.rebar.E
    wc_pcf = ustrip(pcf, γ_concrete)          # mass density → pcf (≈ 150 for NWC)
    Ecs = Ec(fc, wc_pcf)                       # ACI 19.2.2.1.a: 33 × wc^1.5 × √f'c
    
    # Slab geometry
    slab_cell_indices = Set(slab.cell_indices)
    ln_max = max(slab.spans.primary, slab.spans.secondary)
    
    # Self-weight helper
    slab_sw(h) = slab_self_weight(h, γ_concrete)
    
    if verbose
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "FLAT PLATE DESIGN - $(method_name(method)) (ACI 318-11)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Panel geometry" primary=slab.spans.primary secondary=slab.spans.secondary n_cells=length(slab.cell_indices)
        @debug "Materials" fc=fc fy=fy wc=uconvert(pcf, γ_concrete)
    end
    
    # =========================================================================
    # PHASE 2: IDENTIFY SUPPORTING COLUMNS
    # =========================================================================
    
    columns = find_supporting_columns(struc, slab_cell_indices)
    n_cols = length(columns)
    
    if n_cols == 0
        error("No supporting columns found for slab. Ensure tributary areas are computed.")
    end
    
    if verbose
        @debug "SUPPORTING COLUMNS" n_cols=n_cols
        for (i, col) in enumerate(columns)
            trib_m2 = sum(values(col.tributary_cell_areas); init=0.0)
            @debug "Column $i" vertex=col.vertex_idx position=col.position A_trib_m²=trib_m2
        end
    end
    
    # Check method applicability — auto-fallback to FEA if DDM/EFM not permitted
    try
        enforce_method_applicability(method, struc, slab, columns; verbose=verbose, ρ_concrete=γ_concrete)
    catch e
        if e isa DDMApplicabilityError || e isa EFMApplicabilityError
            old_name = method_name(method)
            viol_str = join(e.violations, "; ")
            @warn "$(old_name) not applicable — falling back to FEA" violations=viol_str
            method = FEA()
            enforce_method_applicability(method, struc, slab, columns; verbose=verbose, ρ_concrete=γ_concrete)
        else
            rethrow()
        end
    end
    
    # =========================================================================
    # PHASE 3: INITIAL ESTIMATES
    # =========================================================================
    
    has_edge = any(col.position != :interior for col in columns)
    if !isnothing(opts.min_h)
        h = opts.min_h  # User override — bypass ACI minimum
    elseif !isnothing(drop_panel)
        # Flat slab: reduced minimum thickness (ACI Table 8.3.1.1 Row 2)
        h = min_thickness(FlatSlab(), ln_max; discontinuous_edge=has_edge)
    else
        h = min_thickness(FlatPlate(), ln_max; discontinuous_edge=has_edge)
    end

    # Fire minimum thickness (ACI 216.1-14 Table 4.2) — takes precedence if larger
    if fire_rating > 0
        agg = opts.material.concrete.aggregate_type
        h_fire = min_thickness_fire(fire_rating, agg)
        h = max(h, h_fire)
    end
    h_initial = h
    sw_estimate = slab_sw(h)
    
    # For flat slab, re-check drop panel depth and extent after initial h
    # ACI 8.2.4(a): h_drop ≥ h/4
    # ACI 8.2.4(b): a_drop ≥ l/6
    if !isnothing(drop_panel)
        needs_resize = false
        h_drop = drop_panel.h_drop
        a1 = drop_panel.a_drop_1
        a2 = drop_panel.a_drop_2
        
        # Check depth
        if h_drop < h / 4
            h_drop = auto_size_drop_depth(h)
            needs_resize = true
        end
        
        # Check extent (recalculate from slab spans if not explicitly overridden)
        # Note: if a_drop_ratio was provided, we should respect it.
        # For simplicity in the pipeline, we ensure minimum ACI compliance.
        l1 = slab.spans.primary
        l2 = slab.spans.secondary
        min_a1 = l1 / 6
        min_a2 = l2 / 6
        
        if a1 < min_a1
            a1 = min_a1
            needs_resize = true
        end
        if a2 < min_a2
            a2 = min_a2
            needs_resize = true
        end
        
        if needs_resize
            drop_panel = DropPanelGeometry(h_drop, a1, a2)
            verbose && @debug "Drop panel resized for ACI compliance" h_drop=h_drop a1=a1 a2=a2 h=h
        end
    end
    
    bar_dia = bar_diameter(bar_size)
    c_span_min = estimate_column_size_from_span(ln_max)
    
    # Initialize column sizes
    for col in columns
        if isnothing(col.c1) || col.c1 <= 0u"inch"
            col.c1 = c_span_min
            col.c2 = c_span_min
        end
    end
    
    if verbose
        @debug "INITIAL ESTIMATES" h_min=h sw=sw_estimate c_span_min=c_span_min
    end
    
    # =========================================================================
    # PHASE 4: COMPUTE INITIAL AXIAL LOADS
    # =========================================================================
    
    Pu = compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)
    
    if verbose
        @debug "COLUMN AXIAL LOADS (Pu = max(1.2D+1.6L, 1.4D))"
        for (i, col) in enumerate(columns)
            @debug "Column $i ($(col.position))" Pu=Pu[i]*kip
        end
    end
    
    # =========================================================================
    # PHASE 4b: PRE-BUILD P-M CACHE (hoisted outside iteration loop)
    # =========================================================================
    
    # Reuse shared cache from size_slabs! when available (avoids duplicate P-M diagrams).
    if isnothing(_col_cache)
        _col_cat = isnothing(column_opts.custom_catalog) ?
            rc_column_catalog(column_opts.section_shape, column_opts.catalog) :
            column_opts.custom_catalog
        
        _col_checker = ACIColumnChecker(;
            include_slenderness = column_opts.include_slenderness,
            include_biaxial = column_opts.include_biaxial,
            fy_ksi = ustrip(ksi, column_opts.rebar_material.Fy),
            Es_ksi = ustrip(ksi, column_opts.rebar_material.E),
            max_depth = column_opts.max_depth,
        )
        
        _col_cache = create_cache(_col_checker, length(_col_cat))
        precompute_capacities!(_col_checker, _col_cache, _col_cat, column_opts.material, column_opts.objective)
    end
    
    # =========================================================================
    # PHASE 5: ITERATIVE DESIGN LOOP
    # =========================================================================
    
    # Precompute local→global column index mapping via objectid (O(n) vs O(n²) findfirst)
    _col_id_to_idx = Dict{UInt64, Int}(objectid(struc.columns[i]) => i for i in eachindex(struc.columns))
    local_to_global = [_col_id_to_idx[objectid(col)] for col in columns]
    
    # Analysis cache: pull from struc._analysis_caches if slab_idx is known,
    # otherwise create a local cache.  This allows caches to persist across
    # design_building calls (parametric studies, method comparisons).
    analysis_cache = if slab_idx > 0 && hasproperty(struc, :_analysis_caches)
        slab_caches = get!(struc._analysis_caches, slab_idx, Dict{Symbol, Any}())
        if method isa EFM && method.solver == :asap
            get!(slab_caches, :efm, EFMModelCache())
        elseif method isa FEA
            get!(slab_caches, :fea, FEAModelCache())
        else
            nothing
        end
    else
        if method isa EFM && method.solver == :asap
            EFMModelCache()
        elseif method isa FEA
            FEAModelCache()
        else
            nothing
        end
    end
    
    moment_results = nothing
    secondary_results = nothing
    column_result = nothing
    # Use local Vector for punching results (convert to Dict at output boundary)
    punching_local = Vector{NamedTuple}(undef, n_cols)
    # Punching geometry cache: keyed on (c1_m, c2_m, d_m, position, shape)
    # Cleared when h changes (d changes) — column size changes auto-miss
    _punch_geom_cache = Dict{Tuple{Float64,Float64,Float64,Symbol,Symbol}, NamedTuple}()
    
    # Preallocate column geometries (only column height matters; updated if it changes)
    geometries = [
        ConcreteMemberGeometry(col.base.L; Lu=col.base.L, k=1.0, braced=true)
        for col in columns
    ]
    
    # Preallocate Mu and Mu_secondary buffers (reused each iteration)
    Mu = Vector{Float64}(undef, n_cols)
    Mu_secondary = Vector{Float64}(undef, n_cols)
    
    # ACI 318-11 §8.10.4: distribute unbalanced moment between columns above
    # and below the slab in proportion to their flexural stiffnesses.
    # Factor = K_below / (K_below + K_above); 1.0 when no column above (roof/single-story).
    _dist_factors = column_moment_distribution_factors(struc, columns, column_opts)
    if verbose && any(f -> f < 1.0, _dist_factors)
        @debug "Column moment distribution factors (§8.10.4)" factors=_dist_factors
    end
    
    # Track which check is currently failing (for structured failure diagnostics)
    last_failing_check = ""
    total_iters = 0   # accumulate across all phases for the result tuple
    
    d = effective_depth(h; cover=cover, bar_diameter=bar_dia)
    _prev_h = h  # Track h to avoid redundant recomputation
    
    # Shared mutable state across phases
    deflection_result = nothing
    ρ_prime_est = 0.0
    
    _slab_id = "slab_$(slab_idx)"
    emit!(tc, :slab, "size_flat_plate!", _slab_id, :enter;
          method=method_name(method),
          n_columns=n_cols,
          h_initial=string(h_initial),
          primary_span=string(slab.spans.primary),
          secondary_span=string(slab.spans.secondary),
          punching_strategy=string(opts.punching_strategy),
          has_drop_panel=!isnothing(drop_panel))

    # =====================================================================
    # OUTER LOOP: ties Phase A → B → C together.
    # Phase B (punching) or C (rebar) may signal "need more depth", which
    # bumps h and restarts from Phase A.  This is the rare last-resort path.
    # =====================================================================
    for outer in 1:max_iterations
        
        # =================================================================
        # PHASE A — DEPTH CONVERGENCE
        # Iterate h until deflection, one-way shear, flexural adequacy,
        # and column P-M all stabilize.  No punching check here.
        # =================================================================
        depth_converged = false
        
        for iter_a in 1:max_iterations
            total_iters += 1

            # Guard against runaway thickness (h > ln/10 is impractical)
            h_max = ln_max / 10
            if h > h_max
                @warn "Slab thickness h=$h exceeds practical limit (ln/10 = $h_max). Aborting."
                break
            end
            
            if verbose
                @debug "═══════════════════════════════════════════════════════════════════"
                @debug "PHASE A — DEPTH CONVERGENCE  (outer=$outer, iter=$iter_a, h=$h)"
                @debug "═══════════════════════════════════════════════════════════════════"
            end
            
            # ── Recompute h-dependent quantities only when h actually changed ──
            if h != _prev_h
                d = effective_depth(h; cover=cover, bar_diameter=bar_dia)
                sw_estimate = slab_sw(h)
                Pu = compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)
                _prev_h = h
            end
            
            # ─── Drop panel depth and extent re-check ───
            if !isnothing(drop_panel)
                needs_resize = false
                h_drop = drop_panel.h_drop
                a1 = drop_panel.a_drop_1
                a2 = drop_panel.a_drop_2
                
                if h_drop < h / 4
                    h_drop = auto_size_drop_depth(h)
                    needs_resize = true
                end
                
                l1 = slab.spans.primary
                l2 = slab.spans.secondary
                min_a1 = l1 / 6
                min_a2 = l2 / 6
                
                if a1 < min_a1
                    a1 = min_a1
                    needs_resize = true
                end
                if a2 < min_a2
                    a2 = min_a2
                    needs_resize = true
                end
                
                if needs_resize
                    drop_panel = DropPanelGeometry(h_drop, a1, a2)
                    verbose && @debug "Drop panel re-sized for ACI compliance" h_drop=h_drop a1=a1 a2=a2 h=h
                end
            end
            
            # ─── A1: Moment Analysis ───
            _βt = 0.0
            if !isnothing(opts.edge_beam_βt)
                _βt = opts.edge_beam_βt
            elseif opts.has_edge_beam
                _c1_avg = sum(col.c1 for col in columns) / length(columns)
                _c2_avg = sum(col.c2 for col in columns) / length(columns)
                _βt = edge_beam_βt(h, _c1_avg, _c2_avg, slab.spans.secondary)
            end
            
            moment_results = run_moment_analysis(
                method, struc, slab, columns, h, fc, Ecs, γ_concrete;
                ν_concrete = material.concrete.ν,
                verbose=verbose,
                efm_cache = analysis_cache isa EFMModelCache ? analysis_cache : nothing,
                cache     = analysis_cache isa FEAModelCache ? analysis_cache : nothing,
                drop_panel = drop_panel,
                βt = _βt,
                col_I_factor = opts.col_I_factor,
            )
            
            secondary_results = if method isa FEA && !isnothing(moment_results.secondary)
                moment_results.secondary
            else
                run_secondary_moment_analysis(
                    method, struc, slab, columns, h, fc, Ecs, γ_concrete;
                    verbose=verbose, drop_panel=drop_panel, βt=_βt,
                )
            end
            
            check_pattern_loading_requirement(moment_results; verbose=verbose)
            
            # Column design moments = unbalanced moments × distribution factor
            # (ACI 318-11 §13.5.3.2 + §8.10.4)
            @inbounds for i in eachindex(Mu)
                Mu[i] = ustrip(kip*u"ft", moment_results.unbalanced_moments[i]) * _dist_factors[i]
            end
            if !isnothing(secondary_results)
                @inbounds for i in 1:n_cols
                    Mu_secondary[i] = ustrip(kip*u"ft", secondary_results.unbalanced_moments[i]) * _dist_factors[i]
                end
            else
                fill!(Mu_secondary, 0.0)
            end
            
            # ─── A2: Column P-M Design ───
            verbose && @debug "COLUMN P-M DESIGN"
            
            local column_result
            try
                column_result = size_columns(Pu, Mu, geometries, column_opts;
                                              Muy=Mu_secondary, cache=_col_cache)
            catch e
                e isa ArgumentError || rethrow()
                verbose && @warn "Column P-M infeasible at h=$h: $(e.msg)"
                @warn "Column P-M design infeasible — no catalog section satisfies demand" h=h
                return (
                    converged        = false,
                    failure_reason   = "column_pm_infeasible",
                    failing_check    = "column_pm",
                    iterations       = total_iters,
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
            
            columns_changed = _update_column_sizes!(
                columns, column_result, Pu, Mu, c_span_min, material, column_tol;
                verbose=verbose
            )
            
            if columns_changed
                verbose && @debug "⟳ Column sizes changed, re-running analysis..."
                last_failing_check = "column_pm"
                continue
            end
            
            # ─── A3: Two-Way Deflection Check ───
            verbose && @debug "TWO-WAY DEFLECTION CHECK (ACI 24.2)"
            
            _l2_defl = moment_results.l2
            ρ_prime_est = try
                _As_neg = required_reinforcement(
                    0.75 * moment_results.M_neg_int, _l2_defl / 2, d, fc, fy
                )
                _As_neg = max(_As_neg, minimum_reinforcement(_l2_defl / 2, h, fy))
                0.5 * ustrip(u"inch^2", _As_neg) /
                    (ustrip(u"inch", _l2_defl / 2) * ustrip(u"inch", d))
            catch e
                @debug "ρ' estimation failed, using 0.0" exception=(e, catch_backtrace())
                0.0
            end
            
            verbose && @debug "ρ' estimate for long-term deflection" ρ_prime=round(ρ_prime_est, digits=5)
            
            _Ie_method = method isa FEA ? method.deflection_Ie_method : :branson
            _defl_ok = try
                deflection_result = if !isnothing(drop_panel)
                    check_two_way_deflection(
                        moment_results, h, d, fc, fy, Es, Ecs, slab.spans, γ_concrete, columns,
                        drop_panel;
                        verbose=verbose, limit_type=opts.deflection_limit,
                        ρ_prime=ρ_prime_est,
                        deflection_Ie_method=_Ie_method,
                    )
                else
                    check_two_way_deflection(
                        moment_results, h, d, fc, fy, Es, Ecs, slab.spans, γ_concrete, columns;
                        verbose=verbose, limit_type=opts.deflection_limit,
                        ρ_prime=ρ_prime_est,
                        deflection_Ie_method=_Ie_method,
                    )
                end
                deflection_result.ok
            catch e
                @debug "Deflection check (primary) failed" exception=(e, catch_backtrace())
                false
            end
            
            if !_defl_ok
                h = round_up_thickness(h + h_increment, h_increment)
                verbose && @warn "Deflection FAILED (primary). Increasing h → $h"
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :iteration;
                      phase="A", check="two_way_deflection", passed=false, h_new=string(h))
                last_failing_check = "two_way_deflection"
                continue
            end
            
            # ─── A3b: Secondary Direction Deflection Check ───
            # The primary check uses primary-direction moments for Ie.  For slabs
            # where the secondary span is longer or has higher cracking, the
            # secondary direction may govern.  Run a separate check with swapped
            # spans and secondary-direction moments.
            if !isnothing(secondary_results)
                verbose && @debug "SECONDARY DEFLECTION CHECK (ACI 24.2)"
                _sec_spans = (primary = slab.spans.secondary, secondary = slab.spans.primary)
                # Build a lightweight proxy with secondary moments + shared loads
                _sec_proxy = (
                    M_pos     = secondary_results.M_pos,
                    M_neg_ext = secondary_results.M_neg_ext,
                    M_neg_int = secondary_results.M_neg_int,
                    qu        = moment_results.qu,
                    qD        = moment_results.qD,
                    qL        = moment_results.qL,
                    # FEA: same 2D panel displacement, but Ie uses secondary moments
                    fea_Δ_panel = hasproperty(moment_results, :fea_Δ_panel) ?
                                  moment_results.fea_Δ_panel : nothing,
                )
                _sec_defl_ok = try
                    _sec_defl = check_two_way_deflection(
                        _sec_proxy, h, d, fc, fy, Es, Ecs, _sec_spans, γ_concrete, columns;
                        verbose=verbose, limit_type=opts.deflection_limit,
                        ρ_prime=ρ_prime_est,
                        deflection_Ie_method=_Ie_method,
                    )
                    _sec_defl.ok
                catch e
                    @debug "Deflection check (secondary) failed" exception=(e, catch_backtrace())
                    false
                end
                if !_sec_defl_ok
                    h = round_up_thickness(h + h_increment, h_increment)
                    verbose && @warn "Deflection FAILED (secondary direction). Increasing h → $h"
                    last_failing_check = "two_way_deflection_secondary"
                    continue
                end
            end
            
            # ─── A4: One-Way Shear Check ───
            verbose && @debug "ONE-WAY SHEAR CHECK (ACI 22.5)"
            
            # Extract FEA-based one-way shear demand when available
            _fea_Vu = if analysis_cache isa FEAModelCache && analysis_cache.initialized
                _span_ax = _get_span_axis(slab)
                _extract_fea_one_way_shear(analysis_cache, columns, _span_ax, d; verbose=verbose)
            else
                nothing
            end
            shear_result = check_one_way_shear(moment_results, d, fc;
                verbose=verbose, λ=λ, φ_shear=φ_shear, fea_Vu=_fea_Vu)
            
            if !shear_result.ok
                h = round_up_thickness(h + h_increment, h_increment)
                verbose && @warn "One-way shear FAILED. Increasing h → $h"
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :iteration;
                      phase="A", check="one_way_shear", passed=false, h_new=string(h))
                last_failing_check = "one_way_shear"
                continue
            end
            
            # ─── A5: Flexural Adequacy (Tension-Controlled) ───
            verbose && @debug "FLEXURAL ADEQUACY CHECK (ACI 21.2.2)"
            
            flexure_result = check_flexural_adequacy(moment_results, columns, d, fc; verbose=verbose)
            
            if !flexure_result.ok
                h = round_up_thickness(h + h_increment, h_increment)
                verbose && @warn "Flexure not tension-controlled (Rn/Rn_max=$(round(flexure_result.max_ratio, digits=2)) at $(flexure_result.governing_strip)). Increasing h → $h"
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :iteration;
                      phase="A", check="flexural_adequacy", passed=false,
                      h_new=string(h), ratio=flexure_result.max_ratio,
                      governing_strip=string(flexure_result.governing_strip))
                last_failing_check = "flexural_adequacy"
                continue
            end
            
            # All depth-driven checks pass — h is stable
            depth_converged = true
            verbose && @debug "Phase A converged: h=$h (iter=$iter_a)"
            emit!(tc, :slab, "size_flat_plate!", _slab_id, :decision;
                  phase="A", outcome="converged", h=string(h), iterations=iter_a)
            break
        end  # Phase A loop
        
        if !depth_converged
            @warn "Phase A (depth) did not converge in $max_iterations iterations" h=h last_check=last_failing_check
            return (
                converged       = false,
                failure_reason  = "non_convergence",
                failing_check   = last_failing_check,
                iterations      = total_iters,
                h_final         = h,
                pattern_loading = false,
                slab_result     = nothing,
                column_results  = nothing,
                drop_panel      = drop_panel,
                integrity       = nothing,
                integrity_check = nothing,
                transfer_results = nothing,
                ρ_prime         = nothing,
            )
        end
        
        # =================================================================
        # PHASE B — PUNCHING RESOLUTION (h is locked)
        # Resolve punching via column growth and/or shear studs.
        # Column growth changes stiffness → re-run moments each iteration.
        # h is bumped only as a true last resort (breaks to outer loop).
        # =================================================================
        punching_resolved = false
        h_before_punch = h  # detect if _resolve_punching_failures! bumped h
        
        for iter_b in 1:max_iterations
            total_iters += 1
            
            if verbose
                @debug "═══════════════════════════════════════════════════════════════════"
                @debug "PHASE B — PUNCHING RESOLUTION  (outer=$outer, iter=$iter_b)"
                @debug "═══════════════════════════════════════════════════════════════════"
            end
            
            # ── B1: Re-run moment analysis (column sizes may have changed) ──
            _βt = 0.0
            if !isnothing(opts.edge_beam_βt)
                _βt = opts.edge_beam_βt
            elseif opts.has_edge_beam
                _c1_avg = sum(col.c1 for col in columns) / length(columns)
                _c2_avg = sum(col.c2 for col in columns) / length(columns)
                _βt = edge_beam_βt(h, _c1_avg, _c2_avg, slab.spans.secondary)
            end
            
            moment_results = run_moment_analysis(
                method, struc, slab, columns, h, fc, Ecs, γ_concrete;
                ν_concrete = material.concrete.ν,
                verbose=verbose,
                efm_cache = analysis_cache isa EFMModelCache ? analysis_cache : nothing,
                cache     = analysis_cache isa FEAModelCache ? analysis_cache : nothing,
                drop_panel = drop_panel,
                βt = _βt,
                col_I_factor = opts.col_I_factor,
            )
            
            secondary_results = if method isa FEA && !isnothing(moment_results.secondary)
                moment_results.secondary
            else
                run_secondary_moment_analysis(
                    method, struc, slab, columns, h, fc, Ecs, γ_concrete;
                    verbose=verbose, drop_panel=drop_panel, βt=_βt,
                )
            end
            
            # Update Mu buffers — unbalanced × distribution (§13.5.3.2 + §8.10.4)
            @inbounds for i in eachindex(Mu)
                Mu[i] = ustrip(kip*u"ft", moment_results.unbalanced_moments[i]) * _dist_factors[i]
            end
            if !isnothing(secondary_results)
                @inbounds for i in 1:n_cols
                    Mu_secondary[i] = ustrip(kip*u"ft", secondary_results.unbalanced_moments[i]) * _dist_factors[i]
                end
            else
                fill!(Mu_secondary, 0.0)
            end
            
            # Re-run column P-M with updated moments (column sizes may have grown)
            try
                column_result = size_columns(Pu, Mu, geometries, column_opts;
                                              Muy=Mu_secondary, cache=_col_cache)
            catch e
                e isa ArgumentError || rethrow()
                verbose && @warn "Column P-M infeasible in Phase B at h=$h: $(e.msg)"
                @warn "Column P-M design infeasible in Phase B" h=h
                return (
                    converged        = false,
                    failure_reason   = "column_pm_infeasible",
                    failing_check    = "column_pm",
                    iterations       = total_iters,
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
            _update_column_sizes!(
                columns, column_result, Pu, Mu, c_span_min, material, column_tol;
                verbose=verbose
            )
            
            # ── B2: Punching shear check ──
            verbose && @debug "PUNCHING SHEAR CHECK (ACI 22.6)"
            
            n_cols_ps = length(columns)
            if !isnothing(drop_panel)
                h_total = total_depth_at_drop(h, drop_panel)
                d_total = effective_depth(h_total; cover=cover, bar_diameter=bar_dia)
                
                for i in 1:n_cols_ps
                    punching_local[i] = check_punching(
                        columns[i], moment_results.column_shears[i],
                        moment_results.unbalanced_moments[i],
                        h, d, h_total, d_total, fc, drop_panel;
                        qu=moment_results.qu,
                        verbose=false, col_idx=i, λ=λ, φ_shear=φ_shear
                    )
                end
            else
                for i in 1:n_cols_ps
                    punching_local[i] = check_punching_for_column(
                        columns[i], moment_results.column_shears[i],
                        moment_results.unbalanced_moments[i], d, h, fc;
                        verbose=false, col_idx=i, λ=λ, φ_shear=φ_shear,
                        _geom_cache=_punch_geom_cache
                    )
                end
            end
            
            # ── B3: Classify failures ──
            interior_fails = Int[]
            edge_corner_fails = Int[]
            for i in 1:n_cols_ps
                if !punching_local[i].ok
                    if columns[i].position == :interior
                        push!(interior_fails, i)
                    else
                        push!(edge_corner_fails, i)
                    end
                end
                if verbose
                    r = punching_local[i]
                    status = r.ok ? "OK" : "FAIL"
                    @debug "Punching Column $i ($(columns[i].position))" ratio=round(r.ratio, digits=3) status=status
                end
            end
            
            all_fails = vcat(interior_fails, edge_corner_fails)
            
            if isempty(all_fails)
                punching_resolved = true
                verbose && @debug "Phase B converged: all punching OK (iter=$iter_b)"
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :decision;
                      phase="B", outcome="all_punching_ok", iterations=iter_b,
                      punching_ratios=[round(punching_local[i].ratio, digits=3) for i in 1:n_cols_ps])
                break
            end
            
            # ── B4: Resolve failures ──
            emit!(tc, :slab, "size_flat_plate!", _slab_id, :iteration;
                  phase="B", n_interior_fails=length(interior_fails),
                  n_edge_corner_fails=length(edge_corner_fails),
                  strategy=string(opts.punching_strategy),
                  failing_ratios=Dict(
                      "col_$i" => round(punching_local[i].ratio, digits=3) for i in all_fails))
            columns_grew, h = _resolve_punching_failures!(
                punching_local, columns, all_fails, opts, column_opts,
                moment_results, secondary_results,
                h, d, fc, h_increment;
                λ=λ, φ_shear=φ_shear, verbose=verbose
            )
            
            # If h was bumped (last resort), break to outer loop → restart Phase A
            if h != h_before_punch
                last_failing_check = "punching_shear"
                verbose && @warn "Phase B bumped h → $h (last resort). Restarting Phase A."
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :fallback;
                      phase="B", reason="punching_h_bump", h_new=string(h))
                break
            end
            
            if columns_grew
                last_failing_check = "punching_shear"
                # Re-iterate Phase B with updated column sizes
                continue
            end
            
            # Studs resolved everything without column growth
            punching_resolved = true
            verbose && @debug "Phase B converged: studs resolved punching (iter=$iter_b)"
            break
        end  # Phase B loop
        
        # If Phase B bumped h, restart from Phase A
        if !punching_resolved
            if h != h_before_punch
                # h was bumped — update d and restart Phase A
                d = effective_depth(h; cover=cover, bar_diameter=bar_dia)
                sw_estimate = slab_sw(h)
                Pu = compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)
                _prev_h = h
                continue  # outer loop → Phase A
            end
            @warn "Phase B (punching) did not converge in $max_iterations iterations" h=h
            return (
                converged       = false,
                failure_reason  = "non_convergence",
                failing_check   = "punching_shear",
                iterations      = total_iters,
                h_final         = h,
                pattern_loading = false,
                slab_result     = nothing,
                column_results  = nothing,
                drop_panel      = drop_panel,
                integrity       = nothing,
                integrity_check = nothing,
                transfer_results = nothing,
                ρ_prime         = nothing,
            )
        end
        
        # =================================================================
        # PHASE C — FINAL DESIGN (rebar, transfer, integrity, results)
        # =================================================================
        verbose && @debug "═══════════════════════════════════════════════════════════════════"
        verbose && @debug "PHASE C — FINAL DESIGN"
        verbose && @debug "═══════════════════════════════════════════════════════════════════"
        
        result = _run_final_design(
            method, struc, slab, columns, moment_results, secondary_results,
            h, d, fc, fy, cover, sw_estimate, n_cols, punching_local,
            local_to_global, column_opts, column_result, Pu, opts, total_iters,
            deflection_result, ρ_prime_est, drop_panel, slab_sw, γ_concrete,
            material; verbose=verbose, analysis_cache=analysis_cache
        )
        
        # If rebar design failed, bump h and restart from Phase A
        if hasproperty(result, :converged) && result.converged
            emit!(tc, :slab, "size_flat_plate!", _slab_id, :exit;
                  converged=true, h_final=string(h), h_initial=string(h_initial),
                  iterations=total_iters,
                  column_sizes=[string(col.c1) * "×" * string(col.c2) for col in columns])
        end
        if hasproperty(result, :needs_more_depth) && result.needs_more_depth
            h = round_up_thickness(h + h_increment, h_increment)
            verbose && @warn "Rebar design failed (section inadequate). Increasing h → $h, restarting Phase A."
            last_failing_check = "reinforcement_design"
            # Update h-dependent state for next Phase A
            d = effective_depth(h; cover=cover, bar_diameter=bar_dia)
            sw_estimate = slab_sw(h)
            Pu = compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)
            _prev_h = h
            continue  # outer loop → Phase A
        end
        
        return result
    end  # outer loop
    
    # ─── Non-convergence: return structured failure ───
    emit!(tc, :slab, "size_flat_plate!", _slab_id, :failure;
          reason="non_convergence", failing_check=last_failing_check,
          h_final=string(h), iterations=total_iters)
    @warn "Flat plate design did not converge in $max_iterations outer iterations" last_check=last_failing_check h_final=h
    return (
        converged       = false,
        failure_reason  = "non_convergence",
        failing_check   = last_failing_check,
        iterations      = total_iters,
        h_final         = h,
        pattern_loading = false,
        slab_result     = nothing,
        column_results  = nothing,
        drop_panel      = drop_panel,
        integrity       = nothing,
        integrity_check = nothing,
        transfer_results = nothing,
        ρ_prime         = nothing,
    )
end
