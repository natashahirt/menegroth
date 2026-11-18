# Framing level from the beam layout.
#
# A line of collinear beams that reaches a column, a wall, or a `:support`
# vertex in two places carries itself. A line that lands on other beams is
# one level above the highest beam at either end. `Beam.level` is that rank:
# a lower level supports a higher one where they meet. Two lines of the same
# level support neither one.
#
# ENGINEERING JUDGMENT. No code states which of two crossing beams supports
# the other. The rule above is the one the deflection check uses.

"""Beam indices materialized by a framing level, as opposed to the skeleton."""
function _generated_framing_beams(struc::BuildingStructure)
    out = Set{Int}()
    for slab in struc.slabs
        for fl in slab.framing_levels
            for i in level_member_indices(struc, fl)
                push!(out, i)
            end
        end
    end
    return out
end

"""
Ordered vertices of `beam`, or `nothing` when the chain is branched or closed.

The first and last entries are the ends.
"""
function _beam_vertex_chain(struc::BuildingStructure, beam)
    pairs = Tuple{Int, Int}[]
    n_edges = length(struc.skeleton.edge_indices)
    for si in segment_indices(beam)
        e = struc.segments[si].edge_idx
        1 <= e <= n_edges || return nothing
        push!(pairs, struc.skeleton.edge_indices[e])
    end
    isempty(pairs) && return nothing
    at = Dict{Int, Vector{Int}}()
    for (a, b) in pairs
        push!(get!(at, a, Int[]), b)
        push!(get!(at, b, Int[]), a)
    end
    ends = [v for (v, ns) in at if length(ns) == 1]
    length(ends) == 2 || return nothing
    verts = Int[ends[1]]
    prev, cur = 0, ends[1]
    for _ in 1:length(pairs)
        nxt = 0
        for cand in at[cur]
            cand == prev && continue
            nxt = cand
            break
        end
        nxt == 0 && return nothing
        push!(verts, nxt)
        prev, cur = cur, nxt
    end
    return verts
end

_vertex_xyz(skel, v) = begin
    c = Meshes.coords(skel.vertices[v])
    (ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z))
end

"""Collinear when the unit directions' cross product is shorter than `tol`."""
function _collinear_dirs(a::NTuple{3, Float64}, b::NTuple{3, Float64}, tol::Float64)
    cx = a[2] * b[3] - a[3] * b[2]
    cy = a[3] * b[1] - a[1] * b[3]
    cz = a[1] * b[2] - a[2] * b[1]
    return cx * cx + cy * cy + cz * cz < tol * tol
end

"""
One straight run of beams.

`beams` are the member indices. `verts` runs from one end of the run to the
other, each joint once.
"""
struct _FrameLine
    beams::Vector{Int}
    verts::Vector{Int}
end

"""
Straight runs of every beam that has two ends.

Beams that share an end vertex and point the same way are one run, so a
column line drawn as several members is one line.
"""
function _frame_lines(struc::BuildingStructure; tol::Float64 = 1e-3)
    skel = struc.skeleton
    chains = Dict{Int, Vector{Int}}()
    dirs = Dict{Int, NTuple{3, Float64}}()
    at = Dict{Int, Vector{Int}}()
    for (bi, beam) in enumerate(struc.beams)
        chain = _beam_vertex_chain(struc, beam)
        chain === nothing && continue
        p = _vertex_xyz(skel, chain[1])
        q = _vertex_xyz(skel, chain[end])
        d = (q[1] - p[1], q[2] - p[2], q[3] - p[3])
        L = sqrt(d[1]^2 + d[2]^2 + d[3]^2)
        L < 1e-9 && continue
        chains[bi] = chain
        dirs[bi] = (d[1] / L, d[2] / L, d[3] / L)
        push!(get!(at, chain[1], Int[]), bi)
        push!(get!(at, chain[end], Int[]), bi)
    end
    seen = Set{Int}()
    lines = _FrameLine[]
    for seed in keys(chains)
        seed in seen && continue
        group = Int[]
        stack = Int[seed]
        push!(seen, seed)
        while !isempty(stack)
            cur = pop!(stack)
            push!(group, cur)
            a, b = chains[cur][1], chains[cur][end]
            for v in (a, b)
                for nb in get(at, v, Int[])
                    nb in seen && continue
                    haskey(dirs, nb) || continue
                    _collinear_dirs(dirs[cur], dirs[nb], tol) || continue
                    push!(seen, nb)
                    push!(stack, nb)
                end
            end
        end
        push!(lines, _FrameLine(group, _order_line_vertices(group, chains)))
    end
    return lines
end

"""Vertices of `beams` in order along the run, including each beam's interior joints."""
function _order_line_vertices(beams::Vector{Int}, chains::Dict{Int, Vector{Int}})
    wanted = Set(beams)
    at = Dict{Int, Vector{Int}}()
    for bi in beams
        push!(get!(at, chains[bi][1], Int[]), bi)
        push!(get!(at, chains[bi][end], Int[]), bi)
    end
    start = nothing
    for (v, bs) in at
        count(in(wanted), bs) == 1 && (start = v; break)
    end
    start === nothing && (start = first(keys(at)))
    verts = Int[]
    prev = 0
    cur = start
    incoming = nothing
    for _ in 1:length(beams)
        nxt = 0
        for bi in get(at, cur, Int[])
            bi == prev && continue
            bi in wanted || continue
            nxt = bi
            break
        end
        nxt == 0 && break
        chain = chains[nxt]
        chain[1] == cur || reverse!(chain)
        if incoming === nothing
            append!(verts, chain)
        else
            append!(verts, @view chain[2:end])
        end
        prev = nxt
        cur = chain[end]
        incoming = nxt
    end
    return verts
end

"""
    assign_framing_levels!(struc) -> struc

Write `Beam.level` from [`_frame_lines`](@ref).

A line with two or more column, wall, or `:support` vertices is level 0.
Any other line, once both of its ends are known, is one level above the
higher of those ends. An end on a column or a free tip counts as ground.
Lines that close a loop on each other share the highest level already
assigned, so neither supports the other.
"""
function assign_framing_levels!(struc::BuildingStructure)
    lines = _frame_lines(struc)
    isempty(lines) && return struc
    fixed = beam_support_lookup(struc).fixed
    at = Dict{Int, Vector{Int}}()
    for (i, ln) in enumerate(lines)
        for v in ln.verts
            push!(get!(at, v, Int[]), i)
        end
    end
    rank = Vector{Union{Nothing, Int}}(nothing, length(lines))
    for i in eachindex(lines)
        count(v -> v in fixed, lines[i].verts) >= 2 && (rank[i] = 0)
    end
    moved = true
    while moved
        moved = false
        for i in eachindex(lines)
            rank[i] === nothing || continue
            deps = Int[]
            known = true
            for v in (lines[i].verts[1], lines[i].verts[end])
                if v in fixed
                    push!(deps, -1)
                    continue
                end
                others = [j for j in get(at, v, Int[]) if j != i]
                if isempty(others)
                    push!(deps, -1)
                    continue
                end
                for j in others
                    if rank[j] === nothing
                        known = false
                        break
                    end
                    push!(deps, rank[j])
                end
                known || break
            end
            known || continue
            rank[i] = max(0, 1 + maximum(deps))
            moved = true
        end
    end
    top = maximum(something(r, -1) for r in rank)
    fallback = top < 0 ? 0 : top
    for (i, ln) in enumerate(lines)
        lv = something(rank[i], fallback)
        for bi in ln.beams
            struc.beams[bi].level = lv
        end
    end
    return struc
end

"""Station (m) of each vertex along `verts`, and the polyline coordinates."""
function _line_stations(skel, verts::Vector{Int})
    xy = [_vertex_xyz(skel, v) for v in verts]
    cum = zeros(length(verts))
    for k in 2:length(verts)
        d = xy[k] .- xy[k - 1]
        cum[k] = cum[k - 1] + sqrt(d[1]^2 + d[2]^2 + d[3]^2)
    end
    return cum, xy
end

"""
Stations (m) where `line` is held up: a column, a wall, a `:support`, or a
line of a lower framing level.
"""
function _line_support_stations(line::_FrameLine, line_index::Int, lines, at, fixed, cum, level_of)
    mine = level_of[line_index]
    out = Float64[]
    for (k, v) in enumerate(line.verts)
        held = v in fixed
        if !held
            for j in get(at, v, Int[])
                j == line_index && continue
                level_of[j] < mine || continue
                held = true
                break
            end
        end
        held && push!(out, cum[k])
    end
    return out
end
