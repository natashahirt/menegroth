# =============================================================================
# Section-Cut Bandwidth — Initial Heuristic + Adaptive Convergence
# =============================================================================

"""
    _section_cut_bandwidth(cache, cell_cols) -> Float64

Compute the initial δ-band width (meters) for section-cut moment integration.

The band must be wide enough to capture several element rows (for a smooth
integral) but narrow enough that the moment field doesn't vary significantly
across it.  The formula uses the **mesh edge length** as the primary scale:

    δ = max(3 × h_mesh, c_avg)

where:
- `h_mesh` is the characteristic mesh edge length (median of √(2A) over all
  triangles, stored in `cache.mesh_edge_length`).  The factor of 3 ensures
  the band always spans ≥ 3 element rows, giving a well-sampled integral.
- `c_avg` is the average column dimension — the band should not be narrower
  than the column face it's sampling at.

Fallback: if `mesh_edge_length` is not yet computed (cache not initialized),
uses `c_avg` with a 0.25 m floor (legacy behavior).

This is used as the **initial guess** for the adaptive bandwidth refinement
(see `_adaptive_bandwidth`).  When adaptive mode is disabled, this value is
used directly.
"""
function _section_cut_bandwidth(cache::FEAModelCache, cell_cols)::Float64
    c_avg_m = isempty(cell_cols) ? 0.3 :
        sum(max(ustrip(u"m", c.c1), ustrip(u"m", c.c2)) for c in cell_cols) / length(cell_cols)

    h_mesh = cache.mesh_edge_length
    if h_mesh > 0
        return max(3 * h_mesh, c_avg_m)
    end
    # Fallback (cache not yet initialized)
    return max(c_avg_m, 0.25)
end

# =============================================================================
# Adaptive Bandwidth Convergence
# =============================================================================

"""
    _adaptive_bandwidth(integrate_fn, δ_init;
                        tol=0.05, max_iter=6, δ_min_factor=0.5, δ_max_factor=3.0)
        -> (δ_final, M_final, converged)

Refine the section-cut bandwidth `δ` by testing whether the integrated moment
is stable with respect to bandwidth changes.

# Algorithm
Starting from the heuristic `δ_init`:
1. Evaluate `M₀ = integrate_fn(δ_init)`.
2. Test a geometric sequence of bandwidths:
   `δ_narrow = δ_init × r⁻¹`, `δ_wide = δ_init × r` where `r = √2`.
3. If `|M_wide - M₀| / |M₀| < tol` AND `|M_narrow - M₀| / |M₀| < tol`,
   the bandwidth is converged — return `δ_init`.
4. Otherwise, shift `δ_init` toward the more stable direction and repeat.

The iteration is bounded by `[δ_init × δ_min_factor, δ_init × δ_max_factor]`
and stops after `max_iter` iterations.

# Arguments
- `integrate_fn`: `δ -> Float64` — evaluates the moment integral at bandwidth δ.
  This is typically a closure over `_integrate_at` or `_integrate_at_subset`
  with the position, axis, and element data already bound.
- `δ_init`: Initial bandwidth guess (from `_section_cut_bandwidth`).
- `tol`: Relative tolerance for convergence (default 5%).
- `max_iter`: Maximum refinement iterations (default 6).
- `δ_min_factor`: Minimum δ as fraction of `δ_init` (default 0.5).
- `δ_max_factor`: Maximum δ as fraction of `δ_init` (default 3.0).

# Returns
- `δ_final`: Refined bandwidth (meters).
- `M_final`: Moment at the refined bandwidth (N·m).
- `converged`: Whether the adaptive iteration converged within tolerance.

# Notes
- If the moment is near zero (< 1e-3 N·m), returns immediately with `δ_init`.
- The adaptive iteration adds ~2–6 extra integration evaluations per section cut.
  For production runs with many section cuts, consider disabling adaptive mode
  (use `_section_cut_bandwidth` directly).
"""
function _adaptive_bandwidth(
    integrate_fn,
    δ_init::Float64;
    tol::Float64 = 0.05,
    max_iter::Int = 6,
    δ_min_factor::Float64 = 0.5,
    δ_max_factor::Float64 = 3.0,
)
    δ_min = δ_init * δ_min_factor
    δ_max = δ_init * δ_max_factor
    r = sqrt(2.0)  # geometric step ratio

    δ = δ_init
    M = integrate_fn(δ)

    # Near-zero moment → no refinement needed
    abs(M) < 1e-3 && return (δ, M, true)

    converged = false
    for _ in 1:max_iter
        δ_narrow = max(δ / r, δ_min)
        δ_wide   = min(δ * r, δ_max)

        M_narrow = integrate_fn(δ_narrow)
        M_wide   = integrate_fn(δ_wide)

        # Relative change from narrow to wide
        Δ_narrow = abs(M) > 1e-6 ? abs(M_narrow - M) / abs(M) : 0.0
        Δ_wide   = abs(M) > 1e-6 ? abs(M_wide - M) / abs(M)   : 0.0

        if Δ_narrow < tol && Δ_wide < tol
            converged = true
            break
        end

        # Move toward the more stable direction
        if Δ_narrow < Δ_wide
            # Narrowing is more stable → shrink δ
            δ = δ_narrow
            M = M_narrow
        else
            # Widening is more stable → grow δ
            δ = δ_wide
            M = M_wide
        end
    end

    return (δ, M, converged)
end

# =============================================================================
# Section-Cut Bandwidth Convergence Diagnostic
# =============================================================================

"""
    _check_bandwidth_convergence(cache, struc, slab, columns, span_axis)

Compare strip-integration results at δ vs 2δ to verify that the section-cut
bandwidth is not significantly affecting the design moments.

Logs a warning if any moment changes by > 5% when δ is doubled.
Only called in verbose mode — zero cost in production.
"""
function _check_bandwidth_convergence(
    cache::FEAModelCache, struc, slab, columns,
    span_axis::NTuple{2,Float64},
)
    skel = struc.skeleton
    col_by_vertex = Dict{Int, Int}(col.vertex_idx => i for (i, col) in enumerate(columns))
    cell_to_cols  = _build_cell_to_columns(columns)
    n_cols = length(columns)

    for ci in slab.cell_indices
        cell_cols = get(cell_to_cols, ci, eltype(columns)[])
        isempty(cell_cols) && continue

        geom = _cell_geometry_m(struc, ci; _cache=cache.cell_geometries)
        tri_idx = get(cache.cell_tri_indices, ci, Int[])
        δ = _section_cut_bandwidth(cache, cell_cols)

        col = first(cell_cols)
        px, py = _column_xy_m(skel, col)
        off = _column_face_offset_m(col, span_axis)
        face = (px + off * span_axis[1], py + off * span_axis[2])

        Mn_δ  = _integrate_at(cache.element_data, tri_idx, face, span_axis, δ)
        Mn_2δ = _integrate_at(cache.element_data, tri_idx, face, span_axis, 2δ)

        Mp_δ  = -_integrate_at(cache.element_data, tri_idx, geom.centroid, span_axis, δ)
        Mp_2δ = -_integrate_at(cache.element_data, tri_idx, geom.centroid, span_axis, 2δ)

        Δ_neg = abs(Mn_δ) > 1e-3 ? abs(Mn_2δ - Mn_δ) / abs(Mn_δ) * 100 : 0.0
        Δ_pos = abs(Mp_δ) > 1e-3 ? abs(Mp_2δ - Mp_δ) / abs(Mp_δ) * 100 : 0.0

        h_mm = round(cache.mesh_edge_length * 1000, digits=0)
        δ_mm = round(δ * 1000, digits=0)
        @debug "BANDWIDTH CONVERGENCE (cell $ci)" h_mesh="$(h_mm)mm" δ="$(δ_mm)mm" M⁻_Δ="$(round(Δ_neg, digits=1))%" M⁺_Δ="$(round(Δ_pos, digits=1))%"

        if Δ_neg > 5.0 || Δ_pos > 5.0
            @warn "Section-cut bandwidth sensitivity > 5%: M⁻ Δ=$(round(Δ_neg, digits=1))%, " *
                  "M⁺ Δ=$(round(Δ_pos, digits=1))%. Consider refining the mesh " *
                  "(current h_mesh=$(h_mm)mm, δ=$(δ_mm)mm)."
        end
        break  # one cell is sufficient for the diagnostic
    end
end
