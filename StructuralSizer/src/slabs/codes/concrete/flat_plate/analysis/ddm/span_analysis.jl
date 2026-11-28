# =============================================================================
# Per-Span DDM Moment Computation
# =============================================================================

"""
    _compute_ddm_span_moments(variant, qu, l2, sorted_columns, projections, column_is_exterior)

Compute DDM moments for each span using proper clear span ln.

This is the core of multi-span DDM:
- Each span gets its own M0 = qu × l2 × ln² / 8
- DDM coefficients depend on whether span is at frame end

# Arguments
- `variant`: :full or :simplified DDM
- `qu`: Factored uniform load
- `l2`: Tributary width perpendicular to span
- `sorted_columns`: Columns ordered along span axis
- `projections`: Column positions along axis (meters)
- `column_is_exterior`: Boolean for each column

# Returns
Vector of NamedTuples with (span_idx, ln, M0, M_neg_left, M_pos, M_neg_right)
"""
function _compute_ddm_span_moments(variant::Symbol, qu, l2, 
                                    sorted_columns, projections, column_is_exterior;
                                    βt::Float64 = 0.0)
    n_cols = length(sorted_columns)
    n_spans = n_cols - 1
    
    # Use feet for length type (consistent with l2 which is in ft)
    L_type = typeof(1.0u"ft")
    M_type = typeof(qu * l2 * (1.0u"ft")^2)  # Moment type (lb-ft or kip-ft)
    
    span_moments = NamedTuple{(:span_idx, :ln, :M0, :M_neg_left, :M_pos, :M_neg_right), 
                              Tuple{Int, L_type, M_type, M_type, M_type, M_type}}[]
    
    # Edge beam torsional stiffness modifies end span coefficients
    end_coeffs = if βt > 0.0
        aci_ddm_longitudinal_with_edge_beam(βt)
    else
        ACI_DDM_LONGITUDINAL.end_span
    end
    
    for span_idx in 1:n_spans
        col_left = sorted_columns[span_idx]
        col_right = sorted_columns[span_idx + 1]
        
        # Center-to-center span from projections (in meters, convert to feet for US code)
        l1_span = uconvert(u"ft", (projections[span_idx + 1] - projections[span_idx]) * u"m")
        
        # Column dimensions for clear span
        c_left = col_left.c1
        c_right = col_right.c1
        
        # Handle nil column dimensions (unsized columns → 0 width → full clear span)
        if isnothing(c_left) || isnothing(c_right)
            @warn "DDM: column dimensions not yet sized — using 0\" (clear span = full span)" span_idx c_left c_right maxlog=1
        end
        c_left_val = something(c_left, 0.0u"inch")
        c_right_val = something(c_right, 0.0u"inch")
        
        # Clear span = center-to-center - half column widths
        ln = clear_span(l1_span, (c_left_val + c_right_val) / 2)
        
        # Total static moment
        M0 = total_static_moment(qu, l2, eq13_4_clear_span(l1_span, ln))
        
        # Determine if this is an end span (either support is exterior)
        left_is_ext = column_is_exterior[span_idx]
        right_is_ext = column_is_exterior[span_idx + 1]
        is_end_span = left_is_ext || right_is_ext
        
        # DDM coefficients based on span type and method variant
        if variant == :simplified
            # Simplified DDM: same coefficients for all spans
            M_neg_left = 0.65 * M0
            M_neg_right = 0.65 * M0
            M_pos = 0.35 * M0
        else  # :full
            if is_end_span
                # End span coefficients (ACI 318-11 §13.6.3.3, edge beam via βt)
                M_neg_left = left_is_ext ? 
                    end_coeffs.ext_neg * M0 :
                    end_coeffs.int_neg * M0
                M_neg_right = right_is_ext ? 
                    end_coeffs.ext_neg * M0 :
                    end_coeffs.int_neg * M0
                M_pos = end_coeffs.pos * M0
            else
                # Interior span coefficients (unaffected by edge beam)
                M_neg_left = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
                M_neg_right = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
                M_pos = ACI_DDM_LONGITUDINAL.interior_span.pos * M0
            end
        end
        
        push!(span_moments, (
            span_idx = span_idx,
            ln = ln,
            M0 = M0,
            M_neg_left = M_neg_left,
            M_pos = M_pos,
            M_neg_right = M_neg_right
        ))
    end
    
    return span_moments
end

# =============================================================================
# DDM Moment Analysis
# =============================================================================

"""
    run_moment_analysis(method::DDM, struc, slab, columns, h, fc, Ecs, γ_concrete; verbose=false)

Run moment analysis using Direct Design Method (DDM).

DDM distributes the total static moment M₀ using code-prescribed coefficients:
- Longitudinal distribution (ACI 318-11 §13.6.3.3)
- Transverse distribution is handled separately in the shared pipeline

# DDM Coefficients (ACI 318-11 §13.6.3)

For end span with no edge beam:
- Exterior negative: 0.26 M₀
- Positive: 0.52 M₀  
- Interior negative: 0.70 M₀

For interior span:
- Negative: 0.65 M₀
- Positive: 0.35 M₀

# Simplified MDDM (variant = :simplified)

Uses constant coefficients regardless of span type:
- Negative: 0.65 M₀
- Positive: 0.35 M₀

# Arguments
- `method::DDM`: DDM method with variant (:full or :simplified)
- `struc`: BuildingStructure with cells and loads
- `slab`: Slab being designed
- `columns`: Vector of supporting columns
- `h::Length`: Slab thickness
- `fc::Pressure`: Concrete compressive strength
- `Ecs::Pressure`: Concrete modulus of elasticity
- `γ_concrete`: Concrete unit weight

# Returns
`MomentAnalysisResult` with all moments and geometry data.

# Reference
- ACI 318-11 §13.6.2–13.6.4
- StructurePoint Table 6 (DDM Moments)
"""
function run_moment_analysis(
    method::DDM,
    struc,
    slab,
    supporting_columns,
    h::Length,
    fc::Pressure,
    Ecs::Pressure,
    γ_concrete;
    ν_concrete = nothing,   # API parity (unused by DDM)
    verbose::Bool = false,
    efm_cache = nothing,    # API parity (unused by DDM)
    cache = nothing,        # API parity (unused by DDM)
    drop_panel = nothing,   # For flat slab: adjusts M0 with equivalent uniform load
    βt::Float64 = 0.0,     # Edge beam torsional stiffness ratio (ACI 318-11 §13.6.4.2)
    has_edge_beam::Bool = false,    # API parity (DDM uses βt directly)
    edge_beam_βt::Float64 = 0.0,    # API parity (DDM uses βt directly)
    col_I_factor::Float64 = 0.70,  # API parity (unused by DDM)
    tc = nothing,
    column_concrete = nothing,     # API parity (unused by DDM)
)
    # Shared setup: l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0
    setup = _moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0) = setup
    # A wall along the span and on the slab edge is the §13.6.3.3 edge beam.
    βt = βt_with_parallel_wall(βt, struc, slab, supporting_columns, span_axis)
    
    # For flat slabs with drop panels, the DDM static moment M0 must account
    # for the additional dead load from the drop panel projection.
    # Convert the localized drop panel weight to an equivalent uniform load
    # spread over the full panel area (ACI 318-11 §13.6.2.2 uses qu × l2 × ln²/8).
    q_drop = isnothing(drop_panel) ? 0.0psf : _eq137_drop_service(drop_panel, l1 * l2, γ_concrete)
    if !isnothing(drop_panel)
        # Drop-panel projection as an equivalent uniform dead load on the
        # panel.  Added to service qD so Eq. (13-7) sees it, and so qu is
        # factored by whichever of §9.2.1 Eq. (9-1) and Eq. (9-2) governs
        # (corpus: aci-318-11, page 123) — not a flat 1.2.
        qD, qu, M0 = _eq137_with_drop(qD, qL, l2, eq13_4_clear_span(l1, ln), drop_panel, l1 * l2, γ_concrete)
        if verbose
            @debug "DDM drop panel correction" qD=qD qu=qu M0=uconvert(kip*u"ft", M0)
        end
    end
    n_cols = length(supporting_columns)
    
    # DDM coefficients - determine panel type from cell positions
    # For multi-cell slabs, check if ANY cell is exterior (corner/edge) or interior
    cells = [struc.cells[idx] for idx in slab.cell_indices]
    has_exterior_cell = any(c -> c.position in [:corner, :edge], cells)
    has_interior_cell = any(c -> c.position == :interior, cells)
    
    # Apply DDM moment distribution coefficients (ACI 318-11 §13.6.3)
    # Edge beam torsional stiffness modifies end span coefficients (§13.6.3.3)
    end_coeffs = if βt > 0.0
        aci_ddm_longitudinal_with_edge_beam(βt)
    else
        ACI_DDM_LONGITUDINAL.end_span
    end
    
    if method.variant == :simplified
        # Simplified: uniform 0.65/0.35 for interior negative/positive, but exterior
        # negative MUST use the actual ACI coefficient (0.26 without edge beam).
        # Using 0.65 at exterior would inflate Mub by ~2.5×, making punching shear
        # at edge/corner columns physically unrealistic (vu >> 8√f'c stud limit).
        M_neg_ext = end_coeffs.ext_neg * M0
        M_neg_int = 0.65 * M0
        M_pos = 0.35 * M0
    else  # :full
        if has_exterior_cell && has_interior_cell
            # Mixed slab: use envelope of end span + interior span coefficients
            # This is conservative - ensures both exterior and interior columns are designed correctly
            M_neg_ext = end_coeffs.ext_neg * M0
            M_pos = end_coeffs.pos * M0
            M_neg_int = end_coeffs.int_neg * M0
        elseif has_exterior_cell
            # All exterior cells - pure end span coefficients
            M_neg_ext = end_coeffs.ext_neg * M0
            M_pos = end_coeffs.pos * M0
            M_neg_int = end_coeffs.int_neg * M0
        else
            # Pure interior slab (no exterior cells)
            M_neg_ext = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
            M_pos = ACI_DDM_LONGITUDINAL.interior_span.pos * M0
            M_neg_int = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
        end
    end
    # Column flexure keeps the column-edge coefficient. A fully restrained
    # wall raises only the slab exterior negative (§13.6.3.3 Column 5).
    M_neg_ext_column = M_neg_ext
    M_neg_ext = _slab_exterior_negative(M_neg_ext, M0, supporting_columns)

    if verbose
        variant_name = method.variant == :simplified ? "MDDM (Simplified)" : "DDM (Full ACI)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "MOMENT ANALYSIS - $variant_name"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Geometry" l1=l1 l2=l2 ln=ln h=h n_cols=n_cols
        @debug "Span axis" axis=span_axis
        @debug "Loads" qD=qD qL=qL qu=qu
        @debug "Moments" M0=uconvert(kip*u"ft", M0) M_neg_ext=uconvert(kip*u"ft", M_neg_ext) M_pos=uconvert(kip*u"ft", M_pos) M_neg_int=uconvert(kip*u"ft", M_neg_int)
    end
    
    # Build column-level results using simplified DDM.
    # Exterior unbalanced (transfer) moment = 0.3 M0 per ACI 318-11 §13.6.3.6.
    # Interior unbalanced moment per ACI 318-11 §13.6.9.2 Eq. (13-7)
    # with factored q_Du/q_Lu (corpus: aci-318-11, page 258).
    column_moments, column_shears, unbalanced_moments = _compute_column_demands_ddm(
        struc, supporting_columns, M_neg_ext_column, M_neg_int, M_pos,
        qu, qD, qL, l2, ln, span_axis, M0;
        slab = slab, γ = γ_concrete, design_drop = q_drop, tc = tc,
    )
    
    # Convert all outputs to consistent US units for MomentAnalysisResult
    # Moments in kip·ft, lengths in ft, forces in kip, pressures in psf
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
        qu, qD, qL,  # Already in psf
        uconvert(u"ft", l1),
        uconvert(u"ft", l2),
        uconvert(u"ft", ln),
        uconvert(u"ft", c1_avg),
        column_moments,  # Already in kip*ft from _compute_column_demands_from_spans
        column_shears,   # Already in kip
        unbalanced_moments,  # Already in kip*ft
        Vu_max;
        wall_transfer = _ddm_wall_transfer(struc, slab, span_axis, M0, qD, qL, l2, ln),
    )
end

"""
    _ddm_wall_transfer(struc, slab, span_axis, M0, qD, qL, l2, ln) -> Vector

Moment the slab transfers to each wall across `span_axis`, `(seg, M)`, from
the DDM coefficients scaled per unit width (`M0 / l2`) to the wall length:

- slab on one face: the slab's end moment at a fully restrained exterior
  support, ACI 318-11 §13.6.3.3 Column (5), `0.65 M0` (aci-318-11, page 254);
- slab on both faces: §13.6.9.2 Eq. (13-7) (aci-318-11, page 258) with the
  same span on both sides.

ENGINEERING JUDGMENT: §13.6.3.3 and §13.6.9.2 are written for frame strips
and columns; taking them per unit width along a wall of any length, and
using Eq. (13-7) at a wall, extends them to walls.
"""
function _ddm_wall_transfer(struc, slab, span_axis, M0, qD, qL, l2, ln)
    slab === nothing && return Any[]
    ax = _span_unit_axis(span_axis)
    ax === nothing && return Any[]
    segs = supporting_wall_segments(struc, slab)
    isempty(segs) && return Any[]
    in_slab = _slab_plan_contains(struc, slab)
    in_slab === nothing && return Any[]
    m_end = ACI_DDM_LONGITUDINAL.end_span_fully_restrained.ext_neg * M0 / l2
    m_int = governing_interior_unbalanced_moment(qD, qL, l2, ln, qD, qL, l2, ln) / l2
    out = Any[]
    for seg in segs
        _wall_parallel_to_axis(seg, ax) && continue
        L = hypot(seg[2][1] - seg[1][1], seg[2][2] - seg[1][2])
        L < 1e-3 && continue
        thick = _wall_thickness(struc, seg)
        off = (thick === nothing ? 0.0 : ustrip(u"m", thick)) / 2 + 0.05
        mid = ((seg[1][1] + seg[2][1]) / 2, (seg[1][2] + seg[2][2]) / 2)
        sides = count(dir -> in_slab((mid[1] + dir * off * ax[1], mid[2] + dir * off * ax[2])),
                      (-1.0, 1.0))
        sides == 0 && continue
        m = sides == 1 ? m_end : m_int
        push!(out, (seg = seg, M = uconvert(kip * u"ft", m * L * u"m")))
    end
    return out
end

# =============================================================================
# Secondary (Perpendicular) Direction Analysis
# =============================================================================

"""
    run_secondary_moment_analysis(method::DDM, struc, slab, columns, h, fc, Ecs, γ_concrete; kwargs...) -> MomentAnalysisResult

Run DDM in the perpendicular direction (swapped l1↔l2).

Returns a full `MomentAnalysisResult` for consistency with the primary direction.
This is essentially free — pure arithmetic with swapped geometry.
"""
function run_secondary_moment_analysis(
    method::DDM,
    struc, slab, supporting_columns, h::Length,
    fc::Pressure, Ecs::Pressure, γ_concrete;
    verbose::Bool = false,
    drop_panel = nothing,
    βt::Float64 = 0.0,
    tc = nothing,
    kwargs...
)
    # Secondary setup: l1↔l2 swapped, perpendicular span axis, c2 for clear span
    setup = _secondary_moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0) = setup
    βt = βt_with_parallel_wall(βt, struc, slab, supporting_columns, span_axis)

    # Same drop-panel dead load as the primary direction, factored per
    # combination inside `_eq137_with_drop` and carried in qD for Eq. (13-7).
    q_drop = isnothing(drop_panel) ? 0.0psf : _eq137_drop_service(drop_panel, l1 * l2, γ_concrete)
    if !isnothing(drop_panel)
        qD, qu, M0 = _eq137_with_drop(qD, qL, l2, eq13_4_clear_span(l1, ln), drop_panel, l1 * l2, γ_concrete)
    end

    # Reuse DDM coefficient logic (same code, just operating on swapped geometry)
    cells = [struc.cells[idx] for idx in slab.cell_indices]
    has_exterior_cell = any(c -> c.position in [:corner, :edge], cells)
    has_interior_cell = any(c -> c.position == :interior, cells)

    end_coeffs = βt > 0.0 ? aci_ddm_longitudinal_with_edge_beam(βt) : ACI_DDM_LONGITUDINAL.end_span

    if method.variant == :simplified
        M_neg_ext = end_coeffs.ext_neg * M0
        M_neg_int = 0.65 * M0
        M_pos = 0.35 * M0
    else
        if has_exterior_cell && has_interior_cell
            M_neg_ext = end_coeffs.ext_neg * M0
            M_pos = end_coeffs.pos * M0
            M_neg_int = end_coeffs.int_neg * M0
        elseif has_exterior_cell
            M_neg_ext = end_coeffs.ext_neg * M0
            M_pos = end_coeffs.pos * M0
            M_neg_int = end_coeffs.int_neg * M0
        else
            M_neg_ext = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
            M_pos = ACI_DDM_LONGITUDINAL.interior_span.pos * M0
            M_neg_int = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
        end
    end
    M_neg_ext_column = M_neg_ext
    M_neg_ext = _slab_exterior_negative(M_neg_ext, M0, supporting_columns)
    wall_transfer = _ddm_wall_transfer(struc, slab, span_axis, M0, qD, qL, l2, ln)

    # Column demands in the perpendicular direction.  `span_axis` is already
    # rotated, so Eq. (13-7) sees the panels on each side of that axis
    # (ACI 318-11 §13.6.9.2, corpus: aci-318-11, page 258).
    column_moments, column_shears, unbalanced_moments = _compute_column_demands_ddm(
        struc, supporting_columns, M_neg_ext_column, M_neg_int, M_pos,
        qu, qD, qL, l2, ln, span_axis, M0;
        slab = slab, γ = γ_concrete, design_drop = q_drop, tc = tc,
    )

    if verbose
        @debug "DDM SECONDARY DIRECTION" l1=l1 l2=l2 ln=ln M0=uconvert(kip*u"ft", M0)
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
        pattern_loading = false,  # DDM doesn't use pattern loading
        wall_transfer = wall_transfer,
    )
end

"""
Slab exterior negative moment, raised when a support is a full-edge wall.

ACI 318-11 §13.6.3.3 Column (5) (aci-318-11, page 254) gives that end
0.65M0. The column keeps the moment from the column-edge coefficients.
A support that is not a wall leaves `M_neg_ext` unchanged.
"""
function _slab_exterior_negative(M_neg_ext, M0, supporting_columns)
    any(_support_is_wall_fixed, supporting_columns) || return M_neg_ext
    return ACI_DDM_LONGITUDINAL.end_span_fully_restrained.ext_neg * M0
end

