# =============================================================================
# Rule-of-Thumb (ACI Minimum Thickness) — Single-Pass Evaluation
# =============================================================================
#
# Runs the full flat-plate design pipeline exactly ONCE at the ACI minimum
# thickness.  Every check is executed regardless of pass/fail, and failures
# are recorded in a `failures::Vector{String}` field so the sweep can
# display which checks govern.
#
# This function is dispatched from `size_flat_plate!` when the caller passes
# `method = RuleOfThumb()`.
# =============================================================================

TRACE_REGISTRY[(:check_flat_plate_at_thickness!, :slab)] =
    TracedFunctionMeta(:check_flat_plate_at_thickness!, :slab,
                       [:failure], nothing, @__FILE__, @__LINE__)

"""
    check_flat_plate_at_thickness!(struc, slab, column_opts; method, opts, verbose,
                                   _col_cache, slab_idx, drop_panel, tc)

Single-pass flat-plate evaluation at the ACI minimum slab thickness.

Mirrors the iterative pipeline in `size_flat_plate!` but does **not** bump
`h` on failure.  Instead, every check is run and its result recorded; the
returned NamedTuple includes a `failures` field listing the names of any
checks that did not pass.

`tc` is passed to the moment analyses, so Eq. (13-7) and §13.6.3.3
fallbacks are traced as on the iterative path.  A non-finite transfer
moment or transfer reinforcement (`_rot_transfer_reinforcement!`) records
`transfer_reinforcement`, emits `:failure`, and returns no `slab_result`,
as the iterative pipeline returns none for that case.

When the wrapped DDM/EFM is not permitted for the layout,
`resolve_analysis_method` applies `opts.on_inapplicable` (`:fallback` runs
the pass with `FEA()` and records it in `_method_record`; `:error` rethrows).

Called automatically when `method isa RuleOfThumb`.
"""
function check_flat_plate_at_thickness!(
    struc,
    slab,
    column_opts;
    method::RuleOfThumb,
    opts::FlatPlateOptions = FlatPlateOptions(),
    verbose::Bool = false,
    _col_cache = nothing,
    slab_idx::Int = 0,
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    update_analysis_model::Bool = true,
    tc::Union{Nothing, TraceCollector} = nothing,
    _method_record::Base.RefValue{NamedTuple} = Ref{NamedTuple}(
        (method_requested = method, method_used = method, method_fallback_reasons = String[])),
)
    # =====================================================================
    # 1. SETUP  (identical to pipeline Phase 1)
    # =====================================================================
    material = opts.material
    fc       = material.concrete.fc′
    fy       = material.rebar.Fy
    γ_concrete = material.concrete.ρ
    cover    = opts.cover
    bar_size = opts.bar_size
    φ_flexure = opts.φ_flexure
    φ_shear   = opts.φ_shear
    λ  = isnothing(opts.λ) ? material.concrete.λ : opts.λ
    Es = material.rebar.E
    wc_pcf = ustrip(pcf, γ_concrete)
    Ecs    = Ec(fc, wc_pcf)

    slab_cell_indices = Set(slab.cell_indices)
    # Same longer reinforcement-axis span as the design iteration. ACI 318-11
    # §9.5.3.2 / Table 9.5(c) (corpus: aci-318-11, page 134).
    ln_max = longer_axis_span(slab.spans)
    slab_sw(h) = slab_self_weight(h, γ_concrete)

    # =====================================================================
    # 2. COLUMNS
    # =====================================================================
    columns = find_supporting_columns(struc, slab_cell_indices)
    n_cols  = length(columns)
    n_cols == 0 && error("No supporting columns found for slab.")

    # =====================================================================
    # 3. THICKNESS — fixed at ACI minimum (no iteration)
    # =====================================================================
    has_edge = slab_discontinuous_edge(struc, slab, columns)
    h = if !isnothing(opts.min_h)
        opts.min_h
    elseif !isnothing(drop_panel)
        min_thickness(FlatSlab(), ln_max; discontinuous_edge=has_edge, fy)
    else
        min_thickness(FlatPlate(), ln_max; discontinuous_edge=has_edge, fy)
    end

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
        end
    end

    bar_dia    = bar_diameter(bar_size)
    d          = effective_depth(h; cover=cover, bar_diameter=bar_dia)
    sw_estimate = slab_sw(h)
    c_span_min = _column_span_minimum(ln_max, opts)

    # =====================================================================
    # 4. AXIAL LOADS & P-M CACHE
    # =====================================================================
    Pu = slab_column_axial_loads(struc, slab, columns, slab_cell_indices, sw_estimate,
        drop_panel, γ_concrete)
    _initialize_unsized_columns!(columns, Pu, ln_max, opts, column_opts)

    if isnothing(_col_cache)
        _col_cat = isnothing(column_opts.custom_catalog) ?
            rc_column_catalog(column_opts.section_shape, column_opts.catalog) :
            column_opts.custom_catalog

        _col_checker = ACIColumnChecker(;
            include_slenderness = column_opts.include_slenderness,
            include_biaxial     = column_opts.include_biaxial,
            fy_ksi = ustrip(ksi, column_opts.rebar_material.Fy),
            Es_ksi = ustrip(ksi, column_opts.rebar_material.E),
            max_depth = column_opts.max_depth,
        )

        _col_cache = create_cache(_col_checker, length(_col_cat))
        precompute_capacities!(_col_checker, _col_cache, _col_cat,
                               column_opts.material, column_opts.objective)
    end

    local_to_global = let
        _id_to_idx = Dict{UInt64, Int}(objectid(struc.columns[i]) => i
                                        for i in eachindex(struc.columns))
        [_id_to_idx[objectid(col)] for col in columns]
    end

    # Applicability of the inner method — FEA fallback or rethrow per
    # opts.on_inapplicable, exactly as the iterative pipeline does.
    inner, fallback_reasons = resolve_analysis_method(
        method.analysis, struc, slab, columns, opts.on_inapplicable;
        ρ_concrete=γ_concrete, verbose=verbose, tc=tc, slab_id="slab_$(slab_idx)",
        caller="check_flat_plate_at_thickness!")
    if inner !== method.analysis
        _method_record[] = (method_requested = method, method_used = RuleOfThumb(inner),
                            method_fallback_reasons = fallback_reasons)
    end

    # Analysis cache
    analysis_cache = if slab_idx > 0 && hasproperty(struc, :_analysis_caches)
        slab_caches = get!(struc._analysis_caches, slab_idx, Dict{Symbol, Any}())
        if inner isa EFM && inner.solver == :asap
            get!(slab_caches, :efm, EFMModelCache())
        elseif inner isa FEA
            acquire_fea_cache!(slab_caches, fea_mesh_key(
                struc, slab, columns;
                target_edge=inner.target_edge, drop_panel=drop_panel))
        else
            nothing
        end
    else
        if inner isa EFM && inner.solver == :asap
            EFMModelCache()
        elseif inner isa FEA
            FEAModelCache()
        else
            nothing
        end
    end

    # =====================================================================
    # 5. SINGLE-PASS CHECKS — collect failures instead of re-iterating
    # =====================================================================
    failures = String[]

    # 5a. Moment analysis (using wrapped method)
    _βt = 0.0
    if !isnothing(opts.edge_beam_βt)
        _βt = opts.edge_beam_βt
    elseif opts.has_edge_beam
        _c1_avg = sum(col.c1 for col in columns) / length(columns)
        _c2_avg = sum(col.c2 for col in columns) / length(columns)
        _βt = edge_beam_βt(h, _c1_avg, _c2_avg, slab.spans.secondary)
    end

    moment_results = run_moment_analysis(
        inner, struc, slab, columns, h, fc, Ecs, γ_concrete;
        ν_concrete = material.concrete.ν,
        verbose = verbose,
        efm_cache  = analysis_cache isa EFMModelCache ? analysis_cache : nothing,
        cache      = analysis_cache isa FEAModelCache ? analysis_cache : nothing,
        drop_panel = drop_panel,
        βt = _βt,
        _edge_beam_analysis_kwargs(opts)...,
        col_I_factor = opts.col_I_factor,
        tc = tc,
        column_concrete = column_opts.material,
    )

    secondary_results = if inner isa FEA && !isnothing(moment_results.secondary)
        moment_results.secondary
    else
        run_secondary_moment_analysis(
            inner, struc, slab, columns, h, fc, Ecs, γ_concrete;
            verbose=verbose, drop_panel=drop_panel, βt=_βt,
            _edge_beam_analysis_kwargs(opts)...,
            # ACI 318-11 §10.10.4.1 — cracked column-stub stiffness from caller (default 0.70)
            col_I_factor = opts.col_I_factor, tc=tc,
            column_concrete = column_opts.material,
        )
    end

    check_pattern_loading_requirement(moment_results; verbose=verbose)

    # Column below the slab. FEA reads its stub. DDM and EFM take a
    # stiffness share of the joint moment (§13.6.9.2, not §13.5.3.2).
    _dist_factors = column_moment_distribution_factors(struc, columns, column_opts;
                                                       span_axis = _get_span_axis(slab))
    Mu = [column_design_moment(moment_results, i, _dist_factors.primary[i]) for i in 1:n_cols]
    Mu_secondary = if isnothing(secondary_results)
        zeros(n_cols)
    else
        [column_design_moment(secondary_results, i, _dist_factors.secondary[i]) for i in 1:n_cols]
    end

    # §10.10.5 designation and Fig. R10.10.1.1 k, same as the iterative path.
    geometries = flat_plate_column_geometries(columns, slab, struc; h = h)
    column_result = size_columns(Pu, Mu, geometries, column_opts;
                                 Muy=Mu_secondary, cache=_col_cache)

    # Same update as the iterative pipeline. A rejected NLP result writes
    # nothing and is a failure of this pass.
    _rc_nlp_result_installable(column_result) || push!(failures, "column_pm")
    _update_column_sizes!(columns, column_result, Pu, Mu, c_span_min, column_opts, 0.0;
                          Muy = Mu_secondary, verbose = verbose, geometries = geometries)

    # 5c. Punching shear
    punching_local = Vector{NamedTuple}(undef, n_cols)
    if !isnothing(drop_panel)
        h_total = total_depth_at_drop(h, drop_panel)
        d_total = effective_depth(h_total; cover=cover, bar_diameter=bar_dia)
        for i in 1:n_cols
            # ACI 318-11 §11.11.7.1 (corpus: aci-318-11, page 209) +
            # PCA EB712 Fig. 16-13 Case D (corpus: pca-eb712, page 486).
            Muy_i = isnothing(secondary_results) ? nothing :
                secondary_results.unbalanced_moments[i]
            punching_local[i] = check_punching(
                columns[i], moment_results.column_shears[i],
                moment_results.unbalanced_moments[i],
                h, d, h_total, d_total, fc, drop_panel;
                qu=moment_results.qu, Muy=Muy_i,
                verbose=false, col_idx=i, λ=λ, φ_shear=φ_shear,
                punching_axis_kwargs(struc, slab, columns[i])...
            )
        end
    else
        for i in 1:n_cols
            Muy_i = isnothing(secondary_results) ? nothing :
                secondary_results.unbalanced_moments[i]
            punching_local[i] = check_punching_for_column(
                columns[i], moment_results.column_shears[i],
                moment_results.unbalanced_moments[i], d, h, fc;
                verbose=false, col_idx=i, λ=λ, φ_shear=φ_shear,
                Muy=Muy_i,
                punching_axis_kwargs(struc, slab, columns[i])...
            )
        end
    end

    if any(!pr.ok for pr in punching_local)
        push!(failures, "punching_shear")
    end

    # 5d. Two-way deflection, both directions (secondary on the inner layer)
    d_inner = inner_layer_effective_depth(h, cover, bar_dia, bar_dia)
    ρ_prime_est = FLAT_PLATE_MIDSPAN_RHO_PRIME
    _defl_kw = (; drop_panel = drop_panel, verbose = verbose, λ = λ,
                limit_type = opts.deflection_limit)
    deflection_result = try
        two_way_deflection(moment_results, h, d, fc, fy, Es, Ecs, slab.spans, γ_concrete,
                           columns; ρ_prime = ρ_prime_est, _defl_kw...)
    catch e
        @warn "Deflection check (primary) threw; treated as a failure" exception=(e, catch_backtrace())
        nothing
    end

    if isnothing(deflection_result) || !deflection_result.ok
        push!(failures, "two_way_deflection")
    end
    if !isnothing(secondary_results)
        sec_defl_ok = try
            secondary_two_way_deflection(moment_results, secondary_results, h, d_inner,
                                         fc, fy, Es, Ecs, slab.spans, γ_concrete, columns;
                                         _defl_kw...).ok
        catch e
            @warn "Deflection check (secondary) threw; treated as a failure" exception=(e, catch_backtrace())
            false
        end
        sec_defl_ok || push!(failures, "two_way_deflection_secondary")
    end

    # 5e. One-way shear. Analytical demand governs. The FEA cut is diagnostic.
    _fea_diag = if analysis_cache isa FEAModelCache && analysis_cache.initialized
        _span_ax = _get_span_axis(slab)
        _extract_fea_one_way_shear(
            analysis_cache, columns, _span_ax, d, moment_results.l2;
            verbose=verbose,
        )
    else
        nothing
    end
    shear_result = check_one_way_shear(moment_results, d, fc; h = h, fy = fy,
                                        verbose=verbose, λ=λ, φ_shear=φ_shear,
                                        fea_diag=_fea_diag)
    wall_shear = wall_one_way_shear(
        struc, slab, d, fc, moment_results.qu; h = h, fy = fy, λ = λ, ϕ = φ_shear)
    if !shear_result.ok || any(c -> !c.ok, wall_shear)
        push!(failures, "one_way_shear")
    end
    if _has_frame_strip(secondary_results) &&
       !check_one_way_shear(secondary_results, d_inner, fc; h = h, fy = fy,
                            λ = λ, φ_shear = φ_shear).ok
        push!(failures, "one_way_shear_secondary")
    end

    # 5f. Flexural adequacy, both directions
    flexure_result = check_flexural_adequacy(moment_results, columns, d, fc; fy = fy,
                                              βt=_βt, verbose=verbose,
                                              struc=struc, slab=slab,
                                              span_axis=_get_span_axis(slab),
                                              drop=drop_panel)
    if !flexure_result.ok
        push!(failures, "flexural_adequacy")
    end
    secondary_flexural_adequacy(secondary_results, columns, d_inner, fc, fy; βt = _βt,
                                struc = struc, slab = slab,
                                span_axis = _get_span_axis(slab), drop = drop_panel).ok ||
        push!(failures, "flexural_adequacy_secondary")

    # =====================================================================
    # 6. FINAL DESIGN (reinforcement, integrity) — always attempted
    # =====================================================================

    # Face-of-support moments for EFM (ACI 318-11 §13.7.7.1)
    if inner isa EFM
        moment_results = _efm_moments_at_face(moment_results)
        isnothing(secondary_results) ||
            (secondary_results = _efm_moments_at_face(secondary_results))
    end

    rebar_design = try
        result = design_strip_reinforcement(
            moment_results, columns, h, d, fc, fy, cover;
            βt=_βt, verbose=verbose,
            struc=struc, slab=slab, span_axis=_get_span_axis(slab),
            drop=drop_panel,
        )
        # Check for inadequate section (new graceful failure mode)
        if !result.section_adequate
            push!(failures, "reinforcement_design")
            nothing
        else
            anchorage = wall_face_bar_anchorage(
                result, moment_results, struc, slab, columns,
                fc, fy, λ, cover, _get_span_axis(slab))
            if anchorage !== nothing && !anchorage.ok
                push!(failures, "wall_bar_development")
            end
            result
        end
    catch
        push!(failures, "reinforcement_design")
        nothing
    end

    # Secondary direction on the inner layer, as in the iterative pipeline's
    # strip design (`_run_final_design`). The support moments are taken at
    # the centreline: the face reduction is permitted, not required.
    secondary_rebar_design = if isnothing(rebar_design) || isnothing(secondary_results)
        nothing
    else
        ax = _get_span_axis(slab)
        try
            sec = design_strip_reinforcement(
                secondary_results, columns, h, d_inner, fc, fy, cover;
                βt = _βt, verbose = verbose, struc = struc, slab = slab,
                span_axis = (-ax[2], ax[1]), drop = _transposed_drop(drop_panel))
            sec.section_adequate ? sec :
                (push!(failures, "reinforcement_design_secondary"); nothing)
        catch
            push!(failures, "reinforcement_design_secondary")
            nothing
        end
    end

    # Moment transfer
    transfer_results = Union{Nothing, NamedTuple}[nothing for _ in 1:n_cols]
    d_punch = isnothing(drop_panel) ? d : d + (total_depth_at_drop(h, drop_panel) - h)
    transfer_ok = isnothing(rebar_design) || _rot_transfer_reinforcement!(
        transfer_results, failures, columns, moment_results, secondary_results,
        rebar_design, h, d, fc, fy; tc = tc, slab_id = "slab_$(slab_idx)",
        punching = _column_face_punching(punching_local, columns, d_punch, drop_panel),
        d_punch = d_punch, drop = drop_panel, λ = Float64(λ), φ_shear = φ_shear,
        span_axis = _get_span_axis(slab),
        secondary_rebar_design = secondary_rebar_design, d_secondary = d_inner)

    # Integrity bottom bars (ACI 318-11 §13.3.8.5), both directions.
    integrity_check = if !isnothing(rebar_design)
        integrity_bottom_bars!(rebar_design, h)
        secondary_rebar_design === nothing ||
            integrity_bottom_bars!(secondary_rebar_design, h)
        design_integrity_check(rebar_design, secondary_rebar_design)
    else
        nothing
    end
    integrity = integrity_check

    # =====================================================================
    # 7. UPDATE CELLS & BUILD RESULTS
    # =====================================================================
    sw_final = slab_sw(h)
    for cell_idx in slab.cell_indices
        struc.cells[cell_idx].self_weight = sw_final
    end
    # A rejected NLP column is already in `failures`. Do not write its
    # preliminary section into the analysis model as a completed design.
    if update_analysis_model && _rc_nlp_result_installable(column_result)
        update_asap_column_sections!(struc, columns, column_opts.material)
    end

    punching_results = Dict{Int, NamedTuple}(
        local_to_global[i] => punching_local[i] for i in 1:n_cols
    )

    converged = isempty(failures)

    slab_result = if transfer_ok && !isnothing(rebar_design) && !isnothing(deflection_result)
        build_slab_result(
            h, sw_final, moment_results, rebar_design,
            deflection_result, punching_results;
            γ_concrete = γ_concrete * GRAVITY,
            secondary_rebar_design = secondary_rebar_design,
            secondary_results = secondary_results,
        )
    else
        nothing
    end

    column_results_out = build_column_results(
        struc, columns, column_result, Pu, moment_results.unbalanced_moments, punching_results;
        Mu_secondary = isnothing(secondary_results) ? nothing :
                       secondary_results.unbalanced_moments,
        stubs = stub_moments(moment_results),
        stubs_secondary = stub_moments(secondary_results),
    )

    return (
        converged        = converged,
        failure_reason   = converged ? "" : join(failures, ", "),
        failing_check    = isempty(failures) ? "" : first(failures),
        governing_check  = _governing_check_label(
            isempty(failures) ? "" : first(failures), opts.min_h),
        one_way_shear    = shear_result,
        failures         = failures,
        iterations       = 1,
        h_final          = h,
        pattern_loading  = moment_results.pattern_loading,
        slab_result      = slab_result,
        column_results   = column_results_out,
        drop_panel       = drop_panel,
        integrity        = integrity,
        integrity_check  = integrity_check,
        transfer_results = transfer_results,
        ρ_prime          = ρ_prime_est,
    )
end

"""
    _rot_transfer_reinforcement!(transfer_results, failures, columns, moment_results,
                                 secondary_results, rebar_design, h, d, fc, fy;
                                 tc, slab_id) -> Bool

Moment-transfer reinforcement (ACI 318-11 §13.5.3, corpus: aci-318-11,
page 250) at every column for the rule-of-thumb pass.  Fills
`transfer_results[i]` and returns `true` when every column has a finite
transfer demand and finite transfer steel.

A non-finite transfer moment, or transfer steel the section cannot develop
(`transfer_section_inadequate`), records `transfer_reinforcement` in
`failures`, emits a `:failure` trace event naming the column, and returns
`false`.  The column is not skipped as if no transfer were required; the
caller must not build a design from it (the iterative pipeline returns
`converged = false` with no result in the same case).
"""
function _rot_transfer_reinforcement!(transfer_results, failures, columns,
                                      moment_results, secondary_results,
                                      rebar_design, h, d, fc, fy;
                                      tc = nothing, slab_id::String = "", kwargs...)
    ok = true
    # Retry policy: record every failing column (push once, emit a per-column
    # trace) and keep scanning, so the pass reports all inadequate columns.
    function fail!(i, reason)
        "transfer_reinforcement" in failures || push!(failures, "transfer_reinforcement")
        emit!(tc, :slab, "check_flat_plate_at_thickness!", slab_id, :failure;
              reason = reason, failing_check = "transfer_reinforcement", column = i)
        ok = false
        return true  # continue scanning the remaining columns
    end
    _transfer_reinforcement_pass(columns, moment_results, secondary_results,
                                 rebar_design, h, d, fc, fy;
                                 results = transfer_results, on_inadequate = fail!,
                                 kwargs...)
    return ok
end
