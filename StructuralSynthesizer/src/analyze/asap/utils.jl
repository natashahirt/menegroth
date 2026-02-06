"""
    to_asap!(struc; params=DesignParameters(), diaphragms=nothing, shell_props=nothing)

Converts a BuildingStructure into an Asap.Model.
Uses TributaryLoads for accurate load distribution based on tributary polygons.

# Arguments
- `struc`: BuildingStructure to convert
- `params::DesignParameters`: Design parameters (load combinations, frame defaults, etc.)
- `diaphragms::Union{Symbol, Nothing}=nothing`: Override diaphragm mode from params
  - `:none` — No diaphragm modeling
  - `:rigid` — Rigid diaphragm (very stiff shell elements)
  - `:shell` — Semi-rigid shell elements from slab geometry
  - `nothing` — Use `params.diaphragm_mode` (default)
- `shell_props::Union{Nothing, NamedTuple}=nothing`: Custom shell properties
  - `E`: Young's modulus (overrides `params.diaphragm_E`)
  - `ν`: Poisson's ratio (overrides `params.diaphragm_ν`)
  - `t_factor`: Thickness multiplier (default: 1.0)

# Examples
```julia
# Simple: use defaults
to_asap!(struc)

# With custom parameters
params = DesignParameters(
    load_combination = STRENGTH_1_2D_1_6L,
    diaphragm_mode = :rigid,
    default_frame_E = 200e9u"Pa",
)
to_asap!(struc; params=params)

# Override diaphragm mode
to_asap!(struc; params=params, diaphragms=:shell)

# Shell diaphragm with custom properties
to_asap!(struc; diaphragms=:shell, shell_props=(E=25e9u"Pa", ν=0.15))
```
"""
function to_asap!(struc::BuildingStructure{T, A, P}; 
                  params::DesignParameters=DesignParameters(),
                  diaphragms::Union{Symbol, Nothing}=nothing,
                  shell_props::Union{Nothing, NamedTuple}=nothing) where {T, A, P}
    
    # Determine diaphragm mode: explicit argument overrides params
    diaphragm_mode = isnothing(diaphragms) ? params.diaphragm_mode : diaphragms
    diaphragm_mode in (:none, :rigid, :shell) || error("diaphragms must be :none, :rigid, or :shell")
    
    skel = struc.skeleton
    
    # 1. Nodes
    support_indices = get(skel.groups_vertices, :support, Int[])
    
    nodes = map(enumerate(skel.vertices)) do (v_idx, v)
        coords = Meshes.coords(v)
        x = uconvert(u"m", coords.x)
        y = uconvert(u"m", coords.y)
        z = uconvert(u"m", coords.z)
        
        is_support = v_idx in support_indices
        dofs = is_support ? [false, false, false, false, false, false] : [true, true, true, false, false, false]
        return Asap.Node([x, y, z], dofs)
    end

    # 2. Frame Elements
    # Default placeholder section using params - will be replaced during sizing
    default_section = Asap.Section(
        4.18e-3u"m^2",              # A (approx W10x22 - placeholder geometry)
        params.default_frame_E,     # E from params
        params.default_frame_G,     # G from params
        89.8e-6u"m^4",              # Ix (placeholder)
        11.4e-6u"m^4",              # Iy (placeholder)
        0.5e-6u"m^4",               # J (placeholder)
        params.default_frame_ρ      # ρ from params
    )
    frame_elements = map(skel.edge_indices) do (v1, v2)
        return Asap.Element(nodes[v1], nodes[v2], default_section, release=:fixedfixed)
    end
    
    # 3. Shell Diaphragm elements (for both :rigid and :shell)
    shell_elements = Asap.ShellElement[]
    
    if diaphragm_mode in (:rigid, :shell) && !isempty(struc.slabs)
        # Build shell_props from params if not provided
        effective_props = _build_shell_props(params, diaphragm_mode, shell_props)
        shell_elements = _create_shell_diaphragms(struc, nodes; 
                                                   mode=diaphragm_mode, props=effective_props)
        @debug "Created diaphragm shells" mode=diaphragm_mode n_shells=length(shell_elements)
    end
    
    # 4. Compute tributaries if not done
    isempty(struc.cell_groups) && build_cell_groups!(struc)
    compute_cell_tributaries!(struc)  # Cache handles deduplication
    
    # 5. Create loads using TributaryLoad (uses params.load_combination)
    loads = Asap.AbstractLoad[]
    empty!(struc.cell_tributary_loads)
    
    for (cell_idx, cell) in enumerate(struc.cells)
        # Skip grade cells (ground floor doesn't contribute loads to frame)
        if cell.floor_type == :grade
            struc.cell_tributary_loads[cell_idx] = Asap.AbstractLoad[]
            continue
        end
        cell_loads = _create_cell_tributary_loads!(loads, frame_elements, skel, struc, cell, cell_idx, params)
        struc.cell_tributary_loads[cell_idx] = cell_loads
    end
    
    # 6. Add structural effects (e.g., vault thrust)
    for slab in struc.slabs
        for spec in slab_edge_line_loads(struc, slab, params)
            el = frame_elements[spec.edge_idx]
            push_asap_loads!(loads, el, spec)
        end
    end

    # 7. Build model (frame elements only for now - shells contribute to K separately)
    struc.asap_model = Asap.Model(nodes, frame_elements, loads)
    
    @debug "Converted to Asap.Model" nodes=length(nodes) frame_elements=length(frame_elements) shell_elements=length(shell_elements) loads=length(loads)

    Asap.process!(struc.asap_model)
    Asap.solve!(struc.asap_model)

    return struc.asap_model
end

"""Build effective shell_props from DesignParameters and explicit overrides."""
function _build_shell_props(params::DesignParameters, mode::Symbol, explicit_props::Union{Nothing, NamedTuple})
    # Start with params values
    E_default = if mode == :rigid
        1e15u"Pa"  # Effectively rigid
    else
        isnothing(params.diaphragm_E) ? 30e9u"Pa" : params.diaphragm_E
    end
    
    ν_default = params.diaphragm_ν
    t_factor = 1.0
    
    # Override with explicit props if provided
    if !isnothing(explicit_props)
        E_default = get(explicit_props, :E, E_default)
        ν_default = get(explicit_props, :ν, ν_default)
        t_factor = get(explicit_props, :t_factor, t_factor)
    end
    
    return (E=E_default, ν=ν_default, t_factor=t_factor)
end

# =============================================================================
# Shell Diaphragm Implementation
# =============================================================================

"""
Create shell diaphragms for all slabs.

For `:rigid` mode: uses very high E (1e15 Pa) for effectively infinite in-plane stiffness.
For `:shell` mode: uses actual slab properties or custom overrides.
"""
function _create_shell_diaphragms(struc::BuildingStructure, nodes::Vector{Asap.Node};
                                   mode::Symbol=:shell,
                                   props::Union{Nothing, NamedTuple}=nothing)
    shells = Asap.ShellElement[]
    
    # Default properties based on mode
    if mode == :rigid
        # Rigid diaphragm: very high stiffness (effectively infinite)
        E_default = 1e15u"Pa"
        ν_default = 0.0  # No Poisson effect for rigid
        t_factor = 1.0
    else  # :shell
        # Semi-rigid: actual concrete properties
        E_default = 30e9u"Pa"
        ν_default = 0.2
        t_factor = 1.0
    end
    
    # Override with custom properties if provided
    if props !== nothing
        E_default = get(props, :E, E_default)
        ν_default = get(props, :ν, ν_default)
        t_factor = get(props, :t_factor, t_factor)
    end
    
    for slab in struc.slabs
        slab_shells = create_slab_diaphragm_shells(struc, slab, nodes; 
                                                    E=E_default, ν=ν_default, t_factor=t_factor)
        append!(shells, slab_shells)
    end
    
    return shells
end

"""Create TributaryLoads for a single cell from its tributary polygons."""
function _create_cell_tributary_loads!(
    loads::Vector{Asap.AbstractLoad},
    elements::Vector{<:Asap.Element},
    skel::BuildingSkeleton,
    struc::BuildingStructure,
    cell::Cell,
    cell_idx::Int,
    params::DesignParameters=DesignParameters()
)::Vector{Asap.TributaryLoad}
    cell_loads = Asap.TributaryLoad[]
    
    # Get tributaries from cache
    tribs = cell_edge_tributaries(struc, cell_idx)
    isnothing(tribs) && return cell_loads
    
    face_edges = skel.face_edge_indices[cell.face_idx]
    face_verts = skel.face_vertex_indices[cell.face_idx]
    
    # Use load combination from params instead of hardcoded factors
    combo = params.load_combination
    dead = cell.sdl + cell.self_weight
    live = cell.live_load
    pressure = uconvert(u"Pa", factored_pressure(combo, dead, live))
    
    n_verts = length(face_verts)
    
    for trib in tribs
        # Skip empty tributaries
        trib.area < 1e-12 && continue
        length(trib.s) < 2 && continue
        
        # Extract width profile from tributary polygon
        positions, widths_m = _extract_width_profile(trib)
        length(positions) < 2 && continue
        
        # Map local edge index to global edge/element
        local_idx = trib.local_edge_idx
        global_edge_idx = face_edges[local_idx]
        el = elements[global_edge_idx]
        
        # Check if edge direction matches face CCW order
        # Face expects: face_verts[local_idx] → face_verts[local_idx+1]
        # Edge stored as: skel.edge_indices[global_edge_idx] = (v1, v2)
        expected_v1 = face_verts[local_idx]
        expected_v2 = face_verts[mod1(local_idx + 1, n_verts)]
        actual_v1, actual_v2 = skel.edge_indices[global_edge_idx]
        
        # If edge is reversed relative to face CCW order, flip the parametric positions
        edge_reversed = (actual_v1 == expected_v2 && actual_v2 == expected_v1)
        
        if edge_reversed
            # Flip: s → 1-s, and reverse the arrays to maintain sorted order
            positions = reverse(1.0 .- positions)
            widths_m = reverse(widths_m)
        end
        
        # Convert widths to Unitful
        widths = [w * u"m" for w in widths_m]
        
        # Create TributaryLoad (gravity direction)
        tload = Asap.TributaryLoad(el, positions, widths, pressure, (0.0, 0.0, -1.0))
        
        push!(loads, tload)
        push!(cell_loads, tload)
    end
    
    return cell_loads
end

"""
Extract a sorted width profile from a TributaryPolygon.

The polygon vertices trace the boundary, but TributaryLoad needs positions
sorted along the beam with corresponding widths.

Returns (positions, widths) where positions are in [0,1] sorted order.
"""
function _extract_width_profile(trib::TributaryPolygon)
    isempty(trib.s) && return (Float64[], Float64[])
    
    # Collect (s, |d|) pairs and sort by s
    pairs = [(trib.s[i], abs(trib.d[i])) for i in eachindex(trib.s)]
    sort!(pairs, by=first)
    
    # Remove duplicates (keep max width at each position)
    merged = Tuple{Float64, Float64}[]
    for (s, w) in pairs
        if isempty(merged) || abs(s - merged[end][1]) > 1e-9
            push!(merged, (s, w))
        else
            # Same position - keep max width
            merged[end] = (merged[end][1], max(merged[end][2], w))
        end
    end
    
    # Extract separate vectors
    positions = [p[1] for p in merged]
    widths = [p[2] for p in merged]
    
    # Ensure positions are clamped to [0, 1]
    positions = clamp.(positions, 0.0, 1.0)
    
    return (positions, widths)
end

"""
    update_slab_loads!(struc, slab_idx)

Update tributary load pressures when a slab's properties change.
Call this after modifying slab sizing results, then the model will be re-solved.
"""
function update_slab_loads!(struc::BuildingStructure, slab_idx::Int)
    slab = struc.slabs[slab_idx]
    sw = StructuralSizer.self_weight(slab.result)
    
    for cell_idx in slab.cell_indices
        cell = struc.cells[cell_idx]
        cell.self_weight = sw
        
        new_pressure = uconvert(u"Pa", total_factored_pressure(cell))
        
        for tload in get(struc.cell_tributary_loads, cell_idx, Asap.TributaryLoad[])
            tload.pressure = new_pressure
        end
    end
    
    Asap.solve!(struc.asap_model; reprocess=true)
end

"""
    update_all_slab_loads!(struc)

Update all tributary load pressures and re-solve.
"""
function update_all_slab_loads!(struc::BuildingStructure)
    for slab_idx in eachindex(struc.slabs)
        slab = struc.slabs[slab_idx]
        sw = StructuralSizer.self_weight(slab.result)
        
        for cell_idx in slab.cell_indices
            cell = struc.cells[cell_idx]
            cell.self_weight = sw
            
            new_pressure = uconvert(u"Pa", total_factored_pressure(cell))
            
            for tload in get(struc.cell_tributary_loads, cell_idx, Asap.TributaryLoad[])
                tload.pressure = new_pressure
            end
        end
    end
    
    Asap.solve!(struc.asap_model; reprocess=true)
end

# =============================================================================
# Slab → edge load interface
# =============================================================================

"""
    push_asap_loads!(loads, element, spec)

Convert a backend-agnostic edge load spec into ASAP loads.
Assumes `spec` magnitudes are base SI (N, N/m).

# Fallback Behavior
Unrecognized `AbstractEdgeLoadSpec` subtypes issue a warning and are skipped,
allowing the model to proceed with available loads rather than failing.
"""
function push_asap_loads!(loads::Vector{Asap.AbstractLoad}, el::Asap.Element, spec::AbstractEdgeLoadSpec)
    @warn "No ASAP conversion for $(typeof(spec)) — load skipped" maxlog=1
    return loads
end

function push_asap_loads!(loads::Vector{Asap.AbstractLoad}, el::Asap.Element, spec::EdgeLineLoadSpec)
    # Convert Float64 line load (assumed SI N/m) to Unitful
    w_unitful = [w * u"N/m" for w in collect(spec.w)]
    push!(loads, Asap.LineLoad(el, w_unitful))
    return loads
end

"""
    slab_face_edge_ids(struc, slab) -> Vector{Int}

Return the unique set of skeleton edges referenced by the slab's faces.
"""
function slab_face_edge_ids(struc::BuildingStructure, slab::Slab)
    skel = struc.skeleton

    edge_set = Set{Int}()
    for cell_idx in slab.cell_indices
        face_idx = struc.cells[cell_idx].face_idx
        for e_idx in skel.face_edge_indices[face_idx]
            push!(edge_set, e_idx)
        end
    end

    edge_ids = collect(edge_set)
    sort!(edge_ids)  # deterministic ordering (useful for reproducibility/debug)
    return edge_ids
end

"""Internal helper: structural effects as `EdgeLineLoadSpec` (e.g. vault thrust)."""
function slab_edge_line_loads(struc::BuildingStructure, slab::Slab, 
                               params::DesignParameters=DesignParameters())::Vector{EdgeLineLoadSpec}
    effects = StructuralSizer.structural_effects(slab.result)
    isempty(effects) && return EdgeLineLoadSpec[]

    loads = EdgeLineLoadSpec[]

    for eff in effects
        if eff isa StructuralSizer.LateralThrust
            append!(loads, vault_thrust_line_loads(struc, slab, eff, params))
        end
    end

    return loads
end

# --- Vault thrust → edge line loads (simple implementation) ---
function vault_thrust_line_loads(struc::BuildingStructure, slab::Slab, 
                                  eff::StructuralSizer.LateralThrust,
                                  params::DesignParameters=DesignParameters())::Vector{EdgeLineLoadSpec}
    # Factored thrust using load combination from params
    combo = params.load_combination
    thrust_factored = eff.dead * combo.D + eff.live * combo.L
    mag_N_m = ustrip(u"N/m", uconvert(u"N/m", thrust_factored))

    # Span axis from slab spans
    span_vec = [slab.spans.axis[1], slab.spans.axis[2], 0.0]

    # Vault slabs are enforced as single rectangular faces; thrust acts on that perimeter.
    face_idx = struc.cells[first(slab.cell_indices)].face_idx
    skel = struc.skeleton
    boundary_edges = skel.face_edge_indices[face_idx]

    out = EdgeLineLoadSpec[]
    for e_idx in boundary_edges
        edge = skel.edges[e_idx]
        p1, p2 = Meshes.vertices(edge)
        c1, c2 = Meshes.coords(p1), Meshes.coords(p2)

        v = [c2.x - c1.x, c2.y - c1.y, c2.z - c1.z]
        v_norm = v / sqrt(sum(v .^ 2))
        is_perpendicular = abs(sum(v_norm .* span_vec)) < 0.1
        is_perpendicular || continue

        # Determine "outward" direction (simple heuristic from previous implementation)
        mid = [(c1.x + c2.x) / 2, (c1.y + c2.y) / 2, (c1.z + c2.z) / 2]
        f_poly = skel.faces[face_idx]
        f_pts = Meshes.vertices(f_poly)
        f_xs = [Meshes.coords(p).x for p in f_pts]
        f_ys = [Meshes.coords(p).y for p in f_pts]
        f_zs = [Meshes.coords(p).z for p in f_pts]
        f_mid = [sum(f_xs) / length(f_pts), sum(f_ys) / length(f_pts), sum(f_zs) / length(f_pts)]

        out_vec = mid .- f_mid
        proj = sum(out_vec .* span_vec)
        # `proj` carries length units; compare against a unit-consistent zero.
        dir = proj > zero(proj) ? span_vec : -span_vec

        w = (dir[1] * mag_N_m, dir[2] * mag_N_m, dir[3] * mag_N_m)
        push!(out, EdgeLineLoadSpec(Int(e_idx), w))
    end

    return out
end

# =============================================================================
# Diaphragm Shell Creation (uses Asap.Shell meshing)
# =============================================================================

"""
    create_slab_diaphragm_shells(struc, slab, nodes; E, ν, t_factor) -> Vector{<:Asap.ShellElement}

Create shell elements for a slab's diaphragm action from its cell faces.
Uses Asap.Shell() for automatic triangulation.

# Arguments
- `struc`: BuildingStructure containing the slab
- `slab`: Slab object with sizing result
- `nodes`: Vector of Asap.Node (indexed same as skeleton vertices)
- `E`: Young's modulus (default uses slab concrete or 30 GPa)
- `ν`: Poisson's ratio (default 0.2)
- `t_factor`: Thickness multiplier (default 1.0)

# Returns
Vector of ShellTri3 elements.
"""
function create_slab_diaphragm_shells(struc::BuildingStructure, slab::Slab, nodes::Vector{Asap.Node};
                                       E=nothing, ν::Float64=0.2, t_factor::Float64=1.0)
    skel = struc.skeleton
    
    # Get slab thickness (with optional scaling)
    t = thickness(slab) * t_factor
    
    # Determine E: use provided, or try slab concrete, or default
    if E === nothing
        E = 30e9u"Pa"  # default concrete
        if hasfield(typeof(slab.result), :concrete) && slab.result.concrete !== nothing
            if hasfield(typeof(slab.result.concrete), :E)
                E = slab.result.concrete.E
            end
        end
    end
    
    # Convert E to Pa if not already
    E_pa = E isa Unitful.Quantity ? uconvert(u"Pa", E) : E * u"Pa"
    
    # Collect face indices for this slab
    face_indices = [struc.cells[ci].face_idx for ci in slab.cell_indices]
    
    # Create shells from face meshes using Asap.Shell
    shells = Asap.ShellElement[]
    section = Asap.ShellSection(t, E_pa, ν; ρ=0.0u"kg/m^3")  # zero mass for diaphragm
    
    for face_idx in face_indices
        vert_indices = skel.face_vertex_indices[face_idx]
        corners = tuple([nodes[vi] for vi in vert_indices]...)
        
        # Use Asap's Shell() for automatic triangulation (n=2 for coarse mesh)
        face_shells = Asap.Shell(corners, section; n=2, id=:diaphragm,
                                 edge_support_type=:free, interior_support_type=:free)
        append!(shells, face_shells)
    end
    
    # Assign global DOFs to each shell
    for shell in shells
        Asap.populate_globalID!(shell)
    end
    
    return shells
end

# Helper to extract release symbol from Element type parameter
function _get_release_symbol(el::Asap.Element{R}) where R
    R === Asap.FixedFixed && return :fixedfixed
    R === Asap.FixedFree && return :fixedfree
    R === Asap.FreeFixed && return :freefixed
    R === Asap.FreeFree && return :freefree
    R === Asap.Joist && return :joist
    return :fixedfixed  # fallback
end

# =============================================================================
# Analysis Model Builder (Frame + Shell for Global Deflection)
# =============================================================================

"""
    build_analysis_model!(design; load_combination=SERVICE, mesh_density=2, frame_groups=:auto)

Build a frame+shell Asap model for global deflection analysis.

This creates a **separate** model stored in `design.asap_model` that includes:
- Frame elements (columns, and optionally beams)
- Shell elements representing designed slabs
- Area loads (SDL + LL) applied directly to shells

The original `struc.asap_model` (frame-only) is preserved for design calculations.

# Arguments
- `design::BuildingDesign`: Design with completed slab sizing
- `load_combination::LoadCombination`: Load factors (default: SERVICE = 1.0D + 1.0L)
- `mesh_density::Int`: Shell mesh refinement per face (default: 2 = 2×2 triangulation)
- `frame_groups`: Which skeleton edge groups to include as frame elements
  - `:auto` (default): Infer from floor type
    - `:flat_plate` → `[:columns]` (beamless)
    - `:one_way`, `:two_way` → `[:columns, :beams]`
  - `Vector{Symbol}`: Explicit list, e.g. `[:columns]` or `[:columns, :beams]`

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
"""
function build_analysis_model!(design::BuildingDesign;
                               load_combination::LoadCombination=SERVICE,
                               mesh_density::Int=2,
                               frame_groups::Union{Symbol, Vector{Symbol}}=:auto)
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
    
    # ─── 2. Create nodes (same as struc.asap_model) ───
    support_indices = get(skel.groups_vertices, :support, Int[])
    nodes = [begin
        c = Meshes.coords(skel.vertices[i])
        is_support = i in support_indices
        dofs = is_support ? [false, false, false, false, false, false] : [true, true, true, false, false, false]
        Asap.Node([uconvert(u"m", c.x), uconvert(u"m", c.y), uconvert(u"m", c.z)], dofs)
    end for i in eachindex(skel.vertices)]
    
    # ─── 3. Copy frame elements from selected groups ───
    # Use existing elements from struc.asap_model (preserves sized sections)
    src_model = struc.asap_model
    frame_elements = Asap.FrameElement[]
    
    for (edge_idx, (v1, v2)) in enumerate(skel.edge_indices)
        # Only include edges from selected groups
        edge_idx in included_edges || continue
        
        # Get section from source model if available
        src_el = src_model.elements[edge_idx]
        section = src_el.section
        
        # Extract release symbol from type parameter
        release_sym = _get_release_symbol(src_el)
        
        el = Asap.Element(nodes[v1], nodes[v2], section; release=release_sym)
        push!(frame_elements, el)
    end
    
    # ─── 4. Create shell elements for slabs ───
    shell_elements = Asap.ShellElement[]
    slab_shell_map = Dict{Int, Vector{Asap.ShellElement}}()  # slab_idx → shells
    
    for (slab_idx, slab) in enumerate(struc.slabs)
        # Get slab properties
        t = thickness(slab)
        
        # Get concrete properties from slab result
        E = 30e9u"Pa"  # default
        ρ = 2400.0u"kg/m^3"  # default concrete density
        
        if hasfield(typeof(slab.result), :concrete) && !isnothing(slab.result.concrete)
            concrete = slab.result.concrete
            hasfield(typeof(concrete), :E) && (E = concrete.E)
            hasfield(typeof(concrete), :ρ) && (ρ = concrete.ρ)
        end
        
        E_pa = uconvert(u"Pa", E)
        ρ_kgm3 = uconvert(u"kg/m^3", ρ)
        
        # Create shell section with proper density (enables self-weight)
        section = Asap.ShellSection(t, E_pa, 0.2; ρ=ρ_kgm3)
        
        # Create shells for each cell face
        slab_shells = Asap.ShellElement[]
        face_indices = [struc.cells[ci].face_idx for ci in slab.cell_indices]
        
        for face_idx in face_indices
            vert_indices = skel.face_vertex_indices[face_idx]
            corners = tuple([nodes[vi] for vi in vert_indices]...)
            
            face_shells = Asap.Shell(corners, section; n=mesh_density, 
                                     id=Symbol("slab_$(slab_idx)"),
                                     edge_support_type=:free, 
                                     interior_support_type=:free)
            append!(slab_shells, face_shells)
        end
        
        # Note: populate_globalID! is called by model.process! after nodes get their IDs
        slab_shell_map[slab_idx] = slab_shells
        append!(shell_elements, slab_shells)
    end
    
    # ─── 5. Create loads ───
    loads = Asap.AbstractLoad[]
    
    # Self-weight of shells (concrete weight)
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
    
    # ─── 6. Build and solve model ───
    model = Asap.Model(nodes, frame_elements, shell_elements, loads)
    
    Asap.process!(model)
    Asap.solve!(model)
    
    design.asap_model = model
    
    @info "Built analysis model" frame_groups=resolved_groups n_frames=length(frame_elements) n_shells=length(shell_elements) n_loads=length(loads)
    
    return model
end