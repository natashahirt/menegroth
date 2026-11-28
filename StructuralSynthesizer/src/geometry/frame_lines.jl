# =============================================================================
# Frame Lines - Column Lines for EFM/DDM Analysis
# =============================================================================
#
# A FrameLine represents a row of columns forming a frame strip for analysis.
# Columns are ordered along the frame direction, with spans computed from 
# column positions.
#
# The frame direction can be:
# - :x or :y (axis-aligned)
# - Any (dx, dy) tuple for arbitrary directions (rotated buildings)
#
# =============================================================================

using LinearAlgebra: norm, dot

# =============================================================================
# FrameLine Type
# =============================================================================

"""
    FrameLine{T, C}

A line of columns forming an EFM frame strip.

# Fields
- `direction::NTuple{2, Float64}`: Unit vector along frame (spans measured here)
- `columns::Vector{C}`: Columns ordered along direction
- `tributary_width::T`: l₂ (perpendicular to direction)
- `span_lengths::Vector{T}`: Face-to-face clear spans (n_cols - 1 values)
- `joint_positions::Vector{Symbol}`: :exterior or :interior for each joint
- `center_spans::Vector{T}`: Center-to-center spans, same unit as `span_lengths`

# Notes
The perpendicular direction (for tributary width) is automatically computed
as a 90° CCW rotation of the frame direction.
"""
struct FrameLine{T, C}
    direction::NTuple{2, Float64}
    columns::Vector{C}
    tributary_width::T
    span_lengths::Vector{T}
    joint_positions::Vector{Symbol}
    column_projections::Vector{T}  # Same unit as span_lengths. Bare numbers share one anonymous unit.
    center_spans::Vector{T}
end

"""
    perpendicular(dir::NTuple{2, Float64})

Return the perpendicular direction (90° CCW rotation).
"""
perpendicular(dir::NTuple{2, Float64}) = (-dir[2], dir[1])

"""
    direction_vector(dir::Symbol) -> NTuple{2, Float64}

Convert direction symbol to unit vector.
"""
function direction_vector(dir::Symbol)
    dir == :x && return (1.0, 0.0)
    dir == :y && return (0.0, 1.0)
    error("Unknown direction symbol: $dir. Use :x, :y, or provide a tuple directly.")
end

# =============================================================================
# FrameLine Constructors
# =============================================================================

"""
    FrameLine(direction::Symbol, columns, tributary_width, get_position_fn, get_width_fn)

Construct a FrameLine from columns using axis-aligned direction.

# Arguments
- `direction::Symbol`: :x or :y
- `columns`: Vector of column objects
- `tributary_width`: l₂ (transverse span)
- `get_position_fn(col)`: Function returning (x, y) position of column
- `get_width_fn(col, dir)`: Function returning column width in frame direction
"""
function FrameLine(
    direction::Symbol,
    columns::Vector{C},
    tributary_width::T,
    get_position_fn::Function,
    get_width_fn::Function
) where {T, C}
    return FrameLine(direction_vector(direction), columns, tributary_width, 
                     get_position_fn, get_width_fn)
end

"""
    FrameLine(direction::NTuple{2}, columns, tributary_width, get_position_fn, get_width_fn)

Construct a FrameLine from columns using arbitrary direction vector.
"""
function FrameLine(
    direction::NTuple{2, Float64},
    columns::Vector{C},
    tributary_width::T,
    get_position_fn::Function,
    get_width_fn::Function
) where {T, C}
    n = length(columns)
    n >= 2 || error("FrameLine requires at least 2 columns, got $n")
    
    # Normalize direction
    dir_norm = sqrt(direction[1]^2 + direction[2]^2)
    dir_norm > 1e-10 || error("Direction vector cannot be zero")
    dir = (direction[1] / dir_norm, direction[2] / dir_norm)
    
    # Project each column position onto the frame axis. A length stays a
    # length, so the clear-span subtraction is checked by Unitful.
    projections = T[]
    for col in columns
        pos = get_position_fn(col)
        s = pos[1] * dir[1] + pos[2] * dir[2]
        if s isa Length
            tributary_width isa Length || error(
                "FrameLine positions are lengths, so tributary_width must be a length too")
            push!(projections, uconvert(unit(tributary_width), s))
        elseif tributary_width isa Length
            error("FrameLine positions are bare numbers and tributary_width is a length. " *
                  "Return positions as lengths; skeleton coordinates are meters.")
        else
            push!(projections, T(Float64(s)))
        end
    end
    
    # Sort columns by their projection (position along axis)
    perm = sortperm(projections)
    sorted_cols = columns[perm]
    sorted_proj = projections[perm]
    
    # Clear and center-to-center spans, in `tributary_width`'s unit.
    # Length positions and length widths subtract directly. Bare numbers
    # share one unit and never mix with a length.
    span_lengths = T[]
    center_spans = T[]
    u = tributary_width isa Length ? unit(tributary_width) : nothing
    for i in 1:(n-1)
        c_to_c = sorted_proj[i+1] - sorted_proj[i]
        c_left = get_width_fn(sorted_cols[i], dir)
        c_right = get_width_fn(sorted_cols[i+1], dir)
        if c_to_c isa Length
            (c_left isa Length && c_right isa Length) || error(
                "FrameLine positions are lengths, so column widths must be lengths too")
            push!(center_spans, uconvert(u, c_to_c))
            push!(span_lengths, uconvert(u, c_to_c - c_left / 2 - c_right / 2))
        else
            (c_left isa Length || c_right isa Length) && error(
                "FrameLine column widths are lengths but positions are bare numbers")
            half_l = ustrip(c_left) / 2
            half_r = ustrip(c_right) / 2
            same = oneunit(tributary_width) / oneunit(tributary_width)
            push!(center_spans, T(c_to_c) * same)
            push!(span_lengths, T(c_to_c - half_l - half_r) * same)
        end
    end
    
    # Joint positions: first and last are exterior, middle are interior
    joint_positions = Symbol[]
    for i in 1:n
        if i == 1 || i == n
            push!(joint_positions, :exterior)
        else
            push!(joint_positions, :interior)
        end
    end
    
    return FrameLine{T, C}(dir, sorted_cols, tributary_width, span_lengths,
                           joint_positions, sorted_proj, center_spans)
end

# =============================================================================
# FrameLine Utilities
# =============================================================================

"""
    n_spans(fl::FrameLine) -> Int

Number of spans in the frame line.
"""
n_spans(fl::FrameLine) = length(fl.span_lengths)

"""
    n_joints(fl::FrameLine) -> Int

Number of joints (columns) in the frame line.
"""
n_joints(fl::FrameLine) = length(fl.columns)

"""
    is_end_span(fl::FrameLine, span_idx::Int) -> Bool

Check if span is at the end (exterior) of the frame.
"""
function is_end_span(fl::FrameLine, span_idx::Int)
    return span_idx == 1 || span_idx == n_spans(fl)
end

"""
    get_span_supports(fl::FrameLine, span_idx::Int) -> (left_pos, right_pos)

Get the joint positions for a span (for DDM coefficient selection).
"""
function get_span_supports(fl::FrameLine, span_idx::Int)
    return (fl.joint_positions[span_idx], fl.joint_positions[span_idx + 1])
end

# =============================================================================
# Pretty Printing
# =============================================================================

"""Compact single-line display of a `FrameLine`."""
function Base.show(io::IO, fl::FrameLine{T, C}) where {T, C}
    dir_str = if isapprox(fl.direction[1], 1.0, atol=1e-6) && isapprox(fl.direction[2], 0.0, atol=1e-6)
        "X"
    elseif isapprox(fl.direction[1], 0.0, atol=1e-6) && isapprox(fl.direction[2], 1.0, atol=1e-6)
        "Y"
    else
        "($(round(fl.direction[1], digits=3)), $(round(fl.direction[2], digits=3)))"
    end
    
    print(io, "FrameLine{$dir_str}($(n_joints(fl)) columns, $(n_spans(fl)) spans, l₂=$(fl.tributary_width))")
end

"""Multi-line REPL display of a `FrameLine` with span details."""
function Base.show(io::IO, ::MIME"text/plain", fl::FrameLine{T, C}) where {T, C}
    println(io, "FrameLine:")
    println(io, "  Direction: $(fl.direction)")
    println(io, "  Columns: $(n_joints(fl))")
    println(io, "  Tributary width (l₂): $(fl.tributary_width)")
    println(io, "  Spans:")
    for (i, (ln, (left, right))) in enumerate(zip(fl.span_lengths, 
            [(fl.joint_positions[j], fl.joint_positions[j+1]) for j in 1:n_spans(fl)]))
        span_type = (left == :exterior || right == :exterior) ? "end" : "interior"
        println(io, "    Span $i: ln = $ln ($span_type)")
    end
end
