
# =============================================================================
# Fire Protection Coating → Line Loads
# =============================================================================

"""Load id of every fire-protection coating `Asap.LineLoad` on the building model."""
const FIRE_COATING_LOAD_ID = :fire_coating

"""
    add_coating_loads!(struc, params; member_edge_group=:beams, resolve=true)

Replace the fire-protection coating loads on one member edge group with
`Asap.LineLoad`s for the current steel sections. Returns the number added.

The coating weight `w = thickness × perimeter × density` is dead load. It is
factored like member self-weight, by [`member_self_weight_acceleration`](@ref)
`/ g` (the dead factor of `governing_combo(params)`; ACI 318-11 §9.2.1,
corpus: aci-318-11, page 123), and acts in global −Z. Loads carry the id
[`FIRE_COATING_LOAD_ID`](@ref), so pattern cases include them and unfactored
cases recover `w` with [`unfactored_fire_coating_loads`](@ref).

Beams (3-sided exposure) use `section.PA`; columns (4-sided) use `section.PB`.
Calling again after a section change replaces the group's loads.
"""
function add_coating_loads!(struc::BuildingStructure, params::DesignParameters;
                            member_edge_group::Symbol=:beams, resolve::Bool=true)
    model = struc.asap_model
    edge_ids = Set(get(struc.skeleton.groups_edges, member_edge_group, Int[]))
    group_elements = Set(objectid(model.frame_elements[i]) for i in edge_ids)
    on_group(ld) = ld isa Asap.LineLoad && ld.id === FIRE_COATING_LOAD_ID &&
                   objectid(ld.element) in group_elements
    n_removed = length(model.loads)
    filter!(!on_group, model.loads)
    n_removed -= length(model.loads)

    new_loads = _coating_line_loads(struc, params, member_edge_group, edge_ids)
    append!(model.loads, new_loads)

    if (n_removed > 0 || !isempty(new_loads)) && resolve
        Asap.process!(model)
        _solve_struc_model!(struc)
        _refresh_pattern_solve_cache!(struc)
    end
    return length(new_loads)
end

"""
    _sync_fire_coating_loads!(struc, params) -> Int

Replace every coating load on the model with loads for the current sections
and dead factor. Does not re-solve. Returns the number of coating loads.
"""
function _sync_fire_coating_loads!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    isnothing(model) && return 0
    filter!(ld -> !(ld isa Asap.LineLoad && ld.id === FIRE_COATING_LOAD_ID), model.loads)
    n = 0
    for g in (BEAM_GROUP_SYMBOLS..., :columns)
        edge_ids = Set(get(struc.skeleton.groups_edges, g, Int[]))
        isempty(edge_ids) && continue
        loads = _coating_line_loads(struc, params, g, edge_ids)
        append!(model.loads, loads)
        n += length(loads)
    end
    return n
end

"""
Steel a member was sized with: its section's material, else the steel key of
its material volumes. Catalog sections carry `material = nothing`, and the
section is left that way so it still matches its catalog entry.
"""
function _member_steel(m)
    mat = section(m).material
    mat isa StructuralSizer.StructuralSteel && return mat
    for k in keys(volumes(m))
        k isa StructuralSizer.StructuralSteel && return k
    end
    return nothing
end

"""Factored coating line loads for the members of one edge group."""
function _coating_line_loads(struc, params::DesignParameters, member_edge_group::Symbol,
                             edge_ids::AbstractSet{Int})
    loads = Asap.LineLoad[]
    has_fire_rating(params) || return loads
    fp = params.fire_protection
    fp isa StructuralSizer.NoFireProtection && return loads
    isempty(edge_ids) && return loads

    model = struc.asap_model
    members = member_edge_group === :columns ? struc.columns :
              member_edge_group === :struts ? struc.struts : struc.beams
    three_sided = member_edge_group === :beams || member_edge_group in BEAM_GROUP_SYMBOLS
    dead_factor = ustrip(u"m/s^2", member_self_weight_acceleration(params)) /
                  ustrip(u"m/s^2", GRAVITY)
    for m in members
        sec = m.base.section
        sec isa StructuralSizer.ISymmSection || continue
        mat = _member_steel(m)
        isnothing(mat) && continue
        perimeter_in = ustrip(u"inch", three_sided ? sec.PA : sec.PB)
        W_plf = ustrip(u"lb/ft", StructuralSizer.weight_per_length(sec, mat))
        coating = StructuralSizer.compute_surface_coating(fp, params.fire_rating, W_plf, perimeter_in)
        coating.thickness_in <= 0 && continue
        w_lbft = StructuralSizer.coating_weight_per_foot(coating, perimeter_in)
        w_Nm = dead_factor * to_newtons_per_meter(w_lbft * u"lbf/ft")
        for seg_idx in segment_indices(m)
            edge_idx = struc.segments[seg_idx].edge_idx
            edge_idx in edge_ids || continue
            el = model.frame_elements[edge_idx]
            push!(loads, Asap.LineLoad(el, [0.0u"N/m", 0.0u"N/m", -w_Nm * u"N/m"],
                                       FIRE_COATING_LOAD_ID))
        end
    end
    return loads
end

"""
    unfactored_fire_coating_loads(model) -> Vector{Asap.LineLoad}

Copies of the model's coating loads at their unfactored weight. Each coating
load was factored with its member's self-weight factor, so the copy divides by
the `GravityLoad` factor on the same element over `g`. A coated element with no
self-weight `GravityLoad` throws: its dead factor is unknown.
"""
function unfactored_fire_coating_loads(model)
    out = Asap.LineLoad[]
    isnothing(model) && return out
    accel = Dict{UInt, Float64}()
    for ld in model.loads
        ld isa Asap.GravityLoad && (accel[objectid(ld.element)] = ustrip(u"m/s^2", ld.factor))
    end
    g = ustrip(u"m/s^2", GRAVITY)
    for ld in model.loads
        (ld isa Asap.LineLoad && ld.id === FIRE_COATING_LOAD_ID) || continue
        a = get(accel, objectid(ld.element), nothing)
        (a === nothing || a <= 0) && throw(ArgumentError(
            "fire coating load on a member with no self-weight GravityLoad; " *
            "its dead factor is unknown."))
        push!(out, Asap.LineLoad(ld.element, [v * (g / a) for v in ld.value],
                                 FIRE_COATING_LOAD_ID))
    end
    return out
end
