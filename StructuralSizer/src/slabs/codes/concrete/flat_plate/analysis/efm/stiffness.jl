
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
    column_concrete = nothing,  # column Ec; slab concrete when nothing
)
    setup = _moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    verbose && @debug "MOMENT ANALYSIS - EFM" solver=method.solver column_stiffness=method.column_stiffness n_columns=length(supporting_columns)
    return _analyze_equivalent_frames(
        method, struc, supporting_columns, h, fc, Ecs, γ_concrete, setup;
        slab, ν_concrete, verbose, efm_cache, drop_panel, col_I_factor, column_concrete,
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
    column_concrete = nothing,
    kwargs...
)
    setup = _secondary_moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    return _analyze_equivalent_frames(
        method, struc, supporting_columns, h, fc, Ecs, γ_concrete, setup;
        slab, ν_concrete, verbose, efm_cache = nothing,
        drop_panel = _transposed_drop(drop_panel), col_I_factor, column_concrete,
    )
end

"""
The drop seen from the secondary direction: `a_drop_2` runs along the span
and `a_drop_1` across it.
"""
_transposed_drop(::Nothing) = nothing
_transposed_drop(dp::DropPanelGeometry) = DropPanelGeometry(dp.h_drop, dp.a_drop_2, dp.a_drop_1)

# =============================================================================
# EFM Joint Stiffness Computation
# =============================================================================

"""
True when joint `j` is a wall that supports the whole edge.

That joint does not rotate (ACI 318-11 R13.1, aci-318-11, page 243), so
its equivalent column stiffness is infinite and the slab distribution
factors at the joint are zero. `columns === nothing` leaves every joint
as a column.
"""
function _joint_is_fixed_wall(columns, j::Int)
    columns === nothing && return false
    1 <= j <= length(columns) || return false
    return _support_is_wall_fixed(columns[j])
end

"""
    _joint_column_dims(spans, j) -> (c1, c2)

Column faces at joint `j`, frame-relative: `c1` along the span, `c2`
across it. Interior joints average the two spans' faces.
"""
function _joint_column_dims(spans, j::Int)
    n_joints = length(spans) + 1
    j == 1 && return spans[1].c1_left, spans[1].c2_left
    j == n_joints && return spans[end].c1_right, spans[end].c2_right
    return (spans[j-1].c1_right + spans[j].c1_left) / 2,
           (spans[j-1].c2_right + spans[j].c2_left) / 2
end

"""
    _joint_ΣKc(spans, j, H, Ecc, k_col; column_shape, columns) -> Moment

Column stiffness above plus below joint `j` (ACI 318-11 §13.7.4).

With `columns`, the column above is its own section and height, and a roof
joint has none. Without `columns`, the column above is taken as identical.
"""
function _joint_ΣKc(spans, j::Int, H::Length, Ecc::Pressure, k_col::Float64;
                    column_shape::Symbol, columns)
    h = spans[1].h
    drop = spans[1].drop
    c1, c2 = _joint_column_dims(spans, j)
    Ic = column_moment_of_inertia(c1, c2; shape=column_shape)
    # A flat slab's joint is h + h_drop deep, deeper on the drop side
    # (PCA Table A7 with ta ≠ tb; see `column_stiffness_Kc` with a drop).
    Kc_below = drop === nothing ?
        column_stiffness_Kc(Ecc, Ic, H, h; k_factor=k_col) :
        column_stiffness_Kc(Ecc, Ic, H, h, drop; position=:bottom)
    columns === nothing && return drop === nothing ? 2 * Kc_below :
        Kc_below + column_stiffness_Kc(Ecc, Ic, H, h, drop; position=:top)
    col_above = columns[j].column_above
    col_above === nothing && return Kc_below
    sec_a = _sized_column_section(col_above)
    c1_a, c2_a = sec_a === nothing ? (c1, c2) : sec_a
    H_a = col_above.base.L isa Length ? col_above.base.L : H
    Ic_a = column_moment_of_inertia(c1_a, c2_a; shape=column_shape)
    Kc_above = drop === nothing ?
        column_stiffness_Kc(Ecc, Ic_a, H_a, h; k_factor=pca_column_factors(H_a, h).k) :
        column_stiffness_Kc(Ecc, Ic_a, H_a, h, drop; position=:top)
    return Kc_below + Kc_above
end

"""
    _joint_ΣKt(spans, j, joint_positions, Ecs; column_shape, torsion_l2) -> Moment

Torsional stiffness at joint `j`, summed over its torsional members.

ACI 318-11 R13.7.4 (corpus: aci-318-11, page 260): the equivalent column has
torsional members "on each side of the columns extending to the centerline of
the adjacent panels". R13.7.5 (page 261): Kt = Σ 9·Ecs·C / [l2·(1 − c2/l2)³],
one term per member, with l2 the transverse span on that member's side.
§13.7.5.1(a) (page 260): the member is slab as wide as the column in the
direction of the span, so C uses c1 (Eq. 13-6, x = h, y = c1).

`torsion_l2 = (l2_neg, l2_pos)` is the frame line's transverse span on each
side; a zero side has no adjacent panel and no member. Without it, the member
count follows `joint_positions` (2 at `:interior`, else 1) and each member
uses the frame width `spans[1].l2`.
"""
function _joint_ΣKt(spans, j::Int, joint_positions, Ecs::Pressure;
                    column_shape::Symbol, torsion_l2)
    h = spans[1].h
    c1, c2 = _joint_column_dims(spans, j)
    if column_shape == :circular
        c1, c2 = equivalent_square_column(c1), equivalent_square_column(c2)
    end
    has_drops = has_drop_panels(spans[1])
    h_t = has_drops ? total_depth_at_drop(h, spans[1].drop) : h
    C = torsional_constant_C(h_t, c1)
    sides = if torsion_l2 === nothing
        l2 = spans[1].l2
        joint_positions[j] == :interior ? (l2, l2) : (l2,)
    else
        Tuple(l for l in torsion_l2 if l > zero(l))
    end
    isempty(sides) && throw(ArgumentError(
        "EFM joint $j has no adjacent panel transverse to the frame, so no torsional member"))
    return sum(torsional_member_stiffness_Kt(Ecs, C, l2_side, c2) for l2_side in sides)
end

"""
    _compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc; columns=nothing, torsion_l2=nothing, ...)

Equivalent column stiffness Kec at each joint (ACI 318-11 §13.7.4–13.7.5):

    1/Kec = 1/ΣKc + 1/ΣKt

`k_col` comes from PCA Table A7 at the actual H/Hc. See [`_joint_ΣKc`](@ref)
for the columns above and below and [`_joint_ΣKt`](@ref) for the torsional
members and `torsion_l2`. A fixed wall joint is infinitely stiff.

`use_kc_only = true` (`EFM(column_stiffness=:Kc)`) returns ΣKc with no
torsional reduction.
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
    torsion_l2 = nothing,
)
    k_col = pca_column_factors(H, spans[1].h).k
    Kec = Vector{Moment}(undef, length(spans) + 1)
    for j in eachindex(Kec)
        if _joint_is_fixed_wall(columns, j)
            Kec[j] = Inf * u"kip*ft"
            continue
        end
        ΣKc = _joint_ΣKc(spans, j, H, Ecc, k_col; column_shape, columns)
        Kec[j] = use_kc_only ? ΣKc : equivalent_column_stiffness_Kec(
            ΣKc, _joint_ΣKt(spans, j, joint_positions, Ecs; column_shape, torsion_l2))
    end
    return Kec
end

"""
    _compute_kec_reduction_factors(spans, joint_positions, H, Ecs, Ecc; kwargs...) -> Vector{Float64}

Kec / ΣKc at each joint, in [0, 1]. With `column_stiffness = :Kec` the ASAP
column stubs are softened by this factor to carry the torsional flexibility
that Kec captures. A fixed wall joint and `use_kc_only = true` give 1.
Keywords match [`_compute_joint_Kec`](@ref).
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
    torsion_l2 = nothing,
)
    use_kc_only && return ones(length(spans) + 1)
    k_col = pca_column_factors(H, spans[1].h).k
    return map(1:(length(spans) + 1)) do j
        _joint_is_fixed_wall(columns, j) && return 1.0
        ΣKc = _joint_ΣKc(spans, j, H, Ecc, k_col; column_shape, columns)
        ΣKt = _joint_ΣKt(spans, j, joint_positions, Ecs; column_shape, torsion_l2)
        Kc = ustrip(u"lbf*inch", ΣKc)
        Kec = ustrip(u"lbf*inch", equivalent_column_stiffness_Kec(ΣKc, ΣKt))
        return Kc > 0 ? clamp(Kec / Kc, 0.0, 1.0) : 1.0
    end
end
