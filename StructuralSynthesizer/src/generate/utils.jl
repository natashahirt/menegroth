function add_vertex!(skel::StructureSkeleton{T}, pt::Meshes.Point; group::Symbol=:unknown, level_idx::Int=-1) where T
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

    # if level_idx is not provided, try to find it from skel.floors using Z-coordinate
    z_raw = ustrip(Meshes.coords(pt).z)
    z_round = round(z_raw, digits=2)

    if level_idx == -1 && !isempty(skel.floors)
        for (i, f_elev) in enumerate(skel.floors)
            if round(ustrip(f_elev), digits=2) == z_round
                level_idx = i - 1 # 0-indexed levels
                break
            end
        end
    end

    # assign to level
    if level_idx != -1
        if !haskey(skel.levels, level_idx)
            # Use the exact rounded coordinate for the level definition
            z_val = Meshes.coords(pt).z
            elev = T <: Unitful.Quantity ? T(z_round * unit(z_val)) : T(z_round)
            skel.levels[level_idx] = Level{T}(elev, Int[], Int[], Int[])
            println("DEBUG: Created Level $level_idx at elevation $elev")
        end
        
        if !(idx in skel.levels[level_idx].vertices)
            push!(skel.levels[level_idx].vertices, idx)
            println("DEBUG: Added Vertex $idx to Level $level_idx (z=$z_round)")
        end
    end

    return idx
end

function add_element!(skel::StructureSkeleton{T}, seg::Meshes.Segment; group::Symbol=:unknown, level_idx::Int=-1) where T
    # get/create vertex indices
    v_indices = Vector{Int}(undef, 2)
    
    v_indices[1] = add_vertex!(skel, Meshes.vertices(seg)[1])
    v_indices[2] = add_vertex!(skel, Meshes.vertices(seg)[2])

    # add as an edge
    push!(skel.edges, seg)
    push!(skel.edge_indices, (v_indices[1], v_indices[2]))

    idx = length(skel.edges)
    Graphs.add_edge!(skel.graph, v_indices[1], v_indices[2])

    # assign to group
    if !haskey(skel.groups_edges, group)
        skel.groups_edges[group] = Int[]
    end
    
    if !(idx in skel.groups_edges[group])
        push!(skel.groups_edges[group], idx)
    end

    # assign to level
    if level_idx != -1
        if !(idx in skel.levels[level_idx].edges)
            push!(skel.levels[level_idx].edges, idx)
        end
    end

    return idx
end

function add_face!(skel::StructureSkeleton{T}, face::Meshes.Polygon; group::Symbol=:unknown, level_idx::Int=-1, v_indices::Vector{Int}=Int[]) where T
    # get vertex indices if not provided
    if isempty(v_indices)
        v_indices = [add_vertex!(skel, v) for v in Meshes.vertices(face)]
    end

    idx = findfirst(f -> f == face, skel.faces) 
    if isnothing(idx)
        push!(skel.faces, face)
        push!(skel.face_indices, v_indices)
        idx = length(skel.faces)
    end

    # assign to group
    if !haskey(skel.groups_faces, group)
        skel.groups_faces[group] = Int[]
    end
    
    if !(idx in skel.groups_faces[group])
        push!(skel.groups_faces[group], idx)
    end

    # assign to level
    if level_idx != -1
        if !haskey(skel.levels, level_idx)
            # Level creation logic if it doesn't exist
            z_val = Meshes.coords(skel.vertices[v_indices[1]]).z
            r_z = round(ustrip(z_val), digits=2)
            elev = T <: Unitful.Quantity ? T(r_z * unit(z_val)) : T(r_z)
            skel.levels[level_idx] = Level{T}(elev, Int[], Int[], Int[])
        end
        
        if !(idx in skel.levels[level_idx].faces)
            push!(skel.levels[level_idx].faces, idx)
        end
    end

    return idx
end

function find_faces!(skel::StructureSkeleton{T}) where T
    println("DEBUG: Starting find_faces! for $(length(skel.levels)) levels")
    for (level_idx, level) in skel.levels
        v_indices = level.vertices
        println("DEBUG: Processing Level $level_idx (elev=$(level.elevation)) with $(length(v_indices)) vertices")
        length(v_indices) < 3 && continue 

        # build local adjacency with CCW-sorted neighbors (rotation system)
        adj = Dict{Int, Vector{Int}}()
        for v in v_indices
            neighbors = [n for n in Graphs.neighbors(skel.graph, v) if n in v_indices] # get neighbors using graph
            p_v = Meshes.coords(skel.vertices[v])
            sort!(neighbors, by=n -> begin # sort by angle
                p_n = Meshes.coords(skel.vertices[n])
                atan(ustrip(p_n.y) - ustrip(p_v.y), ustrip(p_n.x) - ustrip(p_v.x))
            end)
            adj[v] = neighbors
        end

        # traverse faces using directed half-edges
        visited_half_edges = Set{Tuple{Int, Int}}()
        faces_found = 0
        
        for u in v_indices
            for v in adj[u]
                if !((u, v) in visited_half_edges)
                    cycle = Int[]
                    curr_u, curr_v = u, v
                    
                    while !((curr_u, curr_v) in visited_half_edges)
                        push!(visited_half_edges, (curr_u, curr_v))
                        push!(cycle, curr_u)
                        
                        v_neighbors = adj[curr_v]
                        idx_in = findfirst(x -> x == curr_u, v_neighbors)
                        idx_next = mod1(idx_in - 1, length(v_neighbors))
                        
                        next_v = v_neighbors[idx_next]
                        curr_u, curr_v = curr_v, next_v
                    end
                    
                    # add valid internal slabs (CCW order)
                    if length(cycle) >= 3
                        area = calculate_signed_area(skel, cycle)
                        if area > 0
                            println("DEBUG: Found slab at Level $level_idx with area $(round(area, digits=2))")
                            polygon = Meshes.Ngon(skel.vertices[cycle]...)
                            add_face!(skel, polygon, group=:slabs, level_idx=level_idx, v_indices=cycle)
                            faces_found += 1
                        else
                            println("DEBUG: Ignoring boundary cycle at Level $level_idx (area=$(round(area, digits=2)))")
                        end
                    end
                end
            end
        end
        println("DEBUG: Level $level_idx: Found $faces_found faces")
    end
end

function calculate_signed_area(skel, indices)
    area = 0.0
    n = length(indices)
    for i in 1:n
        p1 = Meshes.coords(skel.vertices[indices[i]])
        p2 = Meshes.coords(skel.vertices[indices[mod1(i + 1, n)]])
        area += (ustrip(p1.x) * ustrip(p2.y) - ustrip(p2.x) * ustrip(p1.y))
    end
    return area / 2.0
end

function rebuild_levels!(skel::StructureSkeleton{T}) where T
    # get unique z coordinates and assign to corresponding levels
    rounded_z = map(skel.vertices) do v
        z_val = Meshes.coords(v).z
        r_z = round(ustrip(z_val), digits=2)
        return T <: Unitful.Quantity ? T(r_z * unit(z_val)) : T(r_z)
    end
    unique_z = sort(unique(rounded_z))
    z_to_idx = Dict(z => i-1 for (i,z) in enumerate(unique_z))

    # update levels dict
    empty!(skel.levels)

    for (v_idx, v) in enumerate(skel.vertices)
        z = rounded_z[v_idx]
        level_idx = z_to_idx[z]
        if !haskey(skel.levels, level_idx)
            skel.levels[level_idx] = Level{T}(z, Int[], Int[], Int[])
        end
        if !(v_idx in skel.levels[level_idx].vertices)
            push!(skel.levels[level_idx].vertices, v_idx)
        end
    end

    for (e_idx, (v1_idx, v2_idx)) in enumerate(skel.edge_indices)
        z1, z2 = rounded_z[v1_idx], rounded_z[v2_idx]
        if z1 == z2
            level_idx = z_to_idx[z1]
            if !haskey(skel.levels, level_idx)
                skel.levels[level_idx] = Level{T}(z1, Int[], Int[], Int[])
            end
            if !(e_idx in skel.levels[level_idx].edges)
                push!(skel.levels[level_idx].edges, e_idx)
            end
        end
    end

    for (f_idx, v_indices) in enumerate(skel.face_indices)
        z_vals = [rounded_z[i] for i in v_indices]
        if all(z -> z == z_vals[1], z_vals)
            level_idx = z_to_idx[z_vals[1]]
            if !haskey(skel.levels, level_idx)
                skel.levels[level_idx] = Level{T}(z_vals[1], Int[], Int[], Int[])
            end
            if !(f_idx in skel.levels[level_idx].faces)
                push!(skel.levels[level_idx].faces, f_idx)
            end
        end
    end
end

# just does geometry, no loads yet
function to_asap(skel::StructureSkeleton{T};
                 default_section::Asap.Section,
                 default_dof::Vector{Bool} = [true, true, true, false, false, false]
            ) where T
        
        nodes = map(enumerate(skel.vertices)) do (idx, pt)
            coords = Meshes.coords(pt)
            pos = [
                round(ustrip(u"m", coords.x), digits=2), 
                round(ustrip(u"m", coords.y), digits=2), 
                round(ustrip(u"m", coords.z), digits=2)
            ] 
            is_support = idx in get(skel.groups_vertices, :support, Int[])
            dof = is_support ? [false, false, false, false, false, false] : default_dof
            return Asap.Node(pos, dof)
        end

        # Build elements from edge_indices to avoid duplicates from groups
        elements = [Asap.Element(nodes[v1], nodes[v2], default_section) for (v1, v2) in skel.edge_indices]
        println("DEBUG: Converted to Asap model with $(length(nodes)) nodes and $(length(elements)) elements")

        return Asap.Model(nodes, elements, Asap.NodeForce[])
end