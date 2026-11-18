# =============================================================================
# Equivalent Frame Method (EFM) - ACI 318-11 §13.7
# =============================================================================
#
# Stiffness-based frame analysis for flat plate moment distribution.
#
# The floor is one equivalent frame per column line, longitudinally and
# transversely (ACI 318-11 §13.7.2). Each line is solved on its own and
# the column demands are written back to the supporting-column index.
#
# Reference:
# - ACI 318-11 §13.7
# - StructurePoint DE-Two-Way-Flat-Plate Section 3.2
# - PCA Notes on ACI 318-11 Tables A1, A7
#
# =============================================================================

using Logging
using Asap

# =============================================================================
# EFM Model Cache (reuse Asap model across iterations)
# =============================================================================

"""
    EFMModelCache

Mutable cache that holds a built EFM Asap model so it can be reused across
design iterations.  Only the element section properties and load magnitudes
are updated; the topology (nodes, DOFs, connectivity) stays fixed.

Column stubs follow the same pattern as `FEAModelCache`: each joint stores
a `(below=..., above=...)` named tuple with the element and its fixed-end
node.  Roof joints have `above = nothing`.

Create with `EFMModelCache()` before the design loop and pass as the
`efm_cache` keyword to `run_moment_analysis`.
"""
mutable struct EFMModelCache
    initialized::Bool
    model::Union{Nothing, Model}                 # Asap.Model
    span_elements::Vector{Element{FixedFixed}}   # slab-beam elements
    col_stubs::Dict{Int, NamedTuple}             # j => (below=..., above=...)
    n_spans::Int
    # Span property cache (skip rebuild when column sizes + h unchanged)
    _last_span_key::Union{Nothing, UInt64}
    _last_spans::Union{Nothing, Vector}

    EFMModelCache() = new(false, nothing, Element{FixedFixed}[], Dict{Int,NamedTuple}(), 0,
                          nothing, nothing)
end

"""Populate an EFMModelCache from a freshly built model."""
function _populate_efm_cache!(cache::EFMModelCache, model, span_elements, col_stubs, spans)
    cache.initialized    = true
    cache.model          = model
    cache.span_elements  = collect(Element{FixedFixed}, span_elements)
    cache.col_stubs      = col_stubs
    cache.n_spans        = length(spans)
end

"""
    _update_efm_sections_and_loads!(cache, spans, qu, Ecs, Ecc, ν_concrete, ρ_concrete, columns;
                                    col_I_factor, kec_factors, drop_loads)

Update section properties and loads on a cached EFM ASAP model.

Slab-beam sections and line loads are rebuilt from the current spans with
the same sub-element layout the model was built with
([`_efm_span_segments`](@ref)). Column stub sections are updated via
`column_asap_section` — the same single source of truth used by the FEA
path. No Kec → Ic_eff back-solve; the ASAP solver computes column
stiffness from actual geometry.
"""
function _update_efm_sections_and_loads!(
    cache::EFMModelCache,
    spans::Vector{<:EFMSpanProperties},
    qu::Union{Pressure, AbstractVector{<:Pressure}},
    Ecs::Pressure,
    Ecc::Pressure,
    ν_concrete::Float64,
    ρ_concrete,
    columns;
    col_I_factor::Float64 = 0.70,
    kec_factors::Union{Nothing, Vector{Float64}} = nothing,
    drop_loads = nothing,
)
    model = cache.model
    span_elements = cache.span_elements
    n_spans  = cache.n_spans

    l2 = spans[1].l2
    ustrip(l2) > 0 || throw(ArgumentError("Transverse span l2 must be positive (got $l2)"))

    # ── Slab sections, in build order ──
    k = 0
    for i in 1:n_spans
        sp = spans[i]
        for seg in _efm_span_segments(sp, _span_drop(drop_loads, i))
            k += 1
            span_elements[k].section = _efm_segment_section(seg, sp, Ecs, ν_concrete, ρ_concrete)
        end
    end
    k == length(span_elements) || error(
        "EFM cache layout changed ($(length(span_elements)) elements, $k expected); rebuild the model")

    # ── Column stub sections (same as FEA: column_asap_section) ──
    n_joints = n_spans + 1
    for j in 1:n_joints
        haskey(cache.col_stubs, j) || continue
        stubs = cache.col_stubs[j]
        col = columns[j]

        I_j = col_I_factor * (!isnothing(kec_factors) ? kec_factors[j] : 1.0)

        # Below stub (always present)
        stubs.below.element.section = column_asap_section(
            col.c1, col.c2, col_shape(col), Ecc, ν_concrete; I_factor=I_j)

        # Above stub (if column above exists)
        col_above = col.column_above
        if !isnothing(stubs.above) && !isnothing(col_above)
            sec_a = _sized_column_section(col_above)
            c1_a, c2_a = sec_a === nothing ? (col.c1, col.c2) : sec_a
            stubs.above.element.section = column_asap_section(
                c1_a, c2_a, col_shape(col_above), Ecc, ν_concrete;
                I_factor=I_j)
        end
    end

    # ── Loads ──
    _set_efm_slab_loads!(model, spans, qu, drop_loads)

    # Invalidate cached state so next solve! re-processes
    model._factorization = nothing
    model.processed = false
end
