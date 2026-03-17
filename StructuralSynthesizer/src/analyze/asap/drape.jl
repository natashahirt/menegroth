# =============================================================================
# Drape Shell Deflections Over Frame
# =============================================================================
#
# Extracts shell local bending from the coupled (frame+shell) analysis model
# so that visualization can show:
#   - total displacement: the coupled model's own result (consistent with frames)
#   - local bending: slab deflection relative to support (column-top) nodes
#
# Algorithm for each shell mesh node P:
#   total(P)         = δ_coupled(P)
#   local_bending(P) = δ_coupled(P) - bilinear_interp(bay supports at P)
#
# At support nodes (shared with frame elements):
#   total = coupled displacement  (matches frame endpoint exactly)
#   local_bending = [0, 0, 0]
#
# Interpolation strategy:
#   - Primary: bilinear interpolation within the enclosing structural bay
#     (quadrilateral defined by 4 surrounding column nodes). This correctly
#     models the nearly-linear displacement field of a stiff slab panel.
#   - Fallback: IDW for nodes that fall outside all bays (e.g. slab boundary).
# =============================================================================

# ─── Bay-local bilinear interpolation ─────────────────────────────────────────

"""
A rectangular structural bay with support displacement data at 4 corners.

Corners are labeled by their position in the axis-aligned bounding box:
- `d00`: (xmin, ymin)
- `d10`: (xmax, ymin)
- `d01`: (xmin, ymax)
- `d11`: (xmax, ymax)
"""
struct _Bay
    xmin::Float64
    xmax::Float64
    ymin::Float64
    ymax::Float64
    d00::Vector{Float64}
    d10::Vector{Float64}
    d01::Vector{Float64}
    d11::Vector{Float64}
end

"""
    _build_bays(design, slab_idx, sup_x, sup_y, sup_disp) -> Vector{_Bay}

Build rectangular bay structures for a slab from its cells.
Each bay is one cell/panel with 4 corner columns whose displacements are known.
"""
function _build_bays(design::BuildingDesign, slab_idx::Int,
                     sup_x::Vector{Float64}, sup_y::Vector{Float64},
                     sup_disp::Vector{Vector{Float64}})
    struc = design.structure
    skel = struc.skeleton

    slab_idx > length(struc.slabs) && return _Bay[]
    slab = struc.slabs[slab_idx]

    # Position → displacement lookup (rounded keys for floating-point tolerance)
    tol = 1e-4
    round_c(x) = round(Int64, x / tol)
    pos_disp = Dict{Tuple{Int64,Int64}, Vector{Float64}}()
    for i in eachindex(sup_x)
        pos_disp[(round_c(sup_x[i]), round_c(sup_y[i]))] = sup_disp[i]
    end

    bays = _Bay[]
    for cell_idx in slab.cell_indices
        cell = struc.cells[cell_idx]
        cell.floor_type == :grade && continue
        vis = skel.face_vertex_indices[cell.face_idx]
        length(vis) == 4 || continue

        # Corner XY coordinates (meters) from cached matrix
        vc = skel.geometry.vertex_coords
        cxs = [vc[vi, 1] for vi in vis]
        cys = [vc[vi, 2] for vi in vis]

        xmin, xmax = extrema(cxs)
        ymin, ymax = extrema(cys)

        # Look up displacements at the 4 canonical corners
        d00 = get(pos_disp, (round_c(xmin), round_c(ymin)), nothing)
        d10 = get(pos_disp, (round_c(xmax), round_c(ymin)), nothing)
        d01 = get(pos_disp, (round_c(xmin), round_c(ymax)), nothing)
        d11 = get(pos_disp, (round_c(xmax), round_c(ymax)), nothing)

        # All 4 corners must be resolvable
        (d00 === nothing || d10 === nothing || d01 === nothing || d11 === nothing) && continue

        push!(bays, _Bay(xmin, xmax, ymin, ymax, d00, d10, d01, d11))
    end
    return bays
end

"""
    _bay_interpolate(px, py, bays) -> Union{Vector{Float64}, Nothing}

Find the enclosing bay for point `(px, py)` and bilinearly interpolate
the 4-corner support displacements.  Returns `nothing` when the point
is outside every bay (caller should fall back to IDW).
"""
function _bay_interpolate(px::Float64, py::Float64, bays::Vector{_Bay})
    tol = 1e-6
    for bay in bays
        if bay.xmin - tol <= px <= bay.xmax + tol &&
           bay.ymin - tol <= py <= bay.ymax + tol
            dx = bay.xmax - bay.xmin
            dy = bay.ymax - bay.ymin
            s = dx > 1e-12 ? clamp((px - bay.xmin) / dx, 0.0, 1.0) : 0.5
            t = dy > 1e-12 ? clamp((py - bay.ymin) / dy, 0.0, 1.0) : 0.5
            return @. (1-s)*(1-t) * bay.d00 +
                      s*(1-t)     * bay.d10 +
                      (1-s)*t     * bay.d01 +
                      s*t         * bay.d11
        end
    end
    return nothing
end

# ─── IDW fallback ─────────────────────────────────────────────────────────────

"""
    _idw_interpolate(qx, qy, sx, sy, vals; power=2.0)

2D inverse-distance weighted interpolation (fallback for nodes outside all bays).
"""
function _idw_interpolate(qx::Float64, qy::Float64,
                          sx::Vector{Float64}, sy::Vector{Float64},
                          vals::Vector{Vector{Float64}};
                          power::Float64=2.0)
    n = length(sx)
    n == 0 && return [0.0, 0.0, 0.0]
    n == 1 && return copy(vals[1])

    for i in 1:n
        d = sqrt((qx - sx[i])^2 + (qy - sy[i])^2)
        d < 1e-10 && return copy(vals[i])
    end

    result = [0.0, 0.0, 0.0]
    w_total = 0.0
    for i in 1:n
        d = sqrt((qx - sx[i])^2 + (qy - sy[i])^2)
        w = 1.0 / d^power
        result .+= w .* vals[i]
        w_total += w
    end
    result ./= w_total
    return result
end

"""
    _solve_3x3(A, b) -> Union{Vector{Float64}, Nothing}

Solve a 3x3 linear system using an explicit adjugate/determinant formula.
Returns `nothing` if the matrix is singular or ill-conditioned.
"""
function _solve_3x3(A::Matrix{Float64}, b::Vector{Float64})
    a11, a12, a13 = A[1, 1], A[1, 2], A[1, 3]
    a21, a22, a23 = A[2, 1], A[2, 2], A[2, 3]
    a31, a32, a33 = A[3, 1], A[3, 2], A[3, 3]

    detA =
        a11 * (a22 * a33 - a23 * a32) -
        a12 * (a21 * a33 - a23 * a31) +
        a13 * (a21 * a32 - a22 * a31)

    abs(detA) < 1e-12 && return nothing

    c11 =  (a22 * a33 - a23 * a32)
    c12 = -(a21 * a33 - a23 * a31)
    c13 =  (a21 * a32 - a22 * a31)
    c21 = -(a12 * a33 - a13 * a32)
    c22 =  (a11 * a33 - a13 * a31)
    c23 = -(a11 * a32 - a12 * a31)
    c31 =  (a12 * a23 - a13 * a22)
    c32 = -(a11 * a23 - a13 * a21)
    c33 =  (a11 * a22 - a12 * a21)

    invA = Matrix{Float64}(undef, 3, 3)
    invA[1, 1] = c11 / detA; invA[1, 2] = c21 / detA; invA[1, 3] = c31 / detA
    invA[2, 1] = c12 / detA; invA[2, 2] = c22 / detA; invA[2, 3] = c32 / detA
    invA[3, 1] = c13 / detA; invA[3, 2] = c23 / detA; invA[3, 3] = c33 / detA

    return invA * b
end

"""
    _weighted_affine_interpolate(qx, qy, sx, sy, vals; power=2.0)

Primary fallback when bay interpolation is unavailable:
fit an affine field `f(x,y)=a+b*x+c*y` using weighted least squares over supports.
This yields a smoother support field than pure IDW while preserving exact values
at support points.
"""
function _weighted_affine_interpolate(
    qx::Float64, qy::Float64,
    sx::Vector{Float64}, sy::Vector{Float64},
    vals::Vector{Vector{Float64}};
    power::Float64=2.0
)
    n = length(sx)
    n < 3 && return nothing

    # Enforce exact values at support points.
    for i in 1:n
        d = sqrt((qx - sx[i])^2 + (qy - sy[i])^2)
        d < 1e-10 && return copy(vals[i])
    end

    w = Vector{Float64}(undef, n)
    for i in 1:n
        d = sqrt((qx - sx[i])^2 + (qy - sy[i])^2)
        w[i] = 1.0 / (d^power + 1e-12)
    end

    s0 = 0.0; sxw = 0.0; syw = 0.0; sxx = 0.0; sxy = 0.0; syy = 0.0
    for i in 1:n
        wi = w[i]; xi = sx[i]; yi = sy[i]
        s0  += wi
        sxw += wi * xi
        syw += wi * yi
        sxx += wi * xi * xi
        sxy += wi * xi * yi
        syy += wi * yi * yi
    end

    A = [s0 sxw syw;
         sxw sxx sxy;
         syw sxy syy]

    result = [0.0, 0.0, 0.0]
    for c in 1:3
        t0 = 0.0; tx = 0.0; ty = 0.0
        for i in 1:n
            wi = w[i]; xi = sx[i]; yi = sy[i]; vi = vals[i][c]
            t0 += wi * vi
            tx += wi * xi * vi
            ty += wi * yi * vi
        end
        rhs = [t0, tx, ty]
        coeff = _solve_3x3(A, rhs)
        coeff === nothing && return nothing
        result[c] = coeff[1] + coeff[2] * qx + coeff[3] * qy
    end

    return result
end

# ─── Geometric support fallback ───────────────────────────────────────────────

"""
    _adaptive_slab_z_tol(struc, slab_z) -> Float64

Choose a robust elevation-matching tolerance from nearby story spacing.
Keeps tolerance tight for dense floors while still handling minor numeric drift.
"""
function _adaptive_slab_z_tol(struc::BuildingStructure, slab_z::Float64)
    stories = sort(unique([ustrip(u"m", z) for z in struc.skeleton.stories_z]))
    if length(stories) < 2
        return 0.15
    end

    # Nearest non-zero story spacing around this slab elevation.
    deltas = sort(abs.(stories .- slab_z))
    nearest_nonzero = findfirst(d -> d > 1e-9, deltas)
    spacing = nearest_nonzero === nothing ? 0.6 : deltas[nearest_nonzero]

    # Use a quarter of spacing, bounded to practical limits.
    return clamp(0.25 * spacing, 0.02, 0.15)
end

"""
    _geometric_support_nodes_for_slab(design, shell_model, slab_id) -> Vector{Asap.Node}

When a slab has no shell nodes that are identity-equal to frame endpoints, build a
support set geometrically from columns supporting that slab at slab elevation.
"""
function _geometric_support_nodes_for_slab(
    design::BuildingDesign,
    shell_model,
    slab_id::Symbol,
)
    slab_idx = tryparse(Int, String(slab_id)[6:end])
    slab_idx === nothing && return (
        supports = Asap.Node[],
        support_vertices = Int[],
        z_tol = 0.15,
        n_supporting_columns = 0,
    )

    struc = design.structure
    (slab_idx < 1 || slab_idx > length(struc.slabs)) && return (
        supports = Asap.Node[],
        support_vertices = Int[],
        z_tol = 0.15,
        n_supporting_columns = 0,
    )
    slab = struc.slabs[slab_idx]

    # Slab elevation from any face vertex (all vertices on the cell face share z).
    skel = struc.skeleton
    first_cell = struc.cells[first(slab.cell_indices)]
    first_vi = skel.face_vertex_indices[first_cell.face_idx][1]
    slab_z = skel.geometry.vertex_coords[first_vi, 3]
    z_tol = _adaptive_slab_z_tol(struc, slab_z)

    supports = Asap.Node[]
    seen = Set{UInt64}()
    support_vertices = Int[]
    supporting_cols = StructuralSizer.find_supporting_columns(struc, Set(slab.cell_indices))
    for col in supporting_cols
        vi = _column_vertex_at_slab_level(struc, col, slab_z; z_tol=z_tol)
        vi === nothing && continue
        (vi < 1 || vi > length(shell_model.nodes)) && continue
        n = shell_model.nodes[vi]
        nid = objectid(n)
        if nid ∉ seen
            push!(supports, n)
            push!(seen, nid)
            push!(support_vertices, vi)
        end
    end

    return (
        supports = supports,
        support_vertices = support_vertices,
        z_tol = z_tol,
        n_supporting_columns = length(supporting_cols),
    )
end

# ─── Main entry point ─────────────────────────────────────────────────────────

"""
    compute_draped_displacements(design::BuildingDesign)

Compute shell node displacements split into total and local-bending components.

Returns `(total, local_bending)` where each is a
`Dict{UInt64, Vector{Float64}}` keyed by `objectid(node)`:

- `total`: coupled model displacement `[dx, dy, dz]`.
- `local_bending`: slab bending relative to supports `[dx, dy, dz]`.

Uses **bay-local bilinear interpolation** to estimate the support displacement
field. This avoids IDW artifacts from differential column shortening that can
produce spurious upward local deflections at midspan with coarse meshes.
"""
function compute_draped_displacements(design::BuildingDesign)
    empty_result = (total = Dict{UInt64, Vector{Float64}}(),
                    local_bending = Dict{UInt64, Vector{Float64}}(),
                    slab_shells = Dict{Symbol, Vector{Asap.ShellElement}}())

    shell_model = design.asap_model

    if isnothing(shell_model) || !Asap.has_shell_elements(shell_model)
        return empty_result
    end

    total_dict = Dict{UInt64, Vector{Float64}}()
    local_dict = Dict{UInt64, Vector{Float64}}()

    # ── Identify frame nodes in the coupled model ──
    frame_node_set = Set{Asap.Node}()
    for el in shell_model.elements
        push!(frame_node_set, el.nodeStart)
        push!(frame_node_set, el.nodeEnd)
    end

    # ── Group shell elements by slab ID ──
    # Base slab shells use id=:slab_N. _apply_patches! overwrites some to :col_patch or
    # :drop_panel; those must be merged into their parent slab for visualization.
    slab_shells = Dict{Symbol, Vector{Asap.ShellElement}}()
    patch_shells = Asap.ShellElement[]  # col_patch and drop_panel elements
    n_drop_panel = 0
    n_col_patch = 0
    for shell in shell_model.shell_elements
        if shell.id in (:col_patch, :drop_panel)
            push!(patch_shells, shell)
            shell.id == :drop_panel && (n_drop_panel += 1)
            shell.id == :col_patch  && (n_col_patch += 1)
        else
            shells = get!(slab_shells, shell.id, Asap.ShellElement[])
            push!(shells, shell)
        end
    end
    @debug "Drape shell grouping" n_total=length(shell_model.shell_elements) n_patch=length(patch_shells) n_drop_panel n_col_patch slab_keys=collect(keys(slab_shells))

    # ── Merge patch shells into parent slab groups ──
    # Assign each col_patch/drop_panel shell to the slab whose boundary contains its centroid.
    struc = design.structure
    offsets = design.structural_offsets
    for shell in patch_shells
        n1, n2, n3 = shell.nodes
        cx = (ustrip(u"m", n1.position[1]) + ustrip(u"m", n2.position[1]) + ustrip(u"m", n3.position[1])) / 3
        cy = (ustrip(u"m", n1.position[2]) + ustrip(u"m", n2.position[2]) + ustrip(u"m", n3.position[2])) / 3
        centroid = (cx, cy)
        assigned = false
        for (slab_idx, slab) in enumerate(struc.slabs)
            boundary_vis, _ = _get_slab_boundary_vertices(struc, slab)
            vc = struc.skeleton.geometry.vertex_coords
            boundary_pts = Tuple{Float64, Float64}[
                (vc[vi, 1] + get(offsets, vi, (0.0, 0.0))[1],
                 vc[vi, 2] + get(offsets, vi, (0.0, 0.0))[2])
                for vi in boundary_vis
            ]
            if _point_inside_polygon(centroid, boundary_pts)
                slab_id = Symbol("slab_$(slab_idx)")
                shells = get!(slab_shells, slab_id, Asap.ShellElement[])
                push!(shells, shell)
                assigned = true
                break
            end
        end
        # If no slab contains the centroid (e.g. degenerate), attach to first slab with matching elevation
        if !assigned && !isempty(struc.slabs)
            slab_z = ustrip(u"m", n1.position[3])
            for (slab_idx, slab) in enumerate(struc.slabs)
                first_cell = struc.cells[first(slab.cell_indices)]
                first_vi = struc.skeleton.face_vertex_indices[first_cell.face_idx][1]
                cell_z = struc.skeleton.geometry.vertex_coords[first_vi, 3]
                if abs(slab_z - cell_z) < 0.15
                    slab_id = Symbol("slab_$(slab_idx)")
                    shells = get!(slab_shells, slab_id, Asap.ShellElement[])
                    push!(shells, shell)
                    break
                end
            end
        end
    end

    # ── Process each slab ──
    for (slab_id, shells) in slab_shells

        # Collect unique support nodes for this slab.
        # Primary path: shell nodes that are identity-equal to frame endpoints.
        support_nodes = Asap.Node[]
        seen = Set{UInt64}()
        for shell in shells, node in shell.nodes
            nid = objectid(node)
            if node in frame_node_set && nid ∉ seen
                push!(support_nodes, node)
                push!(seen, nid)
            end
        end

        used_geometric_fallback = false
        fallback_support_vertices = Int[]
        fallback_z_tol = 0.15
        fallback_column_count = 0
        if isempty(support_nodes)
            # Fallback: geometric support recovery from supporting columns at slab elevation.
            fallback = _geometric_support_nodes_for_slab(design, shell_model, slab_id)
            support_nodes = fallback.supports
            fallback_support_vertices = fallback.support_vertices
            fallback_z_tol = fallback.z_tol
            fallback_column_count = fallback.n_supporting_columns
            used_geometric_fallback = !isempty(support_nodes)
        end

        if isempty(support_nodes)
            @warn "Drape supports missing for slab; local_bending will fall back to total displacement." slab_id z_tol=fallback_z_tol supporting_columns=fallback_column_count
            for shell in shells, node in shell.nodes
                d = Asap.to_displacement_vec(node.displacement)[1:3]
                total_dict[objectid(node)] = d
                local_dict[objectid(node)] = d
            end
            continue
        end
        if used_geometric_fallback
            @warn "Drape slab recovered supports via geometric fallback (column-based)." slab_id support_count=length(support_nodes) supporting_columns=fallback_column_count z_tol=fallback_z_tol support_vertices=fallback_support_vertices
        end

        if length(support_nodes) < 3
            @warn "Drape slab has insufficient supports for smooth local interpolation; using total displacement for local_bending." slab_id support_count=length(support_nodes)
            for shell in shells, node in shell.nodes
                d = Asap.to_displacement_vec(node.displacement)[1:3]
                total_dict[objectid(node)] = d
                local_dict[objectid(node)] = d
            end
            continue
        end

        # Build support arrays
        sup_x = Float64[ustrip(u"m", sn.position[1]) for sn in support_nodes]
        sup_y = Float64[ustrip(u"m", sn.position[2]) for sn in support_nodes]
        sup_disp = Vector{Float64}[Asap.to_displacement_vec(sn.displacement)[1:3]
                                    for sn in support_nodes]

        # Build bay lookup from slab cells
        slab_idx = tryparse(Int, String(slab_id)[6:end])
        bays = if slab_idx !== nothing
            _build_bays(design, slab_idx, sup_x, sup_y, sup_disp)
        else
            _Bay[]
        end

        # Drape each shell node
        bay_count = 0
        affine_count = 0
        idw_count = 0
        local_count = 0
        for shell in shells, node in shell.nodes
            nid = objectid(node)
            haskey(total_dict, nid) && continue

            δ_coupled = Asap.to_displacement_vec(node.displacement)[1:3]
            total_dict[nid] = δ_coupled

            if node in frame_node_set
                local_dict[nid] = [0.0, 0.0, 0.0]
            else
                nx = ustrip(u"m", node.position[1])
                ny = ustrip(u"m", node.position[2])
                local_count += 1

                # Primary: bilinear within enclosing bay.
                coupled_field = _bay_interpolate(nx, ny, bays)
                if coupled_field === nothing
                    # Secondary: smooth weighted affine interpolation over supports.
                    coupled_field = _weighted_affine_interpolate(nx, ny, sup_x, sup_y, sup_disp)
                    if coupled_field === nothing
                        # Last resort: IDW.
                        coupled_field = _idw_interpolate(nx, ny, sup_x, sup_y, sup_disp)
                        idw_count += 1
                    else
                        affine_count += 1
                    end
                else
                    bay_count += 1
                end

                local_dict[nid] = δ_coupled .- coupled_field
            end
        end
        if idw_count > 0
            @warn "Drape slab used IDW fallback for some shell nodes (outside bay/affine interpolation)." slab_id bay_nodes=bay_count affine_nodes=affine_count idw_nodes=idw_count local_nodes=local_count support_count=length(support_nodes)
        end
    end

    return (total = total_dict, local_bending = local_dict, slab_shells = slab_shells)
end
