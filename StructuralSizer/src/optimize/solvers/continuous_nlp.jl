# ==============================================================================
# Continuous (NLP) Optimization Solver
# ==============================================================================
# Generic solver for continuous optimization problems.
# 
# Backends:
# - :grid      — Grid search with refinement (no additional dependencies)
# - :ipopt     — Ipopt via JuMP (requires Ipopt.jl)
# - :nlopt     — NLopt algorithms (requires NLopt.jl)
# - :nonconvex — NonConvex.jl meta-solver (requires NonConvex.jl)
#
# The gradient-based backends (:ipopt, :nlopt, :nonconvex) use the enhanced
# interface: objective_fn(), constraint_fns(), constraint_bounds().

import JuMP

"""
    optimize_continuous(
        problem::AbstractNLPProblem;
        objective::AbstractObjective = MinVolume(),
        solver::Symbol = :grid,
        kwargs...
    )

Solve a continuous optimization problem.

# Arguments
- `problem`: Problem implementing AbstractNLPProblem interface
- `objective`: Optimization objective (MinVolume, MinWeight, MinCarbon, MinCost)
- `solver`: Solver backend:
  - `:grid` — Grid search with refinement (default, no deps)
  - `:ipopt` — Interior point optimizer (requires Ipopt.jl)
  - `:nlopt` — NLopt algorithms (requires OptimizationNLopt.jl)
  - `:nonconvex` — NonConvex.jl meta-solver

# Solver-Specific Options
## Grid solver (:grid)
- `n_grid::Int = 20` — Initial grid points per dimension
- `n_refine::Int = 2` — Number of refinement iterations

## Gradient-based solvers (:ipopt, :nlopt, :nonconvex)
- `maxiter::Int = 1000` — Maximum iterations
- `tol::Float64 = 1e-6` — Convergence tolerance

# Common Options
- `verbose::Bool = false` — Print progress information

# Returns
Named tuple with:
- `minimizer`: Optimal point [x1, x2, ...]
- `objective_value`: Optimal objective value
- `eval_result`: Raw evaluation result (for building domain result)
- `constraints`: Constraint values at optimum (if any)
- `status`: :optimal, :feasible, :infeasible, :failed
- `iterations`: Total function/iteration count

# Example
```julia
problem = VaultNLPProblem(...)
result = optimize_continuous(problem; objective=MinVolume())
h_opt, t_opt = result.minimizer

# With Ipopt (when available)
result = optimize_continuous(problem; solver=:ipopt, verbose=true)
```
"""
function optimize_continuous(
    problem::AbstractNLPProblem;
    objective::AbstractObjective = MinVolume(),
    solver::Symbol = :grid,
    n_grid::Int = 20,
    n_refine::Int = 2,
    maxiter::Int = 1000,
    tol::Float64 = 1e-6,
    verbose::Bool = false,
    x0::Union{Nothing,Vector{Float64}} = nothing,
    n_multistart::Int = 1,
)
    if solver === :grid
        return _optimize_grid(problem, objective; n_grid, n_refine, verbose)
    elseif solver === :ipopt
        if n_multistart > 1
            return _multistart_ipopt(problem, objective;
                maxiter, tol, verbose, x0, n_starts=n_multistart)
        else
            return _optimize_ipopt(problem, objective; maxiter, tol, verbose, x0)
        end
    elseif solver === :nlopt
        return _optimize_nlopt(problem, objective; maxiter, tol, verbose)
    elseif solver === :nonconvex
        return _optimize_nonconvex(problem, objective; maxiter, tol, verbose)
    else
        throw(ArgumentError("Unknown solver=$solver. Use :grid, :ipopt, :nlopt, or :nonconvex."))
    end
end

# ==============================================================================
# Ipopt Solver via JuMP
# ==============================================================================

import Ipopt

"""
    _numeric_gradient(f, x; ε=1e-6) -> Vector

Compute numerical gradient using central differences.

!!! warning
    Mutates `x` in-place during computation (restores original values before returning).
    Not safe for concurrent reads of `x` or closures that capture `x` by reference.
"""
function _numeric_gradient(f, x::Vector{Float64}; ε::Float64=1e-6)
    n = length(x)
    grad = zeros(n)
    @inbounds for i in 1:n
        xi_orig = x[i]
        x[i] = xi_orig + ε
        fp = f(x)
        x[i] = xi_orig - ε
        fm = f(x)
        grad[i] = (fp - fm) / (2ε)
        x[i] = xi_orig
    end
    return grad
end

"""
    _optimize_ipopt(problem, objective; maxiter, tol, verbose)

Ipopt solver via JuMP for nonlinear constrained optimization.

Uses numerical derivatives since our constraint functions involve
iterative solvers (elastic shortening) that aren't AD-compatible.
"""
function _optimize_ipopt(problem::AbstractNLPProblem, objective::AbstractObjective; 
                         maxiter::Int, tol::Float64, verbose::Bool,
                         x0::Union{Nothing,Vector{Float64}} = nothing)
    
    # Get problem dimensions
    n_vars = n_variables(problem)
    lb, ub = variable_bounds(problem)
    x0 = isnothing(x0) ? initial_guess(problem) : copy(x0)
    # Clamp x0 to variable bounds (e.g. MIP warm-start may exceed NLP bounds)
    for i in 1:n_vars
        x0[i] = clamp(x0[i], lb[i], ub[i])
    end
    nc = n_constraints(problem)
    
    # Build JuMP model
    model = JuMP.Model(Ipopt.Optimizer)
    
    # Set Ipopt options
    JuMP.set_optimizer_attribute(model, "max_iter", maxiter)
    JuMP.set_optimizer_attribute(model, "tol", tol)
    JuMP.set_optimizer_attribute(model, "acceptable_tol", tol * 100)  # Accept relaxed KKT for non-smooth constraints
    JuMP.set_optimizer_attribute(model, "acceptable_iter", 5)         # Accept after 5 acceptable iterations
    JuMP.set_optimizer_attribute(model, "print_level", verbose ? 5 : 0)
    
    # Decision variables with bounds
    JuMP.@variable(model, lb[i] <= x[i=1:n_vars] <= ub[i], start = x0[i])
    
    # Objective function (Float64 vector input)
    _obj_f(xv::Vector{Float64}) = objective_fn(problem, xv)
    
    # Register objective operator - different signatures for 1D vs nD
    obj_op = if n_vars == 1
        # Univariate: f(x) -> y, ∇f(x) -> dy/dx
        _obj_1d(x::Float64) = _obj_f([x])
        _obj_grad_1d(x::Float64) = _numeric_gradient(_obj_f, [x])[1]
        JuMP.add_nonlinear_operator(model, 1, _obj_1d, _obj_grad_1d; name = :obj_fn)
    else
        # Multivariate: f(x...) -> y, ∇f!(g, x...)
        function _obj_grad!(g::AbstractVector{T}, xv...) where {T}
            x_vec = collect(Float64, xv)
            grad = _numeric_gradient(_obj_f, x_vec)
            for i in eachindex(g)
                g[i] = grad[i]
            end
            return
        end
        JuMP.add_nonlinear_operator(
            model, n_vars, (xv...) -> _obj_f(collect(Float64, xv)), _obj_grad!;
            name = :obj_fn
        )
    end
    
    # Set objective (minimize)
    JuMP.@objective(model, Min, obj_op(x...))
    
    # Register and add constraint functions
    if nc > 0
        c_lb, c_ub = constraint_bounds(problem)
        
        for j in 1:nc
            # Constraint j function (Float64 vector input)
            _con_f(xv::Vector{Float64}) = constraint_fns(problem, xv)[j]
            
            # Register constraint operator - different signatures for 1D vs nD
            con_op = if n_vars == 1
                # Univariate
                _con_1d(x::Float64) = _con_f([x])
                _con_grad_1d(x::Float64) = _numeric_gradient(_con_f, [x])[1]
                JuMP.add_nonlinear_operator(model, 1, _con_1d, _con_grad_1d; name = Symbol("con_$j"))
            else
                # Multivariate
                function _con_grad!(g::AbstractVector{T}, xv...) where {T}
                    x_vec = collect(Float64, xv)
                    grad = _numeric_gradient(_con_f, x_vec)
                    for i in eachindex(g)
                        g[i] = grad[i]
                    end
                    return
                end
                JuMP.add_nonlinear_operator(
                    model, n_vars, (xv...) -> _con_f(collect(Float64, xv)), _con_grad!;
                    name = Symbol("con_$j")
                )
            end
            
            # Add constraint with bounds using modern JuMP API
            if c_lb[j] == -Inf
                JuMP.@constraint(model, con_op(x...) <= c_ub[j])
            elseif c_ub[j] == Inf
                JuMP.@constraint(model, con_op(x...) >= c_lb[j])
            else
                JuMP.@constraint(model, c_lb[j] <= con_op(x...) <= c_ub[j])
            end
        end
    end
    
    # Solve
    JuMP.optimize!(model)
    
    # Extract solution
    term_status = JuMP.termination_status(model)
    minimizer = [JuMP.value(x[i]) for i in 1:n_vars]
    obj_val = JuMP.objective_value(model)
    
    # Map termination status
    status = if term_status == JuMP.MOI.LOCALLY_SOLVED || term_status == JuMP.MOI.OPTIMAL
        :optimal
    elseif term_status == JuMP.MOI.ALMOST_LOCALLY_SOLVED || term_status == JuMP.MOI.ALMOST_OPTIMAL
        :feasible   # KKT satisfied to relaxed tolerance (common with piecewise-linear P-M constraints)
    elseif term_status == JuMP.MOI.ITERATION_LIMIT || term_status == JuMP.MOI.SLOW_PROGRESS
        :converged  # Solver stalled or hit iteration cap; solution is typically near-feasible
    elseif term_status == JuMP.MOI.LOCALLY_INFEASIBLE || term_status == JuMP.MOI.INFEASIBLE
        :infeasible
    else
        :failed
    end
    
    if verbose
        @info "Ipopt finished" termination_status=term_status objective=obj_val
    end
    
    # Get eval_result for build_result
    _, _, eval_result = evaluate(problem, minimizer)
    
    # Get constraint values
    constraints = nc > 0 ? constraint_fns(problem, minimizer) : Float64[]
    
    return (
        minimizer = minimizer,
        objective_value = obj_val,
        eval_result = eval_result,
        constraints = constraints,
        status = status,
        iterations = -1,  # Ipopt doesn't easily expose this
    )
end

# ==============================================================================
# Multi-start Ipopt: run from multiple starting points, pick best feasible
# ==============================================================================

"""
    _multistart_ipopt(problem, objective; maxiter, tol, verbose, x0, n_starts)

Run Ipopt from multiple starting points and return the best feasible result.
Starting points: provided x0, lower-bound corner, midpoint, and random samples.
This helps avoid local minima in non-smooth problems (e.g. RC P-M interaction).
"""
function _multistart_ipopt(problem::AbstractNLPProblem, objective::AbstractObjective;
                           maxiter::Int, tol::Float64, verbose::Bool,
                           x0::Union{Nothing,Vector{Float64}} = nothing,
                           n_starts::Int = 3)
    n_vars = n_variables(problem)
    lb, ub = variable_bounds(problem)
    nc = n_constraints(problem)
    c_lb, c_ub = nc > 0 ? constraint_bounds(problem) : (Float64[], Float64[])

    # Generate diverse starting points
    starts = Vector{Float64}[]

    # Start 1: provided x0 or default initial guess
    s1 = isnothing(x0) ? initial_guess(problem) : copy(x0)
    for i in 1:n_vars; s1[i] = clamp(s1[i], lb[i], ub[i]) end
    push!(starts, s1)

    # Start 2: lower-bound corner (smallest section — often optimal for min-area)
    push!(starts, copy(lb))

    # Start 3: upper-bound corner (largest section — guaranteed feasible if any is)
    push!(starts, copy(ub))

    # Start 4: midpoint of bounds
    if n_starts >= 4
        push!(starts, (lb .+ ub) ./ 2)
    end

    # Additional random starts within bounds
    for k in (length(starts)+1):n_starts
        push!(starts, lb .+ rand(n_vars) .* (ub .- lb))
    end

    # Helper: check if constraints are satisfied
    function _is_feasible(result)
        result.status in (:optimal, :feasible) || return false
        nc == 0 && return true
        cvals = result.constraints
        for j in 1:nc
            if cvals[j] > c_ub[j] + 1e-4
                return false
            end
            if c_lb[j] > -Inf && cvals[j] < c_lb[j] - 1e-4
                return false
            end
        end
        return true
    end

    # Run starts in parallel — each Ipopt call creates its own JuMP.Model
    n_st = length(starts)
    results_vec = Vector{Any}(nothing, n_st)

    if Threads.nthreads() > 1
        tasks = map(1:n_st) do k
            Threads.@spawn _optimize_ipopt(problem, objective; maxiter, tol, verbose=false, x0=starts[k])
        end
        for (k, t) in enumerate(tasks)
            results_vec[k] = fetch(t)
        end
    else
        for k in 1:n_st
            results_vec[k] = _optimize_ipopt(problem, objective; maxiter, tol, verbose=false, x0=starts[k])
        end
    end

    # Sequential reduction: pick the best feasible result
    best_result = nothing
    best_obj = Inf
    for r in results_vec
        r === nothing && continue
        if _is_feasible(r) && r.objective_value < best_obj
            best_result = r
            best_obj = r.objective_value
        end
    end

    # If no feasible solution found from any start, fall back to x0 result
    if isnothing(best_result)
        if verbose
            @warn "Multi-start: no feasible solution from $n_starts starts, using x0 fallback"
        end
        best_result = _optimize_ipopt(problem, objective; maxiter, tol, verbose, x0)
    elseif verbose
        @info "Multi-start: best objective $best_obj from $n_starts starts"
    end

    return best_result
end

"""
    _optimize_nlopt(problem, objective; maxiter, tol, verbose)

NLopt solver via Optimization.jl (not yet implemented).
Requires: `using Optimization, OptimizationNLopt`.
"""
function _optimize_nlopt(problem, objective; maxiter, tol, verbose)
    error("""
    NLopt solver not yet available.
    
    To use NLopt, add to your environment:
        using Pkg; Pkg.add(["Optimization", "OptimizationNLopt"])
    
    Then this backend will be implemented.
    For now, use solver=:grid.
    """)
end

"""
    _optimize_nonconvex(problem, objective; maxiter, tol, verbose)

NonConvex.jl meta-solver with autodiff support (not yet implemented).
Requires: `using NonConvex, Ipopt`.
"""
function _optimize_nonconvex(problem, objective; maxiter, tol, verbose)
    error("""
    NonConvex.jl solver not yet available.
    
    To use NonConvex, add to your environment:
        using Pkg; Pkg.add(["NonConvex", "Ipopt"])
    
    Then this backend will be implemented.
    For now, use solver=:grid.
    """)
end

# ==============================================================================
# Grid-Based Solver (No Additional Dependencies)
# ==============================================================================

"""
    _optimize_grid(problem, objective; n_grid, n_refine, verbose)

Grid search with successive refinement.

Algorithm:
1. Evaluate on coarse grid
2. Find best feasible point
3. Zoom into region around best point
4. Repeat refinement

This is robust for smooth, low-dimensional problems (2-3 variables).
"""
function _optimize_grid(
    problem::AbstractNLPProblem,
    objective::AbstractObjective;
    n_grid::Int = 20,
    n_refine::Int = 2,
    verbose::Bool = false,
)
    lb, ub = variable_bounds(problem)
    n_vars = n_variables(problem)
    
    if n_vars > 3
        @warn "Grid search is slow for >3 variables. Consider NonConvex.jl."
    end
    
    # Track best solution
    best_x = initial_guess(problem)
    best_obj = Inf
    best_result = nothing
    best_feasible = false
    total_evals = 0
    
    # Current search bounds (start with full bounds)
    current_lb = copy(lb)
    current_ub = copy(ub)
    
    for iter in 0:n_refine
        grid_size = iter == 0 ? n_grid : max(5, n_grid ÷ 2)
        
        if verbose
            @info "Grid search iteration $iter" bounds=(current_lb, current_ub) grid_size
        end
        
        # Generate grid points
        if n_vars == 1
            best_x, best_obj, best_result, best_feasible, evals = _search_1d(
                problem, objective, current_lb[1], current_ub[1], grid_size
            )
            total_evals += evals
        elseif n_vars == 2
            x, obj, res, feas, evals = _search_2d(
                problem, objective, current_lb, current_ub, grid_size
            )
            total_evals += evals
            if feas && obj < best_obj
                best_x, best_obj, best_result, best_feasible = x, obj, res, feas
            elseif !best_feasible && feas
                best_x, best_obj, best_result, best_feasible = x, obj, res, feas
            end
        else
            error("Grid search for $n_vars variables not yet implemented.")
        end
        
        if verbose && best_feasible
            names = variable_names(problem)
            @info "  Best so far" x=best_x objective=round(best_obj, digits=6)
        end
        
        # Zoom in for next iteration
        if best_feasible && iter < n_refine
            range_scale = 0.3  # Zoom to 30% of current range
            for i in 1:n_vars
                range_i = current_ub[i] - current_lb[i]
                center_i = best_x[i]
                half_new = range_i * range_scale / 2
                current_lb[i] = max(lb[i], center_i - half_new)
                current_ub[i] = min(ub[i], center_i + half_new)
            end
        end
    end
    
    # Determine status and get constraint info
    status = if best_feasible
        :optimal
    else
        :infeasible
    end
    
    # Get constraint values at best point (for diagnostics)
    constraints = if n_constraints(problem) > 0
        constraint_fns(problem, best_x)
    else
        Float64[]
    end
    
    if !best_feasible
        @warn "No feasible solution found in search space"
        if verbose && n_constraints(problem) > 0
            c_names = constraint_names(problem)
            c_lb, c_ub = constraint_bounds(problem)
            @info "Constraint violations at best point:"
            for (i, g) in enumerate(constraints)
                violated = g < c_lb[i] || g > c_ub[i]
                status_str = violated ? "VIOLATED" : "ok"
                @info "  $(c_names[i]): g=$g (bounds: [$(c_lb[i]), $(c_ub[i])]) $status_str"
            end
        end
    end
    
    return (
        minimizer = best_x,
        objective_value = best_obj,
        eval_result = best_result,
        constraints = constraints,
        status = status,
        iterations = total_evals,
    )
end

# ==============================================================================
# Objective Conversion (avoid recomputing expensive analysis)
# ==============================================================================

"""
    _convert_objective(objective, problem, volume) -> Float64

Convert a volume-based base objective to the requested objective type by
scaling with density, ECC, or cost. Avoids recomputing expensive analyses.
"""
function _convert_objective(objective::MinVolume, ::AbstractNLPProblem, volume::Float64)
    volume
end

"""_convert_objective for MinWeight: volume × ρ."""
function _convert_objective(objective::MinWeight, problem::AbstractNLPProblem, volume::Float64)
    density = ustrip(u"kg/m^3", problem.material.ρ)
    volume * density
end

"""_convert_objective for MinCarbon: volume × ρ × ecc."""
function _convert_objective(objective::MinCarbon, problem::AbstractNLPProblem, volume::Float64)
    density = ustrip(u"kg/m^3", problem.material.ρ)
    ecc = problem.material.ecc
    volume * density * ecc
end

"""_convert_objective for MinCost: volume × ρ × cost."""
function _convert_objective(objective::MinCost, problem::AbstractNLPProblem, volume::Float64)
    isnan(problem.material.cost) && error("MinCost requires material.cost to be set (material has cost=NaN)")
    density = ustrip(u"kg/m^3", problem.material.ρ)
    volume * density * problem.material.cost
end

"""_convert_objective fallback: recomputes via `objective_value` (less efficient)."""
function _convert_objective(objective::AbstractObjective, problem::AbstractNLPProblem, volume::Float64, x::Vector{Float64})
    objective_value(objective, problem, x)
end

# ==============================================================================
# Grid Search Functions
# ==============================================================================

"""
    _search_1d(problem, objective, lb, ub, n_points) -> (best_x, best_obj, best_result, feasible, evals)

One-dimensional grid search, parallelized over grid points.
"""
function _search_1d(problem, objective, lb, ub, n_points)
    grid = collect(range(lb, ub, length=n_points))
    n = length(grid)

    local_feasible = Vector{Bool}(undef, n)
    local_obj = fill(Inf, n)
    local_result = Vector{Any}(undef, n)
    local_x = Vector{Vector{Float64}}(undef, n)

    Threads.@threads for k in 1:n
        x = [grid[k]]
        feasible, volume, result = evaluate(problem, x)
        local_feasible[k] = feasible
        local_obj[k] = feasible ? _convert_objective(objective, problem, volume) : Inf
        local_result[k] = result
        local_x[k] = x
    end

    best_x = [lb]
    best_obj = Inf
    best_result = nothing
    best_feasible = false

    for k in 1:n
        if local_feasible[k] && local_obj[k] < best_obj
            best_x = local_x[k]
            best_obj = local_obj[k]
            best_result = local_result[k]
            best_feasible = true
        end
    end

    return best_x, best_obj, best_result, best_feasible, n
end

"""
    _search_2d(problem, objective, lb, ub, n_points) -> (best_x, best_obj, best_result, feasible, evals)

Two-dimensional grid search, parallelized over grid points.
"""
function _search_2d(problem, objective, lb, ub, n_points)
    grid_x1 = collect(range(lb[1], ub[1], length=n_points))
    grid_x2 = collect(range(lb[2], ub[2], length=n_points))
    n_total = n_points * n_points

    local_feasible = Vector{Bool}(undef, n_total)
    local_obj = fill(Inf, n_total)
    local_result = Vector{Any}(undef, n_total)
    local_x = Vector{Vector{Float64}}(undef, n_total)

    Threads.@threads for k in 1:n_total
        i = div(k - 1, n_points) + 1
        j = mod(k - 1, n_points) + 1
        x = [grid_x1[i], grid_x2[j]]
        feasible, volume, result = evaluate(problem, x)
        local_feasible[k] = feasible
        local_obj[k] = feasible ? _convert_objective(objective, problem, volume) : Inf
        local_result[k] = result
        local_x[k] = x
    end

    best_x = [lb[1], lb[2]]
    best_obj = Inf
    best_result = nothing
    best_feasible = false

    for k in 1:n_total
        if local_feasible[k] && local_obj[k] < best_obj
            best_x = local_x[k]
            best_obj = local_obj[k]
            best_result = local_result[k]
            best_feasible = true
        end
    end

    return best_x, best_obj, best_result, best_feasible, n_total
end
