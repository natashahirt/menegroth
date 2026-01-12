"""
    to_asap!(struc)
Converts a BuildingStructure into an Asap.Model.
Hard SI Metric Boundary: All values sent to Asap are stripped of units and forced to base SI.
"""
function to_asap!(struc::BuildingStructure{T}) where T
    skel = struc.skeleton
    
    # 1. nodes
    support_indices = get(skel.groups_vertices, :support, Int[])
    
    nodes = map(enumerate(skel.vertices)) do (v_idx, v)
        coords = Meshes.coords(v)
        x = ustrip(uconvert(u"m", coords.x))
        y = ustrip(uconvert(u"m", coords.y))
        z = ustrip(uconvert(u"m", coords.z))
        
        # ground level fixed, all else moment connected
        is_support = v_idx in support_indices
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
        
        # edges of this slab's face
        face_edge_indices = skel.face_edge_indices[slab.face_idx]
        
        # total perimeter for tributary distribution
        total_perimeter = sum(face_edge_indices) do edge_idx
            v1, v2 = skel.edge_indices[edge_idx]
            p1, p2 = skel.vertices[v1], skel.vertices[v2]
            ustrip(uconvert(u"m", Meshes.measure(Meshes.Segment(p1, p2))))
        end
        
        # area in m²
        area_m2 = ustrip(uconvert(u"m^2", sec.area))
        
        # trib width = area / perimeter
        tributary_width = area_m2 / total_perimeter
        
        # line load (N/m) = pressure (N/m²) × tributary_width (m)
        line_load = pressure * tributary_width
        
        for edge_idx in face_edge_indices
            push!(loads, Asap.LineLoad(elements[edge_idx], [0.0, 0.0, -line_load]))
        end
    end

    model = Asap.Model(nodes, elements, loads)
    @debug "Converted to Asap.Model" nodes=length(nodes) elements=length(elements)

    Asap.process!(model)
    Asap.solve!(model)

    struc.asap_model = model
end