# Semirigid floors: story forces on the membrane mesh, accidental torsion as
# nodal forces, and the center-of-mass displacement read from the
# seismic-system walls.
#
# ASCE 7-22 §12.3.1 and §12.7.3 (corpus: asce-7-22, PDF pages 179 and 184)
# model the diaphragm with its stiffness. §12.8.4 (PDF page 187) distributes
# the story shear to the vertical elements of the seismic force-resisting
# system through that model. Commentary C12.8.4.2 (PDF page 727): on a
# semirigid diaphragm the accidental torsional moment "is decoupled into
# nodal moments or forces that are placed throughout the diaphragm".
# Commentary C12.8.6 (PDF page 730): where semirigid modeling is used and the
# design story drift is computed at the center of mass without the diaphragm
# deformation, the displacement there may come from the displacements of the
# vertical elements of the seismic force-resisting system.

"""
    semirigid_sfrs!(struc, lateral::LateralDesign) -> SemirigidDiaphragmLayout

Record, at each floor of the semirigid mesh, the top nodes of the walls the
declared seismic systems name ([`seismic_members`](@ref)) and the plan axis.
The center-of-mass displacement is read from those nodes
([`_semirigid_disp_at`](@ref)).

Each node is weighted by the wall length it stands for: half of each gap to
its neighbours along the wall top. A floor no seismic-system wall reaches
gets no nodes, and reading it throws. A system that names frames throws:
only walls are read here.
"""
function semirigid_sfrs!(struc::BuildingStructure, lateral::LateralDesign)
    layout = _require_semirigid_layout(struc)
    walls = Set{Int}()
    for system in (lateral.system_x, lateral.system_y)
        members = seismic_members(struc, system)
        (isempty(members.beams) && isempty(members.columns)) || throw(ArgumentError(
            "semirigid diaphragm: the system $(typeof(system)) includes frames. The " *
            "center-of-mass displacement is read from seismic-system walls only."))
        union!(walls, members.walls)
    end
    isempty(walls) && throw(ArgumentError(
        "semirigid diaphragm: the declared systems name no walls."))
    drift = SemirigidDriftNodes[]
    for floor in layout.floors
        nodes = Asap.Node[]
        weights = Float64[]
        for i in sort!(collect(walls))
            edge = _wall_top_stations(struc, i, floor.elevation_m)
            length(edge) >= 2 || continue
            s = first.(edge)
            for k in eachindex(edge)
                lo = k == 1 ? s[1] : 0.5 * (s[k - 1] + s[k])
                hi = k == length(edge) ? s[end] : 0.5 * (s[k] + s[k + 1])
                push!(nodes, edge[k][2])
                push!(weights, hi - lo)
            end
        end
        push!(drift, SemirigidDriftNodes(floor.elevation_m, nodes, weights))
    end
    layout.plan_axis = lateral.plan_axis
    layout.drift_nodes = drift
    return layout
end

"""Wall-shell nodes at the top of wall `i` when that top is at `elevation_m`, sorted along the wall."""
function _wall_top_stations(struc, i::Int, elevation_m)
    geom = _wall_pier_geometry(struc.walls[i], struc.skeleton)
    abs(geom.z_top - elevation_m) <= WALL_CUT_ZTOL_M || return Tuple{Float64, Asap.Node}[]
    pier = _pier_by_wall_index(struc.wall_mesh, i)
    L = hypot(geom.x2 - geom.x1, geom.y2 - geom.y1)
    ux, uy = (geom.x2 - geom.x1) / L, (geom.y2 - geom.y1) / L
    seen = Set{UInt64}()
    edge = Tuple{Float64, Asap.Node}[]
    for sh in pier.shells, nd in sh.nodes
        abs(_z(nd) - elevation_m) <= WALL_CUT_ZTOL_M || continue
        objectid(nd) in seen && continue
        push!(seen, objectid(nd))
        x, y = _xy(nd)
        push!(edge, ((x - geom.x1) * ux + (y - geom.y1) * uy, nd))
    end
    sort!(edge; by=first)
    return edge
end

"""The layout of a floor with no rigid master: flexible wall lines or the semirigid membrane."""
function _require_masterless_layout(struc, axis)
    struc.diaphragm_layout isa SemirigidDiaphragmLayout || return _require_flexible_layout(struc, axis)
    layout = struc.diaphragm_layout
    (layout.plan_axis !== nothing && maximum(abs.(layout.plan_axis .- axis)) <= 1e-12) ||
        throw(ArgumentError(
            "semirigid diaphragm: the seismic-system walls were recorded on plan axis " *
            "$(layout.plan_axis) and the analysis uses $(axis)."))
    return layout
end

_floor_disp_at(u, layout::FlexibleDiaphragmLayout, z, direction, p) =
    _flexible_disp_at(u, layout, z, direction, p)
_floor_disp_at(u, layout::SemirigidDiaphragmLayout, z, direction, p) =
    _semirigid_disp_at(u, layout, z, direction, p)

"""The stored semirigid layout."""
function _require_semirigid_layout(struc)
    layout = struc.diaphragm_layout
    layout isa SemirigidDiaphragmLayout || throw(ArgumentError(
        "semirigid diaphragm: the membrane floor is not built. Call " *
        "to_asap! with diaphragms=:semirigid."))
    return layout
end

"""The meshed floor at `elevation_m`."""
function _semirigid_floor_at(layout::SemirigidDiaphragmLayout, elevation_m)
    for floor in layout.floors
        abs(floor.elevation_m - elevation_m) <= _SEMIRIGID_NODE_TOL_M && return floor
    end
    throw(ArgumentError(
        "semirigid diaphragm: no slab is meshed at $(elevation_m) m, and a story " *
        "force is applied there."))
end

# ------------------------------------------------------------------------------
# Story forces
# ------------------------------------------------------------------------------

"""
Story forces and torsion of every level on the membrane floors.

ELF levels: each node takes the story force in proportion to the seismic
weight it carries ([`_semirigid_node_weights`](@ref)), and the moment `Mz` as
in-plane forces in proportion to that weight times the distance from the
weighted centroid, square to the radius ([`_semirigid_torsion_forces`](@ref)).

Wind levels: the force goes on the exterior floor edge by projected width,
and the moment about the exterior-loop centroid `centroids[i]` is completed
by a linear variation along those edges ([`_semirigid_wind_forces`](@ref)).
"""
function _semirigid_story_loads(struc, levels, Fx, Fy, Mz; force_id::Symbol,
                                centroids=nothing)
    layout = _require_semirigid_layout(struc)
    loads = Asap.AbstractLoad[]
    for i in eachindex(levels)
        (Fx[i] == 0.0 && Fy[i] == 0.0 && Mz[i] == 0.0) && continue
        floor = _semirigid_floor_at(layout, levels[i].elevation_m)
        f = if levels[i] isa ElfLevel
            w = _semirigid_node_weights(struc, floor, levels[i])
            _semirigid_weight_forces(floor, w, Float64(Fx[i]), Float64(Fy[i]), Float64(Mz[i]))
        else
            centroids === nothing && throw(ArgumentError(
                "semirigid diaphragm: a wind level needs the point its moment is about."))
            _semirigid_wind_forces(floor, Float64(Fx[i]), Float64(Fy[i]),
                                   Float64(Mz[i]), centroids[i])
        end
        for (k, nd) in enumerate(floor.nodes)
            fx, fy = f[k]
            (fx == 0.0 && fy == 0.0) && continue
            push!(loads, Asap.NodeForce(nd, [fx * u"kN", fy * u"kN", 0.0 * u"kN"], force_id))
        end
    end
    isempty(loads) && throw(ArgumentError(
        "semirigid diaphragm: a case produced no story force and no torsion."))
    return loads
end

"""
Seismic weight [kN] at each node of `floor`, in `floor.nodes` order.

A slab cell's effective seismic weight is spread over its triangles by area,
a third to each corner. Wall and frame self-weight
([`_elf_weight_items`](@ref)) on this level goes to the floor node at a point
item, and along the floor nodes of a wall by tributary length. The total must
match the level's ELF weight.
"""
function _semirigid_node_weights(struc, floor::SemirigidFloor, level::ElfLevel)
    index = IdDict{Asap.Node, Int}(nd => k for (k, nd) in enumerate(floor.nodes))
    w = zeros(Float64, length(floor.nodes))
    cell_by_face = Dict(c.face_idx => c for c in struc.cells)
    face_area = Dict{Int, Float64}()
    for (sh, face) in zip(floor.shells, floor.face_of_shell)
        face_area[face] = get(face_area, face, 0.0) + sh.area
    end
    for (sh, face) in zip(floor.shells, floor.face_of_shell)
        cell = get(cell_by_face, face, nothing)
        cell === nothing && throw(ArgumentError(
            "semirigid diaphragm: slab face $face has no load cell."))
        # ASCE 7-22 §12.7.2 (corpus: asce-7-22, PDF page 184), the same weight ELF uses.
        share = ustrip(u"kN", effective_seismic_weight(cell)) * sh.area / face_area[face] / 3
        for nd in sh.nodes
            w[index[nd]] += share
        end
    end
    elevs = _elf_story_elevations(struc.skeleton)
    key = _elf_elevation_key(level.elevation_m, elevs)
    items, _ = _elf_weight_items(struc, elevs)
    for (k, wt, a, b) in items
        k == key || continue
        _deposit_on_floor!(w, floor, a, b, wt)
    end
    total = sum(w)
    abs(total - level.weight_kN) <= 1e-6 * max(1.0, level.weight_kN) || throw(ArgumentError(
        "semirigid diaphragm: the floor at $(level.elevation_m) m carries $(total) kN on " *
        "its nodes and the level weight is $(level.weight_kN) kN. A load cell or a " *
        "self-weight item is not on the membrane floor."))
    return w
end

"""Add `wt` kN at plan point `a`, or spread uniformly from `a` to `b`, onto floor nodes."""
function _deposit_on_floor!(w, floor::SemirigidFloor, a, b, wt)
    tol = _SEMIRIGID_NODE_TOL_M
    L = hypot(b[1] - a[1], b[2] - a[2])
    if L <= tol
        for (k, nd) in enumerate(floor.nodes)
            x, y = _xy(nd)
            if hypot(x - a[1], y - a[2]) <= tol
                w[k] += wt
                return w
            end
        end
        throw(ArgumentError(
            "semirigid diaphragm: self-weight at ($(a[1]), $(a[2])) m on the floor at " *
            "$(floor.elevation_m) m has no floor node within 1 mm."))
    end
    ex, ey = (b[1] - a[1]) / L, (b[2] - a[2]) / L
    on = Tuple{Float64, Int}[]
    for (k, nd) in enumerate(floor.nodes)
        x, y = _xy(nd)
        s = (x - a[1]) * ex + (y - a[2]) * ey
        d = abs(-(x - a[1]) * ey + (y - a[2]) * ex)
        (d <= tol && -tol <= s <= L + tol) && push!(on, (s, k))
    end
    sort!(on; by=first)
    (length(on) >= 2 && on[1][1] <= tol && on[end][1] >= L - tol) || throw(ArgumentError(
        "semirigid diaphragm: a wall from ($(a[1]), $(a[2])) to ($(b[1]), $(b[2])) m is " *
        "not along floor nodes at $(floor.elevation_m) m. Its self-weight has nowhere to go."))
    s = first.(on)
    span = s[end] - s[1]
    for j in eachindex(on)
        lo = j == 1 ? s[1] : 0.5 * (s[j - 1] + s[j])
        hi = j == length(on) ? s[end] : 0.5 * (s[j] + s[j + 1])
        w[on[j][2]] += wt * (hi - lo) / span
    end
    return w
end

"""
Nodal `(fx, fy)` [kN]: `(Fx, Fy)` by weight, and `Mz` by weight times distance.

With `r` the node's offset from the weighted centroid and `J = Σ w r²`, the
torsion force is `Mz w (−r_y, r_x) / J`. Those forces sum to zero and their
moment about any point is `Mz`.
"""
function _semirigid_weight_forces(floor::SemirigidFloor, w, Fx, Fy, Mz)
    W = sum(w)
    W > 0 || throw(ArgumentError(
        "semirigid diaphragm: the floor at $(floor.elevation_m) m has no seismic weight."))
    xc = sum(w[k] * _xy(nd)[1] for (k, nd) in enumerate(floor.nodes)) / W
    yc = sum(w[k] * _xy(nd)[2] for (k, nd) in enumerate(floor.nodes)) / W
    f = [(Fx * w[k] / W, Fy * w[k] / W) for k in eachindex(w)]
    Mz == 0.0 && return f
    return _add_torsion!(f, floor, w, xc, yc, Mz)
end

function _add_torsion!(f, floor, w, xc, yc, Mz)
    J = 0.0
    for (k, nd) in enumerate(floor.nodes)
        x, y = _xy(nd)
        J += w[k] * ((x - xc)^2 + (y - yc)^2)
    end
    J > 0 || throw(ArgumentError(
        "semirigid diaphragm: the floor at $(floor.elevation_m) m has no polar moment " *
        "to carry the torsion."))
    for (k, nd) in enumerate(floor.nodes)
        x, y = _xy(nd)
        c = Mz * w[k] / J
        f[k] = (f[k][1] - c * (y - yc), f[k][2] + c * (x - xc))
    end
    return f
end

"""
Nodal `(fx, fy)` [kN] for a wind level on the exterior floor edge.

Each exterior boundary edge of the mesh with outward normal `n` and length
`ℓ` gives each end `ℓ|n_x|/2` of X width and `ℓ|n_y|/2` of Y width. `Fx` is
spread by X width and `Fy` by Y width. The moment those leave about `c` is
then made up to `Mz` by a force varying linearly along the same edges with
no net force.

# Engineering judgment
Figure 27.3-8 gives the torsional cases as a resultant with an eccentricity,
not a pressure shape (corpus: asce-7-22, PDF page 353). The linear variation
is the placement chosen for it; windward and leeward walls share the force
by projected width, not by their separate Cp.
"""
function _semirigid_wind_forces(floor::SemirigidFloor, Fx, Fy, Mz, c)
    tx, ty = _exterior_edge_widths(floor)
    Tx, Ty = sum(tx), sum(ty)
    (Fx == 0.0 || Tx > 0) && (Fy == 0.0 || Ty > 0) || throw(ArgumentError(
        "semirigid diaphragm: the floor at $(floor.elevation_m) m has no exterior edge " *
        "facing the wind."))
    n = length(floor.nodes)
    fx = [Fx == 0.0 ? 0.0 : Fx * tx[k] / Tx for k in 1:n]
    fy = [Fy == 0.0 ? 0.0 : Fy * ty[k] / Ty for k in 1:n]
    dx = [_xy(nd)[1] - c[1] for nd in floor.nodes]
    dy = [_xy(nd)[2] - c[2] for nd in floor.nodes]
    M0 = sum(dx[k] * fy[k] - dy[k] * fx[k] for k in 1:n)
    ΔM = Mz - M0
    if abs(ΔM) > 1e-12 * max(1.0, abs(Mz), abs(M0))
        mx = -dy
        my = dx
        m̄x = Tx > 0 ? sum(tx .* mx) / Tx : 0.0
        m̄y = Ty > 0 ? sum(ty .* my) / Ty : 0.0
        D = sum(tx .* (mx .- m̄x) .^ 2) + sum(ty .* (my .- m̄y) .^ 2)
        D > 0 || throw(ArgumentError(
            "semirigid diaphragm: the exterior edge at $(floor.elevation_m) m cannot " *
            "carry a wind torsion."))
        β = ΔM / D
        fx .+= β .* tx .* (mx .- m̄x)
        fy .+= β .* ty .* (my .- m̄y)
    end
    return [(fx[k], fy[k]) for k in 1:n]
end

"""
Projected widths [m] at each floor node from the exterior boundary of the mesh.

Boundary edges belong to one triangle. They are chained into loops, and the
loop with the largest area is the exterior; an opening's loop takes no wind.
"""
function _exterior_edge_widths(floor::SemirigidFloor)
    index = IdDict{Asap.Node, Int}(nd => k for (k, nd) in enumerate(floor.nodes))
    count = Dict{Tuple{Int, Int}, Int}()
    directed = Dict{Tuple{Int, Int}, Tuple{Int, Int}}()
    for sh in floor.shells
        ids = [index[nd] for nd in sh.nodes]
        p = [_xy(nd) for nd in sh.nodes]
        ccw = (p[2][1] - p[1][1]) * (p[3][2] - p[1][2]) -
              (p[3][1] - p[1][1]) * (p[2][2] - p[1][2]) > 0
        ccw || reverse!(ids)
        for j in 1:3
            a, b = ids[j], ids[mod1(j + 1, 3)]
            key = minmax(a, b)
            count[key] = get(count, key, 0) + 1
            directed[key] = (a, b)
        end
    end
    nxt = Dict{Int, Int}()
    for (key, m) in count
        m == 1 || continue
        a, b = directed[key]
        haskey(nxt, a) && throw(ArgumentError(
            "semirigid diaphragm: the floor boundary at $(floor.elevation_m) m touches " *
            "itself at a node."))
        nxt[a] = b
    end
    loops = Vector{Int}[]
    left = Set(keys(nxt))
    while !isempty(left)
        start = first(left)
        loop = Int[start]
        delete!(left, start)
        k = nxt[start]
        while k != start
            push!(loop, k)
            delete!(left, k)
            k = nxt[k]
        end
        push!(loops, loop)
    end
    area(loop) = 0.5 * sum(_xy(floor.nodes[loop[j]])[1] * _xy(floor.nodes[loop[mod1(j + 1, length(loop))]])[2] -
                           _xy(floor.nodes[loop[mod1(j + 1, length(loop))]])[1] * _xy(floor.nodes[loop[j]])[2]
                           for j in eachindex(loop))
    exterior = loops[argmax([abs(area(l)) for l in loops])]
    tx = zeros(Float64, length(floor.nodes))
    ty = zeros(Float64, length(floor.nodes))
    for j in eachindex(exterior)
        a, b = exterior[j], exterior[mod1(j + 1, length(exterior))]
        (xa, ya), (xb, yb) = _xy(floor.nodes[a]), _xy(floor.nodes[b])
        ℓ = hypot(xb - xa, yb - ya)
        # The exterior loop runs counterclockwise, so the outward normal of
        # a → b is (dy, −dx)/ℓ. Its absolute components give the widths.
        nx, ny = (yb - ya) / ℓ, -(xb - xa) / ℓ
        for k in (a, b)
            tx[k] += 0.5 * ℓ * abs(nx)
            ty[k] += 0.5 * ℓ * abs(ny)
        end
    end
    return tx, ty
end

# ------------------------------------------------------------------------------
# Center-of-mass displacement
# ------------------------------------------------------------------------------

"""
Plan rigid motion `(a, b, r)` fitted to the seismic-system wall tops, about `p`.

Weighted least squares on `u_x = a − r (y − p_y)` and `u_y = b + r (x − p_x)`.
`a` and `b` are the fitted displacement at `p` [m]; `r` is the rotation.
"""
function _semirigid_fit(u, dn::SemirigidDriftNodes, p)
    isempty(dn.nodes) && throw(ArgumentError(
        "semirigid diaphragm: no seismic-system wall reaches the floor at " *
        "$(dn.elevation_m) m, so its center-of-mass displacement is not read."))
    A = zeros(3, 3)
    rhs = zeros(3)
    for (nd, w) in zip(dn.nodes, dn.weights)
        x, y = _xy(nd)
        dx, dy = x - p[1], y - p[2]
        g = nd.globalID
        ux, uy = u[g[1]], u[g[2]]
        # Rows of the two equations for this node: [1 0 −dy] and [0 1 dx].
        A[1, 1] += w
        A[2, 2] += w
        A[1, 3] -= w * dy
        A[2, 3] += w * dx
        A[3, 3] += w * (dx^2 + dy^2)
        rhs[1] += w * ux
        rhs[2] += w * uy
        rhs[3] += w * (-dy * ux + dx * uy)
    end
    A[3, 1] = A[1, 3]
    A[3, 2] = A[2, 3]
    return Tuple(Symmetric(A) \ rhs)
end

function _semirigid_drift_nodes_at(layout::SemirigidDiaphragmLayout, elevation_m)
    for dn in layout.drift_nodes
        abs(dn.elevation_m - elevation_m) <= _SEMIRIGID_NODE_TOL_M && return dn
    end
    throw(ArgumentError(
        "semirigid diaphragm: the seismic-system walls are not recorded at " *
        "$(elevation_m) m. The lateral stage records them (semirigid_sfrs!)."))
end

"""
Displacement [m] along plan axis `direction` at plan point `p` on the floor at
`elevation_m`, from the rigid motion fitted to the seismic-system wall tops.
The diaphragm's own in-plane deformation is not in it (C12.8.6).
"""
function _semirigid_disp_at(u, layout::SemirigidDiaphragmLayout, elevation_m::Real,
                            direction::Symbol, p)
    layout.plan_axis === nothing && throw(ArgumentError(
        "semirigid diaphragm: the plan axis is not recorded (semirigid_sfrs!)."))
    d = plan_axis_vector(layout.plan_axis, direction)
    a, b, _ = _semirigid_fit(u, _semirigid_drift_nodes_at(layout, elevation_m), p)
    return a * d[1] + b * d[2]
end

"""
Story drifts at the two outline edges perpendicular to the force, on the line
through the center of mass, from the fitted rigid motion of each floor.
ASCE 7-22 §12.3.2.1 (corpus: asce-7-22, PDF page 181) permits a rigid
diaphragm for Δmax and Δavg on a semirigid floor.
"""
function _semirigid_edge_drifts(u, layout, levels, i, direction, axis)
    e1, e2 = plan_axes(axis)
    lv = levels[i]
    a1min, a1max, a2min, a2max = lv.bounds_m
    cm = lv.center_of_mass
    m1 = cm[1] * e1[1] + cm[2] * e1[2]
    m2 = cm[1] * e2[1] + cm[2] * e2[2]
    coords = direction === :x ? ((m1, a2min), (m1, a2max)) : ((a1min, m2), (a1max, m2))
    return ntuple(2) do j
        c1, c2 = coords[j]
        q = (c1 * e1[1] + c2 * e2[1], c1 * e1[2] + c2 * e2[2])
        top = _semirigid_disp_at(u, layout, lv.elevation_m, direction, q)
        bot = i == 1 ? 0.0 : _semirigid_disp_at(u, layout, levels[i - 1].elevation_m, direction, q)
        top - bot
    end
end
