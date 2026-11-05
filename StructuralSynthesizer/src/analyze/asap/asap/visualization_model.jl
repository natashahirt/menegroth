
"""
    _get_slab_boundary_vertices(struc, slab)
        -> (boundary_vis::Vector{Int}, interior_edge_vis::Vector{Tuple{Int,Int}})

Exterior boundary vertex indices and interior cell-edge vertex pairs.

The exterior is the largest closed loop of edges that belong to one slab
cell. A missing bay is a hole ([`StructuralSizer.slab_void_loops`](@ref)),
not part of this polygon. Concave plans stay concave: this is not a convex hull.
"""
function _get_slab_boundary_vertices(struc::BuildingStructure, slab::Slab)
    boundary, _, interior = StructuralSizer._get_slab_face_boundary(struc, slab)
    return (boundary, interior)
end

"""
    _get_interior_column_nodes(struc, slab, boundary_vert_indices, nodes) -> Vector{Asap.Node}

Find interior vertices (not on slab boundary) and return their Node objects.
Includes all interior cell vertices — column locations and cell-edge intersections
alike — so the Delaunay triangulation conforms along internal cell boundaries.
"""
function _get_interior_column_nodes(struc::BuildingStructure, slab::Slab,
                                     boundary_vert_indices::Vector{Int},
                                     nodes::Vector{Asap.Node})
    skel = struc.skeleton
    boundary_set = Set(boundary_vert_indices)

    all_cell_verts = Set{Int}()
    for cell_idx in slab.cell_indices
        cell = struc.cells[cell_idx]
        for vi in skel.face_vertex_indices[cell.face_idx]
            push!(all_cell_verts, vi)
        end
    end

    interior_vert_indices = setdiff(all_cell_verts, boundary_set)

    return Asap.Node[nodes[vi] for vi in interior_vert_indices]
end

"""
    _slab_outline_nodes!(skel, nodes, vert_indices, offsets, face_nodes, spawned)
        -> (corners, centers)

Shell corners on the architectural vertices.

`nodes` already carry the structural offset, so an edge or corner column sits
inboard of the face it supports. The plate stays on the input vertex. The
offset column node is returned in `centers` for the shell to embed. A vertex
with no offset keeps `nodes[vi]` as its corner. `face_nodes` reuses one
architectural node when several slabs share the vertex.
"""
function _slab_outline_nodes!(skel, nodes::Vector{Asap.Node}, vert_indices,
                              offsets, face_nodes::Dict{Int, Asap.Node},
                              spawned::Vector{Asap.Node})
    vc = skel.geometry.vertex_coords
    corners = Asap.Node[]
    centers = Asap.Node[]
    sizehint!(corners, length(vert_indices))
    for vi in vert_indices
        off = get(offsets, vi, (0.0, 0.0))
        if hypot(off[1], off[2]) <= 1e-8
            push!(corners, nodes[vi])
            continue
        end
        nd = get!(face_nodes, vi) do
            node = Asap.Node(
                [vc[vi, 1] * u"m", vc[vi, 2] * u"m", vc[vi, 3] * u"m"],
                [true, true, true, false, false, false],
            )
            push!(spawned, node)
            node
        end
        push!(corners, nd)
        # The column frame keeps this node. The shell embeds it inboard of the face.
        push!(centers, nodes[vi])
    end
    return corners, centers
end

"Append column centers that are not already in `interior`."
function _embed_column_centers!(interior::Vector{Asap.Node}, centers::Vector{Asap.Node})
    seen = Set{UInt64}(objectid(n) for n in interior)
    for nd in centers
        id = objectid(nd)
        id in seen && continue
        push!(seen, id)
        push!(interior, nd)
    end
    return interior
end

# =============================================================================
# Analysis Model Builder (Frame + Shell for Global Deflection)
# =============================================================================

"""
    build_analysis_model!(design; load_combination=service, mesh_density=2, frame_groups=:auto)

Build a frame+shell Asap model for global deflection analysis.

This creates a **separate** model stored in `design.asap_model` that includes:
- Frame elements (columns, and optionally beams)
- Shell elements representing designed slabs
- Area loads (SDL + LL) applied directly to shells

The original `struc.asap_model` (frame-only) is preserved for design calculations.

# Arguments
- `design::BuildingDesign`: Design with completed slab sizing
- `load_combination::LoadCombination`: Load factors (default: service = 1.0D + 1.0L)
- `mesh_density::Int`: Shell mesh refinement per face (default: 2 = 2×2 triangulation)
- `frame_groups`: Which skeleton edge groups to include as frame elements
  - `:auto` (default): Infer from floor type
    - `:flat_plate` → `[:columns]` (beamless)
    - `:one_way`, `:two_way` → `[:columns, :beams]`
  - `Vector{Symbol}`: Explicit list, e.g. `[:columns]` or `[:columns, :beams]`
- `patch_stiffness_factor::Union{Real, Nothing}`: Column/drop-panel patch
  modulus multiplier. `nothing` (default) follows the floor `FEA` method
  (100). A number overrides that; `1` is an ordinary-slab patch. Ignored
  when the slab has no drop-panel patches.

# Example
```julia
# After design_building() completes
design = design_building(struc, params)

# Build global analysis model (auto-detects flat plate → columns only)
build_analysis_model!(design)

# Or explicitly include beams for slab-on-beam systems
build_analysis_model!(design; frame_groups=[:columns, :beams])

# Visualize deflected shape including slabs
visualize(design, mode=:deflected)
```

# Notes
- Shells use actual slab thickness and concrete E from design results
- Self-weight is included via shell density (ρ = concrete density)
- SDL + LL applied as AreaLoad to shell surfaces
- Frame TributaryLoads are NOT included (loads go through shells)
- A `:walls` edge that this filter still copies (the edge is also in an
  included group, or `frame_groups` lists `:walls`) gets the same zero frame
  section as `to_asap!`. Which groups are included does not change.
"""
function build_analysis_model!(design::BuildingDesign;
                               load_combination::LoadCombination=service,
                               mesh_density::Int=2,
                               frame_groups::Union{Symbol, Vector{Symbol}}=:auto,
                               target_edge_length=nothing,
                               refinement_edge_length=nothing,
                               refinement_radius=nothing,
                               refinement_targets=nothing,
                               patch_stiffness_factor::Union{Real, Nothing}=nothing)
    struc = design.structure
    skel = struc.skeleton
    
    isempty(struc.slabs) && error("No slabs found. Run size_slabs!() first.")
    isnothing(struc.asap_model) && error("No frame model found. Run to_asap!() first.")
    
    # ─── 1. Resolve frame_groups ───
    resolved_groups = if frame_groups == :auto
        # Infer from floor type
        floor_type = isempty(struc.slabs) ? :unknown : struc.slabs[1].floor_type
        if floor_type == :flat_plate
            [:columns]  # Beamless slab
        else
            [:columns, :beams]  # Slab-on-beam systems
        end
    else
        frame_groups isa Vector ? frame_groups : [frame_groups]
    end
    
    # Build set of edge indices to include
    included_edges = Set{Int}()
    for group in resolved_groups
        union!(included_edges, get(skel.groups_edges, group, Int[]))
    end
    
    # ─── 2. Resolve shell meshing controls from floor FEA method / defaults ───
    mesh_controls = _resolve_visualization_shell_mesh_controls(
        design;
        target_edge_length=target_edge_length,
        refinement_edge_length=refinement_edge_length,
        refinement_radius=refinement_radius,
        refinement_targets=refinement_targets,
        patch_stiffness_factor=patch_stiffness_factor,
    )

    # ─── 3. Create nodes with structural offsets ───
    # Reuse offsets already captured in design (populated by capture_design before restore!)
    support_set = Set(get(skel.groups_vertices, :support, Int[]))
    nodes = _create_offset_nodes(skel, design.structural_offsets, support_set)
    
    # ─── 4. Copy frame elements from selected groups ───
    # Use existing elements from struc.asap_model (preserves sized sections).
    # A :walls edge that the group filter still includes is copied with a zero
    # section, matching to_asap!, even if sizing later replaced that source
    # section. The filter itself is unchanged.
    src_model = struc.asap_model
    frame_elements = Asap.FrameElement[]
    frame_edge_indices = Int[]
    wall_ids = get(skel.groups_edges, :walls, Int[])
    wall_edges = isempty(wall_ids) ? nothing : Set(wall_ids)

    # Resolve releases from the beam release fields (same source as to_asap!), not
    # by reading them back off the source Asap element, so the rebuild honors any
    # per-segment / (role, material) release the design layer assigned.
    edge_release = _build_edge_release_map(struc, design.params)
    # Phase 7 seat-offset dispatch — sections are known here (copied from the
    # sized source model), so joist-on-girder seat eccentricities are populated
    # (see StructuralSizer/src/materials/steel.jl :joist ENGINEERING JUDGMENT marker).
    edge_eccentricity = _build_edge_eccentricity_map(struc, design.params)

    for (edge_idx, (v1, v2)) in enumerate(skel.edge_indices)
        # Only include edges from selected groups
        edge_idx in included_edges || continue
        
        # Get section from source model if available.
        # Zero a copied :walls edge so its frame stiffness and mass stay out
        # of this model. Non-wall edges keep the sized source section.
        # Unified `Model` stores frames on `frame_elements`. `FrameModel` still
        # uses `elements`. Skeleton edge `i` is frame element `i` in both.
        src_frames = hasproperty(src_model, :frame_elements) ? src_model.frame_elements : src_model.elements
        src_el = src_frames[edge_idx]
        section = if !isnothing(wall_edges) && edge_idx in wall_edges
            _zero_wall_frame_section(src_el.section.E, src_el.section.G)
        else
            src_el.section
        end
        
        # Per-beam release (non-beam edges default to :fixedfixed)
        release_sym = get(edge_release, edge_idx, :fixedfixed)
        ecc = get(edge_eccentricity, edge_idx, (0.0, 0.0, 0.0, 0.0))
        
        el = Asap.Element(nodes[v1], nodes[v2], section; release=release_sym, eccentricity=ecc)
        el.Ψ = src_el.Ψ
        push!(frame_elements, el)
        push!(frame_edge_indices, edge_idx)
    end
    
    # ─── 5a. Wall shells ───
    # Same mesh and stiffness as to_asap!. Meshed before the slabs so a flat
    # slab can embed the wall nodes at its elevation (see `_slab_wall_nodes`).
    # Walls are vertical; the slab AreaLoad below does not touch them.
    wall_shells, wall_nodes, _, _ = _mesh_wall_shells(struc, design.params, nodes, Asap.ShellElement[])
    _apply_stated_cracked_wall_stiffness!(wall_shells, design.params)

    # ─── 5b. Create shell elements for slabs ───
    # Mesh entire slab boundary as one continuous shell, not per-cell.
    # For vault slabs, use VaultShell to create curved parabolic mesh.
    shell_elements = Asap.ShellElement[]
    slab_shell_map = Dict{Int, Vector{Asap.ShellElement}}()
    
    for (slab_idx, slab) in enumerate(struc.slabs)
        # Get slab properties
        t = thickness(slab)
        
        # Get concrete properties from slab result (fall back to NWC_4000)
        E = uconvert(u"Pa", NWC_4000.E)
        ρ = NWC_4000.ρ
        ν_slab = NWC_4000.ν
        
        if hasfield(typeof(slab.result), :concrete) && !isnothing(slab.result.concrete)
            concrete = slab.result.concrete
            hasfield(typeof(concrete), :E) && (E = concrete.E)
            hasfield(typeof(concrete), :ρ) && (ρ = concrete.ρ)
            hasfield(typeof(concrete), :ν) && (ν_slab = concrete.ν)
        end
        
        E_pa = uconvert(u"Pa", E)
        ρ_kgm3 = uconvert(u"kg/m^3", ρ)
        
        # Create shell section with proper density (enables self-weight)
        section = Asap.ShellSection(t, E_pa, ν_slab; ρ=ρ_kgm3)
        
        # Outer boundary + interior cell edges (handles concave multi-cell slabs)
        boundary_vert_indices, interior_edge_vis = _get_slab_boundary_vertices(struc, slab)
        
        is_vault = slab.result isa StructuralSizer.VaultResult
        
        if is_vault && length(boundary_vert_indices) == 4
            # Vault slabs: curved parabolic mesh via VaultShell
            vault_result = slab.result::StructuralSizer.VaultResult
            rise = vault_result.rise
            span_axis = slab.spans.axis
            
            corners = tuple([nodes[vi] for vi in boundary_vert_indices]...)
            
            column_refinement_nodes = _get_slab_column_nodes(struc, slab, nodes)
            effective_target_edge_length = _resolve_slab_target_edge_length(
                struc, slab, mesh_controls.target_edge_length)
            effective_refinement_edge_length = _resolve_slab_refinement_edge_length(
                struc, slab, effective_target_edge_length, mesh_controls.refinement_edge_length)
            effective_refinement_targets = isnothing(refinement_targets) ?
                column_refinement_nodes : mesh_controls.refinement_targets
            
            @debug "Vault slab $slab_idx" rise=rise span_axis=span_axis n_refinement=length(column_refinement_nodes)
            
            warn_span_m = _slab_min_primary_span_m(struc, slab)
            slab_shells = Asap.VaultShell(corners, section, span_axis, rise;
                                          n=mesh_density,
                                          id=Symbol("slab_$(slab_idx)"),
                                          interior_nodes=column_refinement_nodes,
                                          edge_support_type=:free,
                                          target_edge_length=effective_target_edge_length,
                                          refinement_edge_length=effective_refinement_edge_length,
                                          refinement_radius=mesh_controls.refinement_radius,
                                          refinement_targets=effective_refinement_targets,
                                          mesh_density_warn_shortest_side_m=warn_span_m)
        elseif length(boundary_vert_indices) >= 3
            # Flat slabs/plates: Delaunay mesh of entire slab outer boundary.
            # Keep patch-based stiffness for flat slabs, but constrain patch creation
            # to slab-owned vertices so patches cannot form disconnected islands.
            n_cells = length(slab.cell_indices)
            scale_factor = ceil(Int, sqrt(n_cells))
            effective_n = mesh_density * scale_factor
            
            interior_nodes = _get_interior_column_nodes(struc, slab, boundary_vert_indices, nodes)
            slab_holes = vcat(StructuralSizer.slab_opening_loops(struc, slab),
                              StructuralSizer.slab_void_loops(struc, slab))
            append!(interior_nodes, _slab_wall_nodes(wall_nodes, interior_nodes,
                                                     [nodes[vi] for vi in boundary_vert_indices];
                                                     holes=slab_holes))
            column_refinement_nodes = _get_slab_column_nodes(struc, slab, nodes)
            slab_columns = _get_slab_columns(struc, slab)
            use_shell_patches = slab.floor_type == :flat_slab && !isnothing(slab.drop_panel)
            slab_vertex_set = Set{Int}()
            for ci in slab.cell_indices
                for vi in skel.face_vertex_indices[struc.cells[ci].face_idx]
                    push!(slab_vertex_set, vi)
                end
            end
            interior_patches = use_shell_patches ?
                StructuralSizer.build_slab_shell_patches(
                    struc, slab_columns, section;
                    drop_panel=slab.drop_panel,
                    patch_stiffness_factor=mesh_controls.patch_stiffness_factor,
                    vertex_set=slab_vertex_set,
                    span_axis=StructuralSizer._get_span_axis(slab)) :
                Asap.ShellPatch[]
            effective_target_edge_length = _resolve_slab_target_edge_length(
                struc, slab, mesh_controls.target_edge_length)
            effective_refinement_edge_length = _resolve_slab_refinement_edge_length(
                struc, slab, effective_target_edge_length, mesh_controls.refinement_edge_length)
            # Refinement targets: column centers + patch interior/edge points so refinement
            # reaches target level throughout patches for smooth deflection visualization.
            base_refinement = isnothing(refinement_targets) ?
                column_refinement_nodes : mesh_controls.refinement_targets
            slab_z = Float64(ustrip(u"m", nodes[boundary_vert_indices[1]].position[3]))
            patch_refinement = effective_refinement_edge_length !== nothing && !isempty(interior_patches) ?
                _patch_refinement_nodes(interior_patches, ustrip(u"m", effective_refinement_edge_length), slab_z) :
                Asap.Node[]
            effective_refinement_targets = vcat(base_refinement, patch_refinement)
            
            @debug "Slab $slab_idx mesh" n_cells=n_cells scale_factor=scale_factor effective_n=effective_n n_corners=length(boundary_vert_indices) n_interior_nodes=length(interior_nodes) n_refinement_nodes=length(effective_refinement_targets) n_patches=length(interior_patches) target_edge=effective_target_edge_length refine_edge=effective_refinement_edge_length refine_radius=mesh_controls.refinement_radius
            if !isempty(effective_refinement_targets)
                ref_positions = [(ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2])) for n in effective_refinement_targets]
                @debug "  Refinement targets" n=length(ref_positions) positions=ref_positions[1:min(10, length(ref_positions))]
            end
            
            corners = tuple([nodes[vi] for vi in boundary_vert_indices]...)
            warn_span_m = _slab_min_primary_span_m(struc, slab)

            slab_shells = Asap.Shell(corners, section; n=effective_n,
                                     holes=slab_holes,
                                     id=Symbol("slab_$(slab_idx)"),
                                     interior_nodes=interior_nodes,
                                     interior_patches=interior_patches,
                                     edge_support_type=:free,
                                     target_edge_length=effective_target_edge_length,
                                     refinement_edge_length=effective_refinement_edge_length,
                                     refinement_radius=mesh_controls.refinement_radius,
                                     refinement_targets=effective_refinement_targets,
                                     mesh_density_warn_shortest_side_m=warn_span_m)
        else
            # Degenerate fallback: per-cell meshing
            slab_shells = Asap.ShellElement[]
            face_indices = [struc.cells[ci].face_idx for ci in slab.cell_indices]
            column_refinement_nodes = _get_slab_column_nodes(struc, slab, nodes)
            slab_columns = _get_slab_columns(struc, slab)
            use_shell_patches = slab.floor_type == :flat_slab && !isnothing(slab.drop_panel)
            slab_vertex_set = Set{Int}()
            for ci in slab.cell_indices
                for vi in skel.face_vertex_indices[struc.cells[ci].face_idx]
                    push!(slab_vertex_set, vi)
                end
            end
            interior_patches = use_shell_patches ?
                StructuralSizer.build_slab_shell_patches(
                    struc, slab_columns, section;
                    drop_panel=slab.drop_panel,
                    patch_stiffness_factor=mesh_controls.patch_stiffness_factor,
                    vertex_set=slab_vertex_set,
                    span_axis=StructuralSizer._get_span_axis(slab)) :
                Asap.ShellPatch[]
            effective_target_edge_length = _resolve_slab_target_edge_length(
                struc, slab, mesh_controls.target_edge_length)
            effective_refinement_edge_length = _resolve_slab_refinement_edge_length(
                struc, slab, effective_target_edge_length, mesh_controls.refinement_edge_length)
            base_refinement = isnothing(refinement_targets) ?
                column_refinement_nodes : mesh_controls.refinement_targets
            first_vi = skel.face_vertex_indices[struc.cells[first(slab.cell_indices)].face_idx][1]
            slab_z = Float64(ustrip(u"m", nodes[first_vi].position[3]))
            patch_refinement = effective_refinement_edge_length !== nothing && !isempty(interior_patches) ?
                _patch_refinement_nodes(interior_patches, ustrip(u"m", effective_refinement_edge_length), slab_z) :
                Asap.Node[]
            effective_refinement_targets = vcat(base_refinement, patch_refinement)
            
            for face_idx in face_indices
                vert_indices = skel.face_vertex_indices[face_idx]
                corners = tuple([nodes[vi] for vi in vert_indices]...)
                
                face_shells = Asap.Shell(corners, section; n=mesh_density,
                                         holes=StructuralSizer.slab_opening_loops(struc, slab; face_idx=face_idx),
                                         id=Symbol("slab_$(slab_idx)"),
                                         edge_support_type=:free,
                                         interior_support_type=:free,
                                         interior_patches=interior_patches,
                                         target_edge_length=effective_target_edge_length,
                                         refinement_edge_length=effective_refinement_edge_length,
                                         refinement_radius=mesh_controls.refinement_radius,
                                         refinement_targets=effective_refinement_targets)
                append!(slab_shells, face_shells)
            end
        end
        
        slab_shell_map[slab_idx] = slab_shells
        append!(shell_elements, slab_shells)
    end
    
    append!(shell_elements, wall_shells)

    # ─── 6. Create loads ───
    loads = Asap.AbstractLoad[]
    
    # Self-weight of shells (slab and wall concrete weight, from each shell's ρ)
    if !isempty(shell_elements)
        push!(loads, Asap.SelfWeight(shell_elements))
    end
    
    # SDL + LL on each slab as AreaLoad
    for (slab_idx, slab) in enumerate(struc.slabs)
        slab_shells = slab_shell_map[slab_idx]
        isempty(slab_shells) && continue
        
        # Get loads from first cell (assumes uniform across slab)
        cell = struc.cells[first(slab.cell_indices)]
        sdl = cell.sdl
        ll = cell.live_load
        
        # Factored superimposed load (SDL + LL, NOT including self-weight which is on shells)
        factored = factored_pressure(load_combination, sdl, ll)
        pressure_pa = uconvert(u"Pa", factored)
        
        # Apply as area load (downward)
        area_load = Asap.AreaLoad(slab_shells, pressure_pa; direction=(0.0, 0.0, -1.0))
        push!(loads, area_load)
    end
    
    # ─── 7. Build and solve model ───
    _free_restrained_node_rotations!(nodes, frame_elements, shell_elements)
    model = Asap.Model(nodes, frame_elements, shell_elements, loads)
    
    Asap.process!(model)
    Asap.solve!(model)
    
    design.asap_model = model
    design.asap_model_frame_edge_indices = frame_edge_indices
    
    @info "Built analysis model" frame_groups=resolved_groups n_frames=length(frame_elements) n_shells=length(shell_elements) n_loads=length(loads)
    
    return model
end

"""
Resolve shell mesh controls from the floor analysis method, then apply explicit overrides.
Keeps visualization analysis meshing aligned with flat-plate FEA options.
"""
function _resolve_visualization_shell_mesh_controls(design::BuildingDesign;
    target_edge_length=nothing,
    refinement_edge_length=nothing,
    refinement_radius=nothing,
    refinement_targets=nothing,
    patch_stiffness_factor::Union{Real, Nothing}=nothing)

    floor_opts = resolve_floor_options(design.params)
    method = if floor_opts isa StructuralSizer.FlatSlabOptions
        floor_opts.base.method
    elseif floor_opts isa StructuralSizer.FlatPlateOptions
        floor_opts.method
    else
        nothing
    end

    fea_target_edge = (method isa StructuralSizer.FEA) ? method.target_edge : nothing
    # Drop-panel patches copy the floor FEA factor. An explicit argument wins.
    # A non-FEA floor has no factor; those patches stay ordinary slab (1×).
    method_factor = (method isa StructuralSizer.FEA) ? method.patch_stiffness_factor : 1.0
    resolved_factor = isnothing(patch_stiffness_factor) ? method_factor : Float64(patch_stiffness_factor)
    resolved_factor > 0 ||
        error("patch_stiffness_factor must be > 0; got $resolved_factor")

    resolved_target = isnothing(target_edge_length) ? fea_target_edge : target_edge_length

    return (
        target_edge_length = resolved_target,
        refinement_edge_length = refinement_edge_length,
        refinement_radius = refinement_radius,
        refinement_targets = refinement_targets,
        patch_stiffness_factor = resolved_factor,
    )
end

"""Minimum primary span (m) across cells in `slab` — characteristic cell size for mesh-density warnings."""
function _slab_min_primary_span_m(struc::BuildingStructure, slab::Slab)::Float64
    try
        minimum(ustrip(u"m", struc.cells[ci].spans.primary) for ci in slab.cell_indices)
    catch
        1.0
    end
end

"""
Resolve slab target edge length, matching flat-plate FEA adaptive default:
clamp(min_span/20, 0.15, 0.75) m when no explicit target is provided.
"""
function _resolve_slab_target_edge_length(struc::BuildingStructure, slab::Slab, target_edge_length)
    if target_edge_length !== nothing
        return target_edge_length
    end

    min_span_m = _slab_min_primary_span_m(struc, slab)
    return clamp(min_span_m / 20.0, 0.15, 0.75) * u"m"
end

"""
Resolve slab refinement edge length, matching flat-plate FEA default:
clamp(min_col_dim/2, 0.04, target_edge/2) m when no explicit refinement size is provided.
"""
function _resolve_slab_refinement_edge_length(
    struc::BuildingStructure, slab::Slab, target_edge_length, refinement_edge_length)
    refinement_edge_length !== nothing && return refinement_edge_length

    slab_cols = _get_slab_columns(struc, slab)
    isempty(slab_cols) && return nothing

    min_col_dim_m = minimum(min(ustrip(u"m", c.c1), ustrip(u"m", c.c2)) for c in slab_cols)
    target_m = try
        ustrip(u"m", target_edge_length)
    catch
        Float64(target_edge_length)
    end
    return clamp(min_col_dim_m / 2.0, 0.04, target_m / 2.0) * u"m"
end

"""
Return columns that support this slab (tributary area overlaps slab cells).
Uses `find_supporting_columns` so columns are correctly identified for slabs
both above and below each column segment (vertex_idx is always the top).
"""
function _get_slab_columns(struc::BuildingStructure, slab::Slab)
    return StructuralSizer.find_supporting_columns(struc, Set(slab.cell_indices))
end

"""
    _slab_wall_nodes(wall_nodes, interior_nodes, corners; holes=...) -> Vector{Asap.Node}

Wall-mesh nodes a flat slab should embed: at the slab elevation (1 mm), inside
the slab or on its edge, and not already a corner or interior node. Nodes
strictly inside a hole are the shaft, not the slab. Embedding the same `Node`
objects is what lets the slab bear on the wall, including along a core opening
where the wall is the slab boundary.
"""
function _slab_wall_nodes(wall_nodes::Vector{Asap.Node}, interior_nodes::Vector{Asap.Node},
                          corners::Vector{Asap.Node};
                          holes=Vector{Vector{NTuple{2,Float64}}}())
    isempty(wall_nodes) && return Asap.Node[]
    slab_z = ustrip(u"m", corners[1].position[3])
    polygon = [(ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2])) for n in corners]
    taken = Set{UInt64}(objectid(n) for n in Iterators.flatten((interior_nodes, corners)))
    out = Asap.Node[]
    for nd in wall_nodes
        objectid(nd) in taken && continue
        abs(ustrip(u"m", nd.position[3]) - slab_z) <= 1e-3 || continue
        pt = (ustrip(u"m", nd.position[1]), ustrip(u"m", nd.position[2]))
        on_slab = _point_inside_polygon(pt, polygon) || _point_on_polygon_boundary(pt, polygon)
        on_slab || continue
        any(h -> _point_inside_polygon(pt, h) && !_point_on_polygon_boundary(pt, h), holes) && continue
        push!(out, nd)
        push!(taken, objectid(nd))
    end
    return out
end

"""True when `pt` is within `tol` metres of an edge of `polygon`."""
function _point_on_polygon_boundary(pt::Tuple{Float64, Float64},
                                    polygon::Vector{Tuple{Float64, Float64}}; tol::Float64=1e-3)
    n = length(polygon)
    for i in 1:n
        a = polygon[i]
        b = polygon[mod1(i + 1, n)]
        ab = (b[1] - a[1], b[2] - a[2])
        len2 = ab[1]^2 + ab[2]^2
        len2 == 0 && continue
        s = clamp(((pt[1] - a[1]) * ab[1] + (pt[2] - a[2]) * ab[2]) / len2, 0.0, 1.0)
        hypot(pt[1] - (a[1] + s * ab[1]), pt[2] - (a[2] + s * ab[2])) <= tol && return true
    end
    return false
end

"""
    _point_inside_polygon(pt, polygon) -> Bool

Ray-casting test for point-in-polygon. Used for patch interior refinement.
"""
function _point_inside_polygon(pt::Tuple{Float64, Float64}, polygon::Vector{Tuple{Float64, Float64}})
    x, y = pt
    n = length(polygon)
    inside = false
    j = n
    for i in 1:n
        xi, yi = polygon[i]
        xj, yj = polygon[j]
        if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            inside = !inside
        end
        j = i
    end
    return inside
end

"""
    _patch_refinement_nodes(patches, refinement_edge_length_m, slab_z) -> Vector{Asap.Node}

Generate refinement target nodes inside and along patch boundaries so that mesh
refinement reaches the target level (refinement_edge_length) throughout the patch.
This yields smooth deflection visualization at column and drop panel regions.

Adds:
- Patch centroid (column center)
- Points along each patch edge at ~refinement_edge_length spacing
- Interior grid at refinement_edge_length spacing (for large patches)
"""
function _patch_refinement_nodes(
    patches::Vector{Asap.ShellPatch},
    refinement_edge_length_m::Float64,
    slab_z::Float64,
)
    isempty(patches) && return Asap.Node[]
    h = refinement_edge_length_m
    tol = 1e-9
    round_key(x) = round(Int64, x / tol)
    seen = Set{Tuple{Int64, Int64}}()
    nodes = Asap.Node[]

    for patch in patches
        verts = patch.vertices
        center = patch.center

        # Centroid
        kc = (round_key(center[1]), round_key(center[2]))
        if kc ∉ seen
            push!(seen, kc)
            push!(nodes, Asap.Node([center[1] * u"m", center[2] * u"m", slab_z * u"m"], :free))
        end

        # Points along each edge at spacing ~ h
        nv = length(verts)
        for i in 1:nv
            va = verts[i]
            vb = verts[mod1(i + 1, nv)]
            dx = vb[1] - va[1]
            dy = vb[2] - va[2]
            L = hypot(dx, dy)
            n_seg = max(1, round(Int, L / h))
            for k in 1:(n_seg - 1)
                t = k / n_seg
                x = va[1] + t * dx
                y = va[2] + t * dy
                kp = (round_key(x), round_key(y))
                kp in seen && continue
                push!(seen, kp)
                push!(nodes, Asap.Node([x * u"m", y * u"m", slab_z * u"m"], :free))
            end
        end

        # Interior grid at spacing h (for smooth deflection inside patch)
        xmin = minimum(v[1] for v in verts)
        xmax = maximum(v[1] for v in verts)
        ymin = minimum(v[2] for v in verts)
        ymax = maximum(v[2] for v in verts)
        nx_raw = max(1, round(Int, (xmax - xmin) / h))
        ny_raw = max(1, round(Int, (ymax - ymin) / h))
        # Cap to avoid excessive nodes for very large patches
        max_per_dim = 15
        nx = min(nx_raw, max_per_dim)
        ny = min(ny_raw, max_per_dim)
        for i in 0:nx
            x = i == nx ? xmax : xmin + i * (xmax - xmin) / nx
            for j in 0:ny
                y = j == ny ? ymax : ymin + j * (ymax - ymin) / ny
                pt = (x, y)
                _point_inside_polygon(pt, verts) || continue
                kp = (round_key(x), round_key(y))
                kp in seen && continue
                push!(seen, kp)
                push!(nodes, Asap.Node([x * u"m", y * u"m", slab_z * u"m"], :free))
            end
        end
    end
    return nodes
end

"""
Return all column nodes that lie on the slab footprint (interior or boundary).
Used as refinement targets to improve shell quality near slab-column interfaces.

Uses the vertex at slab elevation for each supporting column, not just `vertex_idx`
(which is always the column top). This ensures refinement targets are correct for
slabs both above and below each column segment.
"""
function _get_slab_column_nodes(struc::BuildingStructure, slab::Slab, nodes::Vector{Asap.Node})
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    slab_cell_set = Set(slab.cell_indices)

    # Slab elevation from any cell vertex (all vertices of a cell face share the same Z)
    first_cell = struc.cells[first(slab.cell_indices)]
    first_vi = skel.face_vertex_indices[first_cell.face_idx][1]
    slab_z = vc[first_vi, 3]
    z_tol = 0.1  # meters

    supporting = StructuralSizer.find_supporting_columns(struc, slab_cell_set)
    isempty(supporting) && return Asap.Node[]

    target_verts = Int[]
    for col in supporting
        vi_slab = _column_vertex_at_slab_level(struc, col, slab_z; z_tol)
        vi_slab === nothing && continue
        (1 <= vi_slab <= length(nodes)) || continue
        push!(target_verts, vi_slab)
    end

    return Asap.Node[nodes[vi] for vi in unique(target_verts)]
end

"""
    _column_vertex_at_slab_level(struc, col, slab_z; z_tol=0.1) -> Union{Int, Nothing}

Return the skeleton vertex index where the column connects to the slab at elevation `slab_z`.
Checks both ends of each column segment; `vertex_idx` is always the top, so we must
explicitly find the vertex at slab level for slabs below the column.
"""
function _column_vertex_at_slab_level(struc::BuildingStructure, col, slab_z::Float64; z_tol::Float64=0.1)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords

    for seg_idx in segment_indices(col)
        seg_idx > length(struc.segments) && continue
        edge_idx = struc.segments[seg_idx].edge_idx
        (edge_idx < 1 || edge_idx > length(skel.edge_indices)) && continue
        v1, v2 = skel.edge_indices[edge_idx]
        z1 = vc[v1, 3]
        z2 = vc[v2, 3]
        if abs(z1 - slab_z) <= z_tol
            return v1
        end
        if abs(z2 - slab_z) <= z_tol
            return v2
        end
    end
    return nothing
end


