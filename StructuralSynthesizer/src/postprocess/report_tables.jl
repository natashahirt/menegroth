# =============================================================================
# Report Table Formatting Utilities
# =============================================================================
# Shared helpers for dense engineering tables. All tables follow the same
# pattern: header line → divider → data rows → optional totals divider.
#
# Convention:
#   - Column widths are specified once and reused for header, divider, and rows.
#   - Units are stated in column headers, not repeated per row.
#   - Material/geometry parameters shared across rows go in the table title.
# =============================================================================

"""
    table_divider(widths; char='─') -> String

Build a divider line from column widths.
"""
function table_divider(widths::Vector{Int}; char::Char='─')
    join(String(fill(char, w)) for w in widths)
end

"""
    table_header(labels, widths; indent=2) -> String

Build a right-padded header row from labels and widths.
"""
function table_header(labels::Vector{String}, widths::Vector{Int}; indent::Int=2)
    parts = [rpad(l, w) for (l, w) in zip(labels, widths)]
    " "^indent * join(parts)
end

"""
    table_title(title; width=90) -> String

Centered title with divider above and below.
"""
function table_title(title::String; width::Int=90)
    line = "─"^width
    lines = [line, "  " * title, line]
    join(lines, "\n")
end

"""
    section_break(title) -> String

Major section header with double-line border.
"""
function section_break(title::String; width::Int=90)
    line = "═"^width
    join(["\n" * line, "  " * title, line], "\n")
end

"""
    fv(x; d=1) -> String

Format a numeric value. Returns "—" for nothing/NaN.
"""
function fv(x; d::Int=1)
    x === nothing && return "—"
    x isa AbstractFloat && isnan(x) && return "—"
    return string(round(x; digits=d))
end

"""
    fv_pct(x; d=1) -> String

Format a value as a percentage string (e.g., 0.87 → "0.87").
"""
fv_pct(x; d::Int=2) = fv(x; d=d)

"""
    safe_ratio(num, den) -> Float64

Safe division that returns 0.0 when denominator is ≈ 0.
"""
safe_ratio(num, den) = abs(den) > 1e-12 ? Float64(num / den) : 0.0

"""
    pass_fail(ok::Bool) -> String
"""
pass_fail(ok::Bool) = ok ? "✓" : "✗"
