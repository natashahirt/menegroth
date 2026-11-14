# =============================================================================
# Frame-Level Moment Extraction (Full-Width Integration)
# =============================================================================
#
# Integrates moments across the full panel width at column faces and midspan,
# producing frame-level M⁻ and M⁺ that are then distributed to column and
# middle strips using ACI fractions (the same downstream path as DDM/EFM).
# =============================================================================

"""
    _extract_cell_strip_moments(cache, skel, ci, cell_poly, cell_centroid, cell_cols,
                                span_axis; verbose=false)

Extract M⁻ (column faces) and M⁺ (cell centroid) for one cell using
precomputed element data from `cache`.
"""
function _extract_cell_strip_moments(
    cache::FEAModelCache,
    skel,
    ci::Int,
    cell_poly::Vector{NTuple{2,Float64}},
    cell_centroid::NTuple{2,Float64},
    cell_cols::Vector,
    span_axis::NTuple{2,Float64};
    include_torsion::Bool = true,
    verbose::Bool = false
)
    cx, cy = cell_centroid
    δ_pos = _section_cut_bandwidth(cache, cell_cols)

    tri_idx = get(cache.cell_tri_indices, ci, Int[])

    # Column negative moments (M⁻) on the span side of each column face.
    col_Mneg = Vector{Float64}(undef, length(cell_cols))
    for (col_i, col) in enumerate(cell_cols)
        sample, δ = _span_side_cut(col, span_axis, _column_xy_m(skel, col), cell_centroid)
        half_w = _averaging_half_width(col, span_axis, cache.averaging_width_factor)
        n_band = _count_band_elements(cache.element_data, tri_idx, sample, span_axis, δ)
        _require_band_elements(n_band, δ, "column $(col.vertex_idx) (cell $ci)")
        faces = _integrate_design_faces(cache, tri_idx, sample, span_axis, δ;
            include_torsion=include_torsion, transverse_half_width=half_w)
        Mn = faces.hogging
        col_Mneg[col_i] = Mn

        verbose && @debug "  Col $(col.vertex_idx) ($(col.position)): " *
                          "M⁻=$(round(Mn, digits=0)) N·m  (δ=$(round(δ*1000, digits=0))mm, n=$n_band)"
    end

    # Cell positive moment (M⁺) at centroid
    M_pos = _integrate_design_faces(cache, tri_idx, cell_centroid, span_axis, δ_pos;
        include_torsion=include_torsion).sagging

    if verbose
        @debug "  Cell $ci: δ⁺=$(round(δ_pos*1000,digits=0))mm  " *
               "centroid=($(round(cx,digits=3)), $(round(cy,digits=3)))  " *
               "M⁺=$(round(M_pos,digits=1)) N·m  n_tris=$(length(tri_idx))"
    end

    return (col_Mneg=col_Mneg, M_pos=M_pos, δ=δ_pos)
end

"""
    _extract_cell_moments(cache, struc, slab, columns, span_axis; verbose)

Per-cell strip integration across all cells using precomputed data
from `cache`.  Returns per-column M⁻ envelope and global M⁺ (Unitful N·m).
"""
function _extract_cell_moments(
    cache::FEAModelCache,
    struc, slab, columns,
    span_axis::NTuple{2,Float64};
    include_torsion::Bool = true,
    verbose::Bool = false
)
    skel = struc.skeleton
    n_cols = length(columns)
    n_cells = length(slab.cell_indices)

    if verbose
        @debug "SPAN-DIRECTION STRIP INTEGRATION: $n_cells cells, $n_cols columns  " *
               "span_axis=$(round.(span_axis, digits=3))"
    end

    col_by_vertex = Dict{Int, Int}(col.vertex_idx => i for (i, col) in enumerate(columns))
    cell_to_cols  = _build_cell_to_columns(columns)

    env_M_pos = 0.0
    col_Mneg = zeros(Float64, n_cols)

    for ci in slab.cell_indices
        cell_cols = get(cell_to_cols, ci, eltype(columns)[])
        isempty(cell_cols) && continue

        geom = _cell_geometry_m(struc, ci; _cache=cache.cell_geometries)

        r = _extract_cell_strip_moments(
            cache, skel, ci, geom.poly, geom.centroid, cell_cols,
            span_axis; include_torsion=include_torsion, verbose=verbose
        )

        env_M_pos = max(env_M_pos, r.M_pos)

        for (j, col) in enumerate(cell_cols)
            idx = get(col_by_vertex, col.vertex_idx, nothing)
            idx === nothing && continue
            col_Mneg[idx] = max(col_Mneg[idx], r.col_Mneg[j])
        end
    end

    if verbose
        @debug "PER-COLUMN ENVELOPE ($n_cells cells)" begin
            lines = ["M⁺=$(round(env_M_pos,digits=1)) N·m"]
            for (i, col) in enumerate(columns)
                push!(lines, "  Col $i ($(col.position)): M⁻=$(round(col_Mneg[i],digits=1)) N·m")
            end
            join(lines, "\n")
        end
    end

    return (
        col_Mneg = col_Mneg,
        M_pos    = env_M_pos * u"N*m",
        n_cells  = n_cells,
    )
end

"""
    _fea_wall_face_moments(cache, struc, slab, span_axis)

Hogging at the face of each wall perpendicular to `span_axis`.

The cut is `_integrate_design_faces`, the same integration the column faces
use. Only elements whose centroids lie along the wall are included, so the
integral is the wall length and not the whole floor. Both sides of the wall
are sampled and the side that has slab elements governs. A wall parallel to
the span belongs to the other direction.
"""
function _fea_wall_face_moments(cache, struc, slab, span_axis)
    ax = _span_unit_axis(span_axis)
    ax === nothing && return NamedTuple[]
    segs = supporting_wall_segments(struc, slab)
    isempty(segs) && return NamedTuple[]
    tris = collect(Int, eachindex(cache.element_data))
    isempty(tris) && return NamedTuple[]
    out = NamedTuple[]
    for seg in segs
        _wall_parallel_to_axis(seg, ax) && continue
        L = hypot(seg[2][1] - seg[1][1], seg[2][2] - seg[1][2])
        L < 1e-3 && continue
        along = _elements_along_wall(cache.element_data, tris, seg, ax)
        isempty(along) && continue
        thick = _wall_thickness(struc, seg)
        t = thick === nothing ? 0.0 : ustrip(u"m", thick)
        mid = ((seg[1][1] + seg[2][1]) / 2, (seg[1][2] + seg[2][2]) / 2)
        δ = 0.20
        off = t / 2 + 0.5 * δ
        best = 0.0
        for dir in (-1.0, 1.0)
            pos = (mid[1] + dir * off * ax[1], mid[2] + dir * off * ax[2])
            _count_band_elements(cache.element_data, along, pos, ax, δ) == 0 && continue
            faces = _integrate_design_faces(cache, along, pos, ax, δ)
            best = max(best, faces.hogging)
        end
        best > 0 || continue
        push!(out, (x = mid[1], y = mid[2], L = L, M = best * u"N*m"))
    end
    return out
end

"""Largest wall-face hogging perpendicular to `span_axis`, in the units of `sample`."""
function _max_wall_face_moment(cache, struc, slab, span_axis, sample)
    faces = _fea_wall_face_moments(cache, struc, slab, span_axis)
    isempty(faces) && return zero(sample)
    return maximum(f -> uconvert(unit(sample), f.M), faces)
end

"""
    _fea_wall_transfer(cache, struc, slab, span_axis) -> Vector

Moment the slab transfers to each wall perpendicular to `span_axis`, as
`(seg, M)`. With slab on one face the transfer is that face's moment; with
slab on both it is the difference of the two faces in the same combination.
The largest over the combinations is kept.
"""
function _fea_wall_transfer(cache, struc, slab, span_axis)
    ax = _span_unit_axis(span_axis)
    ax === nothing && return Any[]
    segs = supporting_wall_segments(struc, slab)
    tris = collect(Int, eachindex(cache.element_data))
    (isempty(segs) || isempty(tris)) && return Any[]
    n_combo = _n_design_combos(cache)
    out = Any[]
    for seg in segs
        _wall_parallel_to_axis(seg, ax) && continue
        hypot(seg[2][1] - seg[1][1], seg[2][2] - seg[1][2]) < 1e-3 && continue
        along = _elements_along_wall(cache.element_data, tris, seg, ax)
        isempty(along) && continue
        thick = _wall_thickness(struc, seg)
        t = thick === nothing ? 0.0 : ustrip(u"m", thick)
        mid = ((seg[1][1] + seg[2][1]) / 2, (seg[1][2] + seg[2][2]) / 2)
        δ = 0.20
        off = t / 2 + 0.5 * δ
        faces = NTuple{2,Float64}[]
        for dir in (-1.0, 1.0)
            pos = (mid[1] + dir * off * ax[1], mid[2] + dir * off * ax[2])
            _count_band_elements(cache.element_data, along, pos, ax, δ) == 0 && continue
            push!(faces, pos)
        end
        isempty(faces) && continue
        best = 0.0
        for i in 1:n_combo
            I = [_integrate_at(cache.element_data, along, pos, ax, δ;
                               tensor_at = k -> _combo_tensor(cache, k, i)) for pos in faces]
            best = max(best, length(I) == 2 ? abs(I[1] - I[2]) : abs(I[1]))
        end
        push!(out, (seg = seg, M = best * u"N*m"))
    end
    return out
end

"""Element indices whose centroids fall along `seg`, measured across the span."""
function _elements_along_wall(element_data, tris, seg, ax)
    perp = (-ax[2], ax[1])
    t1 = seg[1][1] * perp[1] + seg[1][2] * perp[2]
    t2 = seg[2][1] * perp[1] + seg[2][2] * perp[2]
    lo, hi = minmax(t1, t2)
    out = Int[]
    for k in tris
        ed = element_data[k]
        t = ed.cx * perp[1] + ed.cy * perp[2]
        lo - 1e-6 <= t <= hi + 1e-6 && push!(out, k)
    end
    return out
end

# Note: _check_bandwidth_convergence has been moved to bandwidth.jl
