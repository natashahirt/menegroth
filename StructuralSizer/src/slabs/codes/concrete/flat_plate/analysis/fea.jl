# =============================================================================
# Finite Element Analysis (FEA) — Shell Model for Flat Plate Moment Analysis
# =============================================================================
#
# 2D shell model with column stub frame elements for flat plate moment analysis.
#
# Architecture:
#   1. Triangulated shell elements (Asap.Shell auto-mesher)
#   2. ShellPatch at each column — mesh conforms to column perimeters,
#      elements inside the patch receive 100× slab stiffness
#   3. Column stub Elements from a fixed base (z = −Lc/2, representing the
#      column inflection point) to the slab center node (z = 0).  Section
#      properties are doubled (2A, 2I) to model the combined stiffness of
#      upper + lower column halves.
#   4. Factored area load on the shell elements
#
# This replaces the old spring-based approach:
#   - Springs required ad-hoc kz/krx/kry formulas and uniform patch
#     distribution, leading to extreme stiffness ratios and "stiffness
#     matrix not positive definite" warnings.
#   - Column stubs naturally provide axial stiffness (EA/L), bending
#     stiffness (4EI/L), and moment-shear coupling through standard
#     frame element mechanics — no hand-tuned stiffness formulas.
#
# Caching strategy:
#   - FEAModelCache persists mesh topology between design iterations.
#     Only thickness, stiffness, and load magnitude are updated.
#   - Per-element precomputed data (centroid, area, LCS, bending moments)
#     is rebuilt once after each solve.
#
# Reference: ACI 318-11 §13.2.1
# =============================================================================

using Logging
using Asap
using Meshes: coords

# =============================================================================
# FEA Model Cache
# =============================================================================

"""Per-element precomputed data: extracted once after each solve."""
mutable struct FEAElementData
    cx::Float64;  cy::Float64      # centroid (m)
    area::Float64                  # m²
    Mxx::Float64; Myy::Float64; Mxy::Float64  # bending moments (N·m/m)
    ex::NTuple{2,Float64}         # local x̂ projected to 2D
    ey::NTuple{2,Float64}         # local ŷ projected to 2D
end

# Column stub data for FEA cache: element + connection nodes.
const ColStubData = NamedTuple{(:element, :base_node, :slab_node)}

"""
    FEAModelCache

Persistent cache for a slab's FEA mesh.  Stored in
`struc._analysis_caches[slab_idx][:fea]`.

- On **first call**: `_build_fea_slab_model` creates the mesh + column stubs;
  the cache stores the model, stub data, and topology.
- On **subsequent calls**: `_update_and_resolve!` updates section props,
  column stub sections, and load, then re-processes and re-solves.
- After each solve: `_precompute_element_data!` fills `element_data`
  and `cell_tri_indices` for O(1) strip integration.
"""
mutable struct FEAModelCache
    initialized::Bool

    # Asap model + column stubs (persistent across iterations)
    model::Union{Nothing, Asap.Model}
    col_stubs::Dict{Int, ColStubData}   # i => (element, base_node, slab_node)
    shells::Union{Nothing, Vector{<:Asap.ShellElement}}  # shell elements from mesher

    # Per-element precomputed data (rebuilt after each solve)
    element_data::Vector{FEAElementData}
    cell_tri_indices::Dict{Int, Vector{Int}}   # cell_idx → indices into element_data

    # Cell geometry cache (mesh-invariant — polygon, centroid, bbox)
    cell_geometries::Dict{Int, NamedTuple}

    FEAModelCache() = new(
        false, nothing, Dict{Int,ColStubData}(), nothing,
        FEAElementData[], Dict{Int,Vector{Int}}(),
        Dict{Int,NamedTuple}()
    )
end

# =============================================================================
# Slab Boundary Extraction
# =============================================================================

"""
    _get_slab_face_boundary(struc, slab) -> (boundary_vis, all_vis, interior_edge_vis)

Ordered boundary vertex indices, all vertex indices, and interior cell-edge
vertex pairs for a slab.

Single-cell slabs: boundary = face polygon, interior edges = empty.
Multi-cell slabs: boundary edges (count=1) chained into polygon; interior
edges (count≥2) returned as vertex pairs.
"""
function _get_slab_face_boundary(struc, slab)
    skel = struc.skeleton

    if length(slab.cell_indices) == 1
        face_idx = struc.cells[first(slab.cell_indices)].face_idx
        boundary = collect(skel.face_vertex_indices[face_idx])
        return (boundary, Set(boundary), Tuple{Int,Int}[])
    end

    # Count how many slab cells reference each skeleton edge
    edge_count = Dict{Int, Int}()
    all_verts = Set{Int}()

    for ci in slab.cell_indices
        face_idx = struc.cells[ci].face_idx
        union!(all_verts, skel.face_vertex_indices[face_idx])
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

    # Ensure CCW (Delaunay triangulator requires positive orientation)
    _ensure_ccw_vis!(boundary, skel)

    return (boundary, all_verts, interior_edge_vis)
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

# =============================================================================
# Column Stub Section
# =============================================================================

"""
    _column_stub_section(col, Ec, ν_concrete; I_factor=0.70) -> Section

Build an Asap.Section for a column stub.  Properties are doubled to
represent the combined stiffness of upper + lower column halves
(each modeled as fixed-fixed, height Lc/2).

`I_factor` reduces the gross moment of inertia for cracking per
ACI 318-11 §10.10.4.1 (default 0.70 for columns).  Area is kept
at gross (cracking reduces flexural stiffness, not axial area).

For circular columns (col.shape == :circular), uses circular section
properties: A = πD²/4, I = πD⁴/64, J = πD⁴/32.
"""
function _column_stub_section(col, Ec::Pressure, ν_concrete::Float64;
                               I_factor::Float64 = 0.70)
    cshape = col_shape(col)
    c1 = col.c1
    c2 = col.c2

    if cshape == :circular
        D = c1   # c1 = c2 = diameter for circular
        A  = 2 * π * D^2 / 4
        Ix = 2 * I_factor * π * D^4 / 64
        Iy = Ix
    else
        A  = 2 * c1 * c2
        Ix = 2 * I_factor * c1 * c2^3 / 12
        Iy = 2 * I_factor * c2 * c1^3 / 12
    end

    J = Ix + Iy
    G = Ec / (2 * (1 + ν_concrete))
    return Asap.Section(A, Ec, G, Ix, Iy, J)
end


# =============================================================================
# Skeleton Vertex → (x, y) Cache
# =============================================================================

"""
    _vertex_xy_m(skel, vi) -> NTuple{2,Float64}

XY position of a skeleton vertex in meters.
"""
function _vertex_xy_m(skel, vi::Int)
    vc = skel.geometry.vertex_coords
    return (vc[vi, 1], vc[vi, 2])
end

# =============================================================================
# FEA Model Builder
# =============================================================================

"""
    _build_fea_slab_model(struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
                          target_edge=nothing, verbose=false)

Build a standalone Asap mixed model (shell + frame) with column stubs
and ShellPatch mesh conformity at each column.

`target_edge = nothing` (default) → adaptive mesh scaled to the smallest cell's
short span (from `SpanInfo.primary`): `clamp(min_span/20, 0.15, 0.75) m`, giving
~20 elements per span direction.  An explicit length overrides this.

Returns `(model, col_stubs, shells)`.
"""
function _build_fea_slab_model(
    struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
    target_edge::Union{Nothing, Length} = nothing,
    verbose::Bool = false,
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    col_I_factor::Float64 = 0.70,
)
    skel = struc.skeleton

    # ─── 1. Slab boundary + interior cell edges ───
    boundary_vis, all_vis, interior_edge_vis = _get_slab_face_boundary(struc, slab)

    # ─── 1b. Adaptive mesh resolution ───
    # ~20 elements per shortest cell span, clamped to [0.15 m, 0.75 m].
    # Uses SpanInfo.primary already on each Cell.  Divisor of 20 (vs 25)
    # trades a tiny bit of accuracy for robustness on irregular geometries.
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

    # ─── 3. Column stubs + ShellPatches ───
    stub_height = Lc / 2
    col_stubs = Dict{Int, Any}()
    frame_elements = Asap.FrameElement[]
    base_nodes = Asap.Node[]
    patches = Asap.ShellPatch[]

    # Shell section for patch (same E as slab — mesh conformity only)
    # Stiffness multipliers (10×, 100×) cause severe ill-conditioning
    # on irregular/extreme-AR geometries.  The column stubs already
    # provide the correct support stiffness via frame element mechanics.
    patch_section = Asap.ShellSection(
        uconvert(u"m", h),
        uconvert(u"Pa", Ecs),
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
        xy = _vertex_xy_m(skel, vi)

        # Base node below slab (fixed = inflection point at mid-story)
        base = Asap.Node([xy[1] * u"m", xy[2] * u"m", -stub_height], :fixed)
        push!(base_nodes, base)

        # Column stub (doubled section → combined upper + lower stiffness)
        sec = _column_stub_section(col, Ecs, ν_concrete; I_factor=col_I_factor)
        elem = Asap.Element(base, slab_node, sec, :col_stub)
        push!(frame_elements, elem)

        col_stubs[i] = (element=elem, base_node=base, slab_node=slab_node)

        # ShellPatch for mesh conformity + stiffened region.
        # Circular columns use an equivalent-area square patch (side = D√(π/4))
        # rather than an octagon.  The Ruppert mesh refinement in Asap crashes
        # on the short polygon segments an octagon would introduce, and the
        # actual circular column physics are captured by the stub section
        # properties (πD²/4, πD⁴/64) and the face offset (D/2), not the
        # patch shape.
        cshape = col_shape(col)
        if cshape == :circular
            D_m = ustrip(u"m", col.c1)
            eq_side = D_m * sqrt(π / 4)   # same area as circle
            patch = Asap.ShellPatch(xy[1], xy[2], eq_side, eq_side,
                                    patch_section; id=:col_patch)
        else
            c1_m = ustrip(u"m", col.c1)
            c2_m = ustrip(u"m", col.c2)
            patch = Asap.ShellPatch(xy[1], xy[2], c1_m, c2_m,
                                    patch_section; id=:col_patch)
        end
        push!(patches, patch)

        if verbose
            shape_str = cshape == :circular ? "circular" : "rectangular"
            c1_mm = round(ustrip(u"m", col.c1)*1000, digits=0)
            c2_mm = round(ustrip(u"m", col.c2)*1000, digits=0)
            @debug "  Col $i stub ($shape_str): Lc/2=$(round(ustrip(u"m", stub_height), digits=3))m, " *
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
        w_drop = 2 * a1_m  # full extent in direction 1
        h_drop_m = 2 * a2_m  # full extent in direction 2
        
        for (i, col) in enumerate(columns)
            vi = col.vertex_idx
            haskey(node_map, vi) || continue
            xy = _vertex_xy_m(skel, vi)
            
            # Drop panel patch centered on column, larger than column patch
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

    # Pin in-plane DOFs (u,v) at boundary.  The slab FEA is gravity-only
    # (out-of-plane loading), so in-plane displacements are identically zero.
    # Leaving them :free creates a near-singular in-plane block that causes
    # SPD failures on irregular geometries.  Pinning u,v removes the trivial
    # mechanism without affecting bending moments or column forces.
    #   DOF order: [u, v, w, θx, θy, θz]  →  false = fixed, true = free
    edge_dofs = [false, false, true, true, true, true]

    # Local mesh refinement around column patches / interior nodes.
    # Uses Ruppert's algorithm (DT.refine!) which inserts Steiner points at
    # circumcenters, guaranteeing minimum angle ≥ 30° and respecting
    # constrained patch edges.  Half the smallest column dimension ensures
    # ≥2 elements across each column face.
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
    all_nodes = vcat(collect(values(node_map)), base_nodes)
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
    _update_and_resolve!(cache, h, Ecs, ν_concrete, qu, columns, Lc)

Update an existing FEA model's shell properties, column stub sections,
and load, then re-process and re-solve without re-triangulating.
"""
function _update_and_resolve!(
    cache::FEAModelCache, h, Ecs, ν_concrete, qu, columns, Lc;
    verbose::Bool = false,
    col_I_factor::Float64 = 0.70,
)
    model = cache.model
    t_m = ustrip(u"m", h)
    E_Pa = ustrip(u"Pa", Ecs)

    # 1. Update shell element section properties (patch elements get 100× E)
    for elem in model.shell_elements
        elem.thickness = t_m
        elem.E = E_Pa
        elem.ν = ν_concrete
    end

    # 2. Update load magnitude (geometry unchanged — no need to rebuild tributaries)
    for load in model.loads
        if load isa Asap.AreaLoad
            load.pressure = uconvert(u"Pa", qu)
        end
    end

    # 3. Update column stub sections (column sizes may have changed)
    for (i, col) in enumerate(columns)
        haskey(cache.col_stubs, i) || continue
        cache.col_stubs[i].element.section = _column_stub_section(col, Ecs, ν_concrete; I_factor=col_I_factor)
    end

    # 4. Values-only update: geometry/topology unchanged, only h/E/ν/qu changed
    Asap.update!(model; values_only=true)
    Asap.solve!(model)

    if verbose
        @debug "FEA MODEL UPDATED (reused mesh)" begin
            "shells=$(length(model.shell_elements)) h=$(round(t_m*1000, digits=0))mm " *
            "E=$(round(E_Pa/1e6, digits=0))MPa"
        end
    end
end

# =============================================================================
# Per-Element Precompute (runs once after each solve)
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

    # Geometry (centroid, area, LCS) is mesh-invariant; only moments change.
    first_pass = isempty(cache.element_data)

    # Thread-local workspace for zero-alloc bending_moments!
    ws = Asap.ShellMomentWorkspace()
    M_buf = zeros(3)

    if first_pass
        resize!(cache.element_data, n)
        @inbounds for k in 1:n
            tri = shell_vec[k]
            tri isa Asap.ShellTri3 || continue
            Asap.bending_moments!(M_buf, tri, model.u, ws)
            tc = Asap.shell_centroid(tri)
            cache.element_data[k] = FEAElementData(
                tc.x, tc.y, tri.area,
                M_buf[1], M_buf[2], M_buf[3],
                (tri.LCS[1][1], tri.LCS[1][2]),
                (tri.LCS[2][1], tri.LCS[2][2]),
            )
        end

        # Cell → triangle index mapping (mesh-invariant)
        empty!(cache.cell_tri_indices)
        for ci in slab.cell_indices
            geom = _cell_geometry_m(struc, ci; _cache=cache.cell_geometries)
            indices = Int[]
            for k in 1:n
                ed = cache.element_data[k]
                Asap._point_in_polygon((ed.cx, ed.cy), geom.poly) && push!(indices, k)
            end
            cache.cell_tri_indices[ci] = indices
        end
    else
        # ── Moments-only update: geometry unchanged, just overwrite Mxx/Myy/Mxy ──
        @inbounds for k in 1:n
            tri = shell_vec[k]
            tri isa Asap.ShellTri3 || continue
            Asap.bending_moments!(M_buf, tri, model.u, ws)
            ed = cache.element_data[k]
            ed.Mxx = M_buf[1]
            ed.Myy = M_buf[2]
            ed.Mxy = M_buf[3]
        end
    end
end

# =============================================================================
# Build-or-Update Entry Point
# =============================================================================

"""
    _build_or_update_fea!(cache, struc, slab, columns, h, Ecs, ν, qu, Lc;
                          target_edge, verbose)

If `cache` is uninitialized, build a fresh model.  Otherwise update
section/load/stubs on the existing mesh and re-solve.
Either way, precomputes per-element data afterward.
"""
function _build_or_update_fea!(
    cache::FEAModelCache, struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
    target_edge::Union{Nothing, Length} = nothing,
    verbose::Bool = false,
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    col_I_factor::Float64 = 0.70,
)
    if !cache.initialized
        fea = _build_fea_slab_model(
            struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
            target_edge=target_edge, verbose=verbose, drop_panel=drop_panel,
            col_I_factor=col_I_factor,
        )
        cache.model      = fea.model
        cache.col_stubs  = fea.col_stubs
        cache.shells     = fea.shells
        cache.initialized = true
    else
        _update_and_resolve!(cache, h, Ecs, ν_concrete, qu, columns, Lc;
                             verbose=verbose, col_I_factor=col_I_factor)
    end

    _precompute_element_data!(cache, cache.model, struc, slab)
    return cache
end

# =============================================================================
# Force Extraction from Column Stubs
# =============================================================================

"""
    _extract_stub_forces(stub) -> (Fz, Mx, My)

Extract column forces from a column stub element.  Returns Unitful (N, N·m).

Forces are read from the element's LCS at nodeEnd (slab connection,
indices 7-12) and transformed to GCS using the element's local
coordinate system axes.
"""
function _extract_stub_forces(stub)
    elem = stub.element
    X = elem.LCS[1]   # element X axis in GCS
    y = elem.LCS[2]   # element y axis in GCS
    z = elem.LCS[3]   # element z axis in GCS

    # LCS forces at nodeEnd (slab connection)
    P    = elem.forces[7]    # axial
    Vy   = elem.forces[8]    # shear along y
    Vz   = elem.forces[9]    # shear along z
    T    = elem.forces[10]   # torsion about X
    My_l = elem.forces[11]   # bending about y
    Mz_l = elem.forces[12]   # bending about z

    # Transform to GCS
    Fz   = (P * X[3] + Vy * y[3] + Vz * z[3]) * u"N"
    Mx_g = (T * X[1] + My_l * y[1] + Mz_l * z[1]) * u"N*m"
    My_g = (T * X[2] + My_l * y[2] + Mz_l * z[2]) * u"N*m"

    return (Fz=Fz, Mx=Mx_g, My=My_g)
end

"""
    _extract_fea_column_forces(col_stubs, span_axis, n_cols)

Extract Vu, Mu, Mub from solved column stubs.  Returns Unitful vectors.
"""
function _extract_fea_column_forces(col_stubs, span_axis::NTuple{2, Float64}, n_cols::Int)
    ax_len = hypot(span_axis...)
    ax = ax_len > 1e-9 ? (span_axis[1] / ax_len, span_axis[2] / ax_len) : (1.0, 0.0)

    ForceT  = typeof(1.0kip)
    MomentT = typeof(1.0kip * u"ft")
    Vu  = Vector{ForceT}(undef, n_cols)
    Mu  = Vector{MomentT}(undef, n_cols)
    Mub = Vector{MomentT}(undef, n_cols)
    Mx  = Vector{MomentT}(undef, n_cols)
    My  = Vector{MomentT}(undef, n_cols)

    for i in 1:n_cols
        f = _extract_stub_forces(col_stubs[i])
        Vu[i]  = uconvert(kip, abs(f.Fz))
        Mu[i]  = uconvert(kip * u"ft", hypot(f.Mx, f.My))
        Mub[i] = uconvert(kip * u"ft", abs(ax[1] * f.My - ax[2] * f.Mx))
        Mx[i]  = uconvert(kip * u"ft", f.Mx)
        My[i]  = uconvert(kip * u"ft", f.My)
    end

    return (Vu=Vu, Mu=Mu, Mub=Mub, Mx=Mx, My=My)
end

# =============================================================================
# Cell Geometry Helpers
# =============================================================================

"""
    _cell_geometry_m(struc, cell_idx) -> (poly, centroid)

Polygon vertices and centroid of a cell, both in meters (bare Float64).
Reads directly from skeleton face data — no redundant lookups.
"""
function _cell_geometry_m(struc, cell_idx::Int; _cache::Union{Nothing, Dict} = nothing)
    if !isnothing(_cache)
        cached = get(_cache, cell_idx, nothing)
        !isnothing(cached) && return cached
    end

    skel = struc.skeleton
    cell = struc.cells[cell_idx]
    vis = skel.face_vertex_indices[cell.face_idx]
    poly = NTuple{2,Float64}[_vertex_xy_m(skel, vi) for vi in vis]

    face = skel.faces[cell.face_idx]
    c = coords(Meshes.centroid(face))
    centroid = (Float64(ustrip(u"m", c.x)), Float64(ustrip(u"m", c.y)))

    result = (poly=poly, centroid=centroid)
    !isnothing(_cache) && (_cache[cell_idx] = result)
    return result
end

"""
    _build_cell_to_columns(columns) -> Dict{Int, Vector}

Invert column.tributary_cell_indices into a cell_idx → columns mapping.
O(n_cols) construction, O(1) lookup per cell — replaces O(n_cols) scan per cell.
"""
function _build_cell_to_columns(columns)
    cell_to_cols = Dict{Int, Vector{eltype(columns)}}()
    for col in columns
        for ci in col.tributary_cell_indices
            push!(get!(cell_to_cols, ci, eltype(columns)[]), col)
        end
    end
    return cell_to_cols
end

# =============================================================================
# Column Face Geometry
# =============================================================================

"""
    _column_face_offset_m(col, d::NTuple{2,Float64}) -> Float64

Distance (meters) from column center to column face in direction `d`.

For circular columns, the offset is simply D/2 (isotropic).
For rectangular columns, projects onto the bounding box.
"""
function _column_face_offset_m(col, d::NTuple{2,Float64})
    cshape = col_shape(col)
    if cshape == :circular
        return ustrip(u"m", col.c1) / 2   # D/2 in any direction
    end
    c1_m = ustrip(u"m", col.c1)
    c2_m = ustrip(u"m", col.c2)
    tx = abs(d[1]) > 1e-9 ? c1_m / (2 * abs(d[1])) : Inf
    ty = abs(d[2]) > 1e-9 ? c2_m / (2 * abs(d[2])) : Inf
    return min(tx, ty)
end

# =============================================================================
# Cell-Polygon Strip Moment Extraction
# =============================================================================

"""
    _integrate_at(element_data, tri_indices, pos, ax, δ) -> Float64

Integrate span-direction moment across a δ-band at `pos` using
precomputed per-element data.  Returns bare N·m.

Mohr's circle projects global span axis `ax` into each element's local
frame via the cached LCS axes.
"""
function _integrate_at(
    element_data::Vector{FEAElementData},
    tri_indices::Vector{Int},
    pos::NTuple{2,Float64},
    ax::NTuple{2,Float64},
    δ::Float64,
)
    s_eval = ax[1] * pos[1] + ax[2] * pos[2]
    half_δ = δ / 2
    Mn_A = 0.0   # N·m·m accumulator
    @inbounds for k in tri_indices
        ed = element_data[k]
        abs(ax[1] * ed.cx + ax[2] * ed.cy - s_eval) > half_δ && continue
        axl = (ax[1]*ed.ex[1] + ax[2]*ed.ex[2], ax[1]*ed.ey[1] + ax[2]*ed.ey[2])
        Mn = ed.Mxx*axl[1]^2 + ed.Myy*axl[2]^2 + 2*ed.Mxy*axl[1]*axl[2]
        Mn_A += Mn * ed.area
    end
    return Mn_A / δ
end

"""
    _extract_cell_strip_moments(cache, skel, ci, cell_centroid, cell_cols,
                                span_axis; verbose=false)

Extract M⁻ (column faces) and M⁺ (cell centroid) for one cell using
precomputed element data from `cache`.

Strip width δ: `max(c_avg, √(Lx·Ly)/20, 0.25m)`.
"""
function _extract_cell_strip_moments(
    cache::FEAModelCache,
    skel,
    ci::Int,
    cell_poly::Vector{NTuple{2,Float64}},
    cell_centroid::NTuple{2,Float64},
    cell_cols::Vector,
    span_axis::NTuple{2,Float64};
    verbose::Bool = false
)
    # Inline extrema — avoids allocating xs/ys arrays
    x_lo, x_hi = Inf, -Inf
    y_lo, y_hi = Inf, -Inf
    @inbounds for v in cell_poly
        vx, vy = v[1], v[2]
        vx < x_lo && (x_lo = vx)
        vx > x_hi && (x_hi = vx)
        vy < y_lo && (y_lo = vy)
        vy > y_hi && (y_hi = vy)
    end
    cx, cy = cell_centroid

    Lx = x_hi - x_lo
    Ly = y_hi - y_lo
    L_char = sqrt(max(Lx * Ly, 1e-6))
    c_avg_m = isempty(cell_cols) ? 0.3 :
        sum(max(ustrip(u"m", c.c1), ustrip(u"m", c.c2)) for c in cell_cols) / length(cell_cols)
    δ = max(c_avg_m, L_char / 20, 0.25)

    tri_idx = get(cache.cell_tri_indices, ci, Int[])

    # Column negative moments (M⁻) at column face
    col_Mneg = Vector{Float64}(undef, length(cell_cols))
    for (col_i, col) in enumerate(cell_cols)
        px, py = _vertex_xy_m(skel, col.vertex_idx)
        off = _column_face_offset_m(col, span_axis)
        face = (px + off * span_axis[1], py + off * span_axis[2])
        Mn = max(0.0, _integrate_at(cache.element_data, tri_idx, face, span_axis, δ))
        col_Mneg[col_i] = Mn

        verbose && @debug "  Col $(col.vertex_idx) ($(col.position)): " *
                          "M⁻=$(round(Mn, digits=0)) N·m  (δ=$(round(δ*1000, digits=0))mm)"
    end

    # Cell positive moment (M⁺) at centroid
    M_pos = max(0.0, -_integrate_at(cache.element_data, tri_idx, cell_centroid, span_axis, δ))

    if verbose
        @debug "  Cell x=[$(round(x_lo,digits=2)),$(round(x_hi,digits=2))] " *
               "y=[$(round(y_lo,digits=2)),$(round(y_hi,digits=2))]  δ=$(round(δ*1000,digits=0))mm" begin
            "Centroid: ($(round(cx,digits=3)), $(round(cy,digits=3)))  " *
            "M⁺=$(round(M_pos,digits=1)) N·m  n_tris=$(length(tri_idx))"
        end
    end

    return (col_Mneg=col_Mneg, M_pos=M_pos, δ=δ)
end

"""
    _extract_cell_moments(cache, struc, slab, columns, span_axis; verbose)

Per-cell strip integration across all cells using precomputed data
from `cache`.  Returns per-column M⁻ envelope and global M⁺ (Unitful N·m).
"""
function _extract_cell_moments(
    cache::FEAModelCache,
    struc, slab, columns,
    span_axis::NTuple{2,Float64};
    verbose::Bool = false
)
    skel = struc.skeleton
    n_cols = length(columns)
    n_cells = length(slab.cell_indices)

    if verbose
        @debug "SPAN-DIRECTION STRIP INTEGRATION: $n_cells cells, $n_cols columns  " *
               "span_axis=$(round.(span_axis, digits=3))"
    end

    col_by_vertex = Dict{Int, Int}(col.vertex_idx => i for (i, col) in enumerate(columns))
    cell_to_cols  = _build_cell_to_columns(columns)

    env_M_pos = 0.0
    col_Mneg = zeros(Float64, n_cols)

    for ci in slab.cell_indices
        cell_cols = get(cell_to_cols, ci, eltype(columns)[])
        isempty(cell_cols) && continue

        geom = _cell_geometry_m(struc, ci; _cache=cache.cell_geometries)

        r = _extract_cell_strip_moments(
            cache, skel, ci, geom.poly, geom.centroid, cell_cols,
            span_axis; verbose=verbose
        )

        env_M_pos = max(env_M_pos, r.M_pos)

        for (j, col) in enumerate(cell_cols)
            idx = get(col_by_vertex, col.vertex_idx, nothing)
            idx === nothing && continue
            col_Mneg[idx] = max(col_Mneg[idx], r.col_Mneg[j])
        end
    end

    if verbose
        @debug "PER-COLUMN ENVELOPE ($n_cells cells)" begin
            lines = ["M⁺=$(round(env_M_pos,digits=1)) N·m"]
            for (i, col) in enumerate(columns)
                push!(lines, "  Col $i ($(col.position)): M⁻=$(round(col_Mneg[i],digits=1)) N·m")
            end
            join(lines, "\n")
        end
    end

    return (
        col_Mneg = col_Mneg,
        M_pos    = env_M_pos * u"N*m",
        n_cells  = n_cells,
    )
end

# =============================================================================
# FEA Moment Analysis (Main Entry Point)
# =============================================================================

"""
    run_moment_analysis(method::FEA, struc, slab, columns, h, fc, Ecs, γ_concrete;
                        ν_concrete, verbose, cache)

Run moment analysis using 2D shell FEA with column stub frame elements.

If `cache::FEAModelCache` is provided, the mesh is reused between
iterations (only section + load + stubs are updated).  Per-element
data (moments, centroids, LCS) is precomputed once per solve.

Returns `MomentAnalysisResult` with `secondary = nothing`.
"""
function run_moment_analysis(
    method::FEA,
    struc,
    slab,
    supporting_columns,
    h::Length,
    fc::Pressure,
    Ecs::Pressure,
    γ_concrete;
    ν_concrete::Float64 = 0.20,
    verbose::Bool = false,
    cache::Union{Nothing, FEAModelCache} = nothing,
    efm_cache = nothing,  # API parity (unused by FEA)
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    βt::Float64 = 0.0,  # API parity (unused by FEA — torsion in shell model)
    col_I_factor::Float64 = 0.70,  # ACI 318-11 §10.10.4.1
)
    setup = _moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0) = setup
    n_cols = length(supporting_columns)
    Lc = _get_column_height(supporting_columns)

    if verbose
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "MOMENT ANALYSIS — FEA (Column Stubs + ShellPatch)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Geometry" l1=l1 l2=l2 ln=ln c_avg=c1_avg h=h target_edge=method.target_edge
        @debug "Loads" qD=qD qL=qL qu=qu
        @debug "Reference M₀" M0=uconvert(kip * u"ft", M0)
    end

    # Build (or update) FEA model + precompute element data
    if isnothing(cache)
        cache = FEAModelCache()
    end
    _build_or_update_fea!(
        cache, struc, slab, supporting_columns, h, Ecs, ν_concrete, qu, Lc;
        target_edge=method.target_edge, verbose=verbose, drop_panel=drop_panel,
        col_I_factor=col_I_factor,
    )
    model = cache.model

    # Column forces from stubs (all Unitful)
    forces = _extract_fea_column_forces(cache.col_stubs, span_axis, n_cols)

    # ── Direct FE equilibrium: Σ(reactions_z) + Σ(P_z) ≈ 0 ──
    # Uses only solved model quantities — no indirect qu×A comparison.
    all_z_gids  = [n.globalID[3] for n in model.nodes]
    total_Pz    = sum(model.P[gid] for gid in all_z_gids)           # N (negative = downward)
    total_Rz_fe = sum(model.reactions[gid] for gid in all_z_gids)   # N (positive = upward at fixed; 0 at free)
    fe_residual = total_Pz + total_Rz_fe                            # should be ≈ 0

    fe_equil_err = abs(fe_residual) / max(abs(total_Pz), 1e-6) * 100

    # Diagnostic: compare AreaLoad effective area vs element_data area
    A_mesh_from_P = abs(total_Pz) / ustrip(u"Pa", qu)              # m²
    A_elem_data   = sum(ed.area for ed in cache.element_data)       # m²
    area_mismatch = abs(A_mesh_from_P - A_elem_data) / max(A_elem_data, 1e-6) * 100

    Rz_kN  = round(total_Rz_fe / 1e3, digits=2)
    Pz_kN  = round(total_Pz / 1e3, digits=2)
    res_kN = round(fe_residual / 1e3, digits=4)
    @debug "EQUILIBRIUM (direct FE)" ΣRz_kN=Rz_kN ΣPz_kN=Pz_kN residual_kN=res_kN FE_err_pct=round(fe_equil_err, digits=4) A_from_P_m²=round(A_mesh_from_P, digits=3) A_elem_m²=round(A_elem_data, digits=3) area_Δ_pct=round(area_mismatch, digits=2)
    # Soft warn at 1 %, hard error at 5 %
    if fe_equil_err > 5.0
        error("FEA equilibrium error $(round(fe_equil_err, digits=2))% exceeds 5 % — results unreliable. Check mesh / BCs.")
    elseif fe_equil_err > 1.0
        @warn "FEA direct equilibrium error $(round(fe_equil_err, digits=2))%"
    end
    # Soft warn at 5 %, hard error at 10 %
    if area_mismatch > 10.0
        error("Mesh area mismatch $(round(area_mismatch, digits=1))% exceeds 10 % — mesh integrity compromised.")
    elseif area_mismatch > 5.0
        @warn "Mesh area mismatch $(round(area_mismatch, digits=1))%: " *
              "AreaLoad=$(round(A_mesh_from_P, digits=3))m² vs elem_data=$(round(A_elem_data, digits=3))m²"
    end

    # Cell-polygon strip integration using precomputed data
    envelope = _extract_cell_moments(
        cache, struc, slab, supporting_columns,
        span_axis; verbose=verbose
    )

    column_moments = [uconvert(kip * u"ft", m * u"N*m") for m in envelope.col_Mneg]

    neg_env = _envelope_from_columns(column_moments, supporting_columns)
    M_neg_ext = neg_env.M_neg_ext
    M_neg_int = neg_env.M_neg_int
    M_pos     = uconvert(kip * u"ft", envelope.M_pos)

    # Max panel deflection from FEA nodal displacements (slab-level nodes only)
    fea_Δ_panel = abs(minimum(
        n.displacement[3] for n in model.nodes
        if ustrip(u"m", n.position[3]) > -0.01  # skip base nodes below slab
    ))

    if verbose
        @debug "FEA MAX DISPLACEMENT" Δ_panel=uconvert(u"inch", fea_Δ_panel)
    end

    # ─── Pattern loading amplification (ACI 318-11 §13.7.6) ───
    # When L/D > 0.75, compute EFM-derived amplification factors for the
    # pattern loading moment redistribution and apply them to the FEA
    # baseline.  FEA provides accurate absolute moments; EFM captures the
    # relative redistribution caused by alternate-span loading.
    use_pattern = method.pattern_loading && requires_pattern_loading(qD, qL) && n_cols >= 3
    if use_pattern
        fc_col_pat = _get_column_fc(supporting_columns, fc)
        wc_pcf_val = ustrip(pcf, γ_concrete)
        Ecc_pat = Ec(fc_col_pat, wc_pcf_val)

        efm_spans = _build_efm_spans(supporting_columns, l1, l2, ln, h, Ecs;
                                     drop_panel=drop_panel)
        joint_pos = [col.position for col in supporting_columns]
        cshape   = col_shape(first(supporting_columns))
        jKec     = _compute_joint_Kec(efm_spans, joint_pos, Lc, Ecs, Ecc_pat;
                                      column_shape=cshape)
        n_efm_spans = length(efm_spans)

        # Full-load EFM baseline
        efm_full = solve_moment_distribution(efm_spans, jKec, joint_pos, qu)
        env_neg_ext = abs(efm_full[1].M_neg_left)
        env_neg_int = abs(efm_full[1].M_neg_right)
        env_pos     = abs(efm_full[1].M_pos)

        # Envelope over all patterns
        for pat in generate_load_patterns(n_efm_spans)
            all(==(:dead_plus_live), pat) && continue
            qu_ps = factored_pattern_loads(pat, qD, qL)
            efm_p = solve_moment_distribution(efm_spans, jKec, joint_pos, qu_ps)
            abs(efm_p[1].M_neg_left)  > env_neg_ext && (env_neg_ext = abs(efm_p[1].M_neg_left))
            abs(efm_p[1].M_neg_right) > env_neg_int && (env_neg_int = abs(efm_p[1].M_neg_right))
            abs(efm_p[1].M_pos)       > env_pos     && (env_pos     = abs(efm_p[1].M_pos))
        end

        # Amplification ratios (≥ 1.0 — pattern loading only increases design moments)
        _safe_amp(env, base) = ustrip(base) > 1e-6 ? max(1.0, ustrip(env) / ustrip(base)) : 1.0
        amp_ext = _safe_amp(env_neg_ext, abs(efm_full[1].M_neg_left))
        amp_int = _safe_amp(env_neg_int, abs(efm_full[1].M_neg_right))
        amp_pos = _safe_amp(env_pos,     abs(efm_full[1].M_pos))

        M_neg_ext *= amp_ext
        M_neg_int *= amp_int
        M_pos     *= amp_pos

        verbose && @debug "FEA PATTERN LOADING (ACI 13.7.6)" amp_ext=round(amp_ext, digits=3) amp_int=round(amp_int, digits=3) amp_pos=round(amp_pos, digits=3)
    end

    M0_u = uconvert(kip * u"ft", M0)
    Vu_max = uconvert(kip, qu * l2 * ln / 2)

    if verbose
        @debug "FEA RESULT ($(envelope.n_cells) cells)" begin
            Mne = round(ustrip(kip * u"ft", M_neg_ext), digits=1)
            Mni = round(ustrip(kip * u"ft", M_neg_int), digits=1)
            Mp  = round(ustrip(kip * u"ft", M_pos), digits=1)
            M0k = round(ustrip(kip * u"ft", M0_u), digits=1)
            sum_pct = M0k > 0 ? round(((Mne + Mni) / 2 + Mp) / M0k * 100, digits=1) : 0.0
            "M⁻_ext=$Mne  M⁻_int=$Mni  M⁺=$Mp  (M₀=$M0k, ∑/M₀=$(sum_pct)%)"
        end
        for (i, col) in enumerate(supporting_columns)
            @debug "  Column $i ($(col.position))" begin
                Vu_s = round(ustrip(kip, forces.Vu[i]), digits=1)
                Mub_s = round(ustrip(kip * u"ft", forces.Mub[i]), digits=1)
                Mn = round(ustrip(kip * u"ft", column_moments[i]), digits=1)
                "Vu=$Vu_s kip  Mub=$Mub_s  M⁻=$Mn kip-ft"
            end
        end
    end

    # ─── Secondary direction: perpendicular strip integration ───
    # The shell model is already solved — zero additional solve cost.
    # Extract moments in perpendicular direction and build secondary NamedTuple.
    sec_setup = _secondary_moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    sec_span_axis = sec_setup.span_axis

    sec_envelope = _extract_cell_moments(
        cache, struc, slab, supporting_columns,
        sec_span_axis; verbose=false
    )
    sec_column_moments = [uconvert(kip * u"ft", m * u"N*m") for m in sec_envelope.col_Mneg]
    sec_neg_env = _envelope_from_columns(sec_column_moments, supporting_columns)

    # Column forces in secondary direction (unbalanced about perpendicular axis)
    sec_ax_len = hypot(sec_span_axis...)
    sec_ax = sec_ax_len > 1e-9 ? (sec_span_axis[1]/sec_ax_len, sec_span_axis[2]/sec_ax_len) : (0.0, 1.0)
    MomentT = typeof(1.0kip * u"ft")
    sec_Mub = Vector{MomentT}(undef, n_cols)
    for i in 1:n_cols
        sec_Mub[i] = uconvert(kip * u"ft", abs(sec_ax[1] * forces.My[i] - sec_ax[2] * forces.Mx[i]))
    end

    secondary_data = (
        M0 = uconvert(kip * u"ft", sec_setup.M0),
        M_neg_ext = sec_neg_env.M_neg_ext,
        M_neg_int = sec_neg_env.M_neg_int,
        M_pos = uconvert(kip * u"ft", sec_envelope.M_pos),
        l1 = sec_setup.l1,
        l2 = sec_setup.l2,
        ln = sec_setup.ln,
        column_moments = sec_column_moments,
        column_shears = forces.Vu,  # same shear (axial from stubs)
        unbalanced_moments = sec_Mub,
    )

    return MomentAnalysisResult(
        M0_u,
        M_neg_ext,
        M_neg_int,
        M_pos,
        qu, qD, qL,
        l1, l2, ln, c1_avg,
        column_moments,
        forces.Vu,
        forces.Mub,
        Vu_max;
        secondary = secondary_data,
        fea_Δ_panel = fea_Δ_panel,
        pattern_loading = use_pattern,
    )
end

"""
    run_secondary_moment_analysis(::FEA, ...) -> NamedTuple

For FEA, secondary moments are already computed during `run_moment_analysis`
and stored in `moment_results.secondary`.  This method just extracts it.

If `moment_results.secondary` is already populated (the normal case), returns
it directly.  Otherwise falls back to DDM secondary as an approximation.
"""
function run_secondary_moment_analysis(
    method::FEA,
    struc, slab, supporting_columns, h::Length,
    fc::Pressure, Ecs::Pressure, γ_concrete;
    moment_results = nothing,
    kwargs...
)
    # FEA populates secondary during run_moment_analysis — just return it
    if !isnothing(moment_results) && !isnothing(moment_results.secondary)
        return moment_results.secondary
    end
    # Fallback: DDM secondary (should not happen in normal flow)
    return run_secondary_moment_analysis(
        DDM(), struc, slab, supporting_columns, h, fc, Ecs, γ_concrete; kwargs...
    )
end

