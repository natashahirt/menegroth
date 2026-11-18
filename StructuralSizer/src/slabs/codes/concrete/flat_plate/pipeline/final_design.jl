"""
    _efm_moments_at_face(r::MomentAnalysisResult) -> MomentAnalysisResult

Design negative moments at the ACI 318-11 §13.7.7.1 critical section
(corpus: aci-318-11, page 262). EFM fills `M_neg_ext_face`/`M_neg_int_face`
from each span's statics; this moves them into `M_neg_ext`/`M_neg_int` and
clears the face fields so the step cannot be applied twice. A result
without face moments keeps its centerline values, which are larger.

`M_pos` stays the frame's own midspan value: §13.7.7.1 moves the critical
section for negative moment only.
"""
function _efm_moments_at_face(r::MomentAnalysisResult)
    isnothing(r.M_neg_ext_face) && return r
    M_unit = unit(r.M_neg_ext)
    return MomentAnalysisResult(
        r.M0, uconvert(M_unit, r.M_neg_ext_face), uconvert(M_unit, r.M_neg_int_face),
        r.M_pos, r.qu, r.qD, r.qL, r.l1, r.l2, r.ln, r.c_avg,
        r.column_moments, r.column_shears, r.unbalanced_moments, r.Vu_max;
        secondary = r.secondary,
        fea_Δ_panel = r.fea_Δ_panel,
        pattern_loading = r.pattern_loading,
        M_wall_ext = r.M_wall_ext,
        M_wall_int = r.M_wall_int,
        stub_moments_below = r.stub_moments_below,
        stub_moments_above = r.stub_moments_above,
        wall_transfer = r.wall_transfer,
        wall_faces = r.wall_faces,
    )
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
                            analysis_cache = nothing,
                            defer_asap_process::Bool = false,
                            update_analysis_model::Bool = true)
    # A rejected NLP column is not a finished design. Stop before ASAP is
    # updated and before this function can return converged=true.
    rejected = _flat_plate_column_pm_failure(column_result, h, iter, drop_panel)
    isnothing(rejected) || return rejected

    # ─── Face-of-Support Moments (ACI 318-11 §13.7.7.1) ───
    if method isa EFM
        verbose && @debug "FACE-OF-SUPPORT MOMENTS (ACI 318-11 §13.7.7.1)" M_neg_ext_cl=moment_results.M_neg_ext M_neg_ext_face=moment_results.M_neg_ext_face M_neg_int_cl=moment_results.M_neg_int M_neg_int_face=moment_results.M_neg_int_face
        moment_results = _efm_moments_at_face(moment_results)
        isnothing(secondary_results) ||
            (secondary_results = _efm_moments_at_face(secondary_results))
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
        _fea_col_strips = _fea_strips
        _fea_strips = _add_wall_face_to_strips(
            _fea_strips, moment_results, struc, slab, columns,
            _setup.span_axis, _setup.l1, _setup.l2, _βt_design)
        design_strip_reinforcement_fea(_fea_strips, _setup.l1, _setup.l2, h, d, fc, fy, cover;
            verbose=verbose,
            drop_stations=_fea_drop_stations(
                _fea_col_strips, _fea_strips, moment_results, columns, d,
                _setup.l1, _setup.l2, drop_panel; βt=_βt_design,
                struc=struc, slab=slab, span_axis=_setup.span_axis))
    else
        design_strip_reinforcement(moment_results, columns, h, d, fc, fy, cover;
                                    βt=_βt_design, verbose=verbose,
                                    struc=struc, slab=slab,
                                    span_axis=_get_span_axis(slab),
                                    drop=drop_panel)
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
            _sec_col_strips = _sec_fea_strips
            _sec_fea_strips = _add_wall_face_to_strips(
                _sec_fea_strips, secondary_results, struc, slab, columns,
                _sec_setup.span_axis, _sec_setup.l1, _sec_setup.l2, _βt_design)
            design_strip_reinforcement_fea(_sec_fea_strips, _sec_setup.l1, _sec_setup.l2, h, d_inner, fc, fy, cover;
                verbose=verbose,
                drop_stations=_fea_drop_stations(
                    _sec_col_strips, _sec_fea_strips, secondary_results, columns, d_inner,
                    _sec_setup.l1, _sec_setup.l2, _transposed_drop(drop_panel);
                    βt=_βt_design, struc=struc, slab=slab, span_axis=_sec_setup.span_axis))
        else
            _sec_ax = _get_span_axis(slab)
            design_strip_reinforcement(secondary_results, columns, h, d_inner, fc, fy, cover;
                                        βt=_βt_design, verbose=verbose,
                                        struc=struc, slab=slab,
                                        span_axis=(-_sec_ax[2], _sec_ax[1]),
                                        drop=_transposed_drop(drop_panel))
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

    # ─── Secondary One-Way Shear (ACI 318-19 §22.5) on the inner-layer depth ───
    if _has_frame_strip(secondary_results)
        sec_shear = check_one_way_shear(secondary_results, d_inner, fc; h = h, fy = fy,
            λ = Float64(isnothing(opts.λ) ? material.concrete.λ : opts.λ),
            φ_shear = opts.φ_shear, verbose = verbose)
        if !sec_shear.ok
            verbose && @warn "Secondary one-way shear fails" ratio = sec_shear.ratio
            return (
                converged        = false,
                failure_reason   = "one_way_shear",
                failing_check    = "one_way_shear_secondary",
                h_current        = h,
                needs_more_depth = true,
            )
        end
    end

    # ─── Moment Transfer Reinforcement (ACI 318-11 §13.5.3) ───
    d_punch = isnothing(drop_panel) ? d : d + (total_depth_at_drop(h, drop_panel) - h)
    transfer = _pipeline_transfer_reinforcement(
        columns, moment_results, secondary_results, rebar_design, h, d, fc, fy;
        verbose = verbose,
        punching = _column_face_punching(punching_local, columns, d_punch, drop_panel),
        d_punch = d_punch, drop = drop_panel,
        secondary_rebar_design = secondary_rebar_design,
        span_axis = _get_span_axis(slab),
        d_secondary = d_inner,
        λ = Float64(isnothing(opts.λ) ? material.concrete.λ : opts.λ),
        φ_shear = opts.φ_shear)
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

    # ACI 318-11 §12.12.1 — top bars at a wall face must develop in the wall.
    # A failure is recorded. It does not increase the slab thickness.
    _anch_ax = _get_span_axis(slab)
    wall_anchorage = wall_face_bar_anchorage(
        rebar_design, moment_results, struc, slab, columns,
        fc, fy, material.concrete.λ, cover, _anch_ax)
    if wall_anchorage !== nothing && !wall_anchorage.ok
        verbose && @warn "Slab top bars do not develop in the wall" bar=wall_anchorage.bar_size available=wall_anchorage.available ldh=wall_anchorage.ldh
        return (
            converged        = false,
            failure_reason   = "wall_bar_development",
            failing_check    = "wall_bar_development",
            h_current        = h,
            needs_more_depth = false,
            wall_anchorage   = wall_anchorage,
        )
    end
    if !isnothing(secondary_rebar_design) && !isnothing(secondary_results)
        sec_anchorage = wall_face_bar_anchorage(
            secondary_rebar_design, secondary_results, struc, slab, columns,
            fc, fy, material.concrete.λ, cover, (-_anch_ax[2], _anch_ax[1]))
        if sec_anchorage !== nothing && !sec_anchorage.ok
            verbose && @warn "Secondary top bars do not develop in the wall" bar=sec_anchorage.bar_size
            return (
                converged        = false,
                failure_reason   = "wall_bar_development",
                failing_check    = "wall_bar_development_secondary",
                h_current        = h,
                needs_more_depth = false,
                wall_anchorage   = sec_anchorage,
            )
        end
        wall_anchorage === nothing && (wall_anchorage = sec_anchorage)
    end

    # ─── Structural Integrity Bottom Bars (ACI 318-11 §13.3.8.5) ───
    integrity_bottom_bars!(rebar_design, h)
    secondary_rebar_design === nothing || integrity_bottom_bars!(secondary_rebar_design, h)
    integrity_check = design_integrity_check(rebar_design, secondary_rebar_design)
    integrity = integrity_check
    verbose && @debug "INTEGRITY (ACI 318-11 §13.3.8.5)" integrity_check

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

    face_parts, face_parts_sec = _final_wall_face_parts(
        method, analysis_cache, struc, slab, columns, h, γ_concrete,
        moment_results, secondary_results)
    slab_result = build_slab_result(
        h, sw_final, moment_results, rebar_design,
        deflection_result, punching_results;
        γ_concrete = γ_concrete * GRAVITY,
        secondary_rebar_design = secondary_rebar_design,
        secondary_results = secondary_results,
        wall_face_parts = face_parts,
        wall_face_parts_secondary = face_parts_sec,
    )

    column_results = build_column_results(
        struc, columns, column_result,
        Pu, moment_results.unbalanced_moments, punching_results;
        Mu_secondary = isnothing(secondary_results) ? nothing :
                       secondary_results.unbalanced_moments,
        stubs = stub_moments(moment_results),
        stubs_secondary = stub_moments(secondary_results),
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
        wall_anchorage=wall_anchorage,
    )
end

"""Wall-face parts stored on a moment result. Empty when that result has none."""
function _stored_wall_faces(results)
    results === nothing && return SlabWallFaceMoment[]
    hasproperty(results, :wall_faces) || return SlabWallFaceMoment[]
    return results.wall_faces
end

"""
    _final_wall_face_parts(method, cache, struc, slab, columns, h, γ_concrete,
                           moment_results, secondary_results) -> (primary, secondary)

Dead and live wall-face parts in each span direction.

A shell analysis reads them from the cache at the converged thickness. Direct
design and the equivalent frame read the parts stored on the moment result.
Both are empty when that direction has no wall or no dead/live split.
"""
function _final_wall_face_parts(method, cache, struc, slab, columns, h, γ_concrete,
                                moment_results, secondary_results)
    if !(method isa FEA && cache isa FEAModelCache && cache.initialized)
        return _stored_wall_faces(moment_results), _stored_wall_faces(secondary_results)
    end
    ax = _moment_analysis_setup(struc, slab, columns, h, γ_concrete).span_axis
    primary = _paired_wall_face_parts(cache, struc, slab, ax,
                                      _stored_wall_moment(moment_results))
    secondary_results === nothing && return primary, SlabWallFaceMoment[]
    sec_ax = _secondary_moment_analysis_setup(struc, slab, columns, h, γ_concrete).span_axis
    secondary = _paired_wall_face_parts(cache, struc, slab, sec_ax,
                                        _stored_wall_moment(secondary_results))
    return primary, secondary
end

"""
    _crossing_beam_deflection(moment_results, h, d, fc, fy, material, slab,
                              γ_concrete, columns, drop_panel, opts, ρ_prime)

Crossing-beam deflection at the converged thickness, for reporting next to
the FEA nodal check. `fea_Δ_panel` is cleared so `check_two_way_deflection`
takes the PCA frame → strip → panel path with ACI 318-19 Table 24.2.3.5 `Ie`
(the path DDM and EFM use).

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
        return two_way_deflection(proxy, h, d, fc, fy, Es, Ecs, slab.spans, γ_concrete,
                                  columns; drop_panel = drop_panel,
                                  λ = isnothing(opts.λ) ? material.concrete.λ : opts.λ,
                                  limit_type = opts.deflection_limit, ρ_prime = ρ_prime,
                                  deflection_Ie_method = :aci318_19)
    catch e
        @debug "Crossing-beam deflection (report only) failed" exception=(e, catch_backtrace())
        return nothing
    end
end

