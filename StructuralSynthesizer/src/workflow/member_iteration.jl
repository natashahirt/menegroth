# =============================================================================
# Uniform Column Size Harmonization
# =============================================================================

"""
    harmonize_uniform_column_sizes!(struc, params) -> Int

Post-pipeline pass that promotes column sizes within each uniformity group to
the governing (largest) member.  Groups are defined by `params.uniform_column_sizing`:

- `:per_story` — one group per `Column.story`
- `:building`  — single group for all columns

Returns the number of columns that were enlarged.

**Conservative guarantee:** A larger column never degrades axial, flexural, or
punching capacity vs the individually-sized result — only improves it.

For **RC columns** (`c1`/`c2` dimensions), the maximum `c1` and `c2` within
each group are propagated.  For **steel columns** (catalog sections), the
section with the largest cross-sectional area is propagated.  After
propagation, ASAP element sections and structural offsets are refreshed.
"""
function harmonize_uniform_column_sizes!(struc::BuildingStructure, params::DesignParameters)
    mode = params.uniform_column_sizing
    mode === :off && return 0

    columns = struc.columns
    isempty(columns) && return 0

    # --- Build groups: story → indices (or single group for :building) ---
    groups = Dict{Int, Vector{Int}}()
    for (i, col) in enumerate(columns)
        key = mode === :building ? 0 : col.story
        push!(get!(Vector{Int}, groups, key), i)
    end

    col_opts = params.columns
    is_steel = col_opts isa StructuralSizer.SteelColumnOptions

    changed = 0

    for (_, indices) in groups
        length(indices) <= 1 && continue

        if is_steel
            changed += _harmonize_steel_group!(struc, indices)
        else
            changed += _harmonize_rc_group!(struc, params, indices)
        end
    end

    if changed > 0
        update_structural_offsets!(struc; input_is_centerline=params.geometry_is_centerline)
        if struc.asap_model.processed
            Asap.update!(struc.asap_model; values_only=true)
            Asap.solve!(struc.asap_model)
            _refresh_pattern_solve_cache!(struc)
        end
        @info "Uniform column harmonization: $changed columns enlarged" mode=string(mode)
    end

    return changed
end

"""Promote RC columns in `indices` to max(c1) × max(c2). Returns count of enlarged columns."""
function _harmonize_rc_group!(struc::BuildingStructure, params::DesignParameters, indices::Vector{Int})
    columns = struc.columns
    cols = [columns[i] for i in indices]

    sized = filter(c -> !isnothing(c.c1) && !isnothing(c.c2), cols)
    isempty(sized) && return 0

    gov_c1 = maximum(c.c1 for c in sized)
    gov_c2 = maximum(c.c2 for c in sized)

    # Resolve concrete properties for ASAP section
    conc = resolve_column_concrete(params.materials)
    E_Pa  = ustrip(u"Pa", conc.E)
    ν_c   = conc.ν
    G_Pa  = E_Pa / (2.0 * (1.0 + ν_c))
    ρ_kg  = ustrip(u"kg/m^3", conc.ρ)
    I_factor = params.column_I_factor

    changed = 0
    for i in indices
        col = columns[i]
        (isnothing(col.c1) || isnothing(col.c2)) && continue
        already = col.c1 == gov_c1 && col.c2 == gov_c2
        if already && !isempty(volumes(col))
            continue
        end

        col.c1 = gov_c1
        col.c2 = gov_c2
        already || (changed += 1)

        # A column that already matches keeps its section. One that grew, or
        # that never received a section, gets the same bar assignment as
        # reconciliation. Volumes are written either way when they were empty.
        if !already || isnothing(section(col))
            _assign_flat_plate_column_section!(col)
        end

        # Gross section area as a single concrete volume counted the rebar
        # volume at the concrete coefficient and left rebar carbon at zero.
        _set_rc_column_volumes!(
            col,
            something(col.concrete, resolve_column_concrete(params.materials)),
            resolve_column_rebar(params.materials),
        )
        already && continue

        # Rebuild ASAP element section
        b_m = ustrip(u"m", col.c1)
        h_m = ustrip(u"m", col.c2)
        asap_sec = if col.shape == :circular
            D_m = b_m
            A = π * D_m^2 / 4
            I = π * D_m^4 / 64
            J = π * D_m^4 / 32
            Asap.Section(
                A * u"m^2", E_Pa * u"Pa", G_Pa * u"Pa",
                I_factor * I * u"m^4", I_factor * I * u"m^4",
                I_factor * J * u"m^4", ρ_kg * u"kg/m^3")
        else
            A    = b_m * h_m
            Ig_x = b_m * h_m^3 / 12
            Ig_y = h_m * b_m^3 / 12
            a_dim = max(b_m, h_m); b_dim = min(b_m, h_m)
            β = 1/3 - 0.21 * (b_dim / a_dim) * (1 - (b_dim / a_dim)^4 / 12)
            Asap.Section(
                A * u"m^2", E_Pa * u"Pa", G_Pa * u"Pa",
                I_factor * Ig_x * u"m^4", I_factor * Ig_y * u"m^4",
                I_factor * β * a_dim * b_dim^3 * u"m^4", ρ_kg * u"kg/m^3")
        end

        for seg_idx in segment_indices(col)
            edge_idx = struc.segments[seg_idx].edge_idx
            (edge_idx < 1 || edge_idx > length(struc.asap_model.frame_elements)) && continue
            struc.asap_model.frame_elements[edge_idx].section = asap_sec
        end
    end

    return changed
end

"""Promote steel columns in `indices` to the heaviest section. Returns count of changed columns."""
function _harmonize_steel_group!(struc::BuildingStructure, indices::Vector{Int})
    columns = struc.columns

    # Find governing section (largest cross-sectional area)
    gov_sec = nothing
    gov_area = -Inf
    gov_vols = nothing
    for i in indices
        sec = section(columns[i])
        isnothing(sec) && continue
        a = ustrip(u"m^2", StructuralSizer.section_area(sec))
        if a > gov_area
            gov_area = a
            gov_sec = sec
            gov_vols = volumes(columns[i])
        end
    end
    isnothing(gov_sec) && return 0

    gov_mat_key = (isnothing(gov_vols) || isempty(gov_vols)) ?
        StructuralSizer.A992_Steel : first(keys(gov_vols))
    asap_sec = StructuralSizer.to_asap_section(gov_sec, gov_mat_key)

    changed = 0
    for i in indices
        col = columns[i]
        sec = section(col)
        isnothing(sec) && continue
        sec === gov_sec && continue
        a = ustrip(u"m^2", StructuralSizer.section_area(sec))
        a >= gov_area && continue

        set_section!(col, gov_sec)
        !isnothing(gov_vols) && !isempty(gov_vols) && set_volumes!(col, copy(gov_vols))
        changed += 1

        for seg_idx in segment_indices(col)
            edge_idx = struc.segments[seg_idx].edge_idx
            (edge_idx < 1 || edge_idx > length(struc.asap_model.frame_elements)) && continue
            struc.asap_model.frame_elements[edge_idx].section = asap_sec
        end
    end

    return changed
end

"""Extract compressive axial force (N) for a column from the Asap model.

Asap local `P` is negative in compression (same convention as
`member_group_demands`). Tension is not folded into compression via `abs`.
"""
function _column_asap_Pu(struc::BuildingStructure, col)
    Pu = 0.0
    for seg_idx in segment_indices(col)
        seg = struc.segments[seg_idx]
        edge_idx = seg.edge_idx
        (edge_idx < 1 || edge_idx > length(struc.asap_model.frame_elements)) && continue
        el = struc.asap_model.frame_elements[edge_idx]
        isempty(el.forces) && continue
        n_dof = length(el.forces)
        P_start = el.forces[1]
        P_end = n_dof >= 7 ? el.forces[7] : P_start
        Pu = max(Pu, max(0.0, -P_start), max(0.0, -P_end))
    end
    return Pu
end

"""Rebuild K, re-solve, and refresh pattern `(u, loads)` after a section change."""
function _reanalyze_after_section_change!(struc::BuildingStructure)
    if struc.asap_model.processed
        Asap.update!(struc.asap_model)
    else
        Asap.process!(struc.asap_model)
    end
    Asap.solve!(struc.asap_model)
    _refresh_pattern_solve_cache!(struc)
    return struc
end

"""
Iterative beam + column sizing for beam-based floor systems.

Beams and columns are coupled: beam self-weight affects column demands, and
column stiffness affects beam moments. This loop converges their sizes.
"""
function _size_beams_columns!(struc::BuildingStructure, params::DesignParameters;
                              tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    # Defensive guard: slab-only systems should not run beam sizing.
    # This keeps flat-plate/flat-slab workflows resilient even if an upstream
    # caller accidentally routes into the beam+column stage.
    if !isempty(struc.slabs)
        floor_types = Set(s.floor_type for s in struc.slabs)
        if all(ft -> ft in (:flat_plate, :flat_slab, :grade, :roof), floor_types)
            # [P1 fix cycle 3] Honor-or-throw invariant on the SLAB-ONLY skip branch.
            # Beam sizing is about to be skipped, so no steel beam group will be sized
            # and an EFFECTIVE per-group `member_group_overrides` entry can never be
            # honored on this path — materializing a BuildingDesign anyway would
            # SILENTLY DROP it (the exact safety hazard the feature exists to prevent).
            # The floor-type door (`_assert_member_group_overrides_unsupported`) already
            # refuses flat_plate/flat_slab effective overrides, so the residual exposure
            # closed here is a slab-only :grade/:roof geometry. Empty / all-unset
            # (vacuous) overrides stay a strict no-op (byte-identical). Uses the SAME
            # effectiveness test as the rest of the feature (`_is_effective`).
            # (catalog / deflection_limit / max_depth are engineering sizing knobs — no
            # code citation.)
            if any(_is_effective, values(params.member_group_overrides))
                throw(ArgumentError(_mgo_refusal_message(
                    "beam sizing is skipped for a slab-only floor system " *
                    "(floor_types=$(collect(floor_types))) in the beam+column stage, so " *
                    "no steel beam group is sized and the per-group override cannot be " *
                    "honored")))
            end
            @warn "Skipping beam sizing for slab-only floor system in beam+column stage" floor_types=collect(floor_types)
            StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                                  outcome="skipped", reason="slab_only_system",
                                  floor_types=collect(string.(collect(floor_types))))
            _reconcile_columns!(struc, params; tc=tc)
            StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :exit;
                                  outcome="skipped")
            return struc
        end
    end

    beam_opts   = something(params.beams,   StructuralSizer.SteelBeamOptions())
    column_opts = something(params.columns, StructuralSizer.SteelColumnOptions())
    skel = struc.skeleton
    beam_edge_ids = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(beam_edge_ids, get(skel.groups_edges, g, Int[]))
    end

    # Skip beam sizing when no beam edges (e.g. beam-based floor type but geometry has no beams)
    if isempty(beam_edge_ids)
        # [P1 fix cycle 3] Honor-or-throw invariant on the NO-BEAM-EDGES skip branch.
        # Beam sizing is skipped (columns only), so an EFFECTIVE per-group
        # `member_group_overrides` entry targets a steel beam group that will never be
        # sized on this path; producing a BuildingDesign would SILENTLY DROP it. This
        # fires on a NON-flat steel floor that has columns but no :beams edge group,
        # on BOTH `design_building` and `redesign_incremental!` (both route through
        # `_size_beams_columns!`). Empty / all-unset (vacuous) overrides stay a strict
        # no-op (byte-identical). (Engineering sizing knobs — no code citation.)
        if any(_is_effective, values(params.member_group_overrides))
            throw(ArgumentError(_mgo_refusal_message(
                "beam sizing is skipped because the geometry has no :beams edges " *
                "(sizing columns only), so no steel beam group is sized and the " *
                "per-group override cannot be honored")))
        end
        @warn "Skipping beam sizing: no beam edges in geometry. Sizing columns only."
        StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                              outcome="skipped_beams", reason="no_beam_edges")
        size_columns!(struc, column_opts; reanalyze=false, tc=tc,
                      I_factor=params.column_I_factor)  # ACI 318-11 §10.10.4.1
        _reanalyze_after_section_change!(struc)
        _run_p_delta_if_needed!(struc, column_opts; verbose=false, tc=tc,
                                I_factor=params.column_I_factor)  # ACI 318-11 §10.10.4.1
        if has_fire_rating(params)
            n_col = add_coating_loads!(struc, params; member_edge_group=:columns, resolve=false)
            if n_col > 0
                Asap.process!(struc.asap_model)
                Asap.solve!(struc.asap_model)
                _refresh_pattern_solve_cache!(struc)
            end
        end
        StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :exit;
                              outcome="columns_only")
        return struc
    end

    tol = 0.05
    max_iter = params.max_iterations
    verbose = false

    n_cols_bc = length(struc.columns)
    prev_demands = Vector{Float64}(undef, n_cols_bc)
    curr_demands = Vector{Float64}(undef, n_cols_bc)
    first_iter = true
    converged = false
    iters_used = 0
    
    StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :enter;
                          n_beams=length(beam_edge_ids), n_columns=n_cols_bc,
                          beam_type=string(typeof(beam_opts)),
                          column_type=string(typeof(column_opts)))

    # Run 4 / Phase B: forward per-group member_group_overrides into the batched
    # beam sizing. `nothing`/vacuous overrides route the pre-Phase-B path verbatim
    # (byte-identical); an effective steel-beam-group override narrows only that
    # group. Un-honorable targets are already refused upstream by the guard.
    mgo = isempty(params.member_group_overrides) ? nothing : params.member_group_overrides

    for iter in 1:max_iter
        iters_used = iter
        size_beams!(struc, beam_opts; reanalyze=false, tc=tc,
                    member_group_overrides=mgo, I_factor=params.beam_I_factor,
                    composite_concrete=resolve_slab_concrete(params.materials),
                    composite_option_kwargs(beam_opts)...)
        
        _reanalyze_after_section_change!(struc)
        
        size_columns!(struc, column_opts; reanalyze=false, tc=tc,
                      I_factor=params.column_I_factor)
        
        _reanalyze_after_section_change!(struc)
        
        _extract_column_demands!(curr_demands, struc)
        if !first_iter && _max_demand_change(prev_demands, curr_demands) < tol
            StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                                  outcome="converged", iterations=iter)
            converged = true
            break
        end
        copyto!(prev_demands, curr_demands)
        first_iter = false
    end
    
    # ─── P-Δ second-order analysis (ACI 318-11 §10.10) ───
    # After first-order sizing converges, check if any story has δs > 1.5.
    # If so, run iterative P-Δ to capture second-order effects, then re-size
    # columns with the updated forces.
    _run_p_delta_if_needed!(struc, column_opts; verbose=verbose, tc=tc,
                            I_factor=params.column_I_factor)  # ACI 318-11 §10.10.4.1
    
    # ─── Fire protection coating loads (steel members only) ───
    # After sizing, add SFRM/intumescent self-weight and re-solve.
    if has_fire_rating(params)
        n_beam = add_coating_loads!(struc, params; member_edge_group=:beams, resolve=false)
    # Also add for other beam-like groups if present
    for g in (:joists, :secondary, :girder)
        n_beam += add_coating_loads!(struc, params; member_edge_group=g, resolve=false)
    end
        n_col  = add_coating_loads!(struc, params; member_edge_group=:columns, resolve=false)
        if (n_beam + n_col) > 0
            Asap.process!(struc.asap_model)
            Asap.solve!(struc.asap_model)
            _refresh_pattern_solve_cache!(struc)
        end
    end
    
    StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :exit;
                          converged=converged,
                          iterations=iters_used)
    return struc
end

StructuralSizer.TRACE_REGISTRY[(:_run_p_delta_if_needed!, :workflow)] =
    StructuralSizer.TracedFunctionMeta(
        :_run_p_delta_if_needed!,
        :workflow,
        [:enter, :exit, :decision],
        nothing,
        @__FILE__,
        @__LINE__,
    )

"""
    _run_p_delta_if_needed!(struc, column_opts; verbose=false)

Check whether any story requires P-Δ analysis (δs > 1.5 from both Q and ΣPc
methods).  If so, run `p_delta_iterate!` and re-size columns.
"""
function _run_p_delta_if_needed!(
    struc::BuildingStructure,
    column_opts;
    verbose::Bool = false,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
    # ACI 318-11 §10.10.4.1 — cracked-stiffness reduction for concrete column sections,
    # threaded from params.column_I_factor. Default 0.70 keeps any caller that does not
    # pass it byte-identical (matches to_asap_section's concrete-column default).
    I_factor::Real = 0.70,
)
    StructuralSizer.emit!(tc, :workflow, "_run_p_delta_if_needed!", "", :enter;
                          n_columns=length(struc.columns))
    # Compute story properties with the current solved model
    compute_story_properties!(struc; verbose=false)
    
    # Check if any story needs P-Δ
    # story_properties fields are Float64 in (kip, inch) units
    needs_pdelta = false
    for col in struc.columns
        props = col.story_properties
        isnothing(props) && continue
        
        sp = StructuralSizer.SwayStoryProperties(
            props.ΣPu, props.ΣPc, props.Vus, props.Δo, props.lc
        )
        Q = StructuralSizer.stability_index(sp)
        δs_Q = Q < 1.0 ? 1.0 / (1.0 - Q) : Inf
        
        if δs_Q > 1.5
            needs_pdelta = true
            break
        end
    end
    
    if !needs_pdelta
        StructuralSizer.emit!(tc, :workflow, "_run_p_delta_if_needed!", "", :decision;
                              outcome="skipped", reason="delta_s_below_threshold")
        StructuralSizer.emit!(tc, :workflow, "_run_p_delta_if_needed!", "", :exit;
                              ran=false)
        return
    end
    
    verbose && @info "δs > 1.5 detected — running P-Δ second-order analysis (ACI §6.7)"
    
    result = p_delta_iterate!(struc; verbose=verbose)
    
    if !isempty(result.stories_needing_attention)
        @warn "P-Δ drift ratio exceeds 1.4× first-order (ACI §6.6.4.6.2)" stories=result.stories_needing_attention ratio=round(result.max_drift_ratio, digits=2)
    end
    
    # Re-size columns with updated second-order forces
    size_columns!(struc, column_opts; reanalyze=false, tc=tc,
                  I_factor=I_factor)  # ACI 318-11 §10.10.4.1
    StructuralSizer.emit!(tc, :workflow, "_run_p_delta_if_needed!", "", :decision;
                          outcome="ran",
                          n_stories_attention=length(result.stories_needing_attention),
                          max_drift_ratio=round(result.max_drift_ratio; digits=3))
    StructuralSizer.emit!(tc, :workflow, "_run_p_delta_if_needed!", "", :exit;
                          ran=true)
    
    return
end

