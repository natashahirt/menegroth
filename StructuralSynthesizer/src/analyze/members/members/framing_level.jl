# Framing level from the beam layout.
#
# A line with two columns, walls, or `:support` vertices is level 0 and stays
# one piece. Any other line is cut where a beam that already has a level
# crosses it. When two unranked spans cross and both already reach a support
# at each end, the shorter one is ranked and the longer one is cut. Equal
# lengths support neither. A piece's level is one above the higher beam it
# stops on. A free tip does not raise the level.
#
# ENGINEERING JUDGMENT. No code states which of two crossing beams supports
# the other. This is the rule the deflection check uses. It is the one read
# off the hand-drawn 2024 strokes: the stroke that runs through a joint is
# the longer one, and the strokes that stop there are carried by it.

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

"""One straight piece after a longer span has been cut at a shorter one."""
struct _SpanPiece
    beams::Vector{Int}
    verts::Vector{Int}
end

"""Where `piece`'s beams sit on its vertices: `(beam, first index, last index)`."""
function _piece_beam_spans(struc::BuildingStructure, piece::_SpanPiece)
    pos = Dict{Int, Int}()
    for (k, v) in enumerate(piece.verts)
        get!(pos, v, k)
    end
    spans = Tuple{Int, Int, Int}[]
    for bi in piece.beams
        chain = _beam_vertex_chain(struc, struc.beams[bi])
        chain === nothing && continue
        ks = Int[pos[v] for v in chain if haskey(pos, v)]
        isempty(ks) && continue
        push!(spans, (bi, minimum(ks), maximum(ks)))
    end
    sort!(spans; by = s -> s[2])
    return spans
end

"""Plan length (m) of `verts`."""
function _chain_length(skel, verts::Vector{Int})
    cum, _ = _line_stations(skel, verts)
    return cum[end]
end

"""
Pieces of `piece` on either side of `cuts`.

A cut that falls in the middle of one beam is dropped. A member has one level,
and the skeleton is what splits a beam at a joint.
"""
function _split_piece(struc::BuildingStructure, piece::_SpanPiece, cuts)
    spans = _piece_beam_spans(struc, piece)
    keep = Int[k for k in cuts if !any(s -> s[2] < k < s[3], spans)]
    isempty(keep) && return _SpanPiece[piece]
    sort!(keep)
    bounds = [1; keep; length(piece.verts)]
    out = _SpanPiece[]
    for i in 1:(length(bounds) - 1)
        a, b = bounds[i], bounds[i + 1]
        a < b || continue
        beams = Int[s[1] for s in spans if a <= s[2] && s[3] <= b]
        isempty(beams) && continue
        push!(out, _SpanPiece(beams, piece.verts[a:b]))
    end
    return isempty(out) ? _SpanPiece[piece] : out
end

"""
Cut longer spans where a shorter span that already reaches supports crosses them.

`placed` marks pieces that have been accepted and now cut whatever crosses
them. The numbers those pieces eventually carry are assigned afterwards.
"""
function _cut_shorter_spans!(struc::BuildingStructure, pieces::Vector{_SpanPiece},
                             placed::Vector{Bool}, fixed)
    skel = struc.skeleton
    n0 = length(pieces)
    for _ in 1:(4 * n0 + 8)
        at = Dict{Int, Vector{Int}}()
        for (i, p) in enumerate(pieces)
            for v in p.verts
                push!(get!(at, v, Int[]), i)
            end
        end
        cut_any = false
        nxt_p = _SpanPiece[]
        nxt_f = Bool[]
        for (i, p) in enumerate(pieces)
            cuts = Int[]
            if !placed[i]
                for k in 2:(length(p.verts) - 1)
                    any(j -> j != i && placed[j], get(at, p.verts[k], Int[])) || continue
                    push!(cuts, k)
                end
            end
            parts = isempty(cuts) ? _SpanPiece[p] : _split_piece(struc, p, cuts)
            length(parts) == 1 || (cut_any = true)
            for part in parts
                push!(nxt_p, part)
                push!(nxt_f, length(parts) == 1 && placed[i])
            end
        end
        if cut_any
            pieces, placed = nxt_p, nxt_f
            continue
        end
        supported(v, i) = v in fixed ||
            let others = [j for j in get(at, v, Int[]) if j != i]
                isempty(others) || any(j -> placed[j], others)
            end
        ready = Int[i for (i, p) in enumerate(pieces)
                    if !placed[i] && supported(p.verts[1], i) && supported(p.verts[end], i)]
        isempty(ready) && break
        lengths = Dict(i => _chain_length(skel, pieces[i].verts) for i in ready)
        blocked = Set{Int}()
        for i in ready
            p = pieces[i]
            for k in 2:(length(p.verts) - 1)
                for j in get(at, p.verts[k], Int[])
                    j in keys(lengths) || continue
                    lengths[j] < lengths[i] - 1e-4 || continue
                    push!(blocked, i)
                end
            end
        end
        commit = isempty(setdiff(ready, blocked)) ? ready : [i for i in ready if i ∉ blocked]
        for i in commit
            placed[i] = true
        end
    end
    return pieces, placed
end

"""
Level of each piece from the beams that run through its ends.

An end on a column, a wall, a `:support`, or a free tip is ground (`-1`).
Where several pieces meet, the one that runs through the joint carries the
ones that stop. Pieces that only hold each other up share the highest level
already assigned.
"""
function _wave_levels(pieces::Vector{_SpanPiece}, fixed)
    at = Dict{Int, Vector{Tuple{Int, Int, Int}}}()
    for (i, p) in enumerate(pieces)
        n = length(p.verts)
        for (k, v) in enumerate(p.verts)
            push!(get!(at, v, Tuple{Int, Int, Int}[]), (i, k, n))
        end
    end
    rank = Vector{Union{Nothing, Int}}(nothing, length(pieces))
    for i in eachindex(pieces)
        count(v -> v in fixed, pieces[i].verts) >= 2 && (rank[i] = 0)
    end
    for _ in 1:(length(pieces) + 2)
        moved = false
        for i in eachindex(pieces)
            rank[i] === nothing || continue
            deps = Int[]
            known = true
            for v in (pieces[i].verts[1], pieces[i].verts[end])
                if v in fixed
                    push!(deps, -1)
                    continue
                end
                others = [h for h in get(at, v, Tuple{Int, Int, Int}[]) if h[1] != i]
                if isempty(others)
                    push!(deps, -1)
                    continue
                end
                through = [h for h in others if 1 < h[2] < h[3]]
                pool = isempty(through) ? others : through
                for h in pool
                    if rank[h[1]] === nothing
                        known = false
                        break
                    end
                    push!(deps, rank[h[1]])
                end
                known || break
            end
            known || continue
            rank[i] = max(0, 1 + maximum(deps))
            moved = true
        end
        moved || break
    end
    top = maximum(something(r, -1) for r in rank)
    fallback = top < 0 ? 0 : top
    return [something(r, fallback) for r in rank]
end

"""
    assign_framing_levels!(struc) -> struc

Write `Beam.level` for every straight beam.

A line with two or more column, wall, or `:support` vertices is level 0.
A longer line is cut where a shorter line, already reaching a support at
both ends, crosses it. Each piece is then one level above the higher beam
at either end. Pieces that close a loop on each other share the highest
level already assigned, so neither supports the other.
"""
function assign_framing_levels!(struc::BuildingStructure)
    lines = _frame_lines(struc)
    isempty(lines) && return struc
    fixed = beam_support_lookup(struc).fixed
    pieces = [_SpanPiece(ln.beams, ln.verts) for ln in lines]
    placed = [count(v -> v in fixed, p.verts) >= 2 for p in pieces]
    pieces, _ = _cut_shorter_spans!(struc, pieces, placed, fixed)
    rank = _wave_levels(pieces, fixed)
    for (i, p) in enumerate(pieces)
        for bi in p.beams
            struc.beams[bi].level = rank[i]
        end
    end
    return struc
end

"""
Runs of one framing level along each straight line.

Beams of the same level stay one run, so a shorter beam that crosses the
middle is a support of that run. A change of level starts a new run. Each
beam keeps the level [`assign_framing_levels!`](@ref) wrote.
"""
function _constant_level_lines(struc::BuildingStructure, lines::Vector{_FrameLine})
    out = _FrameLine[]
    for ln in lines
        spans = _piece_beam_spans(struc, _SpanPiece(ln.beams, ln.verts))
        isempty(spans) && continue
        acc = Int[spans[1][1]]
        k0, k1 = spans[1][2], spans[1][3]
        lv = struc.beams[spans[1][1]].level
        function _push()
            push!(out, _FrameLine(copy(acc), ln.verts[k0:k1]))
        end
        for s in @view spans[2:end]
            blv = struc.beams[s[1]].level
            if blv == lv && s[2] <= k1 + 1
                push!(acc, s[1])
                k1 = max(k1, s[3])
            else
                _push()
                empty!(acc)
                push!(acc, s[1])
                k0, k1, lv = s[2], s[3], blv
            end
        end
        _push()
    end
    return out
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
