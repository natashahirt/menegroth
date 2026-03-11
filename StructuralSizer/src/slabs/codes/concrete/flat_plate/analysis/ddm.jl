# =============================================================================
# Direct Design Method (DDM) - ACI 318-11 §13.6
# =============================================================================
#
# Moment analysis using code-prescribed coefficients.
#
# Reference:
# - ACI 318-11 §13.6
# - ACI 318-11 §13.6.3 (longitudinal), §13.6.4 (transverse)
# - StructurePoint DE-Two-Way-Flat-Plate Section 3.1
#
# =============================================================================

using Logging

# =============================================================================
# Column Classification Helpers
# =============================================================================

"""
    is_exterior_support(col, span_axis::NTuple{2, Float64}) -> Bool

Determine if a column is an exterior support for spans in the given direction.

A column is an exterior support if it has a boundary edge perpendicular to the span axis,
meaning the slab does not continue beyond it in the span direction.

Requires `col.boundary_edge_dirs` field (from StructuralSynthesizer). Falls back to
position-based classification if boundary_edge_dirs is not available.
"""
function is_exterior_support(col, span_axis::NTuple{2, Float64})::Bool
    # Check if column has boundary edge directions (from StructuralSynthesizer)
    dirs = col_boundary_edge_dirs(col)
    if !isempty(dirs)
        # Normalize span axis
        ax_len = hypot(span_axis...)
        ax_len < 1e-9 && return false
        ax = (span_axis[1]/ax_len, span_axis[2]/ax_len)
        
        # Check if any boundary edge is perpendicular to span axis
        for dir in dirs
            dot_product = abs(ax[1]*dir[1] + ax[2]*dir[2])
            if dot_product < 0.3  # Edge is roughly perpendicular to span
                return true
            end
        end
        return false
    else
        # Fallback: use position field (less accurate for edge columns)
        # Corner columns are exterior for all directions
        # Edge columns may or may not be exterior (conservative: assume exterior)
        return col.position != :interior
    end
end

"""Convenience overload: convert a direction symbol (`:x` or `:y`) to a unit vector."""
is_exterior_support(col, span_direction::Symbol)::Bool = 
    is_exterior_support(col, span_direction == :x ? (1.0, 0.0) : (0.0, 1.0))

"""
Get the span axis direction from slab spans.
"""
function _get_span_axis(slab)::NTuple{2, Float64}
    if hasproperty(slab, :spans) && hasproperty(slab.spans, :axis)
        ax = slab.spans.axis
        len = hypot(ax[1], ax[2])
        return len > 1e-9 ? (ax[1]/len, ax[2]/len) : (1.0, 0.0)
    end
    return (1.0, 0.0)  # Default to X direction
end

# =============================================================================
# Column Ordering for Multi-Span Analysis
# =============================================================================

"""
    _get_column_xy(struc, col) -> NTuple{2, Float64}

Get XY position of column in meters from skeleton vertex.

Uses `col.vertex_idx` to look up position in `struc.skeleton.vertices`.
"""
function _get_column_xy(struc, col)::NTuple{2, Float64}
    vidx = col_vertex_idx(col)
    if vidx > 0
        vc = struc.skeleton.geometry.vertex_coords
        return (vc[vidx, 1], vc[vidx, 2])
    else
        error("Column missing vertex_idx - cannot determine position for ordering")
    end
end

"""
    _order_columns_along_axis(struc, columns, span_axis) -> (sorted_columns, projections)

Order columns by their projection onto the span axis.

# Arguments
- `struc`: BuildingStructure with skeleton for position lookup
- `columns`: Vector of columns to sort
- `span_axis`: Direction vector (normalized) for sorting

# Returns
- `sorted_columns`: Columns ordered along the span axis
- `projections`: Position of each sorted column along axis (in meters)
"""
function _order_columns_along_axis(struc, columns, span_axis::NTuple{2, Float64})
    # Normalize axis
    ax_len = hypot(span_axis...)
    ax = ax_len > 1e-9 ? (span_axis[1]/ax_len, span_axis[2]/ax_len) : (1.0, 0.0)
    
    # Project each column onto axis
    projections = map(columns) do col
        pos = _get_column_xy(struc, col)
        pos[1] * ax[1] + pos[2] * ax[2]
    end
    
    # Sort by projection
    perm = sortperm(projections)
    return columns[perm], projections[perm]
end

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
        M0 = total_static_moment(qu, l2, ln)
        
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
                # End span coefficients (ACI Table 8.10.4.2, edge beam via βt)
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
- Longitudinal distribution (ACI Table 8.10.4.2)
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
    βt::Float64 = 0.0,     # Edge beam torsional stiffness ratio (ACI 8.10.5.2)
    col_I_factor::Float64 = 0.70,  # API parity (unused by DDM)
)
    # Shared setup: l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0
    setup = _moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0) = setup
    
    # For flat slabs with drop panels, the DDM static moment M0 must account
    # for the additional dead load from the drop panel projection.
    # Convert the localized drop panel weight to an equivalent uniform load
    # spread over the full panel area (ACI 8.10.3.2 uses qu × l2 × ln²/8).
    if !isnothing(drop_panel)
        # Drop panel weight per unit area (projection only)
        w_drop = uconvert(psf, drop_panel.h_drop * γ_concrete * GRAVITY)
        # Drop panel plan area: 2×a_drop_1 × 2×a_drop_2
        A_drop = drop_extent_1(drop_panel) * drop_extent_2(drop_panel)
        # Panel area: l1 × l2
        A_panel = l1 * l2
        # Equivalent uniform load: spread drop panel weight over full panel
        # Convert areas to common units before dividing so the ratio is truly
        # dimensionless and qu stays in psf (DropPanelGeometry stores meters,
        # while l1/l2 are in ft from _moment_analysis_setup).
        A_drop_ft2 = uconvert(u"ft^2", A_drop)
        qu_drop_equiv = 1.2 * w_drop * (A_drop_ft2 / A_panel)  # factored (DL only)
        qu = uconvert(psf, qu + qu_drop_equiv)
        M0 = total_static_moment(qu, l2, ln)
        
        if verbose
            @debug "DDM drop panel correction" w_drop=w_drop A_drop=A_drop A_panel=A_panel qu_drop_equiv=qu_drop_equiv qu_total=qu M0_corrected=uconvert(kip*u"ft", M0)
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
    
    # Build column-level results using simplified DDM
    # For flat plates, unbalanced moment at exterior supports = M_neg_ext
    # For interior supports = difference between adjacent panel moments (zero for uniform load)
    column_moments, column_shears, unbalanced_moments = _compute_column_demands_ddm(
        struc, supporting_columns, M_neg_ext, M_neg_int, M_pos, qu, l2, ln, span_axis
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
        Vu_max
    )
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
    kwargs...
)
    # Secondary setup: l1↔l2 swapped, perpendicular span axis, c2 for clear span
    setup = _secondary_moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0) = setup

    # Drop panel correction for secondary direction (same logic, swapped extents)
    if !isnothing(drop_panel)
        w_drop = uconvert(psf, drop_panel.h_drop * γ_concrete * GRAVITY)
        A_drop = drop_extent_1(drop_panel) * drop_extent_2(drop_panel)
        A_panel = l1 * l2
        A_drop_ft2 = uconvert(u"ft^2", A_drop)
        qu_drop_equiv = 1.2 * w_drop * (A_drop_ft2 / A_panel)
        qu = uconvert(psf, qu + qu_drop_equiv)
        M0 = total_static_moment(qu, l2, ln)
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

    # Column demands in secondary direction (uses perpendicular span_axis)
    column_moments, column_shears, unbalanced_moments = _compute_column_demands_ddm(
        struc, supporting_columns, M_neg_ext, M_neg_int, M_pos, qu, l2, ln, span_axis
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
    )
end

# =============================================================================
# Column Demands from Per-Span Moments
# =============================================================================

"""
    _compute_column_demands_ddm(struc, columns, M_neg_ext, M_neg_int, M_pos, qu, l2, ln, span_axis)

Compute column-level demands for simplified DDM (single panel approach).

For each column:
- Exterior columns: use M_neg_ext as design moment and unbalanced moment
- Interior columns: use M_neg_int as design moment, Mub = 0 for uniform loading
- Shear from tributary area (preferred) or span-based fallback
"""
function _compute_column_demands_ddm(struc, columns, M_neg_ext, M_neg_int, M_pos, qu, l2, ln, span_axis)
    column_moments = Vector{typeof(1.0kip*u"ft")}()
    column_shears = Vector{typeof(1.0kip)}()
    unbalanced_moments = Vector{typeof(1.0kip*u"ft")}()
    
    for col in columns
        # Classify column as exterior or interior for this span direction
        is_ext = is_exterior_support(col, span_axis)
        
        # Design moment based on position
        M = is_ext ? M_neg_ext : M_neg_int
        
        # Unbalanced moment for punching shear
        # For exterior: use design moment
        # For interior with uniform loading: ~0 (symmetric)
        Mub = is_ext ? M : 0.0 * M
        
        push!(column_moments, uconvert(kip*u"ft", M))
        push!(unbalanced_moments, uconvert(kip*u"ft", Mub))
        
        # Shear: prefer tributary area, fallback to span-based
        Vu = _compute_column_shear(struc, col, qu, l2, ln)
        push!(column_shears, Vu)
    end
    
    return column_moments, column_shears, unbalanced_moments
end

"""
    _compute_column_demands_from_spans(struc, sorted_columns, column_is_exterior, span_moments, qu, l2)

Compute column-level demands from per-span DDM moments (legacy multi-span version).

For each column:
- Design moment = max of moments from adjacent spans at this support
- Unbalanced moment = |M_left_span - M_right_span| at interior supports
- Shear from tributary area or span-based fallback

# Arguments
- `struc`: BuildingStructure (for tributary area lookup)
- `sorted_columns`: Columns ordered along span axis
- `column_is_exterior`: Boolean for each column
- `span_moments`: Vector of per-span moment results
- `qu`: Factored uniform load
- `l2`: Tributary width
"""
function _compute_column_demands_from_spans(struc, sorted_columns, column_is_exterior, 
                                             span_moments, qu, l2)
    n_cols = length(sorted_columns)
    column_moments = Vector{typeof(1.0kip*u"ft")}()
    column_shears = Vector{typeof(1.0kip)}()
    unbalanced_moments = Vector{typeof(1.0kip*u"ft")}()
    
    for (i, col) in enumerate(sorted_columns)
        # Get moment from adjacent spans
        if i == 1
            # First column - use left moment of first span
            M = span_moments[1].M_neg_left
            Mub = M  # Unbalanced at exterior (full moment)
            ln_for_shear = span_moments[1].ln
        elseif i == n_cols
            # Last column - use right moment of last span
            M = span_moments[end].M_neg_right
            Mub = M  # Unbalanced at exterior (full moment)
            ln_for_shear = span_moments[end].ln
        else
            # Interior column - max of adjacent spans' moments at this support
            # span_moments[i-1] is the span to the LEFT of column i
            # span_moments[i] is the span to the RIGHT of column i
            M_from_left_span = span_moments[i-1].M_neg_right
            M_from_right_span = span_moments[i].M_neg_left
            M = max(M_from_left_span, M_from_right_span)
            
            # Unbalanced = difference of moments from adjacent spans
            Mub = abs(M_from_left_span - M_from_right_span)
            
            # Average ln for shear calculation
            ln_for_shear = (span_moments[i-1].ln + span_moments[i].ln) / 2
        end
        
        push!(column_moments, M)
        
        # Shear: prefer tributary area, else use span-based fallback
        Vu = _compute_column_shear(struc, col, qu, l2, ln_for_shear)
        push!(column_shears, Vu)
        push!(unbalanced_moments, abs(Mub))
    end
    
    return column_moments, column_shears, unbalanced_moments
end

# _compute_column_shear is defined in common.jl (shared between DDM and EFM)

# =============================================================================
# DDM Applicability Check - ACI 318-11 §13.6.1
# =============================================================================

"""
    DDMApplicabilityError <: Exception

Error thrown when DDM is not applicable for the given geometry/loading.

# Fields
- `violations`: List of ACI 318 §8.10.2 conditions that are violated
- `alternatives`: List of alternative methods that ARE valid for this geometry
"""
struct DDMApplicabilityError <: Exception
    violations::Vector{String}
    alternatives::Vector{String}
end

"""Construct a `DDMApplicabilityError` with an empty alternatives list."""
DDMApplicabilityError(violations::Vector{String}) = DDMApplicabilityError(violations, String[])

"""Print a human-readable error listing violated ACI 318-11 §13.6.1 conditions and suggested alternatives."""
function Base.showerror(io::IO, e::DDMApplicabilityError)
    println(io, "DDM (Direct Design Method) is not permitted for this slab per ACI 318-11 §13.6.1:")
    for (i, v) in enumerate(e.violations)
        println(io, "  $i. $v")
    end
    
    if !isempty(e.alternatives)
        println(io, "\nConsider using one of the following methods instead:")
        for alt in e.alternatives
            println(io, "  • $alt")
        end
    else
        # FEA is always valid as the most general method
        println(io, "\nConsider using FEA (Finite Element Analysis) instead, which has no geometric restrictions.")
    end
end

"""
    check_ddm_applicability(struc, slab, columns; throw_on_failure=true)

Check if DDM is applicable per ACI 318-11 §13.6.1.

# ACI 318-11 §13.6.1 Limitations (DDM shall be permitted only when):

1. **§8.10.2.1** - At least 3 continuous spans in each direction
2. **§8.10.2.2** - Panels are rectangular with l₂/l₁ ≤ 2.0
3. **§8.10.2.3** - Successive span lengths differ by ≤ 1/3 of longer span
4. **§8.10.2.4** - Columns are not offset > 10% of span from column lines
5. **§8.10.2.5** - All loads are due to gravity only, uniformly distributed
6. **§8.10.2.6** - Unfactored L ≤ 2 × unfactored D (L/D ≤ 2.0)
7. **§8.10.2.7** - For slabs with beams: 0.2 ≤ αf×l₂/l₁ ≤ 5.0

# Arguments
- `struc`: BuildingStructure (for building-level span information)
- `slab`: Slab being designed
- `columns`: Vector of supporting columns
- `throw_on_failure`: If true, throw DDMApplicabilityError; if false, return result

# Returns
Named tuple with:
- `ok::Bool`: true if DDM is applicable
- `violations::Vector{String}`: list of violated conditions with code references

# Throws
`DDMApplicabilityError` if any condition is violated and `throw_on_failure=true`
"""
function check_ddm_applicability(struc, slab, columns; throw_on_failure::Bool = true, ρ_concrete::Density = NWC_4000.ρ)
    violations = String[]
    
    l1 = slab.spans.primary
    l2 = slab.spans.secondary
    
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
    # §8.10.2.2 - Panels must be rectangular
    # -------------------------------------------------------------------------
    # Verify valid rectangular geometry (positive orthogonal spans)
    zero_len = 0.0 * unit(l1)
    
    if l1 <= zero_len || l2 <= zero_len
        push!(violations, "§8.10.2.2: Panel must be rectangular; invalid span dimensions l₁=$(l1), l₂=$(l2)")
    end
    
    # Check if slab has non-rectangular geometry flag (if available)
    if hasproperty(slab, :is_rectangular) && !slab.is_rectangular
        push!(violations, "§8.10.2.2: Panel must be rectangular; slab geometry is irregular (L-shaped, triangular, or non-orthogonal)")
    end
    
    # -------------------------------------------------------------------------
    # §8.10.2.2 - Panel aspect ratio: l₂/l₁ ≤ 2.0
    # -------------------------------------------------------------------------
    if l1 > zero_len && l2 > zero_len
        ratio = l2 / l1  # dimensionless
        if ratio > 2.0
            push!(violations, "§8.10.2.2: Panel aspect ratio l₂/l₁ = $(round(ratio, digits=2)) > 2.0")
        elseif ratio < 0.5
            push!(violations, "§8.10.2.2: Panel aspect ratio l₂/l₁ = $(round(ratio, digits=2)) < 0.5 (inverse > 2.0)")
        end
    end
    
    # -------------------------------------------------------------------------
    # §8.10.2.6 - Load ratio: L/D ≤ 2.0
    # -------------------------------------------------------------------------
    # D = SDL + self-weight. At this point we don't have the final slab thickness,
    # so we estimate self-weight using the minimum thickness for the longest span.
    # This gives a conservative (lower) estimate of D, making L/D appear higher.
    cell = struc.cells[first(slab.cell_indices)]
    qL = cell.live_load
    
    # Estimate self-weight from ACI minimum thickness (Table 8.3.1.1)
    γ_concrete = ρ_concrete * GRAVITY
    ln_max = max(l1, l2)
    h_min_estimate = min_thickness(FlatPlate(), ln_max)
    sw_estimate = uconvert(psf, h_min_estimate * γ_concrete)
    
    qD = cell.sdl + sw_estimate  # Include self-weight estimate
    
    if !iszero(qD)
        LD_ratio = ustrip(psf, qL) / ustrip(psf, qD)
        if LD_ratio > 2.0
            push!(violations, "§8.10.2.6: Live/Dead ratio L/D = $(round(LD_ratio, digits=2)) > 2.0 (using estimated h_min for self-weight)")
        end
    end
    
    # -------------------------------------------------------------------------
    # §8.10.2.1 - Minimum 3 continuous spans in each direction
    # -------------------------------------------------------------------------
    # Full check: count columns along the span axis.  n_cols ≥ 4 implies ≥ 3 spans.
    # Partial check: n_cols ≥ 2 needed for any analysis; < 4 triggers a warning.
    n_cols = length(columns)
    if n_cols < 2
        push!(violations, "§8.10.2.1: DDM requires at least 3 continuous spans; only $(n_cols) columns found (need ≥ 4 column lines)")
    elseif n_cols < 4
        # Not a hard violation — the slab may be part of a larger building.
        # But flag it as a potential issue.
        push!(violations, "§8.10.2.1: DDM requires ≥ 3 continuous spans; only $(n_cols) columns found for this slab. Verify that the building has ≥ 3 spans in each direction.")
    end
    
    # -------------------------------------------------------------------------
    # §8.10.2.3 - Successive span lengths differ by ≤ 1/3 of longer span
    # -------------------------------------------------------------------------
    # Check adjacent panel spans if building-level info is available.
    # We can query adjacent slabs from struc to find neighboring spans.
    if hasproperty(slab, :adjacent_slabs) && !isnothing(slab.adjacent_slabs)
        for adj_idx in slab.adjacent_slabs
            adj_slab = struc.slabs[adj_idx]
            l1_adj = adj_slab.spans.primary
            l_longer = max(l1, l1_adj)
            l_diff = abs(l1 - l1_adj)
            if l_diff > l_longer / 3
                push!(violations, "§8.10.2.3: Successive span variation |$(round(ustrip(u"ft", l1), digits=1))' − $(round(ustrip(u"ft", l1_adj), digits=1))'| = $(round(ustrip(u"ft", l_diff), digits=1))' > $(round(ustrip(u"ft", l_longer/3), digits=1))' (l_longer/3)")
            end
        end
    end
    # Note: if adjacent_slabs info is not available, this check is skipped.
    # EFM or FEA should be used when span regularity is uncertain.
    
    # -------------------------------------------------------------------------
    # §8.10.2.4 - Column offset ≤ 10% of span from column lines
    # -------------------------------------------------------------------------
    # A "column line" is a row of columns sharing roughly the same
    # perpendicular coordinate.  We cluster columns into lines first,
    # then check each column's offset from its own line's mean.
    # The previous implementation compared every column to the global
    # mean, which falsely flagged regular grids (columns on different
    # grid lines all appeared "offset" from the centroid).
    if length(columns) >= 2 && all(col_vertex_idx(col) > 0 for col in columns)
        try
            span_axis = _get_span_axis(slab)
            perp_axis = (-span_axis[2], span_axis[1])  # 90° rotation
            l1_m = ustrip(u"m", l1)
            
            # Project each column onto the perpendicular axis
            perp_projs = map(columns) do col
                pos = _get_column_xy(struc, col)
                pos[1] * perp_axis[1] + pos[2] * perp_axis[2]
            end
            
            # Cluster columns into column lines: group by perpendicular
            # projection within a tolerance of 10% of span (the violation
            # threshold itself).  Columns closer than this are on the
            # same column line.
            cluster_tol = 0.10 * l1_m
            assigned = falses(length(columns))
            line_groups = Vector{Vector{Int}}()  # each group = indices into columns
            
            sorted_order = sortperm(perp_projs)
            for idx in sorted_order
                assigned[idx] && continue
                # Start a new column line
                group = [idx]
                assigned[idx] = true
                for jdx in sorted_order
                    assigned[jdx] && continue
                    if abs(perp_projs[jdx] - perp_projs[idx]) <= cluster_tol
                        push!(group, jdx)
                        assigned[jdx] = true
                    end
                end
                push!(line_groups, group)
            end
            
            # Check each column's offset from its own line's mean
            for group in line_groups
                line_mean = sum(perp_projs[i] for i in group) / length(group)
                for i in group
                    offset_m = abs(perp_projs[i] - line_mean)
                    if offset_m > cluster_tol
                        push!(violations, "§8.10.2.4: Column $(i) offset $(round(offset_m, digits=2))m from column line > 10% of span ($(round(cluster_tol, digits=2))m)")
                    end
                end
            end
        catch e
            @warn "DDM §8.10.2.4: column offset check skipped — coordinate lookup failed" exception=(e, catch_backtrace())
        end
    end
    
    # -------------------------------------------------------------------------
    # §8.10.2.5 - Gravity loads only, uniformly distributed
    # -------------------------------------------------------------------------
    # We assume this is satisfied since our load model is uniform
    # Lateral loads would be handled by a separate system
    
    # -------------------------------------------------------------------------
    # §8.10.2.7 - Beam stiffness ratio (for slabs with beams)
    # -------------------------------------------------------------------------
    # For flat plates (no beams), αf = 0, so this doesn't apply
    # This check would be added for two-way slabs with beams
    
    ok = isempty(violations)
    
    if !ok && throw_on_failure
        # Compute valid alternatives
        alternatives = _compute_ddm_alternatives(struc, slab, columns)
        throw(DDMApplicabilityError(violations, alternatives))
    end
    
    return (ok=ok, violations=violations)
end

"""
Compute list of alternative methods that ARE valid for this geometry.
FEA is always valid (most general). EFM is checked for applicability.
"""
function _compute_ddm_alternatives(struc, slab, columns)
    alternatives = String[]
    
    # Check if EFM is valid (import check function from efm.jl)
    # Note: check_efm_applicability is defined in efm.jl which is included after ddm.jl
    # We use a try-catch to handle the case where EFM check might fail
    try
        efm_result = check_efm_applicability(struc, slab, columns; throw_on_failure=false)
        if efm_result.ok
            push!(alternatives, "EFM (Equivalent Frame Method): method=EFM() — fewer geometric restrictions than DDM")
        end
    catch e
        @warn "DDM: EFM applicability check failed — cannot suggest EFM as alternative" exception=(e, catch_backtrace())
    end
    
    # FEA is always valid - it's the most general method with no geometric restrictions
    push!(alternatives, "FEA (Finite Element Analysis): method=FEA() — no geometric restrictions, handles any layout")
    
    return alternatives
end

"""
    enforce_ddm_applicability(struc, slab, columns)

Enforce DDM applicability, throwing an error if not permitted.
This is called automatically by `run_moment_analysis(::DDM, ...)`.
"""
function enforce_ddm_applicability(struc, slab, columns; ρ_concrete::Density = NWC_4000.ρ)
    check_ddm_applicability(struc, slab, columns; throw_on_failure=true, ρ_concrete=ρ_concrete)
end

# =============================================================================
# FrameLine-Based DDM Analysis
# =============================================================================

"""
    run_moment_analysis(method::DDM, frame_line::FrameLine, struc, qu, qD, qL; verbose=false)

Run DDM moment analysis using a FrameLine (multi-span frame strip).

This overload accepts a pre-built FrameLine which already has:
- Columns sorted along the frame direction
- Clear span lengths computed
- Joint positions (exterior/interior) determined

# Arguments
- `method::DDM`: DDM method with variant (:full or :simplified)
- `frame_line::FrameLine`: Pre-built frame strip with columns and spans
- `struc`: BuildingStructure (for tributary area lookup)
- `qu::Pressure`: Factored uniform load (1.2D + 1.6L)
- `qD::Pressure`: Service dead load
- `qL::Pressure`: Service live load

# Returns
`MomentAnalysisResult` with all moments and geometry data.

# Example
```julia
# Build frame line from columns
fl = FrameLine(:x, columns, l2, get_pos, get_width)

# Run DDM analysis
result = run_moment_analysis(DDM(), fl, struc, qu, qD, qL)
```
"""
function run_moment_analysis(
    method::DDM,
    frame_line,  # FrameLine{T, C}
    struc,
    qu::Pressure,
    qD::Pressure,
    qL::Pressure;
    verbose::Bool = false,
    βt::Float64 = 0.0
)
    # Extract from FrameLine
    sorted_columns = frame_line.columns
    l2 = frame_line.tributary_width
    n_spans = length(frame_line.span_lengths)
    n_cols = n_spans + 1
    
    # Build column_is_exterior from joint_positions
    column_is_exterior = [pos == :exterior for pos in frame_line.joint_positions]
    
    # Total static moment type for creating vector
    M_type = typeof(qu * l2 * (1.0u"m")^2)
    L_type = typeof(1.0u"m")
    
    span_moments = NamedTuple{(:span_idx, :ln, :M0, :M_neg_left, :M_pos, :M_neg_right), 
                              Tuple{Int, L_type, M_type, M_type, M_type, M_type}}[]
    
    for span_idx in 1:n_spans
        # Clear span from FrameLine
        ln = frame_line.span_lengths[span_idx]
        
        # Total static moment for this span
        M0 = total_static_moment(qu, l2, ln)
        
        # Determine if this is an end span
        left_is_ext = column_is_exterior[span_idx]
        right_is_ext = column_is_exterior[span_idx + 1]
        is_end_span = left_is_ext || right_is_ext
        
        # DDM coefficients based on span type and method variant
        # Edge beam torsional stiffness modifies end span coefficients
        end_coeffs_fl = if βt > 0.0
            aci_ddm_longitudinal_with_edge_beam(βt)
        else
            ACI_DDM_LONGITUDINAL.end_span
        end
        
        if method.variant == :simplified
            # Simplified DDM: same coefficients for all spans
            M_neg_left = 0.65 * M0
            M_neg_right = 0.65 * M0
            M_pos = 0.35 * M0
        else  # :full
            if is_end_span
                # End span coefficients (ACI Table 8.10.4.2, edge beam via βt)
                M_neg_left = left_is_ext ? 
                    end_coeffs_fl.ext_neg * M0 :
                    end_coeffs_fl.int_neg * M0
                M_neg_right = right_is_ext ? 
                    end_coeffs_fl.ext_neg * M0 :
                    end_coeffs_fl.int_neg * M0
                M_pos = end_coeffs_fl.pos * M0
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
    
    if verbose
        variant_name = method.variant == :simplified ? "MDDM (Simplified)" : "DDM (Full ACI)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "MOMENT ANALYSIS - $variant_name (FrameLine)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Frame direction" dir=frame_line.direction n_spans=n_spans l2=l2
        @debug "Loads" qD=qD qL=qL qu=qu
        @debug "Per-span moments:"
        for sm in span_moments
            ln_ft = round(ustrip(u"ft", sm.ln), digits=2)
            M0_kipft = round(ustrip(kip*u"ft", sm.M0), digits=1)
            @debug "  Span $(sm.span_idx): ln=$(ln_ft) ft, M0=$(M0_kipft) kip-ft"
        end
    end
    
    # Build column-level results
    column_moments, column_shears, unbalanced_moments = _compute_column_demands_from_spans(
        struc, sorted_columns, column_is_exterior, span_moments, qu, l2
    )
    
    # Use first span values for aggregate/representative fields
    ln = span_moments[1].ln
    l1 = ln + sum(c.c1 for c in sorted_columns) / n_cols  # Approx center-to-center
    M0 = span_moments[1].M0
    M_neg_ext = span_moments[1].M_neg_left
    M_neg_int = span_moments[1].M_neg_right
    M_pos = span_moments[1].M_pos
    
    c1_avg = sum(c.c1 for c in sorted_columns) / n_cols
    
    # Convert to consistent units for MomentAnalysisResult
    # The type system requires homogeneous Moment and Force vectors
    M0_kft = uconvert(kip*u"ft", M0)
    M_neg_ext_kft = uconvert(kip*u"ft", M_neg_ext)
    M_neg_int_kft = uconvert(kip*u"ft", M_neg_int)
    M_pos_kft = uconvert(kip*u"ft", M_pos)
    
    Vu_max = uconvert(kip, qu * l2 * ln / 2)
    
    return MomentAnalysisResult(
        M0_kft,
        M_neg_ext_kft,
        M_neg_int_kft,
        M_pos_kft,
        qu, qD, qL,
        l1, l2, ln, c1_avg,
        column_moments,
        column_shears,
        unbalanced_moments,
        Vu_max
    )
end

