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

Get XY position of column's **structural centerline** in meters.

Applies `structural_offset` (edge/corner columns shifted inward) when available.
Falls back to the raw vertex position for lightweight stubs without the offset field.
"""
function _get_column_xy(struc, col)::NTuple{2, Float64}
    vidx = col_vertex_idx(col)
    if vidx > 0
        vc = struc.skeleton.geometry.vertex_coords
        xy = (vc[vidx, 1], vc[vidx, 2])
        off = hasproperty(col, :structural_offset) ? col.structural_offset : (0.0, 0.0)
        return (xy[1] + off[1], xy[2] + off[2])
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
    has_edge_beam::Bool = false,    # API parity (DDM uses βt directly)
    edge_beam_βt::Float64 = 0.0,    # API parity (DDM uses βt directly)
    col_I_factor::Float64 = 0.70,  # API parity (unused by DDM)
    tc = nothing,
)
    # Shared setup: l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0
    setup = _moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0) = setup
    
    # For flat slabs with drop panels, the DDM static moment M0 must account
    # for the additional dead load from the drop panel projection.
    # Convert the localized drop panel weight to an equivalent uniform load
    # spread over the full panel area (ACI 8.10.3.2 uses qu × l2 × ln²/8).
    q_drop = isnothing(drop_panel) ? 0.0psf : _eq137_drop_service(drop_panel, l1 * l2, γ_concrete)
    if !isnothing(drop_panel)
        # Drop-panel projection as an equivalent uniform dead load on the
        # panel.  Added to service qD so Eq. (13-7) sees it, and so qu is
        # factored by whichever of §9.2.1 Eq. (9-1) and Eq. (9-2) governs
        # (corpus: aci-318-11, page 123) — not a flat 1.2.
        qD, qu, M0 = _eq137_with_drop(qD, qL, l2, ln, drop_panel, l1 * l2, γ_concrete)
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
        struc, supporting_columns, M_neg_ext, M_neg_int, M_pos,
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
    tc = nothing,
    kwargs...
)
    # Secondary setup: l1↔l2 swapped, perpendicular span axis, c2 for clear span
    setup = _secondary_moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0) = setup

    # Same drop-panel dead load as the primary direction, factored per
    # combination inside `_eq137_with_drop` and carried in qD for Eq. (13-7).
    q_drop = isnothing(drop_panel) ? 0.0psf : _eq137_drop_service(drop_panel, l1 * l2, γ_concrete)
    if !isnothing(drop_panel)
        qD, qu, M0 = _eq137_with_drop(qD, qL, l2, ln, drop_panel, l1 * l2, γ_concrete)
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

    # Column demands in the perpendicular direction.  `span_axis` is already
    # rotated, so Eq. (13-7) sees the panels on each side of that axis
    # (ACI 318-11 §13.6.9.2, corpus: aci-318-11, page 258).
    column_moments, column_shears, unbalanced_moments = _compute_column_demands_ddm(
        struc, supporting_columns, M_neg_ext, M_neg_int, M_pos,
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
    )
end

# =============================================================================
# Column Demands from Per-Span Moments
# =============================================================================

# =============================================================================
# Eq. (13-7) adjoining spans — ACI 318-11 §13.6.9.2
# =============================================================================
#
# Spans come from the column layout, not from slab-face corners: faces are
# mesh pieces, not panels.  The far support is the nearest column on the
# frame line that the slab is shown to reach (`_eq137_far_support`).  ℓ_cc
# is the distance between structural centerlines of the two columns (vertex
# plus `structural_offset`).  ℓn is face to face along that same line
# (ACI 318-11 §13.6.2.5, corpus: aci-318-11, page 253).  ℓ2 is the sum of
# transverse widths to the panel centerlines, fixed by the adjacent column
# lines and measured from the architectural frame line (the vertex line),
# not from the structural center (§13.6.2.1, §13.6.2.3, §13.6.2.4, page 253;
# `_eq137_side_width`).  The Eq. (13-7) terms are the line loads Σ q·ℓ2.

# ENGINEERING JUDGMENT: a face that overlaps another same-storey face (not
# a piece of one tessellation of the slab) and whose centroid lies this
# close to the column line normal to the analysis direction is a
# perpendicular neighbour and does not enter the Eq. (13-7) widths
# (`_eq137_side_width`).  Floor 0.05 m, or 2% of the centroid distance.  A
# face of a proper tessellation always enters, clipped to the span, however
# close its centroid is to that line.
const _EQ137_PERP_ALONG_MIN_M = 0.05
const _EQ137_PERP_ALONG_FRAC = 0.02

# One on-line predicate (`_eq137_on_line`).  A vertex is on this frame line
# when its perpendicular distance is at most
# max(0.35 m, 10% of its along-axis distance from the column).
#
# The 10% is ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252): "Offset of
# columns by a maximum of 10 percent of the span (in direction of offset)
# from either axis between centerlines of successive columns shall be
# permitted."  The span is taken along the frame line, as the §13.6.1.4
# check in `check_ddm_applicability` does.  It covers a 5° skew
# (tan 5° < 0.10).  The next column line is at least ℓ1/2 away (§13.6.1.2,
# page 252), so it is never on the line.
#
# ENGINEERING JUDGMENT: the 0.35 m floor covers 0.1 ft of vertex noise and a
# 1 mm survey error next to the column, where 10% of the distance is tiny.
#
# Membership, frame-line depth, the far support, the straddle cutoff, and
# the next-column-line cap on tributary width all use this predicate.
const _EQ137_FRAME_BAND_M = 0.35
const _EQ137_FRAME_BAND_FRAC = 0.10

# ENGINEERING JUDGMENT: two skeleton vertices are on the same storey when
# their z agree within 0.05 m.  Storey heights are metres apart, so this is
# a float tolerance on one level.
const _EQ137_STOREY_DZ_M = 0.05

# ENGINEERING JUDGMENT: a far support lies at least 0.15 m along the frame
# line from the column under analysis.  A closer column vertex is the same
# support (a duplicated or nudged vertex), not the next column line.
const _EQ137_FAR_MIN_ALONG_M = 0.15

# ENGINEERING JUDGMENT: two plan points within 5 mm are the same point of
# the slab mesh, whatever their vertex indices.  Continuity at a column is
# read from coordinates, not from shared vertex indices, so a mesh whose
# faces carry their own copies of a vertex (no deduplication, or float noise
# across the StructuralSynthesizer `COORD_DIGITS = 6` rounding, 1e-6 m)
# classifies exactly like the merged mesh.  5 mm covers that noise and a
# 1–3 mm survey offset with margin, and is far below any column or panel
# dimension, so two distinct mesh points are never taken as one.
const _EQ137_COINCIDE_M = 0.005

# ENGINEERING JUDGMENT: the column neighbourhood is the on-line floor
# `_EQ137_FRAME_BAND_M` (0.35 m) around the column point.  A same-storey face
# that comes this close to the column without adjoining it (no corner at the
# column point) and is not explained by the adjoining faces
# (`_eq137_neighbourhood_explained`) may be a hidden panel or a separate
# slab; the geometry cannot tell which, so the column is ambiguous and takes
# the envelope (`_eq137_support_class`).  No structural joint is ever
# inferred from mesh topology: the skeleton has no joint flag.
const _EQ137_NEIGHBOURHOOD_M = _EQ137_FRAME_BAND_M

# ENGINEERING JUDGMENT: a cell vertex within 0.05 m along the frame line of
# the column is at the column and does not give the cell a depth.
const _EQ137_DEPTH_MIN_ALONG_M = 0.05

# ENGINEERING JUDGMENT: two columns recorded at one support point agree when their
# face half-widths along the axis differ by at most 1/8 in (1/4 in on the
# full dimension).  A larger difference changes ℓn (§13.6.2.5) and is a
# data conflict, not float noise.  The comparison allows a further 1e-6 in
# of float error from the unit conversions, so exactly 1/4 in agrees.
const _EQ137_FACE_ATOL_IN = 0.125
const _EQ137_FACE_FLOAT_IN = 1e-6

# ENGINEERING JUDGMENT: a cell at the column puts the slab on one side of
# it along the frame line when it covers at least 0.01 m (twice
# `_EQ137_COINCIDE_M`) of the frame line within `_EQ137_NEIGHBOURHOOD_M`
# of the column point on that side (`_eq137_cell_sides`).  A shorter run is
# the coincidence tolerance at the column point (a face on the other side,
# or across the column's transverse line), not slab.  The frame line is
# probed on its axis and on the two rays `_EQ137_FRAME_BAND_FRAC` (the
# §13.6.1.4 10%, page 252) off it, so a slab edge skewed within that offset
# still continues the frame line.
const _EQ137_SIDE_MIN_M = 2 * _EQ137_COINCIDE_M

# ENGINEERING JUDGMENT: a cell occupies a quadrant around a column when at
# least 5% of its area lies in that quadrant.  A 2° skew sliver across a
# column line is well below that; a panel that genuinely crosses the line
# puts a large share on each side.
const _EQ137_QUADRANT_AREA_FRAC = 0.05

# Spatial-hash bucket (meters) for the column neighbourhood index.  Only an
# accelerator: a cell is tested against every column vertex in the buckets
# its tolerance-expanded bounding box touches, and a point against the
# column points in its own and the eight adjacent buckets (both tolerances
# are far below the bucket), so the size does not change any result.
const _EQ137_PARTWAY_BUCKET_M = 3.0

"""Spatial-hash bucket of a coordinate (meters)."""
_eq137_bucket(x::Float64) = floor(Int, x / _EQ137_PARTWAY_BUCKET_M)

"""True when plan points `a` and `b` are the same mesh point (`_EQ137_COINCIDE_M`)."""
_eq137_coincide(a, b)::Bool = hypot(a[1] - b[1], a[2] - b[2]) <= _EQ137_COINCIDE_M

"""True when segments AB and CD meet, including a shared endpoint."""
function _eq137_segs_cross(A, B, C, D)::Bool
    orient(P, Q, R) = (Q[1] - P[1]) * (R[2] - P[2]) - (Q[2] - P[2]) * (R[1] - P[1])
    o1, o2 = orient(A, B, C), orient(A, B, D)
    o3, o4 = orient(C, D, A), orient(C, D, B)
    tol = 1e-14
    if abs(o1) <= tol && abs(o2) <= tol && abs(o3) <= tol && abs(o4) <= tol
        return !(max(A[1], B[1]) < min(C[1], D[1]) - 1e-12 ||
                 max(C[1], D[1]) < min(A[1], B[1]) - 1e-12 ||
                 max(A[2], B[2]) < min(C[2], D[2]) - 1e-12 ||
                 max(C[2], D[2]) < min(A[2], B[2]) - 1e-12)
    end
    return o1 * o2 <= 0 && o3 * o4 <= 0
end

"""True when polygons `a` and `b` intersect, including a shared boundary."""
function _eq137_poly_hits(a, b)::Bool
    any(p -> _ddm_point_in_or_on(p, b), a) && return true
    any(p -> _ddm_point_in_or_on(p, a), b) && return true
    na, nb = length(a), length(b)
    for i in 1:na
        A, B = a[i], a[mod1(i + 1, na)]
        for j in 1:nb
            _eq137_segs_cross(A, B, b[j], b[mod1(j + 1, nb)]) && return true
        end
    end
    return false
end

"""
Plan rectangle of `col` at `xy` (meters), expanded by `_EQ137_COINCIDE_M`.

ACI 318-11 §13.6.2.5 (corpus: aci-318-11, page 253): a circular support is
the equivalent square of the same area.  Rectangular supports use `c1` and
`c2` in the column's local axes (`col_orientation`).  `nothing` when the
column has no section size.
"""
function _eq137_column_outline(col, xy)::Union{Nothing,Vector{NTuple{2,Float64}}}
    hasproperty(col, :c1) || return nothing
    c1 = col.c1
    (c1 === nothing || !isfinite(ustrip(u"m", c1))) && return nothing
    tol = _EQ137_COINCIDE_M
    if col_shape(col) == :circular
        side = ustrip(u"m", equivalent_square_column(c1))
        hx = side / 2 + tol
        hy = hx
    else
        c2 = hasproperty(col, :c2) && col.c2 !== nothing ? col.c2 : c1
        isfinite(ustrip(u"m", c2)) || return nothing
        hx = ustrip(u"m", c1) / 2 + tol
        hy = ustrip(u"m", c2) / 2 + tol
    end
    (hx > tol && hy > tol) || return nothing
    θ = col_orientation(col)
    cθ, sθ = cos(θ), sin(θ)
    corners = NTuple{2,Float64}[]
    for (dx, dy) in ((-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy))
        push!(corners, (xy[1] + cθ * dx - sθ * dy, xy[2] + sθ * dx + cθ * dy))
    end
    return corners
end

"""
True when the slab `polys` meets a column of the far-support group `far`.

The test is the column cross-section (`_eq137_column_outline`) against the
slab polygons.  With no section size, a polygon within
`_EQ137_NEIGHBOURHOOD_M` of the column point counts: the slab cannot be
shown to miss the support.

ACI 318-11 §13.6.2.5 (corpus: aci-318-11, page 253): ℓn is measured to the
face of a column the slab reaches.  A slot on the frame line does not
remove that column when the slab beside the slot still meets its face.
"""
function _eq137_slab_meets_support(far, polys)::Bool
    sized = false
    for col in far.columns
        outline = _eq137_column_outline(col, far.xy)
        outline === nothing && continue
        sized = true
        any(poly -> _eq137_poly_hits(outline, poly), polys) && return true
    end
    sized && return false
    # ENGINEERING JUDGMENT: no section size is on the column.  A slab within
    # the column neighbourhood cannot be shown to miss the support, so the
    # column stays a candidate and Eq. (13-7) is enveloped up to the
    # column-to-column clear span rather than cut at the slot.
    R = _EQ137_NEIGHBOURHOOD_M
    return any(poly -> _eq137_poly_dist(far.xy, poly) <= R, polys)
end

"""
True when two vertex elevations (meters, `nothing` for a 2-D skeleton) are
on the same storey (`_EQ137_STOREY_DZ_M`).  An unknown or non-finite
elevation cannot exclude the vertex.  A non-finite z on a slab-face corner
or column vertex is rejected before any geometry is read: it flags every
column (`_eq137_partway_index` `nonfinite`), so the transfer moment is NaN
with a `:failure` trace event (`non_finite_vertex`).
"""
function _eq137_z_agree(za, zb)::Bool
    (za === nothing || zb === nothing) && return true
    (isfinite(za) && isfinite(zb)) || return true
    return abs(za - zb) <= _EQ137_STOREY_DZ_M
end

"""On-line tolerance (meters) at an along-axis distance (§13.6.1.4 and a floor)."""
function _eq137_online_tol(along_m::Float64)
    return max(_EQ137_FRAME_BAND_M, _EQ137_FRAME_BAND_FRAC * abs(along_m))
end

"""
True when a point `along` meters along the frame line and `perp` meters off
it lies on the frame line (`_eq137_online_tol`).
"""
_eq137_on_line(along::Float64, perp::Float64)::Bool =
    abs(perp) <= _eq137_online_tol(along)

const _EQ137_WARNED = Set{Symbol}()
# NLP grid search calls `evaluate` on many threads, so the check-and-insert
# on `_EQ137_WARNED` is taken under this lock.
const _EQ137_WARNED_LOCK = ReentrantLock()

"""Warn at most once per process for a given Eq. (13-7) fallback (thread-safe)."""
function _eq137_warn_once(key::Symbol, msg::String)
    first_time = lock(_EQ137_WARNED_LOCK) do
        key in _EQ137_WARNED && return false
        push!(_EQ137_WARNED, key)
        return true
    end
    first_time && @warn msg
    return nothing
end

"""Skeleton geometry is present and readable for adjoining-panel lookup."""
function _eq137_geometry_available(struc)::Bool
    isnothing(struc) && return false
    hasproperty(struc, :skeleton) || return false
    hasproperty(struc, :cells) || return false
    skel = struc.skeleton
    hasproperty(skel, :geometry) || return false
    hasproperty(skel, :face_vertex_indices) || return false
    hasproperty(skel.geometry, :vertex_coords) || return false
    return true
end

"""Bare XY (meters) of skeleton vertex `vi`."""
function _eq137_vertex_xy_m(skel, vi::Int)::NTuple{2,Float64}
    vc = skel.geometry.vertex_coords
    x, y = vc[vi, 1], vc[vi, 2]
    if x isa Length
        return (ustrip(u"m", x), ustrip(u"m", y))
    end
    return (Float64(x), Float64(y))
end

"""Structural centerline (meters): vertex plus `structural_offset`."""
function _eq137_structural_xy(struc, col)::NTuple{2,Float64}
    vi = col_vertex_idx(col)
    vi <= 0 && return (0.0, 0.0)
    x, y = _eq137_vertex_xy_m(struc.skeleton, vi)
    if hasproperty(col, :structural_offset)
        o = col.structural_offset
        x += Float64(o[1])
        y += Float64(o[2])
    end
    return (x, y)
end

"""Unit span axis and the left-pointing perpendicular."""
function _eq137_unit_axes(span_axis::NTuple{2,Float64})
    ax_len = hypot(span_axis...)
    ax_len < 1e-9 && return nothing
    ax = (span_axis[1] / ax_len, span_axis[2] / ax_len)
    return ax, (-ax[2], ax[1])
end

"""
Half-width of `col` along `axis` (center to face).

ACI 318-11 §13.6.2.5 (corpus: aci-318-11, page 253): circular supports are
the equivalent square, not the radius.  Rectangular supports, including
`Column.θ`, use `_column_face_offset_m`.  Axis-aligned θ = 0 along X is `c1/2`.

`c_override` replaces the full dimension of columns on the slab under design
(the NLP trial size).
"""
function _eq137_face_half(col, axis::NTuple{2,Float64};
                          c_override=nothing, design_verts=nothing)
    vi = col_vertex_idx(col)
    if c_override !== nothing && design_verts !== nothing && vi in design_verts
        return c_override / 2
    end
    c1 = hasproperty(col, :c1) ? col.c1 : nothing
    isnothing(c1) && return 0.0u"inch"
    if col_shape(col) == :circular
        return equivalent_square_column(c1) / 2
    end
    if !hasproperty(col, :c2) || isnothing(col.c2)
        return c1 / 2
    end
    axes = _eq137_unit_axes(axis)
    ax = axes === nothing ? (1.0, 0.0) : axes[1]
    return _column_face_offset_m(col, ax) * u"m"
end

"""
Mean full support width along `axis`, for the Eq. (13-4) clear span.

Same face projection as Eq. (13-7).  ACI 318-11 §13.6.2.5
(corpus: aci-318-11, page 253).
"""
function _mean_support_width(columns, axis)
    widths = Length[]
    for col in columns
        push!(widths, 2 * _eq137_face_half(col, axis))
    end
    isempty(widths) && return 0.0u"inch"
    return sum(widths) / length(widths)
end

"""
Vertex indices of the slab under design: its face corners, and every column
vertex of the neighbourhood index `partway` whose point coincides with one
of those corners (`_eq137_columns_at`), so a column on a duplicated vertex
still takes the NLP trial size.
"""
function _eq137_design_vertices(struc, slab, partway = nothing)::Set{Int}
    ids = Set{Int}()
    _eq137_geometry_available(struc) || return ids
    (isnothing(slab) || !hasproperty(slab, :cell_indices)) && return ids
    for ci in slab.cell_indices
        for vi in _eq137_cell_vis(struc, ci)
            push!(ids, vi)
            partway === nothing || union!(ids, _eq137_columns_at(struc, partway, vi))
        end
    end
    return ids
end

"""Cells of every slab, including the slab under design if it is not listed."""
function _eq137_slab_cells(struc, design_slab)
    seen = Set{Int}()
    cells = Int[]
    function _add(sl)
        isnothing(sl) && return
        hasproperty(sl, :cell_indices) || return
        for ci in sl.cell_indices
            ci in seen && continue
            push!(seen, ci)
            push!(cells, ci)
        end
    end
    if hasproperty(struc, :slabs)
        for sl in struc.slabs
            _add(sl)
        end
    end
    _add(design_slab)
    return cells
end

"""Column vertices of `struc.columns` plus the vertex indices in `extra_verts`."""
function _eq137_column_vertices(struc, extra_verts = ())::Set{Int}
    query = Set{Int}(Int(v) for v in extra_verts)
    if hasproperty(struc, :columns)
        for col in struc.columns
            push!(query, col_vertex_idx(col))
        end
    end
    return query
end

"""
Vertex → cells at that vertex.

Built once per analysis.  Eq. (13-7) then touches only the cells at the
column, not every cell in the building.

At a column vertex (one of `struc.columns`, or listed in `extra_verts`;
or every vertex indexed by a supplied `partway`) the entry is the
geometric adjoining set of the neighbourhood index
(`_eq137_partway_index`): every same-storey cell with a corner that
coincides with the column point (`_EQ137_COINCIDE_M`), whatever its vertex
indices.  Other vertices list the cells that use that vertex index.
"""
function _eq137_vertex_cell_index(struc, extra_verts = (); partway = nothing)
    idx = Dict{Int,Vector{Int}}()
    _eq137_geometry_available(struc) || return idx
    for ci in _eq137_slab_cells(struc, nothing), vi in _eq137_cell_vis(struc, ci)
        push!(get!(idx, vi, Int[]), ci)
    end
    pw = partway === nothing ?
         _eq137_partway_index(struc, _eq137_column_vertices(struc, extra_verts)) : partway
    for (v, cells) in pw.adjoin
        idx[v] = copy(cells)
    end
    return idx
end

"""Throw for a cell listed by two slabs (`k1`, `k2` index `struc.slabs`)."""
function _eq137_shared_cell_error(ci::Int, k1::Int, k2::Int)
    throw(ArgumentError(
        "Eq. (13-7) neighbour lookup: cell $ci is listed by slab $k1 and slab $k2 " *
        "(indices in struc.slabs).  A cell must belong to one slab; its self-weight " *
        "and drop panel cannot be chosen between two owners."
    ))
end

"""
Cell index → owning slab.  Built once per analysis call.

A cell listed by two different slabs has no single owner, so its neighbour
thickness and drop are undefined.  That throws `ArgumentError` naming both
slabs and the cell; no slab wins by list order.
"""
function _eq137_cell_slab_map(struc)
    m = Dict{Int,Any}()
    owner = Dict{Int,Int}()
    (isnothing(struc) || !hasproperty(struc, :slabs)) && return m
    for (k, sl) in enumerate(struc.slabs)
        hasproperty(sl, :cell_indices) || continue
        for ci in sl.cell_indices
            c = Int(ci)
            if haskey(m, c)
                m[c] === sl && continue
                _eq137_shared_cell_error(c, owner[c], k)
            end
            m[c] = sl
            owner[c] = k
        end
    end
    return m
end

"""
Vertex → every distinct column recorded at that vertex.

Storeys that share an XY location use different vertex indices, so the map
does not confuse a ground-storey column with the slab under design.  Two
columns at one vertex are both kept; `_eq137_resolved_sides` rejects them
when their sizes disagree.
"""
function _eq137_vertex_column_map(struc, extra)
    m = Dict{Int,Vector{Any}}()
    function add(col)
        vi = col_vertex_idx(col)
        vi > 0 || return
        at = get!(m, vi, Any[])
        any(c -> c === col, at) || push!(at, col)
    end
    if !isnothing(struc) && hasproperty(struc, :columns)
        for col in struc.columns
            add(col)
        end
    end
    for col in extra
        add(col)
    end
    return m
end

"""
Index, cell→slab, vertex→column, and the column neighbourhood index
(`_eq137_partway_index`), built once and reused.  The vertex index takes
its column entries from the neighbourhood index, so both read the same
geometry.
"""
function _eq137_context(struc, extra = ())
    vertex_column = _eq137_vertex_column_map(struc, extra)
    partway = _eq137_partway_index(struc, keys(vertex_column))
    return (
        index = _eq137_geometry_available(struc) ?
                _eq137_vertex_cell_index(struc; partway = partway) : nothing,
        cell_slab = _eq137_cell_slab_map(struc),
        vertex_column = vertex_column,
        partway = partway,
    )
end

"""
Owning slab of a cell.  A precomputed map is not scanned again.  The scan
rejects a cell listed by two slabs, as `_eq137_cell_slab_map` does.
"""
function _eq137_owning_slab(cell_slab, struc, ci::Int)
    cell_slab !== nothing && return get(cell_slab, ci, nothing)
    (isnothing(struc) || !hasproperty(struc, :slabs)) && return nothing
    found = nothing
    found_k = 0
    for (k, sl) in enumerate(struc.slabs)
        hasproperty(sl, :cell_indices) || continue
        ci in sl.cell_indices || continue
        if found !== nothing && found !== sl
            _eq137_shared_cell_error(ci, found_k, k)
        end
        found === nothing && (found = sl; found_k = k)
    end
    return found
end

"""Polygon vertices (meters) of one cell, or `nothing`."""
function _eq137_cell_poly_m(struc, cell_index::Int)
    cell = struc.cells[cell_index]
    hasproperty(cell, :face_idx) || return nothing
    fi = cell.face_idx
    (fi isa Integer && fi >= 1) || return nothing
    skel = struc.skeleton
    vis = skel.face_vertex_indices[fi]
    return [_eq137_vertex_xy_m(skel, Int(vi)) for vi in vis]
end

"""Vertex indices of one cell, or an empty vector."""
function _eq137_cell_vis(struc, cell_index::Int)
    cell = struc.cells[cell_index]
    hasproperty(cell, :face_idx) || return Int[]
    fi = cell.face_idx
    (fi isa Integer && fi >= 1) || return Int[]
    return [Int(vi) for vi in struc.skeleton.face_vertex_indices[fi]]
end

"""Point of segment AB nearest to P, and its distance (meters)."""
function _eq137_seg_nearest(P, A, B)
    abx = B[1] - A[1]
    aby = B[2] - A[2]
    apx = P[1] - A[1]
    apy = P[2] - A[2]
    ab2 = abx * abx + aby * aby
    t = ab2 < 1e-18 ? 0.0 : clamp((apx * abx + apy * aby) / ab2, 0.0, 1.0)
    Q = (A[1] + t * abx, A[2] + t * aby)
    return Q, hypot(P[1] - Q[1], P[2] - Q[2])
end

"""True when P lies strictly inside polygon `poly` (crossing-number test)."""
function _eq137_point_in_poly(P, poly)::Bool
    inside = false
    n = length(poly)
    for i in 1:n
        A = poly[i]
        B = poly[mod1(i + 1, n)]
        if (A[2] > P[2]) != (B[2] > P[2])
            x = A[1] + (P[2] - A[2]) * (B[1] - A[1]) / (B[2] - A[2])
            x > P[1] && (inside = !inside)
        end
    end
    return inside
end

"""Plan distance (meters) from P to polygon `poly`; 0 when P is inside it."""
function _eq137_poly_dist(P, poly)::Float64
    _eq137_point_in_poly(P, poly) && return 0.0
    n = length(poly)
    return minimum(_eq137_seg_nearest(P, poly[i], poly[mod1(i + 1, n)])[2] for i in 1:n)
end

"""
Along-axis depth (meters) to the far frame-line vertex of the cell.

Only vertices inside the on-line tolerance are candidates.  Among those,
the depth is the farthest vertex that actually sits on the line (smallest
perpendicular distance).  An off-line corner, even one inside the
tolerance, does not change the depth.  Returns `nothing` when the cell
has no positive on-line extent.

ENGINEERING JUDGMENT: vertices within 1 mm of the closest perpendicular
distance are the same frame line.  Vertices within
`_EQ137_DEPTH_MIN_ALONG_M` along the line are at the column itself.
"""
function _eq137_frame_depth_m(poly, frame, dir)
    cands = Tuple{Float64,Float64}[]
    for p in poly
        dx = p[1] - frame[1]
        dy = p[2] - frame[2]
        along = dx * dir[1] + dy * dir[2]
        along <= _EQ137_DEPTH_MIN_ALONG_M && continue
        perp = abs(-dx * dir[2] + dy * dir[1])
        _eq137_on_line(along, perp) || continue
        push!(cands, (perp, along))
    end
    isempty(cands) && return nothing
    best_perp = minimum(c[1] for c in cands)
    depth = 0.0
    for (pr, al) in cands
        pr <= best_perp + 0.001 || continue
        depth = max(depth, al)
    end
    return depth
end

"""Z of a vertex, or `nothing` when the skeleton is 2-D."""
function _eq137_vertex_z(struc, vi::Int)
    vi <= 0 && return nothing
    vc = struc.skeleton.geometry.vertex_coords
    size(vc, 2) < 3 && return nothing
    vi > size(vc, 1) && return nothing
    z = vc[vi, 3]
    return z isa Length ? ustrip(u"m", z) : Float64(z)
end

"""
Local `(along, t)` coordinates (meters) of plan point `p` about `frame`:
`along` on the unit direction `dir`, `t` on the unit perpendicular `perp`.
"""
function _eq137_local(p, frame, dir, perp)
    dx = p[1] - frame[1]
    dy = p[2] - frame[2]
    return (dx * dir[1] + dy * dir[2], dx * perp[1] + dy * perp[2])
end

"""
Distance along the ray `P + s·dir` (unit `dir`) at which it crosses the
segment AB, or `nothing` when they are parallel or do not meet.
"""
function _eq137_ray_cross(P, dir, A, B)
    ex = B[1] - A[1]
    ey = B[2] - A[2]
    den = dir[1] * ey - dir[2] * ex
    abs(den) < 1e-12 && return nothing
    wx = A[1] - P[1]
    wy = A[2] - P[2]
    u = (wx * dir[2] - wy * dir[1]) / den
    (-1e-12 <= u <= 1.0 + 1e-12) || return nothing
    return (wx * ey - wy * ex) / den
end

"""
Covered stretches of the segment from `P` along the unit direction `dir`
over `[0, len]` by the polygons `polys`, as sorted, merged `(from, to)`
intervals (meters along `dir`).  A point is covered when it lies in a
polygon or within `_EQ137_COINCIDE_M` of one, so a segment along shared
face edges is covered.  The segment is split at every polygon-edge crossing
and every corner projection, so each piece is wholly in or out of the union.
"""
function _eq137_cover_pieces(P, dir, len::Float64, polys)
    out = Tuple{Float64,Float64}[]
    len > 0 || return out
    tol = _EQ137_COINCIDE_M
    Q = (P[1] + len * dir[1], P[2] + len * dir[2])
    xlo, xhi = min(P[1], Q[1]) - tol, max(P[1], Q[1]) + tol
    ylo, yhi = min(P[2], Q[2]) - tol, max(P[2], Q[2]) + tol
    near = [poly for poly in polys if
            maximum(p[1] for p in poly) >= xlo && minimum(p[1] for p in poly) <= xhi &&
            maximum(p[2] for p in poly) >= ylo && minimum(p[2] for p in poly) <= yhi]
    bps = [0.0, len]
    for poly in near
        n = length(poly)
        for i in 1:n
            A = poly[i]
            s = (A[1] - P[1]) * dir[1] + (A[2] - P[2]) * dir[2]
            0.0 < s < len && push!(bps, s)
            s = _eq137_ray_cross(P, dir, A, poly[mod1(i + 1, n)])
            s !== nothing && 0.0 < s < len && push!(bps, s)
        end
    end
    sort!(bps)
    for k in 1:length(bps)-1
        a, b = bps[k], bps[k+1]
        b - a > 1e-9 || continue
        m = (a + b) / 2
        M = (P[1] + m * dir[1], P[2] + m * dir[2])
        any(poly -> _eq137_poly_dist(M, poly) <= tol, near) || continue
        if !isempty(out) && out[end][2] >= a - 1e-9
            out[end] = (out[end][1], b)
        else
            push!(out, (a, b))
        end
    end
    return out
end

"""
Covered run (meters) of the segment from `P` along the unit direction `dir`
over `[0, len]` by the polygons `polys` (`_eq137_cover_pieces`): the end of
the stretch from `P` that the polygons cover, with uncovered stretches no
longer than `gap` bridged.
"""
function _eq137_cover_run(P, dir, len::Float64, polys, gap::Float64)
    run = 0.0
    for (a, b) in _eq137_cover_pieces(P, dir, len, polys)
        a > run + gap && break
        run = max(run, b)
    end
    return run
end

"""
True when every uncovered stretch longer than `_EQ137_NEIGHBOURHOOD_M`
between the covered `pieces` (`_eq137_cover_pieces` of `polys` along the
segment from `P` on the unit direction `u` over `[0, len]`) is an opening:
the slab closes it on both perpendicular sides within `len` of the gap's
midpoint.  A gap open on one side (a slab edge, notch or joint across the
line) is not an opening.

ENGINEERING JUDGMENT: an uncovered stretch the slab surrounds is an
opening, not a slab edge; the slab continues around it to the column
beyond (§13.6.2.5 measures ℓn between supports, corpus: aci-318-11,
page 253).  The search for the enclosing slab is limited to `len`, the
column-to-column distance; a gap open farther than that is read as a
notch or joint, which `_eq137_far_support` envelopes down to a zero span.
"""
function _eq137_gaps_enclosed(P, u, len::Float64, pieces, polys)::Bool
    R = _EQ137_NEIGHBOURHOOD_M
    perp = (-u[2], u[1])
    for k in 1:length(pieces)-1
        g0, g1 = pieces[k][2], pieces[k+1][1]
        g1 - g0 > R || continue
        m = (g0 + g1) / 2
        M = (P[1] + m * u[1], P[2] + m * u[2])
        for σ in (1, -1)
            isempty(_eq137_cover_pieces(M, (σ * perp[1], σ * perp[2]), len, polys)) &&
                return false
        end
    end
    return true
end

"""
True when P lies inside polygon `poly` farther than `_EQ137_COINCIDE_M`
from its boundary.
"""
function _eq137_strictly_inside(P, poly)::Bool
    _eq137_point_in_poly(P, poly) || return false
    n = length(poly)
    return all(_eq137_seg_nearest(P, poly[i], poly[mod1(i + 1, n)])[2] > _EQ137_COINCIDE_M
               for i in 1:n)
end

"""
True when face `poly` overlaps another face of `polys` (`(cell, polygon)`
pairs; `ci` is its own cell): a corner of one lies strictly inside the
other (`_eq137_strictly_inside`).  Faces of one tessellation never do.
"""
function _eq137_overlaps_other(ci::Int, poly, polys)::Bool
    for (cj, q) in polys
        cj == ci && continue
        (any(p -> _eq137_strictly_inside(p, poly), q) ||
         any(p -> _eq137_strictly_inside(p, q), poly)) && return true
    end
    return false
end

"""
Same-storey slab faces of column vertex `vi`: `(cell, polygon)` pairs from
the neighbourhood index `partway` (`polys`, finite faces only), in cell
order.  A face is on the storey when one of its corners is
(`_eq137_z_agree`), as in `_eq137_partway_index`.
"""
function _eq137_storey_polys(struc, partway, vi::Int)
    zv = _eq137_vertex_z(struc, vi)
    out = Tuple{Int,Vector{NTuple{2,Float64}}}[]
    for ci in sort!(collect(keys(partway.polys)))
        any(w -> _eq137_z_agree(_eq137_vertex_z(struc, w), zv), _eq137_cell_vis(struc, ci)) ||
            continue
        push!(out, (ci, partway.polys[ci]))
    end
    return out
end

"""
Far support column of column vertex `vi` on one side of its frame line:
the nearest column ahead along `dir` that lies on the frame line.

Candidates are every column point of the neighbourhood index `partway`
(`colxy`, matched by coordinates, whatever the vertex indices) on the
storey of `vi`, at least `_EQ137_FAR_MIN_ALONG_M` ahead and on the frame
line (`_eq137_on_line`, the §13.6.1.4 predicate).  Faces play no part: a
slab meshed into sub-panels has the same far support as the merged panel.
Ties in distance go to the smaller perpendicular offset, then the smaller
vertex index.  Every column vertex whose point coincides with the winner
(`_EQ137_COINCIDE_M`) is grouped with it, and all their columns
(`vertex_column`) are returned, so two coincident columns are compared by
`_eq137_resolved_sides` whatever their vertex order.

Twin support: when the nearest column ahead (at `a₁`) is closer to the
column than `_DDM_OFFSET_TWIN_FRAC` × the distance from it to the next
column ahead on the frame line (at `a₂`: `a₁ < 0.25 (a₂ − a₁)`), the two
are one support group (twin or doubled columns) and the far support is
the column at `a₂`; the twin is returned in `twin` (same fields) so the
caller measures the clear span from the group (`_eq137_resolved_sides`).
With no column beyond it the near column stays the far support.

ENGINEERING JUDGMENT: `_DDM_OFFSET_TWIN_FRAC` is the twin ratio of the
§13.6.1.4 successor search (`_ddm_column_successors`), here taken against
the span the group supports rather than the median column spacing, which
twins themselves pull down on a small plan.  A twin is never the far
support, so a sub-twin-spacing clear span is never used.

Returns `(vertices, columns, along_m, xy, twin)` or `nothing`.
"""
function _eq137_far_group(struc, partway, vertex_column, vi::Int, frame, dir)
    zv = _eq137_vertex_z(struc, vi)
    perp = (-dir[2], dir[1])
    keys_ = Tuple{Float64,Float64,Int}[]
    for (v, xy) in partway.colxy
        v == vi && continue
        _eq137_coincide(xy, frame) && continue
        _eq137_z_agree(_eq137_vertex_z(struc, v), zv) || continue
        a, t = _eq137_local(xy, frame, dir, perp)
        a < _EQ137_FAR_MIN_ALONG_M && continue
        _eq137_on_line(a, t) || continue
        push!(keys_, (a, abs(t), v))
    end
    isempty(keys_) && return nothing
    sort!(keys_)
    function group(key)
        xy = partway.colxy[key[3]]
        verts = sort!([v for (v, p) in partway.colxy if _eq137_coincide(p, xy) &&
                       _eq137_z_agree(_eq137_vertex_z(struc, v), zv)])
        cols = Any[]
        for v in verts, c in get(vertex_column, v, Any[])
            any(d -> d === c, cols) || push!(cols, c)
        end
        return (vertices = verts, columns = cols, along_m = key[1], xy = xy)
    end
    first_ = keys_[1]
    k2 = findfirst(k -> k[1] - first_[1] >= _EQ137_FAR_MIN_ALONG_M &&
                        !_eq137_coincide(partway.colxy[k[3]], partway.colxy[first_[3]]), keys_)
    if k2 !== nothing && first_[1] < _DDM_OFFSET_TWIN_FRAC * (keys_[k2][1] - first_[1])
        return merge(group(keys_[k2]), (twin = group(first_),))
    end
    return merge(group(first_), (twin = nothing,))
end

"""
Far end of one side of column vertex `vi` along `dir`, from the column
layout and the slab coverage of the frame line.

1. The far support is the nearest column on the frame line, past a twin
   of the column (`_eq137_far_group`).
2. Continuity: the slab must cover the frame line from the column point
   and reach the far column (`_eq137_cover_pieces`, any meshing).
   Uncovered stretches in between do not end the span when coverage
   resumes past them: ℓn runs between supports (§13.6.2.5, corpus:
   aci-318-11, page 253).
3. Status:
   - `:column`: covered, or covered except for openings the slab closes
     around (`_eq137_gaps_enclosed`, `opening = true`), and no face near
     the far column neither adjoins it nor is explained by its faces
     (`partway.near`).  The span ends at the far column.  Across an
     opening `alts_m` also holds the coverage end before the first
     opening, so Eq. (13-7) is enveloped over both readings and is never
     below the column-span value.  Another column partway along one of
     the far column's faces (`_eq137_ambiguous` `by_cell`) does not move
     this support; it is the design column's own panels that
     `_eq137_support_class` checks for that.  A face that runs past the
     far column (the column partway along its edge or inside it) does not
     move the support: the column under the slab is a support and ℓn is
     measured to its face (§13.6.2.5).
   - `:ambiguous`: the coverage reaches the far column only across a gap
     shorter than `_EQ137_NEIGHBOURHOOD_M` (between faces or just before the
     column), or across a longer gap that is open on one side (a notch or
     joint: `alts_m` then also admits 0, the slab ending at the gap); or a
     face near the far column neither adjoins it nor is explained by its
     faces.  The nominal span still ends at the far column, and `alts_m`
     lists the other support positions the geometry admits: the coverage
     end and on-line face corners within `_EQ137_NEIGHBOURHOOD_M` of the
     far column that do not coincide with it.
   - `:boundary`: no far column, or the slab does not reach it (a gap of
     at least `_EQ137_NEIGHBOURHOOD_M` at either end of the segment) and
     the slab beside that gap does not meet the far column.  The span
     ends where the coverage ends (`end_m`), with no column at that end;
     `alts_m` adds the loosely bridged coverage end and the on-line
     reach of faces past it.  A frame-line slot whose slab still meets
     the far column's face keeps that column (`_eq137_slab_meets_support`,
     §13.6.2.5): ℓn = 0 is not the top of the envelope.

`end_m` and `alts_m` are along-`dir` distances from the column point;
`far` is the `_eq137_far_group` result, or `nothing` for `:boundary`.

ENGINEERING JUDGMENT: a gap in coverage shorter than the column
neighbourhood (`_EQ137_NEIGHBOURHOOD_M`, 0.35 m) cannot be told apart from
a mesh defect (an unmerged copy of the far column vertex, a sliver
between faces) or a real joint, so it is not taken as either; the caller
envelopes both readings (`_eq137_resolved_sides`, `_eq137_support_class`).
"""
function _eq137_far_support(struc, partway, vertex_column, vi::Int, frame, dir, polys)
    R = _EQ137_NEIGHBOURHOOD_M
    tol = _EQ137_COINCIDE_M
    perp = (-dir[2], dir[1])
    all_polys = [p for (_, p) in polys]
    far = _eq137_far_group(struc, partway, vertex_column, vi, frame, dir)
    alts = Float64[]
    if far === nothing
        D = 0.0
        for poly in all_polys, q in poly
            D = max(D, _eq137_local(q, frame, dir, perp)[1])
        end
        end_m = _eq137_cover_run(frame, dir, D, all_polys, tol)
        loose = _eq137_cover_run(frame, dir, D, all_polys, R)
        loose > end_m + tol && push!(alts, loose)
        # On-line reach of the faces on this side past the coverage end.
        for poly in all_polys
            _eq137_local(_eq137_centroid(poly), frame, dir, perp)[1] > 0.0 || continue
            d = _eq137_frame_depth_m(poly, frame, dir)
            d !== nothing && d > end_m + tol && push!(alts, d)
        end
        return (far = nothing, status = :boundary, end_m = end_m, alts_m = alts,
                opening = false)
    end
    seg = (far.xy[1] - frame[1], far.xy[2] - frame[2])
    len = hypot(seg...)
    u = (seg[1] / len, seg[2] / len)
    scale = far.along_m / len
    pieces = _eq137_cover_pieces(frame, u, len, all_polys)
    strict = _eq137_cover_run(frame, u, len, all_polys, tol)
    opening = false
    short = false
    if strict < len - tol
        # The slab must start at the column.  A gap of at least R at the
        # near end is a slab edge.  A gap of at least R at the far end is a
        # slab edge only when the slab beside it does not meet the far
        # column (§13.6.2.5, corpus: aci-318-11, page 253).
        near_gap = isempty(pieces) || pieces[1][1] > R
        far_gap = !isempty(pieces) && len - pieces[end][2] >= R
        meets = far_gap && !near_gap && _eq137_slab_meets_support(far, all_polys)
        if near_gap || (far_gap && !meets)
            return (far = nothing, status = :boundary, end_m = strict * scale,
                    alts_m = alts, opening = false)
        end
        push!(alts, strict * scale)
        gaps = [pieces[k+1][1] - pieces[k][2] for k in 1:length(pieces)-1]
        # The far-end opening that still meets the column is not a "short"
        # gap: ℓn runs to that column, and ℓn = 0 is not admitted.
        short = any(<=(R), gaps) || pieces[1][1] > tol ||
                (len - pieces[end][2] > tol && !meets)
        if any(>(R), gaps)
            if _eq137_gaps_enclosed(frame, u, len, pieces, all_polys)
                # Coverage resumes past every long gap and the slab closes
                # around each one: openings, not slab edges.  The far support
                # is still the column (§13.6.2.5, corpus: aci-318-11,
                # page 253).
                opening = true
            elseif meets
                # ENGINEERING JUDGMENT: the frame line is open, but the slab
                # beside the slot meets the far column, so that column stays
                # a support.  A clear span of 0 is not the upper end of the
                # Eq. (13-7) envelope.
                short = true
            else
                # Coverage resumes before the far column but a long gap is
                # open on one side (a notch or a joint across the line): the
                # slab may end at the gap, so a clear span down to 0 is
                # admitted, as at a slab edge.
                short = true
                push!(alts, 0.0)
            end
        end
        # The column the slab meets is a support even when the centerline
        # itself does not resume before it.
        meets && (opening = true)
    end
    end_m = far.along_m
    if any(v -> !isempty(get(partway.near, v, Int[])), far.vertices)
        for v in far.vertices, ci in get(partway.near, v, Int[])
            poly = get(partway.polys, ci, nothing)
            poly === nothing && continue
            for q in poly
                hypot(q[1] - far.xy[1], q[2] - far.xy[2]) <= R || continue
                _eq137_coincide(q, far.xy) && continue
                a, t = _eq137_local(q, frame, dir, perp)
                _eq137_on_line(a, t) && push!(alts, a)
            end
        end
        return (far = far, status = :ambiguous, end_m = end_m, alts_m = alts,
                opening = opening)
    end
    status = (isempty(alts) || (opening && !short)) ? :column : :ambiguous
    return (far = far, status = status, end_m = end_m, alts_m = alts, opening = opening)
end

"""
Transverse width of one side of column vertex `vi` from the column layout,
summed over every same-storey face on that side (any meshing).

The side's faces are those with area inside the span (each face clipped
to along `[0, end_m]`), whatever their centroid: a face that runs past the
far support, or a sliver at the column, enters with its part inside the
span.  A face that overlaps another same-storey face
(`_eq137_overlaps_other`) and whose centroid lies within the
perpendicular-neighbour cutoff (`_EQ137_PERP_ALONG_MIN_M`,
`_EQ137_PERP_ALONG_FRAC`) of the column's transverse line is a
perpendicular neighbour and is skipped.  On each perpendicular side of the
frame line:

- the next column line is the nearest column (`partway.colxy`, same storey)
  off the frame line (`_eq137_on_line`) between `_EQ137_FAR_MIN_ALONG_M`
  and the far end (plus the on-line tolerance there), other than the
  column and its far support.  Columns on the column's own transverse line
  are transverse neighbours, not the parallel line (ACI 318-11 §13.6.2.3,
  corpus: aci-318-11, page 253);
- the slab extent is the run from the frame line of the faces clipped to
  the span (along `[0, end_m]`).  Gaps up to `_EQ137_NEIGHBOURHOOD_M` are
  bridged.  A wider gap does not end the strip when a later face still
  lies inside the next column line: that face is the same transverse
  panel (§13.6.2.1, §13.6.2.3).  Past the column line, or with no column
  line, the first wider gap is the slab edge;
- the width is the covered run capped at the panel centerline
  (`min(run, line / 2)`): ACI 318-11 §13.6.2.1 bounds the strip by the panel
  centerline, §13.6.2.3 averages the adjacent transverse spans (half of the
  center-to-center `line`), and §13.6.2.4 substitutes the edge-to-centerline
  distance at an edge (corpus: aci-318-11, page 253).  A slab that stops
  short of the next column line but still covers the centerline keeps its
  full half-span; one that stops before the centerline keeps only its
  covered run (see the width computation for the governing judgment).

ℓ2 is the sum of the two widths.  Each face's tributary width (`tribs_m`,
for the line loads Σ q·ℓ2 of `_eq137_side_lines`) is ℓ2 times its share of
the face area inside the strip (along `[0, end_m]`, out to the width on
each perpendicular side), so the widths sum to ℓ2 whatever the meshing.

A face whose part inside the span has corners off the frame line on both
perpendicular sides crosses it.  If no next column line exists on one of
those sides, and that side still has a column somewhere off the frame
line, the half-to-half width there is unknown: `ArgumentError`
(ambiguous geometry, §13.6.9.2, page 258), never the full face width;
`_eq137_transfer_moment` turns it into NaN with a `:failure` trace event.
A side with no column anywhere off the frame line is the building edge.
A face that crosses only to include an overhang past that edge is not
ambiguous: the overhang is not a span (§13.6.2.4), and its width is 0.

`skip` are the plan points (the column and its far support) that are not
column lines.  Returns `(cells, tribs_m, l2_m, bridged_gap, overhang)`.
`bridged_gap` is true when a face past a gap wider than
`_EQ137_NEIGHBOURHOOD_M` was kept because it is still inside the next
column line.  `overhang` is true when a crossing face was kept as an
edge overhang.

"""
function _eq137_side_width(struc, partway, vi::Int, frame, dir, perp, end_m::Float64,
                           polys, skip)
    R = _EQ137_NEIGHBOURHOOD_M
    zv = _eq137_vertex_z(struc, vi)
    up = Inf
    dn = -Inf
    reach = end_m + _eq137_online_tol(end_m)
    for (v, xy) in partway.colxy
        any(s -> _eq137_coincide(xy, s), skip) && continue
        _eq137_z_agree(_eq137_vertex_z(struc, v), zv) || continue
        a, t = _eq137_local(xy, frame, dir, perp)
        (_EQ137_FAR_MIN_ALONG_M < a <= reach) || continue
        _eq137_on_line(a, t) && continue
        t > 0 ? (up = min(up, t)) : (dn = max(dn, t))
    end
    # A column anywhere off the frame line on side σ, not only inside this
    # span.  None means the side is outside the column grid (an edge).
    function has_column(σ::Int)::Bool
        for (v, xy) in partway.colxy
            _eq137_z_agree(_eq137_vertex_z(struc, v), zv) || continue
            a, t = _eq137_local(xy, frame, dir, perp)
            _eq137_on_line(a, t) && continue
            σ * t > 0 && return true
        end
        return false
    end
    col_up, col_dn = has_column(1), has_column(-1)
    # No next column line, and no column on that side of the frame line at
    # all: the slab past the line is an overhang, not a span (§13.6.2.4).
    overhang_up = !isfinite(up) && !col_up
    overhang_dn = !isfinite(dn) && !col_dn
    group = Tuple{Int,Vector{NTuple{2,Float64}}}[]
    crossed_overhang = false
    for (ci, poly) in polys
        lp = [_eq137_local(q, frame, dir, perp) for q in poly]
        span = _eq137_clip_halfplane(_eq137_clip_halfplane(lp, 1, 1), 1, -1, end_m)
        _eq137_poly_area(span) > 1e-9 || continue
        a, t = _eq137_local(_eq137_centroid(poly), frame, dir, perp)
        if abs(a) < max(_EQ137_PERP_ALONG_MIN_M, _EQ137_PERP_ALONG_FRAC * hypot(a, t)) &&
           _eq137_overlaps_other(ci, poly, polys)
            continue
        end
        off_up = any(q -> q[2] > 0 && !_eq137_on_line(q[1], q[2]), span)
        off_dn = any(q -> q[2] < 0 && !_eq137_on_line(q[1], q[2]), span)
        if off_up && off_dn && (!isfinite(up) || !isfinite(dn))
            # One side is an edge overhang and the other has its column
            # line: the overhang is not a span (§13.6.2.4, page 253).
            # Both sides outside the column grid, or a missing line that
            # still has a column somewhere, stays ambiguous.
            ambiguous = (!isfinite(up) && !overhang_up) || (!isfinite(dn) && !overhang_dn)
            if ambiguous || (overhang_up && overhang_dn)
                throw(ArgumentError(
                    "ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258): " *
                    "cell $ci crosses the frame line at column vertex $vi " *
                    "but has no column vertex on one side to fix the next column line, " *
                    "so its half-to-half tributary width (§13.6.2.3, page 253) is " *
                    "unknown.  This is ambiguous geometry for Eq. (13-7)."
                ))
            end
            crossed_overhang = true
        end
        push!(group, (ci, span))
    end
    width = Dict{Int,Float64}()
    bridged = false
    for σ in (1, -1)
        # ENGINEERING JUDGMENT: zero the overhang only when a face crossed
        # the frame line to include it.  A strip whose columns all lie on
        # the frame line still takes ℓ2 = run / 2 from the slab that is
        # there (§13.6.2.4, corpus: aci-318-11, page 253).  The cantilever
        # past an edge column line is not a span.
        if crossed_overhang && ((σ == 1 && overhang_up) || (σ == -1 && overhang_dn))
            width[σ] = 0.0
            continue
        end
        ivs = Tuple{Float64,Float64}[]
        for (_, span) in group
            piece = _eq137_clip_halfplane(span, 2, σ)
            _eq137_poly_area(piece) > 1e-9 || continue
            push!(ivs, (minimum(σ * q[2] for q in piece), maximum(σ * q[2] for q in piece)))
        end
        sort!(ivs)
        line = σ == 1 ? up : -dn
        run = 0.0
        for (lo, hi) in ivs
            if lo > run + R
                # ENGINEERING JUDGMENT: a gap wider than the neighbourhood is
                # still the same panel when the next face lies inside the
                # next column line (§13.6.2.1, §13.6.2.3, corpus:
                # aci-318-11, page 253).  Dropping it would silently shrink ℓ2.
                if isfinite(line) && lo < line - _EQ137_COINCIDE_M
                    bridged = true
                    run = max(run, hi)
                else
                    break
                end
            else
                run = max(run, hi)
            end
        end
        # ACI 318-11 §13.6.2.1 (corpus: aci-318-11, page 253): the static
        # moment is determined "in a strip bounded laterally by centerline of
        # panel on each side of centerline of supports," and ℓ2 (§13.6.2.3,
        # page 253) is the center-to-center transverse span.  When the slab
        # covers the centerline (run >= line / 2) the half-strip reaches it at
        # line / 2; taking line / 2 preserves the full-coverage result
        # (run >= line gives line / 2 = min(run, line) / 2) and restores the
        # full half-span for a panel that stops short of the next column line
        # but still covers the centerline.  §13.6.2.4 (page 253): with no next
        # column line the overhang branch stays run-based (run / 2).
        #
        # A panel whose slab terminates BEFORE the panel centerline
        # (run < line / 2) is not bounded by the centerline of panel required
        # by §13.6.2.1, so its ℓ2 is not the §13.6.2.3 center-to-center
        # transverse span: the geometry is ambiguous for Eq. (13-7).  Fail
        # closed — throw the same §13.6.9.2 ArgumentError the other
        # ambiguous-geometry branches use rather than returning the reduced,
        # unconservative covered run.  `_eq137_transfer_moment` /
        # `_frameline_end_transfer` catch it and turn it into NaN with an
        # `adjoining_spans_unresolved` :failure trace, so the panel is handed
        # to the upstream fallback instead of sized on a shrunken ℓ2.
        if isfinite(line)
            if run < line / 2 - _EQ137_COINCIDE_M
                throw(ArgumentError(
                    "ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258): " *
                    "on side $σ the slab covers only $(round(run; digits = 3)) m of " *
                    "the transverse span, but the panel centerline (§13.6.2.1, " *
                    "page 253) lies at $(round(line / 2; digits = 3)) m, so the strip " *
                    "stops short of the centerline and its center-to-center ℓ2 " *
                    "(§13.6.2.3, page 253) is unknown.  This is ambiguous geometry " *
                    "for Eq. (13-7)."
                ))
            end
            width[σ] = line / 2
        else
            width[σ] = run / 2
        end
    end
    l2 = width[1] + width[-1]
    cells = Int[]
    areas = Float64[]
    for (ci, span) in group
        A = 0.0
        for σ in (1, -1)
            width[σ] > 0 || continue
            piece = _eq137_clip_halfplane(_eq137_clip_halfplane(span, 2, σ), 2, -σ,
                                          σ * width[σ])
            A += _eq137_poly_area(piece)
        end
        A > 1e-9 || continue
        push!(cells, ci)
        push!(areas, A)
    end
    total = sum(areas; init = 0.0)
    tribs = total > 0 ? [l2 * A / total for A in areas] : Float64[]
    return (cells = cells, tribs_m = tribs, l2_m = total > 0 ? l2 : 0.0,
            bridged_gap = bridged, overhang = crossed_overhang)
end

function _eq137_centroid(poly)
    n = length(poly)
    sx = 0.0
    sy = 0.0
    for p in poly
        sx += p[1]
        sy += p[2]
    end
    return (sx / n, sy / n)
end

"""
Sides (+1 / −1 along the unit axis `ax`) of the frame line through `frame`
on which cell `ci` carries the slab next to the column, as
`(side, cell_index, poly)` entries (none, one, or both sides).

The cell comes from the geometric adjoining set (a corner at the column
point), or from the column neighbourhood when an ambiguous column's
envelope counts the nearby faces as adjoining (`_eq137_transfer_moment`).
It carries the slab on a side when it covers at least `_EQ137_SIDE_MIN_M`
of the frame line within `_EQ137_NEIGHBOURHOOD_M` of the column point on
that side (`_eq137_cover_pieces`), probed on the axis and on the two rays
`_EQ137_FRAME_BAND_FRAC` off it.  This reads slab coverage, not face
corners or centroids, so a sliver face at the column or a face with the
column partway along its edge continues the frame line exactly like the
merged panel.  It only says which sides of the column the slab continues
on; the span and width of each side come from the column layout
(`_eq137_resolved_sides`).
"""
function _eq137_cell_sides(struc, ci::Int, frame, ax)
    out = NamedTuple[]
    poly = _eq137_cell_poly_m(struc, ci)
    (poly === nothing || length(poly) < 3) && return out
    all(p -> all(isfinite, p), poly) || return out
    f = _EQ137_FRAME_BAND_FRAC
    for side in (1, -1)
        d = (side * ax[1], side * ax[2])
        n = (-d[2], d[1])
        rays = (d, (d[1] + f * n[1], d[2] + f * n[2]), (d[1] - f * n[1], d[2] - f * n[2]))
        covers = any(rays) do r
            u = (r[1] / hypot(r...), r[2] / hypot(r...))
            pieces = _eq137_cover_pieces(frame, u, _EQ137_NEIGHBOURHOOD_M, (poly,))
            sum((b - a for (a, b) in pieces); init = 0.0) >= _EQ137_SIDE_MIN_M
        end
        covers && push!(out, (side = side, cell_index = ci, poly = poly))
    end
    return out
end

"""Throw when the columns at the far support point give different faces."""
function _eq137_reject_far_columns(col_vi::Int, side::Int, fars, ax)
    sizes = join((string(round(2 * ustrip(u"inch", _eq137_face_half(c, ax)); digits=2))
                  for c in fars), ", ")
    throw(ArgumentError(
        "ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258): the far " *
        "support of column vertex $col_vi on side $side has $(length(fars)) columns " *
        "recorded at one point with different faces along the span ([$sizes] in).  " *
        "The clear span (§13.6.2.5, page 253) is ambiguous geometry for Eq. (13-7)."
    ))
end

"""
    _eq137_resolved_sides(struc, slab, col, span_axis; kwargs...)

Panels on each side of `col` along `span_axis`.

Returns `nothing` when the skeleton cannot place the column.  Otherwise a
vector of 0, 1, or 2 sides.  A side exists where an adjoining panel lies
(`_eq137_side_panels`, the continuity test).  Its span comes from the
column layout, not from face corners, so any sub-panel meshing gives the
merged panel's answer:

- the far support is the nearest column on the frame line, and the slab
  must cover the frame line up to it (`_eq137_far_support`);
- `ℓ_cc` runs between the structural centers of the two columns and `ℓn`
  face to face of them (ACI 318-11 §13.6.2.5, corpus: aci-318-11, page 253:
  "Clear span ℓn shall extend from face to face of columns, capitals,
  brackets, or walls");
- `ℓ2` is the sum of the transverse widths to the panel centerlines, from
  the adjacent column lines, over every face on that side
  (`_eq137_side_width`, §13.6.2.1, §13.6.2.3, §13.6.2.4, page 253).

Each side also carries `status` (`_eq137_far_support`) and `ln_range`, the
smallest and largest clear span the geometry admits.  For `:column` both
are `ℓn`.  For `:ambiguous` (`:decision` trace event
`far_support_ambiguous`) they span `ℓn` and the alternative support
positions, with no far face deducted at an alternative.  For `:boundary`
(the slab ends before any column on the frame line: a slab edge, opening,
wall, or cantilever; `:fallback` trace event `far_support_not_column`),
`ℓn` and `ℓ_cc` run to the end of the slab with no far face deducted, as
before, and `ln_range` runs from 0 to that length.  An opening on the frame
line (`_eq137_far_support` `opening`, `:decision` trace event
`far_support_across_opening`) keeps the column span and adds the span to
the opening to `ln_range`.  A twin of the column ahead
(`_eq137_far_group` `twin`, `:decision` trace event `twin_support_group`)
is part of the column's support: the far support is the next column,
`ℓ_cc` runs to it, the nominal `ℓn` runs from the twin's outer face, and
`ln_range` also keeps `ℓn` from the column's own face.

ENGINEERING JUDGMENT (`:boundary`): with no column at the far end the
support there, if any, is unknown (§13.6.2.5 measures to the face of a
wall, which may stand anywhere inside the slab, and a cantilever has no
support).  Eq. (13-7) magnitude is convex in each ℓn², so its largest value
over the admitted range is at an end of it; `_eq137_transfer_moment` takes
the larger of both ends and of §13.6.3.6 0.3 M0 (page 255).  Running ℓn to
the slab end alone is not conservative when that side is the shorter,
dead-load-only span.

`ArgumentError` (§13.6.9.2) is thrown for a face crossing the line with no
column line on one side (`_eq137_side_width`) and for columns at the far
support point (across vertex indices, `_eq137_far_group`) whose faces
differ by more than `_EQ137_FACE_ATOL_IN` (plus `_EQ137_FACE_FLOAT_IN`).
Those are ambiguous geometry, not §13.6.1.3 successive-span violations.
A non-positive clear span to a far column also throws (column faces
consume the span); on a `:boundary` side (the slab ends within the column
face) ℓn is 0.  `_eq137_transfer_moment` and `_frameline_end_transfer`
turn every such `ArgumentError` into NaN with a `:failure` trace event.  A non-finite clear span (NaN or infinite column face or position)
is returned as NaN with a `:failure` trace event (`non_finite_clear_span`),
so Eq. (13-7) is NaN and the connection is rejected.

`partway` is the column neighbourhood index (`_eq137_partway_index`); far
supports, column lines and faces are read from its coordinates, so a
duplicated vertex is still read as its column.  `nothing` builds it for
the columns in `vertex_column`.
"""
function _eq137_resolved_sides(struc, slab, col, span_axis::NTuple{2,Float64};
                               c_override=nothing, extra_columns=(), index=nothing,
                               vertex_column=nothing, partway=nothing, tc=nothing)
    _eq137_geometry_available(struc) || return nothing
    vi = col_vertex_idx(col)
    vi > 0 || return nothing
    axes = _eq137_unit_axes(span_axis)
    axes === nothing && return nothing
    ax, perp = axes

    vcol = vertex_column === nothing ? _eq137_vertex_column_map(struc, extra_columns) : vertex_column
    # The column under analysis may not be in `struc.columns` (a duck that
    # passes it only as `extra_columns` is already in the map; a lone `col`
    # still needs an entry so a shared vertex resolves).
    if !haskey(vcol, vi)
        vcol = copy(vcol)
        vcol[vi] = Any[col]
    end
    pw = _eq137_partway_at(struc, col, vcol, partway)
    idx = index === nothing ? _eq137_vertex_cell_index(struc; partway = pw) : index
    design_verts = _eq137_design_vertices(struc, slab, pw)
    # ℓ2 and membership use the architectural vertex line.  ℓ_cc uses the
    # structural center so an inset shortens only the end span.
    frame = _eq137_vertex_xy_m(struc.skeleton, vi)
    origin = _eq137_structural_xy(struc, col)
    near_half = _eq137_face_half(col, ax; c_override, design_verts)

    raw = _eq137_side_panels(struc, col, span_axis, idx)
    polys = _eq137_storey_polys(struc, pw, vi)

    sides = NamedTuple[]
    for side in (1, -1)
        group = [p for p in raw if p.side == side]
        isempty(group) && continue
        dir = (side * ax[1], side * ax[2])
        fs = _eq137_far_support(struc, pw, vcol, vi, frame, dir, polys)
        far = fs.far
        inset = (origin[1] - frame[1]) * dir[1] + (origin[2] - frame[2]) * dir[2]
        if far === nothing
            # No column at the far end of the slab on this frame line.  No
            # far face is deducted: ℓn runs to the end of the slab.  ℓ_cc is
            # measured from the structural center, as between two columns.
            _eq137_trace_fallback(tc, col, :far_support_not_column;
                                  stage = "_eq137_resolved_sides")
            l_cc = (fs.end_m - inset) * u"m"
            far_half = 0.0u"inch"
        else
            fs.status == :ambiguous &&
                _eq137_trace_fallback(tc, col, :far_support_ambiguous;
                                      stage = "_eq137_resolved_sides", event = :decision)
            # ENGINEERING JUDGMENT: an opening on the frame line does not end
            # the span (§13.6.2.5, corpus: aci-318-11, page 253); Eq. (13-7)
            # is enveloped over the column span and the span to the opening.
            fs.opening &&
                _eq137_trace_fallback(tc, col, :far_support_across_opening;
                                      stage = "_eq137_resolved_sides", event = :decision)
            fars = far.columns
            function reach(fc)
                fxy = _eq137_structural_xy(struc, fc)
                along = (fxy[1] - origin[1]) * dir[1] + (fxy[2] - origin[2]) * dir[2]
                return along * u"m", _eq137_face_half(fc, ax; c_override, design_verts)
            end
            l_cc, far_half = reach(fars[1])
            # Columns at the far support point (one vertex or coincident
            # vertices) must give the same face (§13.6.2.5, corpus:
            # aci-318-11, page 253).  Neither a smaller nor a larger one is
            # conservative for Eq. (13-7) in general: a longer ℓn on the
            # shorter span lowers Mu.  So a disagreement throws, whatever
            # the vertex order.
            for other in fars[2:end]
                lo, ho = reach(other)
                if abs(ustrip(u"inch", (lo - ho) - (l_cc - far_half))) >
                   _EQ137_FACE_ATOL_IN + _EQ137_FACE_FLOAT_IN
                    _eq137_reject_far_columns(vi, side, fars, ax)
                end
            end
        end
        ln = uconvert(u"ft", l_cc - near_half - far_half)
        # Twin support (`_eq137_far_group`): the column and its twin are one
        # support, so ℓn also runs from the twin's outer face.
        ln_twin = nothing
        if far !== nothing && far.twin !== nothing
            _eq137_trace_fallback(tc, col, :twin_support_group;
                                  stage = "_eq137_resolved_sides", event = :decision)
            ln_twin = minimum(far.twin.columns; init = ln) do tcol
                ta, th = reach(tcol)
                uconvert(u"ft", l_cc - far_half - (ta + th))
            end
        end
        if !isfinite(ln)
            # A non-finite column face or position: ℓn (§13.6.2.5) is
            # undefined.  It is carried as NaN so Eq. (13-7) returns NaN and
            # `transfer_section_inadequate` rejects the connection.
            _eq137_trace_fallback(tc, col, :non_finite_clear_span;
                                  stage = "_eq137_resolved_sides", event = :failure)
            ln = NaN * u"ft"
        elseif ln <= 0.0u"ft" && fs.status == :boundary
            # The slab ends on the frame line within the column face (for
            # example a nearby face read as adjoining that the frame line
            # only grazes): no clear span on this side.  ℓn = 0 is the
            # admitted reading; the boundary range runs from it.
            ln = 0.0u"ft"
        elseif ln <= 0.0u"ft"
            throw(ArgumentError(
                "ACI 318-11 §13.6.2.5 and §13.6.9.2 (corpus: aci-318-11, pages 253 " *
                "and 258): clear span at column vertex $vi is non-positive " *
                "(ℓn = $(ln)).  Column faces consume the center-to-center span."
            ))
        end
        cands = [ln]
        if ln_twin !== nothing && isfinite(ln)
            # ENGINEERING JUDGMENT: the nominal ℓn runs from the group's
            # outer face; the range also keeps ℓn from the column's own face.
            ln = isfinite(ln_twin) ? max(0.0u"ft", ln_twin) : NaN * u"ft"
            isfinite(ln) || _eq137_trace_fallback(tc, col, :non_finite_clear_span;
                                                  stage = "_eq137_resolved_sides",
                                                  event = :failure)
            push!(cands, ln)
        end
        for a in fs.alts_m
            push!(cands, uconvert(u"ft", (a - inset) * u"m" - near_half))
        end
        fs.status == :boundary && push!(cands, 0.0u"ft")
        ln_range = isfinite(ln) ? (max(0.0u"ft", minimum(cands)), maximum(cands)) : (ln, ln)
        skip = far === nothing ? (frame,) : (frame, far.xy)
        width = _eq137_side_width(struc, pw, vi, frame, dir, perp, fs.end_m, polys, skip)
        # A later panel inside the next column line was kept across a gap
        # wider than the neighbourhood.  Eq. (13-7) must not silently drop it.
        width.bridged_gap &&
            _eq137_trace_fallback(tc, col, :transverse_panel_past_gap;
                                  stage = "_eq137_resolved_sides", event = :decision)
        # The face crosses the edge line only to include an overhang.  That
        # overhang is not a span (§13.6.2.4, corpus: aci-318-11, page 253).
        width.overhang &&
            _eq137_trace_fallback(tc, col, :edge_overhang_not_a_span;
                                  stage = "_eq137_resolved_sides", event = :decision)
        cells = isempty(width.cells) ? [p.cell_index for p in group] : width.cells
        rep = cells[1]
        if !isnothing(slab) && hasproperty(slab, :cell_indices)
            k = findfirst(ci -> ci in slab.cell_indices, cells)
            k === nothing || (rep = cells[k])
        end
        tribs = isempty(width.cells) ? fill(0.0u"ft", length(cells)) :
                [uconvert(u"ft", t * u"m") for t in width.tribs_m]
        push!(sides, (
            side = side,
            cell_index = rep,
            cell_indices = cells,
            tribs = tribs,
            l_cc = uconvert(u"ft", l_cc),
            ln = ln,
            l2 = sum(tribs),
            ln_range = ln_range,
            status = fs.status,
        ))
    end
    return sides
end

"""
Adjoining panels of `col` (the cells `index` lists at its vertex: for a
column vertex, every cell with a corner at the column point,
`_eq137_vertex_cell_index`) on either side of its frame line along
`span_axis` (`_eq137_cell_sides`), or `nothing` without geometry.

This is the continuity test shared by the transfer moment
(`_eq137_resolved_sides`) and the flexural assignment
(`_ddm_support_moment`).  It does not depend on column size.
"""
function _eq137_side_panels(struc, col, span_axis::NTuple{2,Float64}, index)
    _eq137_geometry_available(struc) || return nothing
    vi = col_vertex_idx(col)
    vi > 0 || return nothing
    axes = _eq137_unit_axes(span_axis)
    axes === nothing && return nothing
    ax = axes[1]
    frame = _eq137_vertex_xy_m(struc.skeleton, vi)
    raw = NamedTuple[]
    for ci in get(index, vi, Int[])
        append!(raw, _eq137_cell_sides(struc, ci, frame, ax))
    end
    return raw
end

"""
True when a side of `col` along `span_axis` that has an adjoining panel
(`_eq137_side_panels`) has a far support that is not a column the slab is
shown to reach (`_eq137_far_support` status `:ambiguous` or `:boundary`).
Independent of column size, so the flexural and transfer classifications
(`_eq137_support_class`) read the same answer.
"""
function _eq137_far_uncertain(struc, col, span_axis::NTuple{2,Float64}, index,
                              vertex_column, partway)::Bool
    _eq137_geometry_available(struc) || return false
    vi = col_vertex_idx(col)
    vi > 0 || return false
    axes = _eq137_unit_axes(span_axis)
    axes === nothing && return false
    ax = axes[1]
    vcol = vertex_column === nothing ? _eq137_vertex_column_map(struc, (col,)) : vertex_column
    pw = _eq137_partway_at(struc, col, vcol, partway)
    panels = _eq137_side_panels(struc, col, span_axis, index)
    panels === nothing && return false
    frame = _eq137_vertex_xy_m(struc.skeleton, vi)
    polys = _eq137_storey_polys(struc, pw, vi)
    for side in unique(p.side for p in panels)
        dir = (side * ax[1], side * ax[2])
        _eq137_far_support(struc, pw, vcol, vi, frame, dir, polys).status == :column ||
            return true
    end
    return false
end

"""Polygon area (absolute shoelace)."""
function _eq137_poly_area(poly)
    n = length(poly)
    n < 3 && return 0.0
    s = 0.0
    for i in 1:n
        a = poly[i]
        b = poly[mod1(i + 1, n)]
        s += a[1] * b[2] - b[1] * a[2]
    end
    return abs(s) / 2
end

"""Sutherland–Hodgman clip of `poly` to the half-plane `sgn * (p[k] - off) >= 0`."""
function _eq137_clip_halfplane(poly, k::Int, sgn::Int, off::Float64 = 0.0)
    out = NTuple{2,Float64}[]
    n = length(poly)
    for i in 1:n
        P = poly[i]
        Q = poly[mod1(i + 1, n)]
        dp = sgn * (P[k] - off)
        dq = sgn * (Q[k] - off)
        dp >= 0 && push!(out, P)
        if (dp >= 0) != (dq >= 0)
            t = dp / (dp - dq)
            push!(out, (P[1] + t * (Q[1] - P[1]), P[2] + t * (Q[2] - P[2])))
        end
    end
    return out
end

"""
How many quadrants around `col` its cells occupy.

Quadrants are taken in the frame of `span_axis` and its perpendicular, so a
plan rotated off the global axes counts the same as an aligned one.  Each
cell is clipped to each quadrant, so a cell that straddles the frame line
occupies every quadrant it covers.  Measured from the architectural vertex,
so a structural inset does not move a cell across the frame line.

ENGINEERING JUDGMENT: a quadrant counts when it holds at least
`_EQ137_QUADRANT_AREA_FRAC` of the cell's area.
"""
function _eq137_quadrant_count(struc, col, index, span_axis::NTuple{2,Float64})::Int
    vi = col_vertex_idx(col)
    vi <= 0 && return 0
    axes = _eq137_unit_axes(span_axis)
    axes === nothing && return 0
    ax, perp = axes
    origin = _eq137_vertex_xy_m(struc.skeleton, vi)
    quads = Set{Tuple{Int,Int}}()
    for ci in get(index, vi, Int[])
        poly = _eq137_cell_poly_m(struc, ci)
        (poly === nothing || length(poly) < 3) && continue
        loc = [((p[1] - origin[1]) * ax[1] + (p[2] - origin[2]) * ax[2],
                (p[1] - origin[1]) * perp[1] + (p[2] - origin[2]) * perp[2]) for p in poly]
        total = _eq137_poly_area(loc)
        total > 0 || continue
        for sa in (1, -1), sp in (1, -1)
            part = _eq137_clip_halfplane(_eq137_clip_halfplane(loc, 1, sa), 2, sp)
            if _eq137_poly_area(part) >= _EQ137_QUADRANT_AREA_FRAC * total
                push!(quads, (sa, sp))
            end
        end
    end
    return length(quads)
end

"""True when segment AB coincides with an edge of one of the polygons `own`."""
function _eq137_edge_in(A, B, own)::Bool
    for q in own
        m = length(q)
        for i in 1:m
            C = q[i]
            D = q[mod1(i + 1, m)]
            ((_eq137_coincide(A, C) && _eq137_coincide(B, D)) ||
             (_eq137_coincide(A, D) && _eq137_coincide(B, C))) && return true
        end
    end
    return false
end

"""True when point X coincides with a corner of one of the polygons `own`."""
_eq137_corner_in(X, own)::Bool = any(q -> any(c -> _eq137_coincide(c, X), q), own)

"""
True when a face `poly` near the column point `P` that does not adjoin it
is explained by the column's adjoining faces `own` (polygons):

- it does not contain `P`;
- each of its corners within `_EQ137_NEIGHBOURHOOD_M` of `P` coincides with
  a corner of an adjoining face (a mesh vertex the column's faces reach,
  for example the far end of a short edge or an opening corner); and
- each of its edges that passes within that radius either coincides with
  an edge of an adjoining face (the two faces are continuous across it,
  geometrically) or comes nearest to `P` at such a corner.

Otherwise the face is a T-junction, an unmerged near-duplicate, an
overlap, or a slab across a gap, and the geometry cannot say whether it
continues the column's slab.
"""
function _eq137_neighbourhood_explained(P, poly, own)::Bool
    _eq137_point_in_poly(P, poly) && return false
    R = _EQ137_NEIGHBOURHOOD_M
    n = length(poly)
    for k in 1:n
        A = poly[k]
        B = poly[mod1(k + 1, n)]
        if hypot(A[1] - P[1], A[2] - P[2]) <= R && !_eq137_corner_in(A, own)
            return false
        end
        Q, d = _eq137_seg_nearest(P, A, B)
        d <= R || continue
        _eq137_edge_in(A, B, own) && continue
        at_corner(X) = _eq137_coincide(Q, X) && _eq137_corner_in(X, own)
        (at_corner(A) || at_corner(B)) || return false
    end
    return true
end

"""
Column neighbourhood index for the column vertices in `verts`, from
coordinates only (never from shared vertex indices), so a mesh whose faces
carry their own copies of a vertex reads like the merged mesh.  Only
same-storey faces count: a face is off the storey when every corner has a
known z more than `_EQ137_STOREY_DZ_M` from the column's.

Fields (a NamedTuple):
- `adjoin[v]`: faces with a corner that coincides with the column point
  (`_eq137_coincide`, same storey at that corner).  The §13.6.3.3 class
  (corpus: aci-318-11, page 254) and Eq. (13-7) (§13.6.9.2, page 258) read
  the panels at the column from this set (`_eq137_vertex_cell_index`).
- `merged`: column vertices with an adjoining face that does not list the
  column's vertex index (a duplicated or nudged vertex), traced
  `duplicate_vertex_merged`.
- `near[v]`: faces within `_EQ137_NEIGHBOURHOOD_M` of the column point
  (plan distance, 0 inside the face) that do not adjoin it and are not
  explained by its adjoining faces (`_eq137_neighbourhood_explained`).
  `by_cell[ci]` lists the column vertices for which face `ci` is such a
  face.  Both make a column ambiguous (`_eq137_ambiguous`).
- `nonfinite`: column vertices whose own XY or z is not finite, or whose
  storey holds a non-finite slab-face corner or column point.
- `colxy`, `colgrid`: finite column points and their spatial hash
  (`_eq137_columns_at`).
- `polys[ci]`: plan polygon (meters) of every slab face whose corners are
  all finite (XY and z), read by the far-support and transverse-width
  search (`_eq137_far_support`, `_eq137_side_width`).

ENGINEERING JUDGMENT (non-finite): a NaN coordinate can stand for any
point, so it cannot be shown to lie outside a column's neighbourhood, to
not be its far support, or to not be a panel at it.  A NaN z can stand for
any storey.  Every column on that storey (every storey when the bad vertex
has no finite z, which includes a NaN z) is flagged, and
`_eq137_transfer_moment` / `_ddm_support_class` reject it before reading
any geometry.  The geometric tests below then read finite faces only.

Every vertex in `verts` with `v > 0` has an `adjoin` and a `near` entry,
so a missing key means the vertex was not indexed.  Built once per
analysis (`_eq137_context`); each cell is tested only against the column
points in the spatial buckets its radius-expanded bounding box touches.
"""
function _eq137_partway_index(struc, verts)
    adjoin = Dict{Int,Vector{Int}}()
    near = Dict{Int,Vector{Int}}()
    by_cell = Dict{Int,Vector{Int}}()
    merged = Set{Int}()
    nonfinite = Set{Int}()
    colxy = Dict{Int,NTuple{2,Float64}}()
    colgrid = Dict{NTuple{2,Int},Vector{Int}}()
    polys = Dict{Int,Vector{NTuple{2,Float64}}}()
    out = (adjoin = adjoin, near = near, by_cell = by_cell, merged = merged,
           nonfinite = nonfinite, colxy = colxy, colgrid = colgrid, polys = polys)
    _eq137_geometry_available(struc) || return out
    skel = struc.skeleton
    R = _EQ137_NEIGHBOURHOOD_M
    bad_z = Float64[]
    bad_any_storey = Ref(false)
    function taint!(ws)
        for w in ws
            z = _eq137_vertex_z(struc, w)
            if z === nothing || !isfinite(z)
                bad_any_storey[] = true
            else
                push!(bad_z, z)
            end
        end
    end
    finite_z(w) = (z = _eq137_vertex_z(struc, w); z === nothing || isfinite(z))
    cells = _eq137_slab_cells(struc, nothing)
    for ci in cells
        vis = _eq137_cell_vis(struc, ci)
        isempty(vis) && continue
        poly = [_eq137_vertex_xy_m(skel, w) for w in vis]
        if all(p -> all(isfinite, p), poly) && all(finite_z, vis)
            polys[ci] = poly
        else
            taint!(vis)
        end
    end
    for v in verts
        v > 0 || continue
        adjoin[v] = Int[]
        near[v] = Int[]
        p = _eq137_vertex_xy_m(skel, v)
        if all(isfinite, p) && finite_z(v)
            colxy[v] = p
            push!(get!(colgrid, (_eq137_bucket(p[1]), _eq137_bucket(p[2])), Int[]), v)
        else
            taint!((v,))
            append!(adjoin[v], [ci for ci in cells if v in _eq137_cell_vis(struc, ci)])
        end
    end
    for v in keys(adjoin)
        zv = _eq137_vertex_z(struc, v)
        if !haskey(colxy, v) || bad_any_storey[] || any(z -> _eq137_z_agree(z, zv), bad_z)
            push!(nonfinite, v)
        end
    end
    cand = Dict{Int,Vector{Int}}()
    for ci in cells
        poly = get(polys, ci, nothing)
        poly === nothing && continue
        vis = _eq137_cell_vis(struc, ci)
        zs = [_eq137_vertex_z(struc, w) for w in vis]
        bx0 = _eq137_bucket(minimum(p[1] for p in poly) - R)
        bx1 = _eq137_bucket(maximum(p[1] for p in poly) + R)
        by0 = _eq137_bucket(minimum(p[2] for p in poly) - R)
        by1 = _eq137_bucket(maximum(p[2] for p in poly) + R)
        for bx in bx0:bx1, by in by0:by1, v in get(colgrid, (bx, by), Int[])
            zv = _eq137_vertex_z(struc, v)
            any(z -> _eq137_z_agree(z, zv), zs) || continue
            P = colxy[v]
            if any(k -> _eq137_coincide(poly[k], P) && _eq137_z_agree(zs[k], zv), eachindex(poly))
                push!(adjoin[v], ci)
                v in vis || push!(merged, v)
            elseif _eq137_poly_dist(P, poly) <= R
                push!(get!(cand, v, Int[]), ci)
            end
        end
    end
    for (v, cs) in cand
        own = [polys[ci] for ci in adjoin[v]]
        for ci in cs
            _eq137_neighbourhood_explained(colxy[v], polys[ci], own) && continue
            push!(near[v], ci)
            push!(get!(by_cell, ci, Int[]), v)
        end
    end
    return out
end

"""
Column vertices of the neighbourhood index `partway` whose point coincides
with skeleton vertex `w` (`_eq137_coincide`) on the same storey, including
`w` itself when it is an indexed column vertex.  Empty for a non-finite
`w`: a non-finite vertex flags its storey (`partway.nonfinite`), which the
callers reject first.
"""
function _eq137_columns_at(struc, partway, w::Int)
    out = Int[]
    p = _eq137_vertex_xy_m(struc.skeleton, w)
    all(isfinite, p) || return out
    zw = _eq137_vertex_z(struc, w)
    bx, by = _eq137_bucket(p[1]), _eq137_bucket(p[2])
    for i in -1:1, j in -1:1, u in get(partway.colgrid, (bx + i, by + j), Int[])
        _eq137_coincide(partway.colxy[u], p) || continue
        _eq137_z_agree(_eq137_vertex_z(struc, u), zw) || continue
        push!(out, u)
    end
    return out
end

"""
`partway` (a `_eq137_partway_index`) when it indexes `col`'s vertex;
otherwise the index built here for the column vertices of `vertex_column`
(`nothing`: every column of `struc`) plus `col`.
"""
function _eq137_partway_at(struc, col, vertex_column, partway)
    vi = col_vertex_idx(col)
    (partway !== nothing && haskey(partway.adjoin, vi)) && return partway
    vcol = vertex_column === nothing ? _eq137_vertex_column_map(struc, (col,)) : vertex_column
    verts = Set{Int}(keys(vcol))
    push!(verts, vi)
    return _eq137_partway_index(struc, verts)
end

"""
True when the neighbourhood of column vertex `vi` is ambiguous
(`_eq137_partway_index`): a nearby face that does not adjoin it is not
explained by its adjoining faces (`near`), or one of its adjoining faces is
such a face for another column (`by_cell`, for example a column partway
along that face's edge, so the face is not a proper panel there).
"""
function _eq137_ambiguous(partway, vi::Int)::Bool
    isempty(get(partway.near, vi, Int[])) || return true
    return any(ci -> any(!=(vi), get(partway.by_cell, ci, Int[])),
               get(partway.adjoin, vi, Int[]))
end

"""
True when the slab around `col` is read without ambiguity: every
same-storey face in the column neighbourhood adjoins it or is explained by
the faces that do (`_eq137_ambiguous`).  `index` is accepted for call-site
compatibility; the adjoining set is the neighbourhood index's.  `partway`
is the precomputed `_eq137_partway_index`; it is looked up, not rebuilt
(`_eq137_partway_at`).
"""
function _eq137_mesh_conforms(struc, col, index, vertex_column; partway = nothing)::Bool
    vi = col_vertex_idx(col)
    vi > 0 || return false
    return !_eq137_ambiguous(_eq137_partway_at(struc, col, vertex_column, partway), vi)
end

"""
True when the neighbourhood index flags `col` (`partway.nonfinite`): its
own XY, or a slab-face corner or column point on its storey, is not
finite.  Checked before any geometry is read.
"""
_eq137_nonfinite_at(partway, col)::Bool = col_vertex_idx(col) in partway.nonfinite

"""Position fallback used only when geometry cannot see the column."""
function _eq137_position_exterior(col, span_axis)::Bool
    return is_exterior_support(col, span_axis)
end

"""
Service drop pressure spread over `panel_area`.

The projection is dead load.  It is added to service `qD` so the §9.2.1
factor (1.2 or 1.4) is applied with the rest of D, not as a flat 1.2 on
`qu` only.  ACI 318-11 §9.2.1 (corpus: aci-318-11, page 123).
"""
function _eq137_drop_service(drop_panel, panel_area, γ)
    (isnothing(drop_panel) || isnothing(γ)) && return 0.0psf
    w_drop = uconvert(psf, drop_panel.h_drop * γ * GRAVITY)
    A_drop = uconvert(u"ft^2", drop_extent_1(drop_panel) * drop_extent_2(drop_panel))
    A_panel = uconvert(u"ft^2", panel_area)
    A_panel <= 0.0u"ft^2" && return 0.0psf
    return uconvert(psf, w_drop * (A_drop / A_panel))
end

"""Add drop dead load to service `qD`, then refactor `qu` and `M0`."""
function _eq137_with_drop(qD, qL, l2, ln, drop_panel, panel_area, γ)
    qD2 = uconvert(psf, qD + _eq137_drop_service(drop_panel, panel_area, γ))
    # ACI 318-11 §9.2.1 Eq. (9-1) and Eq. (9-2) (corpus: aci-318-11, page 123).
    qu2 = max(factored_pressure(default_combo, qD2, qL),
              factored_pressure(strength_1_4D, qD2, qL))
    return qD2, qu2, total_static_moment(qu2, l2, ln)
end

"""Owning-slab result thickness as a service pressure, or `nothing`."""
function _eq137_sw_from_result(struc, cell_index::Int, γ; cell_slab=nothing)
    isnothing(γ) && return nothing
    sl = _eq137_owning_slab(cell_slab, struc, cell_index)
    sl === nothing && return nothing
    res = hasproperty(sl, :result) ? sl.result : nothing
    (res === nothing || !hasproperty(res, :thickness)) && return nothing
    h = res.thickness
    h isa Length || return nothing
    return uconvert(psf, slab_self_weight(h, γ))
end

"""
Self-weight of a neighbour cell.

`cell.self_weight` is written only after sizing converges, so during moment
analysis it can be zero or left from a previous thickness.  Prefer the
owning slab's result thickness when that exists.  If the stored value and
the thickness disagree, warn and use the thickness.  If neither exists,
warn and use the design panel's trial self-weight.  Both fallbacks also
emit a `:fallback` trace event on `tc` (`stale_self_weight`,
`missing_neighbour_sw`), keyed by the neighbour cell.
"""
function _eq137_neighbour_sw(struc, cell_index::Int, sw_trial::Pressure, γ;
                            cell_slab=nothing, design_drop::Pressure=0.0psf,
                            tc=nothing)
    stage = "_eq137_neighbour_sw"
    cell = struc.cells[cell_index]
    sw_stored = if hasproperty(cell, :self_weight) && !iszero(cell.self_weight)
        uconvert(psf, cell.self_weight)
    else
        nothing
    end
    sw_h = _eq137_sw_from_result(struc, cell_index, γ; cell_slab=cell_slab)
    if sw_h !== nothing && sw_stored !== nothing &&
       !isapprox(ustrip(psf, sw_h), ustrip(psf, sw_stored); atol=1.0)
        # ENGINEERING JUDGMENT: 1 psf is the float tolerance for "these two
        # pressures are the same self-weight".
        _eq137_warn_once(:stale_self_weight,
            "Neighbour cell.self_weight disagrees with the owning slab result thickness; using the thickness. cell.self_weight is written only after sizing converges and can be stale during moment analysis.")
        emit!(tc, :slab, stage, "cell_$(cell_index)", :fallback;
              reason = "stale_self_weight")
        return sw_h
    end
    sw_h !== nothing && return sw_h
    sw_stored !== nothing && return sw_stored
    _eq137_warn_once(:missing_neighbour_sw,
        "Neighbour cell has no self-weight and its slab has no result thickness; using the design panel trial self-weight without the design slab's drop. cell.self_weight is assigned only after sizing converges.")
    emit!(tc, :slab, stage, "cell_$(cell_index)", :fallback;
          reason = "missing_neighbour_sw")
    # `sw_trial` is qD − sdl, and qD already includes the design slab's drop.
    # Subtract that drop so the neighbour is not charged for it twice (once
    # here and again by `_eq137_neighbour_drop` when the neighbour has its own).
    return uconvert(psf, sw_trial) - uconvert(psf, design_drop)
end

"""Drop dead load of a neighbour slab, 0 when this cell is the design slab."""
function _eq137_neighbour_drop(struc, cell_index::Int, design_slab, γ; cell_slab=nothing)
    isnothing(γ) && return 0.0psf
    sl = _eq137_owning_slab(cell_slab, struc, cell_index)
    sl === nothing && return 0.0psf
    sl === design_slab && return 0.0psf
    dp = hasproperty(sl, :drop_panel) ? sl.drop_panel : nothing
    isnothing(dp) && return 0.0psf
    hasproperty(sl, :spans) || return 0.0psf
    area = sl.spans.primary * sl.spans.secondary
    return _eq137_drop_service(dp, area, γ)
end

"""
Service line loads `Σ q·ℓ2` on one side of the column.

ENGINEERING JUDGMENT: panels on the same side of a frame line may each be
uniform (§13.6.1.5, page 252, is per panel) and still differ from each
other.  Eq. (13-7)'s `q ℓ2` terms are line loads, so the side is the
tributary-width-weighted sum, not a throw.
"""
function _eq137_side_lines(struc, slab, side, sw_trial::Pressure, γ;
                          cell_slab=nothing, design_drop::Pressure=0.0psf,
                          tc=nothing)
    wD = 0.0psf * 0.0u"ft"
    wL = 0.0psf * 0.0u"ft"
    for (ci, trib) in zip(side.cell_indices, side.tribs)
        cell = struc.cells[ci]
        sdl = uconvert(psf, cell.sdl)
        qL = uconvert(psf, cell.live_load)
        in_design = !isnothing(slab) && hasproperty(slab, :cell_indices) &&
                    ci in slab.cell_indices
        if in_design
            # Design qD already includes this slab's drop and trial self-weight.
            # Do not add the drop again.
            sw = sw_trial
            q_drop = 0.0psf
        else
            sw = _eq137_neighbour_sw(struc, ci, sw_trial, γ;
                                     cell_slab=cell_slab, design_drop=design_drop,
                                     tc=tc)
            q_drop = _eq137_neighbour_drop(struc, ci, slab, γ; cell_slab=cell_slab)
        end
        wD += uconvert(psf, sdl + sw + q_drop) * trib
        wL += qL * trib
    end
    return wD, wL
end

"""Trial self-weight implied by the design panel `qD` (`qD = sdl + sw`)."""
function _eq137_sw_trial(struc, slab, qD::Pressure)::Pressure
    if isnothing(struc) || isnothing(slab) || !hasproperty(slab, :cell_indices) ||
       isempty(slab.cell_indices) || !hasproperty(struc, :cells)
        return zero(uconvert(psf, qD))
    end
    ref = struc.cells[first(slab.cell_indices)]
    hasproperty(ref, :sdl) || return zero(uconvert(psf, qD))
    return uconvert(psf, qD) - uconvert(psf, ref.sdl)
end

"""ACI 318-11 §13.6.3.6 transfer, 0.3 M0 (corpus: aci-318-11, page 255)."""
function _eq137_edge_moment(M0)
    isnothing(M0) && return 0.0kip * u"ft"
    return 0.3 * M0
end

"""
`:fallback` and `:decision` are registered event types (`size_flat_plate!`).
Reused here so an Eq. (13-7) or §13.6.3.3 classification choice is a trace
event, not only a warning.  `emit!(::Nothing, ...)` is a no-op when the
caller is not tracing.
"""
function _eq137_trace_fallback(tc, col, reason::Symbol;
                               stage::String = "_eq137_transfer_moment",
                               event::Symbol = :fallback)
    vi = col_vertex_idx(col)
    emit!(tc, :slab, stage, "col_v$(vi)", event; reason = String(reason))
end

"""
True when any service load (or length) in `xs` is negative.

ACI 318-11 §13.6.1.5 (corpus: aci-318-11, page 252): DDM loads are due to
gravity only and uniformly distributed.  A negative service dead or live
load is invalid input, rejected like a non-finite one.  Zero is valid.
"""
_eq137_negative_input(xs...)::Bool = any(x -> x < zero(x), xs)

"""
`:failure` trace event (`negative_service_load`) at `col` and a NaN transfer
moment, which `transfer_section_inadequate` rejects.
"""
function _eq137_negative_load_failure(tc, col, stage::String)
    _eq137_trace_fallback(tc, col, :negative_service_load; stage = stage, event = :failure)
    return NaN * kip * u"ft"
end

TRACE_REGISTRY[(:_eq137_transfer_moment, :slab)] = TracedFunctionMeta(
    :_eq137_transfer_moment, :slab, [:fallback, :decision, :failure], nothing,
    @__FILE__, @__LINE__,
)

TRACE_REGISTRY[(:_ddm_support_moment, :slab)] = TracedFunctionMeta(
    :_ddm_support_moment, :slab, [:fallback, :decision, :failure], nothing,
    @__FILE__, @__LINE__,
)

TRACE_REGISTRY[(:_eq137_resolved_sides, :slab)] = TracedFunctionMeta(
    :_eq137_resolved_sides, :slab, [:fallback, :decision, :failure], nothing,
    @__FILE__, @__LINE__,
)

TRACE_REGISTRY[(:_eq137_neighbour_sw, :slab)] = TracedFunctionMeta(
    :_eq137_neighbour_sw, :slab, [:fallback], nothing, @__FILE__, @__LINE__,
)

"""
True for an exterior, edge, or corner column, including a column tagged
`:interior` whose cells occupy one or two quadrants.

A corner or an edge must not receive the equal-span pattern.  Four
quadrants (or no geometry at all) are not edge-like.
"""
function _eq137_edge_like(struc, col, span_axis, idx)::Bool
    _eq137_position_exterior(col, span_axis) && return true
    pos = hasproperty(col, :position) ? col.position : :interior
    pos in (:edge, :corner, :exterior) && return true
    nquad = idx === nothing ? 0 : _eq137_quadrant_count(struc, col, idx, span_axis)
    return 0 < nquad <= 2
end

"""
How far panel geometry is trusted at `col`.

`geom_exterior` is the geometry's answer (slab on one side, or on neither).
Two-sided geometry with an interior tag (`_eq137_position_exterior`) is
`:agree` without a check.  Otherwise the neighbourhood is checked
(`_eq137_mesh_conforms`) whatever the tag says: a T-junction hides a panel,
and a tag derived from the same faces (for example single-face edges at a
T-junction or along a duplicated column line) agrees with the wrong
one-sided answer.  Conforming: `:agree` when the tag matches, `:geometry`
when it does not.  Non-conforming: `:envelope`.

USER DECISION / ENGINEERING JUDGMENT: in an ambiguous neighbourhood the
panel geometry cannot be shown to be continuous or discontinuous, so the
caller takes the larger of the interior and exterior moments.  Otherwise
the geometry is the better witness than a global tag.
"""
function _eq137_tag_trust(struc, col, span_axis, idx, vertex_column, geom_exterior::Bool;
                          partway = nothing)
    tag_exterior = _eq137_position_exterior(col, span_axis)
    !geom_exterior && !tag_exterior && return :agree
    vcol = vertex_column === nothing ? _eq137_vertex_column_map(struc, (col,)) : vertex_column
    _eq137_mesh_conforms(struc, col, idx, vcol; partway = partway) || return :envelope
    return geom_exterior == tag_exterior ? :agree : :geometry
end

"""
Trace reason for a non-conforming envelope, keyed by the geometry and the
tag, so a reader can tell which disagreement (if any) triggered it.
"""
function _eq137_nonconforming_reason(col, span_axis, nsides::Int)::Symbol
    tag_exterior = _eq137_position_exterior(col, span_axis)
    nsides == 2 && return :exterior_tag_nonconforming
    nsides == 1 && return tag_exterior ? :one_sided_nonconforming :
                                         :one_sided_interior_nonconforming
    return :exterior_no_panel_nonconforming
end

"""
Continuity class of `col` along `span_axis` from panel geometry:
`:interior`, `:exterior`, or `:envelope` (the larger of the two answers).

`nsides` is the number of sides of the frame line with a panel
(`_eq137_side_panels`).  The flexural (`_ddm_support_moment`) and transfer
(`_eq137_transfer_moment`) moments both use this one rule, so they agree on
which columns are continuous in this direction.

- Ambiguous neighbourhood (`_eq137_partway_index` `near`: a same-storey
  face within `_EQ137_NEIGHBOURHOOD_M` that neither adjoins the column nor
  is explained by the faces that do): `:envelope`, `:decision`
  (`ambiguous_neighbourhood_envelope`), whatever the sides and the tag.
- Two sides, three quadrants (re-entrant corner): `:envelope`, `:decision`.
- Two sides, a far support that is not a column the slab is shown to reach
  (`_eq137_far_uncertain`): `:envelope`, `:decision`
  (`uncertain_far_support_envelope`).
- Two sides: `:interior`.  An exterior tag is checked (`_eq137_tag_trust`).
- One side: `:exterior` on a conforming mesh, whatever the tag.
- No side, edge-like column (`_eq137_edge_like`): `:exterior` on a
  conforming mesh (`exterior_no_panel`).
- No side, no edge evidence: `:envelope` (`zero_sides`).
- An adjoining face that is ambiguous for another column (for example a
  column partway along its edge) in any of the checked cases: `:envelope`.

Adjoining faces are found by coordinates (`_EQ137_COINCIDE_M`), so faces
on a duplicated or nudged copy of the column vertex count as adjoining;
that emits a `duplicate_vertex_merged` `:decision`.  No structural joint
is inferred from vertex indices: a nearby face that shares no vertex with
the column's faces is ambiguous, not a separate slab.

Every choice that is not plain agreement emits a trace event at `stage`.
"""
function _eq137_support_class(struc, col, span_axis, idx, vertex_column, nsides::Int;
                              partway = nothing, tc = nothing, stage::String)
    pw = _eq137_partway_at(struc, col, vertex_column, partway)
    vi = col_vertex_idx(col)
    if vi in pw.merged
        # ENGINEERING JUDGMENT (`_EQ137_COINCIDE_M`): a face with a corner at
        # the column point adjoins the column whatever vertex index it uses,
        # so it enters the continuity test and Eq. (13-7) as a panel there.
        _eq137_trace_fallback(tc, col, :duplicate_vertex_merged; stage = stage,
                              event = :decision)
    end
    if !isempty(get(pw.near, vi, Int[]))
        # USER DECISION / ENGINEERING JUDGMENT: a face this close to the
        # column that does not adjoin it may be a panel hidden by a
        # T-junction or an unmerged vertex, or a slab across a joint.  The
        # skeleton has no joint flag, so neither can be shown.  Flexure takes
        # the larger of the §13.6.3.3 coefficients (corpus: aci-318-11,
        # page 254); transfer takes the larger of §13.6.3.6 0.3 M0 (page 255)
        # and Eq. (13-7) (§13.6.9.2, page 258) with the nearby faces counted
        # as adjoining (`_eq137_transfer_moment`).
        _eq137_warn_once(:ambiguous_neighbourhood_envelope,
            "A slab face near a column neither adjoins it nor continues its panels, so slab continuity there is uncertain; using the larger of the interior and exterior moments.")
        _eq137_trace_fallback(tc, col, :ambiguous_neighbourhood_envelope; stage = stage,
                              event = :decision)
        return :envelope
    end
    if nsides == 2 && _eq137_quadrant_count(struc, col, idx, span_axis) == 3
        # USER DECISION / ENGINEERING JUDGMENT: a re-entrant corner is
        # continuous on both sides in this direction and is also a plan
        # edge.  §13.6.3.3 (page 254) and R13.6.9 do not address an L-plan.
        # Flexure takes the larger coefficient; transfer takes the larger of
        # Eq. (13-7) and §13.6.3.6 0.3 M0 (corpus: aci-318-11, page 255).
        _eq137_trace_fallback(tc, col, :reentrant_corner; stage = stage, event = :decision)
        return :envelope
    end
    if nsides == 2 && _eq137_far_uncertain(struc, col, span_axis, idx, vertex_column, pw)
        # ENGINEERING JUDGMENT: slab on both sides, but a far support is not a
        # column the slab is shown to reach (`_eq137_far_support`: a slab
        # end, a gap shorter than the column neighbourhood, or a face near
        # the far column that neither adjoins it nor is explained).  Flexure
        # takes the larger §13.6.3.3 coefficient (corpus: aci-318-11,
        # page 254); transfer takes the larger of §13.6.3.6 0.3 M0
        # (page 255) and Eq. (13-7) (§13.6.9.2, page 258) over the admitted
        # clear spans (`_eq137_resolved_sides` `ln_range`).
        _eq137_warn_once(:uncertain_far_support,
            "A far support on this frame line is not a column the slab is shown to reach; using the larger of the interior and exterior moments and Eq. (13-7) over the admissible clear spans.")
        _eq137_trace_fallback(tc, col, :uncertain_far_support_envelope; stage = stage,
                              event = :decision)
        return :envelope
    end
    if nsides == 0 && !_eq137_edge_like(struc, col, span_axis, idx)
        # ENGINEERING JUDGMENT: geometry is present but no panel touches this
        # interior-tagged column, so it cannot be shown to be either kind of
        # support.  A column nudged off its panels may be an edge or corner.
        _eq137_warn_once(:zero_sides,
            "Eq. (13-7) found a column tagged interior but no panel on either side of the frame line; using the larger of the interior and exterior moments.")
        _eq137_trace_fallback(tc, col, :zero_sides; stage = stage)
        return :envelope
    end
    trust = _eq137_tag_trust(struc, col, span_axis, idx, vertex_column, nsides < 2;
                             partway = pw)
    if trust == :envelope
        # USER DECISION / ENGINEERING JUDGMENT: an adjoining face is not a
        # proper panel (another column lies partway along it), so its depth
        # and far support cannot be trusted.  Take the larger of the
        # interior and exterior moments.
        reason = _eq137_nonconforming_reason(col, span_axis, nsides)
        _eq137_warn_once(reason,
            "A panel at this column has another column partway along its edge, so slab continuity along this frame line is uncertain; using the larger of the interior and exterior moments.")
        _eq137_trace_fallback(tc, col, reason; stage = stage)
        return :envelope
    end
    if nsides == 2
        trust == :geometry && _eq137_trace_fallback(tc, col, :exterior_tag_two_sided; stage = stage)
        return :interior
    end
    if nsides == 1
        if trust == :geometry
            _eq137_warn_once(:one_sided_interior,
                "Interior column has slab on only one side of this frame line; treating it as an exterior support rather than repeating that panel.")
            _eq137_trace_fallback(tc, col, :one_sided_interior; stage = stage)
        end
    else
        # ACI 318-11 §13.6.3.6 (page 255) / §13.6.3.3 (page 254): an edge or
        # corner column nudged off its panels is still an exterior support.
        _eq137_warn_once(:exterior_no_panel,
            "Edge or corner column has no panel on either side of this frame line; treating it as an exterior support, not the equal-span pattern.")
        _eq137_trace_fallback(tc, col, :exterior_no_panel; stage = stage)
    end
    return :exterior
end

"""
Transfer moment at one column along `span_axis`.

The support is classified by `_eq137_support_class`.  `:interior`:
Eq. (13-7).  `:exterior`: §13.6.3.6, 0.3 M0 (the one panel is not
repeated).  `:envelope` with two sides (re-entrant corner, ambiguous
neighbourhood, uncertain far support, or exterior tag at a non-conforming
panel): the larger of Eq. (13-7) and 0.3 M0.  `:envelope` with fewer sides
(ambiguous neighbourhood, non-conforming panel, or a column tagged
interior that touches no panel): the larger of the equal-span pattern of
the panel in hand and 0.3 M0.  In an ambiguous neighbourhood either
envelope also takes Eq. (13-7) with the nearby faces counted as adjoining;
if those faces cannot be read as panels (`ArgumentError` from
`_eq137_resolved_sides`), NaN with a `:failure` trace event
(`near_faces_unresolved`), never an abort.  Likewise an `ArgumentError`
from resolving the adjoining sides themselves (ambiguous geometry,
§13.6.9.2) returns NaN with a `:failure` trace event
(`adjoining_spans_unresolved`).

Eq. (13-7) is evaluated at both ends of each side's admitted clear-span
range (`ln_range`, `_eq137_resolved_sides`) and the largest magnitude is
used; for a side whose far support is a column the slab reaches, the range
is the one clear span.

No geometry: the position fallback, and an interior equal-span pattern is
warned once.  Every fallback emits `:fallback`.

A non-finite coordinate at the column vertex, or at any slab-face corner
or column point on its storey (`_eq137_nonfinite_at`), returns NaN with a
`:failure` trace event (`non_finite_vertex`) before any geometry is read,
so `transfer_section_inadequate` rejects the connection.  A negative service `qD` / `qL`, or a negative side line load
from the adjoining cells, returns NaN with a `:failure` trace event
(`negative_service_load`; §13.6.1.5, corpus: aci-318-11, page 252).
"""
function _eq137_transfer_moment(struc, slab, col, span_axis,
                                qD::Pressure, qL::Pressure, l2::Length, ln::Length,
                                M0;
                                c_override=nothing, extra_columns=(),
                                index=nothing, vertex_column=nothing,
                                cell_slab=nothing, partway=nothing,
                                design_drop::Pressure=0.0psf,
                                γ=nothing, tc=nothing)
    stage = "_eq137_transfer_moment"
    _eq137_negative_input(qD, qL) && return _eq137_negative_load_failure(tc, col, stage)
    vcol = vertex_column === nothing ? _eq137_vertex_column_map(struc, extra_columns) : vertex_column
    cslab = cell_slab === nothing ? _eq137_cell_slab_map(struc) : cell_slab
    idx = index
    pw = nothing
    if _eq137_geometry_available(struc) && col_vertex_idx(col) > 0
        pw = _eq137_partway_at(struc, col, vcol, partway)
        idx === nothing && (idx = _eq137_vertex_cell_index(struc; partway = pw))
        if _eq137_nonfinite_at(pw, col)
            _eq137_trace_fallback(tc, col, :non_finite_vertex; stage = stage,
                                  event = :failure)
            return NaN * kip * u"ft"
        end
    end
    sides = try
        _eq137_resolved_sides(struc, slab, col, span_axis;
                              c_override=c_override, extra_columns=extra_columns,
                              index=idx, vertex_column=vcol, partway=pw, tc=tc)
    catch e
        e isa ArgumentError || rethrow()
        # ENGINEERING JUDGMENT: the adjoining spans cannot be read from the
        # geometry (§13.6.9.2 ambiguous geometry, corpus: aci-318-11,
        # page 258: a face across the frame line with no column line on
        # one side, coincident far columns with different faces, or column
        # faces that consume the span).  The connection is rejected (NaN)
        # rather than sized on a guess, and the design is not aborted.
        _eq137_trace_fallback(tc, col, :adjoining_spans_unresolved; stage = stage,
                              event = :failure)
        return NaN * kip * u"ft"
    end
    equal_span() = governing_interior_unbalanced_moment(qD, qL, l2, ln, qD, qL, l2, ln)
    if sides === nothing
        if _eq137_position_exterior(col, span_axis)
            _eq137_trace_fallback(tc, col, :no_geometry_exterior)
            return _eq137_edge_moment(M0)
        end
        _eq137_warn_once(:no_geometry,
            "Eq. (13-7) has no skeleton geometry for this column; using the equal-span pattern of the panel in hand.")
        _eq137_trace_fallback(tc, col, :no_geometry)
        return equal_span()
    end
    sw_trial = _eq137_sw_trial(struc, slab, qD)
    function two_sided(a, b)
        wD_a, wL_a = _eq137_side_lines(struc, slab, a, sw_trial, γ;
                                       cell_slab=cslab, design_drop=design_drop, tc=tc)
        wD_b, wL_b = _eq137_side_lines(struc, slab, b, sw_trial, γ;
                                       cell_slab=cslab, design_drop=design_drop, tc=tc)
        if _eq137_negative_input(wD_a, wL_a, wD_b, wL_b)
            return _eq137_negative_load_failure(tc, col, stage)
        end
        # Eq. (13-7) magnitude is convex in each ℓn², so over each side's
        # admitted clear spans (`ln_range`, `_eq137_resolved_sides`) the
        # largest value is at an end of the range.
        Mu = zero(1.0kip * u"ft")
        for la in unique(a.ln_range), lb in unique(b.ln_range)
            M = uconvert(kip * u"ft", _eq137_governing_line_loads(wD_a, wL_a, la, wD_b, wL_b, lb))
            isfinite(M) || return M
            Mu = max(Mu, M)
        end
        return Mu
    end
    edge = uconvert(kip * u"ft", _eq137_edge_moment(M0))
    # ENGINEERING JUDGMENT: a face near the column that does not adjoin it
    # (`_eq137_support_class`, ambiguous neighbourhood) may be the hidden far
    # side, so the envelope also takes Eq. (13-7) (corpus: aci-318-11,
    # page 258) with those faces counted as adjoining.
    # `_eq137_resolved_sides` reads the index only at the column vertex, so a
    # one-entry index is enough.
    function with_near(Mu_env)
        vi = col_vertex_idx(col)
        near = get(pw.near, vi, Int[])
        isempty(near) && return Mu_env
        near_idx = Dict(vi => union(get(idx, vi, Int[]), near))
        sides_near = try
            _eq137_resolved_sides(struc, slab, col, span_axis;
                                  c_override=c_override, extra_columns=extra_columns,
                                  index=near_idx, vertex_column=vcol,
                                  partway=pw, tc=tc)
        catch e
            e isa ArgumentError || rethrow()
            # ENGINEERING JUDGMENT: the nearby faces cannot be read as
            # panels (for example a face across the frame line with no
            # column line on one side), so the envelope's Eq. (13-7) reading
            # is undefined.  The connection is rejected (NaN) rather than
            # sized on the readings that could be evaluated, and the design
            # is not aborted.
            _eq137_trace_fallback(tc, col, :near_faces_unresolved; stage = stage,
                                  event = :failure)
            return NaN * kip * u"ft"
        end
        length(sides_near) == 2 || return Mu_env
        return max(Mu_env, uconvert(kip * u"ft", two_sided(sides_near[1], sides_near[2])))
    end
    if length(sides) < 2
        cls = _eq137_support_class(struc, col, span_axis, idx, vcol, length(sides);
                                   partway = pw, tc = tc, stage = stage)
        # ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255): the gravity
        # moment transferred between the slab and an edge column is 0.3 M0.
        # An uncertain support takes the larger of that, the equal-span
        # pattern of the panel in hand, and Eq. (13-7) with the nearby faces
        # (see `_eq137_support_class`).
        cls == :envelope || return _eq137_edge_moment(M0)
        return with_near(max(uconvert(kip * u"ft", equal_span()), edge))
    end

    Mu = two_sided(sides[1], sides[2])
    cls = _eq137_support_class(struc, col, span_axis, idx, vcol, 2;
                               partway = pw, tc = tc, stage = stage)
    # Re-entrant corner, ambiguous neighbourhood, or an exterior tag at a
    # non-conforming panel: the larger of Eq. (13-7) and §13.6.3.6 0.3 M0
    # (corpus: aci-318-11, page 255).
    cls == :envelope && return with_near(max(uconvert(kip * u"ft", Mu), edge))
    return Mu
end

"""
Negative flexural moment at one column along `span_axis`.

ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254): an end span takes the
exterior-negative moment at the exterior edge and the interior-negative
moment at the interior support.  The support is classified by the same
panel geometry as `_eq137_transfer_moment`, so the flexural and transfer
moments agree on which columns are continuous in this direction.

Slab on both sides: `M_neg_int`.  One side: `M_neg_ext`.  The rule,
including the re-entrant corner, the ambiguous neighbourhood (T-junction,
unmerged vertex, or nearby face across a gap), and a column touching no
panel, is `_eq137_support_class`; an `:envelope` class takes the larger of
the two.  No geometry: `is_exterior_support`.  Each of these choices is
traced.
"""
function _ddm_support_moment(struc, col, span_axis, M_neg_ext, M_neg_int;
                             index = nothing, vertex_column = nothing,
                             partway = nothing, tc = nothing)
    cls = _ddm_support_class(struc, col, span_axis; index = index,
                             vertex_column = vertex_column, partway = partway, tc = tc)
    cls === nothing && return is_exterior_support(col, span_axis) ? M_neg_ext : M_neg_int
    cls == :interior && return M_neg_int
    cls == :exterior && return M_neg_ext
    return max(M_neg_ext, M_neg_int)
end

"""
§13.6.3.3 support class of `col` along `span_axis` (`_eq137_support_class`
on the vertex-adjacent panels), or `nothing` with a `:fallback` trace event
(`no_geometry`) when the skeleton cannot place the column.

Shared by the single-panel DDM (`_ddm_support_moment`) and the multi-span
FrameLine DDM (`run_moment_analysis(::DDM, frame_line, ...)`), so both
classify a column the same way and emit the same trace events.

A non-finite coordinate at the column, or at any slab-face corner or
column point on its storey (`_eq137_nonfinite_at`), gives `:envelope` with
a `:failure` trace event (`non_finite_vertex`) before any geometry is read.
"""
function _ddm_support_class(struc, col, span_axis;
                            index = nothing, vertex_column = nothing,
                            partway = nothing, tc = nothing)
    stage = "_ddm_support_moment"
    if !_eq137_geometry_available(struc) || col_vertex_idx(col) <= 0
        _eq137_trace_fallback(tc, col, :no_geometry; stage = stage)
        return nothing
    end
    pw = _eq137_partway_at(struc, col, vertex_column, partway)
    if _eq137_nonfinite_at(pw, col)
        # ENGINEERING JUDGMENT: a non-finite vertex cannot be placed, so the
        # class cannot be read.  Flexure takes the larger of the §13.6.3.3
        # interior and exterior moments (corpus: aci-318-11, page 254); the
        # transfer moment at this column is NaN (`_eq137_transfer_moment`),
        # which rejects the connection.
        _eq137_trace_fallback(tc, col, :non_finite_vertex; stage = stage, event = :failure)
        return :envelope
    end
    idx = index === nothing ? _eq137_vertex_cell_index(struc; partway = pw) : index
    panels = _eq137_side_panels(struc, col, span_axis, idx)
    if panels === nothing
        _eq137_trace_fallback(tc, col, :no_geometry; stage = stage)
        return nothing
    end
    nsides = length(unique(p.side for p in panels))
    return _eq137_support_class(struc, col, span_axis, idx, vertex_column, nsides;
                                partway = pw, tc = tc, stage = stage)
end

"""
Eq. (13-7) at one column.  `M0` is required for the edge and re-entrant
transfers; without it those cases return 0.  Two continuous sides do not
use `M0`.
"""
function _interior_mub_for_column(struc, slab, col, span_axis,
                                  qD::Pressure, qL::Pressure, l2::Length, ln::Length;
                                  c_override=nothing, extra_columns=(),
                                  M0=nothing, γ=nothing, index=nothing,
                                  vertex_column=nothing, cell_slab=nothing,
                                  partway=nothing,
                                  design_drop::Pressure=0.0psf, tc=nothing)
    return _eq137_transfer_moment(
        struc, slab, col, span_axis, qD, qL, l2, ln, M0;
        c_override=c_override, extra_columns=extra_columns, γ=γ, index=index,
        vertex_column=vertex_column, cell_slab=cell_slab, partway=partway,
        design_drop=design_drop, tc=tc,
    )
end


"""
    _compute_column_demands_ddm(struc, columns, M_neg_ext, M_neg_int, M_pos,
                                 qu, qD, qL, l2, ln, span_axis, M0;
                                 slab=nothing, c_override=nothing)

Compute column-level demands for simplified DDM (single panel approach).

For each column:
- Exterior columns: design moment = M_neg_ext (ACI 318-11 §13.6.3.3 end-span
  coefficient × M0, e.g. 0.26 M0 for a flat plate without edge beam).
  Unbalanced *transfer* moment = 0.3 M0 per ACI 318-11 §13.6.3.6.
- Interior columns: design moment = M_neg_int; the *unbalanced* moment
  for punching shear is the live-load-pattern moment from
  ACI 318-11 §13.6.9.2 Eq. (13-7):

      Mu = 0.07·[(qDu + 0.5·qLu)·ℓ2·ℓn² − qDu'·ℓ2'·(ℓn')²]                (13-7)

  where the primed quantities refer to the *shorter* of the two adjacent
  spans.  Each interior column is evaluated from the panels that actually
  share that support along `span_axis` (`_interior_mub_for_column`).
  Eq. (13-7) is taken as the larger of §9.2.1 Eq. (9-1) and Eq. (9-2)
  (`governing_interior_unbalanced_moment`).  Equal adjoining spans
  collapse to Mu = 0.07·0.5·q_Lu·ℓ2·ℓn² under Eq. (9-2).  Two candidate
  panels on the same side that disagree throw `ArgumentError`.

`M0` is the total factored static moment already computed for this panel
from the same `qu`, `l2`, `ln` via ACI 318-11 §13.6.2.2 Eq. (13-4)
(M0 = qu ℓ2 ℓn² / 8).  It is reused, not recomputed.

# Interpretation (column design moment vs transfer moment)

ACI 318-11 §13.6.3.6 states: "The gravity load moment to be transferred
between slab and edge column in accordance with 13.5.3.1 shall be 0.3 Mo."
§13.5.3.1 is the slab-column *connection* transfer (γf by flexure, γv by
eccentric shear / punching).  PCA Notes (EB712, Part 16 p.483 and Part 19
p.555) apply 0.3 Mo only to that transfer check, while slab flexure remains
the §13.6.3.3 exterior-negative coefficient (0.26 Mo without edge beam).

ENGINEERING JUDGMENT: `column_moments` (column/slab flexural design) is
kept as M_neg_ext per §13.6.3.3.  `unbalanced_moments` (connection transfer
/ punching) is 0.3 M0 per §13.6.3.6.  Interior Eq. (13-7) is unchanged.
Do **not** use 0.3 Mo for interior columns (exterior §13.6.3.6 only).

# References
- ACI 318-11 §13.6.2.2 / Eq. (13-4) (corpus: aci-318-11, page 253)
- ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254)
- ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255)
- ACI 318-11 §13.5.3.1 (corpus: aci-318-11, page 250)
- ACI 318-11 §13.6.9.2 / Eq. (13-7) (corpus: aci-318-11, page 258)
- PCA EB712 Part 16 (corpus: pca-eb712, page 483) and Part 19 (page 555)
"""
function _compute_column_demands_ddm(struc, columns, M_neg_ext, M_neg_int, M_pos,
                                     qu, qD, qL, l2, ln, span_axis, M0;
                                     slab = nothing,
                                     c_override = nothing,
                                     γ = nothing,
                                     design_drop::Pressure = 0.0psf,
                                     tc = nothing,
                                     ctx = nothing)
    column_moments = Vector{typeof(1.0kip*u"ft")}()
    column_shears = Vector{typeof(1.0kip)}()
    unbalanced_moments = Vector{typeof(1.0kip*u"ft")}()

    # Cell→slab and vertex→column maps, once per analysis call.
    context = ctx === nothing ? _eq137_context(struc, columns) : ctx
    partway = hasproperty(context, :partway) ? context.partway : nothing

    for col in columns
        # Flexural (§13.6.3.3) and transfer moments share one continuity
        # test along `span_axis` (`_eq137_support_class`): interior-negative
        # and Eq. (13-7) where the slab continues on both sides,
        # exterior-negative and 0.3 M0 where it does not.
        M = _ddm_support_moment(struc, col, span_axis, M_neg_ext, M_neg_int;
                                index = context.index,
                                vertex_column = context.vertex_column,
                                partway = partway, tc = tc)
        Mub = _eq137_transfer_moment(
            struc, slab, col, span_axis, qD, qL, l2, ln, M0;
            c_override = c_override, extra_columns = columns,
            index = context.index, vertex_column = context.vertex_column,
            cell_slab = context.cell_slab, partway = partway,
            design_drop = design_drop, γ = γ, tc = tc,
        )

        push!(column_moments, uconvert(kip*u"ft", M))
        push!(unbalanced_moments, uconvert(kip*u"ft", Mub))

        Vu = _compute_column_shear(struc, col, qu, l2, ln)
        push!(column_shears, Vu)
    end

    return column_moments, column_shears, unbalanced_moments
end

"""
    _compute_column_demands_from_spans(struc, sorted_columns, column_is_exterior,
                                        span_moments, qu, qD, qL, l2)

Compute column-level demands from per-span DDM moments (multi-span version).

The flexural moments come from `span_moments`, whose span-end coefficients
the caller chose from each support's class (`_ddm_support_class` in the
FrameLine `run_moment_analysis`), so a column gets the exterior- or
interior-negative moment by the same rule as the single-panel DDM.

The transfer moment follows each support's class, as in the cell path
(`_eq137_transfer_moment`).  `column_is_exterior` holds the classes
(`:interior`, `:exterior`, `:envelope`); a `Bool` entry is read as
`:exterior` (true) or `:interior` (false).

For each column:
- End columns: design moment = M_neg from the adjacent span (§13.6.3.3).
  `:exterior`: transfer moment = 0.3 M0 of that adjacent end span
  (ACI 318-11 §13.6.3.6), where M0 is the span's already-computed
  Eq. (13-4) static moment (`span_moments[i].M0`).  `:interior` or
  `:envelope`: the slab continues beyond the frame end, and the span beyond
  is resolved from panel geometry (`_frameline_end_transfer`); without
  geometry the result is NaN with a `:failure` trace event.
- Columns between two spans: design moment = max of M_neg from the two
  adjacent spans.  `:exterior`: 0.3 M0 (`_frameline_middle_edge_moment`).
  `:envelope`: the larger of Eq. (13-7) and 0.3 M0.  `:interior`:
  unbalanced moment per ACI 318-11 §13.6.9.2 Eq. (13-7) using the actual ℓn
  of the longer / shorter adjacent span.  Service `qD`/`qL` are factored
  under both §9.2.1 Eq. (9-1) and Eq. (9-2) and the larger Mu is kept
  (`governing_interior_unbalanced_moment`):

      Mu = 0.07·[(qDu + 0.5·qLu)·ℓ2·ℓn² − qDu'·ℓ2'·(ℓn')²]               (13-7)

  where the primed quantities refer to the *shorter* of the two adjacent
  spans.  In this multi-span path ℓ2 is constant across spans (one tributary
  width is used for the whole frame) but ℓn may vary; both bays carry the
  frame's `qD`/`qL`.  Do not pass only the combination that maximises `q_u`.
- A column flagged non-finite by the neighbourhood index
  (`_eq137_nonfinite_at`) gets a NaN transfer moment with a `:failure`
  trace event (`non_finite_vertex`), as in the cell path.

# Interpretation

Same split as `_compute_column_demands_ddm`: `column_moments` stay the
§13.6.3.3 flexural assignment; `unbalanced_moments` at exterior columns
are the §13.6.3.6 transfer moment 0.3 M0.  See that function's docstring.
Do **not** use 0.3 Mo for interior columns.

# Arguments
- `struc`: BuildingStructure (for tributary area lookup)
- `sorted_columns`: Columns ordered along span axis
- `column_is_exterior`: support class (or Bool) for each column (already applied to `span_moments`)
- `span_moments`: Vector of per-span moment results (includes `M0`)
- `qu`, `qD`, `qL`: Factored total, service dead, and service live pressures
- `l2`: Tributary width
- `span_axis`: frame direction (needed to resolve geometry); `ctx`: `_eq137_context`
  or `nothing` without geometry; `tc`: optional trace collector
- `γ`: concrete density for neighbour self-weight and drop panels beyond a
  continuous frame end (`_frameline_end_transfer`); `design_drop`: the design
  slab's service drop pressure already included in `qD`
- A negative service `qD` or `qL` is invalid input (§13.6.1.5, gravity
  loads): every transfer moment is NaN with a `:failure` trace event
  (`negative_service_load`)
- A negative or non-finite span `ln` is invalid input: the transfer moment
  of every column adjoining that span (end or middle) is NaN with a
  `:failure` trace event (`negative_span`)

# References
- ACI 318-11 §13.6.2.2 / Eq. (13-4) (corpus: aci-318-11, page 253)
- ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255)
- ACI 318-11 §13.5.3.1 (corpus: aci-318-11, page 250)
- ACI 318-11 §13.6.9.2 / Eq. (13-7) (corpus: aci-318-11, page 258)
"""
function _compute_column_demands_from_spans(struc, sorted_columns, column_is_exterior,
                                            span_moments, qu, qD, qL, l2;
                                            span_axis = nothing, ctx = nothing,
                                            γ = nothing,
                                            design_drop::Pressure = 0.0psf,
                                            tc = nothing)
    n_cols = length(sorted_columns)
    column_moments = Vector{typeof(1.0kip*u"ft")}()
    column_shears = Vector{typeof(1.0kip)}()
    unbalanced_moments = Vector{typeof(1.0kip*u"ft")}()
    classes = [c isa Symbol ? c : (c ? :exterior : :interior) for c in column_is_exterior]
    stage = "_compute_column_demands_from_spans"
    negative_load = _eq137_negative_input(qD, qL)

    function nonfinite_failure(col)
        (ctx === nothing || ctx.partway === nothing) && return false
        _eq137_nonfinite_at(ctx.partway, col) || return false
        _eq137_trace_fallback(tc, col, :non_finite_vertex; stage = stage, event = :failure)
        return true
    end

    # A negative or non-finite clear span is invalid frame input; every
    # column it adjoins gets a NaN transfer moment (`transfer_section_inadequate`).
    bad_span(sm) = !isfinite(ustrip(u"ft", sm.ln)) || sm.ln < zero(sm.ln)
    function span_failure(col, spans...)
        any(bad_span, spans) || return false
        _eq137_trace_fallback(tc, col, :negative_span; stage = stage, event = :failure)
        return true
    end

    for (i, col) in enumerate(sorted_columns)
        cls = classes[i]
        bad_geometry = nonfinite_failure(col)
        if i == 1 || i == n_cols
            # End column.  Its frame span lies on side +1 of `span_axis` for
            # the first column and −1 for the last (columns are sorted
            # along the frame direction).
            sm = i == 1 ? span_moments[1] : span_moments[end]
            M = i == 1 ? sm.M_neg_left : sm.M_neg_right
            bad_geometry |= span_failure(col, sm)
            Mub = if negative_load
                _eq137_negative_load_failure(tc, col, stage)
            elseif bad_geometry
                NaN * kip * u"ft"
            elseif cls == :exterior
                # ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255):
                # 0.3 M0 of the adjacent end span.
                0.3 * sm.M0
            else
                _frameline_end_transfer(struc, col, span_axis, i == 1 ? 1 : -1,
                                        qD, qL, l2, sm.ln, sm.M0, sorted_columns, ctx;
                                        γ = γ, design_drop = design_drop, tc = tc)
            end
            ln_for_shear = sm.ln
        else
            # span_moments[i-1] is the span to the LEFT (side −1),
            # span_moments[i] to the RIGHT (side +1).
            M_from_left_span  = span_moments[i-1].M_neg_right
            M_from_right_span = span_moments[i].M_neg_left
            M = max(M_from_left_span, M_from_right_span)

            ln_left  = span_moments[i-1].ln
            ln_right = span_moments[i].ln
            bad_geometry |= span_failure(col, span_moments[i-1], span_moments[i])
            # ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258)
            # under both §9.2.1 Eq. (9-1) and Eq. (9-2) (page 123).
            Mu137() = governing_interior_unbalanced_moment(
                qD, qL, l2, ln_left, qD, qL, l2, ln_right)
            Mub = if negative_load
                _eq137_negative_load_failure(tc, col, stage)
            elseif bad_geometry
                NaN * kip * u"ft"
            elseif cls == :interior
                Mu137()
            elseif cls == :exterior
                _frameline_middle_edge_moment(struc, col, span_axis,
                                              span_moments[i-1].M0, span_moments[i].M0,
                                              ctx; tc = tc)
            else
                # `:envelope` (re-entrant corner or ambiguous neighbourhood), as
                # in `_eq137_transfer_moment`: the larger of Eq. (13-7) and
                # §13.6.3.6 0.3 M0 (corpus: aci-318-11, page 255).
                # ENGINEERING JUDGMENT: the exterior side is not known, so
                # 0.3 M0 is taken from the larger adjoining span.
                max(uconvert(kip * u"ft", Mu137()),
                    uconvert(kip * u"ft", 0.3 * max(span_moments[i-1].M0, span_moments[i].M0)))
            end

            ln_for_shear = (ln_left + ln_right) / 2
        end

        push!(column_moments, uconvert(kip*u"ft", M))
        push!(unbalanced_moments, uconvert(kip*u"ft", Mub))

        Vu = _compute_column_shear(struc, col, qu, l2, ln_for_shear)
        push!(column_shears, Vu)
    end

    return column_moments, column_shears, unbalanced_moments
end

TRACE_REGISTRY[(:_compute_column_demands_from_spans, :slab)] = TracedFunctionMeta(
    :_compute_column_demands_from_spans, :slab, [:fallback, :failure], nothing,
    @__FILE__, @__LINE__,
)

"""
§13.6.3.6 transfer at a FrameLine middle column classed `:exterior`
(ACI 318-11, corpus: aci-318-11, page 255): 0.3 M0 of the frame span on
the side where the vertex-adjacent panels lie (`_eq137_side_panels`).
"""
function _frameline_middle_edge_moment(struc, col, span_axis, M0_left, M0_right, ctx;
                                       tc = nothing)
    if span_axis !== nothing && ctx !== nothing && ctx.index !== nothing
        axis = (Float64(span_axis[1]), Float64(span_axis[2]))
        panels = _eq137_side_panels(struc, col, axis, ctx.index)
        if panels !== nothing
            sides = unique(p.side for p in panels)
            length(sides) == 1 && return 0.3 * (only(sides) == 1 ? M0_right : M0_left)
        end
    end
    # ENGINEERING JUDGMENT: panel geometry does not say which frame span the
    # slab is on, so 0.3 M0 is taken from the larger adjoining span.
    _eq137_trace_fallback(tc, col, :frameline_exterior_side_unknown;
                          stage = "_compute_column_demands_from_spans")
    return 0.3 * max(M0_left, M0_right)
end

"""
Transfer moment at a FrameLine end column classed `:interior` or
`:envelope`: the slab continues beyond the frame end, so the span beyond is
not in the FrameLine.

With skeleton geometry this is the cell path (`_eq137_transfer_moment`) at
that column along `span_axis`, so both adjoining spans are resolved from the
panels exactly as in the single-panel DDM, with the frame span's `qD`,
`ℓ2`, `ℓn` and `M0` as the panel in hand.  `inner` is the side (+1 / −1) of
`span_axis` on which the frame span lies; the owning slab of those cells is
the design slab (a stand-in holding only those cells when no slab owns
them), so their trial self-weight comes from `qD`.  `γ` (concrete density)
and `design_drop` (the design slab's service drop pressure, already in
`qD`) are passed through as in the cell path, so a neighbour slab beyond
the frame end is charged its own result thickness and drop panel
(`_eq137_neighbour_sw`, `_eq137_neighbour_drop`).

Without geometry that places the column, the span beyond cannot be
resolved: a `:failure` trace event (`frameline_end_beyond_span_unresolved`)
is emitted and NaN is returned, which `transfer_section_inadequate` rejects.
Geometry that places the column but whose sides are ambiguous
(`ArgumentError` from `_eq137_resolved_sides`) likewise returns NaN with a
`:failure` trace event (`adjoining_spans_unresolved`).
"""
function _frameline_end_transfer(struc, col, span_axis, inner::Int,
                                 qD, qL, l2, ln, M0, frame_columns, ctx;
                                 γ = nothing, design_drop::Pressure = 0.0psf,
                                 tc = nothing)
    sides = nothing
    axis = nothing
    if span_axis !== nothing && ctx !== nothing && ctx.index !== nothing
        axis = (Float64(span_axis[1]), Float64(span_axis[2]))
        sides = try
            _eq137_resolved_sides(struc, nothing, col, axis;
                                  extra_columns = frame_columns, index = ctx.index,
                                  vertex_column = ctx.vertex_column,
                                  partway = ctx.partway)
        catch e
            e isa ArgumentError || rethrow()
            # Ambiguous geometry (§13.6.9.2, corpus: aci-318-11, page 258):
            # rejected as in `_eq137_transfer_moment`, never an abort.
            _eq137_trace_fallback(tc, col, :adjoining_spans_unresolved;
                                  stage = "_compute_column_demands_from_spans",
                                  event = :failure)
            return NaN * kip * u"ft"
        end
    end
    if sides === nothing
        # ENGINEERING JUDGMENT: neither §13.6.3.6 (0.3 M0, an edge column) nor
        # Eq. (13-7) with an assumed span beyond is grounded for a column the
        # slab continues past, so the transfer demand is left undefined and
        # the connection is rejected rather than sized on a guess.
        _eq137_warn_once(:frameline_end_unresolved,
            "FrameLine end column is classed continuous but the span beyond the frame end cannot be resolved without skeleton geometry; its transfer moment is undefined and the connection is rejected.")
        _eq137_trace_fallback(tc, col, :frameline_end_beyond_span_unresolved;
                              stage = "_compute_column_demands_from_spans",
                              event = :failure)
        return NaN * kip * u"ft"
    end
    k = findfirst(s -> s.side == inner, sides)
    slab = nothing
    if !isempty(sides)
        own = sides[something(k, 1)]
        slab = something(_eq137_owning_slab(ctx.cell_slab, struc, own.cell_index),
                         (cell_indices = own.cell_indices,))
    end
    return _eq137_transfer_moment(
        struc, slab, col, axis, qD, qL, l2, ln, M0;
        extra_columns = frame_columns, index = ctx.index,
        vertex_column = ctx.vertex_column, cell_slab = ctx.cell_slab,
        partway = ctx.partway, design_drop = design_drop, γ = γ, tc = tc,
    )
end

# _compute_column_shear is defined in common.jl (shared between DDM and EFM)

# =============================================================================
# DDM Applicability Check - ACI 318-11 §13.6.1
# =============================================================================

"""
    DDMApplicabilityError <: Exception

Error thrown when DDM is not applicable for the given geometry/loading.

# Fields
- `violations`: List of ACI 318-11 §13.6.1 conditions that are violated
- `alternatives`: List of alternative methods that ARE valid for this geometry
"""
struct DDMApplicabilityError <: Exception
    violations::Vector{String}
    alternatives::Vector{String}
end

"""Construct a `DDMApplicabilityError` with an empty alternatives list."""
DDMApplicabilityError(violations::Vector{String}) = DDMApplicabilityError(violations, String[])

"""Print a human-readable error listing the violated conditions and suggested alternatives."""
function Base.showerror(io::IO, e::DDMApplicabilityError)
    # A throw that is only Eq. (13-7) geometry is not a §13.6.1
    # applicability failure.  Mixed violations keep the §13.6.1 header.
    # A non-positive clear span is its own failure, not ambiguous geometry.
    geom_only = !isempty(e.violations) && all(v ->
        occursin("13.6.9.2", v) && !occursin("13.6.1", v), e.violations)
    is_clear_span(v) = occursin("non-positive", v)
    if geom_only && all(is_clear_span, e.violations)
        println(io, "DDM cannot evaluate Eq. (13-7): column faces consume the clear span (ACI 318-11 §13.6.2.5 and §13.6.9.2, corpus: aci-318-11, pages 253 and 258):")
    elseif geom_only && any(is_clear_span, e.violations)
        println(io, "DDM cannot evaluate Eq. (13-7): frame-line geometry is ambiguous and column faces consume a clear span (ACI 318-11 §13.6.2.5 and §13.6.9.2, corpus: aci-318-11, pages 253 and 258):")
    elseif geom_only
        println(io, "DDM cannot evaluate Eq. (13-7): frame-line geometry is ambiguous (ACI 318-11 §13.6.9.2, corpus: aci-318-11, page 258):")
    else
        println(io, "DDM (Direct Design Method) is not permitted for this slab per ACI 318-11 §13.6.1:")
    end
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
ACI 318-11 §13.6.1.3 (corpus: aci-318-11, page 252) violations.

Successive span lengths center-to-center of supports in each direction
shall not differ by more than one-third the longer span.  Pairs come
from the same per-column panel lookup as Eq. (13-7); only sides that end
at a far column are spans, so a slab overhang or cantilever beyond an edge
column (`:boundary` side) is not compared.  Returns an empty
vector when geometry is unavailable (nothing to compare).  Ambiguous
frame-line geometry keeps its §13.6.9.2 message; it is not relabeled as
a §13.6.1.3 violation.
"""
function _successive_span_violations(struc, slab, columns)::Vector{String}
    out = String[]
    _eq137_geometry_available(struc) || return out
    (isnothing(slab) || !hasproperty(slab, :spans)) && return out
    span_axis = _get_span_axis(slab)
    perp_axis = (-span_axis[2], span_axis[1])
    seen = Set{Tuple{Int,Int}}()
    ctx = _eq137_context(struc, columns)
    index = ctx.index
    for col in columns
        col_vertex_idx(col) > 0 || continue
        for ax in (span_axis, perp_axis)
            sides = try
                _eq137_resolved_sides(struc, slab, col, ax;
                                      extra_columns=columns, index=index,
                                      vertex_column=ctx.vertex_column,
                                      partway=ctx.partway)
            catch e
                if e isa ArgumentError
                    # Honest Eq. (13-7) message.  Do not prefix §13.6.1.3.
                    push!(out, sprint(showerror, e))
                    continue
                end
                rethrow()
            end
            sides === nothing && continue
            # Spans are center-to-center of supports: a side with no far
            # column (`:boundary` — slab edge overhang or cantilever) is not a span.
            spans = [s for s in sides if s.status !== :boundary]
            length(spans) < 2 && continue
            la, lb = spans[1].l_cc, spans[2].l_cc
            # ACI 318-11 §13.6.1.3 (corpus: aci-318-11, page 252):
            # successive center-to-center spans shall not differ by more
            # than one-third the longer span.
            longer = max(la, lb)
            diff = abs(la - lb)
            diff > longer / 3 || continue
            key = (
                round(Int, ustrip(u"ft", min(la, lb)) * 100),
                round(Int, ustrip(u"ft", max(la, lb)) * 100),
            )
            key in seen && continue
            push!(seen, key)
            push!(out,
                "§13.6.1.3: Successive span lengths center-to-center differ by " *
                "$(round(ustrip(u"ft", diff), digits=2)) ft > one-third of the longer span " *
                "($(round(ustrip(u"ft", longer / 3), digits=2)) ft) " *
                "[$(round(ustrip(u"ft", la), digits=2)) ft vs $(round(ustrip(u"ft", lb), digits=2)) ft] " *
                "(corpus: aci-318-11, page 252)")
        end
    end
    return out
end

# ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252): offset limit as a
# fraction of the span.  Commentary R13.6.1.4 (page 252) adds a cumulative
# 20% limit; that is not checked here.
const _DDM_OFFSET_LIMIT_FRAC = 0.10

# ENGINEERING JUDGMENT: column-line membership for §13.6.1.4 (page 252).
# A column ahead of column `i` along an axis is measured against the
# transverse column-line spacing `s` on its side of `i` (the perpendicular
# distance to the nearest column across from `i`, `_ddm_line_spacing_m`).
# At |perp| < 0.25·s it is on `i`'s column line; at 0.25·s to 0.75·s it lies
# between two lines without clearly belonging to either, and it is still
# treated as on `i`'s line (fail closed: its offset is checked, so DDM is
# not applicable when that offset exceeds 10% of the span); beyond 0.75·s it
# is on the adjacent column line and is checked against that line instead.
# A column offset from its own line is therefore seen whatever the size of
# the offset.  When `i` has no column across from it on that side (the outer
# line of the plan) the spacing on its other side is used; with none on
# either side (a single line) `s` is the span from `i` to the nearest column
# ahead, i.e. a square panel: a column more than 75% of that span off the
# line is then a lone column of another line (a missing column or an L-plan
# end, a §13.6.1.3 span matter), not an offset.
const _DDM_LINE_MEMBER_FRAC = 0.25
const _DDM_LINE_OTHER_FRAC = 0.75

# ENGINEERING JUDGMENT: columns closer in plan than 0.25 × the typical
# column spacing (median nearest-neighbour distance) form one support group
# (twin or doubled columns, e.g. at an expansion joint) and are never each
# other's successive column.  §13.6.1.2 and §13.6.1.3 (page 252) keep every
# DDM span above about one third of the typical spacing, so a genuine span
# is not grouped.
const _DDM_OFFSET_TWIN_FRAC = 0.25

"""
Span (meters) against which a §13.6.1.4 offset is measured, for two
successive columns whose structural centerlines differ by `s` (meters),
along the unit axis `ax`.

ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252): "a maximum of 10
percent of the span (in direction of offset)".  Read here as the
center-to-center distance between the successive columns measured along
the frame line (`ax`), as before.  The alternative reading (the span in the
direction of the offset, i.e. perpendicular to the frame line) is an open
question with the user; switch it here only.
"""
_ddm_offset_span_m(s::NTuple{2,Float64}, ax::NTuple{2,Float64}) =
    abs(s[1] * ax[1] + s[2] * ax[2])

"""
    _ddm_column_successors(struc, columns, span_axis)

Successive column of every column along `span_axis` and along its
perpendicular, from structural centerlines (meters), for the §13.6.1.4
offset check (`_column_offset_violations`) and the §13.6.1.2 panel spans
(`_panel_aspect_violations`).  ENGINEERING JUDGMENT, see the constants
above:

- Support groups: columns closer in plan than `_DDM_OFFSET_TWIN_FRAC` ×
  the median nearest-neighbour spacing (neighbours under
  `_EQ137_FAR_MIN_ALONG_M` are the same support and are not counted) are
  one support group (twins).  A twin is never the successive column; each
  twin is still checked against its own successive column, so grouping
  cannot hide an offset.
- Candidates are at least `_EQ137_FAR_MIN_ALONG_M` ahead along the axis.
  A candidate whose perpendicular offset exceeds `_DDM_LINE_OTHER_FRAC` ×
  the transverse column-line spacing on its side (`_ddm_line_spacing_m`;
  else the spacing on the other side; else the span to the nearest column
  ahead) is on the adjacent column line; every other candidate is on this line,
  including one between lines (`_DDM_LINE_MEMBER_FRAC` to
  `_DDM_LINE_OTHER_FRAC` of the spacing, fail closed).
- The successive column is the nearest (plan distance) candidate on this
  line.

Returns `nothing` for a degenerate axis.  Otherwise `(sxy, ok, lines)`:
`ok` are the columns with finite coordinates, and each entry of `lines`
is `(ax, perp, succ)` with `succ[i] = (j, spacing_m, between)` for every
column `i` that has a successive column `j`; `between` is true for a
column between lines.
"""
function _ddm_column_successors(struc, columns, span_axis)
    axes = _eq137_unit_axes((Float64(span_axis[1]), Float64(span_axis[2])))
    axes === nothing && return nothing
    sxy = [_eq137_structural_xy(struc, c) for c in columns]
    ok = [k for k in eachindex(columns) if all(isfinite, sxy[k])]
    dist(a, b) = hypot(sxy[b][1] - sxy[a][1], sxy[b][2] - sxy[a][2])
    nn = Float64[]
    for a in ok
        dmin = minimum((dist(a, b) for b in ok if dist(a, b) >= _EQ137_FAR_MIN_ALONG_M);
                       init = Inf)
        isfinite(dmin) && push!(nn, dmin)
    end
    twin_m = isempty(nn) ? 0.0 : _DDM_OFFSET_TWIN_FRAC * sort(nn)[(length(nn) + 1) ÷ 2]
    group = Dict(a => [b for b in ok if b == a || dist(a, b) < twin_m] for a in ok)
    lines = Tuple{NTuple{2,Float64},NTuple{2,Float64},Dict{Int,Tuple{Int,Float64,Bool}}}[]
    for ax in (axes[1], axes[2])
        perp = (-ax[2], ax[1])
        along_of(a, b) = (sxy[b][1] - sxy[a][1]) * ax[1] + (sxy[b][2] - sxy[a][2]) * ax[2]
        perp_of(a, b) = (sxy[b][1] - sxy[a][1]) * perp[1] + (sxy[b][2] - sxy[a][2]) * perp[2]
        succ = Dict{Int,Tuple{Int,Float64,Bool}}()
        for i in ok
            ahead = [j for j in ok if !(j in group[i]) && along_of(i, j) >= _EQ137_FAR_MIN_ALONG_M]
            isempty(ahead) && continue
            span_m = minimum(along_of(i, j) for j in ahead)
            spacing = Dict(σ => _ddm_line_spacing_m(i, σ, ok, group, along_of, perp_of, dist)
                           for σ in (1, -1))
            side_spacing(σ) = !isnan(spacing[σ]) ? spacing[σ] :
                              !isnan(spacing[-σ]) ? spacing[-σ] : span_m
            best = (Inf, 0, 0.0, false)
            for j in ahead
                p = perp_of(i, j)
                s = side_spacing(p >= 0 ? 1 : -1)
                abs(p) > _DDM_LINE_OTHER_FRAC * s && continue
                d = dist(i, j)
                d < best[1] && (best = (d, j, s, abs(p) >= _DDM_LINE_MEMBER_FRAC * s))
            end
            best[2] > 0 && (succ[i] = (best[2], best[3], best[4]))
        end
        push!(lines, (ax, perp, succ))
    end
    return (sxy = sxy, ok = ok, lines = lines)
end

"""
Transverse column-line spacing (meters) on side `σ` (±1 along the
perpendicular) of column `i`: the perpendicular distance to the nearest
(plan distance) column across from `i`, i.e. at least
`_EQ137_FAR_MIN_ALONG_M` off on that side and more across than along
(|perp| > |along|), twins excluded.  `NaN` when there is none.  A column
offset by less than its span from a line is never across from that line's
columns, so it does not shorten the spacing it is measured against.
"""
function _ddm_line_spacing_m(i, σ, ok, group, along_of, perp_of, dist)::Float64
    best_d = Inf
    s = NaN
    for k in ok
        k in group[i] && continue
        p = perp_of(i, k)
        σ * p >= _EQ137_FAR_MIN_ALONG_M || continue
        abs(p) > abs(along_of(i, k)) || continue
        d = dist(i, k)
        d < best_d && (best_d = d; s = abs(p))
    end
    return s
end

"""
ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252) violations: "Offset of
columns by a maximum of 10 percent of the span (in direction of offset)
from either axis between centerlines of successive columns shall be
permitted."

Successive columns along `span_axis` and its perpendicular come from
`_ddm_column_successors` (column-line membership by the transverse
column-line spacing).  The pair is flagged when its offset exceeds 10% of
the span (`_ddm_offset_span_m`); a column between two column lines says
so in the message.  No successive column (a line end, or a missing column
with no in-line column further ahead) is not an offset: span regularity is
§13.6.1.3 (`_successive_span_violations`).
"""
function _column_offset_violations(struc, columns, span_axis)::Vector{String}
    out = String[]
    res = _ddm_column_successors(struc, columns, span_axis)
    res === nothing && return out
    sxy = res.sxy
    for (ax, perp, succ) in res.lines, i in res.ok
        haskey(succ, i) || continue
        j, spacing, between = succ[i]
        d = sxy[j] .- sxy[i]
        span = _ddm_offset_span_m(d, ax)
        offset = abs(d[1] * perp[1] + d[2] * perp[2])
        limit = _DDM_OFFSET_LIMIT_FRAC * span
        offset > limit || continue
        note = between ?
            "; it lies between column lines ($(round(100 * offset / spacing, digits=1))% " *
            "of the $(round(spacing, digits=2)) m transverse spacing) and is checked " *
            "against this line" : ""
        push!(out,
            "§13.6.1.4: Column $(j) offset $(round(offset, digits=2)) m " *
            "($(round(100 * offset / span, digits=1))% of the $(round(span, digits=2)) m span) " *
            "from the axis through column $(i) > 10% of the span " *
            "($(round(limit, digits=2)) m)$(note) (corpus: aci-318-11, page 252)")
    end
    return out
end

# ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252): "ratio of longer to
# shorter span center-to-center of supports within a panel not greater
# than 2."  The 1e-9 relative allowance is float tolerance only, so a
# panel at exactly 2 built from rounded coordinates is not rejected.
const _DDM_PANEL_ASPECT_MAX = 2.0
const _DDM_PANEL_ASPECT_RTOL = 1e-9

"""
ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252) panel aspect-ratio
violations from the column layout: "Panels shall be rectangular, with a
ratio of longer to shorter span center-to-center of supports within a
panel not greater than 2."

The panel at column `i` is bounded by `i`, its successive column along the
span axis and its successive column along the perpendicular
(`_ddm_column_successors`).  Its spans are the center-to-center distances
to those columns measured along each axis (`_ddm_offset_span_m`).  A panel
is checked only when its center lies inside one of the slab's cells, so a
void (courtyard, re-entrant corner) between columns is not a panel.
Empty without skeleton geometry; the slab-span check in
`check_ddm_applicability` still applies.
"""
function _panel_aspect_violations(struc, slab, columns, span_axis)::Vector{String}
    out = String[]
    _eq137_geometry_available(struc) || return out
    hasproperty(slab, :cell_indices) || return out
    res = _ddm_column_successors(struc, columns, span_axis)
    res === nothing && return out
    polys = [p for p in (_eq137_cell_poly_m(struc, ci) for ci in slab.cell_indices)
             if p !== nothing && length(p) >= 3]
    isempty(polys) && return out
    (ax, _, succ_a), (pax, _, succ_p) = res.lines
    sxy = res.sxy
    seen = Set{Tuple{Int,Int}}()
    for i in res.ok
        (haskey(succ_a, i) && haskey(succ_p, i)) || continue
        ja, jp = succ_a[i][1], succ_p[i][1]
        la = _ddm_offset_span_m(sxy[ja] .- sxy[i], ax)
        lp = _ddm_offset_span_m(sxy[jp] .- sxy[i], pax)
        centre = (sxy[i][1] + (la * ax[1] + lp * pax[1]) / 2,
                  sxy[i][2] + (la * ax[2] + lp * pax[2]) / 2)
        any(p -> _eq137_point_in_poly(centre, p), polys) || continue
        ratio = max(la, lp) / min(la, lp)
        ratio > _DDM_PANEL_ASPECT_MAX * (1 + _DDM_PANEL_ASPECT_RTOL) || continue
        key = (round(Int, 100 * min(la, lp)), round(Int, 100 * max(la, lp)))
        key in seen && continue
        push!(seen, key)
        push!(out,
            "§13.6.1.2: Panel at column $(i): longer / shorter span center-to-center = " *
            "$(round(ratio, digits=2)) > 2 [$(round(la, digits=2)) m × $(round(lp, digits=2)) m] " *
            "(corpus: aci-318-11, page 252)")
    end
    return out
end

"""
Why polygon `poly` (meters) is not a rectangular panel, or `nothing`.

ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252): "Panels shall be
rectangular".  ENGINEERING JUDGMENT, tolerance consistent with §13.6.1.4
(page 252), which permits offsets of columns up to 10% of the span between
successive columns: a panel is rectangular when it has four corners
(vertices turning by at least 45°; collinear mesh vertices are not corners)
of one turning sense and, in some orthogonal frame, every corner-to-corner
edge alternates between the frame's two directions with every vertex along
it within 10% of the edge length (`_DDM_OFFSET_LIMIT_FRAC`) of the line
through its start corner.  So a panel whose corners are within the
permitted offsets is not also rejected here; one beyond them is both an
offset (§13.6.1.4) and a non-rectangular panel (§13.6.1.2).  The frames
tried are `ax` (the span axis) and the best-fit orientation of the corner
edges (circular mean of their directions modulo 90°), so the test does not
depend on the panel's orientation in plan.  Commentary R13.6.1.4 (page 252)
describes the permitted offsets as "from a regular rectangular array", so
the frame is the array's; as a consequence an interior angle may differ
from 90° by up to 2·atan(0.10) ≈ 11.4° (e.g. a 10° parallelogram, every
edge 8.7% off the array rotated by 5°).  The §13.6.1.4 offset check itself
measures against the span axis and still sees such a skew there.
"""
function _ddm_panel_not_rectangular(poly, ax::NTuple{2,Float64})
    pts = NTuple{2,Float64}[]
    for p in poly
        (isempty(pts) || !_eq137_coincide(p, pts[end])) && push!(pts, (Float64(p[1]), Float64(p[2])))
    end
    length(pts) > 1 && _eq137_coincide(pts[1], pts[end]) && pop!(pts)
    n = length(pts)
    n >= 3 || return "degenerate polygon ($(n) distinct vertices)"
    turn = map(1:n) do k
        a, b, c = pts[mod1(k - 1, n)], pts[k], pts[mod1(k + 1, n)]
        u = (b[1] - a[1], b[2] - a[2])
        v = (c[1] - b[1], c[2] - b[2])
        atan(u[1] * v[2] - u[2] * v[1], u[1] * v[1] + u[2] * v[2])
    end
    corners = [k for k in 1:n if abs(turn[k]) >= π / 4]
    length(corners) == 4 || return "it has $(length(corners)) corners, not 4"
    allequal(sign(turn[k]) for k in corners) || return "it has a re-entrant corner"
    edges = [(corners[e], corners[mod1(e + 1, 4)]) for e in 1:4]
    θs = [atan(pts[b][2] - pts[a][2], pts[b][1] - pts[a][1]) for (a, b) in edges]
    φ = atan(sum(sin(4θ) for θ in θs), sum(cos(4θ) for θ in θs)) / 4
    worst = Inf
    for f in (ax, (cos(φ), sin(φ)))
        g = (-f[2], f[1])
        dirs = Int[]
        frame_worst = 0.0
        for (a, b) in edges
            d = (pts[b][1] - pts[a][1], pts[b][2] - pts[a][2])
            df, dg = abs(d[1] * f[1] + d[2] * f[2]), abs(d[1] * g[1] + d[2] * g[2])
            main, other = df >= dg ? (f, g) : (g, f)
            push!(dirs, df >= dg ? 1 : 2)
            len = max(df, dg)
            k = a
            while true
                k = mod1(k + 1, n)
                q = (pts[k][1] - pts[a][1], pts[k][2] - pts[a][2])
                frame_worst = max(frame_worst, abs(q[1] * other[1] + q[2] * other[2]) / len)
                k == b && break
            end
        end
        all(e -> dirs[e] != dirs[mod1(e + 1, 4)], 1:4) || (frame_worst = Inf)
        worst = min(worst, frame_worst)
    end
    worst <= _DDM_OFFSET_LIMIT_FRAC && return nothing
    isfinite(worst) || return "its edges do not alternate between two orthogonal directions"
    return "a corner or edge vertex is $(round(100 * worst, digits=1))% of the edge length " *
           "off the line through the edge's start corner (> 10%, §13.6.1.4 tolerance)"
end

"""
Column-bounded panels of the layout that are rectangular
(`_ddm_panel_not_rectangular`), as corner polygons (meters).

ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252) speaks of panels
bounded by the supports ("span center-to-center of supports within a
panel"), not of the mesh faces that discretize them.  The panel at column
`i` has corners `i`, its successive column `ja` along the span axis, its
successive column `jp` along the perpendicular (`_ddm_column_successors`),
and the fourth corner `jd`, which must be both the successive column of
`ja` along the perpendicular and of `jp` along the span axis.  Without that
closing column the four columns do not bound one panel and none is
returned for `i`.
"""
function _ddm_rectangular_column_panels(struc, columns, span_axis)
    out = Vector{NTuple{2,Float64}}[]
    res = _ddm_column_successors(struc, columns, span_axis)
    res === nothing && return out
    (ax, _, succ_a), (_, _, succ_p) = res.lines
    sxy = res.sxy
    for i in res.ok
        (haskey(succ_a, i) && haskey(succ_p, i)) || continue
        ja, jp = succ_a[i][1], succ_p[i][1]
        (haskey(succ_p, ja) && haskey(succ_a, jp)) || continue
        jd = succ_p[ja][1]
        jd == succ_a[jp][1] || continue
        poly = [sxy[i], sxy[ja], sxy[jd], sxy[jp]]
        _ddm_panel_not_rectangular(poly, ax) === nothing && push!(out, poly)
    end
    return out
end

"""True when plan point `P` is inside `poly` or within `_EQ137_COINCIDE_M` of its boundary."""
function _ddm_point_in_or_on(P, poly)::Bool
    _eq137_point_in_poly(P, poly) && return true
    n = length(poly)
    return any(_eq137_seg_nearest(P, poly[k], poly[mod1(k + 1, n)])[2] <= _EQ137_COINCIDE_M
               for k in 1:n)
end

"""
ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252) rectangular-panel
violations.  Empty without skeleton geometry.

The verdict does not depend on how the panels are meshed: a slab cell
lying wholly (every corner in or on the boundary) inside a rectangular
column-bounded panel (`_ddm_rectangular_column_panels`, from `columns`) is
part of that panel and is not tested on its own, so a triangulated or
sub-divided regular bay passes as its quad mesh does.  Every other cell
(not inside such a panel, e.g. a panel whose four columns are not
rectangular, a polygonal face with no four-column panel around it, or a
slab overhang beyond the edge columns) must itself be a rectangular panel
(`_ddm_panel_not_rectangular`); one violation is reported per cell that is
not.
"""
function _panel_rectangularity_violations(struc, slab, span_axis;
                                          columns = ())::Vector{String}
    out = String[]
    _eq137_geometry_available(struc) || return out
    hasproperty(slab, :cell_indices) || return out
    axes = _eq137_unit_axes((Float64(span_axis[1]), Float64(span_axis[2])))
    ax = axes === nothing ? (1.0, 0.0) : axes[1]
    panels = length(columns) >= 2 && all(col_vertex_idx(c) > 0 for c in columns) ?
        _ddm_rectangular_column_panels(struc, columns, span_axis) :
        Vector{NTuple{2,Float64}}[]
    for ci in slab.cell_indices
        poly = _eq137_cell_poly_m(struc, ci)
        poly === nothing && continue
        any(pn -> all(p -> _ddm_point_in_or_on(p, pn), poly), panels) && continue
        why = _ddm_panel_not_rectangular(poly, ax)
        why === nothing && continue
        push!(out, "§13.6.1.2: Panel (cell $(ci)) is not rectangular: $(why) " *
                   "(corpus: aci-318-11, page 252)")
    end
    return out
end

"""
    _ddm_continuous_span_counts(struc, columns, span_axis) -> Union{Nothing,NTuple{2,Int}}

Continuous spans along `span_axis` and along its perpendicular.

ACI 318-11 §13.6.1.1 (corpus: aci-318-11, page 252): "There shall be a
minimum of three continuous spans in each direction."  A span is one step
from a column to its successive column on the same line
(`_ddm_column_successors`); the count in a direction is the longest such
run, not the number of columns.  `nothing` when the skeleton cannot place
the columns.
"""
function _ddm_continuous_span_counts(struc, columns, span_axis)::Union{Nothing,NTuple{2,Int}}
    _eq137_geometry_available(struc) || return nothing
    isempty(columns) && return (0, 0)
    all(c -> col_vertex_idx(c) > 0, columns) || return nothing
    res = _ddm_column_successors(struc, columns, span_axis)
    res === nothing && return nothing
    function run(succ)::Int
        best = 0
        for i in res.ok
            n = 0
            v = i
            seen = Set{Int}()
            while haskey(succ, v) && !(v in seen)
                push!(seen, v)
                v = succ[v][1]
                n += 1
            end
            best = max(best, n)
        end
        return best
    end
    return ntuple(k -> run(res.lines[k][3]), 2)
end

"""
    check_ddm_applicability(struc, slab, columns; throw_on_failure=true)

Check if DDM is applicable per ACI 318-11 §13.6.1.

# ACI 318-11 §13.6.1 Limitations (DDM shall be permitted only when):

Clause numbers are ACI 318-11 (corpus: aci-318-11, page 252).

1. **§13.6.1.1** - At least 3 continuous spans in each direction
2. **§13.6.1.2** - Panels are rectangular, longer / shorter span center-to-center ≤ 2
   (from the slab spans and, with skeleton geometry, per panel from the column
   layout and the cell faces: `_panel_aspect_violations`,
   `_panel_rectangularity_violations`)
3. **§13.6.1.3** - Successive span lengths (center-to-center) differ by ≤ 1/3 of the longer span
4. **§13.6.1.4** - Columns are not offset > 10% of span from column lines
5. **§13.6.1.5** - All loads are due to gravity only, uniformly distributed;
   unfactored L ≤ 2 × unfactored D
6. **§13.6.1.6** - For slabs with beams: Eq. (13-2), 0.2 ≤ αf1·l2² / (αf2·l1²) ≤ 5.0

# Arguments
- `struc`: BuildingStructure (for building-level span information)
- `slab`: Slab being designed.  Optional manual override: a Bool field
  `is_rectangular` replaces the geometric rectangular-panel test —
  `false` records a §13.6.1.2 violation, `true` asserts the panels are
  rectangular and skips `_panel_rectangularity_violations` (the user takes
  responsibility).  The aspect-ratio checks always run.
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
        c1_avg = sum(isnothing(col.c1) ? 0.0u"inch" : col.c1 for col in columns) / length(columns)
        ln = clear_span(l1, c1_avg)
        
        ln_min = 4.0u"ft"
        if ln < ln_min
            push!(violations, "Clear span ln = $(round(ustrip(u"ft", ln), digits=2)) ft < $(ustrip(u"ft", ln_min)) ft minimum for two-way slab behavior")
        end
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.2 - Panels shall be rectangular (corpus: aci-318-11, page 252)
    # -------------------------------------------------------------------------
    # Verify valid rectangular geometry (positive orthogonal spans)
    zero_len = 0.0 * unit(l1)
    span_axis = _get_span_axis(slab)
    
    if l1 <= zero_len || l2 <= zero_len
        push!(violations, "§13.6.1.2: Panel must be rectangular; invalid span dimensions l₁=$(l1), l₂=$(l2) (corpus: aci-318-11, page 252)")
    end
    
    # Geometric test of every cell face, unless the slab carries the manual
    # `is_rectangular` override (see the docstring).
    rect_override = hasproperty(slab, :is_rectangular) ? slab.is_rectangular : nothing
    if rect_override === false
        push!(violations, "§13.6.1.2: Panel must be rectangular; slab is marked non-rectangular (is_rectangular = false) (corpus: aci-318-11, page 252)")
    elseif rect_override !== true
        append!(violations, _panel_rectangularity_violations(struc, slab, span_axis;
                                                             columns = columns))
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.2 - Longer / shorter span center-to-center ≤ 2 (page 252)
    # -------------------------------------------------------------------------
    if l1 > zero_len && l2 > zero_len
        ratio = l2 / l1  # dimensionless
        if ratio > 2.0
            push!(violations, "§13.6.1.2: Panel aspect ratio l₂/l₁ = $(round(ratio, digits=2)) > 2.0 (corpus: aci-318-11, page 252)")
        elseif ratio < 0.5
            push!(violations, "§13.6.1.2: Panel aspect ratio l₂/l₁ = $(round(ratio, digits=2)) < 0.5 (inverse > 2.0) (corpus: aci-318-11, page 252)")
        end
    end
    # Per panel from the column layout (center-to-center of supports).
    if length(columns) >= 2 && all(col_vertex_idx(col) > 0 for col in columns)
        append!(violations, _panel_aspect_violations(struc, slab, columns, span_axis))
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.5 - Unfactored L ≤ 2 × unfactored D (corpus: aci-318-11, page 252)
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
            push!(violations, "§13.6.1.5: Live/Dead ratio L/D = $(round(LD_ratio, digits=2)) > 2.0 (using estimated h_min for self-weight) (corpus: aci-318-11, page 252)")
        end
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.1 - Minimum 3 continuous spans in each direction (page 252)
    # -------------------------------------------------------------------------
    # Count successive columns along a line (`_ddm_continuous_span_counts`),
    # not the number of columns.  Four columns can be one span each way.
    counts = _ddm_continuous_span_counts(struc, columns, span_axis)
    if counts === nothing
        push!(violations, "§13.6.1.1: DDM requires a minimum of three continuous spans in each direction; column lines could not be read from this slab (corpus: aci-318-11, page 252)")
    elseif counts[1] < 3 || counts[2] < 3
        push!(violations, "§13.6.1.1: DDM requires a minimum of three continuous spans in each direction; found $(counts[1]) along the span axis and $(counts[2]) transversely (corpus: aci-318-11, page 252)")
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.3 — Successive span lengths, center-to-center of supports,
    # in each direction, shall not differ by more than one-third the
    # longer span (corpus: aci-318-11, page 252).
    # -------------------------------------------------------------------------
    # Same geometry lookup as Eq. (13-7).  Skipped only when the skeleton
    # cannot identify adjoining panels.  A violation is recorded on the same
    # list as the other §13.6.1 checks; it does not introduce a new
    # exception type.  Ambiguous panels are a violation here too — the
    # moment path still throws ArgumentError if analysis is attempted.
    append!(violations, _successive_span_violations(struc, slab, columns))
    
    # -------------------------------------------------------------------------
    # §13.6.1.4 - Column offset ≤ 10% of span (corpus: aci-318-11, page 252)
    # -------------------------------------------------------------------------
    # Successive columns come from column-line membership by the transverse
    # column-line spacing (`_ddm_column_successors`), so an offset from a
    # column's own line is seen whatever its size; twins and columns on
    # another column line are not successive columns.  A missing column is a
    # span-length matter, left to the §13.6.1.3 check above.  The R13.6.1.4
    # cumulative 20% limit (commentary) is not checked.
    if length(columns) >= 2 && all(col_vertex_idx(col) > 0 for col in columns)
        try
            append!(violations, _column_offset_violations(struc, columns, span_axis))
        catch e
            @warn "DDM §13.6.1.4: column offset check skipped — coordinate lookup failed" exception=(e, catch_backtrace())
        end
    end
    
    # -------------------------------------------------------------------------
    # §13.6.1.5 - Gravity loads only, uniformly distributed (page 252)
    # -------------------------------------------------------------------------
    # We assume this is satisfied since our load model is uniform
    # Lateral loads would be handled by a separate system
    
    # -------------------------------------------------------------------------
    # §13.6.1.6 - Eq. (13-2) beam stiffness ratio (slabs with beams, page 252)
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
§13.6.3.3 support class of every FrameLine column along
`frame_line.direction` (`_ddm_support_class`).  Without skeleton geometry
the FrameLine `joint_positions` are used and each column emits a
`:fallback` trace event (`no_geometry`).
"""
function _frameline_support_classes(struc, frame_line; tc = nothing,
                                    ctx = _eq137_geometry_available(struc) ?
                                          _eq137_context(struc, frame_line.columns) : nothing)
    cols = frame_line.columns
    d = frame_line.direction
    axis = (Float64(d[1]), Float64(d[2]))
    classes = Symbol[]
    for (i, col) in enumerate(cols)
        cls = nothing
        if ctx === nothing
            _eq137_trace_fallback(tc, col, :no_geometry; stage = "_ddm_support_moment")
        else
            cls = _ddm_support_class(struc, col, axis; index = ctx.index,
                                     vertex_column = ctx.vertex_column,
                                     partway = ctx.partway, tc = tc)
        end
        if cls === nothing
            cls = frame_line.joint_positions[i] == :exterior ? :exterior : :interior
        end
        push!(classes, cls)
    end
    return classes
end

"""
Per-span DDM moments of a FrameLine with the given exterior supports.

Each span: M0 by ACI 318-11 §13.6.2.2 Eq. (13-4) (corpus: aci-318-11,
page 253) and the §13.6.3 coefficients (page 254): end-span coefficients
when either support is exterior (edge beam via `βt`), interior-span
coefficients otherwise; `:simplified` uses 0.65 / 0.35 throughout.
"""
function _frameline_span_moments(method::DDM, frame_line, qu, column_is_exterior, βt)
    l2 = frame_line.tributary_width
    M_type = typeof(qu * l2 * (1.0u"m")^2)
    L_type = typeof(1.0u"m")
    span_moments = NamedTuple{(:span_idx, :ln, :M0, :M_neg_left, :M_pos, :M_neg_right),
                              Tuple{Int, L_type, M_type, M_type, M_type, M_type}}[]
    end_coeffs = βt > 0.0 ? aci_ddm_longitudinal_with_edge_beam(βt) : ACI_DDM_LONGITUDINAL.end_span
    for span_idx in eachindex(frame_line.span_lengths)
        ln = frame_line.span_lengths[span_idx]
        M0 = total_static_moment(qu, l2, ln)
        left_is_ext = column_is_exterior[span_idx]
        right_is_ext = column_is_exterior[span_idx + 1]
        if method.variant == :simplified
            M_neg_left = 0.65 * M0
            M_neg_right = 0.65 * M0
            M_pos = 0.35 * M0
        elseif left_is_ext || right_is_ext
            M_neg_left = (left_is_ext ? end_coeffs.ext_neg : end_coeffs.int_neg) * M0
            M_neg_right = (right_is_ext ? end_coeffs.ext_neg : end_coeffs.int_neg) * M0
            M_pos = end_coeffs.pos * M0
        else
            M_neg_left = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
            M_neg_right = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
            M_pos = ACI_DDM_LONGITUDINAL.interior_span.pos * M0
        end
        push!(span_moments, (
            span_idx = span_idx,
            ln = ln,
            M0 = M0,
            M_neg_left = M_neg_left,
            M_pos = M_pos,
            M_neg_right = M_neg_right,
        ))
    end
    return span_moments
end

TRACE_REGISTRY[(:_frameline_ddm_gate, :slab)] = TracedFunctionMeta(
    :_frameline_ddm_gate, :slab, [:decision, :failure], nothing, @__FILE__, @__LINE__,
)

"""
ACI 318-11 §13.6.1 (corpus: aci-318-11, page 252) violations that a
`FrameLine` can establish on its own:

- §13.6.1.1 — at least three continuous spans: `frame_line` has ≥ 3 spans.
- §13.6.1.5 — unfactored live load ≤ 2 × unfactored dead load (`qL`, `qD`
  as passed).
- With skeleton geometry (`ctx !== nothing`), from the structural centerlines
  of successive columns measured along / across `frame_line.direction`:
  §13.6.1.2 longer / shorter of the center-to-center span and
  `tributary_width` ≤ 2 (`_DDM_PANEL_ASPECT_MAX`); §13.6.1.3 successive
  center-to-center spans differ by ≤ one-third of the longer; §13.6.1.4 the
  successive column is offset from the frame axis through the previous one
  by ≤ 10% of the span (`_DDM_OFFSET_LIMIT_FRAC`).  Without geometry these
  three are not checked (the FrameLine stores clear spans only).

Rectangularity of the panels (§13.6.1.2) needs the slab faces and is
checked only on the slab path (`check_ddm_applicability`).
"""
function _frameline_ddm_violations(struc, frame_line, qD, qL; ctx = nothing)::Vector{String}
    out = String[]
    n_spans = length(frame_line.span_lengths)
    if n_spans < 3
        push!(out, "§13.6.1.1: DDM requires at least 3 continuous spans; the frame line has " *
                   "$(n_spans) (corpus: aci-318-11, page 252)")
    end
    qD_psf, qL_psf = ustrip(psf, qD), ustrip(psf, qL)
    if qL_psf > 2 * qD_psf
        push!(out, "§13.6.1.5: Unfactored live load $(round(qL_psf, digits=1)) psf > 2 × " *
                   "unfactored dead load $(round(qD_psf, digits=1)) psf (corpus: aci-318-11, page 252)")
    end
    ctx === nothing && return out
    d = frame_line.direction
    ax = (Float64(d[1]), Float64(d[2]))
    perp = (-ax[2], ax[1])
    l2_m = ustrip(u"m", frame_line.tributary_width)
    cols = frame_line.columns
    spans = Float64[]
    for k in 1:(length(cols) - 1)
        if col_vertex_idx(cols[k]) <= 0 || col_vertex_idx(cols[k + 1]) <= 0
            push!(spans, NaN)
            continue
        end
        a = _eq137_structural_xy(struc, cols[k])
        b = _eq137_structural_xy(struc, cols[k + 1])
        Δ = (b[1] - a[1], b[2] - a[2])
        along = abs(Δ[1] * ax[1] + Δ[2] * ax[2])
        across = abs(Δ[1] * perp[1] + Δ[2] * perp[2])
        if !(isfinite(along) && isfinite(across)) || along <= 0
            push!(spans, NaN)
            continue
        end
        push!(spans, along)
        if across > _DDM_OFFSET_LIMIT_FRAC * along
            push!(out, "§13.6.1.4: Frame-line column $(k + 1) offset $(round(across, digits=2)) m " *
                       "from the axis through column $(k) > 10% of the " *
                       "$(round(along, digits=2)) m span (corpus: aci-318-11, page 252)")
        end
        if l2_m > 0 && max(along, l2_m) / min(along, l2_m) >
                       _DDM_PANEL_ASPECT_MAX * (1 + _DDM_PANEL_ASPECT_RTOL)
            push!(out, "§13.6.1.2: Frame-line span $(k): longer / shorter span center-to-center = " *
                       "$(round(max(along, l2_m) / min(along, l2_m), digits=2)) > 2 " *
                       "[$(round(along, digits=2)) m × $(round(l2_m, digits=2)) m] " *
                       "(corpus: aci-318-11, page 252)")
        end
    end
    for k in 1:(length(spans) - 1)
        la, lb = spans[k], spans[k + 1]
        (isfinite(la) && isfinite(lb)) || continue
        abs(la - lb) > max(la, lb) / 3 || continue
        push!(out, "§13.6.1.3: Successive frame-line spans $(k) and $(k + 1) center-to-center " *
                   "differ by $(round(abs(la - lb), digits=2)) m > one-third of the longer span " *
                   "[$(round(la, digits=2)) m vs $(round(lb, digits=2)) m] (corpus: aci-318-11, page 252)")
    end
    return out
end

"""
    _frameline_ddm_gate(struc, frame_line, qD, qL, on_inapplicable; ctx, tc)

DDM applicability gate of `run_moment_analysis(::DDM, frame_line, ...)`
(`_frameline_ddm_violations`, ACI 318-11 §13.6.1, corpus: aci-318-11,
page 252).  A FrameLine has no FEA overload to fall back to, so:

- `on_inapplicable = :error` (default) — emits a `:failure` trace event
  (`reason = "ddm_not_applicable"`) and throws `DDMApplicabilityError`; use
  the slab pipeline (`size_flat_plate!` with `method = FEA()`) instead.
- `on_inapplicable = :proceed` — the caller takes responsibility for using
  DDM coefficients outside §13.6.1 (e.g. to study one frame in isolation):
  `@warn`, a `:decision` trace event (`reason = "ddm_not_applicable_proceed"`)
  and the analysis continues.

No violations: nothing is emitted.
"""
function _frameline_ddm_gate(struc, frame_line, qD, qL, on_inapplicable::Symbol;
                             ctx = nothing, tc = nothing)
    on_inapplicable in (:error, :proceed) || throw(ArgumentError(
        "FrameLine DDM on_inapplicable must be :error or :proceed; got :$on_inapplicable"))
    violations = _frameline_ddm_violations(struc, frame_line, qD, qL; ctx = ctx)
    isempty(violations) && return nothing
    if on_inapplicable === :error
        emit!(tc, :slab, "_frameline_ddm_gate", "frame_line", :failure;
              reason = "ddm_not_applicable", violations = violations,
              n_violations = length(violations))
        throw(DDMApplicabilityError(violations, [
            "FEA (Finite Element Analysis) at slab level: size_flat_plate!(...; method=FEA()) " *
            "— there is no FrameLine FEA analysis"]))
    end
    @warn "FrameLine DDM outside ACI 318-11 §13.6.1 (on_inapplicable = :proceed)" violations = join(violations, "; ")
    emit!(tc, :slab, "_frameline_ddm_gate", "frame_line", :decision;
          reason = "ddm_not_applicable_proceed", violations = violations,
          n_violations = length(violations))
    return nothing
end

"""
    run_moment_analysis(method::DDM, frame_line::FrameLine, struc, qu, qD, qL; verbose=false)

Run DDM moment analysis using a FrameLine (multi-span frame strip).

This overload accepts a pre-built FrameLine which already has:
- Columns sorted along the frame direction
- Clear span lengths computed
- Joint positions (exterior/interior) determined

Each support is classified for §13.6.3.3 (corpus: aci-318-11, page 254)
by `_ddm_support_class` along `frame_line.direction`, the same panel
geometry and tag/conformance rule as the single-panel DDM, with the same
trace events.  Only when `struc` carries no skeleton geometry are the
FrameLine `joint_positions` used (traced `no_geometry`).  An `:envelope`
support takes, at every section of its adjacent spans, the larger of the
coefficients with that support exterior and with it interior.

# Arguments
- `method::DDM`: DDM method with variant (:full or :simplified)
- `frame_line::FrameLine`: Pre-built frame strip with columns and spans
- `struc`: BuildingStructure (tributary areas and skeleton geometry)
- `qu::Pressure`: Factored uniform load (1.2D + 1.6L)
- `qD::Pressure`: Service dead load
- `qL::Pressure`: Service live load
- `γ_concrete`: concrete density, used (as in the cell path) for the self-weight
  and drop panel of a neighbour slab beyond a continuous frame end; `nothing`
  falls back to the stored `cell.self_weight` without a drop
- `design_drop::Pressure`: the design slab's service drop pressure already
  included in `qD` (default 0)
- `on_inapplicable::Symbol`: `:error` (default) throws `DDMApplicabilityError`
  when the frame line violates ACI 318-11 §13.6.1 (`_frameline_ddm_gate`;
  there is no FrameLine FEA fallback); `:proceed` continues with a `@warn` and
  a `:decision` trace event, the caller taking responsibility
- `tc`: optional trace collector

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
    βt::Float64 = 0.0,
    γ_concrete = nothing,
    design_drop::Pressure = 0.0psf,
    on_inapplicable::Symbol = :error,
    tc = nothing,
)
    # Extract from FrameLine
    sorted_columns = frame_line.columns
    l2 = frame_line.tributary_width
    n_spans = length(frame_line.span_lengths)
    n_cols = n_spans + 1

    ctx = _eq137_geometry_available(struc) ? _eq137_context(struc, sorted_columns) : nothing
    _frameline_ddm_gate(struc, frame_line, qD, qL, on_inapplicable; ctx = ctx, tc = tc)

    # §13.6.3.3 support classes, as the single-panel DDM classifies them.
    # They drive both the span coefficients and the transfer moments.
    classes = _frameline_support_classes(struc, frame_line; tc = tc, ctx = ctx)
    column_is_exterior = [c != :interior for c in classes]
    span_moments = _frameline_span_moments(method, frame_line, qu, column_is_exterior, βt)
    if any(==(:envelope), classes)
        # An uncertain support takes the larger of its exterior and interior
        # coefficients at every section of its adjacent spans.
        as_interior = _frameline_span_moments(method, frame_line, qu,
                                              [c == :exterior for c in classes], βt)
        span_moments = [merge(a, (M_neg_left = max(a.M_neg_left, b.M_neg_left),
                                  M_pos = max(a.M_pos, b.M_pos),
                                  M_neg_right = max(a.M_neg_right, b.M_neg_right)))
                        for (a, b) in zip(span_moments, as_interior)]
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
    
    # Build column-level results — interior columns use ACI 318-11 §13.6.9.2 Eq. (13-7).
    column_moments, column_shears, unbalanced_moments = _compute_column_demands_from_spans(
        struc, sorted_columns, classes, span_moments, qu, qD, qL, l2;
        span_axis = frame_line.direction, ctx = ctx,
        γ = γ_concrete, design_drop = design_drop, tc = tc,
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

