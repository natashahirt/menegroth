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
)
    if solver === :grid
        return _optimize_grid(problem, objective; n_grid, n_refine, verbose)
    elseif solver === :ipopt
        return _optimize_ipopt(problem, objective; maxiter, tol, verbose)
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
"""
function _numeric_gradient(f, x::Vector{Float64}; ε::Float64=1e-6)
    n = length(x)
    grad = zeros(n)
    for i in 1:n
        x_plus = copy(x); x_plus[i] += ε
        x_minus = copy(x); x_minus[i] -= ε
        grad[i] = (f(x_plus) - f(x_minus)) / (2ε)
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
                         maxiter::Int, tol::Float64, verbose::Bool)
    
    # Get problem dimensions
    n_vars = n_variables(problem)
    lb, ub = variable_bounds(problem)
    x0 = initial_guess(problem)
    nc = n_constraints(problem)
    
    # Build JuMP model
    model = JuMP.Model(Ipopt.Optimizer)
    
    # Set Ipopt options
    JuMP.set_optimizer_attribute(model, "max_iter", maxiter)
    JuMP.set_optimizer_attribute(model, "tol", tol)
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

"""
NLopt solver via Optimization.jl.

Requires: `using Optimization, OptimizationNLopt`
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
NonConvex.jl meta-solver with autodiff support.

Requires: `using NonConvex, Ipopt` (or other backend)
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
Convert volume-based objective to requested objective type.

`evaluate()` returns volume as the base objective. For MinWeight/MinCarbon,
we scale by density/ECC rather than recomputing arc length.
"""
function _convert_objective(objective::MinVolume, ::AbstractNLPProblem, volume::Float64)
    volume
end

function _convert_objective(objective::MinWeight, problem::AbstractNLPProblem, volume::Float64)
    density = ustrip(u"kg/m^3", problem.material.ρ)
    volume * density
end

function _convert_objective(objective::MinCarbon, problem::AbstractNLPProblem, volume::Float64)
    density = ustrip(u"kg/m^3", problem.material.ρ)
    ecc = problem.material.ecc
    volume * density * ecc
end

function _convert_objective(objective::MinCost, problem::AbstractNLPProblem, volume::Float64)
    # Use material cost if available, otherwise estimate
    cost_per_m3 = hasproperty(problem.material, :cost) ? problem.material.cost : 150.0
    volume * cost_per_m3
end

# Fallback for custom objectives (will recompute - less efficient)
function _convert_objective(objective::AbstractObjective, problem::AbstractNLPProblem, volume::Float64, x::Vector{Float64})
    objective_value(objective, problem, x)
end

# ==============================================================================
# Grid Search Functions
# ==============================================================================

"""1D grid search."""
function _search_1d(problem, objective, lb, ub, n_points)
    best_x = [lb]
    best_obj = Inf
    best_result = nothing
    best_feasible = false
    
    for x1 in range(lb, ub, length=n_points)
        x = [x1]
        feasible, volume, result = evaluate(problem, x)
        
        # Convert volume → requested objective without recomputing
        obj = feasible ? _convert_objective(objective, problem, volume) : Inf
        
        if feasible && obj < best_obj
            best_x = x
            best_obj = obj
            best_result = result
            best_feasible = true
        end
    end
    
    return best_x, best_obj, best_result, best_feasible, n_points
end

"""2D grid search."""
function _search_2d(problem, objective, lb, ub, n_points)
    best_x = [lb[1], lb[2]]
    best_obj = Inf
    best_result = nothing
    best_feasible = false
    evals = 0
    
    for x1 in range(lb[1], ub[1], length=n_points)
        for x2 in range(lb[2], ub[2], length=n_points)
            x = [x1, x2]
            feasible, volume, result = evaluate(problem, x)
            evals += 1
            
            # Convert volume → requested objective without recomputing
            obj = feasible ? _convert_objective(objective, problem, volume) : Inf
            
            if feasible && obj < best_obj
                best_x = x
                best_obj = obj
                best_result = result
                best_feasible = true
            end
        end
    end
    
    return best_x, best_obj, best_result, best_feasible, evals
end
