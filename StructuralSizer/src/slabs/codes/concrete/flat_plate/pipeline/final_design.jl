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
                            analysis_cache = nothing,
                            defer_asap_process::Bool = false,
                            update_analysis_model::Bool = true)
    # A rejected NLP column is not a finished design. Stop before ASAP is
    # updated and before this function can return converged=true.
    rejected = _flat_plate_column_pm_failure(column_result, h, iter, drop_panel)
    isnothing(rejected) || return rejected

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
        #   1. M0 in MomentAnalysisResult uses clear span (ln) per ACI 318-11 §13.6.2.2
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

    # ACI 318-11 §13.6.4.2 — torsional stiffness ratio βt of the edge-supporting
    # member (used to interpolate the exterior-negative column-strip fraction
    # between 100 % at βt = 0 and 75 % at βt ≥ 2.5).  Mirrors the resolution
    # done in the moment-analysis caller; centralised here so the strip-design
    # path has it without duplicating the βt computation.
    _βt_design = if !isnothing(opts.edge_beam_βt)
        Float64(opts.edge_beam_βt)
    elseif opts.has_edge_beam
        _c1_avg_eb = sum(col.c1 for col in columns) / length(columns)
        _c2_avg_eb = sum(col.c2 for col in columns) / length(columns)
        Float64(edge_beam_βt(h, _c1_avg_eb, _c2_avg_eb, slab.spans.secondary))
    else
        0.0
    end

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
        design_strip_reinforcement_fea(_fea_strips, _setup.l1, _setup.l2, h, d, fc, fy, cover;
                                        verbose=verbose)
    else
        design_strip_reinforcement(moment_results, columns, h, d, fc, fy, cover;
                                    βt=_βt_design, verbose=verbose)
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
    #
    # In a two-way slab the secondary-direction bars sit *below* the primary
    # bars in the section (cover requirements per ACI 318-11 §7.7 plus the
    # bar-spacing geometry of §7.6 imply a layered placement).  The effective
    # depth of the inner (secondary) layer is therefore:
    #
    #   d_inner = h − cover − db_primary − db_secondary/2     (geometric)
    #
    # The actual primary bar diameter comes from the reinforcement just
    # selected by the primary design; we take the MAX across all strip
    # locations (CS ext-neg, pos, int-neg + MS pos, int-neg) so d_inner is
    # conservative even when mixed sizes are chosen.  We assume
    # `db_secondary == db_primary` (PCA flat-plate convention — same bar
    # size in both directions).  Engineering judgment: if the secondary
    # design later selects a smaller bar, d_inner will be slightly
    # conservative; on the next iteration this self-corrects via the bar
    # size feeding back into the next primary pass.
    _db_primary_max = let
        _strips = vcat(rebar_design.column_strip_reinf,
                       rebar_design.middle_strip_reinf)
        _bar_dias = [bar_diameter(sr.bar_size) for sr in _strips if sr.bar_size > 0]
        isempty(_bar_dias) ? bar_dia : maximum(_bar_dias)
    end
    _db_secondary = _db_primary_max  # PCA flat-plate convention (engineering judgment)
    d_inner = inner_layer_effective_depth(h, cover, _db_primary_max, _db_secondary)
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
            design_strip_reinforcement_fea(_sec_fea_strips, _sec_setup.l1, _sec_setup.l2, h, d_inner, fc, fy, cover;
                                            verbose=verbose)
        else
            design_strip_reinforcement(secondary_results, columns, h, d_inner, fc, fy, cover;
                                        βt=_βt_design, verbose=verbose)
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
    transfer = _pipeline_transfer_reinforcement(
        columns, moment_results, secondary_results, rebar_design, h, d, fc, fy;
        verbose = verbose)
    if !transfer.ok
        verbose && @warn "Transfer reinforcement failed: section inadequate at column $(transfer.column)"
        return (
            converged        = false,
            failure_reason   = "section_inadequate",
            failing_check    = "transfer_reinforcement",
            h_current        = h,
            needs_more_depth = true,
        )
    end
    transfer_results = transfer.results

    # ─── Structural Integrity Reinforcement (ACI 8.7.4.2) ───
    cell = struc.cells[first(slab.cell_indices)]
    integrity = integrity_reinforcement(cell.area, cell.sdl + sw_estimate, cell.live_load, fy)
    cs_pos_reinf = rebar_design.column_strip_reinf[2]
    integrity_check = check_integrity_reinforcement(cs_pos_reinf.As_provided, integrity.As_integrity)

    verbose && @debug "INTEGRITY REINFORCEMENT (ACI 8.7.4.2)" As_integrity=integrity.As_integrity As_bottom=cs_pos_reinf.As_provided ok=integrity_check.ok utilization=round(integrity_check.utilization, digits=2)

    if !integrity_check.ok
        cs_width = rebar_design.column_strip_width
        # ACI 318-11 §13.3.2 + §7.6.5 — slab-thickness-dependent s_max
        bumped = select_bars(integrity.As_integrity, cs_width;
                             max_spacing=max_bar_spacing(h))
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
    # Sections are written onto the building model here. The design graph
    # defers the stiffness rebuild to the single post-slab sync, because slab
    # sizing does not read frame stiffness between slabs. Every other caller
    # rebuilds K before returning, so a standalone `size_slab!` does not leave
    # a processed model whose stiffness still belongs to the previous sections.
    if update_analysis_model
        update_asap_column_sections!(struc, columns, column_opts.material;
                                     reprocess=!defer_asap_process)
    end

    if verbose
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "DESIGN CONVERGED ✓"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Final slab" h=h sw=sw_final method=method_name(method)
        @debug "Final columns" sizes=["$(c.c1)×$(c.c2)" for c in columns]
        @debug "Iterations" n=iter
    end

    # Report-only. The thickness loop already accepted `deflection_result`.
    # For FEA that value comes from the nodal displacement; this second
    # value is the PCA crossing-beam number DDM and EFM report, so a
    # comparison can show both. It is not read by any later check.
    crossing_beam_deflection = method isa FEA ?
        _crossing_beam_deflection(
            moment_results, h, d, fc, fy, material, slab, γ_concrete, columns,
            drop_panel, opts, ρ_prime_est,
        ) : nothing

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
        Pu, moment_results.unbalanced_moments, punching_results;
        Mu_secondary = isnothing(secondary_results) ? nothing :
                       secondary_results.unbalanced_moments,
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
        deflection_check_crossing_beam=crossing_beam_deflection,
        # Moment analyses at the converged thickness (both directions), for reporting
        moment_results=moment_results,
        secondary_results=secondary_results,
    )
end

"""
    _crossing_beam_deflection(moment_results, h, d, fc, fy, material, slab,
                              γ_concrete, columns, drop_panel, opts, ρ_prime)

Crossing-beam deflection at the converged thickness, for reporting next to
the FEA nodal check. `fea_Δ_panel` is cleared so `check_two_way_deflection`
takes the PCA frame → strip → panel path with Branson `Ie` (the path DDM
and EFM use). ACI 318-11 §9.5.2.6 (corpus: aci-318-11, page 132).

Returns `nothing` if the check cannot be evaluated. The caller does not
use the result to change thickness.
"""
function _crossing_beam_deflection(moment_results, h, d, fc, fy, material, slab,
                                   γ_concrete, columns, drop_panel, opts, ρ_prime)
    Es = material.rebar.E
    Ecs = Ec(fc, ustrip(pcf, γ_concrete))   # ACI 318-11 §8.5.1
    # `fea_Δ_panel = nothing` selects the crossing-beam branch.
    proxy = (
        M_pos       = moment_results.M_pos,
        M_neg_ext   = moment_results.M_neg_ext,
        M_neg_int   = moment_results.M_neg_int,
        qu          = moment_results.qu,
        qD          = moment_results.qD,
        qL          = moment_results.qL,
        fea_Δ_panel = nothing,
    )
    try
        kwargs = (
            limit_type = opts.deflection_limit,
            ρ_prime = ρ_prime,
            deflection_Ie_method = :branson,
        )
        if !isnothing(drop_panel)
            return check_two_way_deflection(
                proxy, h, d, fc, fy, Es, Ecs, slab.spans, γ_concrete, columns,
                drop_panel; kwargs...,
            )
        else
            return check_two_way_deflection(
                proxy, h, d, fc, fy, Es, Ecs, slab.spans, γ_concrete, columns;
                kwargs...,
            )
        end
    catch e
        @debug "Crossing-beam deflection (report only) failed" exception=(e, catch_backtrace())
        return nothing
    end
end

