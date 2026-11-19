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
    return FoundationLateralCases(roof, Float64(rho), Float64(SDS), supports)
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
Vertical reaction and the two plan moments.

`R[gid[3]]` is the same vertical component `_service_reactions` reads.
Compression is positive, matching `FoundationDemand.Pu`.
"""
function _support_footing_action(model, R, supp, label)
    gid = model.nodes[supp.node_idx].globalID
    return FootingAction(label, R[gid[3]], R[gid[4]], R[gid[5]])
end
