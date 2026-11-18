# Foundation initialization and sizing utilities

"""
    initialize_supports!(struc::BuildingStructure)

Create Support objects for each support vertex in the skeleton.
Must be called after `to_asap!(struc)` and `solve!(struc.asap_model)`.

Extracts reaction forces from the ASAP model nodes.
"""
function initialize_supports!(struc::BuildingStructure{T}) where T
    skel = struc.skeleton
    model = struc.asap_model
    
    isempty(model.nodes) && throw(ArgumentError("ASAP model has no nodes. Call to_asap!() first."))
    model.processed || throw(ArgumentError("ASAP model not solved. Call solve!(struc.asap_model) first."))
    
    support_vertex_indices = get(skel.groups_vertices, :support, Int[])
    isempty(support_vertex_indices) && (@warn "No support vertices found in skeleton"; return struc)
    
    empty!(struc.supports)
    
    # Build vertex → Column lookup for column dimension extraction
    col_by_vertex = Dict{Int, Column}()
    for col in struc.columns
        col.vertex_idx > 0 && (col_by_vertex[col.vertex_idx] = col)
    end
    
    for v_idx in support_vertex_indices
        node = model.nodes[v_idx]  # Vertex index maps to node index (from to_asap!)
        
        # Extract reactions with units
        rxn = node.reaction
        forces = (
            uconvert(u"kN", rxn[1]),
            uconvert(u"kN", rxn[2]),
            uconvert(u"kN", rxn[3])
        )
        moments = (
            uconvert(u"kN*m", rxn[4]),
            uconvert(u"kN*m", rxn[5]),
            uconvert(u"kN*m", rxn[6])
        )
        
        # Column dimensions: pull from Column member at this vertex (if sized)
        col_c1 = 18.0u"inch"   # sensible default
        col_c2 = 18.0u"inch"
        col_shape = :rectangular
        if haskey(col_by_vertex, v_idx)
            col = col_by_vertex[v_idx]
            col_shape = col.shape               # :rectangular or :circular
            if col.c1 !== nothing
                col_c1 = uconvert(u"inch", col.c1)
                col_c2 = col.c2 !== nothing ? uconvert(u"inch", col.c2) : col_c1
            elseif section(col) !== nothing
                sec = section(col)
                col_c1 = uconvert(u"inch", StructuralSizer.section_width(sec))
                col_c2 = uconvert(u"inch", StructuralSizer.section_depth(sec))
            end
        end
        
        support = Support(v_idx, v_idx; forces=forces, moments=moments,
                          foundation_type=:spread,
                          c1=col_c1, c2=col_c2, shape=col_shape)
        push!(struc.supports, support)
    end
    
    @debug "Initialized $(length(struc.supports)) supports from skeleton"
    return struc
end

