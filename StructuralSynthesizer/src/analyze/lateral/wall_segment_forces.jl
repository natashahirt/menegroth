# Forces in the segments around an opening.
#
# A vertical segment is cut on horizontal lines at its bottom and its top.
# The bottom uses the same sign as a pier base: the resultant is the load
# above the cut. The top uses the shells below the line and flips that
# resultant, so it is the load entering the top, including a nodal load that
# sits on the top nodes.
#
# A horizontal segment is cut on the vertical faces at its two ends. Each
# resultant is the force the material outside the segment exerts on it.
# N is compression along the span. V is upward. M is about the horizontal
# wall normal.
#
# These functions report the forces. The ordinary-wall stage reads them.
# They do not pass or fail a strength check.

"""Force on one end of a horizontal segment."""
struct SpandrelEndAction
    "Compression-positive force along the span [N]."
    N::Float64
    "Upward force on the segment [N]."
    V::Float64
    "Moment on the segment about the horizontal wall normal [N·m]."
    M::Float64
    "Out-of-plane force on the segment, along the horizontal normal [N]."
    Vo::Float64
    "Moment on the segment about the wall tangent [N·m]."
    Mo::Float64
    function SpandrelEndAction(N, V, M, Vo=0.0, Mo=0.0)
        new(Float64(N), Float64(V), Float64(M), Float64(Vo), Float64(Mo))
    end
end

"""Bottom and top cuts of one vertical segment, both in the pier-base sign."""
struct PierSegmentActions
    bottom::WallAction
    top::WallAction
end

"""End cuts of one horizontal segment. `at_start` is the face at `s0`."""
struct SpandrelSegmentActions
    at_start::SpandrelEndAction
    at_end::SpandrelEndAction
end

"""Reported forces for one vertical segment."""
struct VerticalSegmentForces
    stack::Vector{Int}
    wall_indices::Vector{Int}
    s0::Float64
    s1::Float64
    z0::Float64
    z1::Float64
    design::Symbol
    bottom::WallAction
    top::WallAction
end

"""Reported forces for one horizontal segment."""
struct HorizontalSegmentForces
    stack::Vector{Int}
    wall_indices::Vector{Int}
    s0::Float64
    s1::Float64
    z0::Float64
    z1::Float64
    design::Symbol
    at_start::SpandrelEndAction
    at_end::SpandrelEndAction
end

"""Vertical and horizontal segment forces for one layout."""
struct SegmentForceReport
    vertical::Vector{VerticalSegmentForces}
    horizontal::Vector{HorizontalSegmentForces}
end

"""
Opening-row free body at one elevation.

`stacks` lists every plan stack that has a vertical segment starting at `z_m`.
`equilibrium.passed` is false when the cut misses the load above that line.
A miss withholds those stacks. This record does not change the ordinary-wall
stage, which still withholds every pierced wall until the segment strength
checks exist.
"""
struct OpeningRowGate
    stacks::Vector{Vector{Int}}
    z_m::Float64
    equilibrium::StoryCutEquilibrium
end

"""
    pier_segment_actions(wall, shells, u, z_bottom, z_top; kwargs...) -> PierSegmentActions

In-plane actions at the bottom and top of a vertical segment.

`shells` are the segment's triangles. `z_bottom` and `z_top` are elevations
in metres. `wall` supplies the tangent, from `(x1, y1)` toward `(x2, y2)`.
The meshed nodes on each horizontal face orient that tangent when a column
offset has moved the edge.

`fixed_end_from_loads` reads fixed-end forces from `loads` instead of the
`Q` stored on the element. Fixed-end force on a node of the cut, including
self-weight that lands there, is left out of the resultant. It is load on
the cut, in the same sense as [`pier_wall_action`](@ref).
"""
function pier_segment_actions(wall::Wall, shells, u::AbstractVector{<:Real},
                             z_bottom::Real, z_top::Real;
                             loads=Asap.AbstractLoad[],
                             fixed_end_from_loads::Bool=false)
    zb = Float64(z_bottom)
    zt = Float64(z_top)
    zt > zb + WALL_CUT_ZTOL_M || throw(ArgumentError(
        "pier segment: the top z = $(zt) m is not above the bottom z = $(zb) m."))
    qmap = _segment_fixed_end(loads, fixed_end_from_loads)
    bottom = _horizontal_face_action(wall, shells, u, zb; qmap=qmap, flip=false, face=:bottom)
    top = _horizontal_face_action(wall, shells, u, zt; qmap=qmap, flip=true, face=:top)
    return PierSegmentActions(bottom, top)
end

"""
    spandrel_segment_actions(wall, shells, u, s0, s1, z0, z1; kwargs...) -> SpandrelSegmentActions

Forces on a horizontal segment at its two vertical faces.

`s0` and `s1` are metres along `wall` from `(x1, y1)` toward `(x2, y2)`.
`z0` and `z1` bound the face. A node is on a face when its projection onto
that line is within 1 mm of the station and its elevation is inside the face.

At `s0`, compression is a force on the segment toward `+s`. At `s1`,
compression is a force on the segment toward `-s`. `V` is positive upward
at both faces. `M` is the moment on the segment about the horizontal normal.

A nodal load that sits on a face is part of that face's force. A slab or
diaphragm force that lands on a node of the face is included with it, so a
face that falls on a slab line carries that node's share of the slab.

`fixed_end_from_loads` is the same switch as [`pier_segment_actions`](@ref).
"""
function spandrel_segment_actions(wall::Wall, shells, u::AbstractVector{<:Real},
                                 s0::Real, s1::Real, z0::Real, z1::Real;
                                 loads=Asap.AbstractLoad[],
                                 fixed_end_from_loads::Bool=false)
    a = Float64(s0)
    b = Float64(s1)
    lo = Float64(z0)
    hi = Float64(z1)
    b > a + WALL_OPENING_GAP_M || throw(ArgumentError(
        "spandrel segment: s1 = $(b) m is not past s0 = $(a) m."))
    hi > lo + WALL_CUT_ZTOL_M || throw(ArgumentError(
        "spandrel segment: the face from z = $(lo) m to $(hi) m has no depth."))
    qmap = _segment_fixed_end(loads, fixed_end_from_loads)
    at_start = _vertical_face_action(wall, shells, u, a, lo, hi, true; qmap=qmap)
    at_end = _vertical_face_action(wall, shells, u, b, lo, hi, false; qmap=qmap)
    return SpandrelSegmentActions(at_start, at_end)
end

"""
    segment_opening_forces(walls, layout, u; kwargs...) -> SegmentForceReport

Cuts for every segment in `layout`.

`s` is measured on the stack's reference wall: the lowest story, then the
lowest index. That is the same frame [`wall_segment_layout`](@ref) uses.
A segment with no shells throws. An empty mesh is not a zero demand.
"""
function segment_opening_forces(walls, layout::WallSegmentLayout, u::AbstractVector{<:Real};
                               loads=Asap.AbstractLoad[],
                               fixed_end_from_loads::Bool=false)
    vertical = VerticalSegmentForces[]
    horizontal = HorizontalSegmentForces[]
    for seg in layout.segments
        isempty(seg.shells) && throw(ArgumentError(
            "segment forces: a $(seg.kind) segment from s = $(seg.s0) m to " *
            "$(seg.s1) m, z = $(seg.z0) m to $(seg.z1) m, has no shells. " *
            "The cut is not taken on an empty segment."))
        ref = _segment_reference_wall(walls, seg)
        if seg.kind === :vertical
            actions = pier_segment_actions(
                ref, seg.shells, u, seg.z0, seg.z1;
                loads=loads, fixed_end_from_loads=fixed_end_from_loads)
            push!(vertical, VerticalSegmentForces(
                copy(seg.stack), copy(seg.wall_indices),
                seg.s0, seg.s1, seg.z0, seg.z1, seg.design,
                actions.bottom, actions.top))
        elseif seg.kind === :horizontal
            actions = spandrel_segment_actions(
                ref, seg.shells, u, seg.s0, seg.s1, seg.z0, seg.z1;
                loads=loads, fixed_end_from_loads=fixed_end_from_loads)
            push!(horizontal, HorizontalSegmentForces(
                copy(seg.stack), copy(seg.wall_indices),
                seg.s0, seg.s1, seg.z0, seg.z1, seg.design,
                actions.at_start, actions.at_end))
        else
            throw(ArgumentError(
                "segment forces: a segment kind must be :vertical or :horizontal, " *
                "got $(seg.kind)."))
        end
    end
    return SegmentForceReport(vertical, horizontal)
end

"""
    opening_row_equilibria(model, u, mesh, loads, layout; kwargs...) -> Vector{OpeningRowGate}

One free-body check at the bottom of each vertical segment.

Segments that share an elevation share one check. The cut is the whole
model at that elevation: every wall shell that sits on the line from above,
plus frame elements that cross it. It is compared with the loads strictly
above the line by [`check_opening_row_equilibrium`](@ref).
"""
function opening_row_equilibria(model, u::AbstractVector{<:Real}, mesh::WallMesh,
                               loads, layout::WallSegmentLayout;
                               rtol::Real=1e-6, atol_force::Real=1.0,
                               atol_moment::Real=1.0,
                               fixed_end_from_loads::Bool=false,
                               geometric_stiffness=nothing)
    order = Float64[]
    stacks = Dict{Float64, Vector{Vector{Int}}}()
    for seg in layout.segments
        seg.kind === :vertical || continue
        key = round(seg.z0; digits=4)
        if !haskey(stacks, key)
            stacks[key] = Vector{Int}[]
            push!(order, seg.z0)
        end
        any(s -> s == seg.stack, stacks[key]) && continue
        push!(stacks[key], copy(seg.stack))
    end
    gates = OpeningRowGate[]
    for z in order
        key = round(z; digits=4)
        eq = check_opening_row_equilibrium(
            model, u, mesh, loads, z;
            rtol=rtol, atol_force=atol_force, atol_moment=atol_moment,
            fixed_end_from_loads=fixed_end_from_loads,
            geometric_stiffness=geometric_stiffness)
        push!(gates, OpeningRowGate(stacks[key], z, eq))
    end
    return gates
end

# ------------------------------------------------------------------------------
# Internals
# ------------------------------------------------------------------------------

function _segment_fixed_end(loads, fixed_end_from_loads::Bool)
    fixed_end_from_loads ? _fixed_end_by_element(loads) : nothing
end

function _segment_reference_wall(walls, seg::WallSegment)
    isempty(seg.stack) && throw(ArgumentError(
        "segment forces: a segment has no stack."))
    i = argmin(j -> (walls[j].story, j), seg.stack)
    (1 <= i <= length(walls)) || throw(ArgumentError(
        "segment forces: stack index $i is outside the $(length(walls)) walls."))
    return walls[i]
end

function _project_wall_action(force::NTuple{6, Float64}, tx, ty, nx, ny)
    Fx, Fy, Fz, Mx, My, Mz = force
    return WallAction(
        -Fz,
        Fx * tx + Fy * ty,
        Mx * nx + My * ny,
        Fx * nx + Fy * ny,
        Mx * tx + My * ty)
end

function _cut_plan_points(contrib)
    pts = Tuple{Float64, Float64}[]
    for c in contrib
        xy = (c.x, c.y)
        any(p -> hypot(p[1] - xy[1], p[2] - xy[2]) <= 1e-9, pts) && continue
        push!(pts, xy)
    end
    return pts
end

function _horizontal_face_action(wall, shells, u, z::Float64; qmap, flip::Bool, face::Symbol)
    side = flip ? :below : :above
    kept = Asap.ShellTri3[]
    for sh in shells
        which = _shell_cut_side(sh, z)
        if which === :straddle
            throw(ArgumentError(
                "pier segment: a shell crosses z = $(z) m at the $face of the " *
                "segment. The mesh does not conform to this elevation, so the " *
                "cut is not taken."))
        end
        which === side && push!(kept, sh)
    end
    contrib = _cut_contributions(kept, u, z; qmap=qmap)
    isempty(contrib) && throw(ArgumentError(
        "pier segment: no shell node lies on z = $(z) m at the $face of the segment."))
    origin = _cut_origin(contrib, z)
    force = _sum_about(contrib, origin)
    flip && (force = _negate6(force))
    tx, ty, nx, ny = _oriented_plan_axes(wall, _cut_plan_points(contrib))
    return _project_wall_action(force, tx, ty, nx, ny)
end

function _contrib_centroid(contrib)
    seen = Set{NTuple{3, Int}}()
    sx = 0.0
    sy = 0.0
    sz = 0.0
    n = 0
    for c in contrib
        key = (round(Int, c.x * 1e6), round(Int, c.y * 1e6), round(Int, c.z * 1e6))
        key in seen && continue
        push!(seen, key)
        sx += c.x
        sy += c.y
        sz += c.z
        n += 1
    end
    n == 0 && return (0.0, 0.0, 0.0)
    return (sx / n, sy / n, sz / n)
end

function _project_spandrel(force::NTuple{6, Float64}, wall, at_start::Bool)
    tx, ty, nx, ny = _pier_plan_axes(wall)
    Fx, Fy, Fz, Mx, My, Mz = force
    Fs = Fx * tx + Fy * ty
    # Compression points into the segment: +s at the start, -s at the end.
    N = at_start ? Fs : -Fs
    return SpandrelEndAction(
        N,
        Fz,
        Mx * nx + My * ny,
        Fx * nx + Fy * ny,
        Mx * tx + My * ty)
end

function _shells_on_span_side(wall, shells, s_face, z0, z1, inward)
    out = Asap.ShellTri3[]
    for sh in shells
        on_face = false
        outside = false
        for nd in sh.nodes
            x, y, zz = _node_xyz(nd)
            s = _segment_s(wall, x, y)
            inward * (s - s_face) < -WALL_OPENING_GAP_M && (outside = true)
            on_line = abs(s - s_face) <= WALL_OPENING_GAP_M
            in_depth = z0 - WALL_OPENING_GAP_M <= zz <= z1 + WALL_OPENING_GAP_M
            on_face |= on_line && in_depth
        end
        on_face || continue
        if outside
            throw(ArgumentError(
                "spandrel segment: a shell crosses s = $(s_face) m. " *
                "The cut face is not at a mesh line, so the cut is not taken."))
        end
        push!(out, sh)
    end
    return out
end

function _vertical_face_action(wall, shells, u, s_face, z0, z1, at_start::Bool; qmap)
    inward = at_start ? 1.0 : -1.0
    kept = _shells_on_span_side(wall, shells, s_face, z0, z1, inward)
    contrib = _nodal_cut_contributions(kept, u; qmap=qmap) do x, y, zz
        abs(_segment_s(wall, x, y) - s_face) <= WALL_OPENING_GAP_M &&
            z0 - WALL_OPENING_GAP_M <= zz <= z1 + WALL_OPENING_GAP_M
    end
    isempty(contrib) && throw(ArgumentError(
        "spandrel segment: no shell node lies on s = $(s_face) m between " *
        "z = $(z0) m and $(z1) m."))
    raw = _sum_about(contrib, _contrib_centroid(contrib))
    return _project_spandrel(_negate6(raw), wall, at_start)
end
