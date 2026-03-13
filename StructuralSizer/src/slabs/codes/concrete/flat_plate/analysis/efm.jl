# =============================================================================
# Equivalent Frame Method (EFM) - ACI 318-11 §13.7
# =============================================================================
#
# Stiffness-based frame analysis for flat plate moment distribution.
#
# The equivalent frame models:
# 1. Slab-beam strips (horizontal members with enhanced stiffness at columns)
# 2. Equivalent columns (K_ec = combined column + torsional stiffness)
#
# Reference:
# - ACI 318-11 §13.7
# - StructurePoint DE-Two-Way-Flat-Plate Section 3.2
# - PCA Notes on ACI 318-11 Tables A1, A7
#
# =============================================================================

using Logging
using Asap

# =============================================================================
# EFM Model Cache (reuse Asap model across iterations)
# =============================================================================

"""
    EFMModelCache

Mutable cache that holds a built EFM Asap model so it can be reused across
design iterations.  Only the element section properties and load magnitudes
are updated; the topology (nodes, DOFs, connectivity) stays fixed.

Column stubs follow the same pattern as `FEAModelCache`: each joint stores
a `(below=..., above=...)` named tuple with the element and its fixed-end
node.  Roof joints have `above = nothing`.

Create with `EFMModelCache()` before the design loop and pass as the
`efm_cache` keyword to `run_moment_analysis`.
"""
mutable struct EFMModelCache
    initialized::Bool
    model::Union{Nothing, Model}                 # Asap.Model
    span_elements::Vector{Element{FixedFixed}}   # slab-beam elements
    col_stubs::Dict{Int, NamedTuple}             # j => (below=..., above=...)
    n_spans::Int
    # Span property cache (skip rebuild when column sizes + h unchanged)
    _last_span_key::Union{Nothing, UInt64}
    _last_spans::Union{Nothing, Vector}

    EFMModelCache() = new(false, nothing, Element{FixedFixed}[], Dict{Int,NamedTuple}(), 0,
                          nothing, nothing)
end

"""Populate an EFMModelCache from a freshly built model."""
function _populate_efm_cache!(cache::EFMModelCache, model, span_elements, col_stubs, spans)
    cache.initialized    = true
    cache.model          = model
    cache.span_elements  = collect(Element{FixedFixed}, span_elements)
    cache.col_stubs      = col_stubs
    cache.n_spans        = length(spans)
end

"""
    _update_efm_sections_and_loads!(cache, spans, qu, Ecs, Ecc, ν_concrete, ρ_concrete, columns;
                                    col_I_factor)

Update section properties and loads on a cached EFM ASAP model.

Slab-beam sections are rebuilt from the current `h` and `l2`.  Column stub
sections are updated via `column_asap_section` — the same single source of
truth used by the FEA path.  No Kec → Ic_eff back-solve; the ASAP solver
computes column stiffness from actual geometry.
"""
function _update_efm_sections_and_loads!(
    cache::EFMModelCache,
    spans::Vector{<:EFMSpanProperties},
    qu::Pressure,
    Ecs::Pressure,
    Ecc::Pressure,
    ν_concrete::Float64,
    ρ_concrete,
    columns;
    col_I_factor::Float64 = 0.70,
    kec_factors::Union{Nothing, Vector{Float64}} = nothing,
)
    model = cache.model
    span_elements = cache.span_elements
    n_spans  = cache.n_spans

    h  = spans[1].h
    l2 = spans[1].l2
    ustrip(l2) > 0 || throw(ArgumentError("Transverse span l2 must be positive (got $l2)"))

    G_slab  = Ecs / (2 * (1 + ν_concrete))
    Is_gross = l2 * h^3 / 12
    A_slab   = l2 * h
    J_slab   = _torsional_constant_rect(l2, h)

    Ecs_Pa = uconvert(u"Pa", Ecs)
    G_slab_Pa = uconvert(u"Pa", G_slab)

    # ── Slab sections (3 per span) ──
    clear_sec = Section(
        uconvert(u"m^2", A_slab), Ecs_Pa, G_slab_Pa,
        uconvert(u"m^4", Is_gross),
        uconvert(u"m^4", Is_gross / 10),
        uconvert(u"m^4", J_slab),
        ρ_concrete
    )

    n_elems_per_span = length(span_elements) ÷ n_spans

    for i in 1:n_spans
        sp = spans[i]

        # ACI 318-11 §13.7.3.3 rigid-zone I
        ratio_left  = ustrip(sp.c2_left)  / ustrip(uconvert(unit(sp.c2_left), l2))
        ratio_right = ustrip(sp.c2_right) / ustrip(uconvert(unit(sp.c2_right), l2))
        # Cap ratio below 1.0 to avoid singularity; column wider than span is non-physical
        ratio_left  = min(ratio_left, 0.99)
        ratio_right = min(ratio_right, 0.99)
        Is_rigid_left  = Is_gross / (1 - ratio_left)^2
        Is_rigid_right = Is_gross / (1 - ratio_right)^2

        rigid_sec_left = Section(
            uconvert(u"m^2", A_slab), Ecs_Pa, G_slab_Pa,
            uconvert(u"m^4", Is_rigid_left),
            uconvert(u"m^4", Is_rigid_left / 10),
            uconvert(u"m^4", J_slab),
            ρ_concrete
        )
        rigid_sec_right = Section(
            uconvert(u"m^2", A_slab), Ecs_Pa, G_slab_Pa,
            uconvert(u"m^4", Is_rigid_right),
            uconvert(u"m^4", Is_rigid_right / 10),
            uconvert(u"m^4", J_slab),
            ρ_concrete
        )

        if n_elems_per_span == 3
            idx_base = 3 * (i - 1)
            span_elements[idx_base + 1].section = rigid_sec_left
            span_elements[idx_base + 2].section = clear_sec
            span_elements[idx_base + 3].section = rigid_sec_right
        else
            span_elements[i].section = clear_sec
        end
    end

    # ── Column stub sections (same as FEA: column_asap_section) ──
    n_joints = n_spans + 1
    for j in 1:n_joints
        haskey(cache.col_stubs, j) || continue
        stubs = cache.col_stubs[j]
        col = columns[j]

        I_j = col_I_factor * (!isnothing(kec_factors) ? kec_factors[j] : 1.0)

        # Below stub (always present)
        stubs.below.element.section = column_asap_section(
            col.c1, col.c2, col_shape(col), Ecc, ν_concrete; I_factor=I_j)

        # Above stub (if column above exists)
        col_above = col.column_above
        if !isnothing(stubs.above) && !isnothing(col_above)
            stubs.above.element.section = column_asap_section(
                col_above.c1, col_above.c2, col_shape(col_above), Ecc, ν_concrete;
                I_factor=I_j)
        end
    end

    # ── Loads ──
    w_N_m = uconvert(u"N/m", qu * l2)
    for load in model.loads
        load.value = [0.0u"N/m", 0.0u"N/m", -w_N_m]
    end

    # Invalidate cached state so next solve! re-processes
    model._factorization = nothing
    model.processed = false
end

# =============================================================================
# EFM Moment Analysis
# =============================================================================

"""
    run_moment_analysis(method::EFM, struc, slab, columns, h, fc, Ecs, γ_concrete; kwargs...)

Run moment analysis using Equivalent Frame Method (EFM).

EFM models the slab strip as a continuous beam supported on equivalent columns.
Behavior is controlled by `method.solver`, `method.column_stiffness`, and
`method.cracked_columns` — see [`EFM`](@ref) for the full option matrix.

# Returns
`MomentAnalysisResult` with all moments and geometry data.

# Reference
- ACI 318-11 §13.7
- StructurePoint Table 5 (EFM Moments)
"""
function run_moment_analysis(
    method::EFM,
    struc,
    slab,
    supporting_columns,
    h::Length,
    fc::Pressure,
    Ecs::Pressure,
    γ_concrete;
    ν_concrete::Float64 = 0.20,
    verbose::Bool = false,
    efm_cache::Union{Nothing, EFMModelCache} = nothing,
    cache = nothing,  # API parity (unused by EFM)
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    βt::Float64 = 0.0,  # API parity (unused by EFM — torsion captured in Kt)
    col_I_factor::Float64 = 0.70,  # ignored — determined by method.cracked_columns
)
    # Derive col_I_factor from method fields:
    #   - ASAP stubs: gross Ig (1.0) unless cracked_columns=true (0.70)
    #   - Hardy Cross: always gross Ig (PCA convention, stiffness in Kec)
    col_I_factor = (method.solver == :asap && method.cracked_columns) ? 0.70 : 1.0
    use_kc_only = method.column_stiffness == :Kc

    # Shared setup: l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0
    setup = _moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, c1_avg, qD, qL, qu, M0) = setup
    n_cols = length(supporting_columns)
    
    # Detect column shape (use first column's shape, default :rectangular)
    col_shape_val = col_shape(first(supporting_columns))
    
    if verbose
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "MOMENT ANALYSIS - EFM (Equivalent Frame Method)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Solver" solver=method.solver column_stiffness=method.column_stiffness cracked=method.cracked_columns
        @debug "Geometry" l1=l1 l2=l2 ln=ln c_avg=c1_avg h=h
        @debug "Loads" qD=qD qL=qL qu=qu
        @debug "Reference M₀" M0=uconvert(kip*u"ft", M0)
    end
    
    # Get column concrete strength (may differ from slab)
    fc_col = _get_column_fc(supporting_columns, fc)
    wc_pcf = ustrip(pcf, γ_concrete)                 # mass density → pcf
    Ecc = Ec(fc_col, wc_pcf)                          # ACI 19.2.2.1.a: 33 × wc^1.5 × √f'c
    
    # Get column height
    H = _get_column_height(supporting_columns)
    
    # Build EFM span properties (with drop panel geometry if flat slab)
    # Cache spans: only column sizes and h matter for span stiffness properties.
    # If neither changed, reuse previous spans (avoids redundant Ksb computation).
    _span_key = hash((
        h, Ecs,
        ntuple(i -> (supporting_columns[i].c1, supporting_columns[i].c2), n_cols)...,
    ))
    if !isnothing(efm_cache) && efm_cache.initialized &&
       hasproperty(efm_cache, :_last_span_key) && efm_cache._last_span_key == _span_key
        spans = efm_cache._last_spans
    else
        spans = _build_efm_spans(supporting_columns, l1, l2, ln, h, Ecs; drop_panel=drop_panel)
        if !isnothing(efm_cache)
            efm_cache._last_span_key = _span_key
            efm_cache._last_spans = spans
        end
    end
    
    # Determine joint positions
    joint_positions = [col.position for col in supporting_columns]
    
    # ─── Pattern loading check (ACI 318-11 §13.7.6) ───
    n_spans = length(spans)
    use_pattern = method.pattern_loading && requires_pattern_loading(qD, qL) && n_spans >= 2
    
    # Precompute joint Kec for Hardy Cross (invariant across pattern cases)
    _cached_jKec = method.solver == :hardy_cross ?
        _compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc; 
                           column_shape=col_shape_val, use_kc_only=use_kc_only,
                           columns=supporting_columns) :
        nothing
    
    # Kec reduction factors for ASAP column stubs (ACI 318-11 §13.7.4)
    # When column_stiffness=:Kec, soften stubs by Kec/ΣKc to match the
    # torsional flexibility that Hardy Cross captures via Kec.
    _kec_factors = method.solver == :asap ?
        _compute_kec_reduction_factors(spans, joint_positions, H, Ecs, Ecc;
                                       column_shape=col_shape_val, use_kc_only=use_kc_only,
                                       columns=supporting_columns) :
        nothing
    
    # ─── Helper: run solver once for a given (scalar or per-span) load ───
    function _solve_once(qu_arg)
        if method.solver == :asap
            if !isnothing(efm_cache) && efm_cache.initialized
                _update_efm_sections_and_loads!(
                    efm_cache, spans, qu, Ecs, Ecc,
                    ν_concrete, γ_concrete, supporting_columns;
                    col_I_factor = col_I_factor,
                    kec_factors = _kec_factors,
                )
                # Override per-span loads for pattern loading
                _is_pattern = qu_arg isa Vector
                if _is_pattern
                    n_loads = length(efm_cache.model.loads)
                    n_per_span = n_loads ÷ n_spans
                    for (i, load) in enumerate(efm_cache.model.loads)
                        span_idx = (i - 1) ÷ n_per_span + 1
                        span_idx > n_spans && break
                        w_N_m = uconvert(u"N/m", qu_arg[span_idx] * l2)
                        load.value = [0.0u"N/m", 0.0u"N/m", -w_N_m]
                    end
                end
                solve_efm_frame!(efm_cache.model; full_process=false, loads_only=_is_pattern)
                return extract_span_moments(
                    efm_cache.model, efm_cache.span_elements, spans; qu=qu
                )
            else
                model, span_elements, col_stubs = build_efm_asap_model(
                    spans, joint_positions, qu;
                    Ecs = Ecs, Ecc = Ecc,
                    ν_concrete = ν_concrete,
                    ρ_concrete = γ_concrete,
                    columns = supporting_columns,
                    verbose = verbose,
                    col_I_factor = col_I_factor,
                    kec_factors = _kec_factors,
                )
                # Override per-span loads for pattern loading
                if qu_arg isa Vector
                    n_loads = length(model.loads)
                    n_per_span = n_loads ÷ n_spans
                    for (i, load) in enumerate(model.loads)
                        span_idx = (i - 1) ÷ n_per_span + 1
                        span_idx > n_spans && break
                        w_N_m = uconvert(u"N/m", qu_arg[span_idx] * l2)
                        load.value = [0.0u"N/m", 0.0u"N/m", -w_N_m]
                    end
                end
                solve_efm_frame!(model)
                sm = extract_span_moments(model, span_elements, spans; qu=qu)

                !isnothing(efm_cache) && _populate_efm_cache!(efm_cache, model, span_elements, col_stubs, spans)
                return sm
            end

        elseif method.solver == :hardy_cross
            return solve_moment_distribution(spans, _cached_jKec, joint_positions, qu_arg; verbose=false)
        else
            error("Unknown EFM solver: $(method.solver)")
        end
    end
    
    # ─── Run full-load case (always needed as baseline) ───
    span_moments = _solve_once(qu)
    
    if verbose
        solver_name = method.solver == :asap ? "EFM FRAME" : "MOMENT DISTRIBUTION"
        @debug "───────────────────────────────────────────────────────────────────"
        @debug "$(solver_name) RESULTS$(use_pattern ? " (full-load baseline)" : "")"
        @debug "───────────────────────────────────────────────────────────────────"
        for (i, sm) in enumerate(span_moments)
            @debug "Span $i" M_neg_left=uconvert(kip*u"ft", sm.M_neg_left) M_pos=uconvert(kip*u"ft", sm.M_pos) M_neg_right=uconvert(kip*u"ft", sm.M_neg_right)
        end
    end
    
    M_neg_ext = span_moments[1].M_neg_left
    M_neg_int = span_moments[1].M_neg_right
    M_pos = span_moments[1].M_pos
    
    # ─── Pattern loading envelope (ACI 318-11 §13.7.6) ───
    # When L/D > 0.75, run checkerboard and adjacent patterns to capture
    # the maximum moments at each location.  The envelope governs design.
    if use_pattern
        patterns = generate_load_patterns(n_spans)
        
        for (ip, pattern) in enumerate(patterns)
            # Skip full-load case (already run above)
            all(==(:dead_plus_live), pattern) && continue
            
            qu_per_span = factored_pattern_loads(pattern, qD, qL)
            sm_pat = _solve_once(qu_per_span)
            
            # Envelope: take maximum absolute moment at each location
            pat_neg_ext = sm_pat[1].M_neg_left
            pat_neg_int = sm_pat[1].M_neg_right
            pat_pos     = sm_pat[1].M_pos
            
            abs(pat_neg_ext) > abs(M_neg_ext) && (M_neg_ext = pat_neg_ext)
            abs(pat_neg_int) > abs(M_neg_int) && (M_neg_int = pat_neg_int)
            abs(pat_pos)     > abs(M_pos)     && (M_pos     = pat_pos)
        end
        
        if verbose
            @debug "PATTERN LOADING ENVELOPE (ACI 13.7.6, L/D > 0.75)" M_neg_ext=uconvert(kip*u"ft", M_neg_ext) M_neg_int=uconvert(kip*u"ft", M_neg_int) M_pos=uconvert(kip*u"ft", M_pos)
        end
    end
    
    # Build column-level results (from full-load span_moments — conservative
    # for column shears and unbalanced moments)
    column_moments, column_shears, unbalanced_moments = _compute_efm_column_demands(
        struc, supporting_columns, span_moments, qu, l2, ln
    )
    
    # Convert all outputs to consistent US units for MomentAnalysisResult
    M0_conv = uconvert(kip * u"ft", M0)
    M_neg_ext_conv = uconvert(kip * u"ft", M_neg_ext)
    M_neg_int_conv = uconvert(kip * u"ft", M_neg_int)
    M_pos_conv = uconvert(kip * u"ft", M_pos)
    Vu_max = uconvert(kip, qu * l2 * ln / 2)
    
    return MomentAnalysisResult(
        M0_conv,
        M_neg_ext_conv,
        M_neg_int_conv,
        M_pos_conv,
        qu, qD, qL,
        uconvert(u"ft", l1),
        uconvert(u"ft", l2),
        uconvert(u"ft", ln),
        uconvert(u"ft", c1_avg),
        column_moments,
        column_shears,
        unbalanced_moments,
        Vu_max;
        pattern_loading = use_pattern,
    )
end


# =============================================================================
# Secondary (Perpendicular) Direction — EFM
# =============================================================================

"""
    run_secondary_moment_analysis(method::EFM, struc, slab, columns, h, fc, Ecs, γ_concrete; kwargs...) -> MomentAnalysisResult

Run EFM in the perpendicular direction (swapped l1↔l2).

Builds a fresh equivalent frame for the perpendicular direction using
`_secondary_moment_analysis_setup`.  The EFM span properties, joint Kec,
and moment distribution are recomputed for the swapped geometry — the frame
model cannot be reused because stiffnesses change when l1↔l2 swap and the
column dimension facing the span switches from c1 to c2.

Returns a full `MomentAnalysisResult` for consistency with the primary direction.
"""
function run_secondary_moment_analysis(
    method::EFM,
    struc, slab, supporting_columns, h::Length,
    fc::Pressure, Ecs::Pressure, γ_concrete;
    ν_concrete::Float64 = 0.20,
    verbose::Bool = false,
    drop_panel = nothing,
    kwargs...
)
    use_kc_only = method.column_stiffness == :Kc

    setup = _secondary_moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0) = setup
    n_cols = length(supporting_columns)

    col_shape_val = col_shape(first(supporting_columns))
    fc_col = _get_column_fc(supporting_columns, fc)
    wc_pcf = ustrip(pcf, γ_concrete)
    Ecc = Ec(fc_col, wc_pcf)
    H = _get_column_height(supporting_columns)

    # Build EFM spans for perpendicular direction (fresh — no cache reuse)
    spans = _build_efm_spans(supporting_columns, l1, l2, ln, h, Ecs; drop_panel=drop_panel)
    joint_positions = [col.position for col in supporting_columns]

    n_spans = length(spans)
    use_pattern = method.pattern_loading && requires_pattern_loading(qD, qL) && n_spans >= 2

    # Solve via moment distribution (lightweight, always available)
    jKec = _compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc; 
                              column_shape=col_shape_val, use_kc_only=use_kc_only,
                              columns=supporting_columns)
    span_moments = solve_moment_distribution(spans, jKec, joint_positions, qu; verbose=false)

    M_neg_ext = span_moments[1].M_neg_left
    M_neg_int = span_moments[1].M_neg_right
    M_pos = span_moments[1].M_pos

    if use_pattern
        for pat in generate_load_patterns(n_spans)
            all(==(:dead_plus_live), pat) && continue
            qu_ps = factored_pattern_loads(pat, qD, qL)
            sm_pat = solve_moment_distribution(spans, jKec, joint_positions, qu_ps; verbose=false)
            abs(sm_pat[1].M_neg_left)  > abs(M_neg_ext) && (M_neg_ext = sm_pat[1].M_neg_left)
            abs(sm_pat[1].M_neg_right) > abs(M_neg_int) && (M_neg_int = sm_pat[1].M_neg_right)
            abs(sm_pat[1].M_pos)       > abs(M_pos)     && (M_pos     = sm_pat[1].M_pos)
        end
    end

    column_moments, column_shears, unbalanced_moments = _compute_efm_column_demands(
        struc, supporting_columns, span_moments, qu, l2, ln
    )

    if verbose
        @debug "EFM SECONDARY DIRECTION" l1=l1 l2=l2 ln=ln M0=uconvert(kip*u"ft", M0)
    end

    # Return full MomentAnalysisResult for consistency with primary direction
    Vu_max = uconvert(kip, qu * l2 * ln / 2)
    return MomentAnalysisResult(
        uconvert(kip * u"ft", M0),
        uconvert(kip * u"ft", M_neg_ext),
        uconvert(kip * u"ft", M_neg_int),
        uconvert(kip * u"ft", M_pos),
        qu, qD, qL,
        uconvert(u"ft", l1),
        uconvert(u"ft", l2),
        uconvert(u"ft", ln),
        uconvert(u"ft", c1_avg),
        column_moments,
        column_shears,
        unbalanced_moments,
        Vu_max;
        pattern_loading = use_pattern,
    )
end

# =============================================================================
# EFM Joint Stiffness Computation
# =============================================================================

"""
    _compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc; columns=nothing, ...)

Compute equivalent column stiffness Kec at each joint.

Kec combines column and torsional stiffness in series:
    1/Kec = 1/ΣKc + 1/ΣKt

Column stiffness factor `k_col` is looked up from PCA Table A7 based on
actual `H/Hc` ratio (replacing the old hardcoded PCA_K_COL = 4.74).

When `columns` is provided, `ΣKc` is computed as `Kc_below + Kc_above`
where `Kc_above` uses the column above's dimensions and height (if it exists).
At the roof level (no column above), `ΣKc = Kc_below` only.

When `columns` is `nothing` (legacy), assumes identical columns above and
below (`ΣKc = 2 × Kc`).

# Returns
Vector of Kec values (in Moment units) for each joint.

# Options
- `columns`: Optional sorted column vector (same order as joints).
  When provided, uses `col.column_above` for accurate above/below stiffness.
- `use_kc_only::Bool`: If `true`, skip torsional reduction and use raw column
  stiffness `Kc` instead of equivalent `Kec` (set by `EFM(column_stiffness=:Kc)`).
  Default: `false`.
"""
function _compute_joint_Kec(
    spans::Vector{<:EFMSpanProperties},
    joint_positions::Vector{Symbol},
    H::Length,
    Ecs::Pressure,
    Ecc::Pressure;
    column_shape::Symbol = :rectangular,
    use_kc_only::Bool = false,
    columns = nothing,
)
    n_spans = length(spans)
    n_joints = n_spans + 1
    h = spans[1].h
    l2 = spans[1].l2
    has_drops = has_drop_panels(spans[1])

    # Column stiffness factor from PCA Table A7 (geometry-dependent)
    col_factors = pca_column_factors(H, h)
    k_col = col_factors.k
    
    joint_Kec = Vector{Moment}(undef, n_joints)
    
    for j in 1:n_joints
        # Get column dimensions at this joint (below column)
        if j == 1
            c1 = spans[1].c1_left
            c2 = spans[1].c2_left
        elseif j == n_joints
            c1 = spans[end].c1_right
            c2 = spans[end].c2_right
        else
            c1 = (spans[j-1].c1_right + spans[j].c1_left) / 2
            c2 = (spans[j-1].c2_right + spans[j].c2_left) / 2
        end
        
        # For circular columns, use equivalent square for torsional calc
        c2_torsion = column_shape == :circular ? equivalent_square_column(c2) : c2
        
        # Column stiffness below (always present)
        Ic = column_moment_of_inertia(c1, c2; shape=column_shape)
        Kc_below = column_stiffness_Kc(Ecc, Ic, H, h; k_factor=k_col)

        # Column stiffness above: use actual column_above when available
        col_above = !isnothing(columns) ? columns[j].column_above : nothing
        if !isnothing(col_above)
            c1_a = col_above.c1
            c2_a = col_above.c2
            H_a  = col_above.base.L
            col_factors_a = pca_column_factors(H_a, h)
            Ic_a = column_moment_of_inertia(c1_a, c2_a; shape=column_shape)
            Kc_above = column_stiffness_Kc(Ecc, Ic_a, H_a, h; k_factor=col_factors_a.k)
        elseif isnothing(columns)
            # Legacy fallback: assume identical column above
            Kc_above = Kc_below
        else
            # Roof: no column above
            Kc_above = zero(Kc_below)
        end
        ΣKc = Kc_below + Kc_above
        
        if use_kc_only
            # column_stiffness=:Kc — raw column stiffness (no torsional reduction)
            joint_Kec[j] = ΣKc
        else
            # Standard EFM: combine with torsional flexibility
            # Torsional stiffness: use total depth at drop panel (if present) for C
            if has_drops
                drop = spans[1].drop
                h_total = total_depth_at_drop(h, drop)
                C = torsional_constant_C(h_total, c2_torsion)
            else
                C = torsional_constant_C(h, c2_torsion)
            end
            
            Kt_single = torsional_member_stiffness_Kt(Ecs, C, l2, c2_torsion)
            n_torsion = joint_positions[j] == :interior ? 2 : 1
            ΣKt = n_torsion * Kt_single
            
            joint_Kec[j] = equivalent_column_stiffness_Kec(ΣKc, ΣKt)
        end
    end
    
    return joint_Kec
end

"""
    _compute_kec_reduction_factors(spans, joint_positions, H, Ecs, Ecc; kwargs...)
        -> Vector{Float64}

Compute the Kec / ΣKc ratio at each joint.

When `column_stiffness = :Kec`, the ASAP column stubs must be softened to
account for the torsional flexibility that Kec captures.  This function
returns the per-joint reduction factor α = Kec / ΣKc (≤ 1.0) that should
multiply the column stub I_factor.

When `use_kc_only = true`, returns `ones(n_joints)` (no reduction).
"""
function _compute_kec_reduction_factors(
    spans::Vector{<:EFMSpanProperties},
    joint_positions::Vector{Symbol},
    H::Length,
    Ecs::Pressure,
    Ecc::Pressure;
    column_shape::Symbol = :rectangular,
    use_kc_only::Bool = false,
    columns = nothing,
)
    n_spans = length(spans)
    n_joints = n_spans + 1

    use_kc_only && return ones(n_joints)

    h = spans[1].h
    l2 = spans[1].l2
    has_drops = has_drop_panels(spans[1])

    col_factors = pca_column_factors(H, h)
    k_col = col_factors.k

    factors = Vector{Float64}(undef, n_joints)

    for j in 1:n_joints
        # Column dimensions at this joint
        if j == 1
            c1 = spans[1].c1_left
            c2 = spans[1].c2_left
        elseif j == n_joints
            c1 = spans[end].c1_right
            c2 = spans[end].c2_right
        else
            c1 = (spans[j-1].c1_right + spans[j].c1_left) / 2
            c2 = (spans[j-1].c2_right + spans[j].c2_left) / 2
        end

        c2_torsion = column_shape == :circular ? equivalent_square_column(c2) : c2

        # ΣKc (below + above)
        Ic = column_moment_of_inertia(c1, c2; shape=column_shape)
        Kc_below = column_stiffness_Kc(Ecc, Ic, H, h; k_factor=k_col)

        col_above = !isnothing(columns) ? columns[j].column_above : nothing
        if !isnothing(col_above)
            c1_a = col_above.c1; c2_a = col_above.c2; H_a = col_above.base.L
            col_factors_a = pca_column_factors(H_a, h)
            Ic_a = column_moment_of_inertia(c1_a, c2_a; shape=column_shape)
            Kc_above = column_stiffness_Kc(Ecc, Ic_a, H_a, h; k_factor=col_factors_a.k)
        elseif isnothing(columns)
            Kc_above = Kc_below
        else
            Kc_above = zero(Kc_below)
        end
        ΣKc = Kc_below + Kc_above

        # Kec
        if has_drops
            drop = spans[1].drop
            h_total = total_depth_at_drop(h, drop)
            C = torsional_constant_C(h_total, c2_torsion)
        else
            C = torsional_constant_C(h, c2_torsion)
        end
        Kt_single = torsional_member_stiffness_Kt(Ecs, C, l2, c2_torsion)
        n_torsion = joint_positions[j] == :interior ? 2 : 1
        ΣKt = n_torsion * Kt_single

        Kec = equivalent_column_stiffness_Kec(ΣKc, ΣKt)

        # α = Kec / ΣKc  (≤ 1.0)
        ΣKc_val = ustrip(u"lbf*inch", ΣKc)
        Kec_val = ustrip(u"lbf*inch", Kec)
        factors[j] = ΣKc_val > 0 ? clamp(Kec_val / ΣKc_val, 0.0, 1.0) : 1.0
    end

    return factors
end

# =============================================================================
# EFM ASAP Model Building
# =============================================================================

"""
    build_efm_asap_model(spans, joint_positions, qu; kwargs...)

Build an ASAP frame model for EFM analysis using **3 sub-elements per span**
(rigid zone – clear span – rigid zone) and explicit column stubs.

# Slab-Beam Model (ACI 318-11 §13.7.3.3)

Each span is modeled with 3 elements:
1. **Rigid zone (left)**: column center to column face, length = c₁_left/2.
   Moment of inertia amplified per §13.7.3.3:
       I_rigid = I_s / (1 - c₂/l₂)²
2. **Clear span**: face-to-face, length = l_n.
   Gross moment of inertia: I_s = l₂ × h³ / 12.
3. **Rigid zone (right)**: column face to column center, length = c₁_right/2.
   Same amplified I_rigid.

This eliminates the need for the PCA Table A1 stiffness factor `k_slab`
in the ASAP path — the solver computes exact stiffness, carry-over, and
moment distribution from the actual non-prismatic geometry.

# Column Model

Each joint gets up to two column frame elements (same pattern as FEA):
- **Below column** (always present): fixed base at z = −Lc → slab node (z = 0)
- **Above column** (if `col.column_above` exists): slab node → fixed top at z = +Lc_above

Section properties come from `column_asap_section` (single source of truth),
with I_factor = 0.70 per ACI 318-11 §10.10.4.1.  The ASAP solver computes
column stiffness from actual geometry — no Kec → Ic_eff back-solve.

Roof joints get only the below stub; intermediate joints get both.
Unequal columns above/below are handled naturally.

# Arguments
- `columns`: Vector of column objects (one per joint), each with fields
  `c1`, `c2`, `base.L` (column length), and `column_above` (column above
  or `nothing` for roof).  NamedTuples work fine for tests.

# Returns
- `model`: ASAP Model ready to solve
- `span_elements`: Vector of slab-beam elements (3 per span)
- `col_stubs`: Dict{Int, NamedTuple} — joint index → (below=..., above=...)

# Reference
- ACI 318-11 §13.7.3.3 — Slab-beam moment of inertia at column regions
- ACI 318-11 §10.10.4.1 — Column cracking reduction factor
"""
function build_efm_asap_model(
    spans::Vector{<:EFMSpanProperties},
    joint_positions::Vector{Symbol},
    qu::Pressure;
    Ecs::Pressure,
    Ecc::Pressure,
    ν_concrete::Float64,
    ρ_concrete,
    columns,
    verbose::Bool = false,
    col_I_factor::Float64 = 0.70,
    kec_factors::Union{Nothing, Vector{Float64}} = nothing,
)
    n_spans = length(spans)
    n_joints = n_spans + 1

    l2 = spans[1].l2
    h  = spans[1].h

    Ecs_Pa = uconvert(u"Pa", Ecs)
    G_slab = Ecs / (2 * (1 + ν_concrete))
    ρ = ρ_concrete

    # ── Build nodes ──
    nodes = Node[]
    slab_dofs = [true, false, true, false, true, false]  # XZ plane frame

    # Column-center nodes (one per joint)
    slab_node_indices = Int[]
    x_pos = 0.0u"m"
    for j in 1:n_joints
        push!(nodes, Node([x_pos, 0.0u"m", 0.0u"m"], slab_dofs))
        push!(slab_node_indices, length(nodes))
        if j < n_joints
            x_pos += uconvert(u"m", spans[j].l1)
        end
    end

    # Face-of-column nodes (2 per span: left face, right face)
    face_node_indices = Vector{NTuple{2, Int}}(undef, n_spans)
    for i in 1:n_spans
        sp = spans[i]
        x_left_center = nodes[slab_node_indices[i]].position[1]
        x_right_center = nodes[slab_node_indices[i+1]].position[1]

        c1_left_half  = uconvert(u"m", sp.c1_left / 2)
        c1_right_half = uconvert(u"m", sp.c1_right / 2)

        x_left_face  = x_left_center + c1_left_half
        x_right_face = x_right_center - c1_right_half

        push!(nodes, Node([x_left_face, 0.0u"m", 0.0u"m"], slab_dofs))
        idx_lf = length(nodes)
        push!(nodes, Node([x_right_face, 0.0u"m", 0.0u"m"], slab_dofs))
        idx_rf = length(nodes)
        face_node_indices[i] = (idx_lf, idx_rf)
    end

    # ── Build slab-beam elements (3 per span) ──
    elements = Element[]
    span_elements = Element[]

    Is_gross = l2 * h^3 / 12
    A_slab   = l2 * h
    J_slab   = _torsional_constant_rect(l2, h)

    clear_sec = Section(
        uconvert(u"m^2", A_slab),
        Ecs_Pa,
        uconvert(u"Pa", G_slab),
        uconvert(u"m^4", Is_gross),
        uconvert(u"m^4", Is_gross / 10),
        uconvert(u"m^4", J_slab),
        ρ
    )

    for i in 1:n_spans
        sp = spans[i]
        (idx_lf, idx_rf) = face_node_indices[i]

        # Rigid-zone section: ACI 318-11 §13.7.3.3
        c2_left  = sp.c2_left
        c2_right = sp.c2_right
        ratio_left  = ustrip(c2_left) / ustrip(uconvert(unit(c2_left), l2))
        ratio_right = ustrip(c2_right) / ustrip(uconvert(unit(c2_right), l2))
        ratio_left  = min(ratio_left, 0.99)
        ratio_right = min(ratio_right, 0.99)
        Is_rigid_left  = Is_gross / (1 - ratio_left)^2
        Is_rigid_right = Is_gross / (1 - ratio_right)^2

        rigid_sec_left = Section(
            uconvert(u"m^2", A_slab), Ecs_Pa, uconvert(u"Pa", G_slab),
            uconvert(u"m^4", Is_rigid_left),
            uconvert(u"m^4", Is_rigid_left / 10),
            uconvert(u"m^4", J_slab), ρ
        )
        rigid_sec_right = Section(
            uconvert(u"m^2", A_slab), Ecs_Pa, uconvert(u"Pa", G_slab),
            uconvert(u"m^4", Is_rigid_right),
            uconvert(u"m^4", Is_rigid_right / 10),
            uconvert(u"m^4", J_slab), ρ
        )

        e_rigid_L = Element(nodes[slab_node_indices[i]], nodes[idx_lf], rigid_sec_left)
        e_clear   = Element(nodes[idx_lf], nodes[idx_rf], clear_sec)
        e_rigid_R = Element(nodes[idx_rf], nodes[slab_node_indices[i+1]], rigid_sec_right)

        push!(elements, e_rigid_L); push!(span_elements, e_rigid_L)
        push!(elements, e_clear);   push!(span_elements, e_clear)
        push!(elements, e_rigid_R); push!(span_elements, e_rigid_R)
    end

    # ── Build column stub elements (same pattern as FEA) ──
    col_stubs = Dict{Int, NamedTuple}()

    for j in 1:n_joints
        col = columns[j]
        slab_node = nodes[slab_node_indices[j]]
        x_j = slab_node.position[1]

        # Per-joint I factor: base factor × Kec reduction (ACI 318-11 §13.7.4)
        I_j = col_I_factor * (!isnothing(kec_factors) ? kec_factors[j] : 1.0)

        # Below column (always present)
        Lc_below = col.base.L
        base_below = Node([x_j, 0.0u"m", -uconvert(u"m", Lc_below)], :fixed)
        push!(nodes, base_below)

        sec_below = column_asap_section(
            col.c1, col.c2, col_shape(col), Ecc, ν_concrete; I_factor=I_j)
        elem_below = Element(base_below, slab_node, sec_below)
        push!(elements, elem_below)

        # Above column (if column above exists)
        col_above = hasproperty(col, :column_above) ? col.column_above : nothing
        elem_above = nothing
        if !isnothing(col_above)
            Lc_above = col_above.base.L
            base_above = Node([x_j, 0.0u"m", uconvert(u"m", Lc_above)], :fixed)
            push!(nodes, base_above)

            sec_above = column_asap_section(
                col_above.c1, col_above.c2, col_shape(col_above), Ecc, ν_concrete;
                I_factor=I_j)
            elem_above = Element(slab_node, base_above, sec_above)
            push!(elements, elem_above)
        end

        col_stubs[j] = (
            below = (element=elem_below, base_node=base_below, slab_node=slab_node),
            above = isnothing(elem_above) ? nothing :
                    (element=elem_above, base_node=base_above, slab_node=slab_node),
        )

        if verbose
            above_str = isnothing(col_above) ? "roof (no above)" : "above+below"
            kec_str = !isnothing(kec_factors) ? "  Kec/Kc=$(round(kec_factors[j], digits=3))" : ""
            @debug "Joint $j column stubs" c1=col.c1 c2=col.c2 Lc_below=Lc_below type=above_str I_factor=round(I_j, digits=3) kec_str
        end
    end

    # ── Apply loads to ALL slab elements (rigid + clear) ──
    loads = AbstractLoad[]
    w_N_m = uconvert(u"N/m", qu * l2)
    for elem in span_elements
        push!(loads, LineLoad(elem, [0.0u"N/m", 0.0u"N/m", -w_N_m]))
    end

    model = Model(nodes, elements, loads)

    return model, span_elements, col_stubs
end

"""
    _torsional_constant_rect(width, depth)

Torsional constant C for a rectangular section (ACI 318 formula).

C = (1 - 0.63×x/y) × x³×y / 3

where x = smaller dimension, y = larger dimension.
"""
function _torsional_constant_rect(width::Length, depth::Length)
    x = min(width, depth)
    y = max(width, depth)
    x_val = ustrip(u"inch", x)
    y_val = ustrip(u"inch", y)
    return (1 - 0.63 * x_val/y_val) * x_val^3 * y_val / 3 * u"inch^4"
end

# =============================================================================
# Hardy Cross Moment Distribution Method
# =============================================================================

"""
    solve_moment_distribution(spans, joint_Kec, joint_positions, qu;
                              COF=0.507, max_iterations=20, tolerance=0.01)

Solve EFM using Hardy Cross moment distribution method.

This is the analytical method used by StructurePoint (see Table 5 in their
DE-Two-Way-Flat-Plate example). Matches StructurePoint exactly.

# EFM-Specific Implementation

Unlike standard moment distribution (where unbalanced = sum of member moments),
this implementation tracks carry-over received at each joint. This is correct 
for the EFM model because:

1. **Kec represents a column that provides a REACTION**, not just stiffness
2. When distributing: members get `DF × unbalanced`, column absorbs `(1-ΣDF) × unbalanced`
3. After distribution, joint is in equilibrium (column reaction balances members)
4. Only NEW unbalanced from carry-over needs redistribution in subsequent iterations

Standard moment distribution (redistributing full member sums) causes exterior 
moments to decay toward zero - incorrect for EFM. Validated against both
StructurePoint Table 5 (exact match) and ASAP column-stub model (within 2%).

# Algorithm
1. Compute Distribution Factors: DF = K_sb / (ΣK_sb + K_ec) at each joint
2. Compute Fixed-End Moments: FEM = m × w × l₁²
3. Initialize: member moments = FEMs, unbalanced = FEM sum at each joint
4. Iterate until converged:
   a. Distribute carry-over/FEM received: ΔM = -DF × unbalanced
   b. Carry over: far_end += COF × ΔM (track as next iteration's unbalanced)

# Arguments
- `spans`: Vector of EFMSpanProperties with Ksb (slab-beam stiffness)
- `joint_Kec`: Vector of equivalent column stiffness at each joint
- `joint_positions`: Vector of :interior/:edge/:corner symbols
- `qu`: Factored uniform load (pressure)

# Keyword Arguments  
- `COF`: Carry-over factor (default 0.507 from PCA Table A1)
- `max_iterations`: Maximum iterations (default 20)
- `tolerance`: Convergence tolerance in kip-ft (default 0.01)

# Returns
Vector of named tuples matching `extract_span_moments` format:
- `span_idx`, `M_neg_left`, `M_pos`, `M_neg_right`

# Reference
- StructurePoint DE-Two-Way-Flat-Plate Table 5 (exact match)
- ACI 318-11 §13.7
"""
function solve_moment_distribution(
    spans::Vector{<:EFMSpanProperties},
    joint_Kec::Vector{<:Moment},
    joint_positions::Vector{Symbol},
    qu::Union{Pressure, Vector{<:Pressure}};
    COF::Float64 = spans[1].COF,  # Use span's COF (prismatic or non-prismatic)
    max_iterations::Int = 20,
    tolerance::Float64 = 0.01,
    verbose::Bool = false
)
    n_spans = length(spans)
    n_joints = n_spans + 1
    
    # Per-span factored loads: scalar → uniform, vector → pattern loading
    qu_per_span = qu isa Pressure ? fill(qu, n_spans) : qu
    length(qu_per_span) == n_spans || error("qu_per_span length ($(length(qu_per_span))) ≠ n_spans ($n_spans)")
    
    # =========================================================================
    # Hardy Cross Moment Distribution following StructurePoint Table 5 exactly
    #
    # Member naming convention:
    #   - Member "i-(i+1)" is span i viewed from joint i (left end)
    #   - Member "(i+1)-i" is span i viewed from joint i+1 (right end)
    #
    # For 3 spans (4 joints):
    #   Joint 1: Member 1-2 (left end of span 1)
    #   Joint 2: Members 2-1 (right end of span 1) and 2-3 (left end of span 2)
    #   Joint 3: Members 3-2 (right end of span 2) and 3-4 (left end of span 3)
    #   Joint 4: Member 4-3 (right end of span 3)
    #
    # Key insight from SP Table 5:
    #   - Each iteration: DISTRIBUTE at all joints, THEN apply ALL carry-overs
    #   - At interior joints, if FEMs balance (sum=0), no initial distribution needed
    #   - Sign: positive = counterclockwise acting on member end
    # =========================================================================
    
    # Member indexing: member_idx = 2*span - 1 for left end, 2*span for right end
    # Matches SP column order: 1-2, 2-1, 2-3, 3-2, 3-4, 4-3
    n_members = 2 * n_spans
    
    # Compute Fixed-End Moments
    # For flat plate: FEM = m × w × l₁²  (single uniform load)
    # For flat slab:  FEM = m₁ × w_slab × l₂ × l₁² + m₂ × w_drop × b_drop × l₁² + m₃ × w_drop × b_drop × l₁²
    m_factor = spans[1].m_factor
    has_drops = has_drop_panels(spans[1])
    
    FEM = Vector{Float64}(undef, n_members)
    w_kipft = Vector{Float64}(undef, n_spans)
    l1_ft_arr = Vector{Float64}(undef, n_spans)
    
    @inbounds for span in 1:n_spans
        sp = spans[span]
        l1_f = ustrip(u"ft", sp.l1)
        l1_ft_arr[span] = l1_f
        w_kf = ustrip(kip/u"ft", qu_per_span[span] * sp.l2)
        w_kipft[span] = w_kf
        fem = m_factor * w_kf * l1_f^2
        
        left_idx = 2*span - 1
        right_idx = 2*span
        FEM[left_idx] = fem
        FEM[right_idx] = -fem
    end
    
    # Compute Distribution Factors at each joint
    # DF[member_idx] = K_member / K_total_at_joint
    DF = Vector{Float64}(undef, n_members)
    fill!(DF, 0.0)
    
    # Track which members are at which joint, and reverse mapping for O(1) lookup
    joint_members = [Int[] for _ in 1:n_joints]
    member_to_joint = Vector{Int}(undef, n_members)
    fill!(member_to_joint, 0)
    
    # Pre-allocate fixed buffers (max 2 slab members per joint)
    _mi_buf = Vector{Int}(undef, 2)
    _Km_buf = Vector{Float64}(undef, 2)

    # Pre-strip Kec and Ksb once (avoids ustrip per joint)
    Kec_stripped = Vector{Float64}(undef, n_joints)
    @inbounds for j in 1:n_joints
        Kec_stripped[j] = ustrip(u"lbf*inch", joint_Kec[j])
    end
    Ksb_stripped = Vector{Float64}(undef, n_spans)
    @inbounds for s in 1:n_spans
        Ksb_stripped[s] = ustrip(u"lbf*inch", spans[s].Ksb)
    end

    for joint in 1:n_joints
        Kec_j = @inbounds Kec_stripped[joint]
        n_at = 0
        
        # Right end of span (joint-1)
        if joint > 1
            span = joint - 1
            n_at += 1
            @inbounds _mi_buf[n_at] = 2*span
            @inbounds _Km_buf[n_at] = Ksb_stripped[span]
        end
        
        # Left end of span (joint)
        if joint <= n_spans
            span = joint
            n_at += 1
            @inbounds _mi_buf[n_at] = 2*span - 1
            @inbounds _Km_buf[n_at] = Ksb_stripped[span]
        end
        
        # Total stiffness at joint includes equivalent column stiffness
        K_total = Kec_j
        @inbounds for k in 1:n_at
            K_total += _Km_buf[k]
        end
        
        # Distribution factors and mappings
        @inbounds for k in 1:n_at
            idx = _mi_buf[k]
            DF[idx] = _Km_buf[k] / K_total
            push!(joint_members[joint], idx)
            member_to_joint[idx] = joint
        end
    end
    
    if verbose
        println("\n=== Hardy Cross Setup ===")
        println("DFs: ", round.(DF, digits=3))
        println("FEMs: ", round.(FEM, digits=2))
    end
    
    # Initialize member-end moments
    M = copy(FEM)
    
    # Track carry-over received at each joint (for determining which joints to release)
    # In iteration 1, the "carry-over" is the FEM itself
    co_at_joint = Vector{Float64}(undef, n_joints)
    fill!(co_at_joint, 0.0)
    for j in 1:n_joints
        for idx in joint_members[j]
            co_at_joint[j] += FEM[idx]
        end
    end
    
    # Preallocate scratch vectors (reused every iteration)
    dist_increments = Vector{Float64}(undef, n_members)
    co_increments   = Vector{Float64}(undef, n_members)
    fill!(dist_increments, 0.0)
    fill!(co_increments, 0.0)
    
    # Hardy Cross iteration: alternating Distribute and Carry-Over rows
    for iter in 1:max_iterations
        max_change = 0.0
        
        # =====================================================================
        # DISTRIBUTE ROW
        # =====================================================================
        fill!(dist_increments, 0.0)
        
        for joint in 1:n_joints
            # Only distribute if this joint received carry-over
            if abs(co_at_joint[joint]) < 1e-10
                continue
            end
            
            members = joint_members[joint]
            
            # The unbalanced moment to distribute is the carry-over received
            M_unbalanced = co_at_joint[joint]
            
            # Distribute to each member
            for idx in members
                ΔM = -DF[idx] * M_unbalanced
                dist_increments[idx] = ΔM
                max_change = max(max_change, abs(ΔM))
            end
        end
        
        # Apply all distributions
        M .+= dist_increments
        
        if verbose && iter <= 10
            print("Dist: ")
            println(round.(dist_increments, digits=2))
        end
        
        # =====================================================================
        # CARRY-OVER ROW: Apply carry-overs from the distributions
        # =====================================================================
        # Reset carry-over tracking for next iteration
        fill!(co_at_joint, 0.0)
        fill!(co_increments, 0.0)
        
        for idx in 1:n_members
            if dist_increments[idx] != 0.0
                # Find far end for carry-over
                # Odd idx (left end) → far is idx+1; Even idx (right end) → far is idx-1
                far_idx = isodd(idx) ? idx + 1 : idx - 1
                co_val = COF * dist_increments[idx]
                co_increments[far_idx] = co_val
                
                # Track which joint received this CO (O(1) lookup)
                co_at_joint[member_to_joint[far_idx]] += co_val
            end
        end
        
        # Apply all carry-overs
        M .+= co_increments
        
        if verbose && iter <= 10
            print("CO:   ")
            println(round.(co_increments, digits=2))
            println("M =   ", round.(M, digits=2))
        end
        
        # Check convergence
        if max_change < tolerance
            if verbose
                println("Converged at iteration $iter")
            end
            break
        end
    end
    
    if verbose
        println("\nFinal M: ", round.(M, digits=2))
    end
    
    # Extract span moments
    span_moments = NamedTuple{(:span_idx, :M_neg_left, :M_pos, :M_neg_right), Tuple{Int, Moment, Moment, Moment}}[]
    
    for span in 1:n_spans
        left_idx = 2*span - 1
        right_idx = 2*span
        
        M_left = abs(M[left_idx])
        M_right = abs(M[right_idx])
        
        # Midspan moment from statics: M_mid = M0 - (M_left + M_right)/2
        M0 = w_kipft[span] * l1_ft_arr[span]^2 / 8
        M_mid = M0 - (M_left + M_right) / 2
        
        push!(span_moments, (
            span_idx = span,
            M_neg_left = M_left * kip*u"ft",
            M_pos = M_mid * kip*u"ft",
            M_neg_right = M_right * kip*u"ft"
        ))
    end
    
    return span_moments
end

"""
    solve_efm_frame!(model)

Solve the EFM ASAP frame model.

Uses `process!` to set up the model (compute stiffness matrices, apply constraints)
followed by `solve!` to perform the linear static analysis.
"""
function solve_efm_frame!(model; full_process::Bool=true, loads_only::Bool=false, postprocess::Symbol=:elements)
    if full_process
        process!(model)
    elseif loads_only
        # Only load magnitudes changed — preserve factorization
        Asap.update!(model; loads_only=true)
    else
        Asap.update!(model)
    end
    solve!(model; postprocess=postprocess)
end

"""
    extract_span_moments(model, span_elements, spans; qu=nothing)

Extract moments at key locations from solved ASAP model.

With the 3-sub-element-per-span layout (rigid_L, clear, rigid_R), end moments
are taken from the **outer ends** of the rigid zone elements (at column
centerlines).  The midspan moment is computed from statics:
    M_pos = M0 - (M_neg_left + M_neg_right) / 2

# Arguments
- `model`: Solved ASAP model
- `span_elements`: Vector of slab-beam elements (3 per span in order:
  [rigid_L₁, clear₁, rigid_R₁, rigid_L₂, clear₂, rigid_R₂, ...])
- `spans`: Vector of EFMSpanProperties
- `qu`: Optional factored pressure (for midspan moment calculation from statics)

# Returns
Vector of named tuples with:
- `M_neg_left`: Negative moment at left column centerline
- `M_pos`: Positive moment at midspan
- `M_neg_right`: Negative moment at right column centerline

# Notes
- elem.forces[6]  = Mz at node 1 (start node, in N·m for SI model)
- elem.forces[12] = Mz at node 2 (end node, in N·m for SI model)
"""
function extract_span_moments(model, span_elements, spans; qu::Union{Nothing, Pressure}=nothing)
    n_spans = length(spans)
    n_elems_per_span = length(span_elements) ÷ n_spans  # 3 for sub-element model, 1 for legacy

    span_moments = NamedTuple{(:span_idx, :M_neg_left, :M_pos, :M_neg_right), Tuple{Int, Moment, Moment, Moment}}[]

    for i in 1:n_spans
        sp = spans[i]

        if n_elems_per_span == 3
            # 3-sub-element layout: rigid_L, clear, rigid_R
            idx_base = 3 * (i - 1)
            e_rigid_L = span_elements[idx_base + 1]
            e_rigid_R = span_elements[idx_base + 3]

            # Left support moment: node 1 of rigid_L (column centerline)
            M_neg_left_kipft  = to_kipft(abs(e_rigid_L.forces[6]) * u"N*m")
            # Right support moment: node 2 of rigid_R (column centerline)
            M_neg_right_kipft = to_kipft(abs(e_rigid_R.forces[12]) * u"N*m")
        else
            # Legacy single-element layout (backward compatibility)
            elem = span_elements[i]
            M_neg_left_kipft  = to_kipft(abs(elem.forces[6]) * u"N*m")
            M_neg_right_kipft = to_kipft(abs(elem.forces[12]) * u"N*m")
        end

        # Midspan moment from statics: M_pos = M0 - (M_left + M_right)/2
        if !isnothing(qu)
            w_kipft = ustrip(kip/u"ft", qu * sp.l2)
        else
            w_kipft = 0.0
        end
        l_ft = ustrip(u"ft", sp.l1)
        M0 = w_kipft * l_ft^2 / 8
        M_pos_kipft = M0 - (M_neg_left_kipft + M_neg_right_kipft) / 2

        push!(span_moments, (
            span_idx = i,
            M_neg_left  = M_neg_left_kipft * kip*u"ft",
            M_pos       = M_pos_kipft * kip*u"ft",
            M_neg_right = M_neg_right_kipft * kip*u"ft"
        ))
    end

    return span_moments
end

"""
    distribute_moments_to_strips(span_moments, joint_positions)

Distribute frame-level moments to column and middle strips per ACI 8.10.5.

This is the transverse distribution step - identical for DDM and EFM.

# ACI 8.10.5 Distribution Factors (flat plate, αf = 0)
- Interior negative: 75% to column strip, 25% to middle strip
- Exterior negative: 100% to column strip (no edge beam)
- Positive: 60% to column strip, 40% to middle strip
"""
function distribute_moments_to_strips(span_moments, joint_positions)
    strip_moments = []
    
    for sm in span_moments
        # Left support distribution
        if joint_positions[sm.span_idx] in [:corner, :edge]
            # Exterior: 100% to column strip (ACI Table 8.10.5.2, no edge beam)
            M_neg_left_cs = sm.M_neg_left
            M_neg_left_ms = 0.0kip*u"ft"
        else
            # Interior: 75% / 25% (ACI Table 8.10.5.1)
            M_neg_left_cs = ACI_COL_STRIP_INT_NEG * sm.M_neg_left
            M_neg_left_ms = (1 - ACI_COL_STRIP_INT_NEG) * sm.M_neg_left
        end
        
        # Right support distribution — check if right column is exterior
        right_joint_idx = sm.span_idx + 1
        if right_joint_idx <= length(joint_positions) &&
           joint_positions[right_joint_idx] in [:corner, :edge]
            # Exterior: 100% to column strip
            M_neg_right_cs = sm.M_neg_right
            M_neg_right_ms = 0.0kip*u"ft"
        else
            # Interior: 75% / 25%
            M_neg_right_cs = ACI_COL_STRIP_INT_NEG * sm.M_neg_right
            M_neg_right_ms = (1 - ACI_COL_STRIP_INT_NEG) * sm.M_neg_right
        end
        
        # Positive distribution: 60% / 40%
        col_strip_pos = 0.60
        M_pos_cs = col_strip_pos * sm.M_pos
        M_pos_ms = (1 - col_strip_pos) * sm.M_pos
        
        push!(strip_moments, (
            span_idx = sm.span_idx,
            M_neg_left_cs = M_neg_left_cs,
            M_neg_left_ms = M_neg_left_ms,
            M_pos_cs = M_pos_cs,
            M_pos_ms = M_pos_ms,
            M_neg_right_cs = M_neg_right_cs,
            M_neg_right_ms = M_neg_right_ms
        ))
    end
    
    return strip_moments
end

# =============================================================================
# Helper Functions
# =============================================================================

"""
    _build_efm_spans(columns, l1, l2, ln, h, Ecs; drop_panel=nothing)

Build EFM span properties from column/slab data.

Slab-beam stiffness factors (k, COF, m) are interpolated from PCA Table A1
based on actual c₁/l₁ and c₂/l₂ ratios — replacing the old hardcoded
PCA_K_SLAB, PCA_COF, PCA_M_FACTOR constants.

For **flat slabs** (drop_panel ≠ nothing), the same prismatic PCA factors are
used.  Non-prismatic section behaviour is handled by the ASAP elastic solver
which models the actual varying I along the span.

Is_drop (composite I at the drop section) is still computed so the ASAP solver
can assign a stiffer section to the drop-panel zone.
"""
function _build_efm_spans(columns, l1, l2, ln, h, Ecs;
                           drop_panel::Union{Nothing, DropPanelGeometry} = nothing)
    n_cols = length(columns)
    n_spans = n_cols - 1
    
    spans = Vector{EFMSpanProperties}(undef, n_spans)
    
    for i in 1:n_spans
        col_left = columns[i]
        col_right = columns[i + 1]

        # Geometry-dependent PCA Table A1 lookup
        slab_factors = pca_slab_beam_factors(col_left.c1, l1, col_left.c2, l2)
        k_slab   = slab_factors.k
        m_factor = slab_factors.m
        COF      = slab_factors.COF
        
        Is = slab_moment_of_inertia(l2, h)
        Ksb = slab_beam_stiffness_Ksb(Ecs, Is, l1, col_left.c1, col_left.c2; k_factor=k_slab)
        
        # Compute Is_drop for ASAP section assignment in the drop zone
        Is_drop = if !isnothing(drop_panel)
            h_total = total_depth_at_drop(h, drop_panel)
            slab_moment_of_inertia(l2, h_total)
        else
            nothing
        end
        
        spans[i] = EFMSpanProperties{typeof(Is), typeof(Ksb)}(
            i, i, i + 1,
            l1, l2, ln,
            h,
            col_left.c1, col_left.c2,
            col_right.c1, col_right.c2,
            Is, Ksb,
            m_factor, COF, k_slab,
            drop_panel, Is_drop,
        )
    end
    
    return spans
end

"""Get column concrete strength from first column's material, or fall back to slab fc."""
function _get_column_fc(columns, default_fc)
    if !isempty(columns) && hasproperty(columns[1], :material) && hasproperty(columns[1].material, :fc′)
        return columns[1].material.fc′
    end
    return default_fc
end

"""Get column height from first column. Errors if not available."""
function _get_column_height(columns)
    if !isempty(columns) && hasproperty(columns[1], :base) && hasproperty(columns[1].base, :L)
        return columns[1].base.L
    end
    error("Cannot determine column height: columns[1].base.L not available. " *
          "Ensure column geometry is set before EFM analysis.")
end

"""
    _compute_efm_column_demands(struc, columns, span_moments, qu, l2, ln)

Compute column-level demands from EFM span moments.

Uses tributary area for shear where available.
"""
function _compute_efm_column_demands(struc, columns, span_moments, qu, l2, ln)
    n_cols = length(columns)
    MomentT = typeof(1.0kip*u"ft")
    ForceT  = typeof(1.0kip)
    column_moments     = Vector{MomentT}(undef, n_cols)
    column_shears      = Vector{ForceT}(undef, n_cols)
    unbalanced_moments = Vector{MomentT}(undef, n_cols)
    
    for (i, col) in enumerate(columns)
        if i == 1
            M = span_moments[1].M_neg_left
            Mub = M
        elseif i == n_cols
            M = span_moments[end].M_neg_right
            Mub = M
        else
            M_left = span_moments[i-1].M_neg_right
            M_right = span_moments[i].M_neg_left
            M = max(M_left, M_right)
            Mub = abs(M_left - M_right)
        end
        
        column_moments[i] = M
        unbalanced_moments[i] = Mub
        column_shears[i] = _compute_column_shear(struc, col, qu, l2, ln)
    end
    
    return column_moments, column_shears, unbalanced_moments
end

# _compute_column_shear is defined in common.jl (shared between DDM and EFM)

# =============================================================================
# EFM Applicability Check - ACI 318-11 §13.7
# =============================================================================

"""
    EFMApplicabilityError <: Exception

Error thrown when EFM is not applicable for the given geometry/loading.
"""
struct EFMApplicabilityError <: Exception
    violations::Vector{String}
end

"""Print a human-readable error listing violated ACI 318-11 §13.7 conditions and suggest FEA as fallback."""
function Base.showerror(io::IO, e::EFMApplicabilityError)
    println(io, "EFM (Equivalent Frame Method) is not permitted for this slab per ACI 318-11 §13.7:")
    for (i, v) in enumerate(e.violations)
        println(io, "  $i. $v")
    end
    # FEA is always valid - suggest it as the fallback
    println(io, "\nConsider using FEA (Finite Element Analysis) instead: method=FEA()")
    println(io, "FEA has no geometric restrictions and can handle any layout.")
end

"""
    check_efm_applicability(struc, slab, columns; throw_on_failure=true)

Check if EFM is applicable per ACI 318-11 §13.7.

# ACI 318-11 §13.7 Requirements:

Unlike DDM, EFM has **fewer geometric restrictions**. It is a general method that can
handle irregular layouts. However, it still requires:

1. **§8.11.1.1** - Analysis is for gravity loads only (lateral by separate analysis)
2. **§8.11.2** - Slab-beam must extend from column centerline to column centerline
3. **§8.11.5** - Equivalent column stiffness must properly account for torsion
4. **§8.11.6.1** - Design moments taken at face of support
5. **§8.11.6.1** - Negative moment not taken at distance > 0.175×l₁ from column center

# Key Advantage
EFM has **no restrictions** on:
- Number of spans (DDM requires ≥3)
- Panel aspect ratio (DDM requires l₂/l₁ ≤ 2.0)
- Successive span ratios (DDM requires ≤1/3 difference)
- Column offsets (DDM requires ≤10% of span)
- L/D ratio (DDM requires ≤2.0)

# Arguments
- `struc`: BuildingStructure
- `slab`: Slab being designed
- `columns`: Vector of supporting columns
- `throw_on_failure`: If true, throw EFMApplicabilityError; if false, return result

# Returns
Named tuple with:
- `ok::Bool`: true if EFM is applicable
- `violations::Vector{String}`: list of violated conditions with code references

# Throws
`EFMApplicabilityError` if any condition is violated and `throw_on_failure=true`
"""
function check_efm_applicability(struc, slab, columns; throw_on_failure::Bool = true)
    violations = String[]
    
    l1 = slab.spans.primary
    l2 = slab.spans.secondary
    l1_val = ustrip(l1)
    l2_val = ustrip(l2)
    
    # -------------------------------------------------------------------------
    # Minimum clear span check (practical limit for two-way behavior)
    # -------------------------------------------------------------------------
    # Two-way slab analysis assumes slenderness; spans < 4 ft behave more like
    # thick plates where shear governs over flexure
    if !isempty(columns)
        c1_avg = sum(col.c1 for col in columns) / length(columns)
        ln = clear_span(l1, c1_avg)
        
        ln_min = 4.0u"ft"
        if ln < ln_min
            push!(violations, "Clear span ln = $(round(ustrip(u"ft", ln), digits=2)) ft < $(ustrip(u"ft", ln_min)) ft minimum for two-way slab behavior")
        end
    end
    
    # -------------------------------------------------------------------------
    # §8.11.2 - Panel geometry: must be rectangular
    # -------------------------------------------------------------------------
    # EFM models the slab as a 2D frame; non-rectangular bays require FEA
    if l1_val <= 0 || l2_val <= 0
        push!(violations, "§8.11.2: Panel must be rectangular; invalid span dimensions l₁=$(l1), l₂=$(l2)")
    end
    
    # Check if slab has non-rectangular geometry flag (if available)
    if hasproperty(slab, :is_rectangular) && !slab.is_rectangular
        push!(violations, "§8.11.2: Panel must be rectangular; EFM frame model requires orthogonal bays (use FEA for irregular geometry)")
    end
    
    # -------------------------------------------------------------------------
    # §8.11.1.1 - Gravity loads only
    # -------------------------------------------------------------------------
    # We assume this is satisfied since EFM frame doesn't include lateral loads
    # Lateral loads should be handled by a separate lateral system analysis
    
    # -------------------------------------------------------------------------
    # Minimum geometry requirements
    # -------------------------------------------------------------------------
    # EFM requires at least 2 columns to form a span
    n_cols = length(columns)
    if n_cols < 2
        push!(violations, "§8.11.2: EFM requires at least 2 columns to form a frame; only $(n_cols) column(s) found")
    end
    
    # -------------------------------------------------------------------------
    # Column sizing requirements for torsional stiffness
    # -------------------------------------------------------------------------
    # Check that columns have reasonable dimensions for Kt calculation
    # c2/l2 should not be too large (approaches infinity in Kt formula)
    if l2_val > 0
        for (i, col) in enumerate(columns)
            c2 = col.c2
            c2_l2_ratio = ustrip(c2) / l2_val
            if c2_l2_ratio > 0.5
                push!(violations, "§8.11.5: Column $i dimension c₂ = $(c2) exceeds 50% of panel width l₂ = $(l2); torsional stiffness formula invalid")
            end
        end
    end
    
    ok = isempty(violations)
    
    if !ok && throw_on_failure
        throw(EFMApplicabilityError(violations))
    end
    
    return (ok=ok, violations=violations)
end

"""
    enforce_efm_applicability(struc, slab, columns)

Enforce EFM applicability, throwing an error if not permitted.
This is called automatically by `run_moment_analysis(::EFM, ...)`.
"""
function enforce_efm_applicability(struc, slab, columns)
    check_efm_applicability(struc, slab, columns; throw_on_failure=true)
end

# =============================================================================
# FrameLine-Based EFM Analysis
# =============================================================================

"""
    run_moment_analysis(method::EFM, frame_line::FrameLine, struc, h, fc, Ecs, Ecc, qu, qD, qL; verbose=false)

Run EFM moment analysis using a FrameLine (multi-span frame strip).

This overload accepts a pre-built FrameLine which already has:
- Columns sorted along the frame direction
- Clear span lengths computed
- Joint positions (exterior/interior) determined

# Arguments
- `method::EFM`: EFM method with solver selection (:asap or :hardy_cross)
- `frame_line::FrameLine`: Pre-built frame strip with columns and spans
- `struc`: BuildingStructure (for tributary area lookup)
- `h::Length`: Slab thickness
- `fc::Pressure`: Concrete compressive strength
- `Ecs::Pressure`: Slab concrete modulus
- `Ecc::Pressure`: Column concrete modulus
- `qu::Pressure`: Factored uniform load
- `qD::Pressure`: Service dead load
- `qL::Pressure`: Service live load

# Returns
`MomentAnalysisResult` with all moments and geometry data.

# Example
```julia
fl = FrameLine(:x, columns, l2, get_pos, get_width)
result = run_moment_analysis(EFM(solver=:asap), fl, struc, h, fc, Ecs, Ecc, qu, qD, qL)
```
"""
function run_moment_analysis(
    method::EFM,
    frame_line,  # FrameLine{T, C}
    struc,
    h::Length,
    fc::Pressure,
    Ecs::Pressure,
    Ecc::Pressure,
    qu::Pressure,
    qD::Pressure,
    qL::Pressure;
    ν_concrete::Float64 = 0.20,
    ρ_concrete = 2380.0u"kg/m^3",
    verbose::Bool = false,
    efm_cache::Union{Nothing, EFMModelCache} = nothing,
    cache = nothing,  # API parity (unused by EFM)
)
    # Extract from FrameLine
    sorted_columns = frame_line.columns
    l2 = frame_line.tributary_width
    n_spans = length(frame_line.span_lengths)
    n_cols = n_spans + 1
    
    # Build joint positions from FrameLine
    joint_positions = frame_line.joint_positions
    
    # Get column height (assume uniform)
    H = _get_column_height(sorted_columns)
    
    # Build EFM span properties from FrameLine
    spans = EFMSpanProperties[]
    for span_idx in 1:n_spans
        col_left = sorted_columns[span_idx]
        col_right = sorted_columns[span_idx + 1]
        ln = frame_line.span_lengths[span_idx]
        
        # Center-to-center span (approximate from clear span + column widths)
        l1 = ln + (col_left.c1 + col_right.c1) / 2
        
        # Column dimensions
        c1_left = col_left.c1
        c2_left = col_left.c2
        c1_right = col_right.c1
        c2_right = col_right.c2
        
        # Compute span properties with geometry-dependent PCA Table A1 lookup
        Is = slab_moment_of_inertia(l2, h)
        c1_avg = (c1_left + c1_right) / 2
        c2_avg = (c2_left + c2_right) / 2

        slab_factors = pca_slab_beam_factors(c1_avg, l1, c2_avg, l2)
        k_slab   = slab_factors.k
        m_factor = slab_factors.m
        COF      = slab_factors.COF
        Ksb = slab_beam_stiffness_Ksb(Ecs, Is, l1, c1_avg, c2_avg; k_factor=k_slab)
        
        push!(spans, EFMSpanProperties(
            span_idx, span_idx, span_idx + 1,
            l1, l2, ln, h,
            c1_left, c2_left, c1_right, c2_right,
            Is, Ksb, m_factor, COF, k_slab
        ))
    end
    
    # Total static moment for reference
    ln_avg = sum(sp.ln for sp in spans) / n_spans
    M0 = total_static_moment(qu, l2, ln_avg)
    
    if verbose
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "MOMENT ANALYSIS - EFM (FrameLine)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Frame direction" dir=frame_line.direction n_spans=n_spans l2=l2
        @debug "Solver" solver=method.solver
        @debug "Loads" qD=qD qL=qL qu=qu
    end
    
    # Detect column shape from first column
    col_shape_val = col_shape(sorted_columns[1])
    
    # Derive col_I_factor from method fields
    col_I_factor = (method.solver == :asap && method.cracked_columns) ? 0.70 : 1.0
    use_kc_only = method.column_stiffness == :Kc
    
    # Kec reduction factors for ASAP column stubs
    _kec_factors = method.solver == :asap ?
        _compute_kec_reduction_factors(spans, joint_positions, H, Ecs, Ecc;
                                       column_shape=col_shape_val, use_kc_only=use_kc_only,
                                       columns=sorted_columns) :
        nothing
    
    # Solve using selected method
    if method.solver == :asap
        if !isnothing(efm_cache) && efm_cache.initialized
            _update_efm_sections_and_loads!(
                efm_cache, spans, qu, Ecs, Ecc,
                ν_concrete, ρ_concrete, sorted_columns;
                col_I_factor = col_I_factor,
                kec_factors = _kec_factors,
            )
            solve_efm_frame!(efm_cache.model; full_process=false)
            span_moments = extract_span_moments(
                efm_cache.model, efm_cache.span_elements, spans; qu=qu
            )
        else
            model, span_elements, col_stubs = build_efm_asap_model(
                spans, joint_positions, qu;
                Ecs = Ecs, Ecc = Ecc,
                ν_concrete = ν_concrete,
                ρ_concrete = ρ_concrete,
                columns = sorted_columns,
                verbose = verbose,
                col_I_factor = col_I_factor,
                kec_factors = _kec_factors,
            )
            solve_efm_frame!(model)
            span_moments = extract_span_moments(model, span_elements, spans; qu=qu)

            !isnothing(efm_cache) && _populate_efm_cache!(efm_cache, model, span_elements, col_stubs, spans)
        end
        
    elseif method.solver == :hardy_cross
        joint_Kec = _compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc;
                                       column_shape=col_shape_val, use_kc_only=use_kc_only,
                                       columns=sorted_columns)
        span_moments = solve_moment_distribution(spans, joint_Kec, joint_positions, qu; verbose=verbose)
    else
        error("Unknown EFM solver: $(method.solver)")
    end
    
    if verbose
        @debug "───────────────────────────────────────────────────────────────────"
        @debug "EFM RESULTS"
        @debug "───────────────────────────────────────────────────────────────────"
        for (i, sm) in enumerate(span_moments)
            @debug "Span $i" M_neg_left=uconvert(kip*u"ft", sm.M_neg_left) M_pos=uconvert(kip*u"ft", sm.M_pos) M_neg_right=uconvert(kip*u"ft", sm.M_neg_right)
        end
    end
    
    M_neg_ext = span_moments[1].M_neg_left
    M_neg_int = span_moments[1].M_neg_right
    M_pos = span_moments[1].M_pos
    
    # ─── Pattern loading envelope (ACI 318-11 §13.7.6) ───
    use_pattern = method.pattern_loading && requires_pattern_loading(qD, qL) && n_spans >= 2
    if use_pattern
        # Reuse joint_Kec from baseline solve — invariant across patterns
        for pat in generate_load_patterns(n_spans)
            all(==(:dead_plus_live), pat) && continue
            qu_ps = factored_pattern_loads(pat, qD, qL)
            sm_p = solve_moment_distribution(spans, joint_Kec, joint_positions, qu_ps)
            abs(sm_p[1].M_neg_left)  > abs(M_neg_ext) && (M_neg_ext = sm_p[1].M_neg_left)
            abs(sm_p[1].M_neg_right) > abs(M_neg_int) && (M_neg_int = sm_p[1].M_neg_right)
            abs(sm_p[1].M_pos)       > abs(M_pos)     && (M_pos     = sm_p[1].M_pos)
        end
        verbose && @debug "PATTERN LOADING ENVELOPE (FrameLine)" M_neg_ext=uconvert(kip*u"ft", M_neg_ext) M_neg_int=uconvert(kip*u"ft", M_neg_int) M_pos=uconvert(kip*u"ft", M_pos)
    end
    
    # Build column-level results
    column_moments, column_shears, unbalanced_moments = _compute_efm_column_demands(
        struc, sorted_columns, span_moments, qu, l2, ln_avg
    )
    
    l1_avg = sum(sp.l1 for sp in spans) / n_spans
    c1_avg = sum(c.c1 for c in sorted_columns) / n_cols
    
    # Convert all outputs to consistent US units for MomentAnalysisResult
    M0_conv = uconvert(kip * u"ft", M0)
    M_neg_ext_conv = uconvert(kip * u"ft", M_neg_ext)
    M_neg_int_conv = uconvert(kip * u"ft", M_neg_int)
    M_pos_conv = uconvert(kip * u"ft", M_pos)
    
    qu_psf = uconvert(psf, qu)
    qD_psf = uconvert(psf, qD)
    qL_psf = uconvert(psf, qL)
    Vu_max = uconvert(kip, qu_psf * l2 * ln_avg / 2)
    
    return MomentAnalysisResult(
        M0_conv,
        M_neg_ext_conv,
        M_neg_int_conv,
        M_pos_conv,
        qu_psf, qD_psf, qL_psf,
        uconvert(u"ft", l1_avg),
        uconvert(u"ft", l2),
        uconvert(u"ft", ln_avg),
        uconvert(u"ft", c1_avg),
        column_moments,
        column_shears,
        unbalanced_moments,
        Vu_max;
        pattern_loading = use_pattern,
    )
end
