"""
    _create_offset_nodes(skel, col_offset_by_vertex, support_set) -> Vector{Asap.Node}

Create Asap nodes from skeleton vertices, applying structural offsets for edge/corner columns.
Shared by `to_asap!` and `build_analysis_model!`.
"""
function _create_offset_nodes(skel::BuildingSkeleton, col_offset_by_vertex, support_set::Set{Int})
    vc = skel.geometry.vertex_coords
    n_verts = length(skel.vertices)
    nodes = Vector{Asap.Node}(undef, n_verts)
    @inbounds for v_idx in 1:n_verts
        off = get(col_offset_by_vertex, v_idx, nothing)
        x = (vc[v_idx, 1] + (isnothing(off) ? 0.0 : off[1])) * u"m"
        y = (vc[v_idx, 2] + (isnothing(off) ? 0.0 : off[2])) * u"m"
        z = vc[v_idx, 3] * u"m"
        dofs = v_idx in support_set ? [false, false, false, false, false, false] : [true, true, true, false, false, false]
        nodes[v_idx] = Asap.Node([x, y, z], dofs)
    end
    return nodes
end

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
    load_combinations = [strength_1_2D_1_6L, strength_1_4D],
    diaphragm_mode = :rigid,
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
    
    # 1. Nodes — from cached coordinate matrix, with structural offsets for columns.
    # Both endpoints of each column edge share the same XY offset so the column
    # line shifts as a rigid body and beams that frame into the column follow.
    col_offset_by_vertex = Dict{Int, NTuple{2, Float64}}()
    for col in struc.columns
        off = col.structural_offset
        (off[1] == 0.0 && off[2] == 0.0) && continue
        for seg_idx in segment_indices(col)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            (edge_idx < 1 || edge_idx > length(skel.edge_indices)) && continue
            v1, v2 = skel.edge_indices[edge_idx]
            col_offset_by_vertex[v1] = off
            col_offset_by_vertex[v2] = off
        end
    end

    support_set = Set(get(skel.groups_vertices, :support, Int[]))
    nodes = _create_offset_nodes(skel, col_offset_by_vertex, support_set)

    # 2. Frame Elements — placeholder section (replaced during sizing)
    # Use steel from materials cascade if available, else defaults
    _mat_steel = params.materials.steel
    frame_E = isnothing(_mat_steel) ? params.default_frame_E : uconvert(u"Pa", _mat_steel.E)
    frame_G = isnothing(_mat_steel) ? params.default_frame_G : uconvert(u"Pa", _mat_steel.G)
    frame_ρ = isnothing(_mat_steel) ? params.default_frame_ρ : uconvert(u"kg/m^3", _mat_steel.ρ)
    default_section = Asap.Section(
        4.18e-3u"m^2",    # A (approx W10x22 — placeholder geometry)
        frame_E, frame_G,
        89.8e-6u"m^4",    # Ix
        11.4e-6u"m^4",    # Iy
        0.5e-6u"m^4",     # J
        frame_ρ
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
    
    # 5. Create loads using TributaryLoad
    loads = Asap.AbstractLoad[]
    empty!(struc.cell_tributary_loads)
    empty!(struc.cell_dead_loads)
    empty!(struc.cell_live_loads)
    
    use_patterns = params.pattern_loading != :none
    combo = governing_combo(params)
    
    for (cell_idx, cell) in enumerate(struc.cells)
        if cell.floor_type == :grade
            struc.cell_tributary_loads[cell_idx] = Asap.TributaryLoad[]
            struc.cell_dead_loads[cell_idx] = Asap.TributaryLoad[]
            struc.cell_live_loads[cell_idx] = Asap.TributaryLoad[]
            continue
        end
        
        if use_patterns
            dead, live = _create_cell_tributary_loads!(
                loads, frame_elements, skel, struc, cell, cell_idx, params;
                split_dead_live=true, combo=combo)
            struc.cell_dead_loads[cell_idx] = dead
            struc.cell_live_loads[cell_idx] = live
            struc.cell_tributary_loads[cell_idx] = vcat(dead, live)
        else
            combined = _create_cell_tributary_loads!(
                loads, frame_elements, skel, struc, cell, cell_idx, params;
                split_dead_live=false, combo=combo)
            struc.cell_dead_loads[cell_idx] = Asap.TributaryLoad[]
            struc.cell_live_loads[cell_idx] = Asap.TributaryLoad[]
            struc.cell_tributary_loads[cell_idx] = combined
        end
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
    # Resolve concrete E from materials cascade (user's material choice)
    _mat_conc = resolve_concrete(params)
    concrete_E = uconvert(u"Pa", _mat_conc.E)
    
    # Start with params values
    E_default = if mode == :rigid
        1e15u"Pa"  # Effectively rigid
    else
        isnothing(params.diaphragm_E) ? concrete_E : params.diaphragm_E
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
    
    # Default properties based on mode (uses props from _build_shell_props)
    if mode == :rigid
        # Rigid diaphragm: very high stiffness (effectively infinite)
        E_default = 1e15u"Pa"
        ν_default = 0.0  # No Poisson effect for rigid
        t_factor = 1.0
    else  # :shell
        # Semi-rigid: use whatever _build_shell_props resolved from params.concrete
        E_default = uconvert(u"Pa", NWC_4000.E)  # fallback; overridden by props below
        ν_default = NWC_4000.ν
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

"""
Create TributaryLoads for a single cell from its tributary polygons.

When `split_dead_live=true`, returns `(dead_loads, live_loads)` with separate
pressures for pattern loading. When `false` (default), returns combined loads
with enveloped pressure, as a single vector.
"""
function _create_cell_tributary_loads!(
    loads::Vector{Asap.AbstractLoad},
    elements::Vector{<:Asap.Element},
    skel::BuildingSkeleton,
    struc::BuildingStructure,
    cell::Cell,
    cell_idx::Int,
    params::DesignParameters=DesignParameters();
    split_dead_live::Bool=false,
    combo::LoadCombination=governing_combo(params)
)
    dead_loads = Asap.TributaryLoad[]
    live_loads = Asap.TributaryLoad[]
    
    # Get tributaries from cache
    tribs = cell_edge_tributaries(struc, cell_idx)
    if isnothing(tribs)
        return split_dead_live ? (dead_loads, live_loads) : dead_loads
    end
    
    face_edges = skel.face_edge_indices[cell.face_idx]
    face_verts = skel.face_vertex_indices[cell.face_idx]
    if isempty(face_edges)
        @warn "Cell face has no edges (face_idx=$(cell.face_idx)); skipping tributary loads"
        return split_dead_live ? (dead_loads, live_loads) : dead_loads
    end

    # Compute pressures
    if split_dead_live
        dead_pressure = uconvert(u"Pa", combo.D * (cell.sdl + cell.self_weight))
        live_pressure = uconvert(u"Pa", combo.L * cell.live_load)
    else
        combos = params.load_combinations
        dead = cell.sdl + cell.self_weight
        live = cell.live_load
        combined_pressure = uconvert(u"Pa", envelope_pressure(combos, dead, live))
    end
    
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
        expected_v1 = face_verts[local_idx]
        expected_v2 = face_verts[mod1(local_idx + 1, n_verts)]
        actual_v1, actual_v2 = skel.edge_indices[global_edge_idx]
        edge_reversed = (actual_v1 == expected_v2 && actual_v2 == expected_v1)
        
        if edge_reversed
            positions = reverse(1.0 .- positions)
            widths_m = reverse(widths_m)
        end
        
        widths = [w * u"m" for w in widths_m]
        
        if split_dead_live
            dtload = Asap.TributaryLoad(el, positions, widths, dead_pressure, (0.0, 0.0, -1.0))
            ltload = Asap.TributaryLoad(el, copy(positions), copy(widths), live_pressure, (0.0, 0.0, -1.0))
            push!(loads, dtload)
            push!(loads, ltload)
            push!(dead_loads, dtload)
            push!(live_loads, ltload)
        else
            tload = Asap.TributaryLoad(el, positions, widths, combined_pressure, (0.0, 0.0, -1.0))
            push!(loads, tload)
            push!(dead_loads, tload)
        end
    end
    
    return split_dead_live ? (dead_loads, live_loads) : dead_loads
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
    sync_asap!(struc; params=DesignParameters())

Lightweight sync of the Asap model between pipeline stages.

Updates cell self-weights from current slab results, recomputes tributary load
pressures, and re-solves. Does **not** rebuild topology — only loads change.

When `params.pattern_loading != :none`, performs multi-case solve with
checkerboard live load patterns and writes enveloped element forces back to the
model so downstream consumers (`_column_asap_Pu`, beam sizers, etc.) see the
governing demands.

See also: [`to_asap!`](@ref), [`snapshot!`](@ref), [`restore!`](@ref)
"""
function sync_asap!(struc::BuildingStructure;
                    params::DesignParameters=DesignParameters())
    # 1. Push current slab self-weights into cells
    for slab in struc.slabs
        sw = StructuralSizer.self_weight(slab.result)
        for cell_idx in slab.cell_indices
            struc.cells[cell_idx].self_weight = sw
        end
    end
    
    use_patterns = params.pattern_loading != :none &&
                   !isempty(struc.cell_dead_loads) &&
                   any(!isempty, values(struc.cell_dead_loads))
    
    # 2. Update tributary load pressures
    combo = governing_combo(params)
    for (cell_idx, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        if use_patterns
            dead_p = uconvert(u"Pa", combo.D * (cell.sdl + cell.self_weight))
            live_p = uconvert(u"Pa", combo.L * cell.live_load)
            for tload in get(struc.cell_dead_loads, cell_idx, Asap.TributaryLoad[])
                tload.pressure = dead_p
            end
            for tload in get(struc.cell_live_loads, cell_idx, Asap.TributaryLoad[])
                tload.pressure = live_p
            end
        else
            combos = params.load_combinations
            dead = cell.sdl + cell.self_weight
            live = cell.live_load
            combined_p = uconvert(u"Pa", envelope_pressure(combos, dead, live))
            for tload in get(struc.cell_tributary_loads, cell_idx, Asap.TributaryLoad[])
                tload.pressure = combined_p
            end
        end
    end
    
    # 3. Re-process stiffness and loads (topology unchanged)
    if struc.asap_model.processed
        Asap.update!(struc.asap_model)
    else
        Asap.process!(struc.asap_model)
    end
    
    # 4. Solve — single or multi-case
    if use_patterns && _should_run_patterns(struc, params)
        _solve_with_patterns!(struc, params)
    else
        Asap.solve!(struc.asap_model)
    end
    
    return struc
end

"""
Solve the Asap model with multiple pattern loading cases and write the
enveloped element forces back to `element.forces`.

The full-loading displacement vector is kept in `model.u` for downstream
deflection checks and `node.displacement` queries.
"""
function _solve_with_patterns!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    cases = _generate_pattern_cases(struc)
    
    if length(cases) <= 1
        Asap.solve!(model)
        return
    end
    
    # Full-loading solve (mutating) — sets model.u, node.displacement, element.forces
    Asap.solve!(model)
    
    # Multi-case solve (non-mutating) — reuses cached K factorization
    u_cases = Asap.solve(model, cases)
    
    # Envelope element forces across all pattern cases
    n_el = length(model.frame_elements)
    n_el == 0 && return
    
    for el in model.frame_elements
        gid = el.globalID
        best_forces = copy(el.forces)  # start from full-loading forces
        
        for (case_idx, (u, loads)) in enumerate(zip(u_cases, cases))
            case_idx == 1 && continue  # case 1 is full loading (already in best_forces)
            
            # Compute element forces: R * (K * u_e + Q_e)
            u_e = u[gid]
            Q_e = _element_Q(el, loads)
            forces_i = el.R * (el.K * u_e + Q_e)
            
            # Keep the value with larger absolute magnitude at each DOF
            for k in eachindex(forces_i)
                if abs(forces_i[k]) > abs(best_forces[k])
                    best_forces[k] = forces_i[k]
                end
            end
        end
        
        el.forces = best_forces
    end
end

"""
Compute the fixed-end force vector Q for an element from a given load set.
Returns the accumulated `R' * q(load)` for all loads attached to this element.
"""
function _element_Q(el::Asap.Element, loads::Vector{<:Asap.AbstractLoad})
    Q = zeros(length(el.globalID))
    for load in loads
        load isa Asap.ElementLoad || continue
        load.element === el || continue
        Q .+= el.R' * Asap.q(load)
    end
    return Q
end

"""Check whether pattern loading should actually run (`:auto` skips if L/D ≤ 0.75)."""
function _should_run_patterns(struc::BuildingStructure, params::DesignParameters)
    params.pattern_loading == :checkerboard && return true
    # :auto — skip if L/D ≤ 0.75 for ALL non-grade cells (ACI 318-11 §13.7.6.2)
    for cell in struc.cells
        cell.floor_type == :grade && continue
        D = ustrip(u"Pa", cell.sdl + cell.self_weight)
        D < 1e-12 && continue
        L = ustrip(u"Pa", cell.live_load)
        L / D > 0.75 && return true
    end
    return false
end

"""
Generate pattern loading cases from the dead/live tributary load dicts.

Returns a vector of load vectors:
1. Full loading (dead + all live)
2. Checkerboard A (dead + live on "even" cells)
3. Checkerboard B (dead + live on "odd" cells)
"""
# Module-level cache for checkerboard partition (geometry-only, computed once per model)
const _CHECKERBOARD_CACHE = Ref{Tuple{UInt, Tuple{Vector{Int}, Vector{Int}}}}((UInt(0), (Int[], Int[])))

function _generate_pattern_cases(struc::BuildingStructure)
    dead_all = Asap.AbstractLoad[]
    sizehint!(dead_all, sum(length(v) for (_, v) in struc.cell_dead_loads; init=0))
    live_all = Asap.AbstractLoad[]
    sizehint!(live_all, sum(length(v) for (_, v) in struc.cell_live_loads; init=0))
    for (_, loads) in struc.cell_dead_loads
        append!(dead_all, loads)
    end
    for (_, loads) in struc.cell_live_loads
        append!(live_all, loads)
    end
    
    # Full loading
    case_full = Asap.AbstractLoad[dead_all; live_all]
    
    # Checkerboard partition — cached (geometry never changes for a given skeleton)
    skel_id = objectid(struc.skeleton)
    if _CHECKERBOARD_CACHE[][1] == skel_id
        set_a, set_b = _CHECKERBOARD_CACHE[][2]
    else
        set_a, set_b = _checkerboard_partition(struc)
        _CHECKERBOARD_CACHE[] = (skel_id, (set_a, set_b))
    end
    
    live_a = Asap.AbstractLoad[]
    live_b = Asap.AbstractLoad[]
    for ci in set_a
        append!(live_a, get(struc.cell_live_loads, ci, Asap.TributaryLoad[]))
    end
    for ci in set_b
        append!(live_b, get(struc.cell_live_loads, ci, Asap.TributaryLoad[]))
    end
    
    case_a = Asap.AbstractLoad[dead_all; live_a]
    case_b = Asap.AbstractLoad[dead_all; live_b]
    
    return [case_full, case_a, case_b]
end

"""
Partition non-grade cells into two checkerboard sets based on centroid parity.

For regular rectangular grids this produces the classic checkerboard. For
irregular layouts the partition is approximate but still provides useful
pattern coverage.
"""
function _checkerboard_partition(struc::BuildingStructure)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    
    # Collect cell centroids (x, y) and floor elevations
    centroids = Dict{Int, NTuple{3, Float64}}()
    for (cell_idx, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        vis = skel.face_vertex_indices[cell.face_idx]
        isempty(vis) && continue
        cx = sum(vc[v, 1] for v in vis) / length(vis)
        cy = sum(vc[v, 2] for v in vis) / length(vis)
        cz = sum(vc[v, 3] for v in vis) / length(vis)
        centroids[cell_idx] = (cx, cy, cz)
    end
    
    isempty(centroids) && return (Int[], Int[])
    
    # Find minimum grid spacings in x and y (from unique sorted centroid values)
    xs = sort(unique(round(c[1], digits=4) for c in values(centroids)))
    ys = sort(unique(round(c[2], digits=4) for c in values(centroids)))
    
    dx = length(xs) > 1 ? minimum(diff(xs)) : 1.0
    dy = length(ys) > 1 ? minimum(diff(ys)) : 1.0
    dx = max(dx, 1e-6)
    dy = max(dy, 1e-6)
    
    # Assign parity: floor to grid indices, sum, check even/odd
    # (floor avoids banker's rounding which maps 0.5 and 1.5 to the same parity)
    x0 = minimum(c[1] for c in values(centroids))
    y0 = minimum(c[2] for c in values(centroids))
    set_a = Int[]
    set_b = Int[]
    for (ci, (cx, cy, _)) in centroids
        ix = floor(Int, (cx - x0 + 0.5dx) / dx)
        iy = floor(Int, (cy - y0 + 0.5dy) / dy)
        if iseven(ix + iy)
            push!(set_a, ci)
        else
            push!(set_b, ci)
        end
    end
    
    return (set_a, set_b)
end

# update_slab_loads! and update_all_slab_loads! removed — use sync_asap!(struc; params) instead.

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
    # Convert Float64 line load (assumed SI N/m) to Unitful — no intermediate collect
    w_unitful = [spec.w[1] * u"N/m", spec.w[2] * u"N/m", spec.w[3] * u"N/m"]
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
    # Factored thrust using governing (primary) load combination from params
    combo = governing_combo(params)
    thrust_factored = eff.dead * combo.D + eff.live * combo.L
    mag_N_m = ustrip(u"N/m", uconvert(u"N/m", thrust_factored))

    # Span axis from slab spans
    span_vec = [slab.spans.axis[1], slab.spans.axis[2], 0.0]

    # Vault slabs are enforced as single rectangular faces; thrust acts on that perimeter.
    face_idx = struc.cells[first(slab.cell_indices)].face_idx
    skel = struc.skeleton
    boundary_edges = skel.face_edge_indices[face_idx]

    vc = skel.geometry.vertex_coords
    f_vis = skel.face_vertex_indices[face_idx]
    f_mid = [sum(vc[vi, k] for vi in f_vis) / length(f_vis) for k in 1:3]

    out = EdgeLineLoadSpec[]
    for e_idx in boundary_edges
        ev1, ev2 = skel.edge_indices[e_idx]
        v = [vc[ev2, k] - vc[ev1, k] for k in 1:3]
        v_len = sqrt(sum(v .^ 2))
        v_norm = v / v_len
        abs(sum(v_norm .* span_vec)) < 0.1 || continue

        mid = [(vc[ev1, k] + vc[ev2, k]) / 2 for k in 1:3]
        out_vec = mid .- f_mid
        proj = sum(out_vec .* span_vec)
        dir = proj > 0 ? span_vec : -span_vec

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
- `E`: Young's modulus (default: from slab result material, then NWC_4000)
- `ν`: Poisson's ratio (default: from slab result material, then NWC_4000)
- `t_factor`: Thickness multiplier (default 1.0)

# Returns
Vector of ShellTri3 elements.
"""
function create_slab_diaphragm_shells(struc::BuildingStructure, slab::Slab, nodes::Vector{Asap.Node};
                                       E=nothing, ν::Float64=NWC_4000.ν, t_factor::Float64=1.0)
    skel = struc.skeleton
    
    # Get slab thickness (with optional scaling)
    t = thickness(slab) * t_factor
    
    # Determine E: use provided, or try slab concrete, or default
    if E === nothing
        E = uconvert(u"Pa", NWC_4000.E)  # fallback
        if hasfield(typeof(slab.result), :concrete) && slab.result.concrete !== nothing
            if hasfield(typeof(slab.result.concrete), :E)
                E = slab.result.concrete.E
            end
            if hasfield(typeof(slab.result.concrete), :ν)
                ν = slab.result.concrete.ν
            end
        end
    end
    
    E_pa = uconvert(u"Pa", E)
    
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

"""Extract the end-release symbol (`:fixedfixed`, etc.) from an `Asap.Element` type parameter."""
function _get_release_symbol(el::Asap.Element{R}) where R
    R === Asap.FixedFixed && return :fixedfixed
    R === Asap.FixedFree && return :fixedfree
    R === Asap.FreeFixed && return :freefixed
    R === Asap.FreeFree && return :freefree
    R === Asap.Joist && return :joist
    return :fixedfixed  # fallback
end

"""
    _get_slab_boundary_vertices(struc, slab)
        -> (boundary_vis::Vector{Int}, interior_edge_vis::Vector{Tuple{Int,Int}})

Ordered boundary vertex indices and interior cell-edge vertex pairs for a slab.

Single-cell slabs: boundary = face polygon, interior edges = empty.
Multi-cell slabs: boundary edges (shared by exactly 1 cell) are chained into a
CCW polygon; interior edges (shared by 2+ cells) are returned as vertex pairs.

Correctly handles concave slab boundaries (L-shapes, T-shapes, etc.) — does NOT
use a convex hull.  The architecture supports future multiply-connected domains
(slab openings) via `DT.triangulate(...; boundary_nodes=...)`.
"""
function _get_slab_boundary_vertices(struc::BuildingStructure, slab::Slab)
    skel = struc.skeleton

    if length(slab.cell_indices) == 1
        cell = struc.cells[first(slab.cell_indices)]
        boundary = collect(skel.face_vertex_indices[cell.face_idx])
        return (boundary, Tuple{Int,Int}[])
    end

    # Count how many slab cells reference each skeleton edge
    edge_count = Dict{Int, Int}()
    for ci in slab.cell_indices
        face_idx = struc.cells[ci].face_idx
        for ei in skel.face_edge_indices[face_idx]
            edge_count[ei] = get(edge_count, ei, 0) + 1
        end
    end

    boundary_edge_vis = Tuple{Int,Int}[skel.edge_indices[ei] for (ei, c) in edge_count if c == 1]
    interior_edge_vis = Tuple{Int,Int}[skel.edge_indices[ei] for (ei, c) in edge_count if c >= 2]

    isempty(boundary_edge_vis) && error("Could not find slab boundary — all edges are shared.")

    # Chain boundary edges into an ordered polygon
    adj = Dict{Int, Vector{Int}}()
    for (a, b) in boundary_edge_vis
        push!(get!(adj, a, Int[]), b)
        push!(get!(adj, b, Int[]), a)
    end

    start = boundary_edge_vis[1][1]
    boundary = [start]
    prev = 0
    current = start
    for _ in 1:length(boundary_edge_vis)
        neighbors = adj[current]
        next = first(n for n in neighbors if n != prev)
        next == start && break
        push!(boundary, next)
        prev = current
        current = next
    end

    # Ensure CCW orientation (Delaunay triangulator requirement)
    _ensure_ccw_vis!(boundary, skel)

    return (boundary, interior_edge_vis)
end

"""
    _ensure_ccw_vis!(vis, skel)

Reverse `vis` in-place if the polygon formed by the skeleton vertices is CW.
Uses the signed-area (shoelace) sign test.
"""
function _ensure_ccw_vis!(vis::Vector{Int}, skel)
    n = length(vis)
    vc = skel.geometry.vertex_coords
    signed_area = 0.0
    for i in 1:n
        j = mod1(i + 1, n)
        signed_area += vc[vis[i], 1] * vc[vis[j], 2] -
                       vc[vis[j], 1] * vc[vis[i], 2]
    end
    signed_area < 0 && reverse!(vis)
    return vis
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
                               load_combination::LoadCombination=service,
                               mesh_density::Int=2,
                               frame_groups::Union{Symbol, Vector{Symbol}}=:auto,
                               target_edge_length=nothing,
                               refinement_edge_length=nothing,
                               refinement_radius=nothing,
                               refinement_targets=nothing)
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
    )

    # ─── 3. Create nodes with structural offsets ───
    # Reuse offsets already captured in design (populated by capture_design before restore!)
    support_set = Set(get(skel.groups_vertices, :support, Int[]))
    nodes = _create_offset_nodes(skel, design.structural_offsets, support_set)
    
    # ─── 4. Copy frame elements from selected groups ───
    # Use existing elements from struc.asap_model (preserves sized sections)
    src_model = struc.asap_model
    frame_elements = Asap.FrameElement[]
    frame_edge_indices = Int[]
    
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
        push!(frame_edge_indices, edge_idx)
    end
    
    # ─── 5. Create shell elements for slabs ───
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
                    patch_stiffness_factor=1.0,
                    vertex_set=slab_vertex_set) :
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
                    patch_stiffness_factor=1.0,
                    vertex_set=slab_vertex_set) :
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
    
    # ─── 6. Create loads ───
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
    
    # ─── 7. Build and solve model ───
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
    refinement_targets=nothing)

    floor_opts = resolve_floor_options(design.params)
    method = if floor_opts isa StructuralSizer.FlatSlabOptions
        floor_opts.base.method
    elseif floor_opts isa StructuralSizer.FlatPlateOptions
        floor_opts.method
    else
        nothing
    end

    fea_target_edge = (method isa StructuralSizer.FEA) ? method.target_edge : nothing

    resolved_target = isnothing(target_edge_length) ? fea_target_edge : target_edge_length

    return (
        target_edge_length = resolved_target,
        refinement_edge_length = refinement_edge_length,
        refinement_radius = refinement_radius,
        refinement_targets = refinement_targets,
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



# =============================================================================
# Fire Protection Coating → Line Loads
# =============================================================================

"""
    add_coating_loads!(struc, params; member_edge_group=:beams, resolve=true)

Add fire protection coating self-weight as `Asap.LineLoad`s on steel members.

Call **after** `size_steel_members!` so that sections are assigned. The coating
weight `w = thickness × perimeter × density` acts as additional dead load in
the global -Z direction.

For beams (3-sided exposure), uses `section.PA`; for columns (4-sided), `section.PB`.

# Arguments
- `struc`: BuildingStructure with a solved ASAP model and sized steel members
- `params`: DesignParameters with `fire_rating` and `fire_protection`
- `member_edge_group`: Which edge group — `:beams` or `:columns` (default `:beams`)
- `resolve`: Re-solve the model after adding loads (default `true`)

# Returns
Number of coating loads added.
"""
function add_coating_loads!(struc::BuildingStructure, params::DesignParameters;
                            member_edge_group::Symbol=:beams, resolve::Bool=true)
    fire_rating = params.fire_rating
    fire_rating <= 0 && return 0

    fp = params.fire_protection
    fp isa StructuralSizer.NoFireProtection && return 0

    skel = struc.skeleton
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[]))
    member_array = member_edge_group == :columns ? struc.columns :
                   member_edge_group == :struts ? struc.struts : struc.beams

    model = struc.asap_model
    g = 9.80665  # m/s²
    n_added = 0

    for m in member_array
        sec = m.base.section
        isnothing(sec) && continue
        !(sec isa StructuralSizer.ISymmSection) && continue

        # W/D calculation: choose perimeter based on exposure
        # Beams: 3-sided (PA), columns/struts: 4-sided (PB)
        perimeter = member_edge_group == :beams ? sec.PA : sec.PB
        perimeter_in = ustrip(u"inch", perimeter)

        mat = sec.material
        isnothing(mat) && continue
        W_plf = ustrip(u"lb/ft", StructuralSizer.weight_per_length(sec, mat))

        # Compute coating
        coating = StructuralSizer.compute_surface_coating(fp, fire_rating, W_plf, perimeter_in)
        coating.thickness_in <= 0 && continue

        # Weight per unit length: thickness(in) × perimeter(in) / 144 → ft² per ft × density (pcf) → lb/ft
        w_lbft = StructuralSizer.coating_weight_per_foot(coating, perimeter_in)
        w_Nm = w_lbft * 4.44822 / 0.3048  # lb/ft → N/m

        # Apply as downward (-Z) line load on each segment of this member
        for seg_idx in segment_indices(m)
            edge_idx = struc.segments[seg_idx].edge_idx
            edge_idx in edge_ids_in_group || continue
            el = model.elements[edge_idx]
            push!(model.loads, Asap.LineLoad(el, [0.0u"N/m", 0.0u"N/m", -w_Nm * u"N/m"]))
            n_added += 1
        end
    end

    if n_added > 0 && resolve
        Asap.process!(model)
        Asap.solve!(model)
    end

    n_added > 0 && @info "Added fire protection coating loads" n_loads=n_added group=member_edge_group fire_rating=fire_rating
    return n_added
end