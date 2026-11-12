# A solid head is the rib bays cast solid around one column.
#
# The head is a set of bays of a [`RibArrangement`](@ref). It starts as the
# bays that touch the column and grows by whole bays. A step adds the bays
# across the outline edges that face the failing check, so a failure in one
# direction does not thicken every side. A failure with no direction adds a
# ring all the way around. The set only grows.
#
# The two-way section sits at d/2 outside that outline. ACI 318-11 §11.11.1.2
# (corpus: aci-318-11, page 200) places each critical perimeter no closer than
# d/2 to a change in slab thickness, and makes b₀ the minimum such perimeter.
# An edge of the outline that lies on the slab boundary or on a hole is a free
# edge: the section stops there, which is the two-sided and three-sided
# perimeter of the same clause. The perimeter's properties are
# [`critical_section_properties`](@ref). γv for that perimeter is
# [`gamma_v_general`](@ref) on the returned `l1` and `l2`.
#
# Which way a check fails is the caller's. Pass the rib's outward direction
# for one-way shear on that rib, or the direction from the section centroid
# toward the peak shear when moment transfer governs. `nothing` adds every
# bay that touches the outline, one ring all the way around. On a rectangular
# grid that is the next whole module at a corner, edge, or interior column.

"""Rib bays cast solid around one column. `bays` indexes `arr.bays`."""
struct ColumnSolidHead
    "Plan position of the column, metres."
    column::NTuple{2, Float64}
    "Bay indices, sorted."
    bays::Vector{Int}
end

"""A directed side of a head outline. The bay is on the left of `a → b`."""
struct _HeadSide
    a::Int
    b::Int
    edge::Int
    bay::Int
    across::Union{Int, Nothing}
end

"""Bays of `arr` that use node `node`."""
function _bays_at_node(arr::RibArrangement, node::Int)
    [k for (k, bay) in enumerate(arr.bays) if node in bay.loop]
end

"""`:in` inside the bay, `:on` within `tol` of its boundary, `:out` otherwise."""
function _point_in_bay(arr::RibArrangement, bay::RibBay, p; tol::Float64)
    loop = arr.nodes[bay.loop]
    _distance_to_loop(p, loop) <= tol && return :on
    _inside_loop(p, loop) || return :out
    for h in bay.holes
        hole = arr.nodes[h]
        _distance_to_loop(p, hole) <= tol && return :out
        _inside_loop(p, hole) && return :out
    end
    return :in
end

"""
    seed_column_head(arr, column; tol=1e-6) -> ColumnSolidHead

The bays around `column`.

A column on a rib node takes every bay that uses that node. A column on a
rib edge takes the bays on that edge. A column inside one bay takes that
bay. `column` is a plan point in metres.
"""
function seed_column_head(arr::RibArrangement, column; tol::Float64 = 1e-6)
    xy = _xy2(column)
    tol > 0 || throw(ArgumentError("the column match tolerance is positive, got $tol"))
    nodes = [k for (k, p) in enumerate(arr.nodes) if hypot(p[1] - xy[1], p[2] - xy[2]) <= tol]
    bays = Int[]
    if !isempty(nodes)
        for node in nodes
            append!(bays, _bays_at_node(arr, node))
        end
    else
        on_edge = Int[]
        inside = Int[]
        for (k, bay) in enumerate(arr.bays)
            where = _point_in_bay(arr, bay, xy; tol = tol)
            where === :on && push!(on_edge, k)
            where === :in && push!(inside, k)
        end
        bays = isempty(on_edge) ? inside : on_edge
    end
    unique!(sort!(bays))
    isempty(bays) && throw(ArgumentError(
        "no rib bay meets the column at $(_fmt_m(xy))"))
    return ColumnSolidHead(xy, bays)
end

"""The other bay on `edge`, or `nothing` when the edge is the region boundary."""
function _bay_across(arr::RibArrangement, edge::Int, bay::Int)
    found = nothing
    for (k, other) in enumerate(arr.bays)
        k == bay && continue
        edge in other.sides || continue
        found === nothing || throw(ArgumentError(
            "rib edge $edge bounds more than two bays"))
        found = k
    end
    return found
end

"""
Directed sides of the head outline, one counterclockwise loop.

A side shared by two of the head's bays is inside the head. Anything else
is the outline, with the head's bay on its left.
"""
function _head_sides(arr::RibArrangement, head::ColumnSolidHead)
    isempty(head.bays) && throw(ArgumentError(
        "the solid head at $(_fmt_m(head.column)) contains no bay"))
    selected = Set(head.bays)
    bound = _HeadSide[]
    for bi in head.bays
        bay = arr.bays[bi]
        n = length(bay.loop)
        length(bay.sides) == n || throw(ArgumentError(
            "rib bay $bi does not name one edge per side"))
        for k in 1:n
            a = bay.loop[k]
            b = bay.loop[mod1(k + 1, n)]
            edge = bay.sides[k]
            across = _bay_across(arr, edge, bi)
            across in selected && continue
            push!(bound, _HeadSide(a, b, edge, bi, across))
        end
    end
    isempty(bound) && throw(ArgumentError(
        "the solid head at $(_fmt_m(head.column)) has no outline"))
    nxt = Dict{Int, _HeadSide}()
    for s in bound
        if haskey(nxt, s.a)
            p = arr.nodes[s.a]
            throw(ArgumentError(
                "the solid head at $(_fmt_m(head.column)) pinches at $(_fmt_m(p))"))
        end
        nxt[s.a] = s
    end
    loops = Vector{_HeadSide}[]
    seen = Set{Int}()
    for s0 in bound
        s0.a in seen && continue
        loop = _HeadSide[]
        s = s0
        closed = false
        for _ in 1:length(bound)
            s.a in seen && break
            push!(seen, s.a)
            push!(loop, s)
            haskey(nxt, s.b) || break
            s = nxt[s.b]
            if s.a == s0.a
                closed = true
                break
            end
        end
        closed || throw(ArgumentError(
            "the solid head outline at $(_fmt_m(head.column)) does not close"))
        push!(loops, loop)
    end
    length(loops) == 1 || throw(ArgumentError(
        "the solid head at $(_fmt_m(head.column)) is $(length(loops)) separate pieces"))
    return loops[1]
end

"""`true` when segment `a → b` lies on `loop`."""
function _segment_on_loop(a, b, loop; tol::Float64)
    mid = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
    return _distance_to_loop(a, loop) <= tol &&
           _distance_to_loop(b, loop) <= tol &&
           _distance_to_loop(mid, loop) <= tol
end

"""Outward unit normal of a counterclockwise side. The head is on the left."""
function _outward_normal(a, b)
    dx, dy = b[1] - a[1], b[2] - a[2]
    L = hypot(dx, dy)
    L > 1e-12 || return nothing
    return (dy / L, -dx / L)
end

"""
    column_head_outline(arr, head; free_loops=(), tol=1e-6) -> NamedTuple

The head's outline, walked counterclockwise.

`free[k]` is true when side `k` lies on one of `free_loops` (the slab
boundary or a hole): that side is not a change in thickness inside the
slab. `turns[k]` is the corner at `points[k]`: `:convex`, `:reentrant`, or
`:straight`. `across[k]` is the bay beyond side `k`, or `nothing` on the
region boundary.
"""
function column_head_outline(arr::RibArrangement, head::ColumnSolidHead;
                             free_loops = (), tol::Float64 = 1e-6)
    sides = _head_sides(arr, head)
    points = NTuple{2, Float64}[]
    free = Bool[]
    across = Union{Int, Nothing}[]
    for s in sides
        a = arr.nodes[s.a]
        b = arr.nodes[s.b]
        push!(points, a)
        push!(across, s.across)
        push!(free, any(loop -> _segment_on_loop(a, b, loop; tol = tol), free_loops))
    end
    n = length(points)
    turns = Symbol[]
    for i in 1:n
        a = points[mod1(i - 1, n)]
        b = points[i]
        c = points[mod1(i + 1, n)]
        ab = (b[1] - a[1], b[2] - a[2])
        bc = (c[1] - b[1], c[2] - b[2])
        cr = _cross2(ab, bc)
        tolc = 1e-9 * hypot(ab...) * hypot(bc...)
        push!(turns, cr > tolc ? :convex : cr < -tolc ? :reentrant : :straight)
    end
    return (points = points, free = free, turns = turns, across = across)
end

"""
    grow_column_head(arr, head, direction; taken=Int[], free_loops=(), tol=1e-6)
        -> ColumnSolidHead

One more bay across each outline edge that faces `direction`.

`direction` is a plan vector, metres, pointing out of the head toward the
failing check. The edges added are those whose outward normal is nearest
that direction. `nothing` adds every bay that shares a node with the head,
which is one ring all the way around, corners included. `taken` holds bays
that already belong to another head; a step that would enter one throws, so
does a step that only meets the slab edge, and so does a step whose head
would not be one piece with one outline.
"""
function grow_column_head(arr::RibArrangement, head::ColumnSolidHead, direction;
                          taken::AbstractVector{Int} = Int[],
                          free_loops = (), tol::Float64 = 1e-6)
    if direction === nothing
        add = _ring_bays(arr, head)
        any(in(taken), add) && throw(ArgumentError(
            "growing the solid head at $(_fmt_m(head.column)) would meet another solid head"))
        isempty(add) && throw(ArgumentError(
            "the solid head at $(_fmt_m(head.column)) already covers every bay around it"))
        return _checked_head(arr, ColumnSolidHead(head.column, sort!(vcat(head.bays, add))))
    end
    outline = column_head_outline(arr, head; free_loops = free_loops, tol = tol)
    n = length(outline.points)
    normals = Union{NTuple{2, Float64}, Nothing}[]
    for i in 1:n
        push!(normals, _outward_normal(outline.points[i], outline.points[mod1(i + 1, n)]))
    end
    dir = _xy2(direction)
    L = hypot(dir...)
    L > 1e-12 || throw(ArgumentError(
        "the growth direction at $(_fmt_m(head.column)) has no length"))
    dir = (dir[1] / L, dir[2] / L)
    dots = [nrm === nothing ? -Inf : nrm[1] * dir[1] + nrm[2] * dir[2] for nrm in normals]
    best = maximum(dots)
    best > 1e-8 || throw(ArgumentError(
        "the growth direction at $(_fmt_m(head.column)) does not leave the solid head"))
    facing = [i for i in 1:n if dots[i] >= best - 1e-8]
    add = Int[]
    blocked = false
    for i in facing
        bay = outline.across[i]
        bay === nothing && continue
        bay in taken && (blocked = true)
        push!(add, bay)
    end
    blocked && throw(ArgumentError(
        "growing the solid head at $(_fmt_m(head.column)) would meet another solid head"))
    unique!(sort!(add))
    if isempty(add)
        throw(ArgumentError(
            "the solid head at $(_fmt_m(head.column)) already meets the slab edge in that direction"))
    end
    return _checked_head(arr, ColumnSolidHead(head.column, sort!(vcat(head.bays, add))))
end

"""Bays outside `head` that share a node with one of its bays."""
function _ring_bays(arr::RibArrangement, head::ColumnSolidHead)
    inside = Set(head.bays)
    nodes = Set{Int}()
    for bi in head.bays
        union!(nodes, arr.bays[bi].loop)
    end
    return [k for (k, bay) in enumerate(arr.bays)
            if !(k in inside) && any(in(nodes), bay.loop)]
end

"""`head`, or an `ArgumentError` when its bays are not one piece with one outline."""
function _checked_head(arr::RibArrangement, head::ColumnSolidHead)
    _head_sides(arr, head)
    return head
end

"""
    grow_checked_column_head(arr, head, check; taken=Int[], free_loops=(), tol=1e-6)
        -> ColumnSolidHead

One more step of bays when `check` failed under a positive demand.

A check that names a direction grows toward it. A check that names none
grows one ring all the way around. A passing check, or a failing one whose
shear (or, when stem compression governs, hogging moment) is not positive,
returns `head` with the same bays.
"""
function grow_checked_column_head(arr::RibArrangement, head::ColumnSolidHead, check;
                                  taken::AbstractVector{Int} = Int[],
                                  free_loops = (), tol::Float64 = 1e-6)
    check.ok && return head
    _growth_demand(check) || return head
    dir = hasproperty(check, :direction) ? check.direction : nothing
    return grow_column_head(arr, head, dir; taken = taken, free_loops = free_loops, tol = tol)
end

"""A failing check has a positive shear, or a positive hogging moment."""
function _growth_demand(check)
    if hasproperty(check, :governing) && check.governing === :rib_hogging &&
       hasproperty(check, :Mu)
        return check.Mu > zero(check.Mu)
    end
    hasproperty(check, :Vu) || return false
    return check.Vu > zero(check.Vu)
end

"""
    resolve_column_head(arr, head, check_at; taken, free_loops, tol) -> NamedTuple

Grow `head` one step at a time while `check_at(head)` fails
([`grow_checked_column_head`](@ref)).

`check_at` solves on that head and returns the punching check. This stops
when the check passes, when the failing demand is not positive
(`:no_demand`), when the next step would meet another head or the slab edge
(`:blocked`), or when the governing ratio does not fall (`:ratio`). That
last stop keeps the previous head: a larger head can move the one-way
section onto a rib that carries more of the bay.
"""
function resolve_column_head(arr::RibArrangement, head::ColumnSolidHead, check_at;
                             taken::AbstractVector{Int} = Int[],
                             free_loops = (), tol::Float64 = 1e-6)
    check = check_at(head)
    steps = 0
    while true
        check.ok && return (head = head, check = check, steps = steps, stop = :passed)
        grown = try
            grow_checked_column_head(arr, head, check; taken = taken,
                                     free_loops = free_loops, tol = tol)
        catch err
            err isa ArgumentError || rethrow()
            return (head = head, check = check, steps = steps, stop = :blocked)
        end
        grown.bays == head.bays && return (head = head, check = check, steps = steps,
                                            stop = :no_demand)
        nxt = check_at(grown)
        nxt.ratio < check.ratio - 1e-9 || return (head = head, check = check, steps = steps,
                                                   stop = :ratio)
        head = grown
        check = nxt
        steps += 1
    end
end

"""Intersection of the lines `p + t d` and `q + u e`, or `nothing`."""
function _line_meet(p, d, q, e)
    den = _cross2(d, e)
    abs(den) <= 1e-14 * hypot(d...) * hypot(e...) && return nothing
    r = (q[1] - p[1], q[2] - p[2])
    t = _cross2(r, e) / den
    return (p[1] + t * d[1], p[2] + t * d[2])
end

"""`true` when segments `a→b` and `c→d` cross between their endpoints."""
function _segments_cross_inside(a, b, c, d)
    den = _cross2((b[1] - a[1], b[2] - a[2]), (d[1] - c[1], d[2] - c[2]))
    abs(den) <= 1e-14 && return false
    t = _cross2((c[1] - a[1], c[2] - a[2]), (d[1] - c[1], d[2] - c[2])) / den
    u = _cross2((c[1] - a[1], c[2] - a[2]), (b[1] - a[1], b[2] - a[2])) / den
    return 1e-8 < t < 1 - 1e-8 && 1e-8 < u < 1 - 1e-8
end

"""Drop a vertex where the two sides are collinear and both free or both not."""
function _merge_straight_sides(points, free)
    n = length(points)
    n >= 3 || return points, free
    keep = Int[]
    for i in 1:n
        a = points[mod1(i - 1, n)]
        b = points[i]
        c = points[mod1(i + 1, n)]
        ab = (b[1] - a[1], b[2] - a[2])
        bc = (c[1] - b[1], c[2] - b[2])
        straight = abs(_cross2(ab, bc)) <= 1e-9 * hypot(ab...) * hypot(bc...)
        same = free[mod1(i - 1, n)] == free[i]
        (straight && same) || push!(keep, i)
    end
    length(keep) >= 3 || throw(ArgumentError("the solid head outline has no area"))
    return points[keep], free[keep]
end

"""
Parallel curve at `dist` outside a counterclockwise outline.

`free[k]` is the side from `points[k]` to the next point. Free sides stay:
the section runs out to them and stops. One run of free sides gives an open
perimeter. Two runs are not one critical section.
"""
function _offset_outline(points, free, dist::Float64)
    pts, fr = _merge_straight_sides(points, free)
    n = length(pts)
    function offset_line(i)
        a = pts[i]
        b = pts[mod1(i + 1, n)]
        nrm = _outward_normal(a, b)
        nrm === nothing && return nothing
        p = (a[1] + nrm[1] * dist, a[2] + nrm[2] * dist)
        return (p, (b[1] - a[1], b[2] - a[2]))
    end
    function meet_free(line, free_edge)
        a = pts[free_edge]
        b = pts[mod1(free_edge + 1, n)]
        hit = _line_meet(line[1], line[2], a, (b[1] - a[1], b[2] - a[2]))
        return hit === nothing ? line[1] : hit
    end
    if all(!, fr)
        verts = NTuple{2, Float64}[]
        lines = [offset_line(i) for i in 1:n]
        for i in 1:n
            li = lines[i]
            lj = lines[mod1(i + 1, n)]
            (li === nothing || lj === nothing) && throw(ArgumentError(
                "a solid-head edge has no length"))
            hit = _line_meet(li[1], li[2], lj[1], lj[2])
            hit === nothing && throw(ArgumentError(
                "two solid-head edges have no section corner between them"))
            push!(verts, hit)
        end
        return verts, true, pts, fr
    end
    all(fr) && throw(ArgumentError(
        "the solid head has no interior face to section"))
    runs = 0
    for i in 1:n
        fr[i] && !fr[mod1(i - 1, n)] && (runs += 1)
    end
    runs == 1 || throw(ArgumentError(
        "the solid head meets the slab edge in $runs separate places"))
    i = findfirst(identity, fr)
    while fr[mod1(i, n)]
        i += 1
    end
    start = mod1(i, n)
    kept = Int[]
    j = start
    while !fr[j]
        push!(kept, j)
        j = mod1(j + 1, n)
        length(kept) > n && break
    end
    verts = NTuple{2, Float64}[]
    first = offset_line(kept[1])
    first === nothing && throw(ArgumentError("a solid-head edge has no length"))
    push!(verts, meet_free(first, mod1(start - 1, n)))
    for k in 1:(length(kept) - 1)
        li = offset_line(kept[k])
        lj = offset_line(kept[k + 1])
        (li === nothing || lj === nothing) && throw(ArgumentError(
            "a solid-head edge has no length"))
        hit = _line_meet(li[1], li[2], lj[1], lj[2])
        hit === nothing && throw(ArgumentError(
            "two solid-head edges have no section corner between them"))
        push!(verts, hit)
    end
    last = offset_line(kept[end])
    last === nothing && throw(ArgumentError("a solid-head edge has no length"))
    push!(verts, meet_free(last, mod1(kept[end] + 1, n)))
    return verts, false, pts, fr
end

"""Plan area of the critical section, closing an open perimeter along the free edges."""
function _section_area(section, closed, points, free)
    poly = copy(section)
    if !closed
        n = length(points)
        i = findfirst(!, free)
        while !free[mod1(i, n)]
            i += 1
        end
        j = mod1(i, n)
        for _ in 1:n
            free[j] || break
            push!(poly, points[mod1(j + 1, n)])
            j = mod1(j + 1, n)
        end
    end
    return abs(_loop_signed_area(poly))
end

"""Throw when the section crosses itself. b₀ would not be the minimum perimeter."""
function _reject_crossed_section(section, closed, column)
    n = length(section)
    last = closed ? n : n - 1
    for i in 1:last
        a = section[i]
        b = section[mod1(i + 1, n)]
        for j in (i + 2):last
            (closed && i == 1 && j == n) && continue
            c = section[j]
            d = section[mod1(j + 1, n)]
            _segments_cross_inside(a, b, c, d) || continue
            throw(ArgumentError(
                "the section at $(_fmt_m(column)) crosses itself, so the parallel " *
                "curve is not the minimum perimeter of ACI 318-11 §11.11.1.2"))
        end
    end
    return nothing
end

"""
    column_head_section(arr, head, d; free_loops=(), tol=1e-6) -> NamedTuple

The critical section at `d/2` outside the head, and its perimeter properties.

`d` is the solid head's effective depth. `points` are metres. `closed` is
false when the section stops on a free edge. `area` is the plan area inside
the section, metres², closing an open perimeter along the free edges.
`turns` classifies the head outline the section was offset from.
`properties` is [`critical_section_properties`](@ref) of that perimeter.
"""
function column_head_section(arr::RibArrangement, head::ColumnSolidHead, d::Length;
                             free_loops = (), tol::Float64 = 1e-6)
    d > zero(d) || throw(ArgumentError(
        "the head's effective depth is positive, got $d"))
    outline = column_head_outline(arr, head; free_loops = free_loops, tol = tol)
    dist = ustrip(u"m", d) / 2
    section, closed, pts, fr = _offset_outline(outline.points, outline.free, dist)
    _reject_crossed_section(section, closed, head.column)
    area = _section_area(section, closed, pts, fr)
    area > 0 || throw(ArgumentError(
        "the section at $(_fmt_m(head.column)) encloses no area"))
    q = [(p[1] * u"m", p[2] * u"m") for p in section]
    props = critical_section_properties(q, d; closed = closed)
    turns = Symbol[]
    m = length(pts)
    for i in 1:m
        a = pts[mod1(i - 1, m)]
        b = pts[i]
        c = pts[mod1(i + 1, m)]
        ab = (b[1] - a[1], b[2] - a[2])
        bc = (c[1] - b[1], c[2] - b[2])
        cr = _cross2(ab, bc)
        tolc = 1e-9 * hypot(ab...) * hypot(bc...)
        push!(turns, cr > tolc ? :convex : cr < -tolc ? :reentrant : :straight)
    end
    return (
        points = section,
        closed = closed,
        area = area * u"m^2",
        turns = turns,
        properties = props,
    )
end

"""
    solid_edge_widths(arr, heads) -> Dict{Int, Float64}

Width, in metres, of the gross rectangle on each edge that bounds a solid
head. An edge outside every head is absent.

Parallel edges of one head share the head's extent measured perpendicular
to them. The shares of one family add up to that extent, which is the
split [`solid_piece_widths`](@ref) uses on a rectangle: pieces of one rib
line are in series and each carries the line's share. A bay in two heads
throws. An edge between two heads is one rib and keeps the wider share.
"""
function solid_edge_widths(arr::RibArrangement, heads::AbstractVector{ColumnSolidHead})
    bay_owner = Dict{Int, Int}()
    for (hi, head) in enumerate(heads)
        isempty(head.bays) && throw(ArgumentError(
            "the solid head at $(_fmt_m(head.column)) contains no bay"))
        for bi in head.bays
            1 <= bi <= length(arr.bays) || throw(ArgumentError(
                "solid head bay $bi is not a bay of the arrangement"))
            prev = get(bay_owner, bi, hi)
            prev == hi || throw(ArgumentError(
                "bay $bi is in two solid heads"))
            bay_owner[bi] = hi
        end
    end
    widths = Dict{Int, Float64}()
    for head in heads
        edges = Int[]
        verts = NTuple{2, Float64}[]
        for bi in head.bays
            append!(edges, arr.bays[bi].sides)
            append!(verts, arr.nodes[arr.bays[bi].loop])
        end
        unique!(edges)
        for (e, w) in _solid_family_widths(arr, edges, verts)
            widths[e] = max(get(widths, e, 0.0), w)
        end
    end
    return widths
end

"""Unit direction of edge `e`, folded into a half-turn so parallels match."""
function _edge_axis(arr::RibArrangement, e::Int)
    a = arr.nodes[arr.edges[e][1]]
    b = arr.nodes[arr.edges[e][2]]
    dx, dy = b[1] - a[1], b[2] - a[2]
    L = hypot(dx, dy)
    L > 1e-12 || throw(ArgumentError("a solid-head edge has no length"))
    if dx < -1e-12 || (abs(dx) <= 1e-12 && dy < 0)
        dx, dy = -dx, -dy
    end
    return (dx / L, dy / L)
end

"""Share each parallel family of `edges` across the head's perpendicular extent."""
function _solid_family_widths(arr::RibArrangement, edges::Vector{Int},
                              verts::Vector{NTuple{2, Float64}})
    out = Dict{Int, Float64}()
    isempty(edges) && return out
    isempty(verts) && throw(ArgumentError("a solid head has no vertices"))
    axes = [_edge_axis(arr, e) for e in edges]
    used = falses(length(edges))
    for i in eachindex(edges)
        used[i] && continue
        family = Int[i]
        used[i] = true
        for j in (i + 1):length(edges)
            used[j] && continue
            abs(_cross2(axes[i], axes[j])) <= 1e-6 || continue
            used[j] = true
            push!(family, j)
        end
        t = axes[family[1]]
        nrm = (t[2], -t[1])
        proj = [v[1] * nrm[1] + v[2] * nrm[2] for v in verts]
        extent = maximum(proj) - minimum(proj)
        extent > 1e-8 || throw(ArgumentError(
            "a solid head has no width perpendicular to its ribs"))
        offsets = Float64[]
        for k in family
            e = edges[k]
            a = arr.nodes[arr.edges[e][1]]
            b = arr.nodes[arr.edges[e][2]]
            mid = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
            off = mid[1] * nrm[1] + mid[2] * nrm[2]
            any(o -> abs(o - off) <= 1e-6 * max(1.0, abs(off)), offsets) || push!(offsets, off)
        end
        share = extent / length(offsets)
        for k in family
            out[edges[k]] = share
        end
    end
    return out
end
