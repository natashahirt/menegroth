# Wall segments around rectangular openings.
#
# One stack is the walls on one plan line, linked by `wall_above`. `s` runs
# from the lowest wall's start. `z` is the skeleton elevation, in metres.
# The coarse grid is the wall ends, the story lines, and the opening edges.
#
# A row that contains an opening is cut into vertical segments. A column that
# contains an opening is cut into horizontal segments. Where those two claims
# meet, the row wins: the overlap is a pier, and the horizontal segment stops.
# That overlap rule is an idealization. ACI 318-19 §2.3 defines the segments
# and does not say which claim owns a cell that could be either.
#
# A row with no opening is recorded as a solid row. The whole-wall check is
# the one that still applies there. This file does not run that check.

"""One solid band of a stack, from `z0` to `z1`, with no opening in it."""
struct WallSolidRow
    "Wall indices of the plan stack, sorted."
    stack::Vector{Int}
    "Elevation of the bottom of the band, metres."
    z0::Float64
    "Elevation of the top of the band, metres."
    z1::Float64
end

"""
A vertical or horizontal wall segment.

`kind` is `:vertical` or `:horizontal`. `design` is the check the segment
is routed to: `:wall` or `:column` for a vertical segment, `:beam` or `:stm`
for a horizontal segment. `shells` is empty until a mesh is passed.
`s` is metres along the stack. `z` is elevation in metres.
"""
struct WallSegment
    kind::Symbol
    "Wall indices of the plan stack, sorted."
    stack::Vector{Int}
    "Walls whose story elevation overlaps this segment, sorted."
    wall_indices::Vector{Int}
    s0::Float64
    s1::Float64
    z0::Float64
    z1::Float64
    shells::Vector{Asap.ShellTri3}
    design::Symbol
end

"""Segments and the solid rows of every stack."""
struct WallSegmentLayout
    segments::Vector{WallSegment}
    solid_rows::Vector{WallSolidRow}
end

"""
    wall_segment_layout(walls, skel; shells_by_wall=nothing) -> WallSegmentLayout

Segment every plan stack in `walls`.

A vertical segment is a solid run in a row that contains an opening, merged
with the run above or below it when the `s` extent is the same. A horizontal
segment is a solid run in a column that contains an opening, through the
walls that have that opening, and it stops at a row that contains an
opening. A solid story above a window is not part of the lintel. A band
between two stacked openings still crosses the floor. `shells_by_wall[i]`
is the triangles of `walls[i]`; a triangle is kept on the segment whose
rectangle holds its centroid.

# Routing

A vertical segment is a wall when its length-to-thickness ratio is greater
than 3, and a column otherwise. ACI 318-19 §2.3 (corpus: `aci-318-19`, PDF
p. 48) defines a wall by that ratio. The column route is the segment that
does not meet the definition.

A horizontal segment is a deep beam when its clear span does not exceed four
times its overall depth, and a Chapter 9 beam otherwise. ACI 318-19
§9.9.1.1(a) (corpus: `aci-318-19`, PDF p. 154). R9.9.1.1 on the same page
sends a deep member supported on its sides to Chapter 23, which is the
`:stm` route. §9.9.1.1(b), a concentrated load within `2h` of the support,
is not evaluated.

# Idealization

An overlap cell is a pier. That is not an ACI provision. ACI 318-19 §2.3
defines a horizontal segment as the portion bounded vertically by openings
or an edge, and a vertical segment as the portion bounded horizontally by
openings or an edge. A cell that meets both definitions is kept on the
vertical segment.
"""
function wall_segment_layout(walls, skel::BuildingSkeleton; shells_by_wall=nothing)
    if shells_by_wall !== nothing && length(shells_by_wall) != length(walls)
        throw(ArgumentError(
            "wall segments: $(length(shells_by_wall)) shell lists for " *
            "$(length(walls)) walls."))
    end
    segments = WallSegment[]
    rows = WallSolidRow[]
    for stack in _opening_stacks(walls)
        layout = _stack_segment_layout(walls, skel, stack, shells_by_wall)
        append!(segments, layout.segments)
        append!(rows, layout.solid_rows)
    end
    return WallSegmentLayout(segments, rows)
end

"Plan stacks from `wall_above`, one sorted index list each."
function _opening_stacks(walls)
    groups = _wall_plan_stack_members(walls)
    seen = Set{Int}()
    stacks = Vector{Int}[]
    for (i, group) in enumerate(groups)
        i in seen && continue
        for j in group
            push!(seen, j)
        end
        push!(stacks, sort!(collect(group)))
    end
    return stacks
end

"Bottom and top elevation of one wall, in metres."
function _segment_wall_z(wall, skel)
    haskey(skel.stories, wall.story) || throw(ArgumentError(
        "wall segments: story $(wall.story) is not in the skeleton."))
    z0 = _length_metres(skel.stories[wall.story].elevation, "story elevation")
    h = _length_metres(wall.base.L, "base.L")
    h > 0 || throw(ArgumentError(
        "wall segments: wall story height must be positive, got $(wall.base.L)."))
    return z0, z0 + h
end

"Distance along `ref` from its start to `(x, y)`, in metres."
function _segment_s(ref, x::Float64, y::Float64)
    dx = ref.x2 - ref.x1
    dy = ref.y2 - ref.y1
    L = hypot(dx, dy)
    L > 0 || throw(ArgumentError(
        "wall segments: a stack wall has no plan length."))
    return ((x - ref.x1) * dx + (y - ref.y1) * dy) / L
end

"Opening interval on `ref`, in metres. `wall` may run the other way."
function _segment_opening_s(ref, wall, op::WallOpening)
    L = wall_length(wall)
    L > 0 || throw(ArgumentError("wall segments: a wall with an opening has no length."))
    function at(s)
        f = s / L
        return (wall.x1 + (wall.x2 - wall.x1) * f, wall.y1 + (wall.y2 - wall.y1) * f)
    end
    a = at(op.s0)
    b = at(op.s0 + op.width)
    return minmax(_segment_s(ref, a[1], a[2]), _segment_s(ref, b[1], b[2]))
end

"Sorted stations. Values within 1 mm of the one already kept are one line."
function _segment_stations(xs; tol::Float64=WALL_OPENING_GAP_M)
    xs = sort!(collect(Float64, xs))
    out = Float64[]
    for x in xs
        (isempty(out) || x - out[end] > tol) || continue
        push!(out, x)
    end
    length(out) >= 2 || throw(ArgumentError(
        "wall segments: the stack has no extent."))
    return out
end

"True when the cell centre lies inside an opening of a wall in this stack."
function _segment_cell_open(walls, stack, skel, ref, s0, s1, z0, z1)
    sm = (s0 + s1) / 2
    zm = (z0 + z1) / 2
    for i in stack
        wall = walls[i]
        zb, zt = _segment_wall_z(wall, skel)
        (zb < zm < zt) || continue
        for op in wall.openings
            a, b = _segment_opening_s(ref, wall, op)
            oz0 = zb + op.z0
            oz1 = oz0 + op.height
            a < sm < b && oz0 < zm < oz1 && return true
        end
    end
    return false
end

"""
Route one segment.

Vertical: ACI 318-19 §2.3 (corpus: `aci-318-19`, PDF p. 48), length / thickness
greater than 3 is a wall. Otherwise the segment is routed to a column.

Horizontal: ACI 318-19 §9.9.1.1(a) (corpus: `aci-318-19`, PDF p. 154). Clear
span greater than four times the overall depth is a beam. Otherwise R9.9.1.1
on that page sends this side-supported member to Chapter 23.

ENGINEERING JUDGMENT: §9.9.1.1(b) (a concentrated load within `2h` of a
support) is not evaluated. The span rule alone selects `:beam` or `:stm`.
"""
function _segment_design(kind::Symbol, s0, s1, z0, z1, t)
    if kind === :vertical
        lw = s1 - s0
        lw > 0 || throw(ArgumentError("wall segments: a vertical segment has no length."))
        # ACI 318-19 §2.3 (corpus: aci-318-19, PDF p. 48): a wall has
        # horizontal length-to-thickness ratio greater than 3.
        return lw / t > 3 ? :wall : :column
    end
    ln = s1 - s0
    h = z1 - z0
    (ln > 0 && h > 0) || throw(ArgumentError(
        "wall segments: a horizontal segment has no span or no depth."))
    # ACI 318-19 §9.9.1.1(a) (corpus: aci-318-19, PDF p. 154): clear span
    # does not exceed four times the overall member depth h.
    # R9.9.1.1, same page: a deep member supported on its sides is designed
    # by Chapter 23.
    return ln / h > 4 ? :beam : :stm
end

"Thickness, in metres, of the walls this segment overlaps. One value, or a throw."
function _segment_thickness(walls, stack, skel, z0, z1)
    ts = Float64[]
    owners = Int[]
    for i in stack
        zb, zt = _segment_wall_z(walls[i], skel)
        min(zt, z1) - max(zb, z0) > WALL_OPENING_GAP_M || continue
        push!(ts, _length_metres(walls[i].thickness, "thickness"))
        push!(owners, i)
    end
    isempty(ts) && throw(ArgumentError(
        "wall segments: a segment from z = $z0 m to $z1 m overlaps no wall."))
    if maximum(ts) - minimum(ts) > WALL_OPENING_GAP_M
        throw(ArgumentError(
            "wall segments: walls $owners overlap one segment and their " *
            "thicknesses differ by more than 1 mm ($(minimum(ts)) m to " *
            "$(maximum(ts)) m). No thickness is assumed."))
    end
    return ts[1], owners
end

"Runs `(s0, s1, z0, z1)` merged along `z` when `s` matches, or along `s` when `z` matches."
function _merge_segment_runs(runs, vertical::Bool)
    if vertical
        sort!(runs; by=r -> (r[1], r[2], r[3]))
    else
        sort!(runs; by=r -> (r[3], r[4], r[1]))
    end
    merged = NTuple{4, Float64}[]
    for (s0, s1, z0, z1) in runs
        if !isempty(merged)
            a, b, c, d = merged[end]
            same = vertical ? (abs(a - s0) <= 1e-9 && abs(b - s1) <= 1e-9 && abs(d - z0) <= 1e-9) :
                              (abs(c - z0) <= 1e-9 && abs(d - z1) <= 1e-9 && abs(b - s0) <= 1e-9)
            if same
                merged[end] = vertical ? (a, b, c, z1) : (a, s1, c, d)
                continue
            end
        end
        push!(merged, (s0, s1, z0, z1))
    end
    return merged
end

"Centroid `(s, z)` of one shell. `s` is along `ref`. `z` is elevation."
function _shell_sz(ref, shell)
    n = length(shell.nodes)
    sx = 0.0
    sy = 0.0
    sz = 0.0
    for nd in shell.nodes
        p = nd.position
        sx += ustrip(u"m", p[1])
        sy += ustrip(u"m", p[2])
        sz += ustrip(u"m", p[3])
    end
    return _segment_s(ref, sx / n, sy / n), sz / n
end

function _segment_shells(walls, owners, ref, shells_by_wall, s0, s1, z0, z1)
    shells_by_wall === nothing && return Asap.ShellTri3[]
    out = Asap.ShellTri3[]
    for i in owners
        for shell in shells_by_wall[i]
            s, z = _shell_sz(ref, shell)
            s0 - 1e-9 < s < s1 + 1e-9 && z0 - 1e-9 < z < z1 + 1e-9 || continue
            push!(out, shell)
        end
    end
    return out
end

"True when a wall overlapping this row has an opening in this column."
function _column_opening_in_row(walls, stack, skel, ref, s0, s1, z0, z1)
    for i in stack
        wall = walls[i]
        zb, zt = _segment_wall_z(wall, skel)
        min(zt, z1) - max(zb, z0) > WALL_OPENING_GAP_M || continue
        for op in wall.openings
            a, b = _segment_opening_s(ref, wall, op)
            min(b, s1) - max(a, s0) > WALL_OPENING_GAP_M && return true
        end
    end
    return false
end

"Segments of one stack. `ref` is the wall with the lowest story, then the lowest index."
function _stack_segment_layout(walls, skel, stack, shells_by_wall)
    ref_i = argmin(i -> (walls[i].story, i), stack)
    ref = walls[ref_i]
    L = wall_length(ref)
    L > WALL_OPENING_GAP_M || throw(ArgumentError(
        "wall segments: stack wall $ref_i has no plan length."))
    zs = Float64[]
    for i in stack
        wall = walls[i]
        abs(wall_length(wall) - L) <= WALL_OPENING_GAP_M || throw(ArgumentError(
            "wall segments: stacked walls $ref_i and $i differ in length by " *
            "more than 1 mm. Their openings are not on one line."))
        zb, zt = _segment_wall_z(wall, skel)
        push!(zs, zb, zt)
    end
    zorder = sort(stack; by=i -> _segment_wall_z(walls[i], skel)[1])
    for k in 1:(length(zorder) - 1)
        _, zt = _segment_wall_z(walls[zorder[k]], skel)
        zb, _ = _segment_wall_z(walls[zorder[k + 1]], skel)
        abs(zt - zb) <= WALL_OPENING_GAP_M || throw(ArgumentError(
            "wall segments: stacked walls $(zorder[k]) and $(zorder[k + 1]) " *
            "do not meet. The lower top is $zt m and the upper base is $zb m."))
    end
    ss = Float64[0.0, L]
    for i in stack
        zb, _ = _segment_wall_z(walls[i], skel)
        for op in walls[i].openings
            a, b = _segment_opening_s(ref, walls[i], op)
            push!(ss, a, b)
            push!(zs, zb + op.z0, zb + op.z0 + op.height)
        end
    end
    S = _segment_stations(ss)
    Z = _segment_stations(zs)
    nc = length(S) - 1
    nr = length(Z) - 1
    open = [ _segment_cell_open(walls, stack, skel, ref, S[c], S[c + 1], Z[j], Z[j + 1])
             for c in 1:nc, j in 1:nr ]
    row_open = [any(open[c, j] for c in 1:nc) for j in 1:nr]
    col_open = [any(open[c, j] for j in 1:nr) for c in 1:nc]

    vruns = NTuple{4, Float64}[]
    for j in 1:nr
        row_open[j] || continue
        c = 1
        while c <= nc
            if open[c, j]
                c += 1
                continue
            end
            c0 = c
            while c <= nc && !open[c, j]
                c += 1
            end
            push!(vruns, (S[c0], S[c], Z[j], Z[j + 1]))
        end
    end
    hruns = NTuple{4, Float64}[]
    for c in 1:nc
        col_open[c] || continue
        j = 1
        while j <= nr
            # An opening row is a pier, including the cell beside another
            # story's opening. The horizontal segment stops there. A row
            # whose wall has no opening in this column is the solid story,
            # not the lintel.
            if open[c, j] || row_open[j] || !_column_opening_in_row(
                    walls, stack, skel, ref, S[c], S[c + 1], Z[j], Z[j + 1])
                j += 1
                continue
            end
            j0 = j
            while j <= nr && !open[c, j] && !row_open[j] && _column_opening_in_row(
                    walls, stack, skel, ref, S[c], S[c + 1], Z[j], Z[j + 1])
                j += 1
            end
            push!(hruns, (S[c], S[c + 1], Z[j0], Z[j]))
        end
    end

    segments = WallSegment[]
    for (kind, runs) in ((:vertical, _merge_segment_runs(vruns, true)),
                         (:horizontal, _merge_segment_runs(hruns, false)))
        for (s0, s1, z0, z1) in runs
            t, owners = _segment_thickness(walls, stack, skel, z0, z1)
            push!(segments, WallSegment(
                kind, copy(stack), owners, s0, s1, z0, z1,
                _segment_shells(walls, owners, ref, shells_by_wall, s0, s1, z0, z1),
                _segment_design(kind, s0, s1, z0, z1, t)))
        end
    end
    solid = WallSolidRow[]
    for j in 1:nr
        row_open[j] && continue
        push!(solid, WallSolidRow(copy(stack), Z[j], Z[j + 1]))
    end
    return WallSegmentLayout(segments, solid)
end
