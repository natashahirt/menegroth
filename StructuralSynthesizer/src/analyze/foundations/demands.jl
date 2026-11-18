"""
    _unfactored_DL_loads(struc) → Vector{<:Asap.AbstractLoad}

Unfactored D+L for a service solve. Does not mutate `model.loads`.

Dead is the cell tributary dead load, frame `GravityLoad`s, fire-protection
coating ([`unfactored_fire_coating_loads`](@ref)), drop-panel weight at the
column tops ([`unfactored_drop_panel_loads`](@ref)), and the unfactored
self-weight of wall shells (`wall_self_weight_loads`, pressure ρ t g). The
factored `:wall_self_weight` area load stored on the model is not copied.
ASCE 7-16 §2.4.1 combo 2 is D+L (corpus: asce-7-16, pages 63–64). Strength
combos in §2.3.1 (1.4D, 1.2D+1.6L; page 62) must not be back-solved as Ps=Pu/1.4.
"""
function _unfactored_DL_loads(struc::BuildingStructure)
    loads = Asap.AbstractLoad[]
    model = struc.asap_model
    if !(isnothing(model) || isempty(model.frame_elements))
        els = model.frame_elements
        edge_strips = slab_edge_strips_by_cell(struc)
        for (cell_idx, cell) in enumerate(struc.cells)
            cell.floor_type == :grade && continue
            _create_cell_tributary_loads!(
                loads, els, struc.skeleton, struc, cell, cell_idx;
                split_dead_live=true, combo=StructuralSizer.service, edge_strips=edge_strips)
        end
        # Unfactored member self-weight (ρ A g) is not in the cell tributary
        # dicts. Include it so service D+L matches ASCE 7-16 §2.4.1 combo 2
        # (dead includes self-weight). GravityLoad.q reads the current section;
        # the model's copy carries the dead factor, so this one is at g.
        for ld in model.loads
            ld isa Asap.GravityLoad && push!(loads, unfactored_gravity_load(ld))
        end
        append!(loads, unfactored_fire_coating_loads(model))
        append!(loads, unfactored_drop_panel_loads(struc))
        # Curtain wall is dead load. The model copies are factored, so the service
        # case rebuilds them at wall_SDL.
        append!(loads, unfactored_cladding_loads(struc, els))
    end
    _append_service_wall_weight!(loads, model)
    return loads
end

"""Unfactored wall self-weight. A stored factored area load is left where it is."""
function _append_service_wall_weight!(loads, model)
    (isnothing(model) || !hasproperty(model, :shell_elements)) && return loads
    walls = Asap.ShellTri3[]
    for sh in model.shell_elements
        sh isa Asap.ShellTri3 && sh.id === :wall && push!(walls, sh)
    end
    append!(loads, wall_self_weight_loads(walls))
    return loads
end

"""
    _service_reactions(struc) → Vector{Float64}

Global reaction vector (N, N·m) for unfactored D+L, reusing the cached
stiffness factorization via `Asap.solve`. Does not write `model.u`.
"""
function _service_reactions(struc::BuildingStructure)
    model = struc.asap_model
    R = zeros(Float64, model.nDOFs)
    loads = _unfactored_DL_loads(struc)
    isempty(loads) && return R
    u_s = Asap.solve(model, Vector{Asap.AbstractLoad}[loads], struc.asap_rigid_links)[1]
    # F = P - Pf, so this is Asap's reaction K u - P + Pf. Nodal and area loads
    # lumped onto fixed nodes (wall self-weight at the base row) enter through P.
    F_s = Asap.create_F(model, loads)
    R[model.fixedDOFs] = model.S[model.fixedDOFs, :] * u_s - F_s[model.fixedDOFs]
    return R
end

"""
    _foundation_demand_from_signed(i, Fz, Fz_s, Fx, Fy, Mx, My; c1, c2, shape)

Map signed ASAP reactions onto a `FoundationDemand`.

ASAP reaction is force FROM support TO structure: gravity Fz>0 is compression,
Fz<0 is uplift. Keep signed `Pu`/`Ps` (negative = tension) so grouped
footings retain the tension-compression couple. Isolated all-uplift still
skips a compression footing (ACI 318-11 §15.8.1.2, corpus: aci-318-11,
page 275). `Ps` is unfactored D+L (ASCE 7-16 §2.4.1 combo 2), not `Pu/1.4`.
"""
function _foundation_demand_from_signed(i::Int, Fz, Fz_s, Fx, Fy, Mx, My;
                                       c1, c2, shape)
    uplift = Fz < zero(Fz)
    return StructuralSizer.FoundationDemand(i;
        Pu=Fz, Mux=Mx, Muy=My, Vux=Fx, Vuy=Fy, Ps=Fz_s,
        c1=c1, c2=c2, shape=shape, uplift=uplift)
end

"""
One strength combination's `(Pu, Mux, Muy)` and the heaviest allowable
vertical force as `Ps`, for a strip or mat that still takes one demand.

The pair `(Pu, Mux, Muy)` is one strength combination: the compressive
one with the largest moment. `Ps` is the largest compressive allowable-stress
vertical force. Spread footings do not use this. They check every combination.

No stored lateral cases returns `demand` unchanged.
"""
function _lateral_column_demand(struc::BuildingStructure, demand)
    actions = foundation_actions_at(struc, demand.group_idx)
    actions === nothing && return demand
    strength = [a for a in actions.strength if a.P > 0]
    isempty(strength) && return demand
    gov = strength[argmax(hypot(a.Mx, a.My) for a in strength)]
    service = [a for a in actions.service if a.P > 0]
    Ps = isempty(service) ? demand.Ps :
         uconvert(unit(demand.Ps), maximum(a.P for a in service) * u"N")
    return StructuralSizer.FoundationDemand(demand.group_idx;
        Pu=uconvert(unit(demand.Pu), gov.P * u"N"),
        Mux=uconvert(unit(demand.Mux), gov.Mx * u"N*m"),
        Muy=uconvert(unit(demand.Muy), gov.My * u"N*m"),
        Vux=demand.Vux, Vuy=demand.Vuy, Ps=Ps,
        c1=demand.c1, c2=demand.c2, shape=demand.shape, uplift=false)
end

"""True when every support in `idxs` has factored uplift."""
_all_uplift(demands, idxs) = all(demands[i].uplift for i in idxs)

"""True when `idxs` contains both compressive and tensile factored `Pu`."""
function _mixed_sign_Pu(demands, idxs)
    isempty(idxs) && return false
    z = zero(demands[first(idxs)].Pu)
    has_pos = false
    has_neg = false
    for i in idxs
        P = demands[i].Pu
        P > z && (has_pos = true)
        P < z && (has_neg = true)
        has_pos && has_neg && return true
    end
    return false
end

"""
    support_demands(struc::BuildingStructure; load_factor=1.0)

Convert support reactions to FoundationDemand objects.

Factored `Pu` is the signed vertical reaction (compression positive). Service
`Ps` is read from an extra unfactored D+L solve that reuses the stiffness
factorization. `load_factor` scales both (use 1.0 when reactions are already
factored).
"""
function support_demands(struc::BuildingStructure; load_factor::Real=1.0)
    isempty(struc.supports) && throw(ArgumentError("No supports. Call initialize_supports!() first."))

    model = struc.asap_model
    R_s = _service_reactions(struc)
    demands = StructuralSizer.FoundationDemand[]

    for (i, supp) in enumerate(struc.supports)
        Fx = supp.forces[1] * load_factor
        Fy = supp.forces[2] * load_factor
        Fz = supp.forces[3] * load_factor
        Mx = supp.moments[1] * load_factor
        My = supp.moments[2] * load_factor

        node = model.nodes[supp.node_idx]
        gid = node.globalID
        Fz_s = uconvert(unit(Fz), (R_s[gid[3]] * u"N") * load_factor)

        push!(demands, _foundation_demand_from_signed(i, Fz, Fz_s, Fx, Fy, Mx, My;
            c1=supp.c1, c2=supp.c2, shape=supp.shape))
    end

    return demands
end

