# ==============================================================================
# Floor Optimization API
# ==============================================================================
# High-level API for floor system optimization.
# Parallel to members/optimize/api.jl for columns.

# ==============================================================================
# Solver Trace Contracts (manual registry; this file uses docstrings)
# ==============================================================================
#
# Note: documented functions can't use @traced due to Julia doc macro conflicts.
#

TRACE_REGISTRY[(:optimize_vault, :optimizer)] =
    TracedFunctionMeta(:optimize_vault, :optimizer,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)

TRACE_REGISTRY[(:size_flat_plate_optimized, :slab)] =
    TracedFunctionMeta(:size_flat_plate_optimized, :slab,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)

# ==============================================================================
# Optimization Mode Detection
# ==============================================================================

"""
    VaultOptMode

Represents the optimization mode based on which parameters are provided.
"""
abstract type VaultOptMode end

"""Optimize both rise and thickness."""
struct OptBoth <: VaultOptMode
    rise_bounds::Tuple{Float64, Float64}
    thickness_bounds::Tuple{Float64, Float64}
end

"""Optimize rise only (thickness fixed)."""
struct OptRise <: VaultOptMode
    rise_bounds::Tuple{Float64, Float64}
    fixed_thickness::Float64
end

"""Optimize thickness only (rise fixed)."""
struct OptThickness <: VaultOptMode
    fixed_rise::Float64
    thickness_bounds::Tuple{Float64, Float64}
end

"""Return the optimization mode symbol (`:both`, `:rise_only`, `:thickness_only`)."""
_mode_symbol(::OptBoth) = :both
_mode_symbol(::OptRise) = :rise_only
_mode_symbol(::OptThickness) = :thickness_only

"""Return the effective rise bounds (m) for the mode; degenerate for fixed-rise modes."""
_rise_bounds(m::OptBoth) = m.rise_bounds
_rise_bounds(m::OptRise) = m.rise_bounds
_rise_bounds(m::OptThickness) = (m.fixed_rise, m.fixed_rise)

"""Return the effective thickness bounds (m) for the mode; degenerate for fixed-thickness modes."""
_thickness_bounds(m::OptBoth) = m.thickness_bounds
_thickness_bounds(m::OptRise) = (m.fixed_thickness, m.fixed_thickness)
_thickness_bounds(m::OptThickness) = m.thickness_bounds

"""Human-readable description of the optimization mode."""
_mode_description(::OptBoth) = "rise + thickness"
_mode_description(::OptRise) = "rise (thickness fixed)"
_mode_description(::OptThickness) = "thickness (rise fixed)"

"""Extract (rise, thickness) from minimizer vector, filling in fixed values as needed."""
_extract_result(::OptBoth, minimizer) = (minimizer[1], minimizer[2])
_extract_result(m::OptRise, minimizer) = (minimizer[1], m.fixed_thickness)
_extract_result(m::OptThickness, minimizer) = (m.fixed_rise, minimizer[1])

# ==============================================================================
# Rise Resolution (lambda ↔ rise conversion)
# ==============================================================================

"""
Resolve rise specification to (rise_bounds, fixed_rise) in meters.

Accepts lambda_bounds, rise_bounds, lambda, or rise.
Validates mutual exclusivity.
Returns (effective_rise_bounds, effective_fixed_rise) where one is nothing.
"""
function _resolve_rise(
    span::Length;
    lambda_bounds::Union{Tuple{Real, Real}, Nothing},
    rise_bounds::Union{Tuple{<:Length, <:Length}, Nothing},
    lambda::Union{Real, Nothing},
    rise::Union{Length, Nothing},
)
    # Count how many rise specifications are provided
    specs = filter(!isnothing, [lambda_bounds, rise_bounds, lambda, rise])
    
    if length(specs) > 1
        provided = String[]
        !isnothing(lambda_bounds) && push!(provided, "lambda_bounds")
        !isnothing(rise_bounds) && push!(provided, "rise_bounds")
        !isnothing(lambda) && push!(provided, "lambda")
        !isnothing(rise) && push!(provided, "rise")
        throw(ArgumentError(
            "Specify only ONE of: lambda_bounds, rise_bounds, lambda, or rise. " *
            "Got: $(join(provided, ", "))"))
    end
    
    span_m = ustrip(u"m", span)
    
    # Convert to rise_bounds or fixed_rise (in meters, as Float64)
    if !isnothing(rise_bounds)
        return (ustrip(u"m", rise_bounds[1]), 
                ustrip(u"m", rise_bounds[2])), nothing
    elseif !isnothing(lambda_bounds)
        # λ = span/rise → rise = span/λ
        # λ_min → rise_max, λ_max → rise_min
        λ_min, λ_max = Float64.(lambda_bounds)
        return (span_m / λ_max, span_m / λ_min), nothing
    elseif !isnothing(rise)
        return nothing, ustrip(u"m", rise)
    elseif !isnothing(lambda)
        return nothing, span_m / Float64(lambda)
    else
        # Default: use lambda_bounds = (10, 20)
        return (span_m / 20.0, span_m / 10.0), nothing
    end
end

"""
Resolve thickness specification to (thickness_bounds, fixed_thickness) in meters.
"""
function _resolve_thickness(;
    thickness_bounds::Union{Tuple{<:Length, <:Length}, Nothing},
    thickness::Union{Length, Nothing},
    default_bounds::Tuple{<:Length, <:Length} = (2.0u"inch", 4.0u"inch"),
)
    if !isnothing(thickness_bounds) && !isnothing(thickness)
        throw(ArgumentError("Cannot specify both `thickness_bounds` and `thickness`."))
    end
    
    if !isnothing(thickness)
        return nothing, ustrip(u"m", thickness)
    elseif !isnothing(thickness_bounds)
        return (ustrip(u"m", thickness_bounds[1]), 
                ustrip(u"m", thickness_bounds[2])), nothing
    else
        # Default bounds
        return (ustrip(u"m", default_bounds[1]), 
                ustrip(u"m", default_bounds[2])), nothing
    end
end

"""
Determine optimization mode from resolved rise and thickness.
"""
function _detect_mode(
    rise_bounds::Union{Tuple{Float64, Float64}, Nothing},
    fixed_rise::Union{Float64, Nothing},
    thickness_bounds::Union{Tuple{Float64, Float64}, Nothing},
    fixed_thickness::Union{Float64, Nothing},
)
    has_rise_bounds = !isnothing(rise_bounds)
    has_fixed_rise = !isnothing(fixed_rise)
    has_thickness_bounds = !isnothing(thickness_bounds)
    has_fixed_thickness = !isnothing(fixed_thickness)
    
    if has_rise_bounds && has_thickness_bounds
        return OptBoth(rise_bounds, thickness_bounds)
    elseif has_rise_bounds && has_fixed_thickness
        return OptRise(rise_bounds, fixed_thickness)
    elseif has_fixed_rise && has_thickness_bounds
        return OptThickness(fixed_rise, thickness_bounds)
    elseif has_fixed_rise && has_fixed_thickness
        throw(ArgumentError("Both rise and thickness are fixed. Nothing to optimize!"))
    else
        error("Internal error: invalid rise/thickness resolution")
    end
end

# ==============================================================================
# Public API
# ==============================================================================

"""
    optimize_vault(span, sdl, live; kwargs...) -> NamedTuple

Find optimal vault geometry that minimizes volume/weight/carbon while satisfying
stress and deflection constraints.

# Arguments
- `span`: Clear span (chord length)
- `sdl`: Superimposed dead load
- `live`: Live load

# Rise Specification (choose ONE, or use defaults)
- `lambda_bounds`: `(λ_min, λ_max)` where λ = span/rise (default: `(10, 20)`)
- `rise_bounds`: `(min, max)` absolute rise bounds
- `lambda`: Fixed λ value (rise = span/λ)
- `rise`: Fixed rise value

# Thickness Specification
- `thickness_bounds`: `(min, max)` (default: 2"–4")
- `thickness`: Fixed thickness value

# Examples
```julia
# Use all defaults: λ ∈ (10,20), t ∈ (2",4")
optimize_vault(6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2")

# Custom lambda bounds
optimize_vault(span, sdl, live; lambda_bounds=(8.0, 15.0))

# Absolute rise bounds
optimize_vault(span, sdl, live; rise_bounds=(0.5u"m", 1.5u"m"))

# Fixed lambda, optimize thickness
optimize_vault(span, sdl, live; lambda=12.0)

# Fixed thickness, optimize rise
optimize_vault(span, sdl, live; thickness=75u"mm")

# Fixed rise and custom thickness bounds
optimize_vault(span, sdl, live; rise=1.0u"m", thickness_bounds=(50u"mm", 150u"mm"))
```

# Other Options
- `material`: Concrete (default: NWC_4000)
- `trib_depth`: Tributary depth (default: 1.0m)
- `finishing_load`: Topping load (default: 0)
- `allowable_stress`: Max stress MPa (default: 0.45 fc')
- `deflection_limit`: Max rise reduction (default: span/240)
- `check_asymmetric`: Check half-span live (default: true)
- `rib_depth`, `rib_apex_rise`: Rib geometry (default: 0)
- `objective`: MinVolume(), MinWeight(), MinCarbon(), MinCost()
- `solver`: :grid or :ipopt (default: :grid)
- `n_grid`, `n_refine`: Grid search params (default: 20, 2)
- `verbose`: Print progress (default: false)

# Returns
NamedTuple: `(rise, thickness, result, objective_value, status)`
"""
function optimize_vault(
    span::L,
    sdl::F,
    live::F;
    # Rise specification (choose ONE, or use default lambda_bounds)
    lambda_bounds::Union{Tuple{Real, Real}, Nothing} = nothing,
    rise_bounds::Union{Tuple{<:Length, <:Length}, Nothing} = nothing,
    lambda::Union{Real, Nothing} = nothing,
    rise::Union{Length, Nothing} = nothing,
    # Thickness specification
    thickness_bounds::Union{Tuple{<:Length, <:Length}, Nothing} = nothing,
    thickness::Union{Length, Nothing} = nothing,
    # Material and loading
    material::Concrete = NWC_4000,
    trib_depth::L = 1.0u"m",
    finishing_load::F = zero(sdl),
    allowable_stress::Union{Real, Nothing} = nothing,
    deflection_limit::Union{L, Nothing} = nothing,
    check_asymmetric::Bool = true,
    rib_depth::L = zero(span),
    rib_apex_rise::L = zero(span),
    # Solver options
    objective::AbstractObjective = MinVolume(),
    solver::Symbol = :grid,
    n_grid::Int = 20,
    n_refine::Int = 2,
    verbose::Bool = false,
    tc::Union{Nothing, TraceCollector} = nothing,
) where {L<:Length, F<:Pressure}
    
    # Resolve rise and thickness to bounds/fixed values (in meters)
    eff_rise_bounds, eff_fixed_rise = _resolve_rise(span;
        lambda_bounds, rise_bounds, lambda, rise)
    
    eff_thickness_bounds, eff_fixed_thickness = _resolve_thickness(;
        thickness_bounds, thickness)
    
    # Determine optimization mode
    mode = _detect_mode(eff_rise_bounds, eff_fixed_rise, 
                        eff_thickness_bounds, eff_fixed_thickness)
    
    StructuralSizer.emit!(tc, :optimizer, "optimize_vault", "", :enter;
                          span_m=Float64(ustrip(u"m", span)),
                          mode=_mode_description(mode),
                          solver=string(solver),
                          n_grid=n_grid,
                          n_refine=n_refine,
                          objective=string(typeof(objective)))

    if verbose
        @info "Vault optimization" mode=_mode_description(mode) span
    end
    
    # Build problem with bounds (convert back to Unitful for problem constructor)
    problem = VaultNLPProblem(
        span, trib_depth, sdl, live;
        material = material,
        finishing_load = finishing_load,
        allowable_stress = allowable_stress,
        deflection_limit = deflection_limit,
        rise_bounds = (_rise_bounds(mode)[1] * u"m", _rise_bounds(mode)[2] * u"m"),
        thickness_bounds = (_thickness_bounds(mode)[1] * u"m", _thickness_bounds(mode)[2] * u"m"),
        check_asymmetric = check_asymmetric,
        rib_depth = rib_depth,
        rib_apex_rise = rib_apex_rise,
        mode = _mode_symbol(mode),
    )
    
    if verbose
        @info "Optimizing vault" mode=_mode_description(mode) objective=typeof(objective)
    end
    
    # Solve
    opt_result = optimize_continuous(
        problem;
        objective = objective,
        solver = solver,
        n_grid = n_grid,
        n_refine = n_refine,
        verbose = verbose,
    )
    
    # Extract optimal values with units
    len_unit = unit(span)
    press_unit = unit(sdl)
    
    h_opt_m, t_opt_m = _extract_result(mode, opt_result.minimizer)
    
    h_opt = uconvert(len_unit, h_opt_m * u"m")
    t_opt = uconvert(len_unit, t_opt_m * u"m")
    
    # Build VaultResult from cached eval_result
    full_x = [h_opt_m, t_opt_m]
    vault_result = if opt_result.eval_result !== nothing
        build_result(problem, full_x, opt_result.eval_result, 
                     (length=len_unit, pressure=press_unit))
    else
        nothing
    end
    
    if verbose
        @info "Optimization complete" status=opt_result.status rise=h_opt thickness=t_opt
    end
    
    StructuralSizer.emit!(tc, :optimizer, "optimize_vault", "", :exit;
                          status=string(opt_result.status),
                          rise_m=Float64(ustrip(u"m", h_opt)),
                          thickness_m=Float64(ustrip(u"m", t_opt)),
                          objective_value=Float64(opt_result.objective_value))

    return (
        rise = h_opt,
        thickness = t_opt,
        result = vault_result,
        objective_value = opt_result.objective_value,
        status = opt_result.status,
    )
end

# ==============================================================================
# Flat Plate Optimization API
# ==============================================================================

"""
    size_flat_plate_optimized(struc, slab, opts; kwargs...) -> NamedTuple

Optimize flat plate slab thickness `h` and column size `c` simultaneously
using a 2D grid search with inner rebar sweep.

Unlike `size_flat_plate!` (which greedily bumps thickness), this evaluates
all feasible `(h, c, bar_size)` combinations and selects the one that
minimizes the chosen objective (volume, weight, cost, or carbon).

# Arguments
- `struc::BuildingStructure`: Structure with skeleton, cells, columns
- `slab::Slab`: Slab to design
- `opts::FlatPlateOptions`: Design options (material, objective, etc.)

# Keyword Arguments
- `h_max::Length`: Upper bound on slab thickness (default: ACI min + 6")
- `c_min::Length`: Lower bound on column size (default: span/15)
- `c_max::Length`: Upper bound on column size (default: `opts.max_column_size`)
- `bar_sizes::Vector{Int}`: Candidate bar sizes for rebar sweep (default: [4,5,6,7,8])
- `n_grid::Int = 20`: Grid points per dimension (total evals ≈ n_grid²)
- `n_refine::Int = 2`: Refinement passes around best point
- `verbose::Bool = false`: Print progress
- `column_opts = nothing`: Column options for the FEA fallback design
  (`nothing` → `ConcreteColumnOptions()`); unused by the grid search itself
- `max_iterations::Int = 10`: `size_flat_plate!` iteration limit for the FEA
  fallback design (same default as the pipeline); unused by the grid search

# DDM Applicability (ACI 318-11 §13.6.1, corpus: aci-318-11, page 252)
The grid search evaluates DDM moments, so it is run only when DDM is
permitted for the layout (`check_ddm_applicability`).  Otherwise
`opts.on_inapplicable` decides:
- `:fallback` (default) — no grid search; the slab is designed by the
  `size_flat_plate!` pipeline with `FEA()` (ACI 318-11 §13.5.1 general
  analysis), a `:fallback` trace event is emitted by
  `resolve_analysis_method`, and the result carries `status = :fea_fallback`
  (`:infeasible` if that design did not converge), `fea_design` (the full
  pipeline tuple) and the fallback record below.  `h` is the pipeline's final
  thickness and `c` the largest supporting-column dimension it designed;
  `bar_size`, `eval_result` and `objective_value` (`NaN`) do not apply.
- `:error` — the `DDMApplicabilityError` is thrown.

# Returns
Named tuple with:
- `h::Length`: Optimal slab thickness
- `c::Length`: Optimal column dimension
- `bar_size::Int`: Best bar designation (#4–#8)
- `objective_value::Float64`: Final objective score
- `status::Symbol`: `:success`, `:infeasible` or `:fea_fallback`
- `eval_result`: Full evaluation NamedTuple (moments, deflection, rebar)
- `n_evals::Int`: Total grid evaluations performed
- `fea_design`: The FEA pipeline result on fallback, else `nothing`
- `method_requested`, `method_used`, `method_fallback_reasons`: as for
  `size_flat_plate!` (`method_requested` is always `DDM()`, the NLP's model)

# Example
```julia
opts = FlatPlateOptions(objective=MinCarbon())
result = size_flat_plate_optimized(struc, slab, opts; verbose=true)
result.h       # optimal thickness
result.c       # optimal column size
result.bar_size  # best bar size
```
"""
function size_flat_plate_optimized(
    struc, slab, opts::FlatPlateOptions;
    h_max::Union{Length, Nothing}  = nothing,
    c_min::Union{Length, Nothing}  = nothing,
    c_max::Union{Length, Nothing}  = nothing,
    bar_sizes::Vector{Int}         = [4, 5, 6, 7, 8],
    n_grid::Int                    = 20,
    n_refine::Int                  = 2,
    verbose::Bool                  = false,
    column_opts                    = nothing,
    max_iterations::Int            = 10,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    StructuralSizer.emit!(tc, :slab, "size_flat_plate_optimized", "", :enter;
                          n_grid=n_grid,
                          n_refine=n_refine,
                          objective=string(typeof(opts.objective)),
                          n_bar_sizes=length(bar_sizes))
    # ── Find supporting columns ──
    slab_cell_indices = Set(slab.cell_indices)
    columns = find_supporting_columns(struc, slab_cell_indices)
    if isempty(columns)
        StructuralSizer.emit!(tc, :slab, "size_flat_plate_optimized", "", :failure;
                              reason="no_supporting_columns")
        error("No supporting columns found for slab.")
    end

    # ── DDM applicability (ACI 318-11 §13.6.1): the grid search is DDM ──
    requested = DDM()
    method_used, fallback_reasons = resolve_analysis_method(
        requested, struc, slab, columns, opts.on_inapplicable;
        ρ_concrete=opts.material.concrete.ρ, verbose=verbose, tc=tc,
        caller="size_flat_plate_optimized")
    record = (method_requested = requested, method_used = method_used,
              method_fallback_reasons = fallback_reasons)
    if method_used !== requested
        return _optimized_fea_fallback(struc, slab, opts, record;
                                       column_opts=column_opts, max_iterations=max_iterations,
                                       verbose=verbose, tc=tc)
    end

    # ── Build NLP problem ──
    problem = FlatPlateNLPProblem(
        struc, slab, columns, opts;
        h_max     = h_max,
        c_min     = c_min,
        c_max     = c_max,
        bar_sizes = bar_sizes,
        tc        = tc,
    )

    if verbose
        lb, ub = variable_bounds(problem)
        @info "Flat plate optimization" objective=typeof(opts.objective) h_range="$(lb[1])-$(ub[1]) in" c_range="$(lb[2])-$(ub[2]) in" bar_sizes=bar_sizes n_grid=n_grid n_refine=n_refine
    end

    # ── Run grid search ──
    # Eq. (13-7) maps are checked once for the whole sweep; `struc` must not
    # be mutated while it runs (`_nlp_frozen_sweep`).
    opt = _nlp_frozen_sweep(problem) do
        optimize_continuous(
            problem;
            objective = opts.objective,
            solver    = :grid,
            n_grid    = n_grid,
            n_refine  = n_refine,
            verbose   = verbose,
        )
    end

    # ── Interpret result ──
    if opt.status == :infeasible || isnothing(opt.eval_result)
        if verbose
            @warn "No feasible (h, c) found in grid search"
        end
        StructuralSizer.emit!(tc, :slab, "size_flat_plate_optimized", "", :failure;
                              status=string(opt.status),
                              n_evals=Int(opt.iterations))
        return (
            h              = nothing,
            c              = nothing,
            bar_size       = nothing,
            objective_value = Inf,
            status         = :infeasible,
            eval_result    = nothing,
            n_evals        = opt.iterations,
            fea_design     = nothing,
            record...,
        )
    end

    h_opt = opt.eval_result.h
    c_opt = opt.eval_result.c

    if verbose
        @info "Optimization complete" h=h_opt c=c_opt bar_size=opt.eval_result.bar_size objective=round(opt.objective_value, sigdigits=4) status=opt.status
    end

    StructuralSizer.emit!(tc, :slab, "size_flat_plate_optimized", "", :exit;
                          status=string(opt.status),
                          n_evals=Int(opt.iterations),
                          objective_value=Float64(opt.objective_value),
                          h_in=Float64(ustrip(u"inch", h_opt)),
                          c_in=Float64(ustrip(u"inch", c_opt)),
                          bar_size=Int(opt.eval_result.bar_size))

    return (
        h              = h_opt,
        c              = c_opt,
        bar_size       = opt.eval_result.bar_size,
        objective_value = opt.objective_value,
        status         = opt.status,
        eval_result    = opt.eval_result,
        n_evals        = opt.iterations,
        fea_design     = nothing,
        record...,
    )
end

"""
    _optimized_fea_fallback(struc, slab, opts, record; column_opts, max_iterations, verbose, tc) -> NamedTuple

FEA hand-off of `size_flat_plate_optimized` when DDM is not permitted for
the layout and `opts.on_inapplicable == :fallback`.  Runs the
`size_flat_plate!` pipeline with `method = FEA()` (and the caller's
`max_iterations`) and wraps its result in the
optimizer's return shape: `h` = final thickness, `c` = largest designed
supporting-column dimension, `status = :fea_fallback` (`:infeasible` when the
pipeline did not converge), `fea_design` = the pipeline tuple, and `record`
(`method_requested`, `method_used`, `method_fallback_reasons`) from the
applicability check.  Emits a `:decision` (`outcome = "fea_fallback"`) and,
on convergence, an `:exit` event; a non-converged design emits `:failure`.
"""
function _optimized_fea_fallback(struc, slab, opts::FlatPlateOptions, record;
                                 column_opts = nothing, max_iterations::Int = 10,
                                 verbose::Bool = false,
                                 tc::Union{Nothing, TraceCollector} = nothing)
    StructuralSizer.emit!(tc, :slab, "size_flat_plate_optimized", "", :decision;
                          outcome="fea_fallback",
                          method_requested=method_name(record.method_requested),
                          method_used=method_name(record.method_used),
                          n_violations=length(record.method_fallback_reasons))
    col_opts = isnothing(column_opts) ? ConcreteColumnOptions() : column_opts
    design = size_flat_plate!(struc, slab, col_opts;
                              method=record.method_used, opts=opts,
                              max_iterations=max_iterations, verbose=verbose, tc=tc)
    converged = design.converged && !isnothing(design.slab_result)
    columns = find_supporting_columns(struc, Set(slab.cell_indices))
    c_max = converged ? maximum(max(col.c1, col.c2) for col in columns) : nothing
    if converged
        StructuralSizer.emit!(tc, :slab, "size_flat_plate_optimized", "", :exit;
                              status="fea_fallback",
                              h_in=Float64(ustrip(u"inch", design.h_final)),
                              c_in=Float64(ustrip(u"inch", c_max)))
    else
        StructuralSizer.emit!(tc, :slab, "size_flat_plate_optimized", "", :failure;
                              reason="fea_fallback_not_converged",
                              failing_check=string(design.failing_check))
    end
    return (
        h               = converged ? design.h_final : nothing,
        c               = c_max,
        bar_size        = nothing,
        objective_value = NaN,
        status          = converged ? :fea_fallback : :infeasible,
        eval_result     = nothing,
        n_evals         = 0,
        fea_design      = design,
        record...,
    )
end