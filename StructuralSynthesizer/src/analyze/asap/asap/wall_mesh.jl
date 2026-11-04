
"""Length in metres. Does not assume a unit when `x` is a bare number."""
function _length_metres(x, label::AbstractString)
    x isa Unitful.Quantity || throw(ArgumentError(
        "to_asap!: wall $label must be a length, got $(typeof(x))"))
    return ustrip(u"m", x)
end

"""
Concrete for one wall shell.

`Wall.concrete` when it is set, otherwise `params.materials.concrete`.
Neither field falls through to a preset grade.
"""
function _wall_shell_concrete(wall::Wall, params::DesignParameters)
    conc = wall.concrete
    conc === nothing && (conc = params.materials.concrete)
    conc === nothing && throw(ArgumentError(
        "to_asap!: wall concrete is unset and DesignParameters.materials.concrete " *
        "is unset. No modulus, Poisson's ratio, or density is assumed."))
    return conc
end

"""
Plan and elevation of one wall pier, in metres.

Bottom z is `skeleton.stories[wall.story].elevation`. Top z is that elevation
plus `base.L`. A missing story or a non-positive `base.L` throws. Thickness
and plan length must already be positive; they are not replaced.
"""
function _wall_pier_geometry(wall::Wall, skel::BuildingSkeleton)
    haskey(skel.stories, wall.story) || throw(ArgumentError(
        "to_asap!: wall story $(wall.story) is not in skeleton.stories. " *
        "The pier bottom is that story's elevation; no height is assumed."))
    L_m = _length_metres(wall.base.L, "base.L")
    L_m > 0 || throw(ArgumentError(
        "to_asap!: wall pier height base.L must be positive, got $(wall.base.L). " *
        "No height is assumed."))
    z_bot = _length_metres(skel.stories[wall.story].elevation, "story elevation")
    t_m = _length_metres(wall.thickness, "thickness")
    t_m > 0 || throw(ArgumentError(
        "to_asap!: wall thickness must be positive, got $(wall.thickness). " *
        "No thickness is assumed."))
    hypot(wall.x2 - wall.x1, wall.y2 - wall.y1) > 0 || throw(ArgumentError(
        "to_asap!: wall plan length must be positive " *
        "(($(wall.x1), $(wall.y1))–($(wall.x2), $(wall.y2)) m)."))
    return (x1=wall.x1, y1=wall.y1, x2=wall.x2, y2=wall.y2,
            z_bot=z_bot, z_top=z_bot + L_m, t_m=t_m)
end

"Plan match for an architectural vertex. A 0.9 mm move is a different point."
const _WALL_VERTEX_PLAN_TOL_M = 1e-6
"Elevation match for a story vertex. Same floor as the plan-edge check."
const _WALL_VERTEX_Z_TOL_M = 1e-4

"""Vertex whose architectural coordinates are `x, y, z`, or `nothing`."""
function _vertex_at_architectural(vc::Matrix{Float64}, x, y, z)
    hit = nothing
    for i in 1:size(vc, 1)
        abs(vc[i, 3] - z) <= _WALL_VERTEX_Z_TOL_M || continue
        hypot(vc[i, 1] - x, vc[i, 2] - y) <= _WALL_VERTEX_PLAN_TOL_M || continue
        hit === nothing || return nothing
        hit = i
    end
    return hit
end

"Plan position, in metres, of one frame node."
function _frame_plan_xy(frame_nodes, vidx::Int)
    p = frame_nodes[vidx].position
    return (ustrip(u"m", p[1]), ustrip(u"m", p[2]))
end

"""
Plan corners of one pier on the frame nodes its ends belong to.

`nothing` when the skeleton has no geometry cache, or either base end is not
on an architectural vertex: the stated `wall.x1` … `wall.y2` line is meshed,
and the 1 mm snap still applies.
Both base ends on vertices, with no vertex at the top of either column,
throw. The shell would otherwise miss the column above.
"""
function _structural_pier_corners(struc::BuildingStructure, span, frame_nodes)
    geom = struc.skeleton.geometry
    geom === nothing && return nothing
    vc = geom.vertex_coords
    size(vc, 1) == length(frame_nodes) || return nothing
    bl = _vertex_at_architectural(vc, span.x1, span.y1, span.z_bot)
    br = _vertex_at_architectural(vc, span.x2, span.y2, span.z_bot)
    (bl === nothing || br === nothing) && return nothing
    tl = _vertex_at_architectural(vc, span.x1, span.y1, span.z_top)
    tr = _vertex_at_architectural(vc, span.x2, span.y2, span.z_top)
    if tl === nothing || tr === nothing
        throw(ArgumentError(
            "to_asap!: wall ($(span.x1), $(span.y1))–($(span.x2), $(span.y2)) m " *
            "sits on frame vertices at z = $(span.z_bot) m, but z = $(span.z_top) m " *
            "has no vertex on that column line. The shell cannot share the column."))
    end
    return (
        bl=_frame_plan_xy(frame_nodes, bl),
        br=_frame_plan_xy(frame_nodes, br),
        tl=_frame_plan_xy(frame_nodes, tl),
        tr=_frame_plan_xy(frame_nodes, tr),
    )
end

"Plan position at parameter `(s, r)` on the pier. `s` runs along the wall, `r` up the story."
function _pier_plan_at(corners, s::Real, r::Real)
    s = Float64(s)
    r = Float64(r)
    xb = (1 - s) * corners.bl[1] + s * corners.br[1]
    yb = (1 - s) * corners.bl[2] + s * corners.br[2]
    xt = (1 - s) * corners.tl[1] + s * corners.tr[1]
    yt = (1 - s) * corners.tl[2] + s * corners.tr[2]
    return ((1 - r) * xb + r * xt, (1 - r) * yb + r * yt)
end

"""
    _mesh_wall_shells(struc, params, frame_nodes, existing_shells)
      -> (shells, wall_nodes, shells_by_wall)

Mesh `struc.walls` into `ShellTri3` elements on `frame_nodes`.

Same panel split as `StructuralSizer` `_build_asap_wall_model`. `mesh_div`
quads run along the wall and `mesh_rows` quads run up the story; each quad is
two triangles. The defaults are [`WALL_MESH_DIV`](@ref) and
[`WALL_MESH_ROWS`](@ref). A placed wall node reuses an
existing frame, slab-mesh, or wall node when the 3D distance is at most 1 mm.
A node farther than 1 mm stays separate. Two existing nodes at the same
nearest distance within that tolerance throw `ArgumentError`.

A wall end that still sits on its architectural vertex is drawn through the
frame node at that vertex. A column centerline offset has already moved that
node, and the offset at the top of the story can differ from the offset at
the base, so the pier follows the column line instead of the grid line. An
end that has been moved off its vertex keeps the stated coordinate, and the
1 mm rule decides whether a frame node is reused.

This mesh adds NO supports. Every node it creates is `:free` (all dof true),
and a reused frame, slab-mesh, or wall node keeps the dof vector it already
had — a fixed foundation vertex stays fixed because the frame marked it a
support, not because this mesh touched it. A wall is therefore held only
through the frame/slab nodes it shares, or the story rigid diaphragm it joins
via `_join_wall_nodes_to_rigid_diaphragm!`. A wall that meets no support, no
frame joint, and no diaphragm is intentionally left unattached; the resulting
model is singular, which is the correct signal that the wall is not connected.

An empty `walls` vector returns empty collections and does not read materials.
`shells_by_wall[i]` is the triangles of `struc.walls[i]`, in mesh order.
"""
function _mesh_wall_shells(struc::BuildingStructure,
                           params::DesignParameters,
                           frame_nodes::Vector{Asap.Node},
                           existing_shells;
                           mesh_div::Int=WALL_MESH_DIV,
                           mesh_rows::Int=WALL_MESH_ROWS)
    isempty(struc.walls) && return Asap.ShellTri3[], Asap.Node[], Vector{Asap.ShellTri3}[]

    # Geometry and material are checked before any node is created, so a throw
    # does not leave a half-mutated frame node.
    spans = map(w -> _wall_pier_geometry(w, struc.skeleton), struc.walls)
    concretes = map(w -> _wall_shell_concrete(w, params), struc.walls)

    # Node-share tolerance.
    tol = 1e-3
    existing = Asap.Node[]
    known = Set{UInt64}()
    # One object is one candidate. A frame corner reused by the slab mesh
    # must not look like two nodes at the same point.
    function _keep!(nd::Asap.Node)
        id = objectid(nd)
        id in known && return nothing
        push!(known, id)
        push!(existing, nd)
        return nothing
    end
    for nd in frame_nodes
        _keep!(nd)
    end
    for shell in existing_shells
        for nd in shell.nodes
            _keep!(nd)
        end
    end

    shells = Asap.ShellTri3[]
    shells_by_wall = [Asap.ShellTri3[] for _ in struc.walls]
    wall_nodes = Asap.Node[]
    seen = Set{UInt64}()
    (mesh_div >= 1 && mesh_rows >= 1) || throw(ArgumentError(
        "to_asap!: wall mesh_div and mesh_rows must be ≥ 1 " *
        "(got $mesh_div × $mesh_rows)."))
    nx = mesh_div
    ny = mesh_rows

    """Nearest existing node within `tol`, or `nothing` when all are farther."""
    function _nearest_existing(x, y, z)
        tol2 = tol * tol
        best = nothing
        best_d2 = tol2
        tied = false
        for nd in existing
            p = nd.position
            dx = ustrip(u"m", p[1]) - x
            dy = ustrip(u"m", p[2]) - y
            dz = ustrip(u"m", p[3]) - z
            d2 = dx * dx + dy * dy + dz * dz
            d2 > tol2 && continue
            if best === nothing || d2 < best_d2
                best = nd
                best_d2 = d2
                tied = false
            elseif d2 == best_d2
                tied = true
            end
        end
        tied && throw(ArgumentError(
            "to_asap!: wall node at ($x, $y, $z) m is equally near two or " *
            "more existing nodes within $(tol) m"))
        return best
    end

    function wall_node!(x, y, z)
        nd = _nearest_existing(x, y, z)
        # This mesh adds no supports: a node it creates is always :free. A
        # reused frame, slab, or wall node keeps the dof vector it already has.
        if nd === nothing
            nd = Asap.Node([x, y, z] .* u"m", :free, :wall)
            _keep!(nd)
        end
        if !(objectid(nd) in seen)
            push!(seen, objectid(nd))
            push!(wall_nodes, nd)
        end
        return nd
    end

    for (iw, (span, conc)) in enumerate(zip(spans, concretes))
        sec_t = span.t_m * u"m"
        sec_E = uconvert(u"Pa", conc.E)
        ν = conc.ν
        ρ = ustrip(u"kg/m^3", conc.ρ)
        # Column offsets live on the frame nodes. Follow those nodes when the
        # wall still ends on its architectural vertices.
        corners = _structural_pier_corners(struc, span, frame_nodes)
        for (s0, s1, r0, r1) in wall_panel_quads(nx, ny)
            # Top and base share a plan line when the wall is not on frame
            # vertices. On frame vertices the top offset can differ, so each
            # corner of the quad takes its own plan position.
            xb0, yb0, xb1, yb1, xt1, yt1, xt0, yt0 = if corners === nothing
                x0 = span.x1 + (span.x2 - span.x1) * s0
                y0 = span.y1 + (span.y2 - span.y1) * s0
                x1 = span.x1 + (span.x2 - span.x1) * s1
                y1 = span.y1 + (span.y2 - span.y1) * s1
                (x0, y0, x1, y1, x1, y1, x0, y0)
            else
                p0 = _pier_plan_at(corners, s0, r0)
                p1 = _pier_plan_at(corners, s1, r0)
                q1 = _pier_plan_at(corners, s1, r1)
                q0 = _pier_plan_at(corners, s0, r1)
                (p0[1], p0[2], p1[1], p1[2], q1[1], q1[2], q0[1], q0[2])
            end
            z0 = span.z_bot + (span.z_top - span.z_bot) * r0
            z1 = span.z_bot + (span.z_top - span.z_bot) * r1
            nb0 = wall_node!(xb0, yb0, z0)
            nb1 = wall_node!(xb1, yb1, z0)
            nt1 = wall_node!(xt1, yt1, z1)
            nt0 = wall_node!(xt0, yt0, z1)
            t1 = Asap.ShellTri3((nb0, nb1, nt1), sec_t, sec_E, ν; id=:wall, ρ=ρ)
            t2 = Asap.ShellTri3((nb0, nt1, nt0), sec_t, sec_E, ν; id=:wall, ρ=ρ)
            push!(shells, t1, t2)
            push!(shells_by_wall[iw], t1, t2)
        end
    end
    return shells, wall_nodes, shells_by_wall
end

"""
    _apply_stated_cracked_wall_stiffness!(wall_shells, params) -> wall_shells

Scale wall-shell `E` by 0.35 when `params.wall_inputs` states that the model
uses cracked-section stiffness.

ACI 318-19 Table 6.6.3.1.1(a) (corpus `aci-318-19`, PDF p. 78) permits `0.35 Ig`
for a cracked wall, `1.0 Ag` for axial deformation, and `bw·h` for shear.
A `ShellTri3` has one modulus, so this factor scales flexural, axial, and
shear stiffness together. The axial and shear reductions are not the table.
§6.6.3.1.1's sustained-load divisor `(1 + βds)` is not applied.

No shells and a cracked-section statement throw. A gross-section statement
(`model_uses_cracked_section_stiffness == false`) or missing `wall_inputs`
leaves `E` unchanged.
"""
function _apply_stated_cracked_wall_stiffness!(wall_shells, params::DesignParameters)
    inputs = params.wall_inputs
    (inputs === nothing || !inputs.model_uses_cracked_section_stiffness) && return wall_shells
    isempty(wall_shells) && throw(ArgumentError(
        "to_asap!: wall_inputs states cracked-section stiffness and the " *
        "model has no wall shells."))
    # ACI 318-19 Table 6.6.3.1.1(a) — 0.35 Ig for a cracked wall. PDF p. 78.
    for sh in wall_shells
        sh.E *= 0.35
    end
    return wall_shells
end

"""Story elevations present on the skeleton, as 1 mm keys."""
function _story_elevation_keys(skel::BuildingSkeleton)
    keys = Set{Int}()
    for (_, story) in skel.stories
        z_m = _length_metres(story.elevation, "story elevation")
        push!(keys, round(Int, z_m * 1000))
    end
    return keys
end

"""
Add wall nodes that sit on a story elevation to an existing rigid-link set.

Does nothing when `links` is empty (no diaphragm was built) or `wall_nodes`
is empty. The master is the one already elected for that elevation. The
release rule matches [`_build_rigid_diaphragm_links`](@ref): tie `(u_x, u_y,
θ_z)` only when that DOF is free on both nodes. A fixed base node is skipped.
"""
function _join_wall_nodes_to_rigid_diaphragm!(links::Vector{Asap.RigidLink},
                                              skel::BuildingSkeleton,
                                              wall_nodes::Vector{Asap.Node})
    isempty(links) && return links
    isempty(wall_nodes) && return links

    story_z = _story_elevation_keys(skel)
    master_at = Dict{Int, Asap.Node}()
    linked = Set{UInt64}()
    for link in links
        push!(linked, objectid(link.nodeA))
        push!(linked, objectid(link.nodeB))
        zk = round(Int, ustrip(u"m", link.nodeA.position[3]) * 1000)
        zk in story_z || continue
        master_at[zk] = link.nodeA
    end

    tied_indices = (1, 2, 6)
    for nd in wall_nodes
        objectid(nd) in linked && continue
        zk = round(Int, ustrip(u"m", nd.position[3]) * 1000)
        haskey(master_at, zk) || continue
        master = master_at[zk]
        nd === master && continue
        (length(nd.dof) >= 2 && nd.dof[1] && nd.dof[2]) || continue
        release = ntuple(6) do i
            (i in tied_indices) || return true
            (master.dof[i] && nd.dof[i]) ? false : true
        end
        push!(links, Asap.RigidLink(master, nd;
                                    release=release,
                                    id=:rigid_diaphragm))
        push!(linked, objectid(nd))
    end
    return links
end

"""
    require_diaphragm_node_stiffness(links, elements, shells)

Throw if a plan-only rigid link uses a node that is not already on a
column, beam, or wall shell.

The diaphragm ties `(u_x, u_y, θ_z)` and leaves `(u_z, θ_x, θ_y)` free on
both ends. Those three DOFs are not carried by the constraint, so each end
needs stiffness of its own. A node created only to be the master has none,
and the reduced stiffness is singular. A wall-line frame edge with zero
area and zero inertia does not count. A node whose vertical and bending
DOFs are already supported does.
"""
function require_diaphragm_node_stiffness(links, elements, shells)
    stiff = Set{UInt64}()
    for el in elements
        _frame_stabilizes_free_gravity_dofs(el) || continue
        push!(stiff, objectid(el.nodeStart))
        push!(stiff, objectid(el.nodeEnd))
    end
    for sh in shells
        (sh.thickness > 0 && sh.E > 0) || continue
        for nd in sh.nodes
            push!(stiff, objectid(nd))
        end
    end
    for link in links
        _plan_only_diaphragm_tie(link) || continue
        for nd in (link.nodeA, link.nodeB)
            _gravity_dofs_already_supported(nd) && continue
            objectid(nd) in stiff && continue
            p = nd.position
            x = ustrip(u"m", p[1])
            y = ustrip(u"m", p[2])
            z = ustrip(u"m", p[3])
            throw(ArgumentError(
                "rigid diaphragm node at ($x, $y, $z) m keeps u_z, θ_x, and " *
                "θ_y free and is not a node of a column, beam, or wall shell. " *
                "A node created only to hold the diaphragm makes the model singular."))
        end
    end
    return nothing
end

"Column or beam with area and bending stiffness. A zero wall-line section does not."
function _frame_stabilizes_free_gravity_dofs(el)
    sec = el.section
    ustrip(u"m^2", sec.A) > 0 || return false
    return ustrip(u"m^4", sec.Ix) > 0 || ustrip(u"m^4", sec.Iy) > 0
end

"True when the link ties plan motion and leaves vertical and bending DOFs free."
function _plan_only_diaphragm_tie(link::Asap.RigidLink)
    rel = link.release
    length(rel) == 6 || return false
    ties_plan = !rel[1] || !rel[2] || !rel[6]
    releases_gravity = rel[3] && rel[4] && rel[5]
    return ties_plan && releases_gravity
end

"True when u_z, θ_x, and θ_y are supports, so they are not free unknowns."
function _gravity_dofs_already_supported(nd::Asap.Node)
    dof = nd.dof
    length(dof) >= 5 || return false
    return !dof[3] && !dof[4] && !dof[5]
end

