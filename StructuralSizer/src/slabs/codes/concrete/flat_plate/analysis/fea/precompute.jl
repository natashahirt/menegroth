# =============================================================================
# Per-Element Precompute + Build-or-Update Entry Point
# =============================================================================

"""
    _precompute_element_data!(cache, model, struc, slab)

After each solve, extract per-element data (centroid, area, bending moments,
LCS axes) into flat arrays.  Also builds cell → triangle index mapping.

This replaces per-element calls to `bending_moments()`, `shell_centroid()`,
and `shell_tris_in_region()` during strip integration.
"""
function _precompute_element_data!(cache::FEAModelCache, model, struc, slab)
    shell_vec = model.shell_elements
    n = length(shell_vec)

    # Geometry (centroid, area, LCS) is mesh-invariant; only moments/shears change.
    first_pass = isempty(cache.element_data)

    # Workspace for zero-alloc ShellInternalForces (moments + transverse shear)
    sif_ws = Asap.ShellForcesWorkspace()

    if first_pass
        resize!(cache.element_data, n)
        @inbounds for k in 1:n
            tri = shell_vec[k]
            tri isa Asap.ShellTri3 || continue
            # A wall triangle is the pier below the slab. Its area and
            # moments are not slab-panel data.
            if tri.id === :wall
                cache.element_data[k] = FEAElementData(
                    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, (1.0, 0.0), (0.0, 1.0))
                continue
            end
            sif = Asap.ShellInternalForces(tri, model.u, sif_ws)
            tc = Asap.shell_centroid(tri)
            cache.element_data[k] = FEAElementData(
                tc.x, tc.y, tri.area,
                sif.Mxx, sif.Myy, sif.Mxy,
                sif.Qxz, sif.Qyz,
                (tri.LCS[1][1], tri.LCS[1][2]),
                (tri.LCS[2][1], tri.LCS[2][2]),
            )
        end

        # Cell → triangle index mapping (mesh-invariant).
        # Uses bounding-box pre-check to skip expensive point-in-polygon tests.
        empty!(cache.cell_tri_indices)
        for ci in slab.cell_indices
            geom = _cell_geometry_m(struc, ci; _cache=cache.cell_geometries)
            poly = geom.poly
            # Compute cell bounding box (with small tolerance for edge elements)
            xmin = minimum(v[1] for v in poly)
            xmax = maximum(v[1] for v in poly)
            ymin = minimum(v[2] for v in poly)
            ymax = maximum(v[2] for v in poly)
            pad = 0.01 * max(xmax - xmin, ymax - ymin)  # 1% padding
            xmin -= pad; xmax += pad; ymin -= pad; ymax += pad

            indices = Int[]
            for k in 1:n
                ed = cache.element_data[k]
                ed.area > 0 || continue
                # Fast bbox rejection
                (ed.cx < xmin || ed.cx > xmax || ed.cy < ymin || ed.cy > ymax) && continue
                Asap._point_in_polygon((ed.cx, ed.cy), poly) && push!(indices, k)
            end
            cache.cell_tri_indices[ci] = indices
        end

        # Characteristic mesh edge length: median of √(2A) over all triangles.
        areas = Float64[cache.element_data[k].area for k in 1:n
                        if cache.element_data[k].area > 0]
        if !isempty(areas)
            sort!(areas)
            med_area = areas[div(length(areas) + 1, 2)]
            cache.mesh_edge_length = sqrt(2 * med_area)
        end
    else
        # ── Update: geometry unchanged, overwrite moments + shears ──
        @inbounds for k in 1:n
            tri = shell_vec[k]
            tri isa Asap.ShellTri3 || continue
            tri.id === :wall && continue
            sif = Asap.ShellInternalForces(tri, model.u, sif_ws)
            ed = cache.element_data[k]
            ed.Mxx = sif.Mxx
            ed.Myy = sif.Myy
            ed.Mxy = sif.Mxy
            ed.Qxz = sif.Qxz
            ed.Qyz = sif.Qyz
        end
    end
end

# =============================================================================
# Build-or-Update Entry Point
# =============================================================================

"""
    _build_or_update_fea!(cache, struc, slab, columns, h, Ecs, ν, qu, Lc;
                          Ecc, target_edge, verbose, qD, qL)

If `cache` is uninitialized, build a fresh model.  Otherwise update
section/load/stubs on the existing mesh and re-solve.
Either way, precomputes per-element data afterward.

## D/L Split Solve

When `qD` and `qL` are provided, the model is solved separately for each
unfactored load case and the governing factored combination is written into
`cache.element_data`.  This enables proper post-solve load combination and
FEA-native pattern loading.

When `qD`/`qL` are omitted, the legacy single-solve path is used (model
solved once with the pre-factored `qu`).

`Ecc` is the column concrete modulus (defaults to `Ecs` for same-strength).
"""
function _build_or_update_fea!(
    cache::FEAModelCache, struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
    Ecc::Pressure = Ecs,
    target_edge::Union{Nothing, Length} = nothing,
    verbose::Bool = false,
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    col_I_factor::Float64 = 0.70,
    qD::Union{Nothing, Pressure} = nothing,
    qL::Union{Nothing, Pressure} = nothing,
    patch_stiffness_factor::Float64 = 100.0,
    edge_beam_βt::Float64 = 0.0,
    edge_beam_l2::Union{Nothing, Length} = nothing,
    edge_beam_c1_avg::Union{Nothing, Length} = nothing,
    q_drop::Pressure = 0.0u"Pa",
    fixed_mesh::Bool = false,
    fixed_mesh_cap::Union{Nothing, Length} = nothing,
)
    split_dl = !isnothing(qD) && !isnothing(qL)
    # `q_drop` is the unfactored drop self-weight. It takes the dead factor of
    # the combination that sets `qu`. Without qD/qL that combination is
    # unknown and the larger dead factor, 1.4, is used.
    q_drop_Pa = ustrip(u"Pa", isnothing(drop_panel) ? 0.0u"Pa" : q_drop)
    q_drop_u = (split_dl ? governing_dead_factor(qD, qL) : 1.4) * q_drop_Pa * u"Pa"

    # The update path keeps the mesh, so it is only valid for the geometry the
    # mesh was built from. A grown column changes its patch polygon and the
    # refinement edge; rebuild rather than analyze around the old footprint.
    mesh_key = fea_mesh_key(struc, slab, columns;
                            target_edge=target_edge, drop_panel=drop_panel,
                            fixed_mesh=fixed_mesh, fixed_mesh_cap=fixed_mesh_cap)
    if cache.initialized && cache.mesh_key != mesh_key
        @debug "FEAModelCache" event=:rebuild reason="mesh_key_changed"
        _reset_fea_cache!(cache)
    end
    cache.q_drop = q_drop_Pa

    # If the user toggled edge-beam configuration between iterations (added or
    # removed), we must rebuild the mesh — `_update_and_resolve!` cannot add or
    # remove frame elements.
    eb_active_now = edge_beam_βt > 0
    eb_active_cache = cache.edge_beam_βt > 0
    eb_topology_changed = cache.initialized && (eb_active_now != eb_active_cache)

    if !cache.initialized || eb_topology_changed
        cache.n_rebuilds += 1
        @debug "FEAModelCache" event=:rebuild reason=(!cache.initialized ? "uninitialized" : "edge_beam_topology_changed")
        if eb_topology_changed
            cache.initialized = false
            empty!(cache.element_data)
            empty!(cache.cell_tri_indices)
            empty!(cache.edge_beam_elements)
        end
        # Build model with qu for mesh generation (load magnitude doesn't affect mesh)
        fea = _build_fea_slab_model(
            struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
            Ecc=Ecc, target_edge=target_edge, verbose=verbose, drop_panel=drop_panel,
            col_I_factor=col_I_factor, patch_stiffness_factor=patch_stiffness_factor,
            edge_beam_βt=edge_beam_βt,
            edge_beam_l2=edge_beam_l2,
            edge_beam_c1_avg=edge_beam_c1_avg,
            q_drop=q_drop_u,
            fixed_mesh=fixed_mesh, fixed_mesh_cap=fixed_mesh_cap,
        )
        cache.model      = fea.model
        cache.col_stubs  = fea.col_stubs
        cache.shells     = fea.shells
        cache.edge_beam_elements = fea.edge_beam_elements
        cache.patch_zone = fea.patch_zone
        cache.edge_beam_βt = edge_beam_βt
        cache.initialized = true
        cache.drop_panel  = drop_panel
        cache.mesh_key    = mesh_key

        # Precompute geometry (centroids, areas, LCS, cell mapping) from initial solve
        _precompute_element_data!(cache, cache.model, struc, slab)

        if split_dl
            # Snapshot the factored-state displacement before D/L solves so we can
            # restore it without a redundant third solve.
            U_qu = copy(cache.model.u)
            _solve_dl_cases!(cache, qD, qL; verbose=verbose, U_qu=U_qu)
            _combine_element_moments!(cache; verbose=verbose)
        end
        # else: element_data already has moments from the qu solve
    else
        # Mesh topology depends on drop_panel (flat plate vs flat slab). If it changed,
        # we must rebuild; the update path cannot add/remove drop panel patches.
        if drop_panel != cache.drop_panel
            @debug "FEAModelCache" event=:rebuild reason="drop_panel_changed"
            cache.initialized = false
            empty!(cache.element_data)
            empty!(cache.cell_tri_indices)
            return _build_or_update_fea!(cache, struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
                Ecc=Ecc, target_edge=target_edge, verbose=verbose, drop_panel=drop_panel,
                col_I_factor=col_I_factor, patch_stiffness_factor=patch_stiffness_factor,
                qD=qD, qL=qL,
                edge_beam_βt=edge_beam_βt,
                edge_beam_l2=edge_beam_l2,
                edge_beam_c1_avg=edge_beam_c1_avg,
                q_drop=q_drop,
                fixed_mesh=fixed_mesh, fixed_mesh_cap=fixed_mesh_cap)
        end
        cache.n_updates += 1
        @debug "FEAModelCache" event=:update
        cache.drop_panel  = drop_panel  # may have changed between iterations (same topology)
        cache.edge_beam_βt = edge_beam_βt  # refresh the stored target for this iteration
        if split_dl
            # Update section/stubs (use qu for the initial update), then D/L split.
            # The update solve is already the factored envelope when `qu` is
            # bitwise the pressure `_solve_dl_cases!` would restore
            # (`max(1.2D+1.6L, 1.4D)`). Snapshot that displacement and skip
            # the third solve. A mismatch re-solves.
            _update_and_resolve!(cache, h, Ecs, ν_concrete, qu, columns, Lc;
                                 Ecc=Ecc, verbose=verbose, col_I_factor=col_I_factor,
                                 patch_stiffness_factor=patch_stiffness_factor,
                                 edge_beam_l2=edge_beam_l2,
                                 edge_beam_c1_avg=edge_beam_c1_avg,
                                 q_drop=q_drop_u,
                                 fixed_mesh=fixed_mesh, struc=struc)
            qu_restore = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
            U_qu = ustrip(u"Pa", qu) == ustrip(u"Pa", qu_restore) ?
                copy(cache.model.u) : nothing
            _precompute_element_data!(cache, cache.model, struc, slab)
            _solve_dl_cases!(cache, qD, qL; verbose=verbose, U_qu=U_qu)
            _combine_element_moments!(cache; verbose=verbose)
        else
            _update_and_resolve!(cache, h, Ecs, ν_concrete, qu, columns, Lc;
                                 Ecc=Ecc, verbose=verbose, col_I_factor=col_I_factor,
                                 patch_stiffness_factor=patch_stiffness_factor,
                                 edge_beam_l2=edge_beam_l2,
                                 edge_beam_c1_avg=edge_beam_c1_avg,
                                 q_drop=q_drop_u,
                                 fixed_mesh=fixed_mesh, struc=struc)
            _precompute_element_data!(cache, cache.model, struc, slab)
        end
    end

    return cache
end
