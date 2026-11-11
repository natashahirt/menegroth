"""
    _size_flat_plate!(struc, slab, column_opts; method, _method_record, kwargs...)

Body of `size_flat_plate!`.  When the requested method is replaced by its
fallback (`resolve_analysis_method`), `_method_record[]` is set to the
`(method_requested, method_used, method_fallback_reasons)` record that
`size_flat_plate!` merges into the returned tuple.
"""
function _size_flat_plate!(
    struc,
    slab,
    column_opts;
    method::FlatPlateAnalysisMethod = DDM(),
    _method_record::Base.RefValue{NamedTuple} = Ref{NamedTuple}(
        (method_requested = method, method_used = method, method_fallback_reasons = String[])),
    opts::FlatPlateOptions = FlatPlateOptions(),
    max_iterations::Int = 10,
    column_tol::Float64 = 0.05,
    h_increment::Length = 0.5u"inch",
    verbose::Bool = false,
    _col_cache = nothing,
    slab_idx::Int = 0,
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    fire_rating::Real = 0.0,
    defer_asap_process::Bool = false,
    update_analysis_model::Bool = true,
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
            _col_cache=_col_cache, slab_idx=slab_idx, drop_panel=drop_panel, tc=tc,
            _method_record=_method_record,
            update_analysis_model=update_analysis_model)
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
    # ACI 318-11 §9.5.3.2 and Table 9.5(c) (corpus: aci-318-11, page 134)
    # take the minimum thickness from the longer span. The table is written
    # for a rectangular panel and does not define that span otherwise, so it
    # is the longer of the two reinforcement-axis spans, not the diagonal.
    ln_max = longer_axis_span(slab.spans)
    
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
    
    # Check method applicability — FEA fallback or rethrow per opts.on_inapplicable
    requested_method = method
    method, fallback_reasons = resolve_analysis_method(
        method, struc, slab, columns, opts.on_inapplicable;
        ρ_concrete=γ_concrete, verbose=verbose, tc=tc, slab_id="slab_$(slab_idx)")
    if method !== requested_method
        _method_record[] = (method_requested = requested_method, method_used = method,
                            method_fallback_reasons = fallback_reasons)
    end
    
    # =========================================================================
    # PHASE 3: INITIAL ESTIMATES
    # =========================================================================
    
    has_edge = slab_discontinuous_edge(struc, slab, columns)
    if !isnothing(opts.min_h)
        h = opts.min_h  # User override — bypass ACI minimum
    elseif !isnothing(drop_panel)
        # Flat slab: reduced minimum thickness (ACI Table 8.3.1.1 Row 2)
        h = min_thickness(FlatSlab(), ln_max; discontinuous_edge=has_edge, fy)
    else
        h = min_thickness(FlatPlate(), ln_max; discontinuous_edge=has_edge, fy)
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
    c_span_min = _column_span_minimum(ln_max, opts)
    
    if verbose
        @debug "INITIAL ESTIMATES" h_min=h sw=sw_estimate c_span_min=c_span_min
    end
    
    # =========================================================================
    # PHASE 4: COMPUTE INITIAL AXIAL LOADS
    # =========================================================================
    
    Pu = slab_column_axial_loads(struc, slab, columns, slab_cell_indices, sw_estimate,
        drop_panel, γ_concrete)
    _initialize_unsized_columns!(columns, Pu, ln_max, opts, column_opts)
    
    if verbose
        @debug "COLUMN AXIAL LOADS (Pu = max(1.2D+1.6L, 1.4D))"
        for (i, col) in enumerate(columns)
            @debug "Column $i ($(col.position))" Pu=Pu[i]*kip
        end
    end
    
    # =========================================================================
    # PHASE 4b: PRE-BUILD P-M CACHE (hoisted outside iteration loop)
    # =========================================================================
    
    # Reuse the shared cache from size_slabs! / the design graph when one was
    # passed (avoids duplicate P-M diagrams). The NLP path never reads this
    # catalog cache — size_columns returns before the discrete solver — so
    # building it there only spends the diagram precompute.
    if hasproperty(column_opts, :sizing_strategy) && column_opts.sizing_strategy === :nlp
        _col_cache = nothing
    elseif isnothing(_col_cache)
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
            acquire_fea_cache!(slab_caches, fea_mesh_key(
                struc, slab, columns;
                target_edge=method.target_edge, drop_panel=drop_panel))
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
    # Punching geometry cache: keyed on (c1_m, c2_m, d_m, position, shape, edge_par)
    # edge_par is required so :c1 vs :c2 3-sided geometry cannot collide.
    # Cleared when h changes (d changes) — column size changes auto-miss
    _punch_geom_cache = Dict{Tuple{Float64,Float64,Float64,Symbol,Symbol,Symbol}, NamedTuple}()
    
    # §10.10.5 designation and Fig. R10.10.1.1 k, at the current thickness.
    # Rebuilt each iteration: column size and h both move ψ.
    geometries = flat_plate_column_geometries(columns, slab, struc; h = h)
    
    # Preallocate Mu and Mu_secondary buffers (reused each iteration)
    Mu = Vector{Float64}(undef, n_cols)
    Mu_secondary = Vector{Float64}(undef, n_cols)
    
    # Recomputed at each assignment. Column growth changes c1 and c2, and
    # the §13.6.9.2 factor is K_below / (K_below + K_above), with K for the
    # bending direction of each analysis. A shell result carries its own
    # below-stub moment and does not use the factor.
    function _assign_column_design_moments!(moment_results, secondary_results)
        dist = column_moment_distribution_factors(struc, columns, column_opts;
                                                  span_axis = _get_span_axis(slab))
        if verbose && stub_moments(moment_results) === nothing &&
           any(f -> f < 1.0, dist.primary)
            @debug "Column moment distribution factors (§13.6.9.2)" primary=dist.primary secondary=dist.secondary
        end
        @inbounds for i in eachindex(Mu)
            Mu[i] = column_design_moment(moment_results, i, dist.primary[i])
        end
        if !isnothing(secondary_results)
            @inbounds for i in 1:n_cols
                Mu_secondary[i] = column_design_moment(secondary_results, i, dist.secondary[i])
            end
        else
            fill!(Mu_secondary, 0.0)
        end
        return nothing
    end
    
    # Track which check is currently failing (for structured failure diagnostics)
    last_failing_check = ""
    one_way_shear_report = nothing
    total_iters = 0   # accumulate across all phases for the result tuple
    
    d = effective_depth(h; cover=cover, bar_diameter=bar_dia)
    _prev_h = h  # Track h to avoid redundant recomputation
    _βt = 0.0

    # ACI 318-11 §13.5.3.3 at the column face. The flat-slab check uses the
    # thickness at the drop while the transfer steel uses the slab depth, so
    # the increase is limited to flat plates.
    _moment_transfer = opts.moment_transfer_increase && isnothing(drop_panel) ?
        (fy = fy, bar_diameter = bar_dia, cover = cover) : nothing

    # One analysis, then the thinnest half-inch the scaled checks accept.
    # Column sizes stay frozen across that scan. A column-size change still
    # re-runs the analysis before this is called.
    function _jumped_depth(h_now, mrs, srs; punching::Bool = false)
        edge_stiffness = opts.has_edge_beam && isnothing(opts.edge_beam_βt)
        return propose_slab_thickness(
            h_now, h_increment, ln_max / 10, mrs, srs, γ_concrete;
            drop_panel = drop_panel,
            stiffness_depends_on_h = edge_stiffness,
            passes = (hh, scaled_p, scaled_s) -> begin
                dd = effective_depth(hh; cover = cover, bar_diameter = bar_dia)
                Ie_method = method isa FEA ? method.deflection_Ie_method : :aci318_19
                ok = phase_a_depth_passes(
                    scaled_p, scaled_s, hh, dd, fc, fy, Es, Ecs, slab.spans,
                    γ_concrete, columns;
                    struc = struc, slab = slab, limit_type = opts.deflection_limit,
                    deflection_Ie_method = Ie_method, λ = λ, φ_shear = φ_shear,
                    βt = _βt, span_axis = _get_span_axis(slab),
                    cover = cover, bar_diameter = bar_dia, drop_panel = drop_panel)
                punching || return ok
                return ok && punching_depth_passes(
                    scaled_p, scaled_s, columns, hh, dd, fc, struc, slab;
                    λ = λ, φ_shear = φ_shear, moment_transfer = _moment_transfer,
                    drop_panel = drop_panel, cover = cover, bar_diameter = bar_dia)
            end,
        )
    end
    
    # Shared mutable state across phases
    deflection_result = nothing
    ρ_prime_est = 0.0
    
    _slab_id = "slab_$(slab_idx)"
    emit!(tc, :slab, "size_flat_plate!", _slab_id, :enter;
          method=method_name(method),
          method_requested=method_name(requested_method),
          n_columns=n_cols,
          h_initial=string(h_initial),
          primary_span=string(slab.spans.primary),
          secondary_span=string(slab.spans.secondary),
          punching_strategy=string(opts.punching_strategy),
          has_drop_panel=!isnothing(drop_panel))

    # A still-growing design may take one step per remaining increment, at
    # least `max_iterations`, and never more than the growth ceiling. The
    # `stop` on a failure says whether that budget ran out (`:budget`) or
    # the thickness limit was reached (`:at_limit`).
    function _fea_passes()
        analysis_cache isa FEAModelCache || return (fea_rebuilds = 0, fea_updates = 0)
        return (fea_rebuilds = analysis_cache.n_rebuilds,
                fea_updates = analysis_cache.n_updates)
    end

    function _stopped(check, h_now, stop)
        emit!(tc, :slab, "size_flat_plate!", _slab_id, :failure;
              reason="non_convergence", failing_check=check, stop=string(stop),
              h_final=string(h_now), iterations=total_iters, _fea_passes()...)
        return (
            converged       = false,
            failure_reason  = "non_convergence",
            failing_check   = check,
            iterations      = total_iters,
            h_final         = h_now,
            pattern_loading = false,
            slab_result     = nothing,
            column_results  = nothing,
            drop_panel      = drop_panel,
            integrity       = nothing,
            integrity_check = nothing,
            transfer_results = nothing,
            ρ_prime         = nothing,
            stop            = stop,
        )
    end

    h_max = ln_max / 10
    _thick_steps() = growth_steps(
        _growth_meters(h), _growth_meters(h_max), _growth_meters(h_increment))
    function _column_steps()
        inc = hasproperty(column_opts, :size_increment) ?
            column_opts.size_increment : h_increment
        cmax = opts.max_column_size
        span = 0
        for col in columns
            c0 = max(_growth_meters(col.c1), _growth_meters(col.c2))
            span = max(span, growth_steps(c0, _growth_meters(cmax), _growth_meters(inc)))
        end
        return span
    end

    # ── :joint_search state (docs/flat-plate-joint-sizing-plan.md) ──
    _joint = opts.punching_strategy === :joint_search
    if _joint && opts.joint_studs && !_is_headed_stud_reinforcement(opts.punching_reinforcement)
        throw(ArgumentError(
            "punching_strategy = :joint_search with joint_studs = true needs a headed-stud " *
            "punching_reinforcement; got :$(opts.punching_reinforcement)"))
    end
    joint_scanned = false
    joint_stud_cols = Set{Int}()
    n_joint_scans = 0
    _edge_stiffness_h = opts.has_edge_beam && isnothing(opts.edge_beam_βt)
    function _joint_ctx(βt)
        (struc = struc, slab = slab, columns = columns, opts = opts,
         column_opts = column_opts, fc = fc, fy = fy, λ = λ, φ_shear = φ_shear,
         cover = cover, bar_dia = bar_dia, γ = γ_concrete, h_increment = h_increment,
         h_max = h_max, βt = βt, slab_area_m2 = _joint_slab_area_m2(struc, slab),
         c_floor = [(c.c1, c.c2) for c in columns],
         Ast_floor = [_joint_section_steel(c) for c in columns],
         geom_cache = _punch_geom_cache, moment_transfer = _moment_transfer,
         depth_passes = (hh, sp, ss) -> phase_a_depth_passes(
             sp, ss, hh, effective_depth(hh; cover = cover, bar_diameter = bar_dia),
             fc, fy, Es, Ecs, slab.spans, γ_concrete, columns;
             struc = struc, slab = slab, limit_type = opts.deflection_limit,
             deflection_Ie_method = method isa FEA ? method.deflection_Ie_method : :aci318_19,
             λ = λ, φ_shear = φ_shear, βt = βt, span_axis = _get_span_axis(slab),
             cover = cover, bar_diameter = bar_dia, drop_panel = drop_panel),
         studs = opts.joint_studs, thicken = opts.punching_thickening,
         concrete = material.concrete, rebar = material.rebar, preferred = nothing)
    end

    # =====================================================================
    # OUTER LOOP: ties Phase A → B → C together.
    # Phase B (punching) or C (rebar) may signal "need more depth", which
    # bumps h and restarts from Phase A.  This is the rare last-resort path.
    # The bound is the thickness steps still available, not only the caller's
    # iteration count, so a slab that is still thickening is not stopped early.
    # =====================================================================
    outer_budget = monotone_budget(max_iterations, _thick_steps())
    for outer in 1:outer_budget
        
        # =================================================================
        # PHASE A — DEPTH CONVERGENCE
        # Iterate h until deflection, one-way shear, flexural adequacy,
        # and column P-M all stabilize.  No punching check here.
        # =================================================================
        depth_converged = false
        
        a_budget = monotone_budget(max_iterations, _thick_steps())
        for iter_a in 1:a_budget
            total_iters += 1
            geometries = flat_plate_column_geometries(columns, slab, struc; h = h)

            # Guard against runaway thickness (h > ln/10 is impractical)
            if h > h_max
                @warn "Slab thickness h=$h exceeds practical limit (ln/10 = $h_max). Aborting."
                return _stopped(last_failing_check, h, :at_limit)
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
                Pu = slab_column_axial_loads(struc, slab, columns, slab_cell_indices, sw_estimate,
                    drop_panel, γ_concrete)
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
                    Pu = slab_column_axial_loads(struc, slab, columns, slab_cell_indices, sw_estimate,
                        drop_panel, γ_concrete)
                end
            end
            
            # ─── A1: Moment Analysis ───
            # `_βt` drives DDM/EFM moment-fraction interpolation (ACI 318-11
            # Table 13.6.4.2).  For `has_edge_beam=true` without an explicit
            # value, this falls back to the slab-strip torsional constant (a
            # small number ≈ 0.1–0.2 for a typical flat plate with no real
            # perimeter beam).  FEA receives the user's *intent* separately
            # via `_edge_beam_analysis_kwargs` so it can distinguish "no real
            # edge beam" from "edge beam present" and avoid double-counting.
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
                _edge_beam_analysis_kwargs(opts)...,
                col_I_factor = opts.col_I_factor,
                tc = tc,
                column_concrete = column_opts.material,
            )
            
            secondary_results = if method isa FEA && !isnothing(moment_results.secondary)
                moment_results.secondary
            else
                run_secondary_moment_analysis(
                    method, struc, slab, columns, h, fc, Ecs, γ_concrete;
                    verbose=verbose, drop_panel=drop_panel, βt=_βt,
                    _edge_beam_analysis_kwargs(opts)...,
                    # ACI 318-11 §10.10.4.1 — cracked column-stub stiffness from caller (default 0.70)
                    col_I_factor = opts.col_I_factor,
                    tc = tc,
                    column_concrete = column_opts.material,
                )
            end
            
            check_pattern_loading_requirement(moment_results; verbose=verbose)
            
            # Column below the slab. FEA reads its stub. DDM and EFM take a
            # fresh stiffness share of the joint moment.
            _assign_column_design_moments!(moment_results, secondary_results)
            
            # ─── A2: Column P-M Design ───
            verbose && @debug "COLUMN P-M DESIGN"
            
            local column_result
            try
                column_result = size_columns(Pu, Mu, geometries, column_opts;
                                              Muy=Mu_secondary, cache=_col_cache)
            catch e
                e isa ArgumentError || rethrow()
                @warn "Column P-M design infeasible — no catalog section satisfies demand" h=h reason=e.msg
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

            # Rejected NLP columns return false from _update_column_sizes!
            # (nothing was written). That is not "sizes are stable."
            rejected = _flat_plate_column_pm_failure(column_result, h, total_iters, drop_panel)
            isnothing(rejected) || return rejected

            columns_changed = _update_column_sizes!(
                columns, column_result, Pu, Mu, c_span_min, column_opts, column_tol;
                Muy=Mu_secondary, verbose=verbose, geometries=geometries
            )
            
            if columns_changed
                verbose && @debug "⟳ Column sizes changed, re-running analysis..."
                last_failing_check = "column_pm"
                continue
            end
            
            # ─── A3: Two-Way Deflection Check ───
            verbose && @debug "TWO-WAY DEFLECTION CHECK (ACI 24.2)"
            
            ρ_prime_est = FLAT_PLATE_MIDSPAN_RHO_PRIME

            # Inner (secondary) bar layer: secondary deflection, shear and flexure.
            d_inner_a = inner_layer_effective_depth(h, cover, bar_dia, bar_dia)
            _Ie_method = method isa FEA ? method.deflection_Ie_method : :aci318_19
            _defl_kw = (; drop_panel = drop_panel, verbose = verbose, λ = λ,
                        limit_type = opts.deflection_limit, deflection_Ie_method = _Ie_method)
            _defl_ok = try
                deflection_result = two_way_deflection(
                    moment_results, h, d, fc, fy, Es, Ecs, slab.spans, γ_concrete, columns;
                    ρ_prime = ρ_prime_est, _defl_kw...)
                deflection_result.ok
            catch e
                @warn "Deflection check (primary) threw; treated as a failure" exception=(e, catch_backtrace())
                false
            end
            
            if !_defl_ok
                h = _jumped_depth(h, moment_results, secondary_results)
                verbose && @warn "Deflection FAILED (primary). Increasing h → $h"
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :iteration;
                      phase="A", check="two_way_deflection", passed=false, h_new=string(h))
                last_failing_check = "two_way_deflection"
                continue
            end
            
            # ─── A3b: Secondary Direction Deflection Check ───
            # Swapped spans, secondary moments, inner-layer depth.
            if !isnothing(secondary_results)
                verbose && @debug "SECONDARY DEFLECTION CHECK (ACI 24.2)"
                _sec_defl_ok = try
                    secondary_two_way_deflection(
                        moment_results, secondary_results, h, d_inner_a, fc, fy, Es, Ecs,
                        slab.spans, γ_concrete, columns; _defl_kw...).ok
                catch e
                    @warn "Deflection check (secondary) threw; treated as a failure" exception=(e, catch_backtrace())
                    false
                end
                if !_sec_defl_ok
                    h = _jumped_depth(h, moment_results, secondary_results)
                    verbose && @warn "Deflection FAILED (secondary direction). Increasing h → $h"
                    last_failing_check = "two_way_deflection_secondary"
                    continue
                end
            end
            
            # ─── A4: One-Way Shear Check ───
            verbose && @debug "ONE-WAY SHEAR CHECK (ACI 11.2)"

            # The shell cut is a diagnostic. Thickness is governed by the
            # analytical frame-strip demand shared with DDM and EFM.
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
                verbose=verbose, λ=λ, φ_shear=φ_shear, fea_diag=_fea_diag)
            one_way_shear_report = shear_result
            wall_shear = wall_one_way_shear(
                struc, slab, d, fc, moment_results.qu; h = h, fy = fy, λ = λ, ϕ = φ_shear)
            wall_shear_ok = all(c -> c.ok, wall_shear)
            sec_shear_ok = !_has_frame_strip(secondary_results) ||
                check_one_way_shear(secondary_results, d_inner_a, fc; h = h, fy = fy,
                                    λ = λ, φ_shear = φ_shear).ok

            if !shear_result.ok || !wall_shear_ok || !sec_shear_ok
                h = _jumped_depth(h, moment_results, secondary_results)
                verbose && @warn "One-way shear FAILED. Increasing h → $h"
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :iteration;
                      phase="A", check="one_way_shear", passed=false, h_new=string(h))
                last_failing_check = "one_way_shear"
                continue
            end
            
            # ─── A5: Flexural Adequacy (Tension-Controlled) ───
            verbose && @debug "FLEXURAL ADEQUACY CHECK (ACI 21.2.2)"
            
            flexure_result = check_flexural_adequacy(moment_results, columns, d, fc; fy = fy,
                                                     βt=_βt, verbose=verbose,
                                                     struc=struc, slab=slab,
                                                     span_axis=_get_span_axis(slab),
                                                     drop=drop_panel)
            if flexure_result.ok
                flexure_result = secondary_flexural_adequacy(
                    secondary_results, columns, d_inner_a, fc, fy; βt = _βt,
                    struc = struc, slab = slab, span_axis = _get_span_axis(slab),
                    verbose = verbose, drop = drop_panel)
            end
            
            if !flexure_result.ok
                h = _jumped_depth(h, moment_results, secondary_results)
                verbose && @warn "Flexure not tension-controlled (Rn/Rn_max=$(round(flexure_result.max_ratio, digits=2)) at $(flexure_result.governing_strip)). Increasing h → $h"
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :iteration;
                      phase="A", check="flexural_adequacy", passed=false,
                      h_new=string(h), ratio=flexure_result.max_ratio,
                      governing_strip=string(flexure_result.governing_strip))
                last_failing_check = "flexural_adequacy"
                continue
            end

            # §13.5.3 transfer steel at the column face. The strip check above
            # uses the full column-strip width; the transfer band is narrower
            # and can be the thickness that governs.
            if !_transfer_sections_adequate(
                    columns, moment_results, secondary_results, h, d, fc, fy;
                    span_axis = _get_span_axis(slab),
                    d_secondary = d_inner_a)
                h = _jumped_depth(h, moment_results, secondary_results)
                verbose && @warn "Moment transfer section inadequate. Increasing h → $h"
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :iteration;
                      phase="A", check="transfer_reinforcement", passed=false,
                      h_new=string(h))
                last_failing_check = "transfer_reinforcement"
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
            @warn "Phase A (depth) did not converge" h=h last_check=last_failing_check stop=:budget
            return _stopped(last_failing_check, h, :budget)
        end
        
        # =================================================================
        # PHASE B — PUNCHING RESOLUTION (h is locked)
        # Resolve punching via column growth and/or shear studs.
        # Column growth changes stiffness → re-run moments each iteration.
        # h is bumped only as a true last resort (breaks to outer loop).
        # =================================================================
        punching_resolved = false
        h_before_punch = h  # detect if _resolve_punching_failures! bumped h
        b_last_check = "punching_shear"
        
        # Each confirm can ask for another column step, because a larger
        # column draws more moment. Allow one confirm per remaining step.
        b_budget = monotone_budget(max_iterations, _column_steps())
        for iter_b in 1:b_budget
            total_iters += 1
            geometries = flat_plate_column_geometries(columns, slab, struc; h = h)
            
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
                _edge_beam_analysis_kwargs(opts)...,
                col_I_factor = opts.col_I_factor,
                tc = tc,
                column_concrete = column_opts.material,
            )
            
            secondary_results = if method isa FEA && !isnothing(moment_results.secondary)
                moment_results.secondary
            else
                run_secondary_moment_analysis(
                    method, struc, slab, columns, h, fc, Ecs, γ_concrete;
                    verbose=verbose, drop_panel=drop_panel, βt=_βt,
                    _edge_beam_analysis_kwargs(opts)...,
                    # ACI 318-11 §10.10.4.1 — cracked column-stub stiffness from caller (default 0.70)
                    col_I_factor = opts.col_I_factor,
                    tc = tc,
                    column_concrete = column_opts.material,
                )
            end
            
            # Column sizes may have grown since the last analysis. The
            # stiffness share is recomputed inside the assignment.
            _assign_column_design_moments!(moment_results, secondary_results)
            
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
            rejected = _flat_plate_column_pm_failure(column_result, h, total_iters, drop_panel)
            isnothing(rejected) || return rejected
            pm_grew = _update_column_sizes!(
                columns, column_result, Pu, Mu, c_span_min, column_opts, column_tol;
                Muy=Mu_secondary, verbose=verbose, geometries=geometries
            )
            # The moments above came from the smaller columns' stiffness.
            # Punching is checked only against an analysis of the installed sizes.
            if pm_grew
                b_last_check = "column_pm"
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :iteration;
                      phase="B", check="column_pm", outcome="columns_grew_reanalyze")
                continue
            end
            b_last_check = "punching_shear"
            
            # ── B2: Punching shear check ──
            verbose && @debug "PUNCHING SHEAR CHECK (ACI 22.6)"
            
            n_cols_ps = length(columns)
            # Punching check of column i at its current size against this
            # analysis' demand. Also used by the resolver to size columns and
            # reinforcement without re-running the analysis.
            # ACI 318-11 §11.11.7.1 (corpus: aci-318-11, page 209) +
            # PCA EB712 Fig. 16-13 Case D (corpus: pca-eb712, page 486):
            # corner connections take γv Mux c/Jc + γv Muy c/Jc.
            punch_check = let mr = moment_results, sr = secondary_results, h = h, d = d
                if !isnothing(drop_panel)
                    h_total = total_depth_at_drop(h, drop_panel)
                    d_total = effective_depth(h_total; cover=cover, bar_diameter=bar_dia)
                    i -> check_punching(
                        columns[i], mr.column_shears[i], mr.unbalanced_moments[i],
                        h, d, h_total, d_total, fc, drop_panel;
                        qu=mr.qu, Muy=isnothing(sr) ? nothing : sr.unbalanced_moments[i],
                        verbose=false, col_idx=i, λ=λ, φ_shear=φ_shear,
                        punching_axis_kwargs(struc, slab, columns[i])...
                    )
                else
                    i -> check_punching_for_column(
                        columns[i], mr.column_shears[i], mr.unbalanced_moments[i], d, h, fc;
                        verbose=false, col_idx=i, λ=λ, φ_shear=φ_shear,
                        Muy=isnothing(sr) ? nothing : sr.unbalanced_moments[i],
                        _geom_cache=_punch_geom_cache,
                        moment_transfer=_moment_transfer,
                        punching_axis_kwargs(struc, slab, columns[i])...
                    )
                end
            end
            for i in 1:n_cols_ps
                punching_local[i] = punch_check(i)
            end

            # Wall reactions: one critical section per connected wall
            # (§11.11.1.2). Column growth does not change that section.
            # A failing wall thickens the slab, the same last resort as a
            # column the punching levers cannot clear. Under :joint_search
            # the rescan below rejects this thickness instead.
            joint_applies = _joint && thickness_scale_applies(
                moment_results, drop_panel, h, γ_concrete; stiffness_depends_on_h = _edge_stiffness_h)
            walls_fail = false
            if hasproperty(moment_results, :qu)
                wall_checks = wall_reaction_punching(
                    struc, slab, d, fc, moment_results.qu; λ = λ, ϕ = φ_shear,
                    wall_transfer = wall_transfer_of(moment_results, secondary_results))
                walls_fail = any(c -> !c.ok, wall_checks)
                if walls_fail && !joint_applies
                    if !opts.punching_thickening
                        emit!(tc, :slab, "size_flat_plate!", _slab_id, :failure;
                              reason="wall_punching", failing_check="punching_shear",
                              h_final=string(h), iterations=total_iters)
                        return (
                            converged       = false,
                            failure_reason  = "punching_levers_exhausted",
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
                    h = _jumped_depth(h, moment_results, secondary_results; punching = true)
                    last_failing_check = "punching_shear"
                    emit!(tc, :slab, "size_flat_plate!", _slab_id, :fallback;
                          phase="B", reason="wall_punching_h_bump", h_new=string(h),
                          n_wall_checks=length(wall_checks))
                    break
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

            # ── :joint_search: thickness, columns, and studs chosen together ──
            if joint_applies
                # This analysis is at the installed sizes. Studs confirm only
                # where the search chose them; any other failure, or a failing
                # wall, is rescanned.
                failing = Int[]
                for i in all_fails
                    if i in joint_stud_cols
                        pr = punching_local[i]
                        dem = (Vu = moment_results.column_shears[i],
                               Mub = moment_results.unbalanced_moments[i],
                               Muy = isnothing(secondary_results) ? nothing :
                                     secondary_results.unbalanced_moments[i])
                        r = _try_reinforcement(opts.punching_reinforcement, pr.vu, fc, pr.b0,
                                               d, h, columns[i], opts, moment_results, dem;
                                               λ = λ, φ = φ_shear,
                                               punch_kwargs = punching_axis_kwargs(struc, slab, columns[i]))
                        if r.ok
                            punching_local[i] = _merge_reinforcement_result(pr, r)
                            continue
                        end
                    end
                    push!(failing, i)
                end
                if joint_scanned && isempty(failing) && !walls_fail
                    punching_resolved = true
                    emit!(tc, :slab, "size_flat_plate!", _slab_id, :decision;
                          phase="B", outcome="joint_confirmed", h=string(h),
                          n_studs=count(i -> get(punching_local[i], :studs, nothing) !== nothing,
                                        1:n_cols_ps),
                          punching_ratios=[round(punching_local[i].ratio, digits=3) for i in 1:n_cols_ps])
                    break
                end

                # Scan from this analysis. Columns never go below their installed size.
                scan = joint_search(moment_results, secondary_results, h, _joint_ctx(_βt))
                joint_scanned = true
                n_joint_scans += 1
                best = scan.best
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :decision;
                      phase="B", outcome="joint_search", scan=n_joint_scans,
                      objective=string(nameof(typeof(opts.objective))),
                      h_analyzed=string(h),
                      h_chosen=best === nothing ? "none" : string(best.h),
                      J=best === nothing ? NaN : best.J,
                      n_feasible=length(scan.feasible), n_rejected=length(scan.rejected),
                      candidates=[(h=string(c.h), J=c.J) for c in scan.feasible],
                      column_sizes=best === nothing ? String[] :
                          [string(o.c1) * "×" * string(o.c2) for o in best.columns],
                      n_studs=best === nothing ? 0 : count(o -> o.studs !== nothing, best.columns))
                if best === nothing
                    @warn "Joint search: no thickness up to ln/10 passes with columns within $(opts.max_column_size)" h=h
                    return _stopped("punching_shear", h, :at_limit)
                end
                empty!(joint_stud_cols)
                cols_changed = false
                for (i, o) in enumerate(best.columns)
                    o.studs === nothing || push!(joint_stud_cols, i)
                    if !(columns[i].c1 ≈ o.c1 && columns[i].c2 ≈ o.c2)
                        columns[i].c1, columns[i].c2 = o.c1, o.c2
                        cols_changed = true
                    end
                end
                last_failing_check = "punching_shear"
                if !(best.h ≈ h)
                    h = best.h   # restart Phase A at the chosen thickness
                    break
                end
                cols_changed && continue   # confirm at the chosen sizes
                for (i, o) in enumerate(best.columns)
                    punching_local[i] = o.punching
                end
                punching_resolved = true
                break
            end

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
                λ=λ, φ_shear=φ_shear, verbose=verbose,
                recheck=punch_check,
                punch_kwargs=i -> punching_axis_kwargs(struc, slab, columns[i]),
                drop=_drop_depths(drop_panel, h, cover, bar_dia),
            )
            
            # Punching levers exhausted and thickening not allowed: stop as a failure
            if h != h_before_punch && !opts.punching_thickening
                emit!(tc, :slab, "size_flat_plate!", _slab_id, :failure;
                      reason="punching_levers_exhausted", failing_check="punching_shear",
                      h_final=string(h_before_punch), iterations=total_iters)
                return (
                    converged       = false,
                    failure_reason  = "punching_levers_exhausted",
                    failing_check   = "punching_shear",
                    iterations      = total_iters,
                    h_final         = h_before_punch,
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

            # If h was bumped (last resort), break to outer loop → restart Phase A
            if h != h_before_punch
                last_failing_check = "punching_shear"
                h = _jumped_depth(h_before_punch, moment_results, secondary_results; punching = true)
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
                Pu = slab_column_axial_loads(struc, slab, columns, slab_cell_indices, sw_estimate,
                    drop_panel, γ_concrete)
                _prev_h = h
                continue  # outer loop → Phase A
            end
            ratios = [isassigned(punching_local, i) ? punching_local[i].ratio : -Inf
                      for i in eachindex(columns)]
            worst = argmax(ratios)
            @warn "Phase B did not converge" h=h stop=:budget last_check=b_last_check iterations=total_iters column=worst ratio=ratios[worst] c1=columns[worst].c1 c2=columns[worst].c2
            return _stopped(b_last_check, h, :budget)
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
            material; verbose=verbose, analysis_cache=analysis_cache,
            defer_asap_process=defer_asap_process,
            update_analysis_model=update_analysis_model,
        )
        
        # If rebar design failed, bump h and restart from Phase A
        if hasproperty(result, :converged) && result.converged
            governing = _governing_check_label(last_failing_check, opts.min_h)
            result = merge(result, (
                governing_check = governing,
                one_way_shear = one_way_shear_report,
            ))
            emit!(tc, :slab, "size_flat_plate!", _slab_id, :exit;
                  converged=true, h_final=string(h), h_initial=string(h_initial),
                  iterations=total_iters,
                  governing_check=governing,
                  column_sizes=[string(col.c1) * "×" * string(col.c2) for col in columns],
                  _fea_passes()...)
        end
        if hasproperty(result, :needs_more_depth) && result.needs_more_depth
            h = round_up_thickness(h + h_increment, h_increment)
            verbose && @warn "Rebar design failed (section inadequate). Increasing h → $h, restarting Phase A."
            last_failing_check = "reinforcement_design"
            # Update h-dependent state for next Phase A
            d = effective_depth(h; cover=cover, bar_diameter=bar_dia)
            sw_estimate = slab_sw(h)
            Pu = slab_column_axial_loads(struc, slab, columns, slab_cell_indices, sw_estimate,
                drop_panel, γ_concrete)
            _prev_h = h
            continue  # outer loop → Phase A
        end
        
        return result
    end  # outer loop
    
    # ─── Non-convergence: the outer budget ran out while depth was still moving ───
    @warn "Flat plate design did not converge" last_check=last_failing_check h_final=h stop=:budget
    return _stopped(last_failing_check, h, :budget)
end
