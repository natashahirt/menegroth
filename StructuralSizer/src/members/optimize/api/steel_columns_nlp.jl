# ==============================================================================
# HSS NLP Column Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_hss_nlp(Pu, Mux, geometry, opts::NLPHSSOptions; Muy=0) -> HSSColumnNLPResult

Size a single rectangular HSS column using continuous (NLP) optimization.

Optimizes HSS dimensions (B, H, t) continuously to find the minimum-weight
section that satisfies AISC 360 requirements. Uses smooth approximations
of AISC functions for compatibility with automatic differentiation.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `SteelMemberGeometry` with L, Kx, Ky
- `opts`: `NLPHSSOptions` with material, bounds, solver settings

# Keyword Arguments
- `Muy`: Factored moment about y-axis (default: 0)

# Returns
`HSSColumnNLPResult` with:
- `section`: Optimized `HSSRectSection` (rounded to standard sizes)
- `B_opt`, `H_opt`, `t_opt`: Continuous optimal values
- `B_final`, `H_final`, `t_final`: Final dimensions after rounding
- `area`: Final cross-sectional area (sq in)
- `weight_per_ft`: Weight per linear foot (lb/ft)
- `status`: `:optimal`, `:feasible`, `:infeasible`, `:failed`

# Example
```julia
using Unitful

# Define demand and geometry
Pu = 500.0u"kN"
Mux = 50.0u"kN*m"
geom = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)

# Size with defaults
result = size_hss_nlp(Pu, Mux, geom, NLPHSSOptions())
println("Optimal: HSS \$(result.B_final)×\$(result.H_final)×\$(result.t_final)")

# Custom options
opts = NLPHSSOptions(
    material = A992_Steel,
    min_outer = 6.0u"inch",
    max_outer = 16.0u"inch",
    prefer_square = 0.1,
    verbose = true
)
result = size_hss_nlp(Pu, Mux, geom, opts)
```

# Algorithm
1. Formulates the problem as `HSSColumnNLPProblem <: AbstractNLPProblem`
2. Uses smooth AISC functions for differentiability
3. Calls `optimize_continuous(problem; solver=opts.solver)`
4. Rounds continuous solution to practical HSS sizes
5. Returns `HSSColumnNLPResult` with final section

See also: [`size_columns`](@ref), [`NLPHSSOptions`](@ref), [`HSSColumnNLPProblem`](@ref)
"""
function size_hss_nlp(
    Pu,
    Mux,
    geometry::SteelMemberGeometry,
    opts::NLPHSSOptions;
    Muy = 0.0,
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    demand = MemberDemand(1; 
        Pu_c = to_newtons(Pu) * u"N",
        Mux = to_newton_meters(Mux) * u"N*m",
        Muy = to_newton_meters(Muy) * u"N*m"
    )
    
    problem = HSSColumnNLPProblem(demand, geometry, opts)
    
    # Solve using the generic continuous optimizer
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )
    
    # Convert to user-friendly result
    return build_hss_nlp_result(problem, opt_result)
end

"""
    size_hss_columns_nlp(Pu, Mux, geometries, opts::NLPHSSOptions; Muy=...) -> Vector{HSSColumnNLPResult}

Size multiple HSS columns using continuous (NLP) optimization.

Applies `size_hss_nlp` to each column independently.

# Arguments
- `Pu`: Vector of factored axial loads
- `Mux`: Vector of factored moments about x-axis
- `geometries`: Vector of `SteelMemberGeometry`
- `opts`: `NLPHSSOptions` (shared for all columns)

# Keyword Arguments
- `Muy`: Vector of factored moments about y-axis (default: zeros)

# Returns
Vector of `HSSColumnNLPResult`, one per column.

# Example
```julia
Pu = [300.0, 500.0, 700.0] .* u"kN"
Mux = [30.0, 50.0, 70.0] .* u"kN*m"
geoms = [SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0) for _ in 1:3]

results = size_hss_columns_nlp(Pu, Mux, geoms, NLPHSSOptions())
for (i, r) in enumerate(results)
    println("Column \$i: HSS \$(r.B_final)×\$(r.H_final)×\$(r.t_final)")
end
```
"""
function size_hss_columns_nlp(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:SteelMemberGeometry},
    opts::NLPHSSOptions;
    Muy::Vector = zeros(length(Pu))
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))
    
    results = Vector{HSSColumnNLPResult}(undef, n)
    
    for i in 1:n
        Muy_i = i <= length(Muy) ? Muy[i] : 0.0
        results[i] = size_hss_nlp(Pu[i], Mux[i], geometries[i], opts; Muy=Muy_i)
    end
    
    return results
end

# ==============================================================================
# W Section NLP Column Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_w_nlp(Pu, Mux, geometry, opts::NLPWOptions; Muy=0, Mux_neg=Mux, composite=nothing) -> WColumnNLPResult

Size a W section column using continuous (NLP) optimization.

Optimizes W section dimensions (d, bf, tf, tw) continuously to find the 
minimum-weight section that satisfies AISC 360 requirements. Treats the
section as a parameterized I-shape (similar to a built-up section).

**Note**: The optimal dimensions are a custom continuous section and may not
match standard rolled W shapes. Use the MIP solver for catalog selection.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `SteelMemberGeometry` with L, Kx, Ky
- `opts`: `NLPWOptions` with material, bounds, solver settings

# Keyword Arguments
- `Muy`: Factored moment about y-axis (default: 0)
- `Mux_neg`: Hogging strong-axis moment (default: `Mux`). When `Mux_neg > 0`,
  sizes against `max(Mux, Mux_neg)` with hogging Chapter F (`Lb = L`,
  `Cb = 1.0`) if deck-braced sagging `Lb`/`Cb` would otherwise inflate φMn.
  AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
  # ENGINEERING JUDGMENT: hogging `Cb = 1.0` (no bottom-flange `Cb` field).
- `composite`: Optional `CompositeContext` / `true` / `nothing` stored on
  `MemberDemand`. Chapter I plastic capacity is evaluated by 8-arg
  `is_feasible` on the discrete MIP path (`size_columns` diverts NLP→MIP
  when a `CompositeContext` is present).

# Returns
`WColumnNLPResult` with:
- `d_opt`, `bf_opt`, `tf_opt`, `tw_opt`: Continuous optimal values
- `d_final`, `bf_final`, `tf_final`, `tw_final`: Final dimensions
- `area`: Cross-sectional area (sq in)
- `weight_per_ft`: Weight per linear foot (lb/ft)
- `Ix`, `Iy`, `rx`, `ry`: Section properties
- `status`: `:optimal`, `:feasible`, `:infeasible`, `:failed`

# Example
```julia
using Unitful

# Define demand and geometry
Pu = 1000.0u"kN"
Mux = 150.0u"kN*m"
geom = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)

# Size with defaults
result = size_w_nlp(Pu, Mux, geom, NLPWOptions())
println("Optimal: d=\$(result.d_final)\", bf=\$(result.bf_final)\"")
println("Weight: \$(round(result.weight_per_ft, digits=1)) lb/ft")
```

See also: [`size_columns`](@ref), [`NLPWOptions`](@ref), [`WColumnNLPProblem`](@ref)
"""
function size_w_nlp(
    Pu,
    Mux,
    geometry::SteelMemberGeometry,
    opts::NLPWOptions;
    Muy = 0.0,
    Mux_neg = Mux,
    composite = nothing,
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    demand = MemberDemand(1; 
        Pu_c = to_newtons(Pu) * u"N",
        Mux = to_newton_meters(Mux) * u"N*m",
        Mux_neg = to_newton_meters(Mux_neg) * u"N*m",
        Muy = to_newton_meters(Muy) * u"N*m",
        composite = composite,
    )
    
    problem = WColumnNLPProblem(demand, geometry, opts)
    
    # Solve using the generic continuous optimizer
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )
    
    # Convert to user-friendly result
    return build_w_nlp_result(problem, opt_result)
end

"""
    size_w_columns_nlp(Pu, Mux, geometries, opts::NLPWOptions; Muy, Mux_neg, composite) -> Vector{WColumnNLPResult}

Size multiple W section columns using continuous (NLP) optimization.

Applies `size_w_nlp` to each column independently.

# Arguments
- `Pu`: Vector of factored axial loads
- `Mux`: Vector of factored moments about x-axis
- `geometries`: Vector of `SteelMemberGeometry`
- `opts`: `NLPWOptions` (shared for all columns)

# Keyword Arguments
- `Muy`: Vector of factored moments about y-axis (default: zeros)
- `Mux_neg`: Vector of hogging strong-axis moments (default: `Mux`). Threaded
  into `size_w_nlp` so hogging Chapter F (`Lb=L`, `Cb=1.0`) can govern.
  AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
- `composite`: Per-member or scalar composite payload forwarded onto each
  `MemberDemand` (see `size_w_nlp`).

# Returns
Vector of `WColumnNLPResult`, one per column.

# Example
```julia
Pu = [500.0, 1000.0, 1500.0] .* u"kN"
Mux = [50.0, 100.0, 150.0] .* u"kN*m"
geoms = [SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0) for _ in 1:3]

opts = NLPWOptions()
results = size_w_columns_nlp(Pu, Mux, geoms, opts)
for (i, r) in enumerate(results)
    println("Column \$i: d=\$(round(r.d_final, digits=1))\", \$(round(r.weight_per_ft))lb/ft")
end
```
"""
function size_w_columns_nlp(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:SteelMemberGeometry},
    opts::NLPWOptions;
    Muy::Vector = zeros(length(Pu)),
    Mux_neg::Vector = Mux,
    composite::Union{Nothing, Bool, CompositeContext, PerStationComposite, AbstractVector} = nothing,
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))
    n == length(Mux_neg) || throw(ArgumentError("Pu and Mux_neg must have same length"))
    
    results = Vector{WColumnNLPResult}(undef, n)
    
    for i in 1:n
        Muy_i = i <= length(Muy) ? Muy[i] : 0.0
        comp_i = if composite isa AbstractVector
            i <= length(composite) || throw(ArgumentError(
                "composite vector must have one entry per member"))
            composite[i]
        else
            composite
        end
        results[i] = size_w_nlp(Pu[i], Mux[i], geometries[i], opts;
                                Muy=Muy_i, Mux_neg=Mux_neg[i], composite=comp_i)
    end
    
    return results
end

