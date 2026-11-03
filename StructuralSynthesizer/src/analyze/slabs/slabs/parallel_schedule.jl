# =============================================================================
# Slab Parallel Coloring (graph coloring for concurrent slab sizing)
# =============================================================================

"""
    slab_conflict_coloring(slab_column_sets::Vector{Set{Int}}) -> Vector{Vector{Int}}

Graph-color slabs by column conflict. Two slabs conflict if they share
any supporting column index. Returns batches of non-conflicting slab
indices (1-based) suitable for `Threads.@threads` execution.

Uses greedy coloring with largest-degree-first ordering.
"""
function slab_conflict_coloring(slab_column_sets::Vector{Set{Int}})
    n = length(slab_column_sets)
    n == 0 && return Vector{Int}[]

    # Build conflict adjacency (edge if two slabs share a column)
    neighbors = [Set{Int}() for _ in 1:n]
    for i in 1:n, j in (i+1):n
        if !isempty(intersect(slab_column_sets[i], slab_column_sets[j]))
            push!(neighbors[i], j)
            push!(neighbors[j], i)
        end
    end

    # Greedy coloring (largest-degree-first for fewer colors)
    colors = zeros(Int, n)
    order = sortperm([length(neighbors[i]) for i in 1:n], rev=true)

    for idx in order
        used = Set(colors[nb] for nb in neighbors[idx] if colors[nb] > 0)
        c = 1
        while c in used
            c += 1
        end
        colors[idx] = c
    end

    # Group by color → batches
    n_colors = maximum(colors; init=0)
    batches = [Int[] for _ in 1:n_colors]
    for (idx, c) in enumerate(colors)
        push!(batches[c], idx)
    end

    return batches
end

"""
    compute_slab_parallel_batches!(struc)

Build the slab conflict graph from slab–column tributary overlap and
graph-color it so that slabs in each batch share no columns.

Stores result in `struc.slab_parallel_batches` for reuse by `size_slabs!`.
"""
function compute_slab_parallel_batches!(struc)
    n_slabs = length(struc.slabs)
    if n_slabs == 0
        struc.slab_parallel_batches = Vector{Int}[]
        return struc
    end

    # Build slab → column set mapping via tributary cell overlap
    slab_column_sets = Vector{Set{Int}}(undef, n_slabs)
    for (s_idx, slab) in enumerate(struc.slabs)
        slab_cells = Set(slab.cell_indices)
        col_set = Set{Int}()
        for (c_idx, col) in enumerate(struc.columns)
            if !isempty(col.tributary_cell_indices) &&
               !isempty(intersect(col.tributary_cell_indices, slab_cells))
                push!(col_set, c_idx)
            end
        end
        slab_column_sets[s_idx] = col_set
    end

    struc.slab_parallel_batches = slab_conflict_coloring(slab_column_sets)
    return struc
end