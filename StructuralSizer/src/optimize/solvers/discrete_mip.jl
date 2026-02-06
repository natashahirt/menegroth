import JuMP
import HiGHS

# Optional Gurobi import (accelerator). Keep HiGHS as the baseline open-source solver.
const _HAS_GUROBI = Ref(false)
try
    import Gurobi
    _HAS_GUROBI[] = true
catch
    _HAS_GUROBI[] = false
end

# Cache a single Gurobi environment to avoid repeated license checks
const _GUROBI_ENV = Ref{Any}(nothing)

"""
    _get_gurobi_env()

Get or create a cached Gurobi environment. This avoids repeated license
checks when creating multiple models.
"""
function _get_gurobi_env()
    if _GUROBI_ENV[] === nothing
        _GUROBI_ENV[] = Gurobi.Env()
    end
    return _GUROBI_ENV[]
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
        return _HAS_GUROBI[] ? (() -> Gurobi.Optimizer(_get_gurobi_env()), :gurobi) : (() -> HiGHS.Optimizer(), :highs)
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
        catalogue::AbstractVector{<:AbstractSection},
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
- `catalogue`: Vector of sections to choose from
- `material`: Material for capacity calculations

# Keyword Arguments
- `objective`: Optimization objective (default: `MinVolume()`)
- `n_max_sections`: Max unique sections (0 = no limit)
- `optimizer`: `:auto`, `:highs`, or `:gurobi`
- `mip_gap`: MIP optimality gap tolerance
- `output_flag`: Solver verbosity (0 = silent)

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
    catalogue::AbstractVector{<:AbstractSection},
    material::AbstractMaterial;
    objective::AbstractObjective = MinVolume(),
    n_max_sections::Integer = 0,
    optimizer::Symbol = :auto,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
)
    n_groups = length(demands)
    n_groups == length(geometries) || throw(ArgumentError("demands and geometries must have the same length"))
    n_sections = length(catalogue)
    
    # Extract lengths for objective calculation
    lengths = [g.L for g in geometries]
    
    # Initialize capacity cache (checker creates its own type)
    cache = create_cache(checker, n_sections)
    precompute_capacities!(checker, cache, catalogue, material, objective)
    
    # Filter feasible sections per group
    feasible = Dict{Int, Vector{Int}}()
    for i in 1:n_groups
        idxs = Int[]
        for j in 1:n_sections
            if is_feasible(checker, cache, j, catalogue[j], material, demands[i], geometries[i])
                push!(idxs, j)
            end
        end
        
        if isempty(idxs)
            msg = get_feasibility_error_msg(checker, demands[i], geometries[i])
            throw(ArgumentError("No feasible sections for group $i: $msg"))
        end
        feasible[i] = idxs
    end
    
    # Build MIP model
    opt_factory, solver = _choose_mip_optimizer(optimizer)
    m = JuMP.Model(opt_factory)
    
    if solver === :highs
        # HiGHS expects Bool for output_flag
        JuMP.set_optimizer_attribute(m, "output_flag", output_flag > 0)
        JuMP.set_optimizer_attribute(m, "mip_rel_gap", mip_gap)
    else
        JuMP.set_optimizer_attribute(m, "OutputFlag", output_flag)
        JuMP.set_optimizer_attribute(m, "MIPGap", mip_gap)
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
    sections = Vector{eltype(catalogue)}(undef, n_groups)
    for i in 1:n_groups
        vals = [JuMP.value(x[i, j]) for j in feasible[i]]
        bestj = feasible[i][argmax(vals)]
        section_indices[i] = bestj
        sections[i] = catalogue[bestj]
    end
    
    return (; section_indices, sections, status, objective_value=JuMP.objective_value(m))
end
