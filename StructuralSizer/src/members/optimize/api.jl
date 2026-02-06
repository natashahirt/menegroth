# ==============================================================================
# Column Sizing API
# ==============================================================================
# Clean, type-dispatched interface for column sizing.
# One function, material-specific options types.
# All inputs can be Unitful quantities - conversions handled internally.

# Unit conversion helpers are in Constants.jl (to_newtons, to_kip, to_Nm, to_kipft, etc.)

# ==============================================================================
# Main API: size_columns
# ==============================================================================

"""
    size_columns(Pu, Mux, geometries, opts::SteelColumnOptions; Muy=...)
    size_columns(Pu, Mux, geometries, opts::ConcreteColumnOptions; Muy=...)

Size columns using the specified options. Accepts any consistent Unitful quantities.

# Arguments
- `Pu`: Factored axial loads (positive = compression) — any force unit (N, kN, kip, etc.)
- `Mux`: Factored moments about x-axis — any moment unit (N·m, kN·m, kip·ft, etc.)
- `geometries`: Member geometries (auto-converted as needed)
- `opts`: `SteelColumnOptions` or `ConcreteColumnOptions`

# Keyword Arguments
- `Muy`: Factored moments about y-axis (default: zeros with same unit as Mux)

# Returns
Named tuple with:
- `sections`: Optimal sections (one per member)
- `section_indices`: Indices into catalog
- `status`: Solver status
- `objective_value`: Final objective value

# Example
```julia
using Unitful
using StructuralSizer: kip, ksi  # Asap custom units
# Unitful built-ins like kN, ft, m are available via u"..."

# Steel columns with SI units
Pu = [500.0, 800.0] .* u"kN"
Mux = [100.0, 150.0] .* u"kN*m"
geoms = [SteelMemberGeometry(4.0u"m"), SteelMemberGeometry(4.0u"m")]
result = size_columns(Pu, Mux, geoms, SteelColumnOptions())

# Concrete columns with US units  
Pu = [200.0, 350.0] .* kip
Mux = [150.0, 200.0] .* kip * u"ft"
geoms = [ConcreteMemberGeometry(12.0u"ft"), ConcreteMemberGeometry(12.0u"ft")]
result = size_columns(Pu, Mux, geoms, ConcreteColumnOptions())

# Mixed units work too - conversions are automatic
Pu_mixed = [500.0u"kN", 112.4kip]  # Will be converted internally
```
"""
function size_columns end

# ==============================================================================
# Steel Implementation
# ==============================================================================

function size_columns(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector,
    opts::SteelColumnOptions;
    Muy::Vector = zeros_like(Mux),
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))
    
    # Convert geometries if needed
    steel_geoms = [to_steel_geometry(g) for g in geometries]
    
    # Build catalog
    cat = isnothing(opts.custom_catalog) ? 
        steel_column_catalog(opts.section_type, opts.catalog) : 
        opts.custom_catalog
    
    # Convert forces/moments to SI (N, N·m) - handles any Unitful input
    Pu_N = [to_newtons(p) for p in Pu]
    Mux_Nm = [to_newton_meters(m) for m in Mux]
    Muy_Nm = [to_newton_meters(m) for m in Muy]
    
    # Build demands (now in consistent SI units)
    demands = [MemberDemand(i; Pu_c=Pu_N[i], Mux=Mux_Nm[i], Muy=Muy_Nm[i]) for i in 1:n]
    
    # Create checker
    checker = AISCChecker(; max_depth = opts.max_depth)
    
    # Optimize
    return optimize_discrete(
        checker, demands, steel_geoms, cat, opts.material;
        objective = opts.objective,
        n_max_sections = opts.n_max_sections,
        optimizer = opts.optimizer,
        mip_gap = mip_gap,
        output_flag = output_flag,
    )
end

# ==============================================================================
# Concrete Implementation
# ==============================================================================

function size_columns(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector,
    opts::ConcreteColumnOptions;
    Muy::Vector = zeros_like(Mux),
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))
    
    # Convert geometries if needed
    conc_geoms = [to_concrete_geometry(g) for g in geometries]
    
    # Build catalog (with section_shape dispatch)
    cat = isnothing(opts.custom_catalog) ? 
        rc_column_catalog(opts.section_shape, opts.catalog) : 
        opts.custom_catalog
    
    # Convert forces/moments to ACI units (kip, kip·ft) - handles any Unitful input
    Pu_kip = [to_kip(p) for p in Pu]
    Mux_kipft = [to_kipft(m) for m in Mux]
    Muy_kipft = [to_kipft(m) for m in Muy]
    
    # Build demands (now in consistent ACI units)
    demands = [RCColumnDemand(i; Pu=Pu_kip[i], Mux=Mux_kipft[i], Muy=Muy_kipft[i], βdns=opts.βdns) for i in 1:n]
    
    # Create checker
    fy_ksi_val = ustrip(ksi, opts.rebar_grade.Fy)
    checker = ACIColumnChecker(;
        include_slenderness = opts.include_slenderness,
        include_biaxial = opts.include_biaxial,
        fy_ksi = fy_ksi_val,
        max_depth = opts.max_depth,
    )
    
    # Optimize
    return optimize_discrete(
        checker, demands, conc_geoms, cat, opts.grade;
        objective = opts.objective,
        n_max_sections = opts.n_max_sections,
        optimizer = opts.optimizer,
        mip_gap = mip_gap,
        output_flag = output_flag,
    )
end

# ==============================================================================
# Geometry Converters
# ==============================================================================

"""
    to_steel_geometry(geom) -> SteelMemberGeometry

Convert any geometry to steel geometry.
"""
function to_steel_geometry(geom::ConcreteMemberGeometry)
    SteelMemberGeometry(geom.L; Lb=geom.Lu, Kx=geom.k, Ky=geom.k)
end
to_steel_geometry(geom::SteelMemberGeometry) = geom

"""
    to_concrete_geometry(geom) -> ConcreteMemberGeometry

Convert any geometry to concrete geometry.
"""
function to_concrete_geometry(geom::SteelMemberGeometry)
    ConcreteMemberGeometry(geom.L; Lu=geom.Lb, k=geom.Ky)
end
to_concrete_geometry(geom::ConcreteMemberGeometry) = geom

"""
    convert_geometries(geometries, target::Symbol)

Convert geometries to target type (`:steel` or `:concrete`).
"""
function convert_geometries(geometries::Vector, target::Symbol)
    if target === :steel
        return [to_steel_geometry(g) for g in geometries]
    elseif target === :concrete
        return [to_concrete_geometry(g) for g in geometries]
    else
        throw(ArgumentError("Unknown target=$target. Use :steel or :concrete"))
    end
end

# ==============================================================================
# Demand Converters
# ==============================================================================

"""
    to_steel_demands(demands) -> Vector{MemberDemand}

Convert RC demands to steel demands.
"""
function to_steel_demands(demands::Vector{<:RCColumnDemand})
    [MemberDemand(d.member_idx; Pu_c=d.Pu, Mux=d.Mux, Muy=d.Muy) for d in demands]
end
to_steel_demands(demands::Vector{<:MemberDemand}) = demands

"""
    to_rc_demands(demands; βdns=0.6) -> Vector{RCColumnDemand}

Convert steel demands to RC demands.
"""
function to_rc_demands(demands::Vector{<:MemberDemand}; βdns=0.6)
    [RCColumnDemand(d.member_idx; Pu=d.Pu_c, Mux=d.Mux, Muy=d.Muy, βdns=βdns) for d in demands]
end
to_rc_demands(demands::Vector{<:RCColumnDemand}; βdns=nothing) = demands

# ==============================================================================
# NLP Column Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_column_nlp(Pu, Mux, geometry, opts::NLPColumnOptions; Muy=0) -> RCColumnNLPResult

Size a single RC column using continuous (NLP) optimization.

Unlike `size_columns` which selects from a discrete catalog, this function
optimizes column dimensions (b, h) and reinforcement ratio (ρg) continuously
to find the minimum-volume section that satisfies ACI 318 requirements.

Uses the interior point solver (Ipopt) by default via `optimize_continuous`.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `ConcreteMemberGeometry` with Lu, k, braced
- `opts`: `NLPColumnOptions` with material, bounds, solver settings

# Keyword Arguments
- `Muy`: Factored moment about y-axis (default: 0)

# Returns
`RCColumnNLPResult` with:
- `section`: Optimized `RCColumnSection` (rounded to practical dimensions)
- `b_opt`, `h_opt`, `ρ_opt`: Continuous optimal values
- `b_final`, `h_final`: Final dimensions after rounding
- `area`: Final cross-sectional area (sq in)
- `status`: `:optimal`, `:feasible`, `:infeasible`, `:failed`

# Example
```julia
using Unitful
using StructuralSizer: kip

# Define demand and geometry
Pu = 500.0kip
Mux = 200.0kip * u"ft"
geom = ConcreteMemberGeometry(4.0; k=1.0, braced=true)

# Size with defaults
result = size_column_nlp(Pu, Mux, geom, NLPColumnOptions())
println("Optimal: \$(result.b_final)\" × \$(result.h_final)\"")

# Custom options
opts = NLPColumnOptions(
    grade = NWC_5000,
    min_dim = 14.0u"inch",
    max_dim = 30.0u"inch",
    prefer_square = 0.1,
    verbose = true
)
result = size_column_nlp(Pu, Mux, geom, opts)
```

# Algorithm
1. Formulates the problem as `RCColumnNLPProblem <: AbstractNLPProblem`
2. Calls `optimize_continuous(problem; solver=opts.solver)`
3. Rounds continuous solution to practical dimensions
4. Returns `RCColumnNLPResult` with final section

See also: [`size_columns`](@ref), [`NLPColumnOptions`](@ref), [`RCColumnNLPProblem`](@ref)
"""
function size_column_nlp(
    Pu,
    Mux,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions;
    Muy = 0.0
)
    # Convert demands to RCColumnDemand format
    Pu_kip = to_kip(Pu)
    Mux_kipft = to_kipft(Mux)
    Muy_kipft = Muy isa Unitful.Quantity ? to_kipft(Muy) : Float64(Muy)
    
    demand = RCColumnDemand(1; 
        Pu = Pu_kip, 
        Mux = Mux_kipft, 
        Muy = Muy_kipft, 
        βdns = opts.βdns
    )
    
    # Create NLP problem
    problem = RCColumnNLPProblem(demand, geometry, opts)
    
    # Solve using the generic continuous optimizer
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose
    )
    
    # Convert to user-friendly result
    return build_nlp_result(problem, opt_result)
end

"""
    size_columns_nlp(Pu, Mux, geometries, opts::NLPColumnOptions; Muy=...) -> Vector{RCColumnNLPResult}

Size multiple RC columns using continuous (NLP) optimization.

Applies `size_column_nlp` to each column independently.

# Arguments
- `Pu`: Vector of factored axial loads
- `Mux`: Vector of factored moments about x-axis
- `geometries`: Vector of `ConcreteMemberGeometry`
- `opts`: `NLPColumnOptions` (shared for all columns)

# Keyword Arguments
- `Muy`: Vector of factored moments about y-axis (default: zeros)

# Returns
Vector of `RCColumnNLPResult`, one per column.

# Example
```julia
Pu = [400.0, 600.0, 800.0] .* kip
Mux = [150.0, 200.0, 250.0] .* kip .* u"ft"
geoms = [ConcreteMemberGeometry(4.0; k=1.0) for _ in 1:3]

results = size_columns_nlp(Pu, Mux, geoms, NLPColumnOptions())
for (i, r) in enumerate(results)
    println("Column \$i: \$(r.b_final)\" × \$(r.h_final)\"")
end
```
"""
function size_columns_nlp(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:ConcreteMemberGeometry},
    opts::NLPColumnOptions;
    Muy::Vector = zeros(length(Pu))
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))
    
    results = Vector{RCColumnNLPResult}(undef, n)
    
    for i in 1:n
        Muy_i = i <= length(Muy) ? Muy[i] : 0.0
        results[i] = size_column_nlp(Pu[i], Mux[i], geometries[i], opts; Muy=Muy_i)
    end
    
    return results
end

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
    Muy = 0.0
)
    # Convert demands to MemberDemand format
    Pu_N = Pu isa Unitful.Quantity ? ustrip(u"N", uconvert(u"N", Pu)) : Float64(Pu)
    Mux_Nm = Mux isa Unitful.Quantity ? ustrip(u"N*m", uconvert(u"N*m", Mux)) : Float64(Mux)
    Muy_Nm = Muy isa Unitful.Quantity ? ustrip(u"N*m", uconvert(u"N*m", Muy)) : Float64(Muy)
    
    demand = MemberDemand(1; 
        Pu_c = Pu_N * u"N",
        Mux = Mux_Nm * u"N*m",
        Muy = Muy_Nm * u"N*m"
    )
    
    # Create NLP problem
    problem = HSSColumnNLPProblem(demand, geometry, opts)
    
    # Solve using the generic continuous optimizer
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose
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
    size_w_nlp(Pu, Mux, geometry, opts::NLPWOptions; Muy=0) -> WColumnNLPResult

Size a W section column using continuous (NLP) optimization.

Optimizes W section dimensions (d, bf, tf, tw) continuously to find the 
minimum-weight section that satisfies AISC 360 requirements. Treats the
section as a parameterized I-shape (similar to a built-up section).

**Note**: The optimal dimensions may not match standard rolled W shapes.
Use `opts.snap_to_catalog=true` to find the nearest catalog section.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `SteelMemberGeometry` with L, Kx, Ky
- `opts`: `NLPWOptions` with material, bounds, solver settings

# Keyword Arguments
- `Muy`: Factored moment about y-axis (default: 0)

# Returns
`WColumnNLPResult` with:
- `d_opt`, `bf_opt`, `tf_opt`, `tw_opt`: Continuous optimal values
- `d_final`, `bf_final`, `tf_final`, `tw_final`: Final dimensions
- `area`: Cross-sectional area (sq in)
- `weight_per_ft`: Weight per linear foot (lb/ft)
- `Ix`, `Iy`, `rx`, `ry`: Section properties
- `catalog_match`: Nearest W section name (if snap_to_catalog)
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

# Snap to nearest catalog section
opts = NLPWOptions(snap_to_catalog=true)
result = size_w_nlp(Pu, Mux, geom, opts)
println("Nearest catalog: \$(result.catalog_match)")
```

See also: [`size_columns`](@ref), [`NLPWOptions`](@ref), [`WColumnNLPProblem`](@ref)
"""
function size_w_nlp(
    Pu,
    Mux,
    geometry::SteelMemberGeometry,
    opts::NLPWOptions;
    Muy = 0.0
)
    # Convert demands to MemberDemand format
    Pu_N = Pu isa Unitful.Quantity ? ustrip(u"N", uconvert(u"N", Pu)) : Float64(Pu)
    Mux_Nm = Mux isa Unitful.Quantity ? ustrip(u"N*m", uconvert(u"N*m", Mux)) : Float64(Mux)
    Muy_Nm = Muy isa Unitful.Quantity ? ustrip(u"N*m", uconvert(u"N*m", Muy)) : Float64(Muy)
    
    demand = MemberDemand(1; 
        Pu_c = Pu_N * u"N",
        Mux = Mux_Nm * u"N*m",
        Muy = Muy_Nm * u"N*m"
    )
    
    # Create NLP problem
    problem = WColumnNLPProblem(demand, geometry, opts)
    
    # Solve using the generic continuous optimizer
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose
    )
    
    # Convert to user-friendly result
    return build_w_nlp_result(problem, opt_result)
end

"""
    size_w_columns_nlp(Pu, Mux, geometries, opts::NLPWOptions; Muy=...) -> Vector{WColumnNLPResult}

Size multiple W section columns using continuous (NLP) optimization.

Applies `size_w_nlp` to each column independently.

# Arguments
- `Pu`: Vector of factored axial loads
- `Mux`: Vector of factored moments about x-axis
- `geometries`: Vector of `SteelMemberGeometry`
- `opts`: `NLPWOptions` (shared for all columns)

# Keyword Arguments
- `Muy`: Vector of factored moments about y-axis (default: zeros)

# Returns
Vector of `WColumnNLPResult`, one per column.

# Example
```julia
Pu = [500.0, 1000.0, 1500.0] .* u"kN"
Mux = [50.0, 100.0, 150.0] .* u"kN*m"
geoms = [SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0) for _ in 1:3]

opts = NLPWOptions(snap_to_catalog=true)
results = size_w_columns_nlp(Pu, Mux, geoms, opts)
for (i, r) in enumerate(results)
    println("Column \$i: \$(r.catalog_match), \$(round(r.weight_per_ft))lb/ft")
end
```
"""
function size_w_columns_nlp(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:SteelMemberGeometry},
    opts::NLPWOptions;
    Muy::Vector = zeros(length(Pu))
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))
    
    results = Vector{WColumnNLPResult}(undef, n)
    
    for i in 1:n
        Muy_i = i <= length(Muy) ? Muy[i] : 0.0
        results[i] = size_w_nlp(Pu[i], Mux[i], geometries[i], opts; Muy=Muy_i)
    end
    
    return results
end