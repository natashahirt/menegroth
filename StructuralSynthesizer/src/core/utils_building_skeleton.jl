"""
    add_vertex!(skel, pt; group=:unknown, level_idx=-1)

Add a vertex to the skeleton, returning its index. If vertex already exists, returns existing index.
Automatically uses O(1) lookup if `skel.lookup` is enabled.
"""
function add_vertex!(skel::BuildingSkeleton{T}, pt::Meshes.Point; 
                     group::Symbol=:unknown, level_idx::Int=-1) where T
    # O(1) lookup if available, else O(n) fallback
    idx = find_vertex(skel, pt)
    
    if isnothing(idx)
        push!(skel.vertices, pt)
        Graphs.add_vertex!(skel.graph)
        idx = length(skel.vertices)
        
        # Update lookup if enabled
        _register_vertex!(skel, idx, pt)
    end

    # assign to group
    if !haskey(skel.groups_vertices, group)
        skel.groups_vertices[group] = Int[]
    end
    
    if !(idx in skel.groups_vertices[group])
        push!(skel.groups_vertices[group], idx)
    end

    # if level_idx is not provided, try to find it from skel.stories_z using Z-coordinate
    z_raw = ustrip(Meshes.coords(pt).z)
    z_round = round(z_raw, digits=2)

    if level_idx == -1 && !isempty(skel.stories_z)
        for (i, f_elev) in enumerate(skel.stories_z)
            if round(ustrip(f_elev), digits=2) == z_round
                level_idx = i - 1 # 0-indexed levels
                break
            end
        end
    end

    # assign to story
    if level_idx != -1
        if !haskey(skel.stories, level_idx)
            z_val = Meshes.coords(pt).z
            elev = T <: Unitful.Quantity ? z_round * unit(z_val) : T(z_round)
            skel.stories[level_idx] = Story{T}(elev, Int[], Int[], Int[])
        end
        
        if !(idx in skel.stories[level_idx].vertices)
            push!(skel.stories[level_idx].vertices, idx)
        end
    end

    return idx
end

# Convenience method for vector coordinates
function add_vertex!(skel::BuildingSkeleton{T}, coords::AbstractVector{<:Real}; kwargs...) where T
    pt = Meshes.Point(Tuple(coords))
    return add_vertex!(skel, pt; kwargs...)
end

"""
    add_element!(skel, seg; group=:unknown, level_idx=-1)

Add an edge element to the skeleton. Also adds vertices if they don't exist.
Automatically uses O(1) lookup if `skel.lookup` is enabled.
"""
function add_element!(skel::BuildingSkeleton{T}, seg::Meshes.Segment; 
                      group::Symbol=:unknown, level_idx::Int=-1) where T
    # get/create vertex indices
    v_indices = Vector{Int}(undef, 2)
    
    v_indices[1] = add_vertex!(skel, Meshes.vertices(seg)[1])
    v_indices[2] = add_vertex!(skel, Meshes.vertices(seg)[2])

    # add as an edge
    push!(skel.edges, seg)
    push!(skel.edge_indices, (v_indices[1], v_indices[2]))

    idx = length(skel.edges)
    Graphs.add_edge!(skel.graph, v_indices[1], v_indices[2])
    
    # Update lookup if enabled
    _register_edge!(skel, idx, v_indices[1], v_indices[2])

    # assign to group
    if !haskey(skel.groups_edges, group)
        skel.groups_edges[group] = Int[]
    end
    
    if !(idx in skel.groups_edges[group])
        push!(skel.groups_edges[group], idx)
    end

    # assign to story
    if level_idx != -1
        if !(idx in skel.stories[level_idx].edges)
            push!(skel.stories[level_idx].edges, idx)
        end
    end

    return idx
end

# Convenience method for element by vertex indices
function add_element!(skel::BuildingSkeleton{T}, v1_idx::Int, v2_idx::Int; kwargs...) where T
    p1 = skel.vertices[v1_idx]
    p2 = skel.vertices[v2_idx]
    seg = Meshes.Segment(p1, p2)
    return add_element!(skel, seg; kwargs...)
end

"""
    add_face!(skel, face; group=:unknown, level_idx=-1, v_indices=Int[])

Add a face (polygon) to the skeleton. Also adds vertices if they don't exist.
Automatically uses O(1) lookup if `skel.lookup` is enabled.
"""
function add_face!(skel::BuildingSkeleton{T}, face::Meshes.Polygon; 
                   group::Symbol=:unknown, level_idx::Int=-1, 
                   v_indices::Vector{Int}=Int[]) where T
    # get vertex indices if not provided
    if isempty(v_indices)
        v_indices = [add_vertex!(skel, v) for v in Meshes.vertices(face)]
    end

    # Check if face already exists (O(1) if lookup enabled)
    idx = find_face(skel, v_indices)
    if isnothing(idx)
        # Also check by geometry comparison as fallback
        idx = findfirst(f -> f == face, skel.faces)
    end
    
    if isnothing(idx)
        push!(skel.faces, face)
        push!(skel.face_vertex_indices, v_indices)
        
        # compute edge indices for this face (O(1) per edge if lookup enabled)
        n_verts = length(v_indices)
        e_indices = Int[]
        for i in 1:n_verts
            v1, v2 = v_indices[i], v_indices[mod1(i + 1, n_verts)]
            edge_idx = find_edge(skel, v1, v2)
            !isnothing(edge_idx) && push!(e_indices, edge_idx)
        end
        push!(skel.face_edge_indices, e_indices)
        
        idx = length(skel.faces)
        
        # Update lookup if enabled
        _register_face!(skel, idx, v_indices)
    end

    # assign to group
    if !haskey(skel.groups_faces, group)
        skel.groups_faces[group] = Int[]
    end
    
    if !(idx in skel.groups_faces[group])
        push!(skel.groups_faces[group], idx)
    end

    # assign to story
    if level_idx != -1
        if !haskey(skel.stories, level_idx)
            z_val = Meshes.coords(skel.vertices[v_indices[1]]).z
            r_z = round(ustrip(z_val), digits=2)
            elev = T <: Unitful.Quantity ? r_z * unit(z_val) : T(r_z)
            skel.stories[level_idx] = Story{T}(elev, Int[], Int[], Int[])
        end
        
        if !(idx in skel.stories[level_idx].faces)
            push!(skel.stories[level_idx].faces, idx)
        end
    end

    return idx
end

function find_faces!(skel::BuildingSkeleton{T}) where T
    for (level_idx, story) in skel.stories
        v_indices = story.vertices
        length(v_indices) < 3 && continue 

        # build local adjacency with CCW-sorted neighbors (rotation system)
        adj = Dict{Int, Vector{Int}}()
        for v in v_indices
            neighbors = [n for n in Graphs.neighbors(skel.graph, v) if n in v_indices]
            p_v = Meshes.coords(skel.vertices[v])
            sort!(neighbors, by=n -> begin
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
                            polygon = Meshes.Ngon(skel.vertices[cycle]...)
                            add_face!(skel, polygon, group=:slabs, level_idx=level_idx, v_indices=cycle)
                            faces_found += 1
                        end
                    end
                end
            end
        end
        @debug "Face detection complete" story=level_idx faces=faces_found
    end
end

# utility for finding faces (clockwise vs anticlockwise)
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

function rebuild_stories!(skel::BuildingSkeleton{T}) where T
    # get unique z coordinates and assign to corresponding stories
    rounded_z = map(skel.vertices) do v
        z_val = Meshes.coords(v).z
        r_z = round(ustrip(z_val), digits=2)
        return T <: Unitful.Quantity ? r_z * unit(z_val) : T(r_z)
    end
    unique_z = sort(unique(rounded_z))
    z_to_idx = Dict(z => i-1 for (i,z) in enumerate(unique_z))
    skel.stories_z = unique_z

    # update stories dict
    empty!(skel.stories)

    for (v_idx, v) in enumerate(skel.vertices)
        z = rounded_z[v_idx]
        level_idx = z_to_idx[z]
        if !haskey(skel.stories, level_idx)
            skel.stories[level_idx] = Story{T}(z, Int[], Int[], Int[])
        end
        if !(v_idx in skel.stories[level_idx].vertices)
            push!(skel.stories[level_idx].vertices, v_idx)
        end
    end

    for (e_idx, (v1_idx, v2_idx)) in enumerate(skel.edge_indices)
        z1, z2 = rounded_z[v1_idx], rounded_z[v2_idx]
        if z1 == z2
            level_idx = z_to_idx[z1]
            if !haskey(skel.stories, level_idx)
                skel.stories[level_idx] = Story{T}(z1, Int[], Int[], Int[])
            end
            if !(e_idx in skel.stories[level_idx].edges)
                push!(skel.stories[level_idx].edges, e_idx)
            end
        end
    end

    for (f_idx, v_indices) in enumerate(skel.face_vertex_indices)
        z_vals = [rounded_z[i] for i in v_indices]
        if all(z -> z == z_vals[1], z_vals)
            level_idx = z_to_idx[z_vals[1]]
            if !haskey(skel.stories, level_idx)
                skel.stories[level_idx] = Story{T}(z_vals[1], Int[], Int[], Int[])
            end
            if !(f_idx in skel.stories[level_idx].faces)
                push!(skel.stories[level_idx].faces, f_idx)
            end
        end
    end
end

# =============================================================================
# Geometry Query Helpers
# =============================================================================
# These wrap Meshes operations to avoid exposing Meshes types to downstream packages.

"""
    edge_length(skel, edge_idx)

Return the length of the edge at `edge_idx` in the skeleton.
Wraps `Meshes.measure` so downstream packages don't need Meshes as a dependency.
"""
edge_length(skel::BuildingSkeleton, edge_idx::Int) = Meshes.measure(skel.edges[edge_idx])

"""
    face_area(skel, face_idx)

Return the area of the face at `face_idx` in the skeleton.
"""
face_area(skel::BuildingSkeleton, face_idx::Int) = Meshes.measure(skel.faces[face_idx])

"""
    vertex_coords(skel, vertex_idx)

Return the coordinates of the vertex at `vertex_idx` as a NamedTuple (x, y, z).
"""
function vertex_coords(skel::BuildingSkeleton, vertex_idx::Int)
    c = Meshes.coords(skel.vertices[vertex_idx])
    return (x=c.x, y=c.y, z=c.z)
end

"""
    edge_vertices(skel, edge_idx)

Return the vertex indices (v1, v2) for the edge at `edge_idx`.
"""
edge_vertices(skel::BuildingSkeleton, edge_idx::Int) = skel.edge_indices[edge_idx]

"""
    face_vertices(skel, face_idx)

Return the vertex indices for the face at `face_idx`.
"""
face_vertices(skel::BuildingSkeleton, face_idx::Int) = skel.face_vertex_indices[face_idx]

"""
    is_convex_face(skel, face_idx) -> Bool

Check if a face in the skeleton is convex.

Convenience wrapper around `Asap.is_convex_polygon` for BuildingSkeleton faces.

# Example
```julia
if is_convex_face(skel, face_idx)
    # Use DDM/EFM directly
else
    # Need to split into rectangular regions
end
```
"""
function is_convex_face(skel::BuildingSkeleton, face_idx::Int)
    v_indices = skel.face_vertex_indices[face_idx]
    
    # Extract 2D vertices (x, y) from skeleton
    vertices_2d = map(v_indices) do vi
        c = Meshes.coords(skel.vertices[vi])
        (Float64(ustrip(c.x)), Float64(ustrip(c.y)))
    end
    
    return Asap.is_convex_polygon(vertices_2d)
end