#=
Plan automorphism scan (read-only, analysis-free).

Prototype for the symmetry-policy "automorphism proposer"
(docs/sizing-map/symmetry-policy.md, plan-ec7031af). For every SDF plan it
computes the finite isometry automorphism group of the labeled framing graph
(vertices + beam lines + column nodes) and the resulting beam-line ORBITS, with
NO structural analysis and NO sizing — so it is safe to run across the whole
geometry corpus in seconds and it directly surfaces unexpected symmetries.

Algorithm (standard symmetry detection of a finite labeled point set):
  * Every isometry fixing the set fixes the centroid, so it is a rotation about
    the centroid or a reflection through it.
  * Candidates come from the farthest vertex: any symmetry maps it to an equally
    far vertex, giving O(n) candidate rotations (angle differences) and O(n)
    candidate reflections (axis = angle bisector). Verify each by checking it
    permutes the vertices (within tol) AND preserves the beam-line set AND the
    column-node set.
  * The verified permutations form the automorphism group; beam-line orbits are
    the union-find classes under its generators. Collapse ratio = lines/orbits
    is the proxy speed win (and the number of distinct beam-sizing problems a
    symmetry-aware policy would solve instead of one per line).

    julia --project=StructuralStudies scripts/runners/plan_symmetry_scan.jl
    # optional: restrict to sets, e.g. ... plan_symmetry_scan.jl star topology
=#

using JSON3
using LinearAlgebra
using Printf
using Statistics

const GEOM_ROOT = normpath(joinpath(@__DIR__, "..", "..", "..", "..",
                                    "2024_Slab Design Factors", "Geometries"))
const TOL = 1e-6   # vertex-match tolerance (m); plan coords are exact integers

"""Parsed plan: vertex xy (m), beam lines (1-based node pairs), column nodes."""
struct Plan
    name::String
    xy::Vector{NTuple{2, Float64}}
    lines::Vector{Tuple{Int, Int}}
    columns::Vector{Int}
end

"""Read one SDF plan JSON (a JSON string that holds the JSON object)."""
function read_plan(path::AbstractString, name::AbstractString)
    raw = JSON3.read(read(path, String))
    raw isa AbstractString && (raw = JSON3.read(raw))
    xy = NTuple{2, Float64}[(Float64(p.x), Float64(p.y)) for p in raw.positions]
    lines = Tuple{Int, Int}[(Int(c.from), Int(c.to)) for c in raw.connectivities]
    cols = haskey(raw, :columns_i) ? Int[Int(round(Int, c)) for c in raw.columns_i] : Int[]
    return Plan(name, xy, lines, cols)
end

# Round to the match grid AND normalize signed zero: an isometry can map a
# centerline vertex coordinate to -0.0, and Julia's Dict treats -0.0 and 0.0 as
# distinct keys (isequal(-0.0, 0.0) === false), which would drop the match.
_rz(v) = (r = round(v; digits = 6); r == 0.0 ? 0.0 : r)
_key(p) = (_rz(p[1]), _rz(p[2]))

"""Permutation induced by isometry `M` on the centroid-shifted points `P`, or
`nothing` if `M` is not a vertex bijection within `TOL`."""
function induced_perm(M, P, lookup)
    n = length(P)
    perm = Vector{Int}(undef, n)
    seen = falses(n)
    @inbounds for i in 1:n
        x, y = P[i]
        qx = M[1, 1] * x + M[1, 2] * y
        qy = M[2, 1] * x + M[2, 2] * y
        j = get(lookup, (_rz(qx), _rz(qy)), 0)
        (j == 0 || seen[j]) && return nothing   # not onto / collision ⇒ reject
        perm[i] = j; seen[j] = true
    end
    return perm
end

"""Does `perm` preserve the beam-line set and the column-node set?"""
function preserves_labels(perm, line_set, cols)
    for (a, b) in line_set
        pa, pb = perm[a], perm[b]
        (pa < pb ? (pa, pb) : (pb, pa)) in line_set || return false
    end
    isempty(cols) && return true
    return Set(perm[c] for c in cols) == Set(cols)
end

"""Finite isometry automorphism group as a list of (matrix, permutation)."""
function automorphisms(plan::Plan)
    V = plan.xy
    n = length(V)
    c = (mean(getindex.(V, 1)), mean(getindex.(V, 2)))
    P = [(V[i][1] - c[1], V[i][2] - c[2]) for i in 1:n]
    lookup = Dict(_key(P[i]) => i for i in 1:n)
    line_set = Set(a < b ? (a, b) : (b, a) for (a, b) in plan.lines)

    # Reference = farthest vertex from the centroid; a symmetry maps it to an
    # equally far vertex, which seeds all candidate rotations and reflections.
    r = [hypot(p[1], p[2]) for p in P]
    i0 = argmax(r); r0 = r[i0]
    r0 < TOL && return [([1.0 0.0; 0.0 1.0], collect(1:n))]  # degenerate
    θ0 = atan(P[i0][2], P[i0][1])
    far = [i for i in 1:n if abs(r[i] - r0) <= TOL]

    cands = Matrix{Float64}[[1.0 0.0; 0.0 1.0]]
    for j in far
        θj = atan(P[j][2], P[j][1])
        a = θj - θ0                                   # rotation i0 -> j
        push!(cands, [cos(a) -sin(a); sin(a) cos(a)])
        φ = (θ0 + θj) / 2                             # reflection axis i0 -> j
        push!(cands, [cos(2φ) sin(2φ); sin(2φ) -cos(2φ)])
    end

    group = Tuple{Matrix{Float64}, Vector{Int}}[]
    seen = Set{NTuple{4, Float64}}()
    for M in cands
        k = (_rz(M[1,1]), _rz(M[1,2]), _rz(M[2,1]), _rz(M[2,2]))
        k in seen && continue
        push!(seen, k)
        perm = induced_perm(M, P, lookup)
        perm === nothing && continue
        preserves_labels(perm, line_set, plan.columns) || continue
        push!(group, (M, perm))
    end
    return group
end

"""Union-find: number of beam-line orbits under the group's permutations."""
function line_orbits(plan::Plan, group)
    line_set = Set(a < b ? (a, b) : (b, a) for (a, b) in plan.lines)
    idx = Dict{Tuple{Int, Int}, Int}()
    for (k, ln) in enumerate(sort(collect(line_set)))
        idx[ln] = k
    end
    m = length(idx)
    parent = collect(1:m)
    find(x) = (parent[x] == x ? x : (parent[x] = find(parent[x])))
    union!(a, b) = (parent[find(a)] = find(b))
    for (_, perm) in group
        for (ln, k) in idx
            a, b = perm[ln[1]], perm[ln[2]]
            img = a < b ? (a, b) : (b, a)
            union!(k, idx[img])
        end
    end
    return length(Set(find(k) for k in 1:m))
end

"""Name the point group from its order and reflection count."""
function group_label(group)
    order = length(group)
    refl = count(g -> det(g[1]) < 0, group)
    order == 1 && return "C1"
    refl == 0 && return "C$order"
    return "D$(order ÷ 2)"
end

function scan_set(set::AbstractString)
    dir = joinpath(GEOM_ROOT, set)
    isdir(dir) || return NamedTuple[]
    rows = NamedTuple[]
    for f in sort(readdir(dir))
        endswith(f, ".json") || continue
        name = string(set, "/", splitext(f)[1])
        plan = try
            read_plan(joinpath(dir, f), name)
        catch err
            @warn "skip $name" err
            continue
        end
        g = automorphisms(plan)
        norb = line_orbits(plan, g)
        push!(rows, (name = name, nodes = length(plan.xy), lines = length(plan.lines),
                     group = group_label(g), order = length(g),
                     orbits = norb, collapse = length(plan.lines) / norb))
    end
    return rows
end

function main(sets)
    all_rows = NamedTuple[]
    for set in sets
        rows = scan_set(set)
        isempty(rows) && continue
        append!(all_rows, rows)
        nontriv = count(r -> r.order > 1, rows)
        meancol = mean(getfield.(rows, :collapse))
        groups = sort(unique(getfield.(rows, :group)))
        gcount = join(["$gp:$(count(r -> r.group == gp, rows))" for gp in groups], " ")
        @printf("\n===== %-9s  %d plans | %d with symmetry | mean collapse %.2fx =====\n",
                set, length(rows), nontriv, meancol)
        println("  groups: ", gcount)
        for r in sort(rows; by = x -> -x.collapse)
            r.order == 1 && continue
            @printf("  %-14s nodes=%-4d lines=%-4d  %-4s(|%d|)  orbits=%-4d collapse=%.2fx\n",
                    r.name, r.nodes, r.lines, r.group, r.order, r.orbits, r.collapse)
        end
    end
    if !isempty(all_rows)
        nontriv = count(r -> r.order > 1, all_rows)
        @printf("\n===== TOTAL  %d plans | %d with nontrivial symmetry (%.0f%%) | mean collapse %.2fx =====\n",
                length(all_rows), nontriv, 100 * nontriv / length(all_rows),
                mean(getfield.(all_rows, :collapse)))
    end
    return nothing
end

sets = isempty(ARGS) ? ["grid", "nova", "special", "star", "topology"] : ARGS
main(sets)
