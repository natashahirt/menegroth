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

"""
    check_flat_plate_at_thickness!(struc, slab, column_opts; method, opts, verbose,
                                   _col_cache, slab_idx, drop_panel)

Single-pass flat-plate evaluation at the ACI minimum slab thickness.

Mirrors the iterative pipeline in `size_flat_plate!` but does **not** bump
`h` on failure.  Instead, every check is run and its result recorded; the
returned NamedTuple includes a `failures` field listing the names of any
checks that did not pass.

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
    ln_max = max(slab.spans.primary, slab.spans.secondary)
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
    has_edge = any(col.position != :interior for col in columns)
    h = if !isnothing(opts.min_h)
        opts.min_h
    elseif !isnothing(drop_panel)
        min_thickness(FlatSlab(), ln_max; discontinuous_edge=has_edge)
    else
        min_thickness(FlatPlate(), ln_max; discontinuous_edge=has_edge)
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
    c_span_min = estimate_column_size_from_span(ln_max)

    for col in columns
        if isnothing(col.c1) || col.c1 <= 0u"inch"
            col.c1 = c_span_min
            col.c2 = c_span_min
        end
    end

    # =====================================================================
    # 4. AXIAL LOADS & P-M CACHE
    # =====================================================================
    Pu = compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)

    if isnothing(_col_cache)
        _col_cat = isnothing(column_opts.custom_catalog) ?
            rc_column_catalog(column_opts.section_shape, column_opts.catalog) :
            column_opts.custom_catalog

        _col_checker = ACIColumnChecker(;
            include_slenderness = column_opts.include_slenderness,
            include_biaxial     = column_opts.include_biaxial,
            fy_ksi = ustrip(ksi, column_opts.rebar_grade.Fy),
            Es_ksi = ustrip(ksi, column_opts.rebar_grade.E),
            max_depth = column_opts.max_depth,
        )

        _col_cache = create_cache(_col_checker, length(_col_cat))
        precompute_capacities!(_col_checker, _col_cache, _col_cat,
                               column_opts.grade, column_opts.objective)
    end

    local_to_global = let
        _id_to_idx = Dict{UInt64, Int}(objectid(struc.columns[i]) => i
                                        for i in eachindex(struc.columns))
        [_id_to_idx[objectid(col)] for col in columns]
    end

    # Analysis cache
    inner = method.analysis
    analysis_cache = if slab_idx > 0 && hasproperty(struc, :_analysis_caches)
        slab_caches = get!(struc._analysis_caches, slab_idx, Dict{Symbol, Any}())
        if inner isa EFM && inner.solver == :asap
            get!(slab_caches, :efm, EFMModelCache())
        elseif inner isa FEA
            get!(slab_caches, :fea, FEAModelCache())
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

    # Check applicability — if DDM isn't valid, return early with failure reason
    try
        enforce_method_applicability(inner, struc, slab, columns;
                                     verbose=verbose, ρ_concrete=γ_concrete)
    catch e
        if e isa DDMApplicabilityError || e isa EFMApplicabilityError
            reason = join(e.violations, "; ")
            return (
                converged        = false,
                failure_reason   = reason,
                failing_check    = "applicability",
                failures         = ["applicability"],
                iterations       = 0,
                h_final          = h,
                pattern_loading  = false,
                slab_result      = nothing,
                column_results   = nothing,
                drop_panel       = drop_panel,
                integrity        = nothing,
                integrity_check  = nothing,
                transfer_results = nothing,
                ρ_prime          = 0.0,
            )
        else
            rethrow()
        end
    end

    moment_results = run_moment_analysis(
        inner, struc, slab, columns, h, fc, Ecs, γ_concrete;
        ν_concrete = material.concrete.ν,
        verbose = verbose,
        efm_cache  = analysis_cache isa EFMModelCache ? analysis_cache : nothing,
        cache      = analysis_cache isa FEAModelCache ? analysis_cache : nothing,
        drop_panel = drop_panel,
        βt = _βt,
        col_I_factor = opts.col_I_factor,
    )

    check_pattern_loading_requirement(moment_results; verbose=verbose)

    Mu = [ustrip(kip * u"ft", moment_results.column_moments[i]) for i in 1:n_cols]

    # 5b. Column P-M design
    geometries = [
        ConcreteMemberGeometry(col.base.L; Lu=col.base.L, k=1.0, braced=true)
        for col in columns
    ]
    column_result = size_columns(Pu, Mu, geometries, column_opts; cache=_col_cache)

    for (i, col) in enumerate(columns)
        section = column_result.sections[i]
        c1_pm = section.b
        c2_pm = section.h
        col.c1 = max(c_span_min, c1_pm, col.c1)
        col.c2 = max(c_span_min, c2_pm, col.c2)
        if col.c1 ≈ c1_pm && col.c2 ≈ c2_pm
            col.base.section = section
        else
            col.base.section = resize_column_with_reinforcement(
                section, col.c1, col.c2, Pu[i], Mu[i], material
            )
        end
    end

    # 5c. Punching shear
    punching_local = Vector{NamedTuple}(undef, n_cols)
    if !isnothing(drop_panel)
        h_total = total_depth_at_drop(h, drop_panel)
        d_total = effective_depth(h_total; cover=cover, bar_diameter=bar_dia)
        for i in 1:n_cols
            punching_local[i] = check_punching(
                columns[i], moment_results.column_shears[i],
                moment_results.unbalanced_moments[i],
                h, d, h_total, d_total, fc, drop_panel;
                qu=moment_results.qu, verbose=false, col_idx=i, λ=λ, φ_shear=φ_shear
            )
        end
    else
        for i in 1:n_cols
            punching_local[i] = check_punching_for_column(
                columns[i], moment_results.column_shears[i],
                moment_results.unbalanced_moments[i], d, h, fc;
                verbose=false, col_idx=i, λ=λ, φ_shear=φ_shear,
            )
        end
    end

    if any(!pr.ok for pr in punching_local)
        push!(failures, "punching_shear")
    end

    # 5d. Two-way deflection
    _l2_defl = moment_results.l2
    ρ_prime_est = try
        _As_neg = required_reinforcement(
            0.75 * moment_results.M_neg_int, _l2_defl / 2, d, fc, fy
        )
        _As_neg = max(_As_neg, minimum_reinforcement(_l2_defl / 2, h, fy))
        0.5 * ustrip(u"inch^2", _As_neg) /
            (ustrip(u"inch", _l2_defl / 2) * ustrip(u"inch", d))
    catch
        0.0
    end

    deflection_result = try
        if !isnothing(drop_panel)
            check_two_way_deflection(
                moment_results, h, d, fc, fy, Es, Ecs, slab.spans, γ_concrete, columns,
                drop_panel;
                verbose=verbose, limit_type=opts.deflection_limit, ρ_prime=ρ_prime_est
            )
        else
            check_two_way_deflection(
                moment_results, h, d, fc, fy, Es, Ecs, slab.spans, γ_concrete, columns;
                verbose=verbose, limit_type=opts.deflection_limit, ρ_prime=ρ_prime_est
            )
        end
    catch
        nothing
    end

    if isnothing(deflection_result) || !deflection_result.ok
        push!(failures, "two_way_deflection")
    end

    # 5e. One-way shear
    shear_result = check_one_way_shear(moment_results, d, fc;
                                        verbose=verbose, λ=λ, φ_shear=φ_shear)
    if !shear_result.ok
        push!(failures, "one_way_shear")
    end

    # 5f. Flexural adequacy
    flexure_result = check_flexural_adequacy(moment_results, columns, d, fc;
                                              verbose=verbose)
    if !flexure_result.ok
        push!(failures, "flexural_adequacy")
    end

    # =====================================================================
    # 6. FINAL DESIGN (reinforcement, integrity) — always attempted
    # =====================================================================

    # Face-of-support reduction for EFM
    if inner isa EFM
        _c1_ext_min = typemax(typeof(columns[1].c1))
        _c1_int_min = typemax(typeof(columns[1].c1))
        _has_ext = false; _has_int = false
        for _col in columns
            if _col.position == :interior
                if _col.c1 < _c1_int_min; _c1_int_min = _col.c1; end
                _has_int = true
            else
                if _col.c1 < _c1_ext_min; _c1_ext_min = _col.c1; end
                _has_ext = true
            end
        end
        c1_ext = _has_ext ? _c1_ext_min : moment_results.c_avg
        c1_int = _has_int ? _c1_int_min : moment_results.c_avg
        Vu_face = moment_results.Vu_max
        M_unit  = unit(moment_results.M0)
        
        # Primary direction reduction
        M_neg_ext_reduced = uconvert(M_unit, face_of_support_moment(
            moment_results.M_neg_ext, Vu_face, c1_ext, moment_results.l1))
        M_neg_int_reduced = uconvert(M_unit, face_of_support_moment(
            moment_results.M_neg_int, Vu_face, c1_int, moment_results.l1))

        # For EFM, keep original M_pos from frame analysis (see pipeline.jl comments)
        moment_results = MomentAnalysisResult(
            moment_results.M0,
            M_neg_ext_reduced, M_neg_int_reduced,
            moment_results.M_pos,
            moment_results.qu, moment_results.qD, moment_results.qL,
            moment_results.l1, moment_results.l2, moment_results.ln, moment_results.c_avg,
            moment_results.column_moments,
            moment_results.column_shears,
            moment_results.unbalanced_moments,
            moment_results.Vu_max;
            pattern_loading = moment_results.pattern_loading,
        )
    end

    rebar_design = try
        result = design_strip_reinforcement(
            moment_results, columns, h, d, fc, fy, cover; verbose=verbose
        )
        # Check for inadequate section (new graceful failure mode)
        if !result.section_adequate
            push!(failures, "reinforcement_design")
            nothing
        else
            result
        end
    catch
        push!(failures, "reinforcement_design")
        nothing
    end

    # Moment transfer
    transfer_results = Union{Nothing, NamedTuple}[nothing for _ in 1:n_cols]
    if !isnothing(rebar_design)
        for (i, col) in enumerate(columns)
            Mub_i = moment_results.unbalanced_moments[i]
            abs(ustrip(kip * u"ft", Mub_i)) < 1e-6 && continue
            c2_i = col.c2
            bb   = c2_i + 3 * h
            b1   = col.c1 + d
            b2   = col.c2 + d
            γf_val = gamma_f(b1, b2)
            As_transfer = transfer_reinforcement(abs(Mub_i), γf_val, bb, d, fc, fy)
            # Skip if section inadequate (Inf returned)
            if isinf(As_transfer)
                continue
            end
            cs_neg_idx = col.position == :interior ? 3 : 1
            As_provided_cs = rebar_design.column_strip_reinf[cs_neg_idx].As_provided
            selected = select_bars(As_provided_cs, rebar_design.column_strip_width)
            Ab = bar_area(selected.bar_size)
            transfer_results[i] = additional_transfer_bars(
                As_transfer, As_provided_cs, bb,
                rebar_design.column_strip_width, Ab
            )
        end
    end

    # Integrity reinforcement
    cell = struc.cells[first(slab.cell_indices)]
    integrity = integrity_reinforcement(
        cell.area, cell.sdl + sw_estimate, cell.live_load, fy
    )
    integrity_check = if !isnothing(rebar_design)
        cs_pos_reinf = rebar_design.column_strip_reinf[2]
        chk = check_integrity_reinforcement(cs_pos_reinf.As_provided, integrity.As_integrity)
        if !chk.ok
            cs_width = rebar_design.column_strip_width
            bumped = select_bars(integrity.As_integrity, cs_width)
            rebar_design.column_strip_reinf[2] = StripReinforcement(
                :pos, cs_pos_reinf.Mu, cs_pos_reinf.As_reqd, cs_pos_reinf.As_min,
                uconvert(u"m^2", bumped.As_provided), bumped.bar_size,
                uconvert(u"m", bumped.spacing), bumped.n_bars,
                true  # section_adequate
            )
        end
        chk
    else
        nothing
    end

    # =====================================================================
    # 7. UPDATE CELLS & BUILD RESULTS
    # =====================================================================
    sw_final = slab_sw(h)
    for cell_idx in slab.cell_indices
        struc.cells[cell_idx].self_weight = sw_final
    end
    update_asap_column_sections!(struc, columns, column_opts.grade)

    punching_results = Dict{Int, NamedTuple}(
        local_to_global[i] => punching_local[i] for i in 1:n_cols
    )

    converged = isempty(failures)

    slab_result = if !isnothing(rebar_design) && !isnothing(deflection_result)
        build_slab_result(
            h, sw_final, moment_results, rebar_design,
            deflection_result, punching_results;
            γ_concrete = γ_concrete * GRAVITY
        )
    else
        nothing
    end

    column_results_out = build_column_results(
        struc, columns, column_result, Pu, moment_results.column_moments, punching_results
    )

    return (
        converged        = converged,
        failure_reason   = converged ? "" : join(failures, ", "),
        failing_check    = isempty(failures) ? "" : first(failures),
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
