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

