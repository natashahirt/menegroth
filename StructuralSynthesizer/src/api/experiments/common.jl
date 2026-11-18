# =============================================================================
# Micro-Experiments — Lightweight what-if checks using cached design data
#
# These functions re-run individual structural checks with modified parameters
# WITHOUT requiring a full design_building pass. They extract demands and
# geometry from a completed BuildingDesign and call StructuralSizer checker
# APIs directly.
#
# Experiment types:
#   - punching:                vary column size, slab thickness, or fc for punching check
#   - pm_column:               try alternative column sections against cached P-M demands
#   - beam:                    try alternative W-shapes against cached beam demands
#   - punching_reinforcement:  design studs/stirrups for a punching-failing column
#   - punching_column_downsize: smallest scaled column plan (fixed Vu/Mub) that passes with studs/stirrups
#   - deflection:              test different deflection limits against stored slab data
#   - catalog_screen:          screen a section catalog against a single demand envelope
# =============================================================================

using Unitful

"""Replace `Inf`/`-Inf`/`NaN` with JSON-safe sentinels (JSON spec forbids IEEE specials)."""
_json_safe(x::Float64) = isfinite(x) ? x : (isnan(x) ? nothing : (x > 0 ? 1.0e308 : -1.0e308))
_json_safe(x) = x

"""
    _column_orig_ratio(col) -> (orig_ratio::Float64, unverified::Bool)

Baseline governing ratio for a column used by the P-M / catalog experiments.

An UNVERIFIED column (steel §E3/§E4 buckling capacity unavailable — see
`_populate_column_results!`) carries a `NaN` axial/interaction sentinel. A plain
`max(col.axial_ratio, col.interaction_ratio)` would then be `NaN`, and EVERY downstream
`new_ratio < orig_ratio` comparison would be `false` — so the experiment would report
"not improved" for the very column that most needs resizing, and `round(NaN)` could leak an
invalid `NaN` JSON token. Map an unverified column to a failing baseline (`1.0`) so a
verifiable candidate registers as an improvement; callers surface the `unverified` flag (and
keep the DISPLAYED original ratio null) so the fabricated baseline is never mistaken for a
real, verified utilization.
"""
function _column_orig_ratio(col)
    unverified = isnan(col.axial_ratio) || isnan(col.interaction_ratio)
    r = unverified ? 1.0 : max(col.axial_ratio, col.interaction_ratio, col.shear_ratio)
    return (r, unverified)
end

# ─── Experimental Setup Reporter ─────────────────────────────────────────────

"""
    _experimental_setup(; changed, held_constant, source, note=nothing) -> Dict

Build a structured `experimental_setup` block that documents what was varied,
what was held constant, and where the baseline data comes from.
"""
function _experimental_setup(;
    changed::Vector{String},
    held_constant::Vector{String},
    source::String,
    note::Union{String, Nothing} = nothing,
)::Dict{String, Any}
    out = Dict{String, Any}(
        "changed"       => changed,
        "held_constant" => held_constant,
        "source"        => source,
    )
    !isnothing(note) && (out["note"] = note)
    return out
end

# ─── Argument Coercion Helpers ────────────────────────────────────────────────

"""
    _coerce_float(x) -> Union{Float64, Nothing}

Convert JSON/tool argument `x` to `Float64` when possible. Returns `nothing` for
missing or invalid values.
"""
function _coerce_float(x)::Union{Float64, Nothing}
    isnothing(x) && return nothing
    x isa Real && return Float64(x)
    if x isa AbstractString
        s = strip(x)
        isempty(s) && return nothing
        v = tryparse(Float64, replace(s, "," => ""))
        return v
    end
    return nothing
end

"""
    _coerce_int(x) -> Union{Int, Nothing}

Convert JSON/tool argument `x` to `Int` when possible. Returns `nothing` for
missing or invalid values.
"""
function _coerce_int(x)::Union{Int, Nothing}
    isnothing(x) && return nothing
    if x isa Integer
        return Int(x)
    elseif x isa Real
        return isinteger(x) ? Int(x) : nothing
    elseif x isa AbstractString
        s = strip(x)
        isempty(s) && return nothing
        return tryparse(Int, s)
    end
    return nothing
end

# ─── Helpers: resolve column position from BuildingStructure ──────────────────

"""
    _resolve_column_position(design, col_idx) -> Symbol

Look up the column's position (:interior, :edge, :corner) from the
BuildingStructure stored on the design. Falls back to :interior when the
structure is unavailable.
"""
function _resolve_column_position(design::BuildingDesign, col_idx::Int)::Symbol
    struc = design.structure
    isnothing(struc) && return :interior
    (col_idx < 1 || col_idx > length(struc.columns)) && return :interior
    return struc.columns[col_idx].position
end

"""
    _resolve_column_shape(design, col_idx) -> Symbol

Look up the column's cross-section shape from the BuildingStructure.
Falls back to the ColumnDesignResult.shape if the structure is unavailable.
"""
function _resolve_column_shape(design::BuildingDesign, col_idx::Int)::Symbol
    struc = design.structure
    if !isnothing(struc) && col_idx >= 1 && col_idx <= length(struc.columns)
        return struc.columns[col_idx].shape
    end
    col_result = get(design.columns, col_idx, nothing)
    isnothing(col_result) && return :rectangular
    return col_result.shape
end

