# =============================================================================
# Column Growth Helpers for Flat Plate Design
# =============================================================================
#
# Centralized column dimension management for the slab-column iteration loop.
#
# Instead of blind 2" incrementing, these functions:
#   1. Directly solve for the required column dimensions from the punching ratio
#   2. Use moment direction (Mx/My) to set the target aspect ratio
#   3. Enforce shape constraints (square, bounded, free)
#   4. Round to practical increments
#
# Reference: ACI 318 §22.6.5 (punching geometry), §22.6.5.2 (β factor)
# =============================================================================

# =============================================================================
# Aspect Ratio from Moment Direction
# =============================================================================

"""
    target_aspect_ratio(Mx, My; max_ar=2.0) -> Float64

Compute the target c1/c2 aspect ratio from directional column moments.

The column dimension in each direction provides flexural depth for bending
about that axis.  For Mn ∝ b·d², the required depth scales as √M, so the
aspect ratio of column dimensions should roughly follow √(Mx/My).

# Arguments
- `Mx`: Moment about x-axis (resisted by depth in x-direction = c1)
- `My`: Moment about y-axis (resisted by depth in y-direction = c2)
- `max_ar`: Maximum aspect ratio clamp (default 2.0)

# Returns
Aspect ratio r = c1/c2.  r > 1 means c1 > c2 (deeper in x).
"""
function target_aspect_ratio(Mx, My; max_ar::Float64 = 2.0)
    Mx_abs = abs(ustrip(Mx))
    My_abs = abs(ustrip(My))
    total = Mx_abs + My_abs

    # No moment info → square
    total < 1e-6 && return 1.0

    if Mx_abs ≥ My_abs
        raw = sqrt(Mx_abs / max(My_abs, 0.01 * Mx_abs))
        return clamp(raw, 1.0, max_ar)
    else
        raw = sqrt(My_abs / max(Mx_abs, 0.01 * My_abs))
        return 1.0 / clamp(raw, 1.0, max_ar)
    end
end

# =============================================================================
# Direct Solve for Required Column Dimensions
# =============================================================================

"""
    _round_up_to(x::Length, increment::Length) -> Length

Round `x` up to the next multiple of `increment`.
"""
function _round_up_to(x::Length, increment::Length)
    inc = ustrip(u"inch", increment)
    val = ustrip(u"inch", x)
    return ceil(val / inc) * inc * u"inch"
end

"""
    _solve_square_b0(position::Symbol, b0_req::Length, d::Length) -> Length

Back-solve for the required square column size `c` given a target perimeter `b0_req`.

Interior: b₀ = 4(c+d)        → c = b₀/4 − d
Edge:     b₀ = 2(c+d/2)+(c+d) = 3c + 2d → c = (b₀ − 2d)/3
Corner:   b₀ = (c+d/2)+(c+d/2) = 2c + d  → c = (b₀ − d)/2
"""
function _solve_square_b0(position::Symbol, b0_req::Length, d::Length)
    if position == :interior
        return b0_req / 4 - d
    elseif position == :edge
        return (b0_req - 2d) / 3
    else  # :corner
        return (b0_req - d) / 2
    end
end

"""
    _solve_rectangular_b0(position::Symbol, b0_req::Length, d::Length, r::Float64) -> Length

Back-solve for c1 given target b₀ and aspect ratio r = c1/c2 (so c2 = c1/r).

Interior: b₀ = 2(c1+d) + 2(c1/r+d) → c1 = (b₀ − 4d) / (2 + 2/r)
Edge:     b₀ = 2(c1+d/2) + (c1/r+d) → c1 = (b₀ − 2d) / (2 + 1/r)
Corner:   b₀ = (c1+d/2) + (c1/r+d/2) → c1 = (b₀ − d) / (1 + 1/r)
"""
function _solve_rectangular_b0(position::Symbol, b0_req::Length, d::Length, r::Float64)
    inv_r = 1.0 / r
    if position == :interior
        return (b0_req - 4d) / (2 + 2inv_r)
    elseif position == :edge
        return (b0_req - 2d) / (2 + inv_r)
    else  # :corner
        return (b0_req - d) / (1 + inv_r)
    end
end

"""
    _solve_circular_b0(position::Symbol, b0_req::Length, d::Length) -> Length

Back-solve for the required circular column diameter `D` given a target
perimeter `b0_req`.  ACI 318 §22.6.4.1:

Interior: b₀ = π(D+d)                    → D = b₀/π − d
Edge/Corner: treated as equivalent square (circular b₀ only defined for interior).
"""
function _solve_circular_b0(position::Symbol, b0_req::Length, d::Length)
    if position == :interior
        return b0_req / π - d
    else
        # Edge/corner circular columns are converted to equivalent-square
        # for punching geometry (see checks.jl:61); use square solve.
        return _solve_square_b0(position, b0_req, d)
    end
end

"""
    solve_column_for_punching(col, ratio, b0_current, d;
                               shape_constraint=:square, max_ar=2.0,
                               Mx=nothing, My=nothing,
                               increment=0.5u"inch") -> (c1, c2)

Compute the required column dimensions (c1, c2) to satisfy punching shear,
using a direct algebraic solve of the b₀ geometry equations.

The current punching ratio `vu/(φ·vc)` is used to estimate the required
critical perimeter `b0_req ≈ b0_current × ratio`.  Column dimensions are
back-solved from b₀ given the position geometry, then rounded up to the
nearest `increment`.

Handles both rectangular and circular columns.  Circular columns always
remain circular (c1 = c2 = D), ignoring aspect ratio / shape constraint.

# Arguments
- `col`: Column with `.c1`, `.c2`, `.position` fields (and `.shape` if circular)
- `ratio`: Current punching ratio (vu / φvc > 1.0 means failing)
- `b0_current`: Current critical section perimeter
- `d`: Effective slab depth
- `shape_constraint`: `:square`, `:bounded`, or `:free` (ignored for circular)
- `max_ar`: Maximum aspect ratio (for `:bounded`)
- `Mx`, `My`: Optional directional moments for aspect ratio targeting
- `increment`: Rounding increment

# Returns
Tuple `(c1_new, c2_new)` of required column dimensions.
"""
function solve_column_for_punching(col, ratio::Float64, b0_current::Length, d::Length;
                                    shape_constraint::Symbol = :square,
                                    max_ar::Float64 = 2.0,
                                    Mx = nothing, My = nothing,
                                    increment::Length = 0.5u"inch")
    # Already passes — no growth needed
    ratio ≤ 1.0 && return (col.c1, col.c2)

    # Required b0 (scale by current overstress — conservative for concentric term)
    b0_req = b0_current * ratio

    pos = col.position

    # ── Circular columns: b₀ = π(D+d) for interior ──────────────────────
    _cshape = col_shape(col)
    if _cshape == :circular
        D = _solve_circular_b0(pos, b0_req, d)
        D = max(D, col.c1, col.c2)  # never shrink
        D = _round_up_to(D, increment)
        return (D, D)
    end

    # ── Rectangular columns ─────────────────────────────────────────────
    is_square = shape_constraint == :square ||
                (abs(ustrip(u"inch", col.c1) - ustrip(u"inch", col.c2)) < 0.1)

    if shape_constraint == :square || (is_square && isnothing(Mx))
        # Square growth
        c = _solve_square_b0(pos, b0_req, d)
        c = max(c, col.c1, col.c2)  # never shrink
        c = _round_up_to(c, increment)
        return (c, c)
    else
        # Determine target aspect ratio
        r = if !isnothing(Mx) && !isnothing(My)
            target_aspect_ratio(Mx, My; max_ar = max_ar)
        elseif ustrip(u"inch", col.c1) > 0.1 && ustrip(u"inch", col.c2) > 0.1
            # Preserve current aspect ratio
            clamp(ustrip(u"inch", col.c1) / ustrip(u"inch", col.c2), 1.0/max_ar, max_ar)
        else
            1.0  # default square
        end

        c1 = _solve_rectangular_b0(pos, b0_req, d, r)
        c2 = c1 / r

        # Never shrink
        c1 = max(c1, col.c1)
        c2 = max(c2, col.c2)

        # Round up
        c1 = _round_up_to(c1, increment)
        c2 = _round_up_to(c2, increment)

        # Enforce aspect ratio constraint
        if shape_constraint == :bounded
            _enforce_aspect_ratio!(c1, c2, max_ar, increment)
        end

        return (c1, c2)
    end
end

"""
    _enforce_aspect_ratio!(c1, c2, max_ar, increment) -> (c1, c2)

Clamp the aspect ratio by growing the smaller dimension up.
Returns updated (c1, c2).
"""
function _enforce_aspect_ratio!(c1::Length, c2::Length, max_ar::Float64, increment::Length)
    c1_in = ustrip(u"inch", c1)
    c2_in = ustrip(u"inch", c2)
    ar = c1_in / max(c2_in, 0.1)

    if ar > max_ar
        c2 = _round_up_to(c1 / max_ar, increment)
    elseif ar < 1.0 / max_ar
        c1 = _round_up_to(c2 / max_ar, increment)
    end
    return (c1, c2)
end

# =============================================================================
# Unified Column Growth
# =============================================================================

"""
    grow_column!(col, c_new::Length; shape_constraint=:square, max_ar=2.0,
                  increment=0.5u"inch")

Grow a column to at least `c_new` in its governing dimension, respecting the
shape constraint.

- `:square` — set c1 = c2 = max(c_new, current)
- `:bounded` — grow preserving orientation, clamp aspect ratio
- `:free` — grow the governing dimension only

Mutates `col.c1` and `col.c2` in place.
"""
function grow_column!(col, c_new::Length;
                       shape_constraint::Symbol = :square,
                       max_ar::Float64 = 2.0,
                       increment::Length = 0.5u"inch")
    c_new = _round_up_to(c_new, increment)

    if shape_constraint == :square
        c = max(c_new, col.c1, col.c2)
        c = _round_up_to(c, increment)
        col.c1 = c
        col.c2 = c
    elseif shape_constraint == :bounded
        col.c1 = max(col.c1, c_new)
        col.c2 = max(col.c2, c_new)
        col.c1 = _round_up_to(col.c1, increment)
        col.c2 = _round_up_to(col.c2, increment)
        (col.c1, col.c2) = _enforce_aspect_ratio!(col.c1, col.c2, max_ar, increment)
    else  # :free
        col.c1 = _round_up_to(max(col.c1, c_new), increment)
        col.c2 = _round_up_to(max(col.c2, c_new), increment)
    end
    return nothing
end

"""
    grow_column_for_axial!(col, Ag_required::Area;
                            shape_constraint=:square, max_ar=2.0,
                            increment=0.5u"inch")

Grow a column to provide at least `Ag_required` cross-sectional area.
Used by column reconciliation (post-slab axial load check).

Mutates `col.c1` and `col.c2` in place.
"""
function grow_column_for_axial!(col, Ag_required;
                                 shape_constraint::Symbol = :square,
                                 max_ar::Float64 = 2.0,
                                 increment::Length = 0.5u"inch")
    Ag_m2 = ustrip(u"m^2", Ag_required)
    Ag_m2 ≤ 0 && return nothing

    if shape_constraint == :square
        c = sqrt(Ag_m2) * u"m"
        c = max(c, col.c1, col.c2)
        c = _round_up_to(c, increment)
        col.c1 = c
        col.c2 = c
    else
        # Grow proportionally: maintain current aspect ratio, increase area
        c1_m = ustrip(u"m", col.c1)
        c2_m = ustrip(u"m", col.c2)
        Ag_current = c1_m * c2_m

        if Ag_current > 0 && Ag_m2 > Ag_current
            scale = sqrt(Ag_m2 / Ag_current)
            col.c1 = _round_up_to(col.c1 * scale, increment)
            col.c2 = _round_up_to(col.c2 * scale, increment)
        else
            c = sqrt(Ag_m2) * u"m"
            col.c1 = max(col.c1, c)
            col.c2 = max(col.c2, c)
            col.c1 = _round_up_to(col.c1, increment)
            col.c2 = _round_up_to(col.c2, increment)
        end

        if shape_constraint == :bounded
            (col.c1, col.c2) = _enforce_aspect_ratio!(col.c1, col.c2, max_ar, increment)
        end
    end
    return nothing
end
