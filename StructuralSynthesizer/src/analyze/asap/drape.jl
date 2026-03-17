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

        # Collect unique support nodes for this slab
        support_nodes = Asap.Node[]
        seen = Set{UInt64}()
        for shell in shells, node in shell.nodes
            nid = objectid(node)
            if node in frame_node_set && nid ∉ seen
                push!(support_nodes, node)
                push!(seen, nid)
            end
        end

        if isempty(support_nodes)
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

                # Bilinear within enclosing bay; IDW fallback for boundary nodes
                coupled_field = _bay_interpolate(nx, ny, bays)
                if coupled_field === nothing
                    coupled_field = _idw_interpolate(nx, ny, sup_x, sup_y, sup_disp)
                end

                local_dict[nid] = δ_coupled .- coupled_field
            end
        end
    end

    return (total = total_dict, local_bending = local_dict, slab_shells = slab_shells)
end
