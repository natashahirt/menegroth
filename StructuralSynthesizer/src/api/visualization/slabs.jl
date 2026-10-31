"""Serialize sized slab boundary polygons and utilization for 3D visualization."""
function _serialize_sized_slabs(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits,
                                drop_panel_cache::Dict{Int, Vector{APIDropPanelPatch}})
    sized_slabs = APISizedSlab[]
    sizehint!(sized_slabs, length(struc.slabs))
    skel = struc.skeleton

    slab_concrete = resolve_slab_concrete(design.params.materials)
    slab_mat_color = _material_color_hex(slab_concrete)

    for (slab_idx, slab) in enumerate(struc.slabs)
        slab_result = get(design.slabs, slab_idx, nothing)
        isnothing(slab_result) && continue

        # Collect boundary vertices from all cells
        all_verts_2d = Set{NTuple{2, Float64}}()
        z_coord = 0.0

        for cell_idx in slab.cell_indices
            cell = struc.cells[cell_idx]
            v_indices = skel.face_vertex_indices[cell.face_idx]

            for vi in v_indices
                pt = skel.vertices[vi]
                c = Meshes.coords(pt)
                x = _to_display_length(du, c.x)
                y = _to_display_length(du, c.y)
                z_coord = _to_display_length(du, c.z)
                push!(all_verts_2d, (x, y))
            end
        end

        # Convert to boundary polygon (convex hull for multi-cell slabs)
        verts_2d = collect(all_verts_2d)
        hull_pts = _convex_hull_2d(verts_2d)

        # Convert to 3D vertices at z_top
        boundary_vertices = [[p[1], p[2], z_coord] for p in hull_pts]

        thickness_ft = _to_display_length(du, slab_result.thickness)
        z_top_ft = z_coord
        drop_panels = get(drop_panel_cache, slab_idx, APIDropPanelPatch[])
        ratio = max(slab_result.deflection_ratio, slab_result.punching_max_ratio)
        ok = slab_result.deflection_ok && slab_result.punching_ok
        
        is_vault = slab_result.is_vault
        vault_mesh_vertices = Vector{Float64}[]
        vault_mesh_faces = Vector{Int}[]
        
        if is_vault
            try
                vault_mesh = _serialize_vault_mesh(slab, slab_result, struc, du)
                vault_mesh_vertices = vault_mesh.vertices
                vault_mesh_faces = vault_mesh.faces
            catch e
                @warn "Vault mesh serialization failed for slab $slab_idx — omitting curved mesh" exception=(e, catch_backtrace())
            end
        end
        
        push!(sized_slabs, APISizedSlab(
            slab_id = slab_idx,
            boundary_vertices = [[_round_val(v; digits=6) for v in vert] for vert in boundary_vertices],
            thickness = _round_val(thickness_ft; digits=4),
            z_top = _round_val(z_top_ft; digits=6),
            drop_panels = drop_panels,
            utilization_ratio = _round_val(ratio),
            ok = ok,
            material_color_hex = slab_mat_color,
            is_vault = is_vault,
            vault_mesh_vertices = vault_mesh_vertices,
            vault_mesh_faces = vault_mesh_faces,
        ))
    end
    
    return sized_slabs
end

"""
Build parabolic vault mesh for visualization/serialization.

Uses Asap.get_vault_mesh_data() for Delaunay mesh projected onto parabolic surface.
Returns (vertices=..., faces=...) with vertices in display length units.
"""
function _serialize_vault_mesh(slab, slab_result::SlabDesignResult, struc::BuildingStructure, du::DisplayUnits;
                                target_edge_length::Float64=0.15)
    skel = struc.skeleton
    
    # Build corner nodes from face vertices
    cell_idx = slab.cell_indices[1]
    cell = struc.cells[cell_idx]
    v_indices = skel.face_vertex_indices[cell.face_idx]
    
    # Create temporary Asap nodes for get_vault_mesh_data
    corner_nodes = [let c = Meshes.coords(skel.vertices[vi])
        Asap.Node([c.x, c.y, c.z], :free)
    end for vi in v_indices]
    
    # Get vault mesh data from Asap (Delaunay projected onto parabola)
    span_axis = slab.spans.axis
    rise = slab_result.vault_rise
    
    mesh_data = Asap.get_vault_mesh_data(corner_nodes, span_axis, rise;
                                          target_edge_length=target_edge_length * u"m")
    
    # Convert vertices to display units (scalar multiply — avoids Unitful per vertex)
    _m_to_disp = ustrip(du.units[:length], 1.0u"m")
    vertices = Vector{Float64}[]
    sizehint!(vertices, length(mesh_data.vertices))
    for (x, y, z) in mesh_data.vertices
        push!(vertices, [_round_val(x * _m_to_disp; digits=6),
                         _round_val(y * _m_to_disp; digits=6),
                         _round_val(z * _m_to_disp; digits=6)])
    end
    
    # Convert faces to vectors (JSON serialization)
    faces = [[f[1], f[2], f[3]] for f in mesh_data.faces]
    
    return (vertices=vertices, faces=faces)
end

