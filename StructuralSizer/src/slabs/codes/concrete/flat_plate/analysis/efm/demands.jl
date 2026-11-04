"""Get column concrete strength from first column's material, or fall back to slab fc."""
function _get_column_fc(columns, default_fc)
    if !isempty(columns) && hasproperty(columns[1], :material) && hasproperty(columns[1].material, :fc′)
        return columns[1].material.fc′
    end
    return default_fc
end

"""Get column height from first column. Errors if not available."""
function _get_column_height(columns)
    if !isempty(columns) && hasproperty(columns[1], :base) && hasproperty(columns[1].base, :L)
        return columns[1].base.L
    end
    error("Cannot determine column height: columns[1].base.L not available. " *
          "Ensure column geometry is set before EFM analysis.")
end

"""
Equivalent uniform pressure for one column under a per-span pattern.

ENGINEERING JUDGMENT: the column tributary is split equally between the
adjacent spans. ACI 318-11 §13.7.6.4 (corpus: aci-318-11, page 261) keeps
the all-panels full-load shear as a lower bound; the envelope applies that
bound, this split does not.
"""
function _pattern_shear_pressure(qu, qu_per_span, i::Int, n_cols::Int)
    qu_per_span === nothing && return qu
    i == 1 && return qu_per_span[1]
    i == n_cols && return qu_per_span[end]
    return (qu_per_span[i - 1] + qu_per_span[i]) / 2
end

function _raise_abs(current, candidate)
    return abs(candidate) > abs(current) ? candidate : current
end

function _raise_abs_vector!(dest, src)
    for i in eachindex(dest)
        abs(src[i]) > abs(dest[i]) && (dest[i] = src[i])
    end
    return dest
end

"""
    _compute_efm_column_demands(struc, columns, span_moments, qu, l2, ln)

Compute column-level demands from EFM span moments.

Uses tributary area for shear where available.
"""
function _compute_efm_column_demands(struc, columns, span_moments, qu, l2, ln;
                                     qu_per_span=nothing)
    n_cols = length(columns)
    MomentT = typeof(1.0kip*u"ft")
    ForceT  = typeof(1.0kip)
    column_moments     = Vector{MomentT}(undef, n_cols)
    column_shears      = Vector{ForceT}(undef, n_cols)
    unbalanced_moments = Vector{MomentT}(undef, n_cols)

    for (i, col) in enumerate(columns)
        if i == 1
            M = span_moments[1].M_neg_left
            Mub = M
        elseif i == n_cols
            M = span_moments[end].M_neg_right
            Mub = M
        else
            M_left = span_moments[i-1].M_neg_right
            M_right = span_moments[i].M_neg_left
            M = max(M_left, M_right)
            Mub = abs(M_left - M_right)
        end

        column_moments[i] = M
        unbalanced_moments[i] = Mub
        q_i = _pattern_shear_pressure(qu, qu_per_span, i, n_cols)
        column_shears[i] = _compute_column_shear(struc, col, q_i, l2, ln)
    end

    return column_moments, column_shears, unbalanced_moments
end

"""
    _efm_demands_with_pattern(...) -> NamedTuple

Slab moments from the end span of this frame line, plus column moments, shears, and
unbalanced moments. When `use_pattern` is true, each station is the larger
absolute value of the full-load case and the §13.7.6.3 patterns.

ACI 318-11 §13.7.6.4 (corpus: aci-318-11, page 261): a pattern cannot
reduce a full-load demand. Unbalanced moments are enveloped as a derived
quantity. Enveloping the two end moments first and then subtracting them
would hide the checkerboard transfer.
"""
function _efm_demands_with_pattern(span_moments, struc, columns, qu, qD, qL, l2, ln;
                                   use_pattern::Bool, solve_once)
    M_neg_ext = span_moments[1].M_neg_left
    M_neg_int = span_moments[1].M_neg_right
    M_pos = span_moments[1].M_pos
    column_moments, column_shears, unbalanced_moments = _compute_efm_column_demands(
        struc, columns, span_moments, qu, l2, ln,
    )
    if use_pattern
        n_spans = length(span_moments)
        for pattern in generate_load_patterns(n_spans)
            all(==(:dead_plus_live), pattern) && continue
            qu_ps = factored_pattern_loads(pattern, qD, qL)
            sm_pat = solve_once(qu_ps)
            M_neg_ext = _raise_abs(M_neg_ext, sm_pat[1].M_neg_left)
            M_neg_int = _raise_abs(M_neg_int, sm_pat[1].M_neg_right)
            M_pos = _raise_abs(M_pos, sm_pat[1].M_pos)
            cm_p, cs_p, ub_p = _compute_efm_column_demands(
                struc, columns, sm_pat, qu, l2, ln; qu_per_span=qu_ps,
            )
            _raise_abs_vector!(column_moments, cm_p)
            _raise_abs_vector!(column_shears, cs_p)
            _raise_abs_vector!(unbalanced_moments, ub_p)
        end
    end
    return (
        M_neg_ext = M_neg_ext,
        M_neg_int = M_neg_int,
        M_pos = M_pos,
        column_moments = column_moments,
        column_shears = column_shears,
        unbalanced_moments = unbalanced_moments,
    )
end

# _compute_column_shear is defined in common.jl (shared between DDM and EFM)

