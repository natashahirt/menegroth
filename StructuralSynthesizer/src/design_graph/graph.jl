# =============================================================================
# DesignGraph — Container + Topological Ordering
# =============================================================================
#
# A `DesignGraph` holds a set of `DesignNode`s and their dependency edges. Edges
# are implicit: each node declares the keys of its predecessors via
# `dependencies(node)`. The graph validates keys, then produces a deterministic
# topological ordering for the executor.
#
# Determinism note: ties (nodes that become ready at the same time) are broken
# by insertion order. For the Run-1 linear chain this reproduces the exact stage
# sequence of the pre-graph pipeline loop.
# =============================================================================

"""
    DesignGraph

Container for a set of [`DesignNode`](@ref)s and their directed dependency
edges. Construct from a vector of nodes; the constructor validates that every
declared dependency refers to an existing node and that keys are unique.

Use [`topological_order`](@ref) to get a dependency-respecting execution order
and [`execute_graph!`](@ref) to run the nodes against a `BuildingStructure`.
"""
struct DesignGraph
    nodes::Vector{DesignNode}
    index::Dict{NodeKey, Int}   # node_key -> position in `nodes`
end

"""
    DesignGraph(nodes::AbstractVector{<:DesignNode}) -> DesignGraph

Build a graph from `nodes`. Throws `ArgumentError` on duplicate keys or on a
dependency referencing a key that is not present in `nodes`.
"""
function DesignGraph(nodes::AbstractVector{<:DesignNode})
    index = Dict{NodeKey, Int}()
    for (i, node) in enumerate(nodes)
        k = node_key(node)
        haskey(index, k) && throw(ArgumentError("DesignGraph: duplicate node key :$k"))
        index[k] = i
    end
    for node in nodes
        for d in dependencies(node)
            haskey(index, d) || throw(ArgumentError(
                "DesignGraph: node :$(node_key(node)) depends on unknown key :$d"))
        end
    end
    return DesignGraph(collect(DesignNode, nodes), index)
end

"""
    nodes(g::DesignGraph) -> Vector{DesignNode}

The graph's nodes, in insertion order.
"""
nodes(g::DesignGraph) = g.nodes

"""
    get_node(g::DesignGraph, key::NodeKey) -> DesignNode

Fetch the node with `key`. Throws `KeyError` if absent.
"""
get_node(g::DesignGraph, key::NodeKey) = g.nodes[g.index[key]]

Base.length(g::DesignGraph) = length(g.nodes)

"""
    topological_order(g::DesignGraph) -> Vector{NodeKey}

Return the node keys in a dependency-respecting order (every node appears after
all of its `dependencies`). Uses Kahn's algorithm with insertion-order
tie-breaking, so the ordering is deterministic and, for a linear chain,
identical to the insertion order. Throws `ArgumentError` if the graph contains
a cycle.
"""
function topological_order(g::DesignGraph)
    n = length(g.nodes)
    indeg = zeros(Int, n)
    succ = [Int[] for _ in 1:n]   # i -> nodes that depend on i
    for (i, node) in enumerate(g.nodes)
        for d in dependencies(node)
            j = g.index[d]
            push!(succ[j], i)
            indeg[i] += 1
        end
    end

    # Tie-break rule: ties (multiple nodes ready at once) are broken by
    # insertion index for determinism — the ready set is kept sorted ascending
    # by node position, so the earliest-inserted ready node is always emitted
    # first. This makes the diamond order deterministic and, for a linear chain,
    # identical to insertion order. (Pinned by test_design_graph_topology.jl.)
    ready = [i for i in 1:n if indeg[i] == 0]
    order = NodeKey[]
    sizehint!(order, n)
    while !isempty(ready)
        i = popfirst!(ready)
        push!(order, node_key(g.nodes[i]))
        for j in succ[i]
            indeg[j] -= 1
            if indeg[j] == 0
                push!(ready, j)
                sort!(ready)
            end
        end
    end

    length(order) == n || throw(ArgumentError("DesignGraph: cycle detected in dependencies"))
    return order
end

"""
    topological_levels(g::DesignGraph) -> Vector{Vector{NodeKey}}

Return the node keys grouped into dependency **levels** (Kahn waves): level `k`
holds every node all of whose `dependencies` lie in strictly earlier levels.
Nodes within a level are mutually independent (no edges among them) and are
listed in insertion-index order — the same tie-break as [`topological_order`](@ref)
— so concatenating the levels yields a valid topological order and, for a linear
chain, reproduces the insertion sequence one node per level. Throws
`ArgumentError` if the graph contains a cycle.

This is the level/barrier boundary the executor ([`execute_graph!`](@ref)) and the
incremental scheduler ([`run_target!`](@ref)) use to flush `sync_asap!` exactly
ONCE after a completed level (rather than once per node), so a level that later
holds MULTIPLE sizing nodes still syncs only once. For the current coarse linear
chain every level holds exactly one node, so the sync sequence is byte-identical
to the per-node placement.
"""
function topological_levels(g::DesignGraph)
    n = length(g.nodes)
    indeg = zeros(Int, n)
    succ = [Int[] for _ in 1:n]   # i -> nodes that depend on i
    for (i, node) in enumerate(g.nodes)
        for d in dependencies(node)
            j = g.index[d]
            push!(succ[j], i)
            indeg[i] += 1
        end
    end

    # Each wave is the ENTIRE current ready set (indeg == 0), emitted in
    # insertion-index order to match `topological_order`'s tie-break. Popping the
    # whole ready set at once (instead of one node) is what turns Kahn's per-node
    # order into per-level waves.
    ready = sort!([i for i in 1:n if indeg[i] == 0])
    levels = Vector{NodeKey}[]
    seen = 0
    while !isempty(ready)
        push!(levels, NodeKey[node_key(g.nodes[i]) for i in ready])
        seen += length(ready)
        next_ready = Int[]
        for i in ready
            for j in succ[i]
                indeg[j] -= 1
                indeg[j] == 0 && push!(next_ready, j)
            end
        end
        ready = sort!(next_ready)
    end

    seen == n || throw(ArgumentError("DesignGraph: cycle detected in dependencies"))
    return levels
end

"""
    level_needs_sync(g::DesignGraph, level) -> Bool

Whether running the nodes in `level` requires a single `sync_asap!` barrier after
the level: `true` iff ANY node in `level` declares [`needs_sync`](@ref). Callers
pass either a whole level ([`execute_graph!`](@ref) — every node runs) or the
recomputed subset of a level ([`run_target!`](@ref) — only dirty nodes did work),
so the barrier fires exactly when a node that needs a sync actually ran. An empty
`level` yields `false`. Reduces to the per-node `needs_sync` decision when a level
holds one node.
"""
level_needs_sync(g::DesignGraph, level) =
    any(needs_sync(get_node(g, k)) for k in level)

# =============================================================================
# Graph queries (Run 2) — transitive deps + descendants for the scheduler
# =============================================================================

"""
    transitive_dependencies(g::DesignGraph, target::NodeKey; include_self=true)
        -> Vector{NodeKey}

All nodes that must run before `target` (its dependencies, transitively),
returned in dependency-respecting [`topological_order`](@ref). When
`include_self` is `true` (default) `target` itself is included as the last
relevant node. This is the demand-driven "what does this target need" set the
scheduler walks.
"""
function transitive_dependencies(g::DesignGraph, target::NodeKey; include_self::Bool = true)
    haskey(g.index, target) || throw(KeyError(target))
    needed = Set{NodeKey}()
    stack = NodeKey[target]
    while !isempty(stack)
        k = pop!(stack)
        k in needed && continue
        push!(needed, k)
        for d in dependencies(get_node(g, k))
            d in needed || push!(stack, d)
        end
    end
    include_self || delete!(needed, target)
    return NodeKey[k for k in topological_order(g) if k in needed]
end

"""
    descendants(g::DesignGraph, seeds; include_seeds=true) -> Vector{NodeKey}

All nodes reachable *forward* along dependency edges from any key in `seeds`
(i.e. every node that transitively depends on a seed), in
[`topological_order`](@ref). Used by [`dirty_frontier`](@ref) to propagate a
parameter change from the nodes it directly touches to everything downstream.
`seeds` may be a single `NodeKey` or an iterable of keys.
"""
descendants(g::DesignGraph, seed::NodeKey; include_seeds::Bool = true) =
    descendants(g, (seed,); include_seeds = include_seeds)

function descendants(g::DesignGraph, seeds; include_seeds::Bool = true)
    seedset = Set{NodeKey}(seeds)
    for s in seedset
        haskey(g.index, s) || throw(KeyError(s))
    end
    # Forward adjacency: key -> nodes that depend on it.
    succ = Dict{NodeKey, Vector{NodeKey}}(node_key(nd) => NodeKey[] for nd in g.nodes)
    for nd in g.nodes
        for d in dependencies(nd)
            push!(succ[d], node_key(nd))
        end
    end
    reached = Set{NodeKey}()
    stack = collect(NodeKey, seedset)
    while !isempty(stack)
        k = pop!(stack)
        for c in succ[k]
            if !(c in reached)
                push!(reached, c)
                push!(stack, c)
            end
        end
    end
    include_seeds && union!(reached, seedset)
    return NodeKey[k for k in topological_order(g) if k in reached]
end
