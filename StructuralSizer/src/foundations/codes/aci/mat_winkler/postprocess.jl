# ─────────────────────────────────────────────────────────────────────────────
# Column-strip moment integration (analogous to slab FEA _integrate_at)
# ─────────────────────────────────────────────────────────────────────────────

"""
    _strip_moment(cx, cy, area, M, n, span_pos, span_half, trans_pos, trans_half)

Area-weighted average moment per unit length within a rectangular strip.

Selects elements whose centroid is within `span_half` of `span_pos` along the
span direction AND within `trans_half` of `trans_pos` in the transverse direction.

Returns `Σ(M_i × A_i) / Σ(A_i)` (N·m/m), i.e. the average moment *intensity*
within the strip.  Multiply by full mat width for total As.

This is the mat-foundation analog of the slab FEA's `_integrate_at()`, which
integrates within cell-scoped triangles at column faces and midspan sections.
"""
function _strip_moment(
    cx_arr::Vector{Float64}, cy_arr::Vector{Float64},
    area_arr::Vector{Float64}, M_arr::Vector{Float64}, n::Int,
    span_pos::Float64, span_half::Float64,
    trans_pos::Float64, trans_half::Float64,
)
    Mn_A   = 0.0   # N·m·m accumulator (moment × area)
    strip_A = 0.0   # m²   accumulator (total area in strip)
    @inbounds for k in 1:n
        abs(cx_arr[k] - span_pos)  > span_half  && continue
        abs(cy_arr[k] - trans_pos) > trans_half  && continue
        Mn_A    += M_arr[k] * area_arr[k]
        strip_A += area_arr[k]
    end
    return strip_A > 1e-10 ? Mn_A / strip_A : 0.0
end

