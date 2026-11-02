
# =============================================================================
# Fire Protection Coating → Line Loads
# =============================================================================

"""
    add_coating_loads!(struc, params; member_edge_group=:beams, resolve=true)

Add fire protection coating self-weight as `Asap.LineLoad`s on steel members.

Call **after** `size_steel_members!` so that sections are assigned. The coating
weight `w = thickness × perimeter × density` acts as additional dead load in
the global -Z direction.

For beams (3-sided exposure), uses `section.PA`; for columns (4-sided), `section.PB`.

# Arguments
- `struc`: BuildingStructure with a solved ASAP model and sized steel members
- `params`: DesignParameters with `fire_rating` and `fire_protection`
- `member_edge_group`: Which edge group — `:beams` or `:columns` (default `:beams`)
- `resolve`: Re-solve the model after adding loads (default `true`)

# Returns
Number of coating loads added.
"""
function add_coating_loads!(struc::BuildingStructure, params::DesignParameters;
                            member_edge_group::Symbol=:beams, resolve::Bool=true)
    fire_rating = params.fire_rating
    fire_rating <= 0 && return 0

    fp = params.fire_protection
    fp isa StructuralSizer.NoFireProtection && return 0

    skel = struc.skeleton
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[]))
    member_array = member_edge_group == :columns ? struc.columns :
                   member_edge_group == :struts ? struc.struts : struc.beams

    model = struc.asap_model
    n_added = 0

    for m in member_array
        sec = m.base.section
        isnothing(sec) && continue
        !(sec isa StructuralSizer.ISymmSection) && continue

        # Beams: 3-sided (PA), columns/struts: 4-sided (PB)
        perimeter = (member_edge_group === :beams || member_edge_group in BEAM_GROUP_SYMBOLS) ? sec.PA : sec.PB
        perimeter_in = ustrip(u"inch", perimeter)

        mat = sec.material
        isnothing(mat) && continue
        W_plf = ustrip(u"lb/ft", StructuralSizer.weight_per_length(sec, mat))

        # Compute coating
        coating = StructuralSizer.compute_surface_coating(fp, fire_rating, W_plf, perimeter_in)
        coating.thickness_in <= 0 && continue

        # Weight per unit length: thickness(in) × perimeter(in) / 144 → ft² per ft × density (pcf) → lb/ft
        w_lbft = StructuralSizer.coating_weight_per_foot(coating, perimeter_in)
        w_Nm = to_newtons_per_meter(w_lbft * u"lbf/ft")

        # Apply as downward (-Z) line load on each segment of this member
        for seg_idx in segment_indices(m)
            edge_idx = struc.segments[seg_idx].edge_idx
            edge_idx in edge_ids_in_group || continue
            el = model.frame_elements[edge_idx]
            push!(model.loads, Asap.LineLoad(el, [0.0u"N/m", 0.0u"N/m", -w_Nm * u"N/m"]))
            n_added += 1
        end
    end

    if n_added > 0 && resolve
        Asap.process!(model)
        Asap.solve!(model)
    end

    n_added > 0 && @info "Added fire protection coating loads" n_loads=n_added group=member_edge_group fire_rating=fire_rating
    return n_added
end