# =============================================================================
# Drop-Panel Self-Weight → Column-Top Node Forces
# =============================================================================

"""Load id of every drop-panel self-weight `Asap.NodeForce` on the building model."""
const DROP_PANEL_LOAD_ID = :drop_panel_self_weight

"""True when any slab carries a drop panel."""
_has_drop_panels(struc) = any(s -> !isnothing(s.drop_panel), struc.slabs)

"""
    drop_panel_column_volumes(struc, slab) -> Vector{Tuple{Int, Volume}}

`(vertex_idx, V)` for each column under `slab`'s drop panel. `V = h_drop × A`
is the drop projection below the slab soffit; `A` is the clipped drop outline
the slab sizer, punching check, and FEA patch use
([`StructuralSizer.column_drop_panel_areas`](@ref)). Empty when the slab has no
drop panel.

`vertex_idx` is the column's top skeleton vertex, which is also the index of
its node in the building model.
"""
function drop_panel_column_volumes(struc, slab)
    out = Tuple{Int, typeof(1.0u"m^3")}[]
    dp = slab.drop_panel
    isnothing(dp) && return out
    cols = StructuralSizer.find_supporting_columns(struc, Set(slab.cell_indices))
    areas = StructuralSizer.column_drop_panel_areas(cols, dp, StructuralSizer._get_span_axis(slab))
    nv = length(struc.skeleton.vertices)
    for (col, A) in zip(cols, areas)
        1 <= col.vertex_idx <= nv || continue
        push!(out, (col.vertex_idx, uconvert(u"m^3", dp.h_drop * A)))
    end
    return out
end

"""Density of the slab concrete, read from the slab's volume takeoff."""
function _drop_panel_density(slab)
    mat = _concrete_volume_key(slab.volumes, nothing)
    mat === nothing && throw(ArgumentError(
        "drop-panel self-weight: the slab has a drop panel but no concrete in " *
        "its volumes, so the drop density is unknown."))
    return mat isa StructuralSizer.FiberReinforcedConcrete ? mat.concrete.ρ : mat.ρ
end

"""
    drop_panel_weights_by_vertex(struc) -> Dict{Int, Force}

Unfactored drop-panel weight `ρ g V` at each column-top skeleton vertex,
summed over the slabs that meet there.
"""
function drop_panel_weights_by_vertex(struc)
    W = Dict{Int, typeof(1.0u"N")}()
    for slab in struc.slabs
        isnothing(slab.drop_panel) && continue
        ρ = _drop_panel_density(slab)
        for (v, V) in drop_panel_column_volumes(struc, slab)
            W[v] = get(W, v, 0.0u"N") + uconvert(u"N", ρ * GRAVITY * V)
        end
    end
    return W
end

"""
    drop_panel_weight_loads(struc, nodes; factor=1.0) -> Vector{Asap.NodeForce}

Drop-panel self-weight `factor × ρ g V` as a global −Z force on each column-top
node. `factor = 1` is the unfactored dead load; the building model stores the
dead factor of its solve ([`_sync_drop_panel_loads!`](@ref)). Slab `self_weight`
is `γ h` over the panel and does not include the drop projection.

# Engineering judgment
User decision 2026-11-09: the drop projection is lumped as a nodal dead load at
the column top rather than a patch pressure over the drop footprint. The force
reaches the column directly, so frame moments from the drop weight over the
part of the drop that lies in the span are not represented.
"""
function drop_panel_weight_loads(struc, nodes; factor::Real=1.0)
    out = Asap.NodeForce[]
    for (v, W) in sort!(collect(drop_panel_weights_by_vertex(struc)); by=first)
        F = factor * W
        F > 0.0u"N" || continue
        push!(out, Asap.NodeForce(nodes[v], [0.0u"N", 0.0u"N", -F], DROP_PANEL_LOAD_ID))
    end
    return out
end

"""Unfactored drop-panel forces on the building model's nodes."""
function unfactored_drop_panel_loads(struc)
    model = struc.asap_model
    isnothing(model) && return Asap.NodeForce[]
    return drop_panel_weight_loads(struc, model.nodes)
end

"""
    _sync_drop_panel_loads!(struc, params) -> Int

Replace every drop-panel force on the model with forces for the current drop
geometry, at the same dead factor as the other self-weight loads. Does not
re-solve. Returns the count.
"""
function _sync_drop_panel_loads!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    isnothing(model) && return 0
    filter!(ld -> !(ld isa Asap.NodeForce && ld.id === DROP_PANEL_LOAD_ID), model.loads)
    _has_drop_panels(struc) || return 0
    factor = _self_weight_dead_factor(params; patterned=_pattern_dead_split(struc, params))
    loads = drop_panel_weight_loads(struc, model.nodes; factor)
    append!(model.loads, loads)
    return length(loads)
end
