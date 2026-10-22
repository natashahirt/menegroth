# =============================================================================
# δ-Band Moment Integration
# =============================================================================

"""
    _integrate_at(element_data, tri_indices, pos, ax, δ; include_torsion=true)

Integrate span-direction moment across a δ-band at `pos` using
precomputed per-element data.  Returns bare N·m.

Tensor projection projects global span axis `ax` into each element's local
frame via the cached LCS axes.

When `include_torsion=false`, the Mxy cross-term is dropped from the
projection (intentionally unconservative baseline).
"""
function _integrate_at(
    element_data::Vector{FEAElementData},
    tri_indices::Vector{Int},
    pos::NTuple{2,Float64},
    ax::NTuple{2,Float64},
    δ::Float64;
    include_torsion::Bool = true,
    tensor_at = nothing,
)
    s_eval = ax[1] * pos[1] + ax[2] * pos[2]
    half_δ = δ / 2
    Mn_A = 0.0   # N·m·m accumulator
    @inbounds for k in tri_indices
        ed = element_data[k]
        abs(ax[1] * ed.cx + ax[2] * ed.cy - s_eval) > half_δ && continue
        axl = (ax[1]*ed.ex[1] + ax[2]*ed.ex[2], ax[1]*ed.ey[1] + ax[2]*ed.ey[2])
        if tensor_at === nothing
            Mxx, Myy, Mxy = ed.Mxx, ed.Myy, ed.Mxy
        else
            Mxx, Myy, Mxy = tensor_at(k)
        end
        Mn = Mxx*axl[1]^2 + Myy*axl[2]^2
        if include_torsion
            Mn += 2*Mxy*axl[1]*axl[2]
        end
        Mn_A += Mn * ed.area
    end
    return Mn_A / δ
end

# =============================================================================
# Strip-Filtered Moment Integration
# =============================================================================

"""
    _integrate_at_subset(element_data, tri_subset, pos, span_axis, δ;
                         include_torsion=true)

Same as `_integrate_at` but operates on a pre-filtered subset of triangle
indices (e.g. only column-strip or only middle-strip elements).
Returns bare N·m.
"""
function _integrate_at_subset(
    element_data::Vector{FEAElementData},
    tri_subset::Vector{Int},
    pos::NTuple{2,Float64},
    span_axis::NTuple{2,Float64},
    δ::Float64;
    include_torsion::Bool = true,
    tensor_at = nothing,
)
    s_eval = span_axis[1] * pos[1] + span_axis[2] * pos[2]
    half_δ = δ / 2
    Mn_A = 0.0
    @inbounds for k in tri_subset
        ed = element_data[k]
        abs(span_axis[1] * ed.cx + span_axis[2] * ed.cy - s_eval) > half_δ && continue
        axl = (span_axis[1]*ed.ex[1] + span_axis[2]*ed.ex[2],
               span_axis[1]*ed.ey[1] + span_axis[2]*ed.ey[2])
        if tensor_at === nothing
            Mxx, Myy, Mxy = ed.Mxx, ed.Myy, ed.Mxy
        else
            Mxx, Myy, Mxy = tensor_at(k)
        end
        Mn = Mxx*axl[1]^2 + Myy*axl[2]^2
        if include_torsion
            Mn += 2*Mxy*axl[1]*axl[2]
        end
        Mn_A += Mn * ed.area
    end
    return Mn_A / δ
end

"""
    _integrate_design_faces(cache, tri_indices, pos, ax, δ; include_torsion, subset=false)
        -> NamedTuple{(:hogging, :sagging)}

Envelope the δ-band integral over every factored combo in `cache`.

For each combo the full-band integral `I` is evaluated (same projection as
`_integrate_at`).  Faces are then enveloped independently:

    hogging = max_combo max(I, 0)     # Asap-positive / top tension
    sagging = max_combo max(-I, 0)    # Asap-negative / bottom tension

When only one combo exists this equals `max(I, 0)` / `max(-I, 0)` of the
stored tensor — byte-identical to the historical callers.
"""
function _integrate_design_faces(
    cache::FEAModelCache,
    tri_indices::Vector{Int},
    pos::NTuple{2,Float64},
    ax::NTuple{2,Float64},
    δ::Float64;
    include_torsion::Bool = true,
    subset::Bool = false,
)
    n_combo = _n_design_combos(cache)
    hog = 0.0
    sag = 0.0
    integrate = subset ? _integrate_at_subset : _integrate_at
    for i in 1:n_combo
        I = integrate(cache.element_data, tri_indices, pos, ax, δ;
                      include_torsion=include_torsion,
                      tensor_at = k -> _combo_tensor(cache, k, i))
        hog = max(hog, max(I, 0.0))
        sag = max(sag, max(-I, 0.0))
    end
    return (hogging=hog, sagging=sag)
end

"""Element-wise max of two strip-extraction NamedTuples (all fields ≥ 0)."""
function _max_strip_nt(a, b)
    return (
        M_neg_ext_cs = max(a.M_neg_ext_cs, b.M_neg_ext_cs),
        M_neg_int_cs = max(a.M_neg_int_cs, b.M_neg_int_cs),
        M_pos_cs     = max(a.M_pos_cs,     b.M_pos_cs),
        M_neg_ext_ms = max(a.M_neg_ext_ms, b.M_neg_ext_ms),
        M_neg_int_ms = max(a.M_neg_int_ms, b.M_neg_int_ms),
        M_pos_ms     = max(a.M_pos_ms,     b.M_pos_ms),
    )
end

"""
Write combo `i` tensors onto `cache.element_data` (used by nodal extract,
which builds a smoothed field from the stored triplets).  Caller must
restore the previous values.
"""
function _apply_combo_tensors!(cache::FEAModelCache, i::Int)
    @inbounds for k in eachindex(cache.element_data)
        t = _combo_tensor(cache, k, i)
        cache.element_data[k].Mxx = t[1]
        cache.element_data[k].Myy = t[2]
        cache.element_data[k].Mxy = t[3]
    end
    return nothing
end

function _restore_tensors!(cache::FEAModelCache, saved::Vector{NTuple{3,Float64}})
    @inbounds for k in eachindex(cache.element_data)
        cache.element_data[k].Mxx = saved[k][1]
        cache.element_data[k].Myy = saved[k][2]
        cache.element_data[k].Mxy = saved[k][3]
    end
    return nothing
end
