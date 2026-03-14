# =============================================================================
# FEA Model Builder — Mesh construction, update, and solve
# =============================================================================
#
# 2D shell model with column stub frame elements for flat plate moment analysis.
#
# Architecture:
#   1. Triangulated shell elements (Asap.Shell auto-mesher)
#   2. ShellPatch at each column — mesh conforms to column perimeters.
#      Patch section uses the slab's own (h, Ecs, ν) by default; an optional
#      stiffness_factor multiplies E for rigid-zone modelling if needed.
#   3. Column frame elements — up to two per column location:
#      - Below column: fixed base at z = −Lc_below → slab (z = 0)
#      - Above column: slab (z = 0) → fixed top at z = +Lc_above (if column above exists)
#      At the roof level only the below column is created.  Each uses
#      its actual length and section properties (I_factor × Ig per ACI 318-11 §10.10.4.1).
#   4. Factored area load on the shell elements
#
# Reference: ACI 318-11 §13.2.1
# =============================================================================

"""
    _build_fea_slab_model(struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
                          Ecc=Ecs, target_edge=nothing, verbose=false)

Build a standalone Asap mixed model (shell + frame) with column elements
and ShellPatch mesh conformity at each column.

Each column location gets up to two frame elements using the column's actual
length (`col.base.L`).  `Lc` is retained in the signature for API
compatibility but is not used internally.

`Ecc` is the column concrete modulus (defaults to `Ecs` for same-strength
buildings).  Column stubs use `Ecc`, not `Ecs`, since column concrete
strength may differ from the slab.

`target_edge = nothing` (default) → adaptive mesh scaled to the smallest cell's
short span (from `SpanInfo.primary`): `clamp(min_span/20, 0.15, 0.75) m`, giving
~20 elements per span direction.  An explicit length overrides this.

Returns `(model, col_stubs, shells)`.
"""
function _build_fea_slab_model(
    struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
    Ecc::Pressure = Ecs,   # column concrete modulus (may differ from slab)
    target_edge::Union{Nothing, Length} = nothing,
    verbose::Bool = false,
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    col_I_factor::Float64 = 0.70,
    patch_stiffness_factor::Float64 = 1.0,
)
    skel = struc.skeleton

    # ─── 1. Slab boundary + interior cell edges ───
    boundary_vis, all_vis, interior_edge_vis = _get_slab_face_boundary(struc, slab)

    # ─── 1b. Adaptive mesh resolution ───
    if target_edge === nothing
        min_span_m = minimum(ustrip(u"m", struc.cells[ci].spans.primary)
                             for ci in slab.cell_indices)
        target_edge = clamp(min_span_m / 20.0, 0.15, 0.75) * u"m"
    end

    # ─── 2. Slab-level nodes (z = 0) ───
    node_map = Dict{Int, Asap.Node}()
    for vi in all_vis
        xy = _vertex_xy_m(skel, vi)
        node_map[vi] = Asap.Node([xy[1] * u"m", xy[2] * u"m", 0.0u"m"], :free)
    end

    # ─── 3. Column elements + ShellPatches ───
    col_stubs = Dict{Int, Any}()
    frame_elements = Asap.FrameElement[]
    fixed_nodes = Asap.Node[]
    patches = Asap.ShellPatch[]

    patch_section = Asap.ShellSection(
        uconvert(u"m", h),
        uconvert(u"Pa", Ecs * patch_stiffness_factor),
        ν_concrete;
        name=:col_patch
    )

    for (i, col) in enumerate(columns)
        vi = col.vertex_idx
        if !haskey(node_map, vi)
            xy = _vertex_xy_m(skel, vi)
            @warn "Column $vi at ($(xy[1]), $(xy[2])) not in slab face vertices"
            continue
        end

        slab_node = node_map[vi]
        xy = _column_xy_m(skel, col)

        # ── Below column (always present) ──
        Lc_below = col.base.L
        base_below = Asap.Node([xy[1] * u"m", xy[2] * u"m", -Lc_below], :fixed)
        push!(fixed_nodes, base_below)

        sec_below = _col_asap_sec(col, Ecc, ν_concrete; I_factor=col_I_factor)
        elem_below = Asap.Element(base_below, slab_node, sec_below, :col_below)
        push!(frame_elements, elem_below)

        # ── Above column (only if a column exists above this one) ──
        col_above = col.column_above
        elem_above = nothing
        base_above = nothing
        if !isnothing(col_above)
            Lc_above = col_above.base.L
            base_above = Asap.Node([xy[1] * u"m", xy[2] * u"m", Lc_above], :fixed)
            push!(fixed_nodes, base_above)

            sec_above = _col_asap_sec(col_above, Ecc, ν_concrete; I_factor=col_I_factor)
            elem_above = Asap.Element(slab_node, base_above, sec_above, :col_above)
            push!(frame_elements, elem_above)
        end

        col_stubs[i] = (
            below  = (element=elem_below,  base_node=base_below,  slab_node=slab_node),
            above  = isnothing(elem_above) ? nothing :
                     (element=elem_above, base_node=base_above, slab_node=slab_node),
        )

        # ShellPatch for mesh conformity + stiffened region.
        cshape = col_shape(col)
        if cshape == :circular
            D_m = ustrip(u"m", col.c1)
            eq_side = D_m * sqrt(π / 4)
            patch = Asap.ShellPatch(xy[1], xy[2], eq_side, eq_side,
                                    patch_section; id=:col_patch)
        else
            c1_m = ustrip(u"m", col.c1)
            c2_m = ustrip(u"m", col.c2)
            θ = col_orientation(col)
            if abs(θ) < 1e-12
                # Axis-aligned fast path
                patch = Asap.ShellPatch(xy[1], xy[2], c1_m, c2_m,
                                        patch_section; id=:col_patch)
            else
                # Rotated rectangle: build vertices manually
                cosθ = cos(θ); sinθ = sin(θ)
                hx = c1_m / 2; hy = c2_m / 2
                corners_local = ((-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy))
                verts = Tuple{Float64, Float64}[
                    (xy[1] + cosθ*lx - sinθ*ly, xy[2] + sinθ*lx + cosθ*ly)
                    for (lx, ly) in corners_local
                ]
                patch = Asap.ShellPatch(verts, (xy[1], xy[2]),
                                        patch_section, :col_patch)
            end
        end
        push!(patches, patch)

        if verbose
            shape_str = cshape == :circular ? "circular" : "rectangular"
            c1_mm = round(ustrip(u"m", col.c1)*1000, digits=0)
            c2_mm = round(ustrip(u"m", col.c2)*1000, digits=0)
            above_str = isnothing(col_above) ? "roof (no above)" : "above+below"
            @debug "  Col $i ($shape_str, $above_str): Lc=$(round(ustrip(u"m", Lc_below), digits=3))m, " *
                   "c1=$(c1_mm)mm, c2=$(c2_mm)mm"
        end
    end

    # ─── 3b. Drop panel ShellPatches (thickened zones around columns) ───
    if !isnothing(drop_panel)
        h_total = total_depth_at_drop(h, drop_panel)
        drop_section = Asap.ShellSection(
            uconvert(u"m", h_total),
            uconvert(u"Pa", Ecs),
            ν_concrete;
            name=:drop_panel_patch
        )
        
        a1_m = ustrip(u"m", drop_panel.a_drop_1)
        a2_m = ustrip(u"m", drop_panel.a_drop_2)
        w_drop = 2 * a1_m
        h_drop_m = 2 * a2_m
        
        for (i, col) in enumerate(columns)
            vi = col.vertex_idx
            haskey(node_map, vi) || continue
            xy = _column_xy_m(skel, col)
            
            push!(patches, Asap.ShellPatch(
                xy[1], xy[2], w_drop, h_drop_m,
                drop_section; id=:drop_panel))
            
            if verbose
                @debug "  Drop panel patch at col $i: $(round(w_drop, digits=3))×$(round(h_drop_m, digits=3)) m"
            end
        end
    end

    # ─── 4. Shell mesh with patches ───
    shell_section = Asap.ShellSection(uconvert(u"m", h), uconvert(u"Pa", Ecs), ν_concrete)

    boundary_set = Set(boundary_vis)
    corner_nodes = tuple([node_map[vi] for vi in boundary_vis]...)

    interior_nodes = Asap.Node[]
    for vi in all_vis
        vi in boundary_set && continue
        push!(interior_nodes, node_map[vi])
    end

    # Conforming nodes along interior cell edges
    target_m = ustrip(u"m", target_edge)
    for (vi_a, vi_b) in interior_edge_vis
        haskey(node_map, vi_a) && haskey(node_map, vi_b) || continue
        xa, ya = _vertex_xy_m(skel, vi_a)
        xb, yb = _vertex_xy_m(skel, vi_b)
        edge_len = hypot(xb - xa, yb - ya)
        n_seg = max(1, round(Int, edge_len / target_m))
        for k in 1:(n_seg - 1)
            t = k / n_seg
            x = xa + t * (xb - xa)
            y = ya + t * (yb - ya)
            push!(interior_nodes, Asap.Node([x * u"m", y * u"m", 0.0u"m"], :free))
        end
    end

    # Pin in-plane DOFs (u,v) at boundary.
    edge_dofs = [false, false, true, true, true, true]

    min_col_dim_m = if !isempty(columns)
        minimum(min(ustrip(u"m", col.c1), ustrip(u"m", col.c2)) for col in columns)
    else
        ustrip(u"m", target_edge)
    end
    refine_edge = clamp(min_col_dim_m / 2.0, 0.04, ustrip(u"m", target_edge) / 2.0) * u"m"

    shells = Asap.Shell(corner_nodes, shell_section;
                        id=:slab_fea,
                        interior_nodes=interior_nodes,
                        interior_patches=patches,
                        edge_support_type=edge_dofs,
                        interior_support_type=:free,
                        target_edge_length=target_edge,
                        refinement_edge_length=refine_edge)

    # ─── 5. Load ───
    loads = Asap.AbstractLoad[Asap.AreaLoad(shells, uconvert(u"Pa", qu))]

    # ─── 6. Build, process, solve ───
    all_nodes = vcat(collect(values(node_map)), fixed_nodes)
    model = Asap.Model(all_nodes, frame_elements, shells, loads)
    Asap.process!(model)
    Asap.solve!(model)

    if verbose
        @debug "FEA MODEL BUILT (column stubs + ShellPatch)" begin
            "nodes=$(length(model.nodes)) shells=$(length(model.shell_elements)) " *
            "stubs=$(length(frame_elements)) " *
            "dof=$(length(model.u)) target_edge=$(target_edge)"
        end
    end

    return (model=model, col_stubs=col_stubs, shells=shells)
end

# =============================================================================
# Mesh Reuse: Update Section + Load on Existing Model
# =============================================================================

"""
    _update_and_resolve!(cache, h, Ecs, ν_concrete, qu, columns, Lc; Ecc, ...)

Update an existing FEA model's shell properties, column stub sections,
and load, then re-process and re-solve without re-triangulating.
"""
function _update_and_resolve!(
    cache::FEAModelCache, h, Ecs, ν_concrete, qu, columns, Lc;
    Ecc::Pressure = Ecs,
    verbose::Bool = false,
    col_I_factor::Float64 = 0.70,
    patch_stiffness_factor::Float64 = 1.0,
)
    model = cache.model
    t_m = ustrip(u"m", h)
    E_Pa = ustrip(u"Pa", Ecs)
    E_patch_Pa = E_Pa * patch_stiffness_factor

    # Drop panel total depth (if present)
    drop = cache.drop_panel
    t_drop_m = if !isnothing(drop)
        ustrip(u"m", total_depth_at_drop(h, drop))
    else
        t_m
    end

    # 1. Update shell element section properties — respect patch IDs
    for elem in model.shell_elements
        elem.ν = ν_concrete
        if elem.id === :drop_panel
            # Drop panel patch: thickened section, slab E
            elem.thickness = t_drop_m
            elem.E = E_Pa
        elseif elem.id === :col_patch
            # Column patch: slab thickness, optionally stiffened E
            elem.thickness = t_m
            elem.E = E_patch_Pa
        else
            # Regular slab element
            elem.thickness = t_m
            elem.E = E_Pa
        end
    end

    # 2. Update load magnitude
    for load in model.loads
        if load isa Asap.AreaLoad
            load.pressure = uconvert(u"Pa", qu)
        end
    end

    # 3. Update column sections
    for (i, col) in enumerate(columns)
        haskey(cache.col_stubs, i) || continue
        stubs = cache.col_stubs[i]
        stubs.below.element.section = _col_asap_sec(col, Ecc, ν_concrete; I_factor=col_I_factor)
        if !isnothing(stubs.above) && !isnothing(col.column_above)
            stubs.above.element.section = _col_asap_sec(col.column_above, Ecc, ν_concrete; I_factor=col_I_factor)
        end
    end

    # 4. Values-only update: geometry/topology unchanged
    Asap.update!(model; values_only=true)
    Asap.solve!(model)

    if verbose
        @debug "FEA MODEL UPDATED (reused mesh)" begin
            "shells=$(length(model.shell_elements)) h=$(round(t_m*1000, digits=0))mm " *
            "E=$(round(E_Pa/1e6, digits=0))MPa"
        end
    end
end
