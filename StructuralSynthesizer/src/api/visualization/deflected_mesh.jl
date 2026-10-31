"""Build node → skeleton vertex index mapping. Model nodes are created from skeleton vertices in order."""
function _node_to_vertex_map(model)
    node_to_vi = Dict{Asap.Node, Int}()
    for (vi, n) in enumerate(model.nodes)
        node_to_vi[n] = vi
    end
    return node_to_vi
end

"""Serialize shell-element meshes with global/local vertex displacements for deflected slab visualization.
For boundary vertices at column supports with structural offset, uses the architectural (column-corner)
position instead of the centroid so deflected meshes align with zero-deflection/sized geometry."""
function _serialize_deflected_slab_meshes(design::BuildingDesign, struc::BuildingStructure, model, du::DisplayUnits,
                                          drop_panel_cache::Dict{Int, Vector{APIDropPanelPatch}})
    deflected_meshes = APIDeflectedSlabMesh[]

    !Asap.has_shell_elements(model) && return deflected_meshes

    # Precompute meters→display-length scale factor (avoids per-value Unitful dispatch in inner loop)
    _m_to_disp = ustrip(du.units[:length], 1.0u"m")

    slab_concrete = resolve_slab_concrete(design.params.materials)
    slab_mat_color = _material_color_hex(slab_concrete)

    draped = compute_draped_displacements(design)
    total_disp = draped.total
    local_disp = draped.local_bending
    slab_shells = draped.slab_shells

    sif_ws = Asap.ShellForcesWorkspace()
    node_to_vi = _node_to_vertex_map(model)
    offsets = design.structural_offsets

    # Extract mesh data per slab (grouping already done by compute_draped_displacements)
    for (slab_id_sym, shells) in slab_shells
        # Extract slab index from symbol (e.g., :slab_1 -> 1)
        slab_idx = try
            parse(Int, string(slab_id_sym)[6:end])  # Remove "slab_" prefix
        catch
            continue
        end

        slab_result = get(design.slabs, slab_idx, nothing)
        isnothing(slab_result) && continue
        slab_idx > length(struc.slabs) && continue
        slab = struc.slabs[slab_idx]
        boundary_segments = _slab_boundary_segments_with_offsets(struc, slab, offsets, _m_to_disp)

        # Collect all vertices and faces from shell elements
        # Each ShellTri3 is a triangle with 3 nodes
        n_shells = length(shells)
        n_verts_est = div(n_shells * 3, 2)  # ~shared vertices in triangle mesh

        vertices = Vector{Float64}[]
        vertex_displacements = Vector{Float64}[]
        vertex_displacements_local = Vector{Float64}[]
        faces = Vector{Int}[]
        sizehint!(vertices, n_verts_est)
        sizehint!(vertex_displacements, n_verts_est)
        sizehint!(vertex_displacements_local, n_verts_est)
        sizehint!(faces, n_shells)
        vertex_map = Dict{Asap.Node, Int}()
        sizehint!(vertex_map, n_verts_est)
        # Weld nodes by geometric proximity so patch shells (e.g. col_patch/drop_panel)
        # share vertices with adjacent slab shells even when coordinates differ by tiny
        # numeric drift after export transforms/rounding.
        weld_eps = 5e-5
        weld_eps2 = weld_eps^2
        weld_inv = 1.0 / weld_eps
        vertex_bin_map = Dict{NTuple{3, Int}, Vector{Int}}()
        sizehint!(vertex_bin_map, n_verts_est)

        # Per-face analytical values (one entry per triangle, parallel to `faces`)
        face_bending = Float64[]
        face_membrane = Float64[]
        face_shear = Float64[]
        face_vm = Float64[]
        face_surf = Float64[]
        sizehint!(face_bending, n_shells)
        sizehint!(face_membrane, n_shells)
        sizehint!(face_shear, n_shells)
        sizehint!(face_vm, n_shells)
        sizehint!(face_surf, n_shells)

        drop_panel_face_indices = Int[]

        for shell in shells
            shell_nodes = shell.nodes
            if length(shell_nodes) == 3
                tri_indices = Int[]
                for node in shell_nodes
                    if !haskey(vertex_map, node)
                        npos = node.position
                        vi = get(node_to_vi, node, 0)
                        off = (vi > 0 ? get(offsets, vi, (0.0, 0.0)) : (0.0, 0.0))
                        # Export support-boundary shell vertices at architectural slab coordinates.
                        px = _round_val((ustrip(u"m", npos[1]) - off[1]) * _m_to_disp; digits=6)
                        py = _round_val((ustrip(u"m", npos[2]) - off[2]) * _m_to_disp; digits=6)
                        pz = _round_val(ustrip(u"m", npos[3]) * _m_to_disp; digits=6)

                        vidx, is_new = _register_welded_vertex!(vertices, vertex_bin_map,
                            px, py, pz, weld_eps2, weld_inv)
                        if !is_new
                            vertex_map[node] = vidx
                        else
                            nid = objectid(node)
                            disp_global_m = get(total_disp, nid, Asap.to_displacement_vec(node.displacement)[1:3])
                            disp_local_m = get(local_disp, nid, disp_global_m)

                            push!(vertex_displacements, [_round_val(d * _m_to_disp; digits=6) for d in disp_global_m])
                            push!(vertex_displacements_local, [_round_val(d * _m_to_disp; digits=6) for d in disp_local_m])

                            vertex_map[node] = vidx
                        end
                    end
                    push!(tri_indices, vertex_map[node])
                end
                push!(faces, tri_indices)

                if shell.id == :drop_panel
                    push!(drop_panel_face_indices, length(faces))
                end

                _append_shell_analytical!(face_bending, face_membrane, face_shear,
                                          face_vm, face_surf, shell, model.u, sif_ws)
            end
        end
        _align_mesh_boundary_to_architectural_edges!(vertices, faces, boundary_segments)

        thickness_ft = _to_display_length(du, slab_result.thickness)
        drop_panels = get(drop_panel_cache, slab_idx, APIDropPanelPatch[])
        ratio = max(slab_result.deflection_ratio, slab_result.punching_max_ratio)
        ok = slab_result.deflection_ok && slab_result.punching_ok
        is_vault = slab_result.is_vault

        dp_geom = isnothing(slab_result) ? nothing : slab_result.drop_panel
        dp_extra = isnothing(dp_geom) ? 0.0 : _to_display_length(du, dp_geom.h_drop)
        dp_meshes = if !isempty(drop_panel_face_indices) && dp_extra > 0
            [APIDeflectedDropPanel(face_indices=drop_panel_face_indices, extra_depth=_round_val(dp_extra; digits=4))]
        else
            APIDeflectedDropPanel[]
        end
        @debug "Deflected slab $slab_idx drop panel" n_dp_faces=length(drop_panel_face_indices) dp_extra has_dp_geom=!isnothing(dp_geom) n_dp_meshes=length(dp_meshes)
        
        push!(deflected_meshes, APIDeflectedSlabMesh(
            slab_id = slab_idx,
            vertices = vertices,
            vertex_displacements = vertex_displacements,
            vertex_displacements_local = vertex_displacements_local,
            faces = faces,
            thickness = _round_val(thickness_ft; digits=4),
            drop_panels = drop_panels,
            drop_panel_meshes = dp_meshes,
            utilization_ratio = _round_val(ratio),
            ok = ok,
            material_color_hex = slab_mat_color,
            is_vault = is_vault,
            face_bending_moment = [_round_val(v; digits=4) for v in face_bending],
            face_membrane_force = [_round_val(v; digits=4) for v in face_membrane],
            face_shear_force = [_round_val(v; digits=4) for v in face_shear],
            face_von_mises = [_round_val(v; digits=4) for v in face_vm],
            face_surface_stress = [_round_val(v; digits=4) for v in face_surf],
        ))
    end
    
    return _merge_deflected_slab_meshes_by_slab_id(deflected_meshes)
end

"""Project 2D point to segment and return `(qx, qy, t, d2)`."""
function _project_to_segment_2d(px::Float64, py::Float64,
                                x0::Float64, y0::Float64,
                                x1::Float64, y1::Float64)
    dx = x1 - x0
    dy = y1 - y0
    denom = dx * dx + dy * dy
    if denom <= 1e-18
        qx = x0
        qy = y0
        return (qx, qy, 0.0, (px - qx)^2 + (py - qy)^2)
    end
    t = clamp(((px - x0) * dx + (py - y0) * dy) / denom, 0.0, 1.0)
    qx = x0 + t * dx
    qy = y0 + t * dy
    return (qx, qy, t, (px - qx)^2 + (py - qy)^2)
end

"""Collect mesh naked-boundary vertex indices from triangle faces."""
function _mesh_naked_boundary_vertices(faces::Vector{Vector{Int}})
    edge_count = Dict{Tuple{Int, Int}, Int}()
    for tri in faces
        length(tri) == 3 || continue
        i1, i2, i3 = tri
        for (a, b) in ((i1, i2), (i2, i3), (i3, i1))
            key = a <= b ? (a, b) : (b, a)
            edge_count[key] = get(edge_count, key, 0) + 1
        end
    end
    vids = Set{Int}()
    for ((a, b), c) in edge_count
        c == 1 || continue
        push!(vids, a)
        push!(vids, b)
    end
    return collect(vids)
end

"""Boundary segments with architectural baseline and structural-offset vectors."""
function _slab_boundary_segments_with_offsets(
    struc::BuildingStructure,
    slab,
    offsets::Dict{Int, NTuple{2, Float64}},
    m_to_disp::Float64
)
    boundary_vis = Int[]
    try
        boundary_vis, _ = _get_slab_boundary_vertices(struc, slab)
    catch
        return NamedTuple[]
    end
    isempty(boundary_vis) && return NamedTuple[]

    vc = struc.skeleton.geometry.vertex_coords
    segs = NamedTuple[]
    n = length(boundary_vis)
    for i in 1:n
        vi0 = boundary_vis[i]
        vi1 = boundary_vis[mod1(i + 1, n)]
        off0 = get(offsets, vi0, (0.0, 0.0))
        off1 = get(offsets, vi1, (0.0, 0.0))

        ax0 = vc[vi0, 1] * m_to_disp
        ay0 = vc[vi0, 2] * m_to_disp
        ax1 = vc[vi1, 1] * m_to_disp
        ay1 = vc[vi1, 2] * m_to_disp
        ox0 = off0[1] * m_to_disp
        oy0 = off0[2] * m_to_disp
        ox1 = off1[1] * m_to_disp
        oy1 = off1[2] * m_to_disp

        push!(segs, (
            ax0=ax0, ay0=ay0, ax1=ax1, ay1=ay1,
            sx0=ax0 + ox0, sy0=ay0 + oy0, sx1=ax1 + ox1, sy1=ay1 + oy1,
            ox0=ox0, oy0=oy0, ox1=ox1, oy1=oy1,
        ))
    end
    return segs
end

"""
Align naked-boundary mesh vertices to architectural slab boundary.

A vertex is shifted only when it is demonstrably closer to a structural-shifted
boundary segment than to the architectural baseline segment.
"""
function _align_mesh_boundary_to_architectural_edges!(
    vertices::Vector{Vector{Float64}},
    faces::Vector{Vector{Int}},
    boundary_segments
)
    isempty(vertices) && return nothing
    isempty(faces) && return nothing
    isempty(boundary_segments) && return nothing

    for vid in _mesh_naked_boundary_vertices(faces)
        (vid < 1 || vid > length(vertices)) && continue
        p = vertices[vid]
        length(p) >= 2 || continue
        px = p[1]
        py = p[2]

        d2_struct_best = Inf
        d2_arch_best = Inf
        seg_best = nothing
        t_best = 0.0

        for seg in boundary_segments
            _, _, t_s, d2_s = _project_to_segment_2d(px, py, seg.sx0, seg.sy0, seg.sx1, seg.sy1)
            if d2_s < d2_struct_best
                d2_struct_best = d2_s
                t_best = t_s
                seg_best = seg
            end
            _, _, _, d2_a = _project_to_segment_2d(px, py, seg.ax0, seg.ay0, seg.ax1, seg.ay1)
            d2_a < d2_arch_best && (d2_arch_best = d2_a)
        end

        isnothing(seg_best) && continue
        if d2_struct_best + 1e-10 < d2_arch_best
            ox = (1.0 - t_best) * seg_best.ox0 + t_best * seg_best.ox1
            oy = (1.0 - t_best) * seg_best.oy0 + t_best * seg_best.oy1
            p[1] = _round_val(px - ox; digits=6)
            p[2] = _round_val(py - oy; digits=6)
        end
    end
    return nothing
end

@inline function _weld_bin_key(x::Float64, y::Float64, z::Float64, inv::Float64)
    return (
        floor(Int, x * inv),
        floor(Int, y * inv),
        floor(Int, z * inv),
    )
end

function _find_welded_vertex(
    vertices::Vector{Vector{Float64}},
    bin_map::Dict{NTuple{3, Int}, Vector{Int}},
    x::Float64, y::Float64, z::Float64,
    eps2::Float64, inv::Float64
)
    bx, by, bz = _weld_bin_key(x, y, z, inv)
    for dx in -1:1, dy in -1:1, dz in -1:1
        key = (bx + dx, by + dy, bz + dz)
        haskey(bin_map, key) || continue
        for vi in bin_map[key]
            p = vertices[vi]
            d2 = (p[1] - x)^2 + (p[2] - y)^2 + (p[3] - z)^2
            if d2 <= eps2
                return vi
            end
        end
    end
    return 0
end

function _register_welded_vertex!(
    vertices::Vector{Vector{Float64}},
    bin_map::Dict{NTuple{3, Int}, Vector{Int}},
    x::Float64, y::Float64, z::Float64,
    eps2::Float64, inv::Float64
)
    vi = _find_welded_vertex(vertices, bin_map, x, y, z, eps2, inv)
    if vi > 0
        return vi, false
    end

    push!(vertices, [x, y, z])
    vi = length(vertices)
    key = _weld_bin_key(x, y, z, inv)
    push!(get!(bin_map, key, Int[]), vi)
    return vi, true
end

"""
Ensure there is exactly one deflected slab mesh token per slab_id.
Merges duplicate tokens by welding vertices on exported coordinates and remapping
faces, analytical arrays, and drop_panel_meshes face indices accordingly.
"""
function _merge_deflected_slab_meshes_by_slab_id(
    meshes::Vector{APIDeflectedSlabMesh})
    isempty(meshes) && return meshes

    grouped = Dict{Int, Vector{APIDeflectedSlabMesh}}()
    for m in meshes
        push!(get!(grouped, m.slab_id, APIDeflectedSlabMesh[]), m)
    end

    slab_ids = sort(collect(keys(grouped)))
    merged = APIDeflectedSlabMesh[]
    sizehint!(merged, length(slab_ids))

    for sid in slab_ids
        tokens = grouped[sid]
        push!(merged, _merge_deflected_slab_mesh_group(tokens))
    end

    return merged
end

function _merge_deflected_slab_mesh_group(tokens::Vector{APIDeflectedSlabMesh})
    isempty(tokens) && return APIDeflectedSlabMesh()

    # Tolerance-based welding in exported coordinates (display units).
    weld_eps = 5e-5
    weld_eps2 = weld_eps^2
    weld_inv = 1.0 / weld_eps

    vertices = Vector{Float64}[]
    disps_g = Vector{Float64}[]
    disps_l = Vector{Float64}[]
    faces = Vector{Int}[]
    fb = Float64[]
    fm = Float64[]
    fs = Float64[]
    fvm = Float64[]
    fss = Float64[]
    dp_meshes = APIDeflectedDropPanel[]

    vertex_bin_map = Dict{NTuple{3, Int}, Vector{Int}}()

    for tok in tokens
        local_to_global = Dict{Int, Int}()
        sizehint!(local_to_global, length(tok.vertices))

        for (li, v) in enumerate(tok.vertices)
            length(v) < 3 && continue
            vi, is_new = _register_welded_vertex!(vertices, vertex_bin_map,
                v[1], v[2], v[3], weld_eps2, weld_inv)
            if is_new
                push!(disps_g, li <= length(tok.vertex_displacements) ? tok.vertex_displacements[li] : [0.0, 0.0, 0.0])
                push!(disps_l, li <= length(tok.vertex_displacements_local) ? tok.vertex_displacements_local[li] : [0.0, 0.0, 0.0])
            end
            local_to_global[li] = vi
        end

        # Map old face index (1-based) -> merged face index (1-based)
        old_to_new_face = Dict{Int, Int}()
        for (fi, face) in enumerate(tok.faces)
            length(face) < 3 && continue
            i1 = get(local_to_global, face[1], 0)
            i2 = get(local_to_global, face[2], 0)
            i3 = get(local_to_global, face[3], 0)
            (i1 <= 0 || i2 <= 0 || i3 <= 0) && continue

            push!(faces, [i1, i2, i3])
            new_fi = length(faces)
            old_to_new_face[fi] = new_fi

            push!(fb, fi <= length(tok.face_bending_moment) ? tok.face_bending_moment[fi] : 0.0)
            push!(fm, fi <= length(tok.face_membrane_force) ? tok.face_membrane_force[fi] : 0.0)
            push!(fs, fi <= length(tok.face_shear_force) ? tok.face_shear_force[fi] : 0.0)
            push!(fvm, fi <= length(tok.face_von_mises) ? tok.face_von_mises[fi] : 0.0)
            push!(fss, fi <= length(tok.face_surface_stress) ? tok.face_surface_stress[fi] : 0.0)
        end

        for dpm in tok.drop_panel_meshes
            mapped_faces = Int[]
            for old_fi in dpm.face_indices
                if haskey(old_to_new_face, old_fi)
                    push!(mapped_faces, old_to_new_face[old_fi])
                end
            end
            if !isempty(mapped_faces)
                push!(dp_meshes, APIDeflectedDropPanel(
                    face_indices = mapped_faces,
                    extra_depth = dpm.extra_depth,
                ))
            end
        end
    end

    # Slab-level fields should be identical across tokens; use robust reductions.
    first_tok = tokens[1]
    utilization = maximum(getfield.(tokens, :utilization_ratio))
    ok = all(getfield.(tokens, :ok))
    thickness = maximum(getfield.(tokens, :thickness))
    is_vault = any(getfield.(tokens, :is_vault))
    mat_hex = first_tok.material_color_hex
    for t in tokens
        if !isempty(t.material_color_hex)
            mat_hex = t.material_color_hex
            break
        end
    end

    drop_panels = first_tok.drop_panels
    for t in tokens
        if !isempty(t.drop_panels)
            drop_panels = t.drop_panels
            break
        end
    end

    return APIDeflectedSlabMesh(
        slab_id = first_tok.slab_id,
        vertices = vertices,
        vertex_displacements = disps_g,
        vertex_displacements_local = disps_l,
        faces = faces,
        thickness = thickness,
        drop_panels = drop_panels,
        drop_panel_meshes = dp_meshes,
        utilization_ratio = utilization,
        ok = ok,
        material_color_hex = mat_hex,
        is_vault = is_vault,
        face_bending_moment = fb,
        face_membrane_force = fm,
        face_shear_force = fs,
        face_von_mises = fvm,
        face_surface_stress = fss,
    )
end

