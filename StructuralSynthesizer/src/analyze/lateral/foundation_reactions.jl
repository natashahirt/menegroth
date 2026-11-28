# =============================================================================
# Unfactored support reactions for foundation combinations
# =============================================================================
# Dead, live, the roof companion, each wind case, and each seismic effect,
# at the support nodes. Combination factors are applied later, one case at
# a time. The solve does not replace `model.u`.

"""One support's unfactored cases. Forces are newtons and newton-metres."""
struct SupportFoundationCases
    D::FootingAction
    L::FootingAction
    companion::FootingAction
    wind::Vector{FootingAction}
    qe::Vector{FootingAction}
end

"""
The cases [`foundation_combination_actions`](@ref) needs, one entry per
support, in `struc.supports` order.
"""
struct FoundationLateralCases
    roof::Symbol
    rho::Float64
    SDS::Float64
    supports::Vector{SupportFoundationCases}
    "Unfactored reaction vectors for D, L, and the roof companion."
    gravity_R::NTuple{3,Vector{Float64}}
    "One reaction vector per wind case."
    wind_R::Vector{Vector{Float64}}
    "One reaction vector per seismic effect, before ρ."
    qe_R::Vector{Vector{Float64}}
end

"""
    foundation_lateral_cases(struc, basic, wind, elf, effects; roof, rho, SDS)
        -> FoundationLateralCases

Support reactions for the unfactored gravity cases already solved in
`basic`, each Chapter 27 wind case, and each seismic effect in `effects`.

`effects` are `QE`, before `ρ`. An empty support list returns an empty
`supports` vector. No rigid links throws: story forces are on the masters.

# Citations
ASCE 7-22 §2.3 and §2.4 are applied by
[`foundation_combination_actions`](@ref), not here.
"""
function foundation_lateral_cases(struc::BuildingStructure, basic::GravityBasicCases,
                                  wind::WindStoryAnalysis, elf::ElfStoryAnalysis,
                                  effects;
                                  roof::Symbol, rho::Real, SDS::Real)
    roof in (:Lr, :S, :R) || throw(ArgumentError(
        "foundation reactions: the roof companion must be :Lr, :S, or :R, " *
        "got :$roof."))
    model = struc.asap_model
    isnothing(model) && throw(ArgumentError(
        "foundation reactions: the building has no Asap model."))
    isempty(struc.asap_rigid_links) && throw(ArgumentError(
        "foundation reactions: story forces are on the rigid-diaphragm " *
        "masters. asap_rigid_links is empty."))
    length(basic.symbols) == 3 || throw(ArgumentError(
        "foundation reactions: expected [:D, :L, roof], got $(basic.symbols)."))
    basic.symbols[3] === roof || throw(ArgumentError(
        "foundation reactions: gravity cases end in :$(basic.symbols[3]), " *
        "not :$roof."))

    gravity_R = ntuple(3) do i
        _case_reactions(model, basic.u[i], _fixed_end_by_element(basic.loads[i]))
    end
    wind_loads = [_wind_loads(struc, wind.levels, c.Fx_kN, c.Fy_kN, c.Mz_kN_m,
                              wind.centroids)
                  for c in wind.cases]
    qe_loads = [seismic_effect_loads(struc, elf, e) for e in effects]
    lateral_loads = vcat(wind_loads, qe_loads)
    lateral_u = isempty(lateral_loads) ? Vector{Vector{Float64}}() :
                Asap.solve(model, lateral_loads, struc.asap_rigid_links)
    wind_R = [_case_reactions(model, lateral_u[j],
                              _fixed_end_by_element(wind_loads[j]))
              for j in eachindex(wind_loads)]
    qe_R = [_case_reactions(model, lateral_u[length(wind_loads) + j],
                            _fixed_end_by_element(qe_loads[j]))
            for j in eachindex(qe_loads)]

    supports = SupportFoundationCases[]
    for (i, supp) in enumerate(struc.supports)
        push!(supports, SupportFoundationCases(
            _support_footing_action(model, gravity_R[1], supp, Symbol("D$i")),
            _support_footing_action(model, gravity_R[2], supp, Symbol("L$i")),
            _support_footing_action(model, gravity_R[3], supp, Symbol("roof$i")),
            [_support_footing_action(model, R, supp, Symbol("W$(j)_$i"))
             for (j, R) in enumerate(wind_R)],
            [_support_footing_action(model, R, supp, Symbol("QE$(j)_$i"))
             for (j, R) in enumerate(qe_R)],
        ))
    end
    return FoundationLateralCases(roof, Float64(rho), Float64(SDS), supports,
                                 gravity_R, wind_R, qe_R)
end

"""
Service and strength actions for support `idx` (1-based, `struc.supports`).

`nothing` when the ordinary-wall stage has not stored lateral cases.
"""
function foundation_actions_at(struc::BuildingStructure, idx::Int)
    lat = struc.foundation_lateral
    lat === nothing && return nothing
    1 <= idx <= length(lat.supports) || throw(ArgumentError(
        "foundation actions: support $idx is outside $(length(lat.supports)) " *
        "stored supports."))
    s = lat.supports[idx]
    service = foundation_combination_actions(
        asce7_asd_foundation_combinations, s.D, s.L, s.companion, s.wind, s.qe;
        roof=lat.roof, rho=lat.rho, SDS=lat.SDS)
    strength = foundation_combination_actions(
        asce7_strength_combinations, s.D, s.L, s.companion, s.wind, s.qe;
        roof=lat.roof, rho=lat.rho, SDS=lat.SDS)
    return (service = service, strength = strength)
end

"""
Vertical reaction, the two plan moments, and the two horizontal base shears.

`R[gid[3]]` is the same vertical component `_service_reactions` reads
(compression positive, matching `FoundationDemand.Pu`). `R[gid[1]]` and
`R[gid[2]]` are the horizontal reactions in global x and y — the base shear
the footing must resist for the global-stability (sliding) check, which uses
their resultant magnitude. `R[gid[4]]`/`R[gid[5]]` are the plan moments.
"""
function _support_footing_action(model, R, supp, label)
    gid = model.nodes[supp.node_idx].globalID
    return FootingAction(label, R[gid[3]], R[gid[4]], R[gid[5]],
                         R[gid[1]], R[gid[2]])
end

"""
Vertical reaction, the two plan moments, and the two horizontal base shears
at one node.

`gid[3]` is the vertical component; `gid[1]`/`gid[2]` are the horizontal
base shears (global x/y) the sliding check resists via their resultant. A
node with fewer than six dofs contributes no plan moment, but a translational
node (≥ 3 dofs) still carries the horizontal reactions.
"""
function _node_reaction_action(node, R, label)
    gid = node.globalID
    P = R[gid[3]]
    Mx = length(gid) >= 5 ? R[gid[4]] : 0.0
    My = length(gid) >= 6 ? R[gid[5]] : 0.0
    Hx = R[gid[1]]
    Hy = R[gid[2]]
    return FootingAction(label, P, Mx, My, Hx, Hy)
end

"""
Service and strength actions at one Asap node.

`nothing` when lateral cases have not been stored. The same combination
list as [`foundation_actions_at`](@ref), so a wall station and a column
share combination order.
"""
function node_foundation_actions(struc::BuildingStructure, node)
    lat = struc.foundation_lateral
    lat === nothing && return nothing
    D = _node_reaction_action(node, lat.gravity_R[1], :D)
    L = _node_reaction_action(node, lat.gravity_R[2], :L)
    companion = _node_reaction_action(node, lat.gravity_R[3], :roof)
    wind = [_node_reaction_action(node, R, Symbol("W$j"))
            for (j, R) in enumerate(lat.wind_R)]
    qe = [_node_reaction_action(node, R, Symbol("QE$j"))
          for (j, R) in enumerate(lat.qe_R)]
    service = foundation_combination_actions(
        asce7_asd_foundation_combinations, D, L, companion, wind, qe;
        roof=lat.roof, rho=lat.rho, SDS=lat.SDS)
    strength = foundation_combination_actions(
        asce7_strength_combinations, D, L, companion, wind, qe;
        roof=lat.roof, rho=lat.rho, SDS=lat.SDS)
    return (service = service, strength = strength)
end
