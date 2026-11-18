# =============================================================================
# Force Extraction from Column Stubs
# =============================================================================

"""
    _extract_stub_forces_at_slab(stub; slab_end=:nodeEnd) -> (Fz, Mx, My)

Extract column forces from a column stub element at the slab connection.
Returns Unitful (N, N·m).

`slab_end` specifies which end of the element connects to the slab:
- `:nodeEnd` (default) — below stub: base(fixed) → slab, slab is nodeEnd (indices 7-12)
- `:nodeStart` — above stub: slab → top(fixed), slab is nodeStart (indices 1-6)

Forces are read in the element's LCS and transformed to GCS.
"""
function _extract_stub_forces_at_slab(stub; slab_end::Symbol = :nodeEnd)
    elem = stub.element
    X = elem.LCS[1]   # element X axis in GCS
    y = elem.LCS[2]   # element y axis in GCS
    z = elem.LCS[3]   # element z axis in GCS

    if slab_end === :nodeEnd
        P    = elem.forces[7]
        Vy   = elem.forces[8]
        Vz   = elem.forces[9]
        T    = elem.forces[10]
        My_l = elem.forces[11]
        Mz_l = elem.forces[12]
    else
        P    = elem.forces[1]
        Vy   = elem.forces[2]
        Vz   = elem.forces[3]
        T    = elem.forces[4]
        My_l = elem.forces[5]
        Mz_l = elem.forces[6]
    end

    # Transform to GCS
    Fz   = (P * X[3] + Vy * y[3] + Vz * z[3]) * u"N"
    Mx_g = (T * X[1] + My_l * y[1] + Mz_l * z[1]) * u"N*m"
    My_g = (T * X[2] + My_l * y[2] + Mz_l * z[2]) * u"N*m"

    return (Fz=Fz, Mx=Mx_g, My=My_g)
end

"""
    _extract_fea_column_forces(col_stubs, span_axis, n_cols)

Extract column forces from solved stubs. Returns Unitful vectors.

`Vu`, `Mu`, `Mub`, `Mx`, and `My` sum the stub below the slab and the stub
above it. That sum is the joint unbalanced moment. Punching uses it
(ACI 318-11 §13.5.3.1, corpus: aci-318-11, page 250).

`Mub_below`, `Mx_below`, and `My_below` are the same components from the
stub below the slab only. The column under the slab is designed for that
moment. The shell already includes the stub above, so the §13.6.9.2
stiffness split is not applied again. `Mub_above`, `Mx_above`, and
`My_above` are the stub above, zero where there is no column above; that
column's bottom end is checked with them.
"""
function _extract_fea_column_forces(col_stubs, span_axis::NTuple{2, Float64}, n_cols::Int)
    ax_len = hypot(span_axis...)
    ax = ax_len > 1e-9 ? (span_axis[1] / ax_len, span_axis[2] / ax_len) : (1.0, 0.0)

    ForceT  = typeof(1.0kip)
    MomentT = typeof(1.0kip * u"ft")
    Vu  = Vector{ForceT}(undef, n_cols)
    Mu  = Vector{MomentT}(undef, n_cols)
    Mub = Vector{MomentT}(undef, n_cols)
    Mx  = Vector{MomentT}(undef, n_cols)
    My  = Vector{MomentT}(undef, n_cols)
    Mub_below = Vector{MomentT}(undef, n_cols)
    Mx_below  = Vector{MomentT}(undef, n_cols)
    My_below  = Vector{MomentT}(undef, n_cols)
    Mub_above = Vector{MomentT}(undef, n_cols)
    Mx_above  = Vector{MomentT}(undef, n_cols)
    My_above  = Vector{MomentT}(undef, n_cols)

    for i in 1:n_cols
        stubs = col_stubs[i]

        # Below stub — slab is nodeEnd
        fb = _extract_stub_forces_at_slab(stubs.below; slab_end=:nodeEnd)
        # Above stub — slab is nodeStart (if present)
        fa = isnothing(stubs.above) ? (Fz = 0.0u"N", Mx = 0.0u"N*m", My = 0.0u"N*m") :
            _extract_stub_forces_at_slab(stubs.above; slab_end=:nodeStart)
        Fz_total = fb.Fz + fa.Fz
        Mx_total = fb.Mx + fa.Mx
        My_total = fb.My + fa.My

        Vu[i]  = uconvert(kip, abs(Fz_total))
        Mu[i]  = uconvert(kip * u"ft", hypot(Mx_total, My_total))
        # Joint moment, both stubs. Punching and the stored transfer use this.
        Mub[i] = uconvert(kip * u"ft", abs(ax[1] * My_total - ax[2] * Mx_total))
        Mx[i]  = uconvert(kip * u"ft", Mx_total)
        My[i]  = uconvert(kip * u"ft", My_total)
        # Each stub on its own. Not a replacement for Mub.
        Mub_below[i] = uconvert(kip * u"ft", abs(ax[1] * fb.My - ax[2] * fb.Mx))
        Mx_below[i]  = uconvert(kip * u"ft", fb.Mx)
        My_below[i]  = uconvert(kip * u"ft", fb.My)
        Mub_above[i] = uconvert(kip * u"ft", abs(ax[1] * fa.My - ax[2] * fa.Mx))
        Mx_above[i]  = uconvert(kip * u"ft", fa.Mx)
        My_above[i]  = uconvert(kip * u"ft", fa.My)
    end

    return (
        Vu=Vu, Mu=Mu, Mub=Mub, Mx=Mx, My=My,
        Mub_below=Mub_below, Mx_below=Mx_below, My_below=My_below,
        Mub_above=Mub_above, Mx_above=Mx_above, My_above=My_above,
    )
end

# =============================================================================
# FEA-Based One-Way Shear Demand  (ACI 318-11 §22.5)
# =============================================================================

"""Empty diagnostic for a cut that cannot be formed."""
function _empty_one_way_shear_cut()
    return (
        Vu = 0.0kip,
        cut_length = 0.0u"m",
        band_width = 0.0u"m",
        n_elements = 0,
    )
end

"""
    _integrate_one_way_shear_cut(element_data, cx, cy, c1_m, nx, ny, d_m, δ, half_width)

Integrate transverse shear on the two faces at `c1/2 + d` from a column.

The cut is bounded to the frame-strip half-width `half_width` measured from
the column line. An unbounded cut on a multi-bay mesh integrates the whole
slab width and compares it with the one-bay `l2` capacity.

Signed `Q_n` is summed first. The section resultant is the absolute value of
that sum. Taking the absolute value element by element prevents cancellation
and inflates the demand.

For a uniform intensity the band of depth `2δ` has area `L · 2δ`, so
`Vu = Σ(Q_n · A) / (2δ)`.

# Reference
ACI 318-11 §11.1.3.1 — critical section at `d` from the face of support
(corpus: aci-318-11, via `one_way_shear_demand`).
"""
function _integrate_one_way_shear_cut(
    element_data,
    cx::Float64, cy::Float64,
    c1_m::Float64,
    nx::Float64, ny::Float64,
    d_m::Float64,
    δ::Float64,
    half_width::Float64,
)
    δ < 1e-9 && return (Vu_N = 0.0, n_elements = 0)
    tx, ty = -ny, nx
    n_ed = length(element_data)
    projs = Vector{Float64}(undef, n_ed)
    for i in 1:n_ed
        ed = element_data[i]
        projs[i] = ed.cx * nx + ed.cy * ny
    end
    order = sortperm(projs)
    sorted_proj = projs[order]
    band_pad = 1e-6
    Vu_max = 0.0
    n_used = 0

    for sign in (-1.0, 1.0)
        cut_dist = sign * (c1_m / 2 + d_m)
        cut_s = (cx + cut_dist * nx) * nx + (cy + cut_dist * ny) * ny
        lo = searchsortedfirst(sorted_proj, cut_s - δ - band_pad)
        hi = searchsortedlast(sorted_proj, cut_s + δ + band_pad)
        lo > hi && continue
        Vu_band = 0.0
        n_in_band = 0
        for k in lo:hi
            ed = element_data[order[k]]
            proj = (ed.cx * nx + ed.cy * ny) - cut_s
            abs(proj) > δ && continue
            t = (ed.cx - cx) * tx + (ed.cy - cy) * ty
            abs(t) > half_width && continue
            Qgx = ed.Qxz * ed.ex[1] + ed.Qyz * ed.ey[1]
            Qgy = ed.Qxz * ed.ex[2] + ed.Qyz * ed.ey[2]
            Q_n = Qgx * nx + Qgy * ny
            Vu_band += Q_n * ed.area
            n_in_band += 1
        end
        if n_in_band > 0
            Vu_section = abs(Vu_band) / (2 * δ)
            if Vu_section > Vu_max
                Vu_max = Vu_section
                n_used = n_in_band
            end
        end
    end
    return (Vu_N = Vu_max, n_elements = n_used)
end

"""
    _extract_fea_one_way_shear(cache, columns, span_axis, d, bw; verbose=false)

Diagnostic FEA one-way shear. `bw` is the frame-strip width (`l2`). The
result does not govern thickness; `check_one_way_shear` uses the analytical
demand shared with DDM and EFM.

# Reference
ACI 318-11 §11.1.3.1, critical section at `d` from the support face.
"""
function _extract_fea_one_way_shear(
    cache::FEAModelCache,
    columns,
    span_axis::NTuple{2, Float64},
    d::Length,
    bw::Length;
    verbose::Bool = false,
)
    ax_len = hypot(span_axis...)
    ax_len < 1e-9 && return _empty_one_way_shear_cut()
    nx = span_axis[1] / ax_len
    ny = span_axis[2] / ax_len
    δ = cache.mesh_edge_length
    δ < 1e-9 && return _empty_one_way_shear_cut()

    d_m = ustrip(u"m", d)
    half_width = ustrip(u"m", bw) / 2
    half_width < 1e-9 && return _empty_one_way_shear_cut()

    Vu_max = 0.0
    n_elements = 0
    for (col_idx, col) in enumerate(columns)
        stub_data = get(cache.col_stubs, col_idx, nothing)
        stub_data === nothing && continue
        slab_node = stub_data.below.slab_node
        cx = ustrip(u"m", slab_node.position[1])
        cy = ustrip(u"m", slab_node.position[2])
        cut = _integrate_one_way_shear_cut(
            cache.element_data, cx, cy, ustrip(u"m", col.c1),
            nx, ny, d_m, δ, half_width,
        )
        if cut.Vu_N > Vu_max
            Vu_max = cut.Vu_N
            n_elements = cut.n_elements
        end
    end

    Vu_result = uconvert(kip, Vu_max * u"N")
    if verbose
        @debug "FEA ONE-WAY SHEAR (diagnostic)" Vu=Vu_result bw=bw δ_mm=round(δ * 1000, digits=1) n=n_elements
    end
    return (
        Vu = Vu_result,
        cut_length = bw,
        band_width = (2 * δ) * u"m",
        n_elements = n_elements,
    )
end