
# =============================================================================
# EFM Moment Analysis
# =============================================================================

"""
    run_moment_analysis(method::EFM, struc, slab, columns, h, fc, Ecs, γ_concrete; kwargs...)

Run moment analysis using Equivalent Frame Method (EFM).

EFM models the floor as one equivalent frame per column line, longitudinally and transversely (ACI 318-11 §13.7.2.1, corpus: aci-318-11, page 259).
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
    has_edge_beam::Bool = false,    # API parity (EFM uses Kt directly)
    edge_beam_βt::Float64 = 0.0,    # API parity (EFM uses Kt directly)
    col_I_factor::Float64 = 0.70,  # ACI 318-11 §10.10.4.1 — cracked-column magnitude (from caller)
    tc = nothing,  # API parity with DDM (EFM does not emit Eq. 13-7 fallbacks)
)
    setup = _moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    verbose && @debug "MOMENT ANALYSIS - EFM" solver=method.solver column_stiffness=method.column_stiffness n_columns=length(supporting_columns)
    return _analyze_equivalent_frames(
        method, struc, supporting_columns, h, fc, Ecs, γ_concrete, setup;
        ν_concrete, verbose, efm_cache, drop_panel, col_I_factor,
    )
end

# =============================================================================
# Secondary (Perpendicular) Direction — EFM
# =============================================================================

"""
    run_secondary_moment_analysis(method::EFM, struc, slab, columns, h, fc, Ecs, γ_concrete; kwargs...) -> MomentAnalysisResult

Run EFM in the perpendicular direction (swapped l1↔l2).

Groups the columns into frame lines along the perpendicular axis and
solves each line. The span-parallel column face is the face along that
axis. The primary direction's Asap model is not reused.

Honors `method.solver` (`:asap` or `:hardy_cross`), `method.column_stiffness`,
`method.cracked_columns`, and `method.pattern_loading` — same option matrix
as the primary direction.

Returns a full `MomentAnalysisResult` for consistency with the primary direction.

# Reference
- ACI 318-11 §13.7
"""
function run_secondary_moment_analysis(
    method::EFM,
    struc, slab, supporting_columns, h::Length,
    fc::Pressure, Ecs::Pressure, γ_concrete;
    ν_concrete::Float64 = 0.20,
    verbose::Bool = false,
    drop_panel = nothing,
    col_I_factor::Float64 = 0.70,  # ACI 318-11 §10.10.4.1 — cracked-column magnitude (from caller)
    kwargs...
)
    setup = _secondary_moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    return _analyze_equivalent_frames(
        method, struc, supporting_columns, h, fc, Ecs, γ_concrete, setup;
        ν_concrete, verbose, efm_cache = nothing, drop_panel, col_I_factor,
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

