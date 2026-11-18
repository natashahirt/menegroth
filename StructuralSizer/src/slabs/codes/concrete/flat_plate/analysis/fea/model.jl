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
    build_slab_shell_patches(struc, columns, section;
        drop_panel=nothing, patch_stiffness_factor=100.0,
        vertex_set=nothing, span_axis=(1.0, 0.0)) -> Vector{Asap.ShellPatch}

Build ShellPatch objects for columns (and optionally drop panels) to enforce mesh
conformity at column perimeters and drop panel boundaries.

Used by both the FEA design pipeline and the visualization analysis model so that
mesh vertices respect patch boundaries and refinement happens around them.

# Arguments
- `struc`: BuildingStructure (for skeleton geometry)
- `columns`: Columns supporting the slab
- `section`: Base slab ShellSection (thickness, E, ν)

# Keyword Arguments
- `drop_panel`: DropPanelGeometry for flat slabs; `nothing` for flat plate
- `patch_stiffness_factor`: Multiplier for patch E (default 100, a rigid footprint)
- `vertex_set`: Optional `Set{Int}` of slab vertex indices; columns with
  `vertex_idx ∉ vertex_set` are skipped. Pass `nothing` to include all columns.
- `span_axis`: Unit vector of span direction 1. The drop is `±a1` along this
  axis and `±a2` along its left normal, then clipped at a free edge.

# Returns
`Vector{Asap.ShellPatch}` — column patches (and drop panel patches when present).
"""
function build_slab_shell_patches(
    struc, columns, section::Asap.ShellSection;
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    patch_stiffness_factor::Float64 = 100.0,
    vertex_set::Union{Nothing, Set{Int}} = nothing,
    span_axis::NTuple{2, Float64} = (1.0, 0.0),
)
    skel = struc.skeleton
    h_m = section.thickness
    E_Pa = section.E
    ν_val = section.ν

    patch_section = Asap.ShellSection(
        h_m * u"m", (E_Pa * patch_stiffness_factor) * u"Pa", ν_val; name=:col_patch
    )
    patches = Asap.ShellPatch[]

    for col in columns
        vi = col.vertex_idx
        isnothing(vertex_set) || vi in vertex_set || continue
        xy = _column_xy_m(skel, col)
        cshape = col_shape(col)
        if cshape == :circular
            D_m = ustrip(u"m", col.c1)
            eq_side = D_m * sqrt(π / 4)
            push!(patches, Asap.ShellPatch(xy[1], xy[2], eq_side, eq_side,
                                           patch_section; id=:col_patch))
        else
            c1_m = ustrip(u"m", col.c1)
            c2_m = ustrip(u"m", col.c2)
            θ = col_orientation(col)
            if abs(θ) < 1e-12
                push!(patches, Asap.ShellPatch(xy[1], xy[2], c1_m, c2_m,
                                               patch_section; id=:col_patch))
            else
                cosθ = cos(θ); sinθ = sin(θ)
                hx = c1_m / 2; hy = c2_m / 2
                corners_local = ((-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy))
                verts = Tuple{Float64, Float64}[
                    (xy[1] + cosθ*lx - sinθ*ly, xy[2] + sinθ*lx + cosθ*ly)
                    for (lx, ly) in corners_local
                ]
                push!(patches, Asap.ShellPatch(verts, (xy[1], xy[2]),
                                               patch_section, :col_patch))
            end
        end
    end

    if !isnothing(drop_panel)
        h_total = total_depth_at_drop(h_m * u"m", drop_panel)
        drop_section = Asap.ShellSection(
            uconvert(u"m", h_total), E_Pa * u"Pa", ν_val; name=:drop_panel_patch
        )
        # Same outline the punching check uses: ±a1 along the span, ±a2 across
        # it, clipped where a free edge cuts the drop. ACI 318-11 §11.11.1.2
        # (corpus: aci-318-11, page 200).
        for col in columns
            vi = col.vertex_idx
            isnothing(vertex_set) || vi in vertex_set || continue
            xy = _column_xy_m(skel, col)
            outline = _column_drop_outline(col, drop_panel, span_axis)
            verts = Tuple{Float64, Float64}[
                (xy[1] + p[1], xy[2] + p[2]) for p in outline.polygon]
            center = (xy[1] + outline.centroid[1], xy[2] + outline.centroid[2])
            push!(patches, Asap.ShellPatch(verts, center, drop_section, :drop_panel))
        end
    end

    return patches
end

"""Clipped drop outline in the column-centre frame. Interior columns stay the full rectangle."""
function _column_drop_outline(col, drop_panel::DropPanelGeometry, span_axis)
    position = hasproperty(col, :position) ? col.position : :interior
    swapped = position === :edge && _infer_free_edge_parallel(col) === :c1
    kind = hasproperty(col, :corner_kind) ? col.corner_kind : :convex
    return drop_outline(col.c1, col.c2, drop_panel.a_drop_1, drop_panel.a_drop_2,
                        position, col_orientation(col), span_axis;
                        swapped = swapped, corner_kind = kind)
end

"""
Plan loops of the unframed openings that meet this slab's faces. `face_idx`
keeps one face. An opening inside a nested beam network (`skel.face_holes`)
belongs to the slab within that network and is left out; the network's
outline itself is a framed void, see [`slab_void_loops`](@ref).
"""
function slab_opening_loops(struc, slab; face_idx::Union{Nothing, Int} = nothing)
    skel = struc.skeleton
    hasproperty(skel, :openings) || return Vector{NTuple{2, Float64}}[]
    ops = getfield(skel, :openings)
    isempty(ops) && return Vector{NTuple{2, Float64}}[]
    nested = hasproperty(skel, :face_holes) ? getfield(skel, :face_holes) : nothing
    face_loops = Vector{NTuple{2, Float64}}[]
    holes = Vector{NTuple{2, Float64}}[]
    for ci in slab.cell_indices
        f = struc.cells[ci].face_idx
        (face_idx === nothing || f == face_idx) || continue
        push!(face_loops, NTuple{2, Float64}[_vertex_xy_m(skel, vi) for vi in skel.face_vertex_indices[f]])
        nested === nothing || append!(holes, get(nested, f, ()))
    end
    out = Vector{NTuple{2, Float64}}[]
    seen = Set{Vector{Tuple{Int, Int}}}()
    for op in ops
        _opening_meets_face(op.loop, face_loops) || continue
        any(h -> all(p -> _pip_xy(p[1], p[2], h), op.loop), holes) && continue
        key = [(round(Int, 1e6 * p[1]), round(Int, 1e6 * p[2])) for p in op.loop]
        key in seen && continue
        push!(seen, key)
        push!(out, op.loop)
    end
    return out
end

function _pip_xy(x, y, poly)
    inside = false
    n = length(poly)
    j = n
    for i in 1:n
        xi, yi = poly[i]
        xj, yj = poly[j]
        if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi + 1e-30) + xi)
            inside = !inside
        end
        j = i
    end
    return inside
end

function _opening_meets_face(opening, faces)
    for face in faces
        for (x, y) in opening
            _pip_xy(x, y, face) && return true
        end
        for (x, y) in face
            _pip_xy(x, y, opening) && return true
        end
        n = length(opening)
        cx = sum(p[1] for p in opening) / n
        cy = sum(p[2] for p in opening) / n
        _pip_xy(cx, cy, face) && return true
    end
    return false
end

"""
Panels of `slab` that have a corner at `col`, each with its own column-strip
half-width `0.25 * min(l1, l2)` (ACI 318-11 §13.2.1, corpus: aci-318-11, page 244).

The polygon is in absolute plan metres. With no framing cell on the slab, one
uncipped cross uses the slab's governing spans.
"""
function _column_strip_panels(struc, slab, col)
    vi = hasproperty(col, :vertex_idx) ? Int(col.vertex_idx) : 0
    panels = Any[]
    skel = struc.skeleton
    if vi > 0
        for ci in slab.cell_indices
            cell = struc.cells[ci]
            hasproperty(cell, :spans) || continue
            vis = skel.face_vertex_indices[cell.face_idx]
            any(v -> Int(v) == vi, vis) || continue
            half = 0.25 * min(cell.spans.primary, cell.spans.secondary)
            poly = NTuple{2, Float64}[_vertex_xy_m(skel, Int(v)) for v in vis]
            push!(panels, (half, poly))
        end
    end
    if isempty(panels)
        half = 0.25 * min(slab.spans.primary, slab.spans.secondary)
        push!(panels, (half, nothing))
    end
    return panels
end

"""
Opening arguments for one column's §11.11.6 punching reduction.

The column centre is the structural centre (vertex plus `structural_offset`).
Column-strip half-widths come from the panels that frame the column.

# ENGINEERING JUDGMENT
§11.11.6 names flat slabs for the column-strip trigger. A flat plate is
checked with the `10h` rule only.
"""
function column_opening_punching(struc, slab, col)
    loops = slab_opening_loops(struc, slab)
    isempty(loops) && return (;)
    xy = _column_xy_m(struc.skeleton, col)
    θcol = hasproperty(col, :θ) ? Float64(col.θ) : 0.0
    return (openings = loops, column_xy = (xy[1], xy[2]),
            flat_slab = slab.floor_type == :flat_slab,
            column_strips = _column_strip_panels(struc, slab, col),
            span_axis = _get_span_axis(slab),
            θ = θcol)
end

"""
    punching_axis_kwargs(struc, slab, col) -> NamedTuple

Keywords for `check_punching_for_column` / `check_punching`: the slab span
direction, so the unbalanced moments meet the column's own `c1` / `c2`, plus
the opening data from [`column_opening_punching`](@ref).
"""
punching_axis_kwargs(struc, slab, col) =
    merge((span_axis = _get_span_axis(slab),), column_opening_punching(struc, slab, col))

"""
    build_slab_shell_mesh(struc, slab, columns, section;
        target_edge=nothing, drop_panel=nothing,
        patch_stiffness_factor=100.0, id=:slab,
        edge_support_type=:free, node_map=nothing) -> (shells, patches, node_map, target_edge)

Build triangulated shell elements for a slab with ShellPatch mesh conformity at
each column.  This is the **single source of truth** for slab shell meshing —
used by both the FEA design pipeline and the visualization analysis model.

The centerline polygon is the frame. Outside it, and inside a courtyard, a
band of triangles runs out to the largest column face on each straight edge.
Those elements are part of `shells`, so the caller's single area load covers
the strip. Column nodes and edge-beam nodes stay on the centerline. A column
that grows changes [`fea_mesh_key`](@ref), and the rebuilt mesh carries the
new width.

Returns a NamedTuple `(shells, patches, interior_nodes, node_map, target_edge)`.
The caller is responsible for adding column stubs, loads, and assembling/solving.
"""
function build_slab_shell_mesh(
    struc, slab, columns, section::Asap.ShellSection;
    target_edge::Union{Nothing, Length} = nothing,
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    patch_stiffness_factor::Float64 = 100.0,
    id::Symbol = :slab,
    edge_support_type = :free,
    node_map::Union{Nothing, Dict{Int, Asap.Node}} = nothing,
)
    skel = struc.skeleton

    # ─── 1. Slab boundary + interior cell edges ───
    boundary_vis, all_vis, interior_edge_vis = _get_slab_face_boundary(struc, slab)

    # ─── 1b. Adaptive mesh resolution ───
    if target_edge === nothing
        min_span_m = minimum(ustrip(u"m", struc.cells[ci].spans.primary)
                             for ci in slab.cell_indices)
        # Upper bound 0.30 m: with the column-width section cut, face moments
        # and a rigid column patch stay within a few percent of a 0.10 m mesh
        # down to this size and diverge by 0.50 m
        # (scripts/runners/diagnose_fea_unbalanced_mesh.jl).
        target_edge = clamp(min_span_m / 20.0, 0.15, 0.30) * u"m"
    end

    # ─── 2. Slab-level nodes (z = 0) ───
    if node_map === nothing
        node_map = Dict{Int, Asap.Node}()
        for vi in all_vis
            xy = _vertex_xy_m(skel, vi)
            node_map[vi] = Asap.Node([xy[1] * u"m", xy[2] * u"m", 0.0u"m"], :free)
        end
    end

    # ─── 3. ShellPatches at columns (and drop panels when present) ───
    vertex_set = Set(keys(node_map))
    patches = build_slab_shell_patches(struc, columns, section;
        drop_panel=drop_panel,
        patch_stiffness_factor=patch_stiffness_factor,
        vertex_set=vertex_set,
        span_axis=_get_span_axis(slab))

    # ─── 4. Interior nodes + conforming nodes along interior cell edges ───
    boundary_set = Set(boundary_vis)
    corner_nodes = tuple([node_map[vi] for vi in boundary_vis]...)

    interior_nodes = Asap.Node[]
    for vi in all_vis
        vi in boundary_set && continue
        haskey(node_map, vi) && push!(interior_nodes, node_map[vi])
    end

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

    # ─── 5. Refinement edge length ───
    min_col_dim_m = if !isempty(columns)
        minimum(min(ustrip(u"m", col.c1), ustrip(u"m", col.c2)) for col in columns)
    else
        target_m
    end
    refine_edge = clamp(min_col_dim_m / 2.0, 0.04, target_m / 2.0) * u"m"

    # ─── 6. Build shell mesh ───
    # Openings cut into a face, plus bays that were never a slab (a core shaft).
    holes = vcat(slab_opening_loops(struc, slab), slab_void_loops(struc, slab))
    shells = Asap.Shell(corner_nodes, section;
                        holes=holes,
                        id=id,
                        interior_nodes=interior_nodes,
                        interior_patches=patches,
                        edge_support_type=edge_support_type,
                        interior_support_type=:free,
                        target_edge_length=target_edge,
                        refinement_edge_length=refine_edge)

    # Slab past the centerline, out to the largest column face. The area load
    # is built from `shells`, so the strip is loaded with the rest of the slab.
    _append_flat_plate_edge_strip!(shells, section, struc, slab, node_map, boundary_vis)

    return (shells=shells, patches=patches, interior_nodes=interior_nodes,
            node_map=node_map, target_edge=target_edge)
end

"""
    _append_flat_plate_edge_strip!(shells, section, struc, slab, node_map, boundary_vis)

Add the centerline-to-slab-edge band along the slab's free edges.

The band is the floor's slab edge ([`floor_slab_edges`](@ref)), so it matches
the story shell: a straight run is as wide as the largest column face on it,
anywhere on the floor. An edge shared with another slab gets no band, and
neither does an opening. No sized column leaves the mesh unchanged.
"""
function _append_flat_plate_edge_strip!(shells, section, struc, slab, node_map, boundary_vis)
    isempty(boundary_vis) && return shells
    skel = struc.skeleton
    z = _edge_m(skel.geometry.vertex_coords[first(boundary_vis), 3])
    off = slab_edge_offsets(floor_slab_edges(struc, z))
    isempty(off.side) && return shells
    _, _, _, holes = _slab_boundary_topology(struc, slab)
    nodes = _slab_mesh_nodes(shells)
    outer = Dict{Int, Asap.Node}()
    for loop in Iterators.flatten(((boundary_vis,), holes))
        n = length(loop)
        for i in 1:n
            va, vb = loop[i], loop[mod1(i + 1, n)]
            side = get(off.side, minmax(va, vb), nothing)
            side === nothing && continue
            haskey(node_map, va) && haskey(node_map, vb) || continue
            _append_edge_strip_segment!(shells, section, nodes, outer, off.shift, side,
                                        skel, va, vb, node_map)
        end
    end
    return shells
end

"""
Band triangles on the boundary edge `va`→`vb`, walked with the slab on the left.

An end vertex moves by `shift` (a corner goes to the outline corner); a mesh
node inside the edge moves along the run's outward normal by its width. The
centerline nodes are not moved. `outer` shares the moved vertex nodes between
the two edges that meet there.
"""
function _append_edge_strip_segment!(shells, section, nodes, outer, shift, side,
                                     skel, va, vb, node_map)
    a = _vertex_xy_m(skel, va)
    b = _vertex_xy_m(skel, vb)
    sa = get(shift, va, (0.0, 0.0))
    sb = get(shift, vb, (0.0, 0.0))
    hypot(sa...) < 1e-6 && hypot(sb...) < 1e-6 && return shells
    chain = collect(Asap.Node, _nodes_along(nodes, node_map[va], node_map[vb]))
    outers = Asap.Node[_moved_vertex_node!(outer, va, node_map[va], a, sa)]
    for node in @view chain[2:end-1]
        if side.width < 1e-6
            push!(outers, node)
        else
            x = ustrip(u"m", node.position[1]) + side.outward[1] * side.width
            y = ustrip(u"m", node.position[2]) + side.outward[2] * side.width
            push!(outers, Asap.Node([x * u"m", y * u"m", 0.0u"m"], :free))
        end
    end
    push!(outers, _moved_vertex_node!(outer, vb, node_map[vb], b, sb))
    n_quads = length(chain) - 1
    for i in 1:n_quads
        b0, b1 = chain[i], chain[i + 1]
        o0, o1 = outers[i], outers[i + 1]
        _node_span(b0, b1) < 1e-6 && continue
        # A moved end vertex can slide along the next boundary run when that
        # run has no band. Mesh nodes of that run then sit on the band's end
        # edge; fanning through them keeps the mesh conforming.
        start = i == 1 ? _nodes_along(nodes, b0, o0) : (b0, o0)
        stop = i == n_quads ? _nodes_along(nodes, b1, o1) : (b1, o1)
        for k in 1:(length(start) - 1)
            _push_band_tri!(shells, section, (start[k], start[k + 1], b1))
        end
        for k in 1:(length(stop) - 1)
            _push_band_tri!(shells, section, (o0, stop[k + 1], stop[k]))
        end
    end
    return shells
end

"""
`from`, the mesh nodes strictly inside the segment `from`→`to` in order, then
`to`. Just the two ends when the segment has no length.
"""
function _nodes_along(nodes, from::Asap.Node, to::Asap.Node)
    _node_span(from, to) < 1e-6 && return (from, to)
    a = _xy_m(from)
    b = _xy_m(to)
    hits = Tuple{Float64, Asap.Node}[]
    for node in nodes
        s = _segment_station(_xy_m(node), a, b; tol = 1e-4)
        (s === nothing || s <= 1e-5 || s >= 1 - 1e-5) && continue
        push!(hits, (s, node))
    end
    isempty(hits) && return (from, to)
    sort!(hits; by = first)
    return (from, (last(h) for h in hits)..., to)
end

_xy_m(node::Asap.Node) = (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))

"""Add one band triangle, unless its three corners are collinear or coincide."""
function _push_band_tri!(shells, section, tri)
    p1, p2, p3 = _xy_m.(tri)
    twice_area = (p2[1] - p1[1]) * (p3[2] - p1[2]) - (p3[1] - p1[1]) * (p2[2] - p1[2])
    abs(twice_area) < 2e-9 && return shells
    push!(shells, Asap.ShellTri3(
        tri, section.thickness * u"m", section.E * u"Pa", section.ν;
        ρ = section.ρ, id = :slab_edge))
    return shells
end

"""
The node at boundary vertex `v` moved to the slab edge, made once per vertex.
A vertex that does not move keeps its centerline `node`, so the mesh stays joined.
"""
function _moved_vertex_node!(outer, v::Int, node, xy, shift)
    hypot(shift[1], shift[2]) < 1e-6 && return node
    get!(outer, v) do
        Asap.Node([(xy[1] + shift[1]) * u"m", (xy[2] + shift[2]) * u"m", 0.0u"m"], :free)
    end
end

"""Plan distance between two nodes, in metres."""
_node_span(a::Asap.Node, b::Asap.Node) = hypot(
    ustrip(u"m", a.position[1]) - ustrip(u"m", b.position[1]),
    ustrip(u"m", a.position[2]) - ustrip(u"m", b.position[2]))

"""Distinct shell nodes, in first-seen order."""
function _slab_mesh_nodes(shells)
    seen = IdDict{Asap.Node, Nothing}()
    nodes = Asap.Node[]
    for el in shells
        for node in el.nodes
            haskey(seen, node) && continue
            seen[node] = nothing
            push!(nodes, node)
        end
    end
    return nodes
end

"""
Join slab nodes on each wall to a wall shell. The slab nodes are not fixed.

ACI 318-11 R13.6.3.3 (corpus: aci-318-11, page 254) is a direct-design moment
coefficient for an edge cast with a stiff wall. It is not a support. The
wall hangs `drop_m` below the slab. Its base translations are held and its
rotations are not. The wall shell uses the slab analysis section's modulus.

Returns the number of slab nodes joined, and the new base nodes. Wall
triangles are appended to `shells` with id `:wall`.
"""
function _attach_slab_walls!(shells, struc, slab, section)
    piers = flat_plate_wall_piers(struc, slab)
    isempty(piers) && return 0, Asap.Node[]
    nodes = _slab_mesh_nodes(shells)
    bases = Dict{NTuple{3, Int}, Asap.Node}()
    joined = IdDict{Asap.Node, Nothing}()
    E = section.E * u"Pa"
    for pier in piers
        seg = ((pier.x1, pier.y1), (pier.x2, pier.y2))
        seen = IdDict{Asap.Node, Nothing}()
        d = (pier.x2 - pier.x1, pier.y2 - pier.y1)
        L2 = d[1] * d[1] + d[2] * d[2]
        L2 > 0 || continue
        hits = Tuple{Float64, Asap.Node}[]
        for node in nodes
            haskey(seen, node) && continue
            abs(ustrip(u"m", node.position[3])) > 1e-3 && continue
            pt = (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))
            _point_on_segment(pt, seg[1], seg[2]) || continue
            seen[node] = nothing
            s = ((pt[1] - pier.x1) * d[1] + (pt[2] - pier.y1) * d[2]) / L2
            push!(hits, (s, node))
        end
        sort!(hits; by = first)
        tops = Asap.Node[n for (_, n) in hits]
        length(tops) < 2 && continue
        z_local = -pier.drop_m
        row = Asap.Node[]
        for n in tops
            joined[n] = nothing
            x = ustrip(u"m", n.position[1])
            y = ustrip(u"m", n.position[2])
            key = (round(Int, 1000 * x), round(Int, 1000 * y), round(Int, 1000 * z_local))
            b = get(bases, key, nothing)
            if b === nothing
                b = Asap.Node([x * u"m", y * u"m", z_local * u"m"], :free)
                b.dof = Bool[false, false, false, true, true, true]
                bases[key] = b
            end
            push!(row, b)
        end
        t = pier.thickness_m * u"m"
        for i in 1:(length(tops) - 1)
            dx = ustrip(u"m", tops[i + 1].position[1] - tops[i].position[1])
            dy = ustrip(u"m", tops[i + 1].position[2] - tops[i].position[2])
            hypot(dx, dy) < 1e-4 && continue
            push!(shells, Asap.ShellTri3((tops[i], tops[i + 1], row[i + 1]), t, E,
                                         section.ν; id = :wall, ρ = section.ρ))
            push!(shells, Asap.ShellTri3((tops[i], row[i + 1], row[i]), t, E,
                                         section.ν; id = :wall, ρ = section.ρ))
        end
    end
    return length(joined), collect(values(bases))
end

"""
    _build_fea_slab_model(struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
                          Ecc=Ecs, target_edge=nothing, verbose=false,
                          edge_beam_βt=0.0, edge_beam_l2=nothing,
                          edge_beam_c1_avg=nothing)

Build a standalone Asap mixed model (shell + frame) with column elements
and ShellPatch mesh conformity at each column.

Delegates shell meshing to `build_slab_shell_mesh`, then adds column stubs,
optional perimeter edge-beam frame elements, loads, and assembles/solves.

When `edge_beam_βt > 0`, an `Asap.Element` is added for every consecutive
pair of boundary-vertex nodes returned by `_get_slab_face_boundary`.  This
generalizes to non-rectangular slabs (L-shapes, T-shapes, polygonal floors)
because the boundary is always a CCW closed polygon — the iteration only
relies on the polygon being closed, and each frame element's local axes
are derived from its endpoint geometry.

Returns `(model, col_stubs, shells, edge_beam_elements)`.

# Reference
- ACI 318-11 §13.6.4.2 (β_t, Eq. 13-5/13-6)
- ACI 318-11 §13.7.5 (torsional members)
"""
function _build_fea_slab_model(
    struc, slab, columns, h, Ecs, ν_concrete, qu, Lc;
    Ecc::Pressure = Ecs,
    target_edge::Union{Nothing, Length} = nothing,
    verbose::Bool = false,
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    col_I_factor::Float64 = 0.70,
    patch_stiffness_factor::Float64 = 100.0,
    edge_beam_βt::Float64 = 0.0,
    edge_beam_l2::Union{Nothing, Length} = nothing,
    edge_beam_c1_avg::Union{Nothing, Length} = nothing,
    q_drop::Pressure = 0.0u"Pa",
)
    skel = struc.skeleton
    shell_section = Asap.ShellSection(uconvert(u"m", h), uconvert(u"Pa", Ecs), ν_concrete)

    # Pin in-plane DOFs (u,v) at boundary for FEA.
    edge_dofs = [false, false, true, true, true, true]

    mesh = build_slab_shell_mesh(struc, slab, columns, shell_section;
        target_edge=target_edge, drop_panel=drop_panel,
        patch_stiffness_factor=patch_stiffness_factor,
        id=:slab_fea, edge_support_type=edge_dofs)
    shells = mesh.shells
    node_map = mesh.node_map
    target_edge = mesh.target_edge

    # The slab edge is joined to the wall. It is not held in space.
    _, wall_bases = _attach_slab_walls!(shells, struc, slab, shell_section)

    # ─── Column stub frame elements ───
    col_stubs = Dict{Int, Any}()
    frame_elements = Asap.FrameElement[]
    fixed_nodes = Asap.Node[]

    for (i, col) in enumerate(columns)
        vi = col.vertex_idx
        if !haskey(node_map, vi)
            xy = _vertex_xy_m(skel, vi)
            @warn "Column $vi at ($(xy[1]), $(xy[2])) not in slab face vertices"
            continue
        end

        slab_node = node_map[vi]
        xy = _column_xy_m(skel, col)

        Lc_below = col.base.L
        base_below = Asap.Node([xy[1] * u"m", xy[2] * u"m", -Lc_below], :fixed)
        push!(fixed_nodes, base_below)
        sec_below = _col_asap_sec(col, Ecc, ν_concrete; I_factor=col_I_factor)
        elem_below = Asap.Element(base_below, slab_node, sec_below, :col_below)
        # Drawn bottom to top, roll θ puts c1 (section x) at θ from global X.
        elem_below.Ψ = col_orientation(col)
        push!(frame_elements, elem_below)

        col_above = col.column_above
        elem_above = nothing
        base_above = nothing
        if !isnothing(col_above)
            Lc_above = col_above.base.L
            base_above = Asap.Node([xy[1] * u"m", xy[2] * u"m", Lc_above], :fixed)
            push!(fixed_nodes, base_above)
            sec_above = _col_asap_sec(col_above, Ecc, ν_concrete;
                I_factor=col_I_factor, fallback=(col.c1, col.c2))
            elem_above = Asap.Element(slab_node, base_above, sec_above, :col_above)
            elem_above.Ψ = col_orientation(col_above)
            push!(frame_elements, elem_above)
        end

        col_stubs[i] = (
            below  = (element=elem_below,  base_node=base_below,  slab_node=slab_node),
            above  = isnothing(elem_above) ? nothing :
                     (element=elem_above, base_node=base_above, slab_node=slab_node),
        )

        if verbose
            cshape = col_shape(col)
            shape_str = cshape == :circular ? "circular" : "rectangular"
            c1_mm = round(ustrip(u"m", col.c1)*1000, digits=0)
            c2_mm = round(ustrip(u"m", col.c2)*1000, digits=0)
            above_str = isnothing(col_above) ? "roof (no above)" : "above+below"
            @debug "  Col $i ($shape_str, $above_str): Lc=$(round(ustrip(u"m", Lc_below), digits=3))m, " *
                   "c1=$(c1_mm)mm, c2=$(c2_mm)mm"
        end
    end

    # ─── Edge-beam frame elements (ACI 318-11 §13.6.4.2 / §13.7.5) ───
    # Generalizes to non-rectangular slabs: `_get_slab_face_boundary` returns
    # a CCW-ordered closed polygon for any face shape (single-cell or chained
    # multi-cell), and we add one frame element per consecutive vertex pair.
    edge_beam_elements = Asap.FrameElement[]
    if edge_beam_βt > 0 && !isnothing(edge_beam_l2) && !isnothing(edge_beam_c1_avg)
        boundary_vis, _, _ = _get_slab_face_boundary(struc, slab)
        n_b = length(boundary_vis)
        if n_b >= 2
            eb_section = _edge_beam_asap_sec(
                edge_beam_βt, h, edge_beam_c1_avg, edge_beam_l2, Ecs, ν_concrete,
            )
            for i in 1:n_b
                vi_a = boundary_vis[i]
                vi_b = boundary_vis[mod1(i + 1, n_b)]
                (haskey(node_map, vi_a) && haskey(node_map, vi_b)) || continue
                node_a = node_map[vi_a]
                node_b = node_map[vi_b]
                # Skip degenerate (coincident) endpoints — possible in certain
                # multi-cell collapses.  Asap requires nonzero element length.
                pa = node_a.position; pb = node_b.position
                ustrip(u"m", hypot(pa[1] - pb[1], pa[2] - pb[2])) < 1e-6 && continue
                eb_elem = Asap.Element(node_a, node_b, eb_section, :edge_beam)
                push!(frame_elements, eb_elem)
                push!(edge_beam_elements, eb_elem)
            end
            if verbose
                b_eb, h_eb = _edge_beam_dims(edge_beam_βt, h, edge_beam_c1_avg, edge_beam_l2)
                @debug "FEA: edge-beam elements added on free perimeter " *
                       "(ACI 318-11 §13.6.4.2 Eq. 13-5/13-6)" begin
                    n=length(edge_beam_elements)
                    βt=edge_beam_βt
                    b=uconvert(u"inch", b_eb)
                    h_eb=uconvert(u"inch", h_eb)
                end
            end
        end
    end

    # Slab pressure stays off the wall shells.
    slab_shells = [s for s in shells if s.id !== :wall]
    loads = Asap.AbstractLoad[Asap.AreaLoad(slab_shells, uconvert(u"Pa", qu))]
    # Flat slab: the drop projection's self-weight on the drop patches only.
    if !isnothing(drop_panel)
        drop_shells = [s for s in shells if s.id === :drop_panel]
        isempty(drop_shells) || push!(loads, Asap.AreaLoad(
            drop_shells, uconvert(u"Pa", q_drop); id = FEA_DROP_LOAD_ID))
    end

    # ─── Build, process, solve ───
    all_nodes = vcat(collect(values(node_map)), fixed_nodes, wall_bases)
    model = Asap.Model(all_nodes, frame_elements, shells, loads)
    Asap.process!(model)
    Asap.solve!(model)

    if verbose
        @debug "FEA MODEL BUILT (column stubs + ShellPatch)" begin
            "nodes=$(length(model.nodes)) shells=$(length(model.shell_elements)) " *
            "stubs=$(length(frame_elements)) edge_beams=$(length(edge_beam_elements)) " *
            "dof=$(length(model.u)) target_edge=$(target_edge)"
        end
    end

    return (model=model, col_stubs=col_stubs, shells=shells,
            edge_beam_elements=edge_beam_elements)
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
    patch_stiffness_factor::Float64 = 100.0,
    edge_beam_l2::Union{Nothing, Length} = nothing,
    edge_beam_c1_avg::Union{Nothing, Length} = nothing,
    q_drop::Pressure = 0.0u"Pa",
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

    # 2. Update load magnitude (slab, and the drop patches' extra self-weight)
    _set_fea_area_loads!(model, qu, q_drop)

    # 3. Update column sections
    for (i, col) in enumerate(columns)
        haskey(cache.col_stubs, i) || continue
        stubs = cache.col_stubs[i]
        stubs.below.element.section = _col_asap_sec(col, Ecc, ν_concrete; I_factor=col_I_factor)
        if !isnothing(stubs.above) && !isnothing(col.column_above)
            stubs.above.element.section = _col_asap_sec(
                col.column_above, Ecc, ν_concrete;
                I_factor=col_I_factor, fallback=(col.c1, col.c2))
        end
    end

    # 3b. Refresh edge-beam sections — h, Ecs, or βt may have changed between
    # iterations.  Cross-section is invariant across all perimeter elements
    # (single βt per slab, ACI 318-11 §13.6.4.2), so we compute once and assign.
    if !isempty(cache.edge_beam_elements) && cache.edge_beam_βt > 0 &&
       !isnothing(edge_beam_l2) && !isnothing(edge_beam_c1_avg)
        eb_section = _edge_beam_asap_sec(
            cache.edge_beam_βt, h, edge_beam_c1_avg, edge_beam_l2, Ecs, ν_concrete,
        )
        for elem in cache.edge_beam_elements
            elem.section = eb_section
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
