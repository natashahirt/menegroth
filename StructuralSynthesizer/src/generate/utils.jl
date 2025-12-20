function add_vertex!(skel::StructureSkeleton, pt::Meshes.Point; group::Symbol=:unknown)
    # check if vertex exists
    idx = findfirst(v -> v == pt, skel.vertices)
    if isnothing(idx)
        push!(skel.vertices, pt)
        Graphs.add_vertex!(skel.graph)
        idx = length(skel.vertices)
    end

    # assign to group
    if !haskey(skel.groups_vertices, group)
        skel.groups_vertices[group] = Int[]
    end
    
    if !(idx in skel.groups_vertices[group])
        push!(skel.groups_vertices[group], idx)
    end

    return idx
end

function add_element!(skel::StructureSkeleton, seg::Meshes.Segment, group::Symbol)
    # get/create vertex indices
    v_indices = Vector{Int}(undef, 2)
    
    v_indices[1] = add_vertex!(skel, Meshes.vertices(seg)[1])
    v_indices[2] = add_vertex!(skel, Meshes.vertices(seg)[2])

    # add as an edge
    push!(skel.edges, seg)
    edge_idx = length(skel.edges)
    Graphs.add_edge!(skel.graph, v_indices[1], v_indices[2])

    # assign to group
    if !haskey(skel.groups_edges, group)
        skel.groups_edges[group] = Int[]
    end
    push!(skel.groups_edges[group], edge_idx)
end

function to_ASAP!(skel::StructureSkeleton)
    # asap runs in 
    

end