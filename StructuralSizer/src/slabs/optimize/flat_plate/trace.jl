TRACE_REGISTRY[(:_nlp_transfer_moment, :slab)] = TracedFunctionMeta(
    :_nlp_transfer_moment, :slab, [:fallback, :failure], nothing, @__FILE__, @__LINE__,
)

TRACE_REGISTRY[(:_nlp_support_moment, :slab)] = TracedFunctionMeta(
    :_nlp_support_moment, :slab, [:fallback], nothing, @__FILE__, @__LINE__,
)

"""
Positional fallback of `_nlp_transfer_moment` / `_nlp_support_moment`:
trace it, and warn once when the column is missing from stored geometry
(a data mismatch, not the geometry-free test constructor).
"""
function _nlp_trace_positional(p::FlatPlateNLPProblem, i::Int, stage::String, tc)
    reason = if isnothing(p.eq137)
        "no_geometry_position"
    else
        _eq137_warn_once(:nlp_column_not_in_geometry,
            "FlatPlateNLPProblem: column index exceeds the stored Eq. (13-7) columns; using the position tag for that column.")
        "column_not_in_geometry"
    end
    emit!(tc, :slab, stage, "nlp_col_$(i)", :fallback;
          reason = reason, position = String(p.column_positions[i]))
    return nothing
end

