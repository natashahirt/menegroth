# =============================================================================
# Wall assemblies and free-body cuts
# =============================================================================
# Assemblies are geometry: piers on one story whose ends meet within the same
# 1 mm the mesher uses to share a node.
#
# A cut sums K*u of the elements that meet a line, at the nodes on that line.
# On a horizontal line the shells are the ones above it, and the sum equals
# the load above the cut. A segment top uses the shells below the line and
# flips that sum, so it reads as the load entering the top.
# Equilibrium is six components, one residual, on the basic load case. A
# combination is a mix of cases that already closed, so it is not checked again.

"""
Quads along a wall. Two triangles per quad.

From `scripts/runners/wall_mesh_convergence.jl`: on the unsymmetric
two-wall-plus-frame case, 8 × 8 is within 0.002 of the story force of the
next refinement (16 along, or 16 up). One row up the story, the previous
mesh, gave the short wall 0.45 of the force instead of 0.39.
"""
const WALL_MESH_DIV = 8
"Quads up a story. See [`WALL_MESH_DIV`](@ref)."
const WALL_MESH_ROWS = 8

"""
    wall_panel_quads(nx, ny) -> Vector of (s0, s1, r0, r1)

Parameter boxes on a wall. `s` runs along the plan line, `r` runs up the
story, both in `[0, 1]`. `_mesh_wall_shells` and the mesh study use this
so a refinement is the same split the building gets.
"""
function wall_panel_quads(nx::Int, ny::Int)
    (nx >= 1 && ny >= 1) || throw(ArgumentError(
        "wall_panel_quads: nx and ny must be ≥ 1 (got $nx × $ny)."))
    quads = Tuple{Float64,Float64,Float64,Float64}[]
    for r in 0:(ny - 1), c in 0:(nx - 1)
        push!(quads, (c / nx, (c + 1) / nx, r / ny, (r + 1) / ny))
    end
    return quads
end

"Ends closer than this share a corner. Same 1 mm as the wall-node share."
const WALL_CORNER_TOL_M = 1e-3
# A node is on the cut when its elevation is within WALL_CUT_ZTOL_M of the cut.
# That constant lives with the wall mesh, which is loaded first.

"""Six-component resultant about `origin`, in newtons and newton-metres."""
struct WallCut
    "Wall indices included. Empty for a frame-only contribution."
    wall_indices::Vector{Int}
    z_m::Float64
    origin::NTuple{3, Float64}
    Fx::Float64
    Fy::Float64
    Fz::Float64
    Mx::Float64
    My::Float64
    Mz::Float64
end

"""
Global cut at one elevation: element forces against the loads above it.

`passed` is false when any component misses `atol + rtol * scale`. The
tolerances are numerical. They are not a code provision.
"""
struct StoryCutEquilibrium
    z_m::Float64
    origin::NTuple{3, Float64}
    cut::NTuple{6, Float64}
    applied::NTuple{6, Float64}
    residual::NTuple{6, Float64}
    passed::Bool
end

"""
    wall_assemblies(walls; tol=WALL_CORNER_TOL_M) -> Vector{WallAssembly}

Group walls that share a story and have ends within `tol`. Walls on different
stories stay apart even when their plan lines stack. A wall with no neighbour
is an assembly of one (`joined == false`).
"""
function wall_assemblies(walls::AbstractVector; tol::Real=WALL_CORNER_TOL_M)
    n = length(walls)
    n == 0 && return WallAssembly[]
    parent = collect(1:n)
    function find(i)
        while parent[i] != i
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    function unite(a, b)
        ra, rb = find(a), find(b)
        ra != rb && (parent[rb] = ra)
        return nothing
    end
    tol2 = Float64(tol) * Float64(tol)
    for i in 1:n, j in (i + 1):n
        walls[i].story == walls[j].story || continue
        _wall_ends_meet(walls[i], walls[j], tol2) && unite(i, j)
    end
    groups = Dict{Int, Vector{Int}}()
    for i in 1:n
        push!(get!(() -> Int[], groups, find(i)), i)
    end
    assemblies = WallAssembly[]
    for idxs in values(groups)
        sort!(idxs)
        push!(assemblies, WallAssembly(walls[idxs[1]].story, idxs, length(idxs) > 1))
    end
    sort!(assemblies; by=a -> (a.story, first(a.wall_indices)))
    return assemblies
end

"""
    wall_pier_cut(shells, u, z_m; wall_indices=[]) -> WallCut

Sum `K*u` of `shells` at nodes on elevation `z_m`. Moments are about the
centroid of those nodes.

`u` is a full displacement vector from a processed model, slaves included.
The element must already have `globalID` and `K` from `process!`.
"""
function wall_pier_cut(shells, u::AbstractVector{<:Real}, z_m::Real;
                       wall_indices::AbstractVector{<:Integer}=Int[])
    contrib = _cut_contributions(shells, u, Float64(z_m))
    origin = _cut_origin(contrib, Float64(z_m))
    Fx, Fy, Fz, Mx, My, Mz = _sum_about(contrib, origin)
    return WallCut(collect(Int, wall_indices), Float64(z_m), origin,
                   Fx, Fy, Fz, Mx, My, Mz)
end

"""
    check_story_cut_equilibrium(model, u, mesh, loads, z_m; kwargs...) -> StoryCutEquilibrium

At elevation `z_m`, sum the pier triangles whose bottom is on that elevation
and the frame elements that cross it (one node on the cut, the other above).
Compare the six components with the actions strictly above the cut, about
one origin: nodal loads, shell area loads (including wall self-weight) on
nodes above the cut, line and tributary loads on frame nodes above the cut,
and support reactions at fixed DOFs. A roof node whose rotation is fixed is
a support on that free body. Reactions on the cut itself are not added; the
element forces are that interface. An area load's share, or a line load's
end force, that lands on a node of the cut is not above the cut.

`fixed_end_from_loads` uses the fixed-end forces of `loads` on a frame that
crosses the cut, and the support reactions of this `u` with those forces.
The model's stored `Q` and `reactions` belong to the load set last processed,
which is not this case when `u` came from another load vector.

A miss does not invent a demand. The caller withholds the walls at that cut.
Without the flag, `model.reactions` must already be filled (`solve!` does this).

A member that crosses the cut carries its own fixed-end, including self-weight,
at the node on the cut. That share is not load from above. It is removed from
the reported interface, so the cut equals the load strictly above it.

`geometric_stiffness` is the signed story matrix the displacement was solved
with. The element stiffness does not contain it, so `K_e u` is larger than
the applied story shear by the story couple. Those fictitious forces,
`−K_G u`, are added to the applied side at nodes strictly above the cut
(Wilson & Habibullah 1987, Eq. 1–2, corpus: wilson-habibullah-1987-pdelta,
PDF page 5). A node on the cut is not added.
"""
function check_story_cut_equilibrium(model, u::AbstractVector{<:Real}, mesh::WallMesh,
                                    loads, z_m::Real;
                                    rtol::Real=1e-6, atol_force::Real=1.0,
                                    atol_moment::Real=1.0,
                                    fixed_end_from_loads::Bool=false,
                                    geometric_stiffness=nothing,
                                    include_walls::Bool=true)
    z = Float64(z_m)
    qmap = fixed_end_from_loads ? _fixed_end_by_element(loads) : nothing
    reactions = fixed_end_from_loads ? _case_reactions(model, u, qmap) : model.reactions
    contrib = NamedTuple{(:x, :y, :z, :fx, :fy, :fz, :mx, :my, :mz),
                         NTuple{9, Float64}}[]
    if include_walls
        for pier in mesh.piers
            isempty(pier.shells) && continue
            _pier_bottom(pier) <= z + WALL_CUT_ZTOL_M &&
                _pier_bottom(pier) >= z - WALL_CUT_ZTOL_M || continue
            append!(contrib, _cut_contributions(pier.shells, u, z; qmap=qmap))
        end
    end
    append!(contrib, _frame_cut_contributions(model, u, z; qmap=qmap))
    return _finish_cut_equilibrium(
        contrib, model, u, loads, z;
        reactions=reactions, geometric_stiffness=geometric_stiffness,
        rtol=rtol, atol_force=atol_force, atol_moment=atol_moment,
        what="check_story_cut_equilibrium")
end

"""
    check_opening_row_equilibrium(model, u, mesh, loads, z_m; kwargs...) -> StoryCutEquilibrium

Free-body check at an elevation that cuts through a wall, not only at a pier base.

Shells with a node on `z_m` and the rest of their nodes above it are the wall
side of the cut. Frame elements that cross the line are included, as in
[`check_story_cut_equilibrium`](@ref). The six components are compared with
the loads strictly above the line. `passed` is false when a component misses
the numerical tolerance. A false result withholds the stacks that have an
opening row at this elevation. This function does not apply a strength check.

A shell that has nodes both above and below the line has no face on the cut.
The mesh does not conform to this elevation, and the cut is refused.
"""
function check_opening_row_equilibrium(model, u::AbstractVector{<:Real}, mesh::WallMesh,
                                      loads, z_m::Real;
                                      rtol::Real=1e-6, atol_force::Real=1.0,
                                      atol_moment::Real=1.0,
                                      fixed_end_from_loads::Bool=false,
                                      geometric_stiffness=nothing)
    z = Float64(z_m)
    qmap = fixed_end_from_loads ? _fixed_end_by_element(loads) : nothing
    reactions = fixed_end_from_loads ? _case_reactions(model, u, qmap) : model.reactions
    shells = Asap.ShellTri3[]
    for pier in mesh.piers
        for sh in pier.shells
            side = _shell_cut_side(sh, z)
            if side === :straddle
                throw(ArgumentError(
                    "opening-row cut: a wall shell crosses z = $(z) m with nodes " *
                    "both above and below the line. The mesh does not conform to " *
                    "this elevation, so the cut is not taken."))
            end
            side === :above || continue
            any(nd -> abs(_node_xyz(nd)[3] - z) <= WALL_CUT_ZTOL_M, sh.nodes) || continue
            push!(shells, sh)
        end
    end
    contrib = _cut_contributions(shells, u, z; qmap=qmap)
    append!(contrib, _frame_cut_contributions(model, u, z; qmap=qmap))
    return _finish_cut_equilibrium(
        contrib, model, u, loads, z;
        reactions=reactions, geometric_stiffness=geometric_stiffness,
        rtol=rtol, atol_force=atol_force, atol_moment=atol_moment,
        what="check_opening_row_equilibrium")
end

# ------------------------------------------------------------------------------
# Internals
# ------------------------------------------------------------------------------

function _wall_ends_meet(a, b, tol2::Float64)
    ends_a = ((a.x1, a.y1), (a.x2, a.y2))
    ends_b = ((b.x1, b.y1), (b.x2, b.y2))
    for (x1, y1) in ends_a, (x2, y2) in ends_b
        dx = x1 - x2
        dy = y1 - y2
        dx * dx + dy * dy <= tol2 && return true
    end
    return false
end

function _require_processed(elem)
    gid = elem.globalID
    (length(gid) == 0 || any(i -> i <= 0, gid)) && throw(ArgumentError(
        "wall cut: element global DOFs are not assigned. process! the model first."))
    return gid
end

"""
Force the element carries at its nodes.

`K*u + Q` is the force applied to the element. Element equilibrium makes the
base of that vector the opposite of the load above. The returned vector is
negated so a cut at the base equals the load above it.
"""
function _element_nodal_force(elem, u::AbstractVector{<:Real}; Qfixed=nothing)
    gid = _require_processed(elem)
    n = length(gid)
    ue = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        ue[i] = u[gid[i]]
    end
    f = elem.K * ue
    if Qfixed !== nothing
        length(Qfixed) == n || throw(ArgumentError(
            "wall cut: fixed-end force length $(length(Qfixed)) does not match $(n) DOFs."))
        f = f .+ Qfixed
    elseif hasfield(typeof(elem), :Q) && length(elem.Q) == n
        f = f .+ elem.Q
    end
    return -f
end

"""
Force at one cut node with that node's own fixed-end removed.

`f` is `-(K u + Q)`. `Q` at this node is load applied on the cut, including
the member's self-weight there. It is not load from above the cut.
"""
function _interface_at_cut_node(f, Q, i0::Int)
    ntuple(k -> f[i0 + k] + (Q === nothing ? 0.0 : Q[i0 + k]), 6)
end

"""
Fixed-end forces of `loads`, in the element's global DOF order.

`nothing` means the caller keeps the fixed-end vector stored on the element.
A case that is not the processed load set passes this map and gets zeros on
an element the case does not load.
"""
function _fixed_end_by_element(loads)
    acc = IdDict{Any, Vector{Float64}}()
    for ld in loads
        ld isa Asap.ElementLoad || continue
        el = ld.element
        qg = transpose(el.R) * Asap.q(ld)
        q = get!(() -> zeros(length(qg)), acc, el)
        q .+= qg
    end
    return acc
end

function _case_fixed_end(elem, qmap)
    qmap === nothing && return nothing
    n = length(elem.globalID)
    return get(qmap, elem, zeros(n))
end

"""
Nodal forces of a frame line or tributary load, on nodes strictly above `z`.

The fixed-end vector is the force on the element. The structure carries the
opposite, which is the same split `create_F` puts in `P - Pf`. A node on the
cut is not included.
"""
function _element_load_above(ld::Asap.ElementLoad, origin::NTuple{3, Float64}, z::Float64)
    el = ld.element
    qg = transpose(el.R) * Asap.q(ld)
    length(qg) == 12 || throw(ArgumentError(
        "wall cut: a frame load has $(length(qg)) fixed-end components, not 12."))
    ox, oy, oz = origin
    Fx = Fy = Fz = Mx = My = Mz = 0.0
    for (k, node) in enumerate((el.nodeStart, el.nodeEnd))
        x, y, zz = _node_xyz(node)
        zz > z + WALL_CUT_ZTOL_M || continue
        i0 = (k - 1) * 6
        fx = -qg[i0 + 1]
        fy = -qg[i0 + 2]
        fz = -qg[i0 + 3]
        mx = -qg[i0 + 4]
        my = -qg[i0 + 5]
        mz = -qg[i0 + 6]
        rx = x - ox
        ry = y - oy
        rz = zz - oz
        Fx += fx
        Fy += fy
        Fz += fz
        Mx += ry * fz - rz * fy + mx
        My += rz * fx - rx * fz + my
        Mz += rx * fy - ry * fx + mz
    end
    return (Fx, Fy, Fz, Mx, My, Mz)
end

function _node_xyz(nd)
    p = nd.position
    return (ustrip(u"m", p[1]), ustrip(u"m", p[2]), ustrip(u"m", p[3]))
end

function _nodal_cut_contributions(keep::Function, shells, u; qmap=nothing)
    out = NamedTuple{(:x, :y, :z, :fx, :fy, :fz, :mx, :my, :mz),
                     NTuple{9, Float64}}[]
    for sh in shells
        Q = _case_fixed_end(sh, qmap)
        f = _element_nodal_force(sh, u; Qfixed=Q)
        for (k, nd) in enumerate(sh.nodes)
            x, y, zz = _node_xyz(nd)
            keep(x, y, zz) || continue
            i0 = (k - 1) * 6
            fx, fy, fz, mx, my, mz = _interface_at_cut_node(f, Q, i0)
            push!(out, (x=x, y=y, z=zz,
                        fx=fx, fy=fy, fz=fz, mx=mx, my=my, mz=mz))
        end
    end
    return out
end

function _cut_contributions(shells, u, z::Float64; qmap=nothing)
    _nodal_cut_contributions(shells, u; qmap=qmap) do x, y, zz
        abs(zz - z) <= WALL_CUT_ZTOL_M
    end
end

"""
`:above` when every node is on or above `z` and one is above it.
`:below` when every node is on or below `z` and one is below it.
`:straddle` when the shell has nodes on both sides. `:on` when every node
lies on the line.
"""
function _shell_cut_side(sh, z::Float64)
    above = false
    below = false
    for nd in sh.nodes
        zz = _node_xyz(nd)[3]
        if zz > z + WALL_CUT_ZTOL_M
            above = true
        elseif zz < z - WALL_CUT_ZTOL_M
            below = true
        end
    end
    above && below && return :straddle
    above && return :above
    below && return :below
    return :on
end

function _finish_cut_equilibrium(contrib, model, u, loads, z::Float64;
                                reactions, geometric_stiffness,
                                rtol, atol_force, atol_moment, what::AbstractString)
    isempty(contrib) && throw(ArgumentError(
        "$what: no wall or frame element crosses z = $(z) m."))
    origin = _cut_origin(contrib, z)
    cut6 = _sum_about(contrib, origin)
    applied6 = _loads_above(loads, origin, z)
    react6 = _reactions_above(model, reactions, origin, z)
    applied6 = ntuple(i -> applied6[i] + react6[i], 6)
    if geometric_stiffness !== nothing
        geo6 = _geometric_above(model, geometric_stiffness, u, origin, z)
        applied6 = ntuple(i -> applied6[i] + geo6[i], 6)
    end
    residual = ntuple(i -> cut6[i] - applied6[i], 6)
    scale = max(maximum(abs, cut6), maximum(abs, applied6))
    passed = true
    for i in 1:6
        atol = i <= 3 ? Float64(atol_force) : Float64(atol_moment)
        abs(residual[i]) <= atol + Float64(rtol) * scale || (passed = false)
    end
    return StoryCutEquilibrium(z, origin, cut6, applied6, residual, passed)
end

"Negate a six-component resultant. Moments stay about the same origin."
_negate6(f::NTuple{6, Float64}) = ntuple(i -> -f[i], 6)

function _frame_cut_contributions(model, u, z::Float64; qmap=nothing)
    out = NamedTuple{(:x, :y, :z, :fx, :fy, :fz, :mx, :my, :mz),
                     NTuple{9, Float64}}[]
    for el in _frame_elements(model)
        za = _node_xyz(el.nodeStart)[3]
        zb = _node_xyz(el.nodeEnd)[3]
        lower = nothing
        if abs(za - z) <= WALL_CUT_ZTOL_M && zb > z + WALL_CUT_ZTOL_M
            lower = (el.nodeStart, 0)
        elseif abs(zb - z) <= WALL_CUT_ZTOL_M && za > z + WALL_CUT_ZTOL_M
            lower = (el.nodeEnd, 6)
        else
            continue
        end
        Q = _case_fixed_end(el, qmap)
        f = _element_nodal_force(el, u; Qfixed=Q)
        nd, i0 = lower
        x, y, zz = _node_xyz(nd)
        fx, fy, fz, mx, my, mz = _interface_at_cut_node(f, Q, i0)
        push!(out, (x=x, y=y, z=zz,
                    fx=fx, fy=fy, fz=fz, mx=mx, my=my, mz=mz))
    end
    return out
end

function _pier_bottom(pier::WallPierMesh)
    z = Inf
    for sh in pier.shells, nd in sh.nodes
        z = min(z, _node_xyz(nd)[3])
    end
    return z
end

function _cut_origin(contrib, z::Float64)
    isempty(contrib) && return (0.0, 0.0, z)
    seen = Set{NTuple{3, Int}}()
    sx = 0.0
    sy = 0.0
    n = 0
    for c in contrib
        key = (round(Int, c.x * 1e6), round(Int, c.y * 1e6), round(Int, c.z * 1e6))
        key in seen && continue
        push!(seen, key)
        sx += c.x
        sy += c.y
        n += 1
    end
    n == 0 && return (0.0, 0.0, z)
    return (sx / n, sy / n, z)
end

function _sum_about(contrib, origin::NTuple{3, Float64})
    Fx = Fy = Fz = Mx = My = Mz = 0.0
    ox, oy, oz = origin
    for c in contrib
        rx = c.x - ox
        ry = c.y - oy
        rz = c.z - oz
        Fx += c.fx
        Fy += c.fy
        Fz += c.fz
        Mx += ry * c.fz - rz * c.fy + c.mx
        My += rz * c.fx - rx * c.fz + c.my
        Mz += rx * c.fy - ry * c.fx + c.mz
    end
    return (Fx, Fy, Fz, Mx, My, Mz)
end

"""
Fictitious story forces `−K_G u` at nodes strictly above `z`.

`K_G` is signed: compression is negative, so `−K_G u` points with the
displacement and is the couple Wilson & Habibullah add to the applied load
(Eq. 1, `KU = F + LU`, with `K_G = −L`).
"""
function _geometric_above(model, Kg, u::AbstractVector{<:Real},
                          origin::NTuple{3, Float64}, z::Float64)
    n = model.nDOFs
    length(u) == n || throw(ArgumentError(
        "story cut: displacement length $(length(u)) does not match $(n) DOFs."))
    size(Kg) == (n, n) || throw(ArgumentError(
        "story cut: geometric stiffness is $(size(Kg)); the model has $n DOFs."))
    Ff = Vector{Float64}(-(Kg * collect(Float64, u)))
    ox, oy, oz = origin
    Fx = Fy = Fz = Mx = My = Mz = 0.0
    for nd in model.nodes
        x, y, zz = _node_xyz(nd)
        zz > z + WALL_CUT_ZTOL_M || continue
        gid = nd.globalID
        (length(gid) == 6 && all(i -> 1 <= i <= n, gid)) || continue
        fx = Ff[gid[1]]
        fy = Ff[gid[2]]
        fz = Ff[gid[3]]
        mx = Ff[gid[4]]
        my = Ff[gid[5]]
        mz = Ff[gid[6]]
        rx = x - ox
        ry = y - oy
        rz = zz - oz
        Fx += fx
        Fy += fy
        Fz += fz
        Mx += ry * fz - rz * fy + mx
        My += rz * fx - rx * fz + my
        Mz += rx * fy - ry * fx + mz
    end
    return (Fx, Fy, Fz, Mx, My, Mz)
end

function _loads_above(loads, origin::NTuple{3, Float64}, z::Float64)
    ox, oy, oz = origin
    Fx = Fy = Fz = Mx = My = Mz = 0.0
    for ld in loads
        if ld isa Asap.NodeForce || ld isa Asap.NodeMoment
            x, y, zz = _node_xyz(ld.node)
            zz > z + WALL_CUT_ZTOL_M || continue
            rx = x - ox
            ry = y - oy
            rz = zz - oz
            if ld isa Asap.NodeForce
                fx = ustrip(u"N", ld.value[1])
                fy = ustrip(u"N", ld.value[2])
                fz = ustrip(u"N", ld.value[3])
                Fx += fx
                Fy += fy
                Fz += fz
                Mx += ry * fz - rz * fy
                My += rz * fx - rx * fz
                Mz += rx * fy - ry * fx
            else
                mx = ustrip(u"N*m", ld.value[1])
                my = ustrip(u"N*m", ld.value[2])
                mz = ustrip(u"N*m", ld.value[3])
                Mx += mx
                My += my
                Mz += mz
            end
        elseif ld isa Asap.AreaLoad
            fx, fy, fz, mx, my, mz = _area_load_above(ld, origin, z)
            Fx += fx
            Fy += fy
            Fz += fz
            Mx += mx
            My += my
            Mz += mz
        elseif ld isa Asap.ElementLoad
            fx, fy, fz, mx, my, mz = _element_load_above(ld, origin, z)
            Fx += fx
            Fy += fy
            Fz += fz
            Mx += mx
            My += my
            Mz += mz
        end
    end
    return (Fx, Fy, Fz, Mx, My, Mz)
end

"""
Unfactored self-weight of `shells`, one area load per density and thickness.

Pressure on a triangle is `ρ t g`, with `g` = [`Asap.GRAVITY`](@ref). Each
triangle then splits `pressure × area` equally across its three nodes,
straight down. Shells are not pooled across a different density or
thickness. The returned pressure is unfactored. The dead-load factor is
applied by the caller. A shell with no density is omitted.
"""
function wall_self_weight_loads(shells)
    g = ustrip(u"m/s^2", Asap.GRAVITY)
    groups = Dict{NTuple{2, Float64}, Vector{Asap.ShellTri3}}()
    for sh in shells
        sh isa Asap.ShellTri3 || continue
        (sh.ρ > 0 && sh.thickness > 0) || continue
        key = (sh.ρ, sh.thickness)
        push!(get!(() -> Asap.ShellTri3[], groups, key), sh)
    end
    loads = Asap.AreaLoad[]
    for key in sort!(collect(keys(groups)); by=k -> (k[1], k[2]))
        group = groups[key]
        ρ, t = key
        pressure = ρ * t * g * u"Pa"
        push!(loads, Asap.AreaLoad(group, pressure;
                                    direction=(0.0, 0.0, -1.0),
                                    id=:wall_self_weight))
    end
    return loads
end

"""Unfactored `ρ t g` for one shell, in pascals. `g` is [`Asap.GRAVITY`](@ref)."""
function unfactored_wall_self_weight_pressure(shell)
    g = ustrip(u"m/s^2", Asap.GRAVITY)
    return shell.ρ * shell.thickness * g * u"Pa"
end

"""
Nodal forces of an area load on nodes strictly above `z`.

Same split as `Asap` populate for `distribute_to = :nodes`:
`pressure × area / n` at each node. A load that was turned into tributary
line loads on frames is not summed here.
"""
function _area_load_above(ld::Asap.AreaLoad, origin::NTuple{3, Float64}, z::Float64)
    ox, oy, oz = origin
    Fx = Fy = Fz = Mx = My = Mz = 0.0
    ld.distribute_to == :nodes || return (Fx, Fy, Fz, Mx, My, Mz)
    p = ustrip(u"Pa", ld.pressure)
    d1, d2, d3 = ld.direction
    for shell in ld.shells
        n = length(shell.nodes)
        n == 0 && continue
        shell.area > 0 || throw(ArgumentError(
            "wall cut: an area load owns a shell with no area. " *
            "The self-weight split is pressure times area."))
        fpn = p * shell.area / n
        fx = fpn * d1
        fy = fpn * d2
        fz = fpn * d3
        for node in shell.nodes
            x, y, zz = _node_xyz(node)
            zz > z + WALL_CUT_ZTOL_M || continue
            rx = x - ox
            ry = y - oy
            rz = zz - oz
            Fx += fx
            Fy += fy
            Fz += fz
            Mx += ry * fz - rz * fy
            My += rz * fx - rx * fz
            Mz += rx * fy - ry * fx
        end
    end
    return (Fx, Fy, Fz, Mx, My, Mz)
end

"""
Support reactions for one displacement and one set of fixed-end forces.

Same split as `reactions!` on a unified model: `(S*u + Pf)` at the fixed
DOFs, and zero elsewhere. `Pf` is the fixed-end force of this case, not the
vector stored on the model. Does not write `model.reactions`.
"""
function _case_reactions(model, u::AbstractVector{<:Real}, qmap)
    n = model.nDOFs
    length(u) == n || throw(ArgumentError(
        "wall cut: displacement length $(length(u)) does not match $(n) DOFs."))
    Pf = zeros(n)
    for (el, q) in pairs(qmap)
        gid = el.globalID
        length(q) == length(gid) || throw(ArgumentError(
            "wall cut: fixed-end force length $(length(q)) does not match " *
            "$(length(gid)) DOFs."))
        @inbounds for i in eachindex(gid)
            Pf[gid[i]] += q[i]
        end
    end
    R = zeros(n)
    Ku = model.S * u
    @inbounds for g in model.fixedDOFs
        R[g] = Ku[g] + Pf[g]
    end
    return R
end

"""
Support reactions strictly above the cut, in the same components as a nodal load.

`model.reactions` is the force the support applies to the node. A fixed DOF
above the cut is part of the free body. A fixed DOF on the cut is not: the
element forces already account for it.
"""
function _reactions_above(model, reactions, origin::NTuple{3, Float64}, z::Float64)
    nR = length(reactions)
    ox, oy, oz = origin
    Fx = Fy = Fz = Mx = My = Mz = 0.0
    for nd in model.nodes
        x, y, zz = _node_xyz(nd)
        zz > z + WALL_CUT_ZTOL_M || continue
        dof = nd.dof
        gid = nd.globalID
        length(gid) == length(dof) || continue
        fx = fy = fz = mx = my = mz = 0.0
        for i in eachindex(dof, gid)
            dof[i] && continue
            g = gid[i]
            1 <= g <= nR || continue
            r = reactions[g]
            if i == 1
                fx += r
            elseif i == 2
                fy += r
            elseif i == 3
                fz += r
            elseif i == 4
                mx += r
            elseif i == 5
                my += r
            elseif i == 6
                mz += r
            end
        end
        rx = x - ox
        ry = y - oy
        rz = zz - oz
        Fx += fx
        Fy += fy
        Fz += fz
        Mx += ry * fz - rz * fy + mx
        My += rz * fx - rx * fz + my
        Mz += rx * fy - ry * fx + mz
    end
    return (Fx, Fy, Fz, Mx, My, Mz)
end
