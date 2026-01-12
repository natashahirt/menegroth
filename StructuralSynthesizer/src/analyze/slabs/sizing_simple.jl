# simple sizing of the slabs based on maximum span

"""
    get_slab_hash(skel, face_idx, span_axis, total_dl, total_ll)
Generates a unique signature for a face based on its geometry and orientation relative to a span axis.
Reinforces metric units internally for universal hashing.
"""
function get_slab_hash(skel::BuildingSkeleton{T}, face_idx::Int, span_axis::Union{Meshes.Vec{3, T}, Nothing}, total_dl, total_ll) where T
    polygon = skel.faces[face_idx]
    pts = Meshes.vertices(polygon)

    # span dimensions (orientation aware, AABB relative to span_axis)
    # perpendicular axis is 90 degrees to span_axis in xy plane
    if !isnothing(span_axis)
        u_axis = [ustrip(span_axis[1]), ustrip(span_axis[2]), ustrip(span_axis[3])]
        perp_axis = [-u_axis[2], u_axis[1], 0.0]
        
        projections_along = [ustrip(uconvert(Constants.STANDARD_LENGTH, Meshes.coords(p).x)) * u_axis[1] + ustrip(uconvert(Constants.STANDARD_LENGTH, Meshes.coords(p).y)) * u_axis[2] for p in pts]
        projections_perp = [ustrip(uconvert(Constants.STANDARD_LENGTH, Meshes.coords(p).x)) * perp_axis[1] + ustrip(uconvert(Constants.STANDARD_LENGTH, Meshes.coords(p).y)) * perp_axis[2] for p in pts]
        
        span_l = round(maximum(projections_along) - minimum(projections_along), digits=3)
        span_w = round(maximum(projections_perp) - minimum(projections_perp), digits=3)
    else
        # For isotropic/no axis, use diameter in meters
        span_l = round(maximum([ustrip(uconvert(Constants.STANDARD_LENGTH, Meshes.dist(p1, p2))) for p1 in pts, p2 in pts]), digits=3)
        span_w = span_l
    end

    # 2. Geometric Invariants (Standardized to Metric)
    area = round(ustrip(uconvert(Constants.STANDARD_AREA, Meshes.measure(polygon))), digits=3)
    n_v = length(pts)
    
    # 3. Loads (Standardized to Metric)
    dl_metric = round(ustrip(uconvert(Constants.STANDARD_PRESSURE, total_dl)), digits=3)
    ll_metric = round(ustrip(uconvert(Constants.STANDARD_PRESSURE, total_ll)), digits=3)
    
    return hash((n_v, area, span_l, span_w, dl_metric, ll_metric))
end

"""
    initialize_slabs!(struc; material=:concrete)
Iterates through a BuildingStructure's skeleton to populate Slab and SlabSection objects.
Uses a "Smart Default" of L/28 for thickness and automatically detects span axes.
Reinforces metric units throughout.
"""
function initialize_slabs!(struc::BuildingStructure{T}; material=:concrete) where T
    skel = struc.skeleton
    empty!(struc.slabs)

    # should initialize the load map with geometry?
    # Priority order: grade > floor > roof (a face only gets one classification)
    load_map = [
        :grade => (Constants.LL_GRADE_f, Constants.SDL_FLOOR_f),
        :floor => (Constants.LL_FLOOR_f, Constants.SDL_FLOOR_f),
        :roof  => (Constants.LL_ROOF_f,  Constants.SDL_ROOF_f)
    ]
    
    processed_faces = Set{Int}()
    
    for (grp_name, loads) in load_map
        face_indices = get(skel.groups_faces, grp_name, Int[])
        ll_f, sdl_f = loads
        
        for face_idx in face_indices
            # Skip if already processed (prevents double-counting from overlapping groups)
            face_idx in processed_faces && continue
            push!(processed_faces, face_idx)
            
            polygon = skel.faces[face_idx]
            pts = Meshes.vertices(polygon)

            # rectangular plan spans (push to metric)
            xs = [ustrip(uconvert(Constants.STANDARD_LENGTH, Meshes.coords(p).x)) for p in pts]
            ys = [ustrip(uconvert(Constants.STANDARD_LENGTH, Meshes.coords(p).y)) for p in pts]
            lx, ly = maximum(xs)-minimum(xs), maximum(ys)-minimum(ys)
            l_short = min(lx, ly)
            
            # span axis logic
            span_axis = lx <= ly ? Meshes.Vec{3, T}(T(1.0), T(0.0), T(0.0)) : Meshes.Vec{3, T}(T(0.0), T(1.0), T(0.0))
            
            # sizing (L_short / 28) - thickness_val is in m
            thickness_val = max(0.125, l_short / 28.0)
            thickness = T <: Unitful.Quantity ? T(thickness_val * Constants.STANDARD_LENGTH) : T(thickness_val)

            # Calculate Self-Weight and ADD to SDL (push to metric)
            sw = thickness_val * Constants.STANDARD_LENGTH * Constants.ρ_CONCRETE * Constants.GRAVITY
            sw_f = uconvert(Constants.STANDARD_PRESSURE, sw * Constants.DL_FACTOR)
            total_dl_f = sdl_f + sw_f

            # Generate Structural Hash
            h = get_slab_hash(skel, face_idx, span_axis, total_dl_f, ll_f)

            # create or get the SlabSection
            if !haskey(struc.slab_sections, h)
                struc.slab_sections[h] = SlabSection{T}(
                    h,
                    thickness,
                    material,
                    Meshes.measure(polygon),
                    :one_way,
                    span_axis,
                    total_dl_f,
                    ll_f,
                )
            end

            push!(struc.slabs, Slab{T}(face_idx, struc.slab_sections[h], Int[]))
        end
    end
    println("DEBUG: Initialized $(length(struc.slabs)) slabs into $(length(struc.slab_sections)) unique sections.")
end

"""
    to_asap(struc)
Converts a BuildingStructure into an Asap.Model.
Hard SI Metric Boundary: All values sent to Asap are stripped of units and forced to base SI.
"""
function to_asap!(struc::BuildingStructure{T}) where T
    skel = struc.skeleton
    
    # 1. nodes
    nodes = map(skel.vertices) do v
        coords = Meshes.coords(v)
        x = ustrip(uconvert(u"m", coords.x))
        y = ustrip(uconvert(u"m", coords.y))
        z = ustrip(uconvert(u"m", coords.z))
        
        # is vertex a support?
        is_support = false
        for (grp, indices) in skel.groups_vertices
            if grp == :support && findfirst(==(findfirst(==(v), skel.vertices)), indices) !== nothing
                is_support = true
                break
            end
        end
        
        # ground level fixed, all else moment connected
        dofs = is_support ? [false, false, false, false, false, false] : [true, true, true, false, false, false]
        return Asap.Node([x, y, z], dofs)
    end

    # 2. elements
    default_section = AsapToolkit.toASAPframe("W10x22", unit=u"m")
    elements = map(skel.edge_indices) do (v1, v2)
        return Asap.Element(nodes[v1], nodes[v2], default_section, release=:fixedfixed) # placeholder section
    end
    
    # 3. loads - distribute slab loads to supporting edges
    loads = Asap.AbstractLoad[]
    for slab in struc.slabs
        sec = slab.section
        # Pressure (N/m²) applied to this slab
        pressure = ustrip(uconvert(u"N/m^2", sec.dead_load + sec.live_load))
        
        # edges of this slab's face (now stored directly as edge indices)
        face_edge_indices = skel.face_edge_indices[slab.face_idx]
        
        # total perimeter for tributary distribution
        total_perimeter = sum(face_edge_indices) do edge_idx
            v1, v2 = skel.edge_indices[edge_idx]
            p1, p2 = skel.vertices[v1], skel.vertices[v2]
            ustrip(uconvert(u"m", Meshes.measure(Meshes.Segment(p1, p2))))
        end
        
        # area in m²
        area_m2 = ustrip(uconvert(u"m^2", sec.area))
        
        # trib width = area / perimeter (assumes load fans out to edges)
        tributary_width = area_m2 / total_perimeter
        
        # line load (N/m) = pressure (N/m²) × tributary_width (m)
        line_load = pressure * tributary_width
        
        for edge_idx in face_edge_indices
            push!(loads, Asap.LineLoad(elements[edge_idx], [0.0, 0.0, -line_load]))
        end
    end

    model = Asap.Model(nodes, elements, loads)
    println("DEBUG: Converted to Asap.Model with $(length(nodes)) nodes and $(length(elements)) elements.")

    Asap.process!(model)
    Asap.solve!(model)

    struc.asap_model = model
end
