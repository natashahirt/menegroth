# =============================================================================
# Flat-plate floors as loaded shells of the building model
# =============================================================================
#
# Under `params.flat_plate_analysis = :building`, every flat-plate and flat-slab
# floor is meshed into `struc.asap_model` as one continuous shell per story.
# The shell carries the floor's pressure itself; the cell edges between those
# panels are inert frame slots. Column tops and wall nodes on the floor are
# mesh nodes, so the slab, the columns and the walls share their joints.
# =============================================================================

"""
Flexural and axial stiffness factors of a flat plate or flat slab for the
elastic analysis: `I = 0.25 Ig`, `A = 1.0 Ag`. ACI 318-11 §10.10.4.1(b), (c)
(corpus: aci-318-11, page 153).
"""
const FLAT_PLATE_CRACKED_I = 0.25
const FLAT_PLATE_CRACKED_A = 1.0

"""Target triangle edge (m) of the building flat-plate mesh."""
const FLAT_PLATE_SHELL_TARGET_EDGE = 0.5

"""
Column-footprint modulus multiplier. ENGINEERING JUDGMENT: the same rigid
footprint the per-slab FEA uses by default (`FEA.patch_stiffness_factor`).
"""
const FLAT_PLATE_PATCH_FACTOR = 100.0

const FP_SHELL_ID = :flat_plate
const FP_PATCH_ID = :flat_plate_patch
const FP_DROP_ID = :flat_plate_drop
const FP_DEAD_ID = :flat_plate_dead
const FP_LIVE_ID = :flat_plate_live
const FP_TOTAL_ID = :flat_plate_total
const _FP_LOAD_IDS = (FP_DEAD_ID, FP_LIVE_ID, FP_TOTAL_ID)

"""
    FlatPlateShellLayout

The flat-plate shells of one building model and the loads on them.

- `slab_shells[s]`, `slab_kinds[s]`: triangles of slab `s` and their kind,
  `:slab`, `:col_patch` or `:drop`.
- `cell_shells[c]`: triangles of cell `c`; `slab_of_cell[c]` its slab.
- `thickness[s]`, `E[s]`: gross thickness (m) and slab modulus (Pa) now on
  the triangles of slab `s`. `ν` is shared.
- `dead`, `live`: per-cell factored `AreaLoad`s when the model is split for
  patterns (`split`), else `total`, the enveloped pressure.
- `wall_nodes`: slab nodes that are also wall-shell nodes.
- `columns_key`: the installed column footprints the patches were meshed for.
"""
mutable struct FlatPlateShellLayout
    slab_shells::Dict{Int, Vector{Asap.ShellTri3}}
    slab_kinds::Dict{Int, Vector{Symbol}}
    cell_shells::Dict{Int, Vector{Asap.ShellTri3}}
    slab_of_cell::Dict{Int, Int}
    thickness::Dict{Int, Float64}
    E::Dict{Int, Float64}
    ν::Float64
    dead::Dict{Int, Asap.AreaLoad}
    live::Dict{Int, Asap.AreaLoad}
    total::Dict{Int, Asap.AreaLoad}
    split::Bool
    wall_nodes::Set{UInt64}
    columns_key::UInt
    params::DesignParameters
end

const _FLAT_PLATE_SHELLS = WeakKeyDict{Asap.Model, FlatPlateShellLayout}()

"""The flat-plate shell layout of `struc.asap_model`, or `nothing` when it has none."""
function flat_plate_shell_layout(struc::BuildingStructure)
    model = struc.asap_model
    model === nothing && return nothing
    return get(_FLAT_PLATE_SHELLS, model, nothing)
end

"""
    _flat_plate_building_cells(struc, params, diaphragm_mode) -> Dict{Int, Int}

Cell → slab for the floors meshed into the building model. Empty unless
`params.flat_plate_analysis === :building`. A `:shell` or `:semirigid`
diaphragm already meshes the slabs, so those modes keep the frame path.
"""
function _flat_plate_building_cells(struc::BuildingStructure, params::DesignParameters,
                                    diaphragm_mode::Symbol)
    out = Dict{Int, Int}()
    params.flat_plate_analysis === :building || return out
    diaphragm_mode in (:shell, :semirigid) && return out
    for (si, slab) in enumerate(struc.slabs)
        slab.floor_type in (:flat_plate, :flat_slab) || continue
        for ci in slab.cell_indices
            struc.cells[ci].floor_type == :grade && continue
            out[ci] = si
        end
    end
    return out
end

"""
Cell edges that only flat-plate shell cells touch. They keep their frame slot
with no stiffness: the slab between those panels is the shell.
"""
function _flat_plate_inert_edges(struc::BuildingStructure, fp_cells::Dict{Int, Int})
    isempty(fp_cells) && return Set{Int}()
    skel = struc.skeleton
    all_fp = Dict{Int, Bool}()
    for (ci, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        fp = haskey(fp_cells, ci)
        for e in skel.face_edge_indices[cell.face_idx]
            all_fp[e] = get(all_fp, e, true) && fp
        end
    end
    return Set(e for (e, ok) in all_fp if ok)
end

_node_xy_m(nd::Asap.Node) = (ustrip(u"m", nd.position[1]), ustrip(u"m", nd.position[2]))
_node_z_m(nd::Asap.Node) = ustrip(u"m", nd.position[3])

"""
Equivalent shell `(t, E)` of a gross section `(t_gross, E_gross)` with the
§10.10.4.1 factors: `E t = A_factor · E t_gross` and
`E t³ = I_factor · E t_gross³` (ACI 318-11 §10.10.4.1(b), (c), corpus:
aci-318-11, page 153).
"""
function _flat_plate_equivalent_section(t_gross::Float64, E_gross::Float64)
    κ = sqrt(FLAT_PLATE_CRACKED_I / FLAT_PLATE_CRACKED_A)
    return (κ * t_gross, E_gross * FLAT_PLATE_CRACKED_A / κ)
end

"""Gross thickness (m) of a triangle of `kind` on a slab of thickness `h` (m)."""
function _flat_plate_gross_thickness(kind::Symbol, h::Float64, drop_panel)
    kind === :drop || return h
    drop_panel === nothing && return h
    return ustrip(u"m", StructuralSizer.total_depth_at_drop(h * u"m", drop_panel))
end

"""Write the equivalent section of `kind` onto `tri`."""
function _set_flat_plate_tri_section!(tri::Asap.ShellTri3, kind::Symbol, h::Float64,
                                      E::Float64, ν::Float64, drop_panel)
    t_eq, E_eq = _flat_plate_equivalent_section(
        _flat_plate_gross_thickness(kind, h, drop_panel), E)
    tri.thickness = t_eq
    tri.E = kind === :col_patch ? FLAT_PLATE_PATCH_FACTOR * E_eq : E_eq
    tri.ν = ν
    tri.ρ = 0.0
    return tri
end

"""
Fingerprint of the installed column footprints under the meshed floors.
A different value means the column patches no longer match the columns.
"""
function _flat_plate_columns_key(struc::BuildingStructure, slab_ids)
    h = UInt(0)
    seen = Set{UInt64}()
    for si in sort!(collect(slab_ids))
        for col in _get_slab_columns(struc, struc.slabs[si])
            objectid(col) in seen && continue
            push!(seen, objectid(col))
            dims = col.c1 === nothing ? nothing :
                (ustrip(u"m", col.c1), ustrip(u"m", col.c2), col.shape,
                 Float64(col.θ), col.structural_offset)
            h = hash((col.vertex_idx, dims), h)
        end
    end
    return h
end

"""
    _mesh_flat_plate_floors(struc, params, nodes, wall_shells, fp_cells) -> (layout, shells)

Mesh the flat-plate cells `fp_cells` (cell → slab) story by story. Panels of
one story that share a vertex are one shell. Frame nodes and wall nodes on
that story inside the floor are embedded, so the columns and walls are joined
to the slab. Each column with a size gets a stiff patch over its footprint,
and a flat slab gets its drop panel at the drop depth.
"""
function _mesh_flat_plate_floors(struc::BuildingStructure, params::DesignParameters,
                                 nodes::Vector{Asap.Node}, wall_shells, fp_cells::Dict{Int, Int})
    conc = resolve_concrete(params)
    layout = FlatPlateShellLayout(
        Dict{Int, Vector{Asap.ShellTri3}}(), Dict{Int, Vector{Symbol}}(),
        Dict{Int, Vector{Asap.ShellTri3}}(), copy(fp_cells),
        Dict{Int, Float64}(), Dict{Int, Float64}(), Float64(conc.ν),
        Dict{Int, Asap.AreaLoad}(), Dict{Int, Asap.AreaLoad}(), Dict{Int, Asap.AreaLoad}(),
        false, Set{UInt64}(), UInt(0), params)
    shells = Asap.ShellTri3[]
    isempty(fp_cells) && return layout, shells

    E = Float64(ustrip(u"Pa", conc.E))
    for si in unique(values(fp_cells))
        layout.thickness[si] = Float64(ustrip(u"m", thickness(struc.slabs[si])))
        layout.E[si] = E
        layout.slab_shells[si] = Asap.ShellTri3[]
        layout.slab_kinds[si] = Symbol[]
    end
    layout.columns_key = _flat_plate_columns_key(struc, keys(layout.thickness))

    wall_pool = Asap.Node[]
    seen = Set{UInt64}()
    for sh in wall_shells, nd in sh.nodes
        objectid(nd) in seen && continue
        push!(seen, objectid(nd))
        push!(wall_pool, nd)
    end
    layout.wall_nodes = seen

    skel = struc.skeleton
    by_z = Dict{Int, Vector{Int}}()
    for ci in sort!(collect(keys(fp_cells)))
        vis = skel.face_vertex_indices[struc.cells[ci].face_idx]
        isempty(vis) && continue
        push!(get!(() -> Int[], by_z, round(Int, 1000 * _node_z_m(nodes[first(vis)]))), ci)
    end
    for zkey in sort!(collect(keys(by_z)))
        for comp in _shared_vertex_components(skel, struc, by_z[zkey])
            _mesh_flat_plate_component!(layout, shells, struc, nodes, wall_pool, comp)
        end
    end
    return layout, shells
end

"""Groups of `cells` joined through shared face vertices."""
function _shared_vertex_components(skel, struc, cells::Vector{Int})
    parent = collect(eachindex(cells))
    function root(i)
        while parent[i] != i
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    owner = Dict{Int, Int}()
    for (k, ci) in enumerate(cells)
        for vi in skel.face_vertex_indices[struc.cells[ci].face_idx]
            j = get(owner, vi, 0)
            if j == 0
                owner[vi] = k
            else
                a, b = root(k), root(j)
                a == b || (parent[a] = b)
            end
        end
    end
    groups = Dict{Int, Vector{Int}}()
    for k in eachindex(cells)
        push!(get!(() -> Int[], groups, root(k)), cells[k])
    end
    comps = [sort!(g) for g in values(groups)]
    return sort!(comps; by = first)
end

"""The node in `pool` within `tol` (m) of `p`, or `nothing`."""
function _node_near(pool, p; tol::Float64 = 1e-5)
    for nd in pool
        q = _node_xy_m(nd)
        hypot(q[1] - p[1], q[2] - p[2]) <= tol && return nd
    end
    return nothing
end

"""`p` moved onto the plan position of a node in `pool` within `tol`, else `p`."""
function _snap_xy(pool, p; tol::Float64 = 1e-5)
    nd = _node_near(pool, p; tol)
    return nd === nothing ? p : _node_xy_m(nd)
end

function _mesh_flat_plate_component!(layout::FlatPlateShellLayout, shells, struc,
                                     nodes::Vector{Asap.Node}, wall_pool, cells::Vector{Int})
    skel = struc.skeleton
    z = _node_z_m(nodes[first(skel.face_vertex_indices[struc.cells[first(cells)].face_idx])])

    # One panel per cell, outlined through the building nodes so a column
    # centerline offset moves the panel corner with its column.
    panels = StructuralSizer.StoryShellPanel[]
    for ci in cells
        si = layout.slab_of_cell[ci]
        slab = struc.slabs[si]
        t_eq, E_eq = _flat_plate_equivalent_section(layout.thickness[si], layout.E[si])
        sec = Asap.ShellSection(t_eq * u"m", E_eq * u"Pa", layout.ν; name = FP_SHELL_ID)
        face = struc.cells[ci].face_idx
        poly = NTuple{2, Float64}[_node_xy_m(nodes[vi]) for vi in skel.face_vertex_indices[face]]
        holes = vcat(StructuralSizer.slab_opening_loops(struc, slab; face_idx = face),
                     face_hole_loops(skel, face))
        push!(panels, StructuralSizer.StoryShellPanel(poly, sec; holes = holes))
    end
    outer, interior, holes = StructuralSizer._story_plate(panels, StructuralSizer.ShellFrameBeam[])

    # Frame and wall nodes on this story inside the floor (or on its edge),
    # not strictly inside a hole.
    on_or_in(p, loop) = Asap._point_in_polygon(p, loop) ||
                        StructuralSizer._dist_to_polygon(p[1], p[2], loop) <= 1e-6
    strictly_in(p, loop) = Asap._point_in_polygon(p, loop) &&
                           StructuralSizer._dist_to_polygon(p[1], p[2], loop) > 1e-6
    attach = Asap.Node[]
    for nd in Iterators.flatten((nodes, wall_pool))
        abs(_node_z_m(nd) - z) <= 1e-3 || continue
        p = _node_xy_m(nd)
        on_or_in(p, outer) || continue
        any(h -> strictly_in(p, h), holes) && continue
        _node_near(attach, p; tol = 1e-6) === nothing && push!(attach, nd)
    end
    # Lines and loops on the attached nodes' exact coordinates, with every
    # attached node on an outline inserted as a vertex of that outline.
    snap(p) = _snap_xy(attach, p)
    lines = Vector{NTuple{2, Float64}}[NTuple{2, Float64}[snap(p) for p in l] for l in interior]
    point_lines = Vector{NTuple{2, Float64}}[[_node_xy_m(nd)] for nd in attach]
    loop_lines = vcat(lines, point_lines)
    mesh_outer = [snap(p) for p in StructuralSizer._with_line_points_on_loop(
        [snap(p) for p in outer], loop_lines)]
    mesh_holes = [[snap(p) for p in StructuralSizer._with_line_points_on_loop(
        [snap(p) for p in h], loop_lines)] for h in holes]

    corners = Asap.Node[]
    for p in mesh_outer
        nd = _node_near(attach, p)
        push!(corners, nd === nothing ?
            Asap.Node([p[1] * u"m", p[2] * u"m", z * u"m"], :free) : nd)
    end
    interior_nodes = Asap.Node[nd for nd in attach
                               if _node_near(corners, _node_xy_m(nd)) === nothing]

    # Stiff column footprints, and drop panels at the drop depth.
    patches = Asap.ShellPatch[]
    column_nodes = Asap.Node[]
    c_min = Inf
    done = Set{UInt64}()
    base_sec = first(panels).section
    for si in unique(layout.slab_of_cell[ci] for ci in cells)
        slab = struc.slabs[si]
        cols = [col for col in _get_slab_columns(struc, slab)
                if col.c1 !== nothing && col.c2 !== nothing && !(objectid(col) in done) &&
                   1 <= col.vertex_idx <= length(nodes) &&
                   abs(_node_z_m(nodes[col.vertex_idx]) - z) <= 1e-3]
        isempty(cols) && continue
        foreach(col -> push!(done, objectid(col)), cols)
        append!(patches, StructuralSizer.build_slab_shell_patches(
            struc, cols, base_sec;
            drop_panel = slab.drop_panel,
            patch_stiffness_factor = FLAT_PLATE_PATCH_FACTOR,
            span_axis = StructuralSizer._get_span_axis(slab)))
        for col in cols
            push!(column_nodes, nodes[col.vertex_idx])
            c_min = min(c_min, ustrip(u"m", col.c1), ustrip(u"m", col.c2))
        end
    end
    # Column patches first: the first patch that holds a centroid wins.
    sort!(patches; by = p -> p.id === :col_patch ? 0 : 1)

    target = FLAT_PLATE_SHELL_TARGET_EDGE
    refine = isfinite(c_min) ? clamp(c_min / 2, 0.04, target / 2) : nothing
    raw = Asap.Shell(corners, base_sec;
                     holes = mesh_holes,
                     id = FP_SHELL_ID,
                     interior_nodes = interior_nodes,
                     interior_patches = patches,
                     interior_constrained_lines = lines,
                     edge_support_type = :free,
                     interior_support_type = :free,
                     target_edge_length = target * u"m",
                     refinement_edge_length = refine === nothing ? nothing : refine * u"m",
                     refinement_targets = isempty(column_nodes) ? :none : column_nodes)

    for el in raw
        el isa Asap.ShellTri3 || continue
        x, y = StructuralSizer._triangle_centroid(el)
        ci = cells[StructuralSizer._owning_panel(x, y, panels)]
        si = layout.slab_of_cell[ci]
        kind = el.id === :col_patch ? :col_patch : el.id === :drop_panel ? :drop : :slab
        el.id = kind === :col_patch ? FP_PATCH_ID : kind === :drop ? FP_DROP_ID : FP_SHELL_ID
        _set_flat_plate_tri_section!(el, kind, layout.thickness[si], layout.E[si],
                                     layout.ν, struc.slabs[si].drop_panel)
        push!(layout.slab_shells[si], el)
        push!(layout.slab_kinds[si], kind)
        push!(get!(() -> Asap.ShellTri3[], layout.cell_shells, ci), el)
        push!(shells, el)
    end
    return layout
end

"""
    _add_flat_plate_loads!(loads, layout, struc, params; use_patterns, combo)

One `AreaLoad` per flat-plate cell on its own triangles: factored dead and
live separately when `use_patterns`, else the enveloped pressure. The slab
past the centerlines stays a strip load on the cell's edge slot.
"""
function _add_flat_plate_loads!(loads, layout::FlatPlateShellLayout, struc::BuildingStructure,
                                params::DesignParameters; use_patterns::Bool,
                                combo::LoadCombination)
    layout.split = use_patterns
    for ci in sort!(collect(keys(layout.cell_shells)))
        tris = layout.cell_shells[ci]
        isempty(tris) && continue
        p = _flat_plate_cell_pressures(struc.cells[ci], params, use_patterns, combo)
        if use_patterns
            d = Asap.AreaLoad(tris, p.dead; id = FP_DEAD_ID)
            l = Asap.AreaLoad(tris, p.live; id = FP_LIVE_ID)
            push!(loads, d, l)
            layout.dead[ci] = d
            layout.live[ci] = l
        else
            t = Asap.AreaLoad(tris, p.total; id = FP_TOTAL_ID)
            push!(loads, t)
            layout.total[ci] = t
        end
    end
    return loads
end

"""Factored dead and live pressure of a cell, or its envelope, in pascals."""
function _flat_plate_cell_pressures(cell, params::DesignParameters, split::Bool,
                                    combo::LoadCombination)
    dead = cell.sdl + cell.self_weight
    if split
        return (dead = uconvert(u"Pa", combo.D * dead),
                live = uconvert(u"Pa", combo.L * cell.live_load))
    end
    return (total = uconvert(u"Pa", envelope_pressure(params.load_combinations, dead,
                                                      cell.live_load)),)
end

"""
    _sync_flat_plate_shells!(struc, params) -> Bool

Put each meshed slab's current thickness on its triangles and each cell's
current pressure on its load. Returns `true` when a section changed, which
changes the stiffness.
"""
function _sync_flat_plate_shells!(struc::BuildingStructure, params::DesignParameters)
    layout = flat_plate_shell_layout(struc)
    layout === nothing && return false
    changed = false
    for (si, tris) in layout.slab_shells
        h = Float64(ustrip(u"m", thickness(struc.slabs[si])))
        changed |= _set_flat_plate_slab_section!(layout, struc, si, h, layout.E[si])
    end
    combo = governing_combo(params)
    for (ci, _) in layout.cell_shells
        p = _flat_plate_cell_pressures(struc.cells[ci], params, layout.split, combo)
        if layout.split
            haskey(layout.dead, ci) && (layout.dead[ci].pressure = p.dead)
            haskey(layout.live, ci) && (layout.live[ci].pressure = p.live)
        else
            haskey(layout.total, ci) && (layout.total[ci].pressure = p.total)
        end
    end
    return changed
end

"""
Section of slab `si` at gross thickness `h` (m) and modulus `E` (Pa).
Returns `true` when it differs from what the triangles carried.
"""
function _set_flat_plate_slab_section!(layout::FlatPlateShellLayout, struc, si::Int,
                                       h::Float64, E::Float64)
    (abs(h - layout.thickness[si]) < 1e-9 && abs(E - layout.E[si]) < 1e-3) && return false
    layout.thickness[si] = h
    layout.E[si] = E
    dp = struc.slabs[si].drop_panel
    for (tri, kind) in zip(layout.slab_shells[si], layout.slab_kinds[si])
        _set_flat_plate_tri_section!(tri, kind, h, E, layout.ν, dp)
    end
    return true
end

"""True when the installed columns no longer match the column patches."""
function _flat_plate_mesh_stale(struc::BuildingStructure)
    layout = flat_plate_shell_layout(struc)
    layout === nothing && return false
    return _flat_plate_columns_key(struc, keys(layout.thickness)) != layout.columns_key
end

"""
    refresh_flat_plate_analysis!(struc, params)

Re-solve the building after a flat-plate stage. A column whose footprint
changed needs a new patch, so the model is rebuilt; otherwise this is
[`sync_asap!`](@ref).
"""
function refresh_flat_plate_analysis!(struc::BuildingStructure, params::DesignParameters)
    _flat_plate_mesh_stale(struc) && return update_analysis!(struc, :geometry; params)
    return sync_asap!(struc; params)
end

"""Unfactored pressures on flat-plate cell `ci`'s triangles: `(dead, live)` area loads."""
function _flat_plate_unfactored_cell_loads(layout::FlatPlateShellLayout, ci::Int, qD, qL)
    tris = layout.cell_shells[ci]
    return (Asap.AreaLoad(tris, uconvert(u"Pa", qD); id = FP_DEAD_ID),
            Asap.AreaLoad(tris, uconvert(u"Pa", qL); id = FP_LIVE_ID))
end
