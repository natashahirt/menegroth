"""
    to_asap!(struc)
Converts a BuildingStructure into an Asap.Model.
Hard SI boundary: all loads/coords sent to ASAP are plain Float64 in base SI.
"""
function to_asap!(struc::BuildingStructure{T, A, P}) where {T, A, P}
    skel = struc.skeleton
    
    # 1. nodes
    support_indices = get(skel.groups_vertices, :support, Int[])
    
    nodes = map(enumerate(skel.vertices)) do (v_idx, v)
        coords = Meshes.coords(v)
        x = ustrip(uconvert(u"m", coords.x))
        y = ustrip(uconvert(u"m", coords.y))
        z = ustrip(uconvert(u"m", coords.z))
        
        # ground level fixed, all else moment connected
        is_support = v_idx in support_indices
        dofs = is_support ? [false, false, false, false, false, false] : [true, true, true, false, false, false]
        return Asap.Node([x, y, z], dofs)
    end

    # 2. Elements
    default_section = AsapToolkit.toASAPframe("W10x22", unit=u"m")
    elements = map(skel.edge_indices) do (v1, v2)
        return Asap.Element(nodes[v1], nodes[v2], default_section, release=:fixedfixed)
    end
    
    # 3. loads
    loads = Asap.AbstractLoad[]
    # Temporarily set model so apply_effects! can find it
    struc.asap_model = Asap.Model(nodes, elements, loads)
    
    for slab in struc.slabs
        # 3. Slab-derived loads (gravity + effects) as unified edge specs
        #    Uses tributary area distribution by default
        for spec in slab_edge_load_specs(struc, slab)
            el = elements[spec.edge_idx]
            push_asap_loads!(loads, el, spec)
        end
    end

    model = struc.asap_model
    @debug "Converted to Asap.Model" nodes=length(nodes) elements=length(elements) loads=length(model.loads)

    Asap.process!(model)
    Asap.solve!(model)

    return model
end

# =============================================================================
# Slab → edge load interface
# =============================================================================

"""
    push_asap_loads!(loads, element, spec)

Convert a backend-agnostic edge load spec into ASAP loads.
Assumes `spec` magnitudes are base SI (N, N/m).
"""
function push_asap_loads!(loads::Vector{Asap.AbstractLoad}, el::Asap.Element, spec::AbstractEdgeLoadSpec)
    error("No ASAP conversion defined for $(typeof(spec))")
end

function push_asap_loads!(loads::Vector{Asap.AbstractLoad}, el::Asap.Element, spec::EdgePointLoadSpec)
    for (x, F) in zip(spec.xs, spec.F)
        # ASAP expects a *normalized* position in (0,1), not an absolute distance.
        # Also, it rejects exactly 0.0 and 1.0, so clamp slightly inward.
        x01 = clamp(Float64(x), eps(Float64), 1.0 - eps(Float64))
        push!(loads, Asap.PointLoad(el, x01, collect(F)))
    end
    return loads
end

function push_asap_loads!(loads::Vector{Asap.AbstractLoad}, el::Asap.Element, spec::EdgeLineLoadSpec)
    push!(loads, Asap.LineLoad(el, collect(spec.w)))
    return loads
end

"""
    slab_total_factored_force(struc, slab) -> (Fx, Fy, Fz) [N]

Compute the factored slab resultant in global coordinates (SI N).
Currently gravity-only: `(0, 0, -total_Fz)` using `total_factored_pressure(cell) * cell.area`.
"""
function slab_total_factored_force(struc::BuildingStructure, slab::Slab)
    total_Fz = 0.0
    for cell_idx in slab.cell_indices
        cell = struc.cells[cell_idx]
        p = ustrip(uconvert(u"N/m^2", total_factored_pressure(cell)))
        a = ustrip(uconvert(u"m^2", cell.area))
        total_Fz += p * a
    end
    return (0.0, 0.0, -total_Fz)
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

"""
    extract_cell_geometry(struc, cell_idx) -> CellGeometry

Extract polygon geometry from a cell for tributary area calculation.
Converts from skeleton/Meshes format to pure CellGeometry.
"""
function extract_cell_geometry(struc::BuildingStructure, cell_idx::Int)
    cell = struc.cells[cell_idx]
    skel = struc.skeleton
    face_idx = cell.face_idx
    
    # Get vertices from polygon
    polygon = skel.faces[face_idx]
    pts = Meshes.vertices(polygon)
    
    verts = NTuple{2, Float64}[]
    for p in pts
        c = Meshes.coords(p)
        x = Float64(ustrip(uconvert(u"m", c.x)))
        y = Float64(ustrip(uconvert(u"m", c.y)))
        push!(verts, (x, y))
    end
    
    # Get edge indices
    edge_ids = collect(skel.face_edge_indices[face_idx])
    
    return StructuralSizer.CellGeometry(verts, edge_ids; cell_idx=cell_idx, face_idx=face_idx)
end

"""
    cell_total_factored_force(struc, cell_idx) -> (Fx, Fy, Fz) [N]

Compute factored force for a single cell.
"""
function cell_total_factored_force(struc::BuildingStructure, cell_idx::Int)
    cell = struc.cells[cell_idx]
    p = ustrip(uconvert(u"N/m^2", total_factored_pressure(cell)))
    a = ustrip(uconvert(u"m^2", cell.area))
    return (0.0, 0.0, -p * a)
end

"""Internal helper: gravity point loads as `EdgePointLoadSpec`."""
function slab_edge_point_loads(
    struc::BuildingStructure,
    slab::Slab;
    use_tributary::Bool = true,
    weight_strategy::StructuralSizer.WeightStrategy = StructuralSizer.WEIGHT_UNIFORM,
    n_points::Int = 5,
    # Legacy options (ignored when use_tributary=true)
    xs::AbstractVector{<:Real} = [0.5],
    total_force::Union{Nothing, NTuple{3, Float64}} = nothing,
)::Vector{EdgePointLoadSpec}
    
    if use_tributary
        return _slab_edge_point_loads_tributary(struc, slab; 
            weight_strategy=weight_strategy, n_points=n_points)
    else
        return _slab_edge_point_loads_uniform(struc, slab; xs=xs, total_force=total_force)
    end
end

"""Tributary-based point load distribution (per-cell with edge merging)."""
function _slab_edge_point_loads_tributary(
    struc::BuildingStructure,
    slab::Slab;
    weight_strategy::StructuralSizer.WeightStrategy = StructuralSizer.WEIGHT_UNIFORM,
    n_points::Int = 5,
)::Vector{EdgePointLoadSpec}
    # Compute loads for each cell
    all_edge_loads = Vector{StructuralSizer.EdgeLoadResult}[]
    
    for cell_idx in slab.cell_indices
        geom = extract_cell_geometry(struc, cell_idx)
        force = cell_total_factored_force(struc, cell_idx)
        
        # Compute tributary loads for this cell
        cell_loads = StructuralSizer.distribute_cell_loads(
            geom, force;
            strategy=weight_strategy,
            n_points=n_points
        )
        push!(all_edge_loads, cell_loads)
    end
    
    # Merge loads from multiple cells (internal edges get contributions from both sides)
    merged = StructuralSizer.merge_edge_loads(all_edge_loads)
    
    # Convert to EdgePointLoadSpec
    return [
        EdgePointLoadSpec(load.edge_idx, load.xs, load.forces)
        for load in merged
    ]
end

"""Legacy uniform distribution (for backward compatibility)."""
function _slab_edge_point_loads_uniform(
    struc::BuildingStructure,
    slab::Slab;
    xs::AbstractVector{<:Real} = [0.5],
    total_force::Union{Nothing, NTuple{3, Float64}} = nothing,
)::Vector{EdgePointLoadSpec}
    edge_ids = slab_face_edge_ids(struc, slab)
    n_edges = length(edge_ids)
    n_edges > 0 || return EdgePointLoadSpec[]

    xs_vec = Float64.(xs)
    n_pts = length(xs_vec)
    n_pts > 0 || return EdgePointLoadSpec[]

    Fx, Fy, Fz = isnothing(total_force) ? slab_total_factored_force(struc, slab) : total_force
    scale = 1.0 / n_edges
    f_per_edge = (Fx * scale, Fy * scale, Fz * scale)

    return [
        EdgePointLoadSpec(Int(e), xs_vec, fill(f_per_edge, n_pts))
        for e in edge_ids
    ]
end

"""Internal helper: structural effects as `EdgeLineLoadSpec` (e.g. vault thrust)."""
function slab_edge_line_loads(struc::BuildingStructure, slab::Slab)::Vector{EdgeLineLoadSpec}
    effects = StructuralSizer.structural_effects(slab.result)
    isempty(effects) && return EdgeLineLoadSpec[]

    loads = EdgeLineLoadSpec[]

    for eff in effects
        if eff isa StructuralSizer.LateralThrust
            append!(loads, vault_thrust_line_loads(struc, slab, eff))
        end
    end

    return loads
end

"""
    slab_edge_load_specs(struc, slab; use_tributary=true, weight_strategy=WEIGHT_UNIFORM, n_points=5)

Unified slab load API: returns a single list of edge load specs (point + line).

# Keyword Arguments
- `use_tributary::Bool`: If true, use grassfire/tributary area distribution (default)
- `weight_strategy::WeightStrategy`: Edge weight strategy for tributary calculation
- `n_points::Int`: Number of point loads per edge
"""
function slab_edge_load_specs(
    struc::BuildingStructure,
    slab::Slab;
    use_tributary::Bool = true,
    weight_strategy::StructuralSizer.WeightStrategy = StructuralSizer.WEIGHT_UNIFORM,
    n_points::Int = 5,
)::Vector{AbstractEdgeLoadSpec}
    specs = AbstractEdgeLoadSpec[]
    append!(specs, slab_edge_point_loads(struc, slab; 
        use_tributary=use_tributary, 
        weight_strategy=weight_strategy, 
        n_points=n_points))
    append!(specs, slab_edge_line_loads(struc, slab))
    return specs
end

# --- Vault thrust → edge line loads (simple implementation) ---
function vault_thrust_line_loads(struc::BuildingStructure, slab::Slab, eff::StructuralSizer.LateralThrust)::Vector{EdgeLineLoadSpec}
    # Factored thrust (consistent with other factored load usage in the model)
    thrust_factored = eff.dead * Constants.DL_FACTOR + eff.live * Constants.LL_FACTOR
    mag_N_m = ustrip(u"N/m", uconvert(u"N/m", thrust_factored))

    # Span axis (default to X)
    span_vec = isnothing(slab.span_axis) ? [1.0, 0.0, 0.0] : collect(slab.span_axis)

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