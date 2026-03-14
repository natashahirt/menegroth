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
    δ = _section_cut_bandwidth(cache, cell_cols)

    tri_idx = get(cache.cell_tri_indices, ci, Int[])

    # Column negative moments (M⁻) at column face
    col_Mneg = Vector{Float64}(undef, length(cell_cols))
    for (col_i, col) in enumerate(cell_cols)
        px, py = _column_xy_m(skel, col)
        off = _column_face_offset_m(col, span_axis)
        face = (px + off * span_axis[1], py + off * span_axis[2])
        Mn = max(0.0, _integrate_at(cache.element_data, tri_idx, face, span_axis, δ;
            include_torsion=include_torsion))
        col_Mneg[col_i] = Mn

        verbose && @debug "  Col $(col.vertex_idx) ($(col.position)): " *
                          "M⁻=$(round(Mn, digits=0)) N·m  (δ=$(round(δ*1000, digits=0))mm)"
    end

    # Cell positive moment (M⁺) at centroid
    M_pos = max(0.0, -_integrate_at(cache.element_data, tri_idx, cell_centroid, span_axis, δ;
        include_torsion=include_torsion))

    if verbose
        @debug "  Cell $ci: δ=$(round(δ*1000,digits=0))mm  " *
               "centroid=($(round(cx,digits=3)), $(round(cy,digits=3)))  " *
               "M⁺=$(round(M_pos,digits=1)) N·m  n_tris=$(length(tri_idx))"
    end

    return (col_Mneg=col_Mneg, M_pos=M_pos, δ=δ)
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

# Note: _check_bandwidth_convergence has been moved to bandwidth.jl
