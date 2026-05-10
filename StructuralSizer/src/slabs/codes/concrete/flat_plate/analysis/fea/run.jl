# =============================================================================
# FEA Moment Analysis — Main Entry Point
# =============================================================================

"""
    run_moment_analysis(method::FEA, struc, slab, columns, h, fc, Ecs, γ_concrete;
                        ν_concrete, verbose, cache, has_edge_beam, edge_beam_βt)

Run moment analysis using 2D shell FEA with column stub frame elements.

Column stubs use `Ecc` (column concrete modulus), computed from the columns'
own `fc′` when available, falling back to the slab `fc`.

If `cache::FEAModelCache` is provided, the mesh is reused between
iterations (only section + load + stubs are updated).

When `has_edge_beam=true` or `edge_beam_βt > 0`, perimeter edge-beam frame
elements are added along every free boundary edge per ACI 318-11 §13.6.4.2 /
§13.7.5 (cross-section back-solved from the requested βt).  This generalizes
to non-rectangular slabs because the boundary is iterated as a CCW polygon.

Returns `MomentAnalysisResult` with `secondary = nothing`.
"""
function run_moment_analysis(
    method::FEA,
    struc,
    slab,
    supporting_columns,
    h::Length,
    fc::Pressure,
    Ecs::Pressure,
    γ_concrete;
    ν_concrete::Float64 = 0.20,
    verbose::Bool = false,
    cache::Union{Nothing, FEAModelCache} = nothing,
    efm_cache = nothing,  # API parity (unused by FEA)
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    βt::Float64 = 0.0,  # alias of edge_beam_βt for API parity with DDM/EFM
    has_edge_beam::Bool = false,
    edge_beam_βt::Float64 = 0.0,
    col_I_factor::Float64 = 0.70,  # ACI 318-11 §10.10.4.1
)
    setup = _moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0) = setup
    n_cols = length(supporting_columns)
    Lc = _get_column_height(supporting_columns)

    # Resolve effective βt for the FEA edge-beam construction.  The pipeline
    # may pass `βt` (computed in pipeline.jl from has_edge_beam / edge_beam_βt)
    # or callers may pass `edge_beam_βt` / `has_edge_beam` directly.
    eb_βt = if edge_beam_βt > 0
        edge_beam_βt
    elseif βt > 0
        βt
    elseif has_edge_beam
        # Default for `has_edge_beam=true` without explicit βt: assume the
        # full-edge-beam value from ACI 318-11 Table 13.6.4.2 (βt = 2.5).
        # ENGINEERING JUDGMENT: matches the `edge_beam=true` boolean fallback
        # used by `distribute_moments_aci` in DDM (see test_pipeline_provisions.jl).
        2.5
    else
        0.0
    end

    # Column concrete modulus (may differ from slab fc)
    fc_col = _get_column_fc(supporting_columns, fc)
    wc_pcf = ustrip(pcf, γ_concrete)
    Ecc = Ec(fc_col, wc_pcf)   # ACI 318-11 §19.2.2.1.a

    if verbose
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "MOMENT ANALYSIS — FEA (Column Stubs + ShellPatch)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Geometry" l1=l1 l2=l2 ln=ln c_avg=c1_avg h=h target_edge=method.target_edge
        @debug "Loads" qD=qD qL=qL qu=qu
        @debug "Reference M₀" M0=uconvert(kip * u"ft", M0)
        @debug "Edge beam" eb_βt=eb_βt has_edge_beam=has_edge_beam
    end

    # Build (or update) FEA model + precompute element data
    # D/L split: solve dead and live separately for proper load combination
    if isnothing(cache)
        cache = FEAModelCache()
    end
    _build_or_update_fea!(
        cache, struc, slab, supporting_columns, h, Ecs, ν_concrete, qu, Lc;
        Ecc=Ecc, target_edge=method.target_edge, verbose=verbose, drop_panel=drop_panel,
        col_I_factor=col_I_factor,
        qD=qD, qL=qL,
        patch_stiffness_factor=method.patch_stiffness_factor,
        edge_beam_βt   = eb_βt,
        edge_beam_l2   = l2,
        edge_beam_c1_avg = c1_avg,
    )
    model = cache.model

    # ── Edge/corner column diagnostic ──
    # Two distinct cases:
    # (1) Edge beam configured → frame elements have been added on the free
    #     perimeter (see `_build_fea_slab_model` and `_edge_beam_asap_sec`).
    # (2) No edge beam configured → edges remain free.  This is *physically
    #     correct* for a true flat plate (no perimeter beam in the structure).
    #     Only flag a warning if the user has edge/corner columns AND no
    #     edge beam, in case they intended to model one.
    if verbose
        edge_cols = [(i, col.position) for (i, col) in enumerate(supporting_columns)
                     if col.position in (:edge, :corner)]
        if !isempty(edge_cols)
            n_edge   = count(x -> x[2] == :edge,   edge_cols)
            n_corner = count(x -> x[2] == :corner, edge_cols)
            if eb_βt > 0
                @debug "FEA: edge-beam frame elements modelled on free perimeter " *
                       "(ACI 318-11 §13.6.4.2 / §13.7.5)" *
                       " — βt=$(round(eb_βt, digits=3)), " *
                       "$(n_edge) edge + $(n_corner) corner columns."
            else
                @debug "FEA EDGE DIAGNOSTIC: $n_edge edge + $n_corner corner columns " *
                       "with free slab perimeter.  This is physically correct for a " *
                       "true flat plate (no perimeter beam).  If a perimeter beam " *
                       "exists in the actual structure, set has_edge_beam=true or " *
                       "edge_beam_βt>0 in FlatPlateOptions to model it explicitly " *
                       "(ACI 318-11 §13.6.4.2)."
            end
        end
    end

    # Column forces from stubs (all Unitful)
    forces = _extract_fea_column_forces(cache.col_stubs, span_axis, n_cols)

    # ── Direct FE equilibrium: Σ(reactions_z) + Σ(P_z) ≈ 0 ──
    all_z_gids  = [n.globalID[3] for n in model.nodes]
    total_Pz    = sum(model.P[gid] for gid in all_z_gids)
    total_Rz_fe = sum(model.reactions[gid] for gid in all_z_gids)
    fe_residual = total_Pz + total_Rz_fe

    fe_equil_err = abs(fe_residual) / max(abs(total_Pz), 1e-6) * 100

    # Diagnostic: compare AreaLoad effective area vs element_data area
    A_mesh_from_P = abs(total_Pz) / ustrip(u"Pa", qu)
    A_elem_data   = sum(ed.area for ed in cache.element_data)
    area_mismatch = abs(A_mesh_from_P - A_elem_data) / max(A_elem_data, 1e-6) * 100

    Rz_kN  = round(total_Rz_fe / 1e3, digits=2)
    Pz_kN  = round(total_Pz / 1e3, digits=2)
    res_kN = round(fe_residual / 1e3, digits=4)
    @debug "EQUILIBRIUM (direct FE)" ΣRz_kN=Rz_kN ΣPz_kN=Pz_kN residual_kN=res_kN FE_err_pct=round(fe_equil_err, digits=4) A_from_P_m²=round(A_mesh_from_P, digits=3) A_elem_m²=round(A_elem_data, digits=3) area_Δ_pct=round(area_mismatch, digits=2)
    if fe_equil_err > 5.0
        error("FEA equilibrium error $(round(fe_equil_err, digits=2))% exceeds 5 % — results unreliable. Check mesh / BCs.")
    elseif fe_equil_err > 1.0
        @warn "FEA direct equilibrium error $(round(fe_equil_err, digits=2))%"
    end
    if area_mismatch > 10.0
        error("Mesh area mismatch $(round(area_mismatch, digits=1))% exceeds 10 % — mesh integrity compromised.")
    elseif area_mismatch > 5.0
        @warn "Mesh area mismatch $(round(area_mismatch, digits=1))%: " *
              "AreaLoad=$(round(A_mesh_from_P, digits=3))m² vs elem_data=$(round(A_elem_data, digits=3))m²"
    end

    # Cell-polygon strip integration using precomputed data
    incl_torsion = method.moment_transform != :no_torsion
    envelope = _extract_cell_moments(
        cache, struc, slab, supporting_columns,
        span_axis; include_torsion=incl_torsion, verbose=verbose
    )

    # Bandwidth convergence diagnostic (verbose only)
    if verbose
        _check_bandwidth_convergence(cache, struc, slab, supporting_columns, span_axis)
    end

    column_moments = [uconvert(kip * u"ft", m * u"N*m") for m in envelope.col_Mneg]

    neg_env = _envelope_from_columns(column_moments, supporting_columns)
    M_neg_ext = neg_env.M_neg_ext
    M_neg_int = neg_env.M_neg_int
    M_pos     = uconvert(kip * u"ft", envelope.M_pos)

    # Max panel deflection from FEA nodal displacements (slab-level nodes only)
    _slab_node_filter(n) = ustrip(u"m", n.position[3]) > -0.01
    fea_Δ_panel = abs(minimum(
        n.displacement[3] for n in model.nodes if _slab_node_filter(n)
    ))

    if verbose
        @debug "FEA MAX DISPLACEMENT" Δ_panel=uconvert(u"inch", fea_Δ_panel)
    end

    # ─── Pattern loading (ACI 318-11 §13.7.6) ───
    use_pattern = method.pattern_loading && requires_pattern_loading(qD, qL) && n_cols >= 3
    if use_pattern
        if method.pattern_mode === :fea_resolve
            # ── FEA-native pattern loading ──
            # Decompose live load into per-cell contributions, then envelope
            # across all ACI 318-11 §13.7.6 load patterns.
            # This modifies cache.element_data in-place with the governing envelope.
            _solve_per_cell_live!(cache, slab, qL; verbose=verbose)
            _fea_pattern_envelope!(cache, slab; verbose=verbose)

            # Assemble governing displacement field from pattern envelope
            # and inject into model for consistent column force extraction.
            U_pattern = _pattern_envelope_displacement(cache, slab)
            copy!(model.u, U_pattern)
            Asap.post_process!(model; targets=:elements)

            # Re-extract column forces from the pattern-enveloped displacement
            forces = _extract_fea_column_forces(cache.col_stubs, span_axis, n_cols)

            # Update fea_Δ_panel from pattern envelope displacement
            fea_Δ_panel = abs(minimum(
                U_pattern[n.globalID[3]] * u"m" for n in model.nodes
                if _slab_node_filter(n)
            ))

            # Re-extract moments from the updated element_data
            envelope = _extract_cell_moments(
                cache, struc, slab, supporting_columns,
                span_axis; include_torsion=incl_torsion, verbose=verbose
            )
            column_moments = [uconvert(kip * u"ft", m * u"N*m") for m in envelope.col_Mneg]
            neg_env = _envelope_from_columns(column_moments, supporting_columns)
            M_neg_ext = neg_env.M_neg_ext
            M_neg_int = neg_env.M_neg_int
            M_pos     = uconvert(kip * u"ft", envelope.M_pos)

            verbose && @debug "FEA PATTERN LOADING (:fea_resolve)" n_cells=length(slab.cell_indices) Δ_pattern=uconvert(u"inch", fea_Δ_panel)
        else
            # ── EFM amplification (default: :efm_amp) ──
            fc_col_pat = _get_column_fc(supporting_columns, fc)
            wc_pcf_val = ustrip(pcf, γ_concrete)
            Ecc_pat = Ec(fc_col_pat, wc_pcf_val)

            efm_spans = _build_efm_spans(supporting_columns, l1, l2, ln, h, Ecs;
                                         drop_panel=drop_panel)
            joint_pos = [col.position for col in supporting_columns]
            cshape   = col_shape(first(supporting_columns))
            jKec     = _compute_joint_Kec(efm_spans, joint_pos, Lc, Ecs, Ecc_pat;
                                          column_shape=cshape, columns=supporting_columns)
            n_efm_spans = length(efm_spans)

            efm_full = solve_moment_distribution(efm_spans, jKec, joint_pos, qu)
            env_neg_ext = abs(efm_full[1].M_neg_left)
            env_neg_int = abs(efm_full[1].M_neg_right)
            env_pos     = abs(efm_full[1].M_pos)

            for pat in generate_load_patterns(n_efm_spans)
                all(==(:dead_plus_live), pat) && continue
                qu_ps = factored_pattern_loads(pat, qD, qL)
                efm_p = solve_moment_distribution(efm_spans, jKec, joint_pos, qu_ps)
                abs(efm_p[1].M_neg_left)  > env_neg_ext && (env_neg_ext = abs(efm_p[1].M_neg_left))
                abs(efm_p[1].M_neg_right) > env_neg_int && (env_neg_int = abs(efm_p[1].M_neg_right))
                abs(efm_p[1].M_pos)       > env_pos     && (env_pos     = abs(efm_p[1].M_pos))
            end

            _safe_amp(env, base) = ustrip(base) > 1e-6 ? max(1.0, ustrip(env) / ustrip(base)) : 1.0
            amp_ext = _safe_amp(env_neg_ext, abs(efm_full[1].M_neg_left))
            amp_int = _safe_amp(env_neg_int, abs(efm_full[1].M_neg_right))
            amp_pos = _safe_amp(env_pos,     abs(efm_full[1].M_pos))

            M_neg_ext *= amp_ext
            M_neg_int *= amp_int
            M_pos     *= amp_pos

            verbose && @debug "FEA PATTERN LOADING (:efm_amp)" amp_ext=round(amp_ext, digits=3) amp_int=round(amp_int, digits=3) amp_pos=round(amp_pos, digits=3)
        end
    end

    M0_u = uconvert(kip * u"ft", M0)
    Vu_max = uconvert(kip, qu * l2 * ln / 2)

    if verbose
        @debug "FEA RESULT ($(envelope.n_cells) cells)" begin
            Mne = round(ustrip(kip * u"ft", M_neg_ext), digits=1)
            Mni = round(ustrip(kip * u"ft", M_neg_int), digits=1)
            Mp  = round(ustrip(kip * u"ft", M_pos), digits=1)
            M0k = round(ustrip(kip * u"ft", M0_u), digits=1)
            sum_pct = M0k > 0 ? round(((Mne + Mni) / 2 + Mp) / M0k * 100, digits=1) : 0.0
            "M⁻_ext=$Mne  M⁻_int=$Mni  M⁺=$Mp  (M₀=$M0k, ∑/M₀=$(sum_pct)%)"
        end
        for (i, col) in enumerate(supporting_columns)
            @debug "  Column $i ($(col.position))" begin
                Vu_s = round(ustrip(kip, forces.Vu[i]), digits=1)
                Mub_s = round(ustrip(kip * u"ft", forces.Mub[i]), digits=1)
                Mn = round(ustrip(kip * u"ft", column_moments[i]), digits=1)
                "Vu=$Vu_s kip  Mub=$Mub_s  M⁻=$Mn kip-ft"
            end
        end
    end

    # ─── Secondary direction: perpendicular strip integration ───
    sec_setup = _secondary_moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    sec_span_axis = sec_setup.span_axis

    sec_envelope = _extract_cell_moments(
        cache, struc, slab, supporting_columns,
        sec_span_axis; include_torsion=incl_torsion, verbose=false
    )
    sec_column_moments = [uconvert(kip * u"ft", m * u"N*m") for m in sec_envelope.col_Mneg]
    sec_neg_env = _envelope_from_columns(sec_column_moments, supporting_columns)

    sec_ax_len = hypot(sec_span_axis...)
    sec_ax = sec_ax_len > 1e-9 ? (sec_span_axis[1]/sec_ax_len, sec_span_axis[2]/sec_ax_len) : (0.0, 1.0)
    MomentT = typeof(1.0kip * u"ft")
    sec_Mub = Vector{MomentT}(undef, n_cols)
    for i in 1:n_cols
        sec_Mub[i] = uconvert(kip * u"ft", abs(sec_ax[1] * forces.My[i] - sec_ax[2] * forces.Mx[i]))
    end

    secondary_data = (
        M0 = uconvert(kip * u"ft", sec_setup.M0),
        M_neg_ext = sec_neg_env.M_neg_ext,
        M_neg_int = sec_neg_env.M_neg_int,
        M_pos = uconvert(kip * u"ft", sec_envelope.M_pos),
        l1 = sec_setup.l1,
        l2 = sec_setup.l2,
        ln = sec_setup.ln,
        column_moments = sec_column_moments,
        column_shears = forces.Vu,
        unbalanced_moments = sec_Mub,
    )

    return MomentAnalysisResult(
        M0_u,
        M_neg_ext,
        M_neg_int,
        M_pos,
        qu, qD, qL,
        l1, l2, ln, c1_avg,
        column_moments,
        forces.Vu,
        forces.Mub,
        Vu_max;
        secondary = secondary_data,
        fea_Δ_panel = fea_Δ_panel,
        pattern_loading = use_pattern,
    )
end

"""
    run_secondary_moment_analysis(::FEA, ...) -> NamedTuple

For FEA, secondary moments are already computed during `run_moment_analysis`
and stored in `moment_results.secondary`.  This method just extracts it.
"""
function run_secondary_moment_analysis(
    method::FEA,
    struc, slab, supporting_columns, h::Length,
    fc::Pressure, Ecs::Pressure, γ_concrete;
    moment_results = nothing,
    kwargs...
)
    if !isnothing(moment_results) && !isnothing(moment_results.secondary)
        return moment_results.secondary
    end
    return run_secondary_moment_analysis(
        DDM(), struc, slab, supporting_columns, h, fc, Ecs, γ_concrete; kwargs...
    )
end
