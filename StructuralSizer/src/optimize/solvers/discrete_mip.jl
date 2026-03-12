import JuMP
import HiGHS

"""Whether Gurobi.jl is available in the current environment."""
const _HAS_GUROBI = Ref(false)
try
    import Gurobi
    _HAS_GUROBI[] = true
catch
    _HAS_GUROBI[] = false
end

"""Thread-local Gurobi environment pool (one `Env` per thread)."""
const _GUROBI_ENV_POOL = Dict{Int, Any}()

"""Lock guarding `_GUROBI_ENV_POOL` access."""
const _GUROBI_ENV_LOCK = ReentrantLock()

"""
    _reset_gurobi_env!()

Reset all cached Gurobi environments. Called from `__init__` to clear stale
pointers that survive precompilation (C pointers are invalid after deserialisation).
"""
function _reset_gurobi_env!()
    lock(_GUROBI_ENV_LOCK) do
        empty!(_GUROBI_ENV_POOL)
    end
end

"""
    _get_gurobi_env()

Get or create a thread-local cached Gurobi environment.  Each thread keeps
its own `Gurobi.Env` so that parallel `@threads` solves are safe.
"""
function _get_gurobi_env()
    tid = Threads.threadid()
    env = lock(_GUROBI_ENV_LOCK) do
        get(_GUROBI_ENV_POOL, tid, nothing)
    end
    if env === nothing || env.ptr_env == C_NULL
        new_env = Gurobi.Env()
        lock(_GUROBI_ENV_LOCK) do
            _GUROBI_ENV_POOL[tid] = new_env
        end
        return new_env
    end
    return env
end

# =============================================================================
# JuMP / Solver Warm-up
# =============================================================================

"""
    _warmup_jump_solvers()

Solve a trivial one-variable MIP through each available backend so that
JuMP's bridge / MOI layers are JIT-compiled once during package loading.
Called from `__init__`.
"""
function _warmup_jump_solvers()
    # ── HiGHS ──
    try
        m = JuMP.Model(HiGHS.Optimizer)
        JuMP.set_optimizer_attribute(m, "output_flag", false)
        JuMP.@variable(m, x >= 0, Int)
        JuMP.@objective(m, Min, x)
        JuMP.optimize!(m)
    catch e
        @debug "JuMP/HiGHS warmup skipped" exception = e
    end

    # ── Gurobi ──
    if _HAS_GUROBI[]
        try
            env = _get_gurobi_env()
            m = JuMP.Model(() -> Gurobi.Optimizer(env))
            JuMP.set_silent(m)
            JuMP.@variable(m, x >= 0, Int)
            JuMP.@objective(m, Min, x)
            JuMP.optimize!(m)
        catch e
            # No license or other Gurobi failure — use HiGHS for :auto from now on
            @info "Gurobi unavailable (e.g. no license); :auto will use HiGHS" exception = e
            _HAS_GUROBI[] = false
        end
    end
    nothing
end

# =============================================================================
# MIP Optimizer Selection
# =============================================================================

"""
    _choose_mip_optimizer(optimizer::Symbol)

Select a JuMP optimizer constructor.

- `:auto`: prefer Gurobi if available, else HiGHS
- `:gurobi`: require Gurobi
- `:highs`: use HiGHS
"""
function _choose_mip_optimizer(optimizer::Symbol)
    if optimizer === :highs
        return (() -> HiGHS.Optimizer()), :highs
    elseif optimizer === :gurobi
        _HAS_GUROBI[] || throw(ArgumentError("optimizer=:gurobi requested, but Gurobi.jl is not available in this environment."))
        return (() -> Gurobi.Optimizer(_get_gurobi_env())), :gurobi
    elseif optimizer === :auto
        if _HAS_GUROBI[]
            try
                _get_gurobi_env()
                return (() -> Gurobi.Optimizer(_get_gurobi_env())), :gurobi
            catch e
                @info "Gurobi not usable (e.g. no license); falling back to HiGHS" exception = e
                _HAS_GUROBI[] = false
            end
        end
        return (() -> HiGHS.Optimizer(), :highs)
    else
        throw(ArgumentError("Unknown optimizer=$optimizer. Use :auto, :gurobi, or :highs."))
    end
end

# =============================================================================
# Generic Discrete Optimization (Checker-Based)
# =============================================================================

"""
    optimize_discrete(
        checker::AbstractCapacityChecker,
        demands::AbstractVector{<:AbstractDemand},
        geometries::AbstractVector{<:AbstractMemberGeometry},
        catalog::AbstractVector{<:AbstractSection},
        material::AbstractMaterial;
        objective::AbstractObjective = MinVolume(),
        n_max_sections::Integer = 0,
        optimizer::Symbol = :auto,
        mip_gap::Real = 1e-4,
        output_flag::Integer = 0,
    )

Generic discrete section assignment using a pluggable capacity checker.

This is the material-agnostic core optimization routine. The `checker` parameter
implements the `is_feasible` interface for the specific design code.

# Arguments
- `checker`: Capacity checker implementing `is_feasible(checker, ...)` 
- `demands`: Vector of demand objects (material-specific type)
- `geometries`: Vector of geometry objects (material-specific type)
- `catalog`: Vector of sections to choose from
- `material`: Material for capacity calculations

# Keyword Arguments
- `objective`: Optimization objective (default: `MinVolume()`)
- `n_max_sections`: Max unique sections (0 = no limit)
- `optimizer`: `:auto`, `:highs`, or `:gurobi`
- `mip_gap`: MIP optimality gap tolerance
- `output_flag`: Solver verbosity (0 = silent)
- `time_limit_sec`: Maximum solver wall-clock time in seconds (default 30)

# Returns
Named tuple: `(; section_indices, sections, status, objective_value)`

# Example
```julia
checker = AISCChecker(; deflection_limit=1/360, prefer_penalty=1.05)
demands = [MemberDemand(1; Mux=100e3), MemberDemand(2; Mux=150e3)]
geometries = [SteelMemberGeometry(6.0; Lb=6.0), SteelMemberGeometry(8.0; Lb=8.0)]
result = optimize_discrete(checker, demands, geometries, all_W(), A992_Steel)
```
"""
function optimize_discrete(
    checker::AbstractCapacityChecker,
    demands::AbstractVector{<:AbstractDemand},
    geometries::AbstractVector{<:AbstractMemberGeometry},
    catalog::AbstractVector{<:AbstractSection},
    material::AbstractMaterial;
    objective::AbstractObjective = MinVolume(),
    n_max_sections::Integer = 0,
    optimizer::Symbol = :auto,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    time_limit_sec::Real = 30.0,
    cache::Union{Nothing, AbstractCapacityCache} = nothing,
)
    n_groups = length(demands)
    n_groups == length(geometries) || throw(ArgumentError("demands and geometries must have the same length"))
    n_sections = length(catalog)
    
    # Extract lengths for objective calculation
    # Strip units — JuMP can't handle Unitful quantities in expressions
    lengths = [g.L isa Length ? ustrip(u"m", g.L) : Float64(g.L) for g in geometries]
    
    # Reuse provided cache or create a fresh one
    if cache === nothing
        cache = create_cache(checker, n_sections)
        precompute_capacities!(checker, cache, catalog, material, objective)
    end
    
    # Filter feasible sections per group (each group is independent)
    feasible = Vector{Vector{Int}}(undef, n_groups)
    errors = Vector{Union{Nothing, String}}(nothing, n_groups)

    if Threads.nthreads() > 1
        Threads.@threads for i in 1:n_groups
            idxs = Int[]
            for j in 1:n_sections
                if is_feasible(checker, cache, j, catalog[j], material, demands[i], geometries[i])
                    push!(idxs, j)
                end
            end
            if isempty(idxs)
                errors[i] = get_feasibility_error_msg(checker, demands[i], geometries[i])
            end
            feasible[i] = idxs
        end
    else
        for i in 1:n_groups
            idxs = Int[]
            for j in 1:n_sections
                if is_feasible(checker, cache, j, catalog[j], material, demands[i], geometries[i])
                    push!(idxs, j)
                end
            end
            if isempty(idxs)
                errors[i] = get_feasibility_error_msg(checker, demands[i], geometries[i])
            end
            feasible[i] = idxs
        end
    end

    # Check for infeasible groups (sequential — only on error path)
    for i in 1:n_groups
        if !isnothing(errors[i])
            throw(ArgumentError("No feasible sections for group $i: $(errors[i])"))
        end
    end
    
    # Build MIP model
    opt_factory, solver = _choose_mip_optimizer(optimizer)
    m = JuMP.Model(opt_factory)
    
    if solver === :highs
        # HiGHS expects Bool for output_flag
        JuMP.set_optimizer_attribute(m, "output_flag", output_flag > 0)
        JuMP.set_optimizer_attribute(m, "mip_rel_gap", mip_gap)
        JuMP.set_optimizer_attribute(m, "time_limit", Float64(time_limit_sec))
    else
        if output_flag == 0
            JuMP.set_silent(m)
        else
            JuMP.set_optimizer_attribute(m, "OutputFlag", output_flag)
        end
        JuMP.set_optimizer_attribute(m, "MIPGap", mip_gap)
        JuMP.set_optimizer_attribute(m, "TimeLimit", Float64(time_limit_sec))
    end
    
    # Decision: x[i,j] = 1 if group i uses section j
    JuMP.@variable(m, x[i=1:n_groups, j=feasible[i]], binary=true)
    JuMP.@constraint(m, [i=1:n_groups], sum(x[i,j] for j in feasible[i]) == 1)
    
    # Optional: limit unique sections
    if n_max_sections > 0
        JuMP.@variable(m, z[j=1:n_sections], binary=true)
        JuMP.@constraint(m, [j=1:n_sections],
            sum(x[i,j] for i in 1:n_groups if j in feasible[i]) <= n_groups * z[j]
        )
        JuMP.@constraint(m, sum(z[j] for j in 1:n_sections) <= n_max_sections)
    end
    
    # Minimize objective
    JuMP.@objective(m, Min, 
        sum(sum(x[i,j] * get_objective_coeff(checker, cache, j) * lengths[i] 
                for j in feasible[i]) 
            for i in 1:n_groups))
    
    JuMP.optimize!(m)
    
    status = JuMP.termination_status(m)
    status == JuMP.MOI.OPTIMAL || status == JuMP.MOI.TIME_LIMIT ||
        @warn "MIP did not reach OPTIMAL" status
    
    # Extract solution
    section_indices = Vector{Int}(undef, n_groups)
    sections = Vector{eltype(catalog)}(undef, n_groups)
    for i in 1:n_groups
        vals = [JuMP.value(x[i, j]) for j in feasible[i]]
        bestj = feasible[i][argmax(vals)]
        section_indices[i] = bestj
        sections[i] = catalog[bestj]
    end
    
    return (; section_indices, sections, status, objective_value=JuMP.objective_value(m))
end

# =============================================================================
# Multi-Material Discrete Optimization
# =============================================================================

"""
    expand_catalog_with_materials(catalog, materials) -> (expanded_catalog, sec_indices, mat_indices)

Create an expanded catalog where each entry is a (section, material) pair.
The expanded catalog has `N_sections × M_materials` entries.

# Returns
- `expanded_catalog`: Vector of sections (repeated for each material)
- `sec_indices`: Maps expanded index k → original section index j
- `mat_indices`: Maps expanded index k → material index m
"""
function expand_catalog_with_materials(
    catalog::AbstractVector{<:AbstractSection},
    materials::AbstractVector{<:AbstractMaterial},
)
    n_sec = length(catalog)
    n_mat = length(materials)
    n_total = n_sec * n_mat

    expanded = Vector{eltype(catalog)}(undef, n_total)
    sec_idx = Vector{Int}(undef, n_total)
    mat_idx = Vector{Int}(undef, n_total)

    k = 0
    for mi in 1:n_mat, ji in 1:n_sec
        k += 1
        expanded[k] = catalog[ji]
        sec_idx[k] = ji
        mat_idx[k] = mi
    end

    return expanded, sec_idx, mat_idx
end

"""
    optimize_discrete(
        checker::AbstractCapacityChecker,
        demands::AbstractVector{<:AbstractDemand},
        geometries::AbstractVector{<:AbstractMemberGeometry},
        catalog::AbstractVector{<:AbstractSection},
        materials::AbstractVector{<:AbstractMaterial};
        kwargs...
    )

Multi-material discrete optimization. Expands the catalog into
`N_sections × M_materials` candidates, precomputes a separate capacity
cache per material, and solves a single MIP that can assign different
materials to different member groups.

# Returns
Named tuple: `(; section_indices, sections, material_indices, materials_chosen,
                 status, objective_value)`

where `section_indices` and `material_indices` index into the original
`catalog` and `materials` vectors respectively.

# Example
```julia
result = optimize_discrete(checker, demands, geometries, catalog,
                           [NWC_4000, NWC_5000, NWC_6000];
                           objective=MinCarbon())
result.materials_chosen  # Vector of materials chosen per group
```
"""
function optimize_discrete(
    checker::AbstractCapacityChecker,
    demands::AbstractVector{<:AbstractDemand},
    geometries::AbstractVector{<:AbstractMemberGeometry},
    catalog::AbstractVector{<:AbstractSection},
    materials::AbstractVector{<:AbstractMaterial};
    objective::AbstractObjective = MinVolume(),
    n_max_sections::Integer = 0,
    optimizer::Symbol = :auto,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    time_limit_sec::Real = 30.0,
)
    n_groups = length(demands)
    n_groups == length(geometries) || throw(ArgumentError("demands and geometries must have the same length"))
    n_sec = length(catalog)
    n_mat = length(materials)

    # Expand catalog: k = (m-1)*n_sec + j
    expanded, sec_idx_map, mat_idx_map = expand_catalog_with_materials(catalog, materials)
    n_total = length(expanded)

    # Extract lengths for objective calculation
    lengths = [g.L isa Length ? ustrip(u"m", g.L) : Float64(g.L) for g in geometries]

    # Precompute one cache per material
    caches = Vector{AbstractCapacityCache}(undef, n_mat)
    for mi in 1:n_mat
        caches[mi] = create_cache(checker, n_sec)
        precompute_capacities!(checker, caches[mi], catalog, materials[mi], objective)
    end

    # Filter feasible expanded candidates per group
    feasible = Vector{Vector{Int}}(undef, n_groups)
    errors = Vector{Union{Nothing, String}}(nothing, n_groups)

    for i in 1:n_groups
        idxs = Int[]
        for k in 1:n_total
            j = sec_idx_map[k]
            mi = mat_idx_map[k]
            if is_feasible(checker, caches[mi], j, catalog[j], materials[mi], demands[i], geometries[i])
                push!(idxs, k)
            end
        end
        if isempty(idxs)
            errors[i] = get_feasibility_error_msg(checker, demands[i], geometries[i])
        end
        feasible[i] = idxs
    end

    # Check for infeasible groups
    for i in 1:n_groups
        if !isnothing(errors[i])
            throw(ArgumentError("No feasible sections for group $i (multi-material): $(errors[i])"))
        end
    end

    # Build MIP model
    opt_factory, solver = _choose_mip_optimizer(optimizer)
    m = JuMP.Model(opt_factory)

    if solver === :highs
        JuMP.set_optimizer_attribute(m, "output_flag", output_flag > 0)
        JuMP.set_optimizer_attribute(m, "mip_rel_gap", mip_gap)
        JuMP.set_optimizer_attribute(m, "time_limit", Float64(time_limit_sec))
    else
        if output_flag == 0
            JuMP.set_silent(m)
        else
            JuMP.set_optimizer_attribute(m, "OutputFlag", output_flag)
        end
        JuMP.set_optimizer_attribute(m, "MIPGap", mip_gap)
        JuMP.set_optimizer_attribute(m, "TimeLimit", Float64(time_limit_sec))
    end

    # Decision: x[i,k] = 1 if group i uses expanded candidate k
    JuMP.@variable(m, x[i=1:n_groups, k=feasible[i]], binary=true)
    JuMP.@constraint(m, [i=1:n_groups], sum(x[i,k] for k in feasible[i]) == 1)

    # Optional: limit unique (section, material) pairs
    if n_max_sections > 0
        JuMP.@variable(m, z[k=1:n_total], binary=true)
        JuMP.@constraint(m, [k=1:n_total],
            sum(x[i,k] for i in 1:n_groups if k in feasible[i]) <= n_groups * z[k]
        )
        JuMP.@constraint(m, sum(z[k] for k in 1:n_total) <= n_max_sections)
    end

    # Objective: use the cache for the material associated with each expanded index
    JuMP.@objective(m, Min,
        sum(sum(x[i,k] * get_objective_coeff(checker, caches[mat_idx_map[k]], sec_idx_map[k]) * lengths[i]
                for k in feasible[i])
            for i in 1:n_groups))

    JuMP.optimize!(m)

    status = JuMP.termination_status(m)
    status == JuMP.MOI.OPTIMAL || status == JuMP.MOI.TIME_LIMIT ||
        @warn "Multi-material MIP did not reach OPTIMAL" status

    # Extract solution
    section_indices = Vector{Int}(undef, n_groups)
    material_indices = Vector{Int}(undef, n_groups)
    sections = Vector{eltype(catalog)}(undef, n_groups)
    materials_chosen = Vector{eltype(materials)}(undef, n_groups)

    for i in 1:n_groups
        vals = [JuMP.value(x[i, k]) for k in feasible[i]]
        bestk = feasible[i][argmax(vals)]
        j = sec_idx_map[bestk]
        mi = mat_idx_map[bestk]
        section_indices[i] = j
        material_indices[i] = mi
        sections[i] = catalog[j]
        materials_chosen[i] = materials[mi]
    end

    return (; section_indices, sections, material_indices, materials_chosen,
              status, objective_value=JuMP.objective_value(m))
end