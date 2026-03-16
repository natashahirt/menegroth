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

"""
    support_demands(struc::BuildingStructure; load_factor=1.0)

Convert support reactions to FoundationDemand objects.

# Arguments
- `load_factor`: Factor to apply (use 1.0 if reactions are already factored)

# Returns
Vector of FoundationDemand, one per support.
"""
function support_demands(struc::BuildingStructure; load_factor::Real=1.0)
    isempty(struc.supports) && throw(ArgumentError("No supports. Call initialize_supports!() first."))
    
    demands = StructuralSizer.FoundationDemand[]
    
    for (i, supp) in enumerate(struc.supports)
        # Extract forces and moments
        Fx = supp.forces[1] * load_factor
        Fy = supp.forces[2] * load_factor
        Fz = supp.forces[3] * load_factor
        Mx = supp.moments[1] * load_factor
        My = supp.moments[2] * load_factor
        Mz = supp.moments[3] * load_factor
        
        # Convention: ASAP reaction is force FROM support TO structure
        # For gravity loads: structure pushes down, support pushes up → Fz is positive
        # For footing: Pu (compression) = magnitude of vertical reaction
        Pu = abs(Fz)  # Compression is always positive for footing design
        
        # Horizontal shears
        Vux = Fx
        Vuy = Fy
        
        # Moments about horizontal axes
        Mux = Mx
        Muy = My
        
        # Service load (unfactored) - approximate as factored/1.4
        Ps = Pu / 1.4
        
        demand = StructuralSizer.FoundationDemand(i; 
            Pu=Pu, Mux=Mux, Muy=Muy, Vux=Vux, Vuy=Vuy, Ps=Ps,
            c1=supp.c1, c2=supp.c2, shape=supp.shape)
        push!(demands, demand)
    end
    
    return demands
end

"""
    initialize_foundations!(struc::BuildingStructure; groupings=nothing)

Create Foundation objects for supports.

# Arguments
- `groupings`: Optional vector of support index vectors for combined foundations.
  If `nothing`, creates 1:1 mapping (one spread footing per support).

# Example
```julia
# One footing per column (default)
initialize_foundations!(struc)

# Combined footing for supports 1 & 2
initialize_foundations!(struc; groupings=[[1, 2], [3], [4]])
```
"""
function initialize_foundations!(struc::BuildingStructure{T}; 
                                  groupings::Union{Nothing, Vector{Vector{Int}}}=nothing) where T
    isempty(struc.supports) && throw(ArgumentError("No supports. Call initialize_supports!() first."))
    
    empty!(struc.foundations)
    
    if isnothing(groupings)
        # Default: one foundation per support
        for (i, _) in enumerate(struc.supports)
            # Placeholder result - will be filled by size_foundations!
            placeholder = _placeholder_foundation_result(T)
            fnd = Foundation([i], placeholder; foundation_type=:spread)
            push!(struc.foundations, fnd)
        end
    else
        # Explicit groupings
        for supp_indices in groupings
            ftype = length(supp_indices) > 1 ? :combined : :spread
            placeholder = _placeholder_foundation_result(T)
            fnd = Foundation(supp_indices, placeholder; foundation_type=ftype)
            push!(struc.foundations, fnd)
        end
    end
    
    @debug "Initialized $(length(struc.foundations)) foundations"
    return struc
end

"""Create a zero-valued `SpreadFootingResult` placeholder for undesigned foundations."""
function _placeholder_foundation_result(::Type{T}) where T
    L = typeof(1.0u"m")
    V = typeof(1.0u"m^3")
    F = typeof(1.0u"kN")
    StructuralSizer.SpreadFootingResult{L, V, F}(
        0.0u"m", 0.0u"m", 0.0u"m", 0.0u"m",
        0.0u"m", 0, 0.0u"m",
        0.0u"m^3", 0.0u"m^3", 0.0
    )
end

"""Size each foundation in `struc.foundations` as-is (no strategy / grouping logic)."""
function _size_foundation!(
    struc::BuildingStructure;
    soil::StructuralSizer.Soil,
    opts::StructuralSizer.FoundationOptions = StructuralSizer.FoundationOptions(),
    demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}} = nothing,
    concrete::StructuralSizer.Concrete = StructuralSizer.NWC_4000,
    rebar::StructuralSizer.Metal = StructuralSizer.Rebar_60,
    pier_width = 0.3u"m",
    kwargs...
)
    isempty(struc.foundations) && throw(ArgumentError(
        "No foundations. Call initialize_foundations!() first."))

    demands = isnothing(demands) ? support_demands(struc) : demands
    n_fnd = length(struc.foundations)

    # ── Per-foundation sizing closure ────────────────────────────────────
    _size_one_fnd!(f_idx) = begin
        fnd = struc.foundations[f_idx]
        n_supp = length(fnd.support_indices)

        if opts.code == :aci
            _size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts)
        else
            _size_fnd_is!(struc, f_idx, fnd, n_supp, demands, soil,
                          concrete, rebar, pier_width; kwargs...)
        end
    end

    # ── Dispatch (threaded or serial) ────────────────────────────────────
    if Threads.nthreads() > 1
        Threads.@threads for f_idx in 1:n_fnd
            _size_one_fnd!(f_idx)
        end
    else
        for f_idx in 1:n_fnd
            _size_one_fnd!(f_idx)
        end
    end

    total_concrete = sum(StructuralSizer.concrete_volume(f.result) for f in struc.foundations)
    total_steel    = sum(StructuralSizer.steel_volume(f.result)    for f in struc.foundations)
    @info "Sized $(length(struc.foundations)) foundations ($(opts.code))" total_concrete total_steel

    return struc
end

# ─────────────────────────────────────────────────────────────────────────────
# ACI 318-11 dispatch
# ─────────────────────────────────────────────────────────────────────────────

"""Dispatch a single foundation through the ACI 318 sizing path (spread, strip, or mat)."""
function _size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts)
    mat = opts.spread_params.material   # ReinforcedConcreteMaterial (concrete + rebar)

    if fnd.foundation_type == :mat
        # Mat foundation — all supports in one slab
        mat_demands = [demands[i] for i in fnd.support_indices]
        positions = _support_positions_xy(struc, fnd.support_indices)
        result = StructuralSizer.design_footing(StructuralSizer.MatFoundation(), 
            mat_demands, positions, soil; opts=opts.mat_params)
        _assign_foundation!(struc, f_idx, fnd, result, :mat, mat)

    elseif fnd.foundation_type == :spread && n_supp == 1
        demand = demands[fnd.support_indices[1]]
        result = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), demand, soil; opts=opts.spread_params)
        _assign_foundation!(struc, f_idx, fnd, result, :spread, mat)

    elseif fnd.foundation_type in (:combined, :strip) || n_supp > 1
        strip_demands = [demands[i] for i in fnd.support_indices]
        positions = _support_positions_along_axis(struc, fnd.support_indices)
        result = StructuralSizer.design_footing(StructuralSizer.StripFooting(), 
            strip_demands, positions, soil; opts=opts.strip_params)
        _assign_foundation!(struc, f_idx, fnd, result, :strip, mat)
    else
        @warn "Foundation type $(fnd.foundation_type) not wired for ACI, skipping"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# IS 456 legacy dispatch
# ─────────────────────────────────────────────────────────────────────────────

"""Dispatch a single foundation through the IS 456 legacy sizing path."""
function _size_fnd_is!(struc, f_idx, fnd, n_supp, demands, soil,
                       concrete, rebar, pier_width; kwargs...)
    if fnd.foundation_type == :spread && n_supp == 1
        demand = demands[fnd.support_indices[1]]
        result = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
            demand, soil, concrete, rebar; pier_width=pier_width, kwargs...)
        volumes = _compute_foundation_volumes(result, concrete, rebar)
        struc.foundations[f_idx] = Foundation(
            fnd.support_indices, result;
            foundation_type=:spread, group_id=fnd.group_id, volumes=volumes)

    elseif fnd.foundation_type == :combined || n_supp > 1
        total_Pu = sum(demands[i].Pu for i in fnd.support_indices)
        combined_demand = StructuralSizer.FoundationDemand(f_idx;
            Pu=total_Pu, Ps=total_Pu / 1.4)
        result = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
            combined_demand, soil, concrete, rebar; pier_width=pier_width, kwargs...)
        volumes = _compute_foundation_volumes(result, concrete, rebar)
        struc.foundations[f_idx] = Foundation(
            fnd.support_indices, result;
            foundation_type=:combined, group_id=fnd.group_id, volumes=volumes)
        @warn "Combined footing designed as equivalent spread footing (IS simplified)"
    else
        @warn "Foundation type $(fnd.foundation_type) not implemented (IS), skipping"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Assign a sized foundation result back into struc, computing material volumes."""
function _assign_foundation!(struc, f_idx, fnd, result, ftype::Symbol, mat)
    concrete_mat = mat.concrete
    rebar_mat    = mat.rebar
    volumes = _compute_foundation_volumes(result, concrete_mat, rebar_mat)
    struc.foundations[f_idx] = Foundation(
        fnd.support_indices, result;
        foundation_type=ftype, group_id=fnd.group_id, volumes=volumes)
end

"""Extract support positions along the longest axis (for strip footing layout)."""
function _support_positions_along_axis(struc, supp_indices::Vector{Int})
    skel = struc.skeleton
    pts = [skel.vertices[struc.supports[i].vertex_idx] for i in supp_indices]

    # Project onto principal axis (longest span)
    if length(pts) <= 1
        return [0.0u"m"]
    end

    # Use X or Y depending on which has larger range
    xs = [p[1] for p in pts]
    ys = [p[2] for p in pts]
    Δx = maximum(xs) - minimum(xs)
    Δy = maximum(ys) - minimum(ys)

    coords = Δx >= Δy ? xs : ys
    origin = minimum(coords)
    return [c - origin for c in coords]
end

"""Extract support positions as (x, y) tuples (for mat footing layout)."""
function _support_positions_xy(struc, supp_indices::Vector{Int})
    skel = struc.skeleton
    return [let v = skel.vertices[struc.supports[i].vertex_idx]
        (v[1], v[2])
    end for i in supp_indices]
end

"""Compute material volumes for a foundation from its result."""
function _compute_foundation_volumes(result::R, concrete, rebar) where R<:AbstractFoundationResult
    MaterialVolumes(
        concrete => StructuralSizer.concrete_volume(result),
        rebar => StructuralSizer.steel_volume(result)
    )
end

"""Print rebar schedule line for a spread footing (count × bar size each way)."""
function _print_rebar_line(r::StructuralSizer.SpreadFootingResult, du)
    println("  Rebar: $(r.rebar_count) × $(fmt(du, :rebar_dia, r.rebar_dia, digits=0)) each way")
end
"""Print rebar schedule line for a strip footing (longitudinal + transverse areas)."""
function _print_rebar_line(r::StructuralSizer.StripFootingResult, du)
    println("  Rebar: As_long=$(fmt(du, :rebar_area, r.As_long_bot)), As_trans=$(fmt(du, :rebar_area, r.As_trans))")
end
"""Print rebar schedule line for a mat footing (x- and y-direction areas)."""
function _print_rebar_line(r::StructuralSizer.MatFootingResult, du)
    println("  Rebar: As_x=$(fmt(du, :rebar_area, r.As_x_bot)), As_y=$(fmt(du, :rebar_area, r.As_y_bot))")
end
"""Fallback rebar line for unrecognised foundation result types."""
_print_rebar_line(r, du) = println("  Rebar: (see result object)")

"""
    foundation_summary(design::BuildingDesign)
    foundation_summary(struc::BuildingStructure; du=imperial)

Print a summary of all foundations in the structure.
Display units controlled by `du` (default: `imperial`).
"""
function foundation_summary(design::BuildingDesign)
    foundation_summary(design.structure; du=design.params.display_units)
end

function foundation_summary(struc::BuildingStructure; du::DisplayUnits=imperial)
    isempty(struc.foundations) && return println("No foundations designed.")
    
    println("\n=== Foundation Summary ===")
    println("─" ^ 60)
    
    total_concrete = 0.0u"m^3"
    total_steel = 0.0u"m^3"
    total_area = 0.0u"m^2"
    
    for (i, fnd) in enumerate(struc.foundations)
        r = fnd.result
        supp_str = join(fnd.support_indices, ", ")
        
        println("Foundation $i ($(fnd.foundation_type), supports: [$supp_str])")
        println("  Size: $(fmt(du, :length, r.B)) × $(fmt(du, :length, r.L_ftg)) × $(fmt(du, :length, r.D))")
        _print_rebar_line(r, du)
        println("  Concrete: $(fmt(du, :volume, r.concrete_volume, digits=3))")
        println("  Steel: $(fmt(du, :volume, r.steel_volume, digits=5))")
        println("  Utilization: $(round(r.utilization * 100, digits=1))%")
        println()
        
        total_concrete += r.concrete_volume
        total_steel += r.steel_volume
        total_area += StructuralSizer.footprint_area(r)
    end
    
    println("─" ^ 60)
    println("TOTALS:")
    println("  Foundations: $(length(struc.foundations))")
    println("  Footprint area: $(fmt(du, :area, total_area))")
    println("  Concrete volume: $(fmt(du, :volume, total_concrete))")
    println("  Steel volume: $(fmt(du, :volume, total_steel, digits=4))")
    println("  Steel weight: $(fmt(du, :mass, total_steel * 7850u"kg/m^3", digits=1))")
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

    gids = collect(keys(struc.foundation_groups))
    n_fnd_groups = length(gids)
    group_results_vec = Vector{Any}(nothing, n_fnd_groups)

    _size_one_group!(k) = begin
        gid = gids[k]
        fg = struc.foundation_groups[gid]
        f_indices = fg.foundation_indices
        isempty(f_indices) && return

        gov_Pu  = 0.0u"kN"
        gov_Mux = 0.0u"kN*m"
        gov_Muy = 0.0u"kN*m"
        gov_Vux = 0.0u"kN"
        gov_Vuy = 0.0u"kN"

        for f_idx in f_indices
            fnd = struc.foundations[f_idx]
            if length(fnd.support_indices) == 1
                d = demands[fnd.support_indices[1]]
                gov_Pu  = max(gov_Pu,  d.Pu)
                gov_Mux = max(gov_Mux, abs(d.Mux))
                gov_Muy = max(gov_Muy, abs(d.Muy))
                gov_Vux = max(gov_Vux, abs(d.Vux))
                gov_Vuy = max(gov_Vuy, abs(d.Vuy))
            else
                total_Pu = sum(demands[i].Pu for i in fnd.support_indices)
                gov_Pu = max(gov_Pu, total_Pu)
            end
        end

        gov_Ps = gov_Pu / 1.4
        # Use the largest column dimensions in the group (conservative for punching)
        gov_c1 = 18.0u"inch"
        gov_c2 = 18.0u"inch"
        gov_shape = :rectangular
        for f_idx in f_indices
            fnd = struc.foundations[f_idx]
            for si in fnd.support_indices
                d = demands[si]
                gov_c1 = max(gov_c1, d.c1)
                gov_c2 = max(gov_c2, d.c2)
                d.shape == :circular && (gov_shape = :circular)
            end
        end
        gov_demand = StructuralSizer.FoundationDemand(1;
            Pu=gov_Pu, Mux=gov_Mux, Muy=gov_Muy,
            Vux=gov_Vux, Vuy=gov_Vuy, Ps=gov_Ps,
            c1=gov_c1, c2=gov_c2, shape=gov_shape)

        if opts.code == :aci
            group_results_vec[k] = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
                gov_demand, soil; opts=opts.spread_params)
        else
            group_results_vec[k] = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
                gov_demand, soil, concrete, rebar;
                pier_width=pier_width, kwargs...)
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

    return struc
end

"""
    foundation_group_summary(design::BuildingDesign; demands=nothing)
    foundation_group_summary(struc::BuildingStructure; du=imperial, demands=nothing)

Print a summary organized by foundation groups.
Display units controlled by `du` (default: `imperial`).

# Arguments
- `demands`: Optional precomputed `support_demands(struc)` to avoid recomputation
"""
function foundation_group_summary(design::BuildingDesign;
                                   demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}}=nothing)
    foundation_group_summary(design.structure; du=design.params.display_units, demands=demands)
end

function foundation_group_summary(struc::BuildingStructure; 
                                   du::DisplayUnits=imperial,
                                   demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}}=nothing)
    isempty(struc.foundation_groups) && return println("No foundation groups. Call build_foundation_groups!() first.")
    
    demands = isnothing(demands) ? support_demands(struc) : demands
    
    println("\n=== Foundation Group Summary ===")
    println("─" ^ 70)
    
    total_concrete = 0.0u"m^3"
    total_steel = 0.0u"m^3"
    
    for (g_idx, (gid, fg)) in enumerate(struc.foundation_groups)
        f_indices = fg.foundation_indices
        n_ftg = length(f_indices)
        
        # Get representative foundation
        fnd = struc.foundations[f_indices[1]]
        r = fnd.result
        
        # Load range in group
        loads = Float64[]
        for f_idx in f_indices
            f = struc.foundations[f_idx]
            if length(f.support_indices) == 1
                push!(loads, ustrip(u"kN", demands[f.support_indices[1]].Pu))
            else
                push!(loads, sum(ustrip(u"kN", demands[i].Pu) for i in f.support_indices))
            end
        end
        
        load_min = minimum(loads)
        load_max = maximum(loads)
        
        println("Group $g_idx: $n_ftg foundations")
        println("  Load range: $(round(load_min, digits=1)) - $(round(load_max, digits=1)) kN")
        println("  Size: $(fmt(du, :length, r.B)) × $(fmt(du, :length, r.L_ftg)) × $(fmt(du, :length, r.D))")
        _print_rebar_line(r, du)
        println("  Concrete/footing: $(fmt(du, :volume, r.concrete_volume, digits=3))")
        println("  Group total concrete: $(fmt(du, :volume, r.concrete_volume * n_ftg))")
        println()
        
        total_concrete += r.concrete_volume * n_ftg
        total_steel += r.steel_volume * n_ftg
    end
    
    println("─" ^ 70)
    println("TOTALS:")
    println("  Groups: $(length(struc.foundation_groups))")
    println("  Foundations: $(length(struc.foundations))")
    println("  Concrete volume: $(fmt(du, :volume, total_concrete))")
    println("  Steel volume: $(fmt(du, :volume, total_steel, digits=4))")
    println("  Steel weight: $(fmt(du, :mass, total_steel * 7850u"kg/m^3", digits=1))")
end

# =============================================================================
# Strategy-Aware Foundation Pipeline
# =============================================================================

"""
    _resolve_strategy(struc, demands, soil, opts) → Symbol

Determine foundation strategy: `:spread`, `:strip`, or `:mat`.

# Strategy values
- `:auto` — Coverage-based: spread (<30%), strip (30–50%), mat (>threshold).
- `:auto_strip_spread` — Same as auto but never picks mat; high coverage → strip.
- `:all_spread`, `:all_strip`, `:mat` — Explicit override.
"""
function _resolve_strategy(struc, demands, soil, opts)
    strat = opts.strategy
    strat == :all_spread && return :spread
    strat == :all_strip  && return :strip
    strat == :mat        && return :mat
    strat != :auto && strat != :auto_strip_spread && return strat

    # Auto: estimate required spread footing area per support
    qa = soil.qa
    total_req = 0.0u"m^2"
    for d in demands
        A_req = d.Ps / qa
        total_req += A_req
    end

    # Building footprint from skeleton bounding box
    skel = struc.skeleton
    verts = skel.vertices
    isempty(verts) && return :spread
    xs = [v[1] for v in verts]
    ys = [v[2] for v in verts]
    footprint = (maximum(xs) - minimum(xs)) * (maximum(ys) - minimum(ys))
    footprint_m2 = ustrip(u"m^2", footprint)
    footprint_m2 < 1.0 && return :spread

    coverage = ustrip(u"m^2", total_req) / footprint_m2

    result = if coverage > opts.mat_coverage_threshold
        :mat
    elseif coverage > 0.30
        :strip
    else
        :spread
    end

    # auto_strip_spread: never pick mat; high coverage → strip
    if strat == :auto_strip_spread && result == :mat
        return :strip
    end
    return result
end

"""
    _strip_groupings_from_orthogonal_grid(struc) → Vector{Vector{Int}}

Use DDM-style column-line detection to group supports into strips.
Uses governing spans from cells (primary/secondary axis) and clusters supports
by projection onto the perpendicular axis within 10% of primary span (ACI §8.10.2.4).
Returns empty if no cells or geometry, or if the structure is not orthogonal.

Strips run along the primary (short) span direction — each column line = one strip.
"""
function _strip_groupings_from_orthogonal_grid(struc::BuildingStructure)
    isempty(struc.supports) && return Vector{Int}[]
    isempty(struc.cells) && return Vector{Int}[]
    isnothing(struc.skeleton.geometry) && return Vector{Int}[]

    skel = struc.skeleton
    vc = skel.geometry.vertex_coords

    # Governing spans from cells (same source as DDM)
    cell_spans = [c.spans for c in struc.cells]
    spans_gov = StructuralSizer.governing_spans(cell_spans)
    span_axis = spans_gov.axis
    l1 = spans_gov.primary

    ax_len = hypot(span_axis...)
    ax_len < 1e-9 && return Vector{Int}[]
    span_axis = (span_axis[1] / ax_len, span_axis[2] / ax_len)
    perp_axis = (-span_axis[2], span_axis[1])  # 90° CCW

    l1_m = ustrip(u"m", l1)
    cluster_tol = 0.10 * l1_m  # ACI §8.10.2.4: columns within 10% of span = same column line

    # Project each support onto the perpendicular axis (DDM column-line logic)
    perp_projs = [let vi = struc.supports[i].vertex_idx
        vc[vi, 1] * perp_axis[1] + vc[vi, 2] * perp_axis[2]
    end for i in 1:length(struc.supports)]

    # Span-axis projections (for ordering within each strip)
    span_projs = [let vi = struc.supports[i].vertex_idx
        vc[vi, 1] * span_axis[1] + vc[vi, 2] * span_axis[2]
    end for i in 1:length(struc.supports)]

    # Cluster supports by perpendicular projection (same column line)
    assigned = falses(length(struc.supports))
    groups = Vector{Int}[]
    sorted_order = sortperm(perp_projs)

    for idx in sorted_order
        assigned[idx] && continue
        group = [idx]
        assigned[idx] = true
        for jdx in sorted_order
            assigned[jdx] && continue
            if abs(perp_projs[jdx] - perp_projs[idx]) <= cluster_tol
                push!(group, jdx)
                assigned[jdx] = true
            end
        end
        sort!(group; by=i -> span_projs[i])  # Order along strip for design
        push!(groups, group)
    end

    return groups
end

"""
    _auto_merge_to_strips!(struc, demands, soil, opts) → struc

Inspect spread footings for adjacency and merge overlapping pairs into
strip footings. After this call, `struc.foundations` may contain a mix of
`:spread` (single support) and `:strip` (multiple supports).

Merge criterion: gap between footing edges < `merge_gap_factor × D_max`.
"""
function _auto_merge_to_strips!(struc, demands, soil, opts)
    N = length(struc.foundations)
    N < 2 && return struc

    qa = soil.qa
    skel = struc.skeleton

    # Tentative spread footing widths (B ≈ √(Ps/qa)) and a default D
    spreads = Vector{NamedTuple{(:idx, :x, :y, :B, :D), Tuple{Int, Float64, Float64, Float64, Float64}}}()
    for (fi, fnd) in enumerate(struc.foundations)
        length(fnd.support_indices) != 1 && continue
        si = fnd.support_indices[1]
        d = demands[si]
        B = sqrt(ustrip(u"m^2", d.Ps / qa))
        D = max(B * 0.15, 0.3)   # rough depth ≈ 15% of B, min 0.3 m
        v = skel.vertices[struc.supports[si].vertex_idx]
        push!(spreads, (idx=fi, x=ustrip(u"m", v[1]), y=ustrip(u"m", v[2]), B=B, D=D))
    end

    merge_factor = opts.strip_params.merge_gap_factor
    merged = Set{Int}()   # foundation indices already merged
    new_groups = Vector{Vector{Int}}()   # groups of support indices to merge

    # Greedy pairwise merge (column-line detection)
    for i in eachindex(spreads)
        spreads[i].idx in merged && continue
        group_support = [struc.foundations[spreads[i].idx].support_indices[1]]
        group_fnd_idx = [spreads[i].idx]

        for j in (i+1):length(spreads)
            spreads[j].idx in merged && continue

            dx = abs(spreads[i].x - spreads[j].x)
            dy = abs(spreads[i].y - spreads[j].y)
            dist = sqrt(dx^2 + dy^2)
            half_Bi = spreads[i].B / 2
            half_Bj = spreads[j].B / 2
            gap = dist - half_Bi - half_Bj
            D_max = max(spreads[i].D, spreads[j].D)

            # Merge if footings would nearly touch / overlap
            if gap < merge_factor * D_max
                push!(group_support, struc.foundations[spreads[j].idx].support_indices[1])
                push!(group_fnd_idx, spreads[j].idx)
                push!(merged, spreads[j].idx)
            end
        end

        if length(group_support) > 1
            push!(merged, spreads[i].idx)
            push!(new_groups, group_support)
        end
    end

    isempty(new_groups) && return struc

    # Rebuild foundations: keep non-merged as :spread, add merged as :strip
    placeholder = _placeholder_foundation_result(typeof(struc).parameters[1])
    new_foundations = Foundation[]

    for (fi, fnd) in enumerate(struc.foundations)
        fi in merged && continue
        push!(new_foundations, fnd)
    end
    for supp_group in new_groups
        push!(new_foundations,
            Foundation(supp_group, placeholder; foundation_type=:strip))
    end

    empty!(struc.foundations)
    append!(struc.foundations, new_foundations)

    n_strips = length(new_groups)
    n_spreads = count(f -> f.foundation_type == :spread, struc.foundations)
    @info "Auto-merge: $n_strips strips + $n_spreads spreads (from $(N) original)"

    return struc
end

"""
    size_foundations!(struc; soil, opts, demands=nothing, group_tolerance=0.15, verbose=true)

Strategy-aware foundation sizing pipeline:

1. Compute demands from support reactions
2. Determine strategy (`:spread`, `:strip`, `:mat`) from coverage or user override
3. For `:mat` → one mat foundation covering all supports
4. For `:strip`:
   - Infer orthogonal grid from support positions (primary/secondary axes, spacing)
   - If orthogonal: strips along axis with shorter spacing (one strip per row/column)
   - If not orthogonal: fall back to spread footings + merge foundations too close
5. For `:spread` → group by reaction similarity, size one per group
6. Size all foundations via ACI or IS dispatch
"""
function size_foundations!(
    struc::BuildingStructure;
    soil::StructuralSizer.Soil,
    opts::StructuralSizer.FoundationOptions = StructuralSizer.FoundationOptions(),
    demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}} = nothing,
    group_tolerance::Float64 = 0.15,
    verbose::Bool = true,
    # Legacy IS kwargs
    concrete::StructuralSizer.Concrete = StructuralSizer.NWC_4000,
    rebar::StructuralSizer.Metal = StructuralSizer.Rebar_60,
    pier_width = 0.3u"m",
    kwargs...
)
    demands = isnothing(demands) ? support_demands(struc) : demands
    strategy = _resolve_strategy(struc, demands, soil, opts)
    verbose && @info "Foundation strategy: $strategy" opts_strategy=opts.strategy

    if strategy == :mat
        # Single mat foundation covering all supports
        all_supp = collect(1:length(struc.supports))
        placeholder = _placeholder_foundation_result(typeof(struc).parameters[1])
        empty!(struc.foundations)
        push!(struc.foundations, Foundation(all_supp, placeholder; foundation_type=:mat))
        _size_foundation!(struc; soil=soil, opts=opts, demands=demands,
                               concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)

    elseif strategy == :strip
        initialize_foundations!(struc)
        strip_groups = _strip_groupings_from_orthogonal_grid(struc)
        if !isempty(strip_groups)
            # Orthogonal grid detected: create strip foundations along shorter-spacing axis
            placeholder = _placeholder_foundation_result(typeof(struc).parameters[1])
            in_strip = Set{Int}()
            new_foundations = Foundation[]
            for g in strip_groups
                length(g) > 1 || continue
                union!(in_strip, g)
                push!(new_foundations, Foundation(g, placeholder; foundation_type=:strip))
            end
            for fnd in struc.foundations
                length(fnd.support_indices) == 1 || continue
                fnd.support_indices[1] in in_strip && continue
                push!(new_foundations, fnd)
            end
            empty!(struc.foundations)
            append!(struc.foundations, new_foundations)
            verbose && @info "Strip groupings from orthogonal grid: $(count(g -> length(g) > 1, strip_groups)) strips"
        else
            # Non-orthogonal or irregular: merge foundations that are too close
            _auto_merge_to_strips!(struc, demands, soil, opts)
        end
        _size_foundation!(struc; soil=soil, opts=opts, demands=demands,
                               concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)

    else  # :spread
        # Pure spread → group by reaction for efficiency
        initialize_foundations!(struc)
        group_foundations_by_reaction!(struc; tolerance=group_tolerance, demands=demands)
        size_foundations_grouped!(struc; soil=soil, opts=opts, demands=demands,
                                  concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)
    end

    return struc
end
