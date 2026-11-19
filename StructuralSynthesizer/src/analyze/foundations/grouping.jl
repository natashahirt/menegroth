"""True when any foundation already spans more than one support."""
_explicit_support_groupings(struc) =
    any(f -> length(f.support_indices) > 1, struc.foundations)

"""`:strip` if supports are colinear; `:mat` if both plan axes have span.

ACI 318-11 §15.10.1 — footings supporting more than one column are combined
footings or mats (corpus: aci-318-11, page 277).
"""
function _combined_foundation_type(struc, supp_indices)
    length(supp_indices) < 2 && return :spread
    positions = _support_positions_xy(struc, supp_indices)
    xs = [p[1] for p in positions]
    ys = [p[2] for p in positions]
    Δx = maximum(xs) - minimum(xs)
    Δy = maximum(ys) - minimum(ys)
    # A true line has ~0 span on the perpendicular axis.
    if Δx > 1.0u"ft" && Δy > 1.0u"ft"
        return :mat
    end
    return :strip
end

"""Merge isolated mixed-sign foundations in one reaction group into a strip/mat.

ACI 318-11 §15.10.1 / §15.8.1.2 — do not net a tension-compression couple
into one isolated spread (corpus: aci-318-11, pages 277 / 275).
"""
function _promote_mixed_sign_isolated_groups!(struc, demands)
    isempty(struc.foundation_groups) && return struc
    to_merge = Vector{Vector{Int}}()
    for (_, fg) in struc.foundation_groups
        f_indices = fg.foundation_indices
        length(f_indices) < 2 && continue
        all(i -> length(struc.foundations[i].support_indices) == 1, f_indices) || continue
        supports = [struc.foundations[i].support_indices[1] for i in f_indices]
        _mixed_sign_Pu(demands, supports) || continue
        push!(to_merge, copy(f_indices))
    end
    isempty(to_merge) && return struc

    merged = Set{Int}()
    for f_indices in to_merge
        union!(merged, f_indices)
    end
    placeholder = _placeholder_foundation_result(typeof(struc).parameters[1])
    new_foundations = Foundation[]
    for (fi, fnd) in enumerate(struc.foundations)
        fi in merged && continue
        push!(new_foundations, fnd)
    end
    for f_indices in to_merge
        supports = [struc.foundations[i].support_indices[1] for i in f_indices]
        ftype = _combined_foundation_type(struc, supports)
        push!(new_foundations, Foundation(supports, placeholder; foundation_type=ftype))
    end
    empty!(struc.foundations)
    append!(struc.foundations, new_foundations)
    build_foundation_groups!(struc)
    return struc
end

"""
    build_foundation_groups!(struc::BuildingStructure)

Populate `struc.foundation_groups` from `struc.foundations` using `Foundation.group_id`.
"""
function build_foundation_groups!(struc::BuildingStructure)
    empty!(struc.foundation_groups)
    
    for (f_idx, f) in enumerate(struc.foundations)
        gid = f.group_id === nothing ? UInt64(hash((:singleton_foundation_group, f_idx))) : f.group_id
        f.group_id = gid
        
        fg = get!(struc.foundation_groups, gid) do
            FoundationGroup(gid)
        end
        push!(fg.foundation_indices, f_idx)
    end
    
    return struc.foundation_groups
end

# =============================================================================
# Automatic Grouping by Reaction Similarity
# =============================================================================

"""
    group_foundations_by_reaction!(struc::BuildingStructure; 
                                    tolerance=0.15, 
                                    n_support_bins=true,
                                    demands=nothing)

Automatically assign `group_id` to foundations with similar reaction magnitudes.

# Arguments
- `tolerance`: Relative tolerance for grouping (0.15 = 15% difference allowed)
- `n_support_bins`: If true, also separate by number of supports (single vs combined)
- `demands`: Optional precomputed `support_demands(struc)` to avoid recomputation

# Returns
Number of unique groups created.

# Example
```julia
initialize_supports!(struc)
initialize_foundations!(struc)
demands = support_demands(struc)  # Compute once
n_groups = group_foundations_by_reaction!(struc; tolerance=0.0, demands=demands)
size_foundations_grouped!(struc; soil=medium_sand, demands=demands)
```
"""
function group_foundations_by_reaction!(struc::BuildingStructure; 
                                         tolerance::Real=0.0,
                                         n_support_bins::Bool=true,
                                         demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}}=nothing)
    isempty(struc.foundations) && throw(ArgumentError("No foundations. Call initialize_foundations!() first."))
    
    demands = isnothing(demands) ? support_demands(struc) : demands
    
    # Compute governing Pu for each foundation
    foundation_loads = Float64[]
    for fnd in struc.foundations
        if length(fnd.support_indices) == 1
            Pu = ustrip(u"kN", demands[fnd.support_indices[1]].Pu)
        else
            # Combined: sum of loads
            Pu = sum(ustrip(u"kN", demands[i].Pu) for i in fnd.support_indices)
        end
        push!(foundation_loads, Pu)
    end
    
    # Cluster into groups by similarity
    # Simple greedy clustering: assign to existing group if within tolerance, else create new
    groups = Dict{UInt64, Vector{Int}}()
    group_loads = Dict{UInt64, Float64}()  # Representative load for each group
    
    for (f_idx, load) in enumerate(foundation_loads)
        fnd = struc.foundations[f_idx]
        n_supports = length(fnd.support_indices)
        
        # Find compatible group
        assigned = false
        for (gid, rep_load) in group_loads
            # Check tolerance
            if rep_load > 0 && abs(load - rep_load) / rep_load <= tolerance
                # Check n_supports constraint
                if !n_support_bins || _group_n_supports(struc, groups[gid]) == n_supports
                    push!(groups[gid], f_idx)
                    # Update representative to max (conservative)
                    group_loads[gid] = max(rep_load, load)
                    assigned = true
                    break
                end
            end
        end
        
        if !assigned
            # Create new group
            gid = UInt64(hash((:foundation_reaction_group, length(groups) + 1, n_supports)))
            groups[gid] = [f_idx]
            group_loads[gid] = load
        end
    end
    
    # Assign group_ids to foundations
    for (gid, f_indices) in groups
        for f_idx in f_indices
            struc.foundations[f_idx].group_id = gid
        end
    end
    
    # Build the groups dict
    build_foundation_groups!(struc)
    
    n_groups = length(groups)
    @info "Grouped $(length(struc.foundations)) foundations into $n_groups groups (tolerance=$(tolerance*100)%)"
    
    return n_groups
end

"""Number of supports for the first foundation in a group (for grouping compatibility)."""
function _group_n_supports(struc, f_indices)
    isempty(f_indices) && return 0
    return length(struc.foundations[f_indices[1]].support_indices)
end

"""
    size_foundations_grouped!(struc; soil, opts, demands=nothing, ...)

Size foundations at the group level: design for governing load, apply to all in group.

This is more efficient than individual sizing and ensures constructability
(same footing size for similar columns).

Dispatches on `opts.code` (`:aci` default, `:is` legacy).
"""
function size_foundations_grouped!(
    struc::BuildingStructure;
    soil::StructuralSizer.Soil,
    opts::StructuralSizer.FoundationOptions = StructuralSizer.FoundationOptions(),
    demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}} = nothing,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
    # Legacy IS kwargs
    concrete::StructuralSizer.Concrete = StructuralSizer.NWC_4000,
    rebar::StructuralSizer.Metal = StructuralSizer.Rebar_60,
    pier_width = 0.3u"m",
    kwargs...
)
    isempty(struc.foundations) && throw(ArgumentError(
        "No foundations. Call initialize_foundations!() first."))

    isempty(struc.foundation_groups) && build_foundation_groups!(struc)
    demands = isnothing(demands) ? support_demands(struc) : demands
    _promote_mixed_sign_isolated_groups!(struc, demands)

    gids = collect(keys(struc.foundation_groups))
    n_fnd_groups = length(gids)
    group_results_vec = Vector{Any}(nothing, n_fnd_groups)

    StructuralSizer.emit!(tc, :workflow, "size_foundations_grouped!", "", :enter;
                          n_groups=n_fnd_groups,
                          n_foundations=length(struc.foundations),
                          code=string(opts.code))

    _size_one_group!(k) = begin
        gid = gids[k]
        fg = struc.foundation_groups[gid]
        f_indices = fg.foundation_indices
        isempty(f_indices) && return

        gov_Pu  = 0.0u"kN"
        gov_Ps  = 0.0u"kN"
        gov_Mux = 0.0u"kN*m"
        gov_Muy = 0.0u"kN*m"
        gov_Vux = 0.0u"kN"
        gov_Vuy = 0.0u"kN"

        try
            group_supports = Int[]
            for f_idx in f_indices
                append!(group_supports, struc.foundations[f_idx].support_indices)
            end
            unique!(group_supports)

            if _all_uplift(demands, group_supports)
                @warn "Foundation group $gid in factored uplift — skipping compression footing (ACI 318-11 §15.8.1.2)"
                return
            end

            # ACI 318-11 §15.10.1 — combined footings/mats resist the factored
            # loads (corpus: aci-318-11, page 277). Mixed-sign or multi-support
            # groups keep per-support signed Pu/Ps so x_bar uses the couple
            # (§15.8.1.2, page 275). Do not net into one SpreadFooting.
            needs_signed_combined = _mixed_sign_Pu(demands, group_supports) ||
                any(i -> length(struc.foundations[i].support_indices) > 1 ||
                         struc.foundations[i].foundation_type in (:combined, :strip, :mat),
                    f_indices)

            if needs_signed_combined
                for f_idx in f_indices
                    fnd = struc.foundations[f_idx]
                    n_supp = length(fnd.support_indices)
                    if opts.code == :aci
                        _size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts; tc=tc)
                    else
                        _size_fnd_is!(struc, f_idx, fnd, n_supp, demands, soil,
                                      concrete, rebar, pier_width; tc=tc, kwargs...)
                    end
                end
                if _mixed_sign_Pu(demands, group_supports)
                    has_tensile = any(f_indices) do fi
                        r = struc.foundations[fi].result
                        r isa StructuralSizer.StripFootingResult &&
                            ustrip(u"m^2", r.As_tensile) > 0
                    end
                    has_tensile || error(
                        "Foundation group $gid mixed-sign couple did not form a strip " *
                        "with designed As_tensile (ACI 318-11 §15.8.1.2(b), " *
                        "corpus: aci-318-11, page 275); refuse rather than omit the steel.")
                end
                r = struc.foundations[f_indices[1]].result
                StructuralSizer.emit!(tc, :workflow, "size_foundations_grouped!", "foundation_group_$(gid)", :decision;
                                      n_foundations=length(f_indices),
                                      n_supports=length(group_supports),
                                      mixed_sign=_mixed_sign_Pu(demands, group_supports),
                                      routed="signed_combined",
                                      B_m=Float64(ustrip(u"m", StructuralSizer.footing_width(r))),
                                      L_m=Float64(ustrip(u"m", StructuralSizer.footing_length(r))),
                                      D_m=Float64(ustrip(u"m", StructuralSizer.footing_depth(r))),
                                      utilization=Float64(StructuralSizer.utilization(r)))
                return
            end

            any_compression = false
            service_actions = StructuralSizer.FootingAction[]
            strength_actions = StructuralSizer.FootingAction[]
            n_with_actions = 0
            n_without_actions = 0
            for f_idx in f_indices
                fnd = struc.foundations[f_idx]
                _all_uplift(demands, fnd.support_indices) && continue
                any_compression = true
                d = demands[fnd.support_indices[1]]
                gov_Pu  = max(gov_Pu,  d.Pu)
                gov_Ps  = max(gov_Ps,  d.Ps)
                gov_Mux = max(gov_Mux, abs(d.Mux))
                gov_Muy = max(gov_Muy, abs(d.Muy))
                gov_Vux = max(gov_Vux, abs(d.Vux))
                gov_Vuy = max(gov_Vuy, abs(d.Vuy))
                for si in fnd.support_indices
                    actions = foundation_actions_at(struc, si)
                    if actions === nothing
                        n_without_actions += 1
                    else
                        n_with_actions += 1
                        append!(service_actions, actions.service)
                        append!(strength_actions, actions.strength)
                    end
                end
            end

            if !any_compression
                @warn "Foundation group $gid in factored uplift — skipping compression footing (ACI 318-11 §15.8.1.2)"
                return
            end
            if n_with_actions > 0 && n_without_actions > 0
                error("Foundation group $gid mixes supports that have concurrent " *
                      "load cases with supports that do not. Each case keeps its " *
                      "own axial force and moment (ASCE 7-22 §2.3 and §2.4).")
            end
            # Punching is checked at the smallest column in the group. A larger
            # column would raise the concrete shear strength.
            gov_c1 = nothing
            gov_c2 = nothing
            gov_shape = :rectangular
            for f_idx in f_indices
                fnd = struc.foundations[f_idx]
                for si in fnd.support_indices
                    d = demands[si]
                    gov_c1 = gov_c1 === nothing ? d.c1 : min(gov_c1, d.c1)
                    gov_c2 = gov_c2 === nothing ? d.c2 : min(gov_c2, d.c2)
                    d.shape == :circular && (gov_shape = :circular)
                end
            end
            gov_c1 = something(gov_c1, 18.0u"inch")
            gov_c2 = something(gov_c2, 18.0u"inch")
            gov_demand = StructuralSizer.FoundationDemand(1;
                Pu=gov_Pu, Mux=gov_Mux, Muy=gov_Muy,
                Vux=gov_Vux, Vuy=gov_Vuy, Ps=gov_Ps,
                c1=gov_c1, c2=gov_c2, shape=gov_shape)

            if opts.code == :aci
                # Each support's cases stay intact. The component-wise max of
                # P and M is used only when the wall stage stored no cases.
                group_results_vec[k] = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(),
                    gov_demand, soil; opts=opts.spread_params, tc=tc,
                    service_actions = service_actions,
                    strength_actions = strength_actions)
            else
                group_results_vec[k] = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
                    gov_demand, soil, concrete, rebar;
                    pier_width=pier_width, kwargs...)
            end

            r = group_results_vec[k]
            StructuralSizer.emit!(tc, :workflow, "size_foundations_grouped!", "foundation_group_$(gid)", :decision;
                                  n_foundations=length(f_indices),
                                  gov_Pu_kN=Float64(ustrip(u"kN", gov_Pu)),
                                  gov_c1_in=Float64(ustrip(u"inch", gov_c1)),
                                  gov_c2_in=Float64(ustrip(u"inch", gov_c2)),
                                  shape=string(gov_shape),
                                  B_m=Float64(ustrip(u"m", StructuralSizer.footing_width(r))),
                                  L_m=Float64(ustrip(u"m", StructuralSizer.footing_length(r))),
                                  D_m=Float64(ustrip(u"m", StructuralSizer.footing_depth(r))),
                                  utilization=Float64(StructuralSizer.utilization(r)))
        catch e
            StructuralSizer.emit!(tc, :workflow, "size_foundations_grouped!", "foundation_group_$(gid)", :failure;
                                  error=string(typeof(e)),
                                  message=sprint(showerror, e))
            rethrow()
        end
    end

    if Threads.nthreads() > 1
        tasks = map(1:n_fnd_groups) do k
            Threads.@spawn _size_one_group!(k)
        end
        fetch.(tasks)
    else
        for k in 1:n_fnd_groups
            _size_one_group!(k)
        end
    end

    # Reconstruct Dict from parallel results
    group_results = Dict{UInt64, StructuralSizer.AbstractFoundationResult}()
    for k in 1:n_fnd_groups
        group_results_vec[k] === nothing && continue
        group_results[gids[k]] = group_results_vec[k]
    end

    # Determine material source for volume computation
    if opts.code == :aci
        mat = opts.spread_params.material
        c_mat, r_mat = mat.concrete, mat.rebar
    else
        c_mat, r_mat = concrete, rebar
    end

    # Apply group result to all foundations in each group
    for (f_idx, fnd) in enumerate(struc.foundations)
        gid = fnd.group_id
        gid === nothing && continue
        haskey(group_results, gid) || continue
        result = group_results[gid]
        volumes = _compute_foundation_volumes(result, c_mat, r_mat)
        struc.foundations[f_idx] = Foundation(
            fnd.support_indices, result;
            foundation_type=fnd.foundation_type, group_id=gid, volumes=volumes)
    end

    n_groups = length(struc.foundation_groups)
    total_concrete = sum(StructuralSizer.concrete_volume(f.result) for f in struc.foundations)
    total_steel    = sum(StructuralSizer.steel_volume(f.result)    for f in struc.foundations)
    @info "Sized $n_groups foundation groups ($(opts.code))" total_concrete total_steel

    StructuralSizer.emit!(tc, :workflow, "size_foundations_grouped!", "", :exit;
                          n_groups=n_groups,
                          total_concrete_m3=Float64(ustrip(u"m^3", total_concrete)),
                          total_steel_m3=Float64(ustrip(u"m^3", total_steel)))

    return struc
end

