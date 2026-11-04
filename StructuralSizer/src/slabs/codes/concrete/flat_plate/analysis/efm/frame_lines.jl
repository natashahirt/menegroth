# =============================================================================
# Helper Functions
# =============================================================================

"""
    _efm_span(span_idx, l1, l2, ln, h, Ecs, c_par_l, c_tr_l, c_par_r, c_tr_r; drop_panel=nothing)

One slab-beam span. `c_par` is the column face parallel to the span and
`c_tr` is the face transverse to it, which is what PCA Table A1 calls c1 and c2.

For a flat slab the prismatic PCA factors are unchanged. The ASAP solver
sees the drop through `Is_drop`.
"""
function _efm_span(span_idx, l1, l2, ln, h, Ecs, c_par_l, c_tr_l, c_par_r, c_tr_r;
                   drop_panel::Union{Nothing, DropPanelGeometry} = nothing)
    slab_factors = pca_slab_beam_factors(c_par_l, l1, c_tr_l, l2)
    Is = slab_moment_of_inertia(l2, h)
    Ksb = slab_beam_stiffness_Ksb(Ecs, Is, l1, c_par_l, c_tr_l; k_factor=slab_factors.k)
    Is_drop = isnothing(drop_panel) ? nothing :
        slab_moment_of_inertia(l2, total_depth_at_drop(h, drop_panel))
    return EFMSpanProperties{typeof(Is), typeof(Ksb)}(
        span_idx, span_idx, span_idx + 1,
        l1, l2, ln, h,
        c_par_l, c_tr_l, c_par_r, c_tr_r,
        Is, Ksb,
        slab_factors.m, slab_factors.COF, slab_factors.k,
        drop_panel, Is_drop,
    )
end

"""
Spans of one column line. `proj_m` is the station of each column in meters
along `axis`, already sorted. The clear span is center-to-center minus the
two face projections.
"""
function _spans_from_projections(columns, proj_m::Vector{Float64}, axis, l2::Length, h, Ecs;
                                drop_panel::Union{Nothing, DropPanelGeometry} = nothing)
    n = length(columns)
    n >= 2 || error("EFM frame line needs at least two columns")
    length(proj_m) == n || error("EFM frame line projections do not match its columns")
    perp = (-axis[2], axis[1])
    spans = Vector{EFMSpanProperties}(undef, n - 1)
    for i in 1:(n - 1)
        l1 = (proj_m[i + 1] - proj_m[i]) * u"m"
        half_l = _eq137_face_half(columns[i], axis)
        half_r = _eq137_face_half(columns[i + 1], axis)
        ln = l1 - half_l - half_r
        ln > 0u"m" || error(
            "EFM clear span is non-positive between columns $i and $(i + 1) " *
            "(center-to-center $l1, faces $(2 * half_l) and $(2 * half_r)). " *
            "Column projections are meters along the frame.")
        spans[i] = _efm_span(
            i, l1, l2, ln, h, Ecs,
            2 * half_l, 2 * _eq137_face_half(columns[i], perp),
            2 * half_r, 2 * _eq137_face_half(columns[i + 1], perp);
            drop_panel,
        )
    end
    return spans
end

"""
Split column indices into column lines.

Stations are the coordinate transverse to the span. A gap larger than half
the median bay starts a new line, so a millimeter vertex mismatch stays on
its line and the next panel does not.
"""
function _cluster_transverse(t::Vector{Float64})
    order = sortperm(t)
    groups = Vector{Int}[]
    isempty(order) && return groups
    gaps = [t[order[i + 1]] - t[order[i]] for i in 1:(length(order) - 1)]
    positive = filter(>(0.05), gaps)
    bay = isempty(positive) ? Inf : 0.5 * sort(positive)[(end + 1) ÷ 2]
    current = Int[order[1]]
    for i in eachindex(gaps)
        if gaps[i] > bay
            push!(groups, current)
            current = Int[order[i + 1]]
        else
            push!(current, order[i + 1])
        end
    end
    push!(groups, current)
    return groups
end

"""
Tributary width of column line `k` of `n`.

ACI 318-11 §13.7.2.2 (corpus: aci-318-11, page 259): an interior frame is
bounded by the panel centerline on each side of the column line.
§13.7.2.4: a frame on an edge is bounded by that edge and the centerline of
the adjacent panel. These slabs end on the column line, so the edge frame's
outer bound is the line itself and its width is half the bay.

A single line is the panel strip the caller already measured.
"""
function _line_tributary_width(k::Int, n::Int, stations::Vector{Float64}, panel_l2::Length)
    n == 1 && return panel_l2
    left = k == 1 ? 0.0 : (stations[k] - stations[k - 1]) / 2
    right = k == n ? 0.0 : (stations[k + 1] - stations[k]) / 2
    width = (left + right) * u"m"
    width > 0u"m" || error("EFM frame line $k has a non-positive tributary width")
    return width
end

"""Column lines along `axis`, each sorted in the span direction."""
function _column_line_groups(columns, xy, axis, panel_l2::Length)
    axes = _eq137_unit_axes(axis)
    axes === nothing && error("EFM span axis has zero length")
    ax, perp = axes
    s = [xy[i][1] * ax[1] + xy[i][2] * ax[2] for i in eachindex(columns)]
    t = [xy[i][1] * perp[1] + xy[i][2] * perp[2] for i in eachindex(columns)]
    groups = _cluster_transverse(t)
    stations = [sum(t[i] for i in g) / length(g) for g in groups]
    lines = map(enumerate(groups)) do (k, g)
        idx = g[sortperm(s[g])]
        cols = [columns[i] for i in idx]
        length(cols) >= 2 || error(
            "EFM column line has a single column. ACI 318-11 §13.7.2.2 " *
            "(corpus: aci-318-11, page 259) requires a row of columns and slab-beam strips.")
        (
            columns = cols,
            projections = [s[i] for i in idx],
            width = _line_tributary_width(k, length(groups), stations, panel_l2),
            axis = ax,
        )
    end
    return lines
end

"""Meters, structural centerline. Without skeleton geometry the list is already one line at spacing `l1`."""
function _efm_xy(struc, columns, l1::Length, axis)
    if _eq137_geometry_available(struc) && all(c -> col_vertex_idx(c) > 0, columns)
        return [_eq137_structural_xy(struc, col) for col in columns]
    end
    axes = _eq137_unit_axes(axis)
    ax = axes === nothing ? (1.0, 0.0) : axes[1]
    step = ustrip(u"m", l1)
    return [((i - 1) * step * ax[1], (i - 1) * step * ax[2]) for i in eachindex(columns)]
end

"""
One entry per column line, in the shape `run_moment_analysis(::EFM, line, ...)` reads.

`column_projections` are meters along the span.
"""
function _equivalent_frames(struc, columns, setup)
    grouped = _column_line_groups(
        columns,
        _efm_xy(struc, columns, setup.l1, setup.span_axis),
        setup.span_axis,
        setup.l2,
    )
    return map(grouped) do g
        (
            columns = g.columns,
            column_projections = g.projections,
            tributary_width = g.width,
            direction = g.axis,
        )
    end
end

"""
Drop the cached Asap model when this line is not the line that built it.
Section and load updates stay valid across a thickness change: span lengths
do not depend on `h`.
"""
function _reuse_line_model!(efm_cache, spans)
    isnothing(efm_cache) && return
    if efm_cache.initialized && !isnothing(efm_cache._last_spans)
        old = efm_cache._last_spans
        same = length(old) == length(spans) && all(eachindex(spans)) do i
            old[i].l1 == spans[i].l1 && old[i].ln == spans[i].ln && old[i].l2 == spans[i].l2
        end
        same || (efm_cache.initialized = false)
    end
    if efm_cache.initialized && efm_cache.n_spans != length(spans)
        efm_cache.initialized = false
    end
    efm_cache._last_spans = spans
    return
end

"""
Solve one frame line. Hardy Cross and ASAP share this path, including the
pattern envelope. Returns the demand named tuple and whether a pattern was applied.
"""
function _solve_efm_line(method::EFM, spans, columns, joint_positions, struc,
                         Ecs, Ecc, qu, qD, qL;
                         ν_concrete::Float64 = 0.20,
                         ρ_concrete = 2380.0u"kg/m^3",
                         verbose::Bool = false,
                         efm_cache::Union{Nothing, EFMModelCache} = nothing,
                         col_I_factor::Float64 = 0.70)
    l2 = spans[1].l2
    n_spans = length(spans)
    ln_avg = sum(sp.ln for sp in spans) / n_spans
    H = _get_column_height(columns)
    col_shape_val = col_shape(columns[1])
    # ASAP cracked stubs take the caller's factor. Hardy Cross uses gross Ig;
    # its column stiffness is Kec. ACI 318-11 §10.10.4.1.
    incoming_col_I = col_I_factor
    col_I_factor = (method.solver == :asap && method.cracked_columns) ? incoming_col_I : 1.0
    use_kc_only = method.column_stiffness == :Kc

    jKec = method.solver == :hardy_cross ?
        _compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc;
                           column_shape=col_shape_val, use_kc_only=use_kc_only,
                           columns=columns) :
        nothing
    kec_factors = method.solver == :asap ?
        _compute_kec_reduction_factors(spans, joint_positions, H, Ecs, Ecc;
                                       column_shape=col_shape_val, use_kc_only=use_kc_only,
                                       columns=columns) :
        nothing

    function _solve_once(qu_arg)
        if method.solver == :asap
            if !isnothing(efm_cache) && efm_cache.initialized
                _update_efm_sections_and_loads!(
                    efm_cache, spans, qu, Ecs, Ecc,
                    ν_concrete, ρ_concrete, columns;
                    col_I_factor = col_I_factor,
                    kec_factors = kec_factors,
                )
                is_pattern = qu_arg isa Vector
                if is_pattern
                    n_loads = length(efm_cache.model.loads)
                    n_per_span = n_loads ÷ n_spans
                    for (i, load) in enumerate(efm_cache.model.loads)
                        span_idx = (i - 1) ÷ n_per_span + 1
                        span_idx > n_spans && break
                        w_N_m = uconvert(u"N/m", qu_arg[span_idx] * l2)
                        load.value = [0.0u"N/m", 0.0u"N/m", -w_N_m]
                    end
                end
                solve_efm_frame!(efm_cache.model; full_process=false, loads_only=is_pattern)
                return extract_span_moments(
                    efm_cache.model, efm_cache.span_elements, spans; qu=qu)
            else
                model, span_elements, col_stubs = build_efm_asap_model(
                    spans, joint_positions, qu;
                    Ecs = Ecs, Ecc = Ecc,
                    ν_concrete = ν_concrete,
                    ρ_concrete = ρ_concrete,
                    columns = columns,
                    verbose = verbose,
                    col_I_factor = col_I_factor,
                    kec_factors = kec_factors,
                )
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
                !isnothing(efm_cache) && _populate_efm_cache!(
                    efm_cache, model, span_elements, col_stubs, spans)
                return sm
            end
        elseif method.solver == :hardy_cross
            return solve_moment_distribution(
                spans, jKec, joint_positions, qu_arg;
                verbose = verbose && !(qu_arg isa Vector),
            )
        else
            error("Unknown EFM solver: $(method.solver)")
        end
    end

    span_moments = _solve_once(qu)
    use_pattern = method.pattern_loading && requires_pattern_loading(qD, qL) && n_spans >= 2
    env = _efm_demands_with_pattern(
        span_moments, struc, columns, qu, qD, qL, l2, ln_avg;
        use_pattern, solve_once=_solve_once,
    )
    return env, use_pattern
end

"""
Solve every column line and write each column's demands back to its index
in `columns`. Strip moments are the largest absolute value among the lines.
`setup.M0`, `l1`, `l2`, and `ln` stay the panel design strip.

One `EFMModelCache` is one Asap model. It is used only when the floor is a
single line. Several lines would overwrite each other's topology.
"""
function _analyze_equivalent_frames(method::EFM, struc, columns, h, fc, Ecs, γ_concrete, setup;
                                   ν_concrete::Float64 = 0.20,
                                   verbose::Bool = false,
                                   efm_cache::Union{Nothing, EFMModelCache} = nothing,
                                   drop_panel = nothing,
                                   col_I_factor::Float64 = 0.70)
    lines = _equivalent_frames(struc, columns, setup)
    isempty(lines) && error("EFM found no frame lines")
    fc_col = _get_column_fc(columns, fc)
    Ecc = Ec(fc_col, ustrip(pcf, γ_concrete))
    n = length(columns)
    MomentT = typeof(1.0kip * u"ft")
    ForceT = typeof(1.0kip)
    column_moments = Vector{MomentT}(undef, n)
    column_shears = Vector{ForceT}(undef, n)
    unbalanced_moments = Vector{MomentT}(undef, n)
    covered = falses(n)
    index_of = Dict{UInt, Int}(objectid(col) => i for (i, col) in enumerate(columns))
    M_neg_ext = M_neg_int = M_pos = nothing
    use_pattern = false
    one_line = length(lines) == 1
    for (k, line) in enumerate(lines)
        res = run_moment_analysis(
            method, line, struc, h, fc, Ecs, Ecc, setup.qu, setup.qD, setup.qL;
            ν_concrete, ρ_concrete = γ_concrete,
            verbose = verbose && k == 1,
            efm_cache = one_line ? efm_cache : nothing,
            drop_panel, col_I_factor,
        )
        use_pattern |= res.pattern_loading
        M_neg_ext = isnothing(M_neg_ext) ? res.M_neg_ext : _raise_abs(M_neg_ext, res.M_neg_ext)
        M_neg_int = isnothing(M_neg_int) ? res.M_neg_int : _raise_abs(M_neg_int, res.M_neg_int)
        M_pos = isnothing(M_pos) ? res.M_pos : _raise_abs(M_pos, res.M_pos)
        for (j, col) in enumerate(line.columns)
            i = index_of[objectid(col)]
            covered[i] && error("A column lies on two EFM frame lines")
            column_moments[i] = uconvert(kip * u"ft", res.column_moments[j])
            column_shears[i] = uconvert(kip, res.column_shears[j])
            unbalanced_moments[i] = uconvert(kip * u"ft", res.unbalanced_moments[j])
            covered[i] = true
        end
    end
    n_missed = n - count(covered)
    n_missed == 0 || error("EFM left $n_missed column(s) off every frame line")
    verbose && @debug "EFM frame lines" n_lines=length(lines) pattern=use_pattern
    return MomentAnalysisResult(
        uconvert(kip * u"ft", setup.M0),
        uconvert(kip * u"ft", M_neg_ext),
        uconvert(kip * u"ft", M_neg_int),
        uconvert(kip * u"ft", M_pos),
        setup.qu, setup.qD, setup.qL,
        uconvert(u"ft", setup.l1),
        uconvert(u"ft", setup.l2),
        uconvert(u"ft", setup.ln),
        uconvert(u"ft", setup.c1_avg),
        column_moments,
        column_shears,
        unbalanced_moments,
        uconvert(kip, setup.qu * setup.l2 * setup.ln / 2);
        pattern_loading = use_pattern,
    )
end

"""
Pattern-on and pattern-off equivalent frames, both directions, with column
demands at the supporting-column index. FEA `:efm_amp` scales each shell
demand by the frame that owns that column.
"""
function _efm_pattern_baselines(struc, slab, columns, h, fc, Ecs, γ_concrete;
                               drop_panel = nothing,
                               col_I_factor::Float64 = 0.70,
                               ν_concrete::Float64 = 0.20)
    on = EFM(solver=:hardy_cross, column_stiffness=:Kec, pattern_loading=true, cracked_columns=false)
    off = EFM(solver=:hardy_cross, column_stiffness=:Kec, pattern_loading=false, cracked_columns=false)
    kw = (; drop_panel, col_I_factor, ν_concrete, verbose=false)
    return (
        primary_on = run_moment_analysis(on, struc, slab, columns, h, fc, Ecs, γ_concrete; kw...),
        primary_off = run_moment_analysis(off, struc, slab, columns, h, fc, Ecs, γ_concrete; kw...),
        secondary_on = run_secondary_moment_analysis(on, struc, slab, columns, h, fc, Ecs, γ_concrete; kw...),
        secondary_off = run_secondary_moment_analysis(off, struc, slab, columns, h, fc, Ecs, γ_concrete; kw...),
    )
end


