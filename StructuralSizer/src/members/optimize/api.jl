# ==============================================================================
# Column Sizing API
# ==============================================================================
# Clean, type-dispatched interface for column sizing.
# One function, material-specific options types.
# All inputs can be Unitful quantities - conversions handled internally.

"""Create zero vector matching the units of the input vector."""
function zeros_like(v::Vector)
    if !isempty(v) && v[1] isa Unitful.Quantity
        return zeros(length(v)) .* unit(v[1])
    else
        return zeros(length(v))
    end
end

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
    
    # Build demands (SI units)
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
    cache::Union{Nothing, AbstractCapacityCache} = nothing,
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
    
    # Build demands (ACI units)
    demands = [RCColumnDemand(i; Pu=Pu_kip[i], Mux=Mux_kipft[i], Muy=Muy_kipft[i], βdns=opts.βdns) for i in 1:n]
    
    # Create checker (rebar properties from user's material)
    checker = ACIColumnChecker(;
        include_slenderness = opts.include_slenderness,
        include_biaxial = opts.include_biaxial,
        fy_ksi = ustrip(ksi, opts.rebar_grade.Fy),
        Es_ksi = ustrip(ksi, opts.rebar_grade.E),
        max_depth = opts.max_depth,
    )
    
    # Optimize (reuse external cache if provided)
    return optimize_discrete(
        checker, demands, conc_geoms, cat, opts.grade;
        objective = opts.objective,
        n_max_sections = opts.n_max_sections,
        optimizer = opts.optimizer,
        mip_gap = mip_gap,
        output_flag = output_flag,
        cache = cache,
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
# RC Beam Sizing (Discrete Catalog Optimization)
# ==============================================================================

"""
    size_beams(Mu, Vu, geometries, opts::ConcreteBeamOptions; Nu=..., Tu=..., ...)

Size reinforced concrete beams using discrete catalog optimization.
Selects the lightest (or minimum-objective) RCBeamSection that satisfies
ACI 318-11 flexure and shear requirements.

# Arguments
- `Mu`: Vector of factored moments — any moment unit (N·m, kN·m, kip·ft, etc.)
- `Vu`: Vector of factored shears — any force unit (N, kN, kip, etc.)
- `geometries`: Member geometries (span length via `ConcreteMemberGeometry`)
- `opts`: `ConcreteBeamOptions`

# Keyword Arguments
- `Nu`: Vector of factored axial compressions (default: zeros). When > 0,
  the shear checker increases Vc per ACI §22.5.6.1.
- `Tu`: Vector of factored torsional moments (default: zeros, kip·in or Unitful).
  When > threshold torsion, the MIP checker checks cross-section adequacy
  per ACI 318-11 §11.5.3.1.
- `mip_gap`: MIP optimality gap (default 1e-4)
- `output_flag`: Solver verbosity (default 0)

# Returns
Named tuple with:
- `sections`: Optimal `RCBeamSection` per member
- `section_indices`: Indices into catalog
- `status`: Solver status
- `objective_value`: Final objective value

# Example
```julia
Mu = [100.0, 200.0] .* kip .* u"ft"
Vu = [30.0, 50.0] .* kip
geoms = [ConcreteMemberGeometry(6.0u"m") for _ in 1:2]
result = size_beams(Mu, Vu, geoms, ConcreteBeamOptions())

# With axial compression on member 2:
Nu = [0.0, 50.0] .* kip
result = size_beams(Mu, Vu, geoms, ConcreteBeamOptions(); Nu=Nu)

# With torsion on member 1:
Tu = [80.0, 0.0]   # kip·in (or Unitful: [80.0u"kip*inch", 0.0u"kip*inch"])
result = size_beams(Mu, Vu, geoms, ConcreteBeamOptions(); Tu=Tu)
```
"""
function size_beams end

function size_beams(
    Mu::Vector,
    Vu::Vector,
    geometries::Vector,
    opts::ConcreteBeamOptions;
    Nu::Vector = zeros_like(Vu),
    Tu::Vector = Float64[],
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
)
    n = length(Mu)
    n == length(Vu)          || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(geometries)  || throw(ArgumentError("demands and geometries must have same length"))

    # Convert geometries
    conc_geoms = [to_concrete_geometry(g) for g in geometries]

    # Build catalog
    cat = isnothing(opts.custom_catalog) ?
        rc_beam_catalog(opts.catalog) :
        opts.custom_catalog

    # Convert forces / moments to kip / kip·ft
    Mu_kipft = [to_kipft(m) for m in Mu]
    Vu_kip   = [to_kip(v)   for v in Vu]
    Nu_kip   = [to_kip(n)   for n in Nu]

    # Convert torsion to kip·in (raw number)
    Tu_kipin = if isempty(Tu)
        zeros(n)
    else
        [t isa Unitful.Quantity ? abs(ustrip(kip*u"inch", t)) : abs(Float64(t)) for t in Tu]
    end

    # Build demands (Nu, Tu flow to checker via RCBeamDemand fields)
    demands = [RCBeamDemand(i; Mu=Mu_kipft[i], Vu=Vu_kip[i], Nu=Nu_kip[i], Tu=Tu_kipin[i]) for i in 1:n]

    # Create checker
    checker = ACIBeamChecker(;
        fy_ksi  = ustrip(ksi, opts.rebar_grade.Fy),
        fyt_ksi = ustrip(ksi, get_transverse_rebar(opts).Fy),
        Es_ksi  = ustrip(ksi, opts.rebar_grade.E),
        λ       = opts.grade.λ,       # Lightweight factor from Concrete type
        max_depth = opts.max_depth,
    )

    # Optimize
    return optimize_discrete(
        checker, demands, conc_geoms, cat, opts.grade;
        objective      = opts.objective,
        n_max_sections = opts.n_max_sections,
        optimizer      = opts.optimizer,
        mip_gap        = mip_gap,
        output_flag    = output_flag,
    )
end

# ==============================================================================
# Steel Beam Sizing (via AISC Checker with Pu=0)
# ==============================================================================

"""
    size_beams(Mu, Vu, geometries, opts::SteelMemberOptions; ...)

Size steel beams using discrete catalog optimization.

Uses the AISC 360 checker with zero axial load (pure flexure). The same
checker handles both beams and columns, so this is a thin wrapper around
`size_columns` with `Pu = 0`.

Shear (`Vu`) is not used in the MIP selection — check it after sizing
with `get_ϕVn` or the beam utilization function.

# Arguments
- `Mu`: Vector of factored moments — any moment unit (N·m, kN·m, kip·ft, etc.)
- `Vu`: Vector of factored shears — any force unit (reserved; not used in MIP)
- `geometries`: Member geometries (span via `SteelMemberGeometry`)
- `opts`: `SteelBeamOptions` (alias for `SteelMemberOptions`)

# Keyword Arguments
- `mip_gap`: MIP optimality gap (default 1e-4)
- `output_flag`: Solver verbosity (default 0)

# Returns
Named tuple with:
- `sections`: Optimal sections (one per member)
- `section_indices`: Indices into catalog
- `status`: Solver status
- `objective_value`: Final objective value

# Example
```julia
Mu = [150.0, 200.0] .* u"kN*m"
Vu = [100.0, 120.0] .* u"kN"
geoms = [SteelMemberGeometry(8.0; Kx=1.0, Ky=1.0) for _ in 1:2]
result = size_beams(Mu, Vu, geoms, SteelBeamOptions(section_type=:w))
```
"""
function size_beams(
    Mu::Vector,
    Vu::Vector,
    geometries::Vector,
    opts::SteelMemberOptions;
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
)
    # Pu = 0 for pure beams; Mu maps to Mux for the AISC interaction checker.
    # Use Vu's units (force) to build a zero Pu vector with compatible dimensions.
    Pu_zero = [zero(Vu[1]) for _ in Mu]
    return size_columns(Pu_zero, Mu, geometries, opts;
                        mip_gap=mip_gap, output_flag=output_flag)
end

# ==============================================================================
# Unified Entry Point: size_members
# ==============================================================================

"""
    size_members(arg1, arg2, geometries, opts; ...)

Unified member sizing dispatcher. Routes to `size_columns` or `size_beams`
based on the options type:

| Options type             | Interpretation       | Delegates to     |
|:------------------------ |:-------------------- |:---------------- |
| `ConcreteColumnOptions`  | arg1=Pu, arg2=Mux    | `size_columns`   |
| `ConcreteBeamOptions`    | arg1=Mu, arg2=Vu     | `size_beams`     |

For `SteelMemberOptions` (where `SteelColumnOptions === SteelBeamOptions`),
call `size_columns` or `size_beams` directly since the type system cannot
distinguish the two cases.

# Example
```julia
# Concrete columns
result = size_members(Pu, Mux, geoms, ConcreteColumnOptions())

# Concrete beams
result = size_members(Mu, Vu, geoms, ConcreteBeamOptions())

# Steel — use size_beams / size_columns directly
result = size_beams(Mu, Vu, geoms, SteelBeamOptions())
result = size_columns(Pu, Mux, geoms, SteelColumnOptions())
```
"""
function size_members end

function size_members(
    Pu::Vector, Mux::Vector, geometries::Vector,
    opts::ConcreteColumnOptions; kwargs...
)
    size_columns(Pu, Mux, geometries, opts; kwargs...)
end

function size_members(
    Mu::Vector, Vu::Vector, geometries::Vector,
    opts::ConcreteBeamOptions; kwargs...
)
    size_beams(Mu, Vu, geometries, opts; kwargs...)
end

# ==============================================================================
# NLP Column Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_rc_column_nlp(Pu, Mux, geometry, opts::NLPColumnOptions; Muy=0) -> RCColumnNLPResult

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
result = size_rc_column_nlp(Pu, Mux, geom, NLPColumnOptions())
println("Optimal: \$(result.b_final)\" × \$(result.h_final)\"")

# Custom options
opts = NLPColumnOptions(
    grade = NWC_5000,
    min_dim = 14.0u"inch",
    max_dim = 30.0u"inch",
    prefer_square = 0.1,
    verbose = true
)
result = size_rc_column_nlp(Pu, Mux, geom, opts)
```

# Algorithm
1. Formulates the problem as `RCColumnNLPProblem <: AbstractNLPProblem`
2. Calls `optimize_continuous(problem; solver=opts.solver)`
3. Rounds continuous solution to practical dimensions
4. Returns `RCColumnNLPResult` with final section

See also: [`size_columns`](@ref), [`NLPColumnOptions`](@ref), [`RCColumnNLPProblem`](@ref)
"""
function size_rc_column_nlp(
    Pu,
    Mux,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions;
    Muy = 0.0,
    x0::Union{Nothing,Vector{Float64}} = nothing
)
    # Convert demands to RCColumnDemand format
    Pu_kip = to_kip(Pu)
    Mux_kipft = to_kipft(Mux)
    Muy_kipft = to_kipft(Muy)
    
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
        verbose = opts.verbose,
        x0 = x0,
        n_multistart = opts.n_multistart,
    )
    
    # Convert to user-friendly result
    return build_rc_column_nlp_result(problem, opt_result)
end

"""
    size_rc_columns_nlp(Pu, Mux, geometries, opts::NLPColumnOptions; Muy=...) -> Vector{RCColumnNLPResult}

Size multiple RC columns using continuous (NLP) optimization.

Applies `size_rc_column_nlp` to each column independently.

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

results = size_rc_columns_nlp(Pu, Mux, geoms, NLPColumnOptions())
for (i, r) in enumerate(results)
    println("Column \$i: \$(r.b_final)\" × \$(r.h_final)\"")
end
```
"""
function size_rc_columns_nlp(
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
        results[i] = size_rc_column_nlp(Pu[i], Mux[i], geometries[i], opts; Muy=Muy_i)
    end
    
    return results
end

# ==============================================================================
# RC Circular Column NLP Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_rc_column_nlp(::Type{RCCircularSection}, Pu, Mux, geometry, opts) -> RCCircularNLPResult

Size a single circular RC column using continuous (NLP) optimization.

Optimizes column diameter (D) and reinforcement ratio (ρg) continuously
to find the minimum-area section that satisfies ACI 318 requirements.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `ConcreteMemberGeometry` with Lu, k, braced
- `opts`: `NLPColumnOptions` with material, bounds, solver settings.
  Use `tie_type=:spiral` for spiral confinement (typical for circular).

# Returns
`RCCircularNLPResult` with:
- `section`: Optimized `RCCircularSection` (rounded to practical diameter)
- `D_opt`, `ρ_opt`: Continuous optimal values
- `D_final`: Final diameter after rounding
- `area`: Final cross-sectional area (sq in)
- `status`: `:optimal`, `:feasible`, `:infeasible`, `:failed`

# Example
```julia
using Unitful
using StructuralSizer: kip

Pu = 500.0kip
Mux = 200.0kip * u"ft"
geom = ConcreteMemberGeometry(4.0; k=1.0, braced=true)

opts = NLPColumnOptions(tie_type=:spiral, min_dim=10.0u"inch", max_dim=36.0u"inch")
result = size_rc_column_nlp(RCCircularSection, Pu, Mux, geom, opts)
println("Optimal diameter: \$(result.D_final)\"")
```

See also: [`size_rc_column_nlp`](@ref), [`NLPColumnOptions`](@ref), [`RCCircularNLPProblem`](@ref)
"""
function size_rc_column_nlp(::Type{RCCircularSection},
    Pu,
    Mux,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions;
    x0::Union{Nothing,Vector{Float64}} = nothing
)
    Pu_kip = to_kip(Pu)
    Mux_kipft = to_kipft(Mux)

    demand = RCColumnDemand(1;
        Pu = Pu_kip,
        Mux = Mux_kipft,
        Muy = 0.0,
        βdns = opts.βdns
    )

    problem = RCCircularNLPProblem(demand, geometry, opts)

    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
        n_multistart = opts.n_multistart,
    )

    return build_rc_circular_nlp_result(problem, opt_result)
end

"""
    size_rc_columns_nlp(::Type{RCCircularSection}, Pu, Mux, geometries, opts) -> Vector{RCCircularNLPResult}

Size multiple circular RC columns using continuous (NLP) optimization.
Applies `size_rc_column_nlp(RCCircularSection, ...)` to each column independently.
"""
function size_rc_columns_nlp(::Type{RCCircularSection},
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:ConcreteMemberGeometry},
    opts::NLPColumnOptions
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))

    results = Vector{RCCircularNLPResult}(undef, n)
    for i in 1:n
        results[i] = size_rc_column_nlp(RCCircularSection, Pu[i], Mux[i], geometries[i], opts)
    end
    return results
end

# ==============================================================================
# RC Beam NLP Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_rc_beam_nlp(Mu, Vu, opts::NLPBeamOptions) -> RCBeamNLPResult

Size a single RC beam using continuous (NLP) optimization.

Optimizes beam width (b), depth (h), and reinforcement ratio (ρ) to find
the minimum-area section satisfying ACI 318 flexure and shear requirements.

# Arguments
- `Mu`: Factored moment — any moment unit (kip·ft, kN·m, etc.)
- `Vu`: Factored shear — any force unit (kip, kN, etc.)
- `opts`: `NLPBeamOptions` with material, bounds, solver settings

# Returns
`RCBeamNLPResult` with:
- `section`: Constructed `RCBeamSection`
- `b_opt`, `h_opt`, `ρ_opt`: Continuous optimal values
- `b_final`, `h_final`: Final dimensions after optional snapping
- `area`: Final cross-sectional area (in²)
- `status`: Solver termination status

# Example
```julia
using Unitful
using StructuralSizer: kip

Mu = 200.0kip * u"ft"
Vu = 40.0kip
opts = NLPBeamOptions(min_depth=14.0u"inch", max_depth=30.0u"inch")
result = size_rc_beam_nlp(Mu, Vu, opts)
println("Section: \$(result.section.name), Area: \$(result.area) in²")
```
"""
function size_rc_beam_nlp(Mu, Vu, opts::NLPBeamOptions;
                          Tu = 0.0,
                          x0::Union{Nothing,Vector{Float64}} = nothing)
    problem = RCBeamNLPProblem(Mu, Vu, opts; Tu=Tu)

    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )

    return build_rc_beam_nlp_result(problem, opt_result)
end

"""
    size_rc_beams_nlp(Mu, Vu, opts::NLPBeamOptions) -> Vector{RCBeamNLPResult}

Size multiple RC beams using continuous (NLP) optimization.
"""
function size_rc_beams_nlp(Mu::Vector, Vu::Vector, opts::NLPBeamOptions)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))

    results = Vector{RCBeamNLPResult}(undef, n)
    for i in 1:n
        results[i] = size_rc_beam_nlp(Mu[i], Vu[i], opts)
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
    size_w_nlp(Pu, Mux, geometry, opts::NLPWOptions; Muy=0) -> WColumnNLPResult

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
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    demand = MemberDemand(1; 
        Pu_c = to_newtons(Pu) * u"N",
        Mux = to_newton_meters(Mux) * u"N*m",
        Muy = to_newton_meters(Muy) * u"N*m"
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

# ==============================================================================
# Steel W Beam NLP Sizing (Dedicated Beam Formulation)
# ==============================================================================

"""
    size_steel_w_beam_nlp(Mu, Vu, geometry, opts::NLPWOptions; Ix_min, x0) -> WColumnNLPResult

Size a W-shape beam using continuous (NLP) optimization with dedicated
AISC F2 flexure (including smooth LTB) and G2 shear constraints.

Unlike `size_w_nlp` (which uses H1-1 interaction with Pu=0), this
formulation directly optimizes for flexure and shear, producing beams
with wider flanges to resist lateral-torsional buckling.

# Arguments
- `Mu`: Factored moment — any moment unit
- `Vu`: Factored shear — any force unit
- `geometry`: `SteelMemberGeometry` with L, Lb (unbraced length), Cb
- `opts`: `NLPWOptions` with material, dimension bounds, solver settings

# Keyword Arguments
- `Ix_min`: Minimum required Ix for deflection (Length⁴ or bare in⁴). Use
  `required_Ix_for_deflection` to compute from service loads. Default: `nothing`.
- `x0`: Initial guess vector (default: automatic)

# Returns
`WColumnNLPResult` with `.section::ISymmSection` for analytical checks.

# Example
```julia
# Strength only
result = size_steel_w_beam_nlp(150.0u"kN*m", 100.0u"kN",
    SteelMemberGeometry(8.0; Kx=1.0, Ky=1.0),
    NLPWOptions(min_depth=8.0u"inch", max_depth=24.0u"inch"))

# With deflection constraint
Ix_req = required_Ix_for_deflection(0.8u"kip/ft", 25.0u"ft", 29000.0u"ksi")
result = size_steel_w_beam_nlp(Mu, Vu, geom, opts; Ix_min=Ix_req)
```
"""
function size_steel_w_beam_nlp(
    Mu,
    Vu,
    geometry::SteelMemberGeometry,
    opts::NLPWOptions;
    Ix_min = nothing,
    Tu = 0.0,
    L_span = nothing,
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    problem = SteelWBeamNLPProblem(Mu, Vu, geometry, opts; Ix_min=Ix_min, Tu=Tu, L_span=L_span)
    
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )
    
    return build_w_beam_nlp_result(problem, opt_result)
end

"""
    size_steel_w_beams_nlp(Mu, Vu, geometries, opts; Ix_min) -> Vector{WColumnNLPResult}

Size multiple W-shape beams using continuous (NLP) optimization.

`Ix_min` can be a scalar (applied to all) or a vector (per beam).
"""
function size_steel_w_beams_nlp(
    Mu::Vector,
    Vu::Vector,
    geometries::Vector{<:SteelMemberGeometry},
    opts::NLPWOptions;
    Ix_min = nothing,
)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(geometries) || throw(ArgumentError("Mu and geometries must have same length"))
    
    results = Vector{WColumnNLPResult}(undef, n)
    for i in 1:n
        Ix_i = isnothing(Ix_min) ? nothing :
               (Ix_min isa AbstractVector ? Ix_min[i] : Ix_min)
        results[i] = size_steel_w_beam_nlp(Mu[i], Vu[i], geometries[i], opts; Ix_min=Ix_i)
    end
    return results
end

# ==============================================================================
# Steel HSS Beam NLP Sizing (Dedicated Beam Formulation)
# ==============================================================================

"""
    size_steel_hss_beam_nlp(Mu, Vu, opts::NLPHSSOptions; Ix_min, x0) -> HSSColumnNLPResult

Size a rectangular HSS beam using continuous (NLP) optimization with
dedicated AISC F7 flexure and G4 shear constraints.

Unlike `size_hss_nlp` (which uses H1-1 interaction with Pu=0), this
formulation directly optimizes for flexure and shear without compression
capacity calculations, producing more efficient beam sections.

# Arguments
- `Mu`: Factored moment — any moment unit
- `Vu`: Factored shear — any force unit
- `opts`: `NLPHSSOptions` with material, dimension bounds, solver settings

# Keyword Arguments
- `Ix_min`: Minimum required Ix for deflection (Length⁴ or bare in⁴). Default: `nothing`.
- `x0`: Initial guess vector (default: automatic)

# Returns
`HSSColumnNLPResult` with `.section::HSSRectSection` for analytical checks.

# Example
```julia
result = size_steel_hss_beam_nlp(60.0u"kN*m", 80.0u"kN",
    NLPHSSOptions(min_outer=4.0u"inch", max_outer=12.0u"inch"))
```
"""
function size_steel_hss_beam_nlp(
    Mu,
    Vu,
    opts::NLPHSSOptions;
    Ix_min = nothing,
    Tu = 0.0,
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    problem = SteelHSSBeamNLPProblem(Mu, Vu, opts; Ix_min=Ix_min, Tu=Tu)
    
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )
    
    return build_hss_beam_nlp_result(problem, opt_result)
end

"""
    size_steel_hss_beams_nlp(Mu, Vu, opts; Ix_min) -> Vector{HSSColumnNLPResult}

Size multiple HSS beams using continuous (NLP) optimization.

`Ix_min` can be a scalar (applied to all) or a vector (per beam).
"""
function size_steel_hss_beams_nlp(
    Mu::Vector,
    Vu::Vector,
    opts::NLPHSSOptions;
    Ix_min = nothing,
)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    
    results = Vector{HSSColumnNLPResult}(undef, n)
    for i in 1:n
        Ix_i = isnothing(Ix_min) ? nothing :
               (Ix_min isa AbstractVector ? Ix_min[i] : Ix_min)
        results[i] = size_steel_hss_beam_nlp(Mu[i], Vu[i], opts; Ix_min=Ix_i)
    end
    return results
end

# ==============================================================================
# RC T-Beam Sizing: Discrete (MIP)
# ==============================================================================

"""
    size_tbeams(Mu, Vu, geometries, opts::ConcreteBeamOptions;
                flange_width, flange_thickness, Nu=..., catalog_size=:standard, ...)

Size reinforced concrete T-beams using discrete catalog optimization.

Generates a catalog of `RCTBeamSection`s with fixed flange dimensions
(from slab sizing and tributary geometry) and selects the minimum-objective
section satisfying ACI 318-11 requirements.

# Arguments
- `Mu`: Vector of factored moments — any moment unit
- `Vu`: Vector of factored shears — any force unit
- `geometries`: Member geometries
- `opts`: `ConcreteBeamOptions`

# Keyword Arguments
- `flange_width`: Effective flange width (bf) — Length unit
- `flange_thickness`: Slab thickness (hf) — Length unit
- `Nu`: Vector of factored axial compressions (default: zeros). When > 0,
  the shear checker increases Vc per ACI §22.5.6.1.
- `catalog_size`: `:standard`, `:small`, `:large` (default `:standard`)
- `mip_gap`: MIP optimality gap (default 1e-4)
- `output_flag`: Solver verbosity (default 0)

# Returns
Named tuple: `(; section_indices, sections, status, objective_value)`

# Example
```julia
Mu = [200.0, 300.0] .* kip .* u"ft"
Vu = [40.0, 60.0] .* kip
geoms = [ConcreteMemberGeometry(8.0u"m") for _ in 1:2]
result = size_tbeams(Mu, Vu, geoms, ConcreteBeamOptions();
                     flange_width=48u"inch", flange_thickness=5u"inch")
```
"""
function size_tbeams(
    Mu::Vector,
    Vu::Vector,
    geometries::Vector,
    opts::ConcreteBeamOptions;
    flange_width::Length,
    flange_thickness::Length,
    Nu::Vector = zeros_like(Vu),
    Tu::Vector = Float64[],
    catalog_size::Symbol = :standard,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    w_dead = nothing,
    w_live = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Real = 2.0,
)
    n = length(Mu)
    n == length(Vu)          || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(geometries)  || throw(ArgumentError("demands and geometries must have same length"))

    # Convert geometries
    conc_geoms = [to_concrete_geometry(g) for g in geometries]

    # Build T-beam catalog
    cat = if !isnothing(opts.custom_catalog)
        opts.custom_catalog
    elseif catalog_size === :standard
        standard_rc_tbeams(flange_width=flange_width, flange_thickness=flange_thickness)
    elseif catalog_size === :small
        small_rc_tbeams(flange_width=flange_width, flange_thickness=flange_thickness)
    elseif catalog_size === :large
        large_rc_tbeams(flange_width=flange_width, flange_thickness=flange_thickness)
    else
        throw(ArgumentError("Unknown catalog_size=:$catalog_size. Use :standard, :small, or :large"))
    end

    isempty(cat) && throw(ArgumentError("T-beam catalog is empty — check flange_width/flange_thickness"))

    # Convert forces / moments
    Mu_kipft = [to_kipft(m) for m in Mu]
    Vu_kip   = [to_kip(v)   for v in Vu]
    Nu_kip   = [to_kip(n)   for n in Nu]

    # Convert torsion to kip·in (raw number)
    Tu_kipin = if isempty(Tu)
        zeros(n)
    else
        [t isa Unitful.Quantity ? abs(ustrip(kip*u"inch", t)) : abs(Float64(t)) for t in Tu]
    end

    # Build demands (Nu, Tu flow to checker via RCBeamDemand fields)
    demands = [RCBeamDemand(i; Mu=Mu_kipft[i], Vu=Vu_kip[i], Nu=Nu_kip[i], Tu=Tu_kipin[i]) for i in 1:n]

    # Convert service loads for deflection check (if provided)
    wd_kplf = if isnothing(w_dead)
        0.0
    elseif w_dead isa Unitful.Quantity
        ustrip(kip/u"ft", w_dead)
    else
        Float64(w_dead)
    end
    wl_kplf = if isnothing(w_live)
        0.0
    elseif w_live isa Unitful.Quantity
        ustrip(kip/u"ft", w_live)
    else
        Float64(w_live)
    end

    # Create checker (with optional deflection)
    checker = ACIBeamChecker(;
        fy_ksi  = ustrip(ksi, opts.rebar_grade.Fy),
        fyt_ksi = ustrip(ksi, get_transverse_rebar(opts).Fy),
        Es_ksi  = ustrip(ksi, opts.rebar_grade.E),
        λ       = opts.grade.λ,
        max_depth = opts.max_depth,
        w_dead_kplf = wd_kplf,
        w_live_kplf = wl_kplf,
        defl_support = defl_support,
        defl_ξ = Float64(defl_ξ),
    )

    return optimize_discrete(
        checker, demands, conc_geoms, cat, opts.grade;
        objective      = opts.objective,
        n_max_sections = opts.n_max_sections,
        optimizer      = opts.optimizer,
        mip_gap        = mip_gap,
        output_flag    = output_flag,
    )
end

# ==============================================================================
# RC T-Beam NLP Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_rc_tbeam_nlp(Mu, Vu, bf, hf, opts::NLPBeamOptions) -> RCTBeamNLPResult

Size a single RC T-beam using continuous (NLP) optimization.

Optimizes web width (bw), total depth (h), and reinforcement ratio (ρ) with
fixed flange dimensions. The flange width and thickness are determined by slab
sizing and tributary geometry, and are not design variables.

# Arguments
- `Mu`: Factored moment — any moment unit
- `Vu`: Factored shear — any force unit
- `bf`: Effective flange width — any length unit
- `hf`: Flange (slab) thickness — any length unit
- `opts`: `NLPBeamOptions` with material, bounds, solver settings

# Returns
`RCTBeamNLPResult` with:
- `section`: Constructed `RCTBeamSection`
- `bw_opt`, `h_opt`, `ρ_opt`: Continuous optimal values
- `bw_final`, `h_final`: Dimensions after optional snapping
- `bf`, `hf`: Fixed flange dimensions (inches)
- `area_web`: Web area bw×h (in²)
- `status`: Solver termination status

# Example
```julia
Mu = 250.0kip * u"ft"
Vu = 50.0kip
bf = 48.0u"inch"
hf = 5.0u"inch"
opts = NLPBeamOptions(min_depth=16.0u"inch", max_depth=30.0u"inch")
result = size_rc_tbeam_nlp(Mu, Vu, bf, hf, opts)
println("Section: \$(result.section.name), Web area: \$(result.area_web) in²")
```
"""
function size_rc_tbeam_nlp(
    Mu, Vu,
    bf::Length, hf::Length,
    opts::NLPBeamOptions;
    Tu = 0.0,
    x0::Union{Nothing,Vector{Float64}} = nothing,
    w_dead = nothing,
    w_live = nothing,
    L_span = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Float64 = 2.0,
)
    problem = RCTBeamNLPProblem(Mu, Vu, bf, hf, opts;
                                w_dead=w_dead, w_live=w_live, L_span=L_span,
                                support=defl_support, ξ=defl_ξ, Tu=Tu)

    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )

    return build_rc_tbeam_nlp_result(problem, opt_result)
end

"""
    size_rc_tbeams_nlp(Mu, Vu, bf, hf, opts::NLPBeamOptions) -> Vector{RCTBeamNLPResult}

Size multiple RC T-beams using continuous (NLP) optimization.

`bf` and `hf` can be scalars (shared) or vectors (per beam).

# Example
```julia
Mu = [200.0, 300.0] .* kip .* u"ft"
Vu = [40.0, 60.0] .* kip
bf = 48.0u"inch"   # shared flange width
hf = 5.0u"inch"    # shared slab thickness
results = size_rc_tbeams_nlp(Mu, Vu, bf, hf, NLPBeamOptions())
```
"""
function size_rc_tbeams_nlp(
    Mu::Vector, Vu::Vector,
    bf, hf,
    opts::NLPBeamOptions;
    w_dead = nothing,
    w_live = nothing,
    L_span = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Float64 = 2.0,
)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))

    # Allow scalar or vector bf/hf
    bf_vec = bf isa AbstractVector ? bf : fill(bf, n)
    hf_vec = hf isa AbstractVector ? hf : fill(hf, n)
    length(bf_vec) == n || throw(ArgumentError("bf vector length must match Mu"))
    length(hf_vec) == n || throw(ArgumentError("hf vector length must match Mu"))

    # Allow scalar or vector service loads / span
    wd_vec = isnothing(w_dead) ? fill(nothing, n) : (w_dead isa AbstractVector ? w_dead : fill(w_dead, n))
    wl_vec = isnothing(w_live) ? fill(nothing, n) : (w_live isa AbstractVector ? w_live : fill(w_live, n))
    Ls_vec = isnothing(L_span) ? fill(nothing, n) : (L_span isa AbstractVector ? L_span : fill(L_span, n))

    results = Vector{RCTBeamNLPResult}(undef, n)
    for i in 1:n
        results[i] = size_rc_tbeam_nlp(Mu[i], Vu[i], bf_vec[i], hf_vec[i], opts;
                                        w_dead=wd_vec[i], w_live=wl_vec[i],
                                        L_span=Ls_vec[i],
                                        defl_support=defl_support, defl_ξ=defl_ξ)
    end
    return results
end