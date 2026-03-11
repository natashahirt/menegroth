# ==============================================================================
# RC Column NLP Problem
# ==============================================================================
# Continuous optimization problem for RC column sizing.
# Interfaces with src/optimize/continuous_nlp.jl via AbstractNLPProblem.
#
# Design variables: [b, h, ρg] (width, depth in inches, reinforcement ratio)
# Objective: Minimize cross-sectional area (∝ volume)
# Constraints: ACI 318 P-M interaction, slenderness, reinforcement limits

using Unitful
using Asap: kip, ksi, to_kip, to_kipft, to_inches, to_sqinches

# ==============================================================================
# Problem Type
# ==============================================================================

"""
    RCColumnNLPProblem <: AbstractNLPProblem

Continuous optimization problem for RC column sizing.

Implements the `AbstractNLPProblem` interface for use with `optimize_continuous`.
Treats column dimensions (b, h) and reinforcement ratio (ρg) as continuous
design variables, finding the minimum-area section that satisfies ACI 318.

# Design Variables
- `x[1]` = b: Column width (inches)
- `x[2]` = h: Column depth (inches)  
- `x[3]` = ρg: Longitudinal reinforcement ratio (dimensionless, 0.01-0.08)

# Constraints
- P-M interaction: utilization ≤ 1.0
- Biaxial interaction (if Muy > 0): Bresler load contour ≤ 1.0

# Usage
```julia
demand = RCColumnDemand(1; Pu=500.0, Mux=200.0)  # kip, kip-ft
geometry = ConcreteMemberGeometry(4.0u"m"; k=1.0)
opts = NLPColumnOptions(grade=NWC_5000)

problem = RCColumnNLPProblem(demand, geometry, opts)
result = optimize_continuous(problem; solver=:ipopt)

b_opt, h_opt, ρ_opt = result.minimizer
```
"""
struct RCColumnNLPProblem <: AbstractNLPProblem
    demand::RCColumnDemand
    geometry::ConcreteMemberGeometry
    opts::NLPColumnOptions
    
    # Material tuple for P-M calculations (cached for efficiency)
    mat::NamedTuple{(:fc, :fy, :Es, :εcu), NTuple{4, Float64}}
    
    # Cached demand values in ACI units (kip, kip-ft)
    Pu_kip::Float64
    Mux_kipft::Float64
    Muy_kipft::Float64
    
    # Bounds in inches
    b_min::Float64
    b_max::Float64
end

"""
    RCColumnNLPProblem(demand, geometry, opts)

Construct an RC column NLP problem from demand, geometry, and options.
"""
function RCColumnNLPProblem(
    demand::RCColumnDemand,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions
)
    # Build material tuple for P-M calculations (from material types)
    mat = to_material_tuple(opts.grade, fy_ksi(opts.rebar_grade), Es_ksi(opts.rebar_grade))
    
    # Convert demands to ACI units (kip, kip-ft)
    Pu_kip = to_kip(demand.Pu)
    Mux_kipft = to_kipft(demand.Mux)
    Muy_kipft = to_kipft(demand.Muy)
    
    # Convert dimension bounds to inches
    b_min = ustrip(u"inch", opts.min_dim)
    b_max = ustrip(u"inch", opts.max_dim)
    
    RCColumnNLPProblem(
        demand, geometry, opts, mat,
        Pu_kip, Mux_kipft, Muy_kipft,
        b_min, b_max
    )
end


# ==============================================================================
# AbstractNLPProblem Interface: Core
# ==============================================================================

"""Number of design variables: b, h, ρg."""
n_variables(::RCColumnNLPProblem) = 3

"""Variable bounds for RC column NLP: [b_min, b_min, 0.01] to [b_max, b_max, ρ_max]."""
function variable_bounds(p::RCColumnNLPProblem)
    lb = [p.b_min, p.b_min, 0.01]   # ACI min ρ = 0.01
    ub = [p.b_max, p.b_max, p.opts.ρ_max]  # Practical ρ limit (default 0.06)
    return (lb, ub)
end

"""Initial guess from simplified axial capacity: start square at midrange ρ."""
function initial_guess(p::RCColumnNLPProblem)
    # Estimate from simplified axial capacity: Ag ≈ Pu / (0.40 × f'c)
    Ag_est = p.Pu_kip / (0.40 * p.mat.fc)
    c0 = sqrt(max(Ag_est, p.b_min^2))
    c0 = clamp(c0, p.b_min, p.b_max)
    return [c0, c0, 0.04]  # Start square at midrange reinforcement
end

"""Human-readable variable names for solver output."""
variable_names(::RCColumnNLPProblem) = ["b (in)", "h (in)", "ρg"]

# ==============================================================================
# AbstractNLPProblem Interface: Objective
# ==============================================================================

"""Objective function: gross area with ρ weighting per objective type (ACI 318)."""
function objective_fn(p::RCColumnNLPProblem, x::Vector{Float64})
    b, h, ρ = x
    Ag = b * h  # Gross area (sq in)
    
    # Objective depends on what we're minimizing
    obj = p.opts.objective
    
    # Every RC objective must couple ρ so the solver gets a gradient signal
    # to trade off reinforcement ratio against section size.  Without ρ in
    # the objective, ∂obj/∂ρ = 0 and Ipopt treats ρ as slack.
    
    if obj isa MinVolume
        # Gross area with constructability penalty for high reinforcement.
        # Factor (1 + 2ρ) gives ∂obj/∂ρ = 2Ag > 0 so the solver prefers
        # moderate ρ (1–3%) unless higher ρ is needed to meet P-M demands.
        # At ρ=0.01 penalty is 2%; at ρ=0.06 it's 12%.  Without this,
        # area minimization always pegs ρ at the upper bound.
        value = Ag * (1 + 2.0 * ρ)
    elseif obj isa MinWeight
        # Total weight per unit length: concrete + steel (density-weighted).
        # Steel is ~3.3× denser, so there is a genuine tradeoff: smaller Ag
        # saves weight but higher ρ adds weight.  The solver finds the optimum.
        γ_concrete = ustrip(pcf, p.opts.grade.ρ)
        γ_steel = ustrip(pcf, p.opts.rebar_grade.ρ)
        value = Ag * ((1 - ρ) * γ_concrete + ρ * γ_steel)
    elseif obj isa MinCost
        isnan(p.opts.grade.cost) && error("MinCost requires material.cost to be set (concrete grade has cost=NaN)")
        isnan(p.opts.rebar_grade.cost) && error("MinCost requires material.cost to be set (rebar grade has cost=NaN)")
        ρ_c_kgft3 = ustrip(u"kg/ft^3", p.opts.grade.ρ)
        ρ_s_kgft3 = ustrip(u"kg/ft^3", p.opts.rebar_grade.ρ)
        cost_c_vol = p.opts.grade.cost * ρ_c_kgft3
        cost_s_vol = p.opts.rebar_grade.cost * ρ_s_kgft3
        value = Ag * ((1 - ρ) * cost_c_vol + ρ * cost_s_vol)
    elseif obj isa MinCarbon
        ρ_c_kgft3 = ustrip(u"kg/ft^3", p.opts.grade.ρ)
        ρ_s_kgft3 = ustrip(u"kg/ft^3", p.opts.rebar_grade.ρ)
        ecc_concrete = p.opts.grade.ecc * ρ_c_kgft3
        ecc_steel = p.opts.rebar_grade.ecc * ρ_s_kgft3
        value = Ag * ((1 - ρ) * ecc_concrete + ρ * ecc_steel)
    else
        # Default: gross area with ρ penalty (same as MinVolume)
        value = Ag * (1 + 2.0 * ρ)
    end
    
    # Optional: penalize non-square sections
    if p.opts.prefer_square > 0
        aspect = max(b/h, h/b)
        value *= (1 + p.opts.prefer_square * (aspect - 1))
    end
    
    return value
end

# ==============================================================================
# AbstractNLPProblem Interface: Constraints
# ==============================================================================

"""Number of constraints: 1 (P-Mx) or 2 (+ biaxial Bresler) if Muy > 0."""
function n_constraints(p::RCColumnNLPProblem)
    # 1 constraint for P-Mx, +1 for biaxial if Muy > 0
    return p.Muy_kipft > 1e-6 ? 2 : 1
end

"""Human-readable constraint names for solver diagnostics."""
function constraint_names(p::RCColumnNLPProblem)
    if p.Muy_kipft > 1e-6
        return ["P-Mx utilization", "biaxial utilization"]
    else
        return ["P-M utilization"]
    end
end

"""Constraint bounds: all utilizations ≤ 1.0, no lower bound."""
function constraint_bounds(p::RCColumnNLPProblem)
    nc = n_constraints(p)
    lb = fill(-Inf, nc)   # No lower bound
    ub = fill(1.0, nc)    # utilization ≤ 1.0
    return (lb, ub)
end

"""
    constraint_fns(p::RCColumnNLPProblem, x) -> Vector{Float64}

Evaluate smooth ACI 318 P-M constraint utilizations for RC column.
Includes optional slenderness magnification and Bresler biaxial interaction.
"""
function constraint_fns(p::RCColumnNLPProblem, x::Vector{Float64})
    b, h, ρ = x

    # Effective cover to bar centroid (inches)
    db = ustrip(u"inch", rebar(p.opts.bar_size).diameter)
    cover = 1.5 + (p.opts.tie_type == :spiral ? 0.375 : 0.5) + db / 2.0

    # Slenderness magnification (smooth analytical version)
    Mux_design = p.Mux_kipft
    if p.opts.include_slenderness
        Ig = b * h^3 / 12.0   # in⁴
        Ec_ksi = 57.0 * sqrt(p.mat.fc * 1000.0)
        EI = 0.4 * Ec_ksi * Ig / (1.0 + p.opts.βdns)   # kip·in²

        Lu_in = ustrip(u"inch", p.geometry.Lu)
        k = Float64(p.geometry.k)
        Pc = π^2 * EI / (k * Lu_in)^2   # Euler buckling (kip)

        # Cm factor from end moments
        M1x = to_kipft(p.demand.M1x)
        M2x = to_kipft(p.demand.M2x)
        Cm = abs(M2x) > 1e-6 ? max(0.6 - 0.4 * M1x / M2x, 0.4) : 1.0

        denom = max(1.0 - p.Pu_kip / (0.75 * Pc), 0.001)
        δns = max(Cm / denom, 1.0)

        if δns > 50.0
            return fill(100.0, n_constraints(p))   # Buckling failure
        end
        Mux_design = δns * p.Mux_kipft
    end

    # Smooth analytical P-M utilization (replaces piecewise-linear P-M diagram)
    util_x = _smooth_rc_pm_util(b, h, ρ, p.Pu_kip, Mux_design, p.mat;
                                      cover, n_layers=10, tie_type=p.opts.tie_type)

    if p.Muy_kipft > 1e-6
        # Biaxial: Bresler load contour
        cap = _smooth_rc_pm_capacity(b, h, ρ, p.Pu_kip, p.mat;
                                           cover, n_layers=10, tie_type=p.opts.tie_type)
        φMnx = max(cap.φMn_kipft, 1e-6)
        φMny = φMnx   # Symmetric assumption (conservative for b < h)
        util_biax = (abs(Mux_design) / φMnx)^1.5 + (abs(p.Muy_kipft) / φMny)^1.5
        return [util_x, util_biax]
    else
        return [util_x]
    end
end

# ==============================================================================
# Helper: Build Trial Section from Continuous Variables
# ==============================================================================

"""
    _build_nlp_trial_section(b_in, h_in, ρg, opts) -> Union{RCColumnSection, Nothing}

Build an `RCColumnSection` from continuous design variables (b, h, ρg).

Determines the number of bars to achieve the target ρg and constructs the section.
Returns `nothing` if the configuration is invalid (e.g., too many bars for dimensions).
"""
function _build_nlp_trial_section(
    b_in::Real, h_in::Real, ρg::Real,
    opts::NLPColumnOptions
)
    try
        # Calculate required steel area
        Ag = b_in * h_in
        As_required = ρg * Ag
        
        # Get bar properties
        bar = rebar(opts.bar_size)
        As_bar = ustrip(u"inch^2", bar.A)
        
        # Calculate number of bars
        min_bars = opts.tie_type == :spiral ? 6 : 4
        n_bars_raw = As_required / As_bar
        n_bars = max(min_bars, ceil(Int, n_bars_raw))
        
        # Make even for symmetric perimeter arrangement
        n_bars = iseven(n_bars) ? n_bars : n_bars + 1
        
        # Cap at reasonable maximum
        n_bars = min(n_bars, 32)
        
        # Build section
        return RCColumnSection(
            b = b_in * u"inch",
            h = h_in * u"inch",
            bar_size = opts.bar_size,
            n_bars = n_bars,
            cover = opts.cover,
            tie_type = opts.tie_type
        )
    catch e
        # Invalid configuration (spacing too tight, etc.)
        return nothing
    end
end

# ==============================================================================
# Result Conversion
# ==============================================================================

"""
    RCColumnNLPResult

Result from RC column NLP optimization.

# Fields
- `section`: Optimized `RCColumnSection` (rounded to practical dimensions)
- `b_opt`: Optimal width from solver (inches, continuous)
- `h_opt`: Optimal depth from solver (inches, continuous)
- `ρ_opt`: Optimal reinforcement ratio (continuous)
- `b_final`: Final width after rounding (inches)
- `h_final`: Final depth after rounding (inches)
- `area`: Final cross-sectional area (sq in)
- `status`: Solver termination status
- `iterations`: Number of solver iterations/evaluations
"""
struct RCColumnNLPResult
    section::RCColumnSection
    b_opt::Float64
    h_opt::Float64
    ρ_opt::Float64
    b_final::Float64
    h_final::Float64
    area::Float64
    status::Symbol
    iterations::Int
end

"""
    build_rc_column_nlp_result(problem, opt_result) -> RCColumnNLPResult

Convert optimization result to `RCColumnNLPResult` with practical section.
"""
function build_rc_column_nlp_result(p::RCColumnNLPProblem, opt_result)
    b_opt, h_opt, ρ_opt = opt_result.minimizer
    
    if p.opts.snap
        # Round to practical dimensions
        incr = ustrip(u"inch", p.opts.dim_increment)
        b_final = ceil(b_opt / incr) * incr
        h_final = ceil(h_opt / incr) * incr
    else
        b_final = b_opt
        h_final = h_opt
    end
    
    # Build final section with rounded dimensions
    section = _build_nlp_trial_section(b_final, h_final, ρ_opt, p.opts)
    
    # If rounding made it infeasible, try increasing dimensions
    if isnothing(section)
        b_final += incr
        h_final += incr
        section = _build_nlp_trial_section(b_final, h_final, ρ_opt, p.opts)
    end
    
    # Final fallback: return the continuous solution section
    if isnothing(section)
        section = _build_nlp_trial_section(b_opt, h_opt, ρ_opt, p.opts)
        b_final, h_final = b_opt, h_opt
    end
    
    return RCColumnNLPResult(
        section,
        b_opt, h_opt, ρ_opt,
        b_final, h_final,
        b_final * h_final,
        opt_result.status,
        opt_result.iterations
    )
end

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                     HSS COLUMN NLP PROBLEM                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Continuous optimization for rectangular HSS columns.
# Uses smooth AISC functions for differentiability with ForwardDiff.
#
# Design variables: [B, H, t] (outer width, outer height, wall thickness in inches)
# Objective: Minimize cross-sectional area (∝ weight)
# Constraints: AISC 360 compression capacity, local buckling limits

"""
    HSSColumnNLPProblem <: AbstractNLPProblem

Continuous optimization problem for rectangular HSS column sizing.

Implements the `AbstractNLPProblem` interface for use with `optimize_continuous`.
Treats HSS dimensions (B, H, t) as continuous design variables, finding the
minimum-weight section that satisfies AISC 360 requirements.

Uses smooth approximations of AISC functions for compatibility with
automatic differentiation (ForwardDiff).

# Design Variables
- `x[1]` = B: Outer width (inches)
- `x[2]` = H: Outer height/depth (inches)
- `x[3]` = t: Wall thickness (inches)

# Constraints
- Compression utilization: Pu / φPn ≤ 1.0
- Flexure utilization: Mu / φMn ≤ 1.0 (if moment demand exists)
- Width-to-thickness: (B-3t)/t ≥ min_b_t (practical fabrication limit)

# Example
```julia
demand = MemberDemand(1; Pu_c=500e3, Mux=50e3)  # N, N·m
geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)  # 4m, K=1.0
opts = NLPHSSOptions(material=A992_Steel)

problem = HSSColumnNLPProblem(demand, geometry, opts)
result = optimize_continuous(problem; solver=:ipopt)

B_opt, H_opt, t_opt = result.minimizer
```
"""
struct HSSColumnNLPProblem <: AbstractNLPProblem
    demand::MemberDemand
    geometry::SteelMemberGeometry
    opts::NLPHSSOptions
    
    # Material properties (cached, in consistent units for optimization)
    E_ksi::Float64   # Elastic modulus (ksi)
    Fy_ksi::Float64  # Yield stress (ksi)
    
    # Demand values in kip, kip-ft
    Pu_kip::Float64
    Mux_kipft::Float64
    Muy_kipft::Float64
    
    # Effective length in inches
    KL_in::Float64
    
    # Bounds in inches
    B_min::Float64
    B_max::Float64
    t_min::Float64
    t_max::Float64
end

"""
    HSSColumnNLPProblem(demand, geometry, opts)

Construct an HSS column NLP problem from demand, geometry, and options.
"""
function HSSColumnNLPProblem(
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
    opts::NLPHSSOptions
)
    # Extract material properties in ksi
    E_ksi = to_ksi(opts.material.E)
    Fy_ksi = to_ksi(opts.material.Fy)
    
    # Convert demands to kip, kip-ft
    Pu_kip = to_kip(demand.Pu_c)
    Mux_kipft = to_kipft(demand.Mux)
    Muy_kipft = to_kipft(demand.Muy)
    
    L_in = to_inches(geometry.L)
    KL_in = max(geometry.Kx, geometry.Ky) * L_in
    
    # Convert dimension bounds to inches
    B_min = to_inches(opts.min_outer)
    B_max = to_inches(opts.max_outer)
    t_min = to_inches(opts.min_thickness)
    t_max = to_inches(opts.max_thickness)
    
    HSSColumnNLPProblem(
        demand, geometry, opts,
        E_ksi, Fy_ksi,
        Pu_kip, Mux_kipft, Muy_kipft,
        KL_in,
        B_min, B_max, t_min, t_max
    )
end

# ==============================================================================
# AbstractNLPProblem Interface: Core
# ==============================================================================

"""Number of design variables: B, H, t."""
n_variables(::HSSColumnNLPProblem) = 3

"""Variable bounds for HSS column NLP: [B_min, B_min, t_min] to [B_max, B_max, t_max]."""
function variable_bounds(p::HSSColumnNLPProblem)
    lb = [p.B_min, p.B_min, p.t_min]
    ub = [p.B_max, p.B_max, p.t_max]
    return (lb, ub)
end

"""Initial guess from axial capacity estimate; starts square."""
function initial_guess(p::HSSColumnNLPProblem)
    # Estimate based on axial capacity: A ≈ Pu / (0.5 × Fy)
    A_est = p.Pu_kip / (0.5 * p.Fy_ksi)  # sq in
    
    # For HSS, A ≈ 2(B+H)t - 4t²  ≈ 4B*t for square
    # → B ≈ sqrt(A_est / 4) / t_guess
    t_guess = (p.t_min + p.t_max) / 2
    B_guess = sqrt(A_est / 4) + 2*t_guess
    B_guess = clamp(B_guess, p.B_min, p.B_max)
    
    return [B_guess, B_guess, t_guess]  # Start square
end

"""Human-readable variable names for solver output."""
variable_names(::HSSColumnNLPProblem) = ["B (in)", "H (in)", "t (in)"]

# ==============================================================================
# AbstractNLPProblem Interface: Objective
# ==============================================================================

"""Objective function: HSS cross-sectional area with optional aspect penalty."""
function objective_fn(p::HSSColumnNLPProblem, x::Vector{Float64})
    B, H, t = x
    
    # Cross-sectional area (minimize weight)
    area = _hss_area_smooth(B, H, t)
    
    # Optional: penalize non-square sections
    if p.opts.prefer_square > 0
        aspect = _smooth_max(B/H, H/B; k=p.opts.smooth_k)
        area *= (1 + p.opts.prefer_square * (aspect - 1))
    end
    
    return area
end

"""
    _hss_area_smooth(B, H, t) -> Float64

Smooth HSS cross-sectional area: A = 2(B + H - 2t)t
This is already a polynomial — fully differentiable.
"""
@inline function _hss_area_smooth(B::T, H::T, t::T) where T<:Real
    return 2 * (B + H - 2*t) * t
end

# ==============================================================================
# AbstractNLPProblem Interface: Constraints
# ==============================================================================

"""Number of constraints: AISC H1-1 interaction + b/t fabrication limit."""
function n_constraints(p::HSSColumnNLPProblem)
    # H1-1 P-M interaction + b/t ratio constraint
    return 2
end

"""Human-readable constraint names for solver diagnostics."""
function constraint_names(p::HSSColumnNLPProblem)
    return ["H1-1 P-M interaction", "min b/t ratio"]
end

"""Constraint bounds: all utilizations ≤ 1.0, no lower bound."""
function constraint_bounds(p::HSSColumnNLPProblem)
    return ([-Inf, -Inf], [1.0, 1.0])
end

"""
    constraint_fns(p::HSSColumnNLPProblem, x) -> Vector{Float64}

Evaluate smooth AISC 360 constraint utilizations for HSS column at design point `x`.
Includes E1/E7 compression (with slender-element reduction), F7 flexure
(noncompact/slender web and flange), H1-1a/b P-M interaction, and b/t fabrication limit.
"""
function constraint_fns(p::HSSColumnNLPProblem, x::Vector{Float64})
    B, H, t = x
    k = p.opts.smooth_k
    
    # Geometric properties (all smooth polynomials)
    A = _hss_area_smooth(B, H, t)
    Ix, Iy = _hss_inertia_smooth(B, H, t)
    rx = sqrt(Ix / A)
    ry = sqrt(Iy / A)
    r_min = _smooth_min(rx, ry; k=k)
    
    # Slenderness
    KL_r = p.KL_in / r_min
    
    # Euler buckling stress
    Fe = _Fe_euler_smooth(p.E_ksi, KL_r)
    
    # Critical stress (smooth column curve)
    Fcr = _Fcr_column_smooth(Fe, p.Fy_ksi; k=k)
    
    # Effective area for slender elements (smooth)
    Ae = _hss_effective_area_smooth(B, H, t, p.E_ksi, p.Fy_ksi, Fcr; k=k)
    
    # Compression capacity (AISC E1)
    φPn = 0.9 * Fcr * Ae  # kip
    
    # Flexural capacity (AISC F7 for HSS — with noncompact reduction)
    Zx, Zy = _hss_plastic_modulus_smooth(B, H, t)
    Sx, Sy = _hss_section_modulus_smooth(B, H, t)
    
    Mp_x = p.Fy_ksi * Zx     # kip-in
    My_x = p.Fy_ksi * Sx     # kip-in
    Mp_y = p.Fy_ksi * Zy     # kip-in
    My_y = p.Fy_ksi * Sy     # kip-in
    
    # Flange slenderness (flat width / thickness)
    b_f = _smooth_max(B - 3*t, 0.1; k=k)
    λ_f = b_f / t
    λp_f = 1.12 * sqrt(p.E_ksi / p.Fy_ksi)   # Table B4.1b
    λr_f = 1.40 * sqrt(p.E_ksi / p.Fy_ksi)
    
    # Web slenderness (flat depth / thickness)
    h_w = _smooth_max(H - 3*t, 0.1; k=k)
    λ_w = h_w / t
    λp_w = 2.42 * sqrt(p.E_ksi / p.Fy_ksi)
    λr_w = 5.70 * sqrt(p.E_ksi / p.Fy_ksi)
    
    # Smooth noncompact reduction (F7-2 for flange, F7-3 for web)
    frac_f = _smooth_max(λ_f - λp_f, 0.0; k=k) / _smooth_max(λr_f - λp_f, 0.01; k=k)
    frac_w = _smooth_max(λ_w - λp_w, 0.0; k=k) / _smooth_max(λr_w - λp_w, 0.01; k=k)
    
    # Strong axis: take worst of flange/web reduction
    Mn_f_x = Mp_x - (Mp_x - My_x) * _smooth_min(frac_f, 1.5; k=k)
    Mn_w_x = Mp_x - (Mp_x - My_x) * _smooth_min(frac_w, 1.5; k=k)
    Mn_x = _smooth_min(Mn_f_x, Mn_w_x; k=k)
    Mn_x = _smooth_min(Mn_x, Mp_x; k=k)
    Mn_x = _smooth_max(Mn_x, 0.01; k=k)
    
    # Weak axis: same approach (conservative — flange/web roles swap but limits similar)
    Mn_f_y = Mp_y - (Mp_y - My_y) * _smooth_min(frac_f, 1.5; k=k)
    Mn_w_y = Mp_y - (Mp_y - My_y) * _smooth_min(frac_w, 1.5; k=k)
    Mn_y = _smooth_min(Mn_f_y, Mn_w_y; k=k)
    Mn_y = _smooth_min(Mn_y, Mp_y; k=k)
    Mn_y = _smooth_max(Mn_y, 0.01; k=k)
    
    # Apply conservatism factor (0.95) for smooth blending errors
    φMnx = 0.95 * 0.9 * Mn_x / 12.0  # kip-ft
    φMny = 0.95 * 0.9 * Mn_y / 12.0  # kip-ft
    
    # AISC H1-1 P-M interaction (smooth)
    # Pr/Pc
    Pr_Pc = p.Pu_kip / _smooth_max(φPn, 0.001; k=k)
    # Mr/Mc for each axis
    Mrx_Mcx = p.Mux_kipft / _smooth_max(φMnx, 0.001; k=k)
    Mry_Mcy = p.Muy_kipft / _smooth_max(φMny, 0.001; k=k)
    
    # Smooth H1-1a/b transition:
    #   If Pr/Pc ≥ 0.2:  interaction = Pr/Pc + 8/9*(Mrx/Mcx + Mry/Mcy)   [H1-1a]
    #   If Pr/Pc <  0.2:  interaction = Pr/(2*Pc) + Mrx/Mcx + Mry/Mcy     [H1-1b]
    # Use smooth step to blend:
    α = _smooth_step(Pr_Pc, 0.2; k=k)
    interaction_a = Pr_Pc + (8.0/9.0) * (Mrx_Mcx + Mry_Mcy)
    interaction_b = Pr_Pc / 2.0 + (Mrx_Mcx + Mry_Mcy)
    util_h1 = α * interaction_a + (1 - α) * interaction_b
    
    # Apply conservatism factor (1.03) to account for accumulated smooth
    # approximation errors in compression, flexure, and H1-1 blending.
    # This effectively requires H1-1 ≤ 0.97, ensuring exact check ≤ 1.0.
    util_h1 *= 1.03
    
    # b/t ratio constraint (ensure fabricable)
    b = H - 3*t  # Clear height
    b_t = b / t
    util_bt = p.opts.min_b_t / _smooth_max(b_t, 1.0; k=k)
    
    return [util_h1, util_bt]
end

# ==============================================================================
# Smooth HSS Geometric Properties
# ==============================================================================

"""
    _hss_inertia_smooth(B, H, t) -> (Ix, Iy)

Smooth moments of inertia for rectangular HSS.
Ix = (BH³ - (B-2t)(H-2t)³) / 12
Iy = (HB³ - (H-2t)(B-2t)³) / 12
"""
@inline function _hss_inertia_smooth(B::T, H::T, t::T) where T<:Real
    Ix = (B * H^3 - (B - 2*t) * (H - 2*t)^3) / 12
    Iy = (H * B^3 - (H - 2*t) * (B - 2*t)^3) / 12
    return (Ix, Iy)
end

"""
    _hss_section_modulus_smooth(B, H, t) -> (Sx, Sy)

Elastic section modulus: S = I / c
"""
@inline function _hss_section_modulus_smooth(B::T, H::T, t::T) where T<:Real
    Ix, Iy = _hss_inertia_smooth(B, H, t)
    Sx = Ix / (H / 2)
    Sy = Iy / (B / 2)
    return (Sx, Sy)
end

"""
    _hss_plastic_modulus_smooth(B, H, t) -> (Zx, Zy)

Plastic section modulus for rectangular HSS.
Zx = BH²/4 - (B-2t)(H-2t)²/4
"""
@inline function _hss_plastic_modulus_smooth(B::T, H::T, t::T) where T<:Real
    Zx = B * H^2 / 4 - (B - 2*t) * (H - 2*t)^2 / 4
    Zy = H * B^2 / 4 - (H - 2*t) * (B - 2*t)^2 / 4
    return (Zx, Zy)
end

"""
    _hss_effective_area_smooth(B, H, t, E, Fy, Fcr; k=20.0) -> Float64

Smooth effective area for HSS compression per AISC E7.

For slender walls (λ > λr), applies effective width reduction using
smooth approximations of the piecewise AISC formulas.
"""
function _hss_effective_area_smooth(B::T, H::T, t::T, E::T, Fy::T, Fcr::T; k::Real=20.0) where T<:Real
    # Gross area
    A = _hss_area_smooth(B, H, t)
    
    # Clear dimensions (AISC: b = B - 3t)
    b_clear = B - 3*t  # Flange (shorter wall)
    h_clear = H - 3*t  # Web (taller wall)
    
    # Slenderness ratios
    λ_f = b_clear / t
    λ_w = h_clear / t
    
    # Slenderness limit for compression (Table B4.1a Case 6)
    λr = 1.40 * sqrt(E / Fy)
    
    # E7.1 constants for stiffened elements
    c1 = 0.18
    c2 = 1.31
    
    # Smooth effective width calculation
    # For each wall: if λ > λr, reduce width
    
    # Flanges (two walls of width b_clear)
    ΔA_f = _smooth_effective_width_reduction(b_clear, t, λ_f, λr, Fy, Fcr, c1, c2; k=k)
    
    # Webs (two walls of height h_clear)  
    ΔA_w = _smooth_effective_width_reduction(h_clear, t, λ_w, λr, Fy, Fcr, c1, c2; k=k)
    
    # Effective area
    Ae = A - 2*ΔA_f - 2*ΔA_w
    
    # Ensure positive (smooth clamp)
    return _smooth_max(Ae, 0.01 * A; k=k)
end

"""
    _smooth_effective_width_reduction(b, t, λ, λr, Fy, Fcr, c1, c2; k) -> Float64

Smooth calculation of area reduction due to effective width per AISC E7.

Returns ΔA = (b - be) × t, the area reduction for one wall.
Uses smooth transition at λ = λr boundary.
"""
function _smooth_effective_width_reduction(b::T, t::T, λ::T, λr::T, Fy::T, Fcr::T, 
                                            c1::Real, c2::Real; k::Real=20.0) where T<:Real
    # Sigmoid: 1 when λ > λr (slender), 0 when λ ≤ λr (compact/noncompact)
    slender_mask = _smooth_step(λ, λr; k=k)
    
    # Elastic local buckling stress (E7-5)
    # Fel = (c2 × λr / λ)² × Fy
    # Use smooth_max to avoid division issues
    λ_safe = _smooth_max(λ, 1.0; k=k)
    Fel = (c2 * λr / λ_safe)^2 * Fy
    
    # Effective width ratio (E7-3)
    # be/b = √(Fel/Fcr) × (1 - c1×√(Fel/Fcr))
    Fcr_safe = _smooth_max(Fcr, 0.01 * Fy; k=k)
    ratio = sqrt(Fel / Fcr_safe)
    be_over_b = ratio * (1 - c1 * ratio)
    
    # Clamp to [0, 1]
    be_over_b = _smooth_clamp(be_over_b, zero(T), one(T); k=k)
    
    # Effective width
    be = b * be_over_b
    
    # Area reduction (only when slender)
    ΔA = slender_mask * (b - be) * t
    
    return ΔA
end

# ==============================================================================
# HSS NLP Result
# ==============================================================================

"""
    HSSColumnNLPResult

Result from HSS column NLP optimization.

# Fields
- `section`: Optimized `HSSRectSection` (rounded to standard sizes)
- `B_opt`, `H_opt`, `t_opt`: Continuous optimal values (inches)
- `B_final`, `H_final`, `t_final`: Final dimensions after rounding (inches)
- `area`: Final cross-sectional area (sq in)
- `weight_per_ft`: Weight per linear foot (lb/ft)
- `status`: Solver termination status
- `iterations`: Number of solver iterations
"""
struct HSSColumnNLPResult
    section::HSSRectSection
    B_opt::Float64
    H_opt::Float64
    t_opt::Float64
    B_final::Float64
    H_final::Float64
    t_final::Float64
    area::Float64
    weight_per_ft::Float64
    status::Symbol
    iterations::Int
end

"""
    build_hss_nlp_result(problem, opt_result) -> HSSColumnNLPResult

Convert optimization result to `HSSColumnNLPResult` with practical section.
"""
function build_hss_nlp_result(p::HSSColumnNLPProblem, opt_result)
    B_opt, H_opt, t_opt = opt_result.minimizer
    
    if p.opts.snap
        # Round to practical dimensions
        outer_incr = ustrip(u"inch", p.opts.outer_increment)
        t_incr = ustrip(u"inch", p.opts.thickness_increment)
        
        B_final = ceil(B_opt / outer_incr) * outer_incr
        H_final = ceil(H_opt / outer_incr) * outer_incr
        t_final = ceil(t_opt / t_incr) * t_incr
        
        # Ensure thickness doesn't exceed wall (practical limit)
        max_t = min(B_final, H_final) / 4
        t_final = min(t_final, max_t)
        t_final = max(t_final, p.t_min)
    else
        B_final = B_opt
        H_final = H_opt
        t_final = t_opt
    end
    
    # Build final section
    section = HSSRectSection(H_final * u"inch", B_final * u"inch", t_final * u"inch")
    
    # Calculate area and weight
    area = ustrip(u"inch^2", section.A)
    ρ_steel = 490.0  # lb/ft³
    weight_per_ft = area * ρ_steel / 144.0  # lb/ft
    
    return HSSColumnNLPResult(
        section,
        B_opt, H_opt, t_opt,
        B_final, H_final, t_final,
        area, weight_per_ft,
        opt_result.status,
        opt_result.iterations
    )
end

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                      W SECTION COLUMN NLP PROBLEM                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Continuous optimization for W (wide flange) section columns.
# Parameterizes the I-shape with 4 dimensions: d, bf, tf, tw.
# Uses smooth AISC functions for differentiability with ForwardDiff.
#
# Design variables: [d, bf, tf, tw] (depth, flange width, flange thickness, web thickness)
# Objective: Minimize cross-sectional area (∝ weight)
# Constraints: AISC 360 compression/flexure capacity, local buckling limits, proportions

"""
    WColumnNLPProblem <: AbstractNLPProblem

Continuous optimization problem for W section (wide flange) column sizing.

Implements the `AbstractNLPProblem` interface for use with `optimize_continuous`.
Treats the W section as a parameterized I-shape with 4 continuous design variables,
finding the minimum-weight section that satisfies AISC 360 requirements.

Uses smooth approximations of AISC functions for compatibility with
automatic differentiation (ForwardDiff).

# Design Variables
- `x[1]` = d: Overall depth (inches)
- `x[2]` = bf: Flange width (inches)
- `x[3]` = tf: Flange thickness (inches)
- `x[4]` = tw: Web thickness (inches)

# Constraints
- Compression utilization: Pu / φPn ≤ 1.0
- Flexure utilization: Mu / φMn ≤ 1.0 (if moment demand exists)
- Flange compactness: λf ≤ λpf (if require_compact)
- Web compactness: λw ≤ λpw (if require_compact)
- Proportioning: bf_d_min ≤ bf/d ≤ bf_d_max
- Proportioning: tf_tw_min ≤ tf/tw ≤ tf_tw_max

# Example
```julia
demand = MemberDemand(1; Pu_c=1000e3, Mux=100e3)  # N, N·m
geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)  # 4m, K=1.0
opts = NLPWOptions(material=A992_Steel)

problem = WColumnNLPProblem(demand, geometry, opts)
result = optimize_continuous(problem; solver=:ipopt)

d_opt, bf_opt, tf_opt, tw_opt = result.minimizer
```
"""
struct WColumnNLPProblem <: AbstractNLPProblem
    demand::MemberDemand
    geometry::SteelMemberGeometry
    opts::NLPWOptions
    
    # Material properties (cached, in ksi)
    E_ksi::Float64
    Fy_ksi::Float64
    
    # Demand values in kip, kip-ft
    Pu_kip::Float64
    Mux_kipft::Float64
    Muy_kipft::Float64
    
    # Effective length in inches
    KLx_in::Float64
    KLy_in::Float64
    
    # Bounds in inches
    d_min::Float64
    d_max::Float64
    bf_min::Float64
    bf_max::Float64
    tf_min::Float64
    tf_max::Float64
    tw_min::Float64
    tw_max::Float64
end

"""
    WColumnNLPProblem(demand, geometry, opts)

Construct a W column NLP problem from demand, geometry, and options.
"""
function WColumnNLPProblem(
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
    opts::NLPWOptions
)
    # Extract material properties in ksi
    E_ksi = to_ksi(opts.material.E)
    Fy_ksi = to_ksi(opts.material.Fy)
    
    # Convert demands to kip, kip-ft
    Pu_kip = to_kip(demand.Pu_c)
    Mux_kipft = to_kipft(demand.Mux)
    Muy_kipft = to_kipft(demand.Muy)
    
    # Effective lengths: KL = K*L for each axis
    L_in = to_inches(geometry.L)
    KLx_in = geometry.Kx * L_in
    KLy_in = geometry.Ky * L_in
    
    # Convert dimension bounds to inches
    d_min = to_inches(opts.min_depth)
    d_max = to_inches(opts.max_depth)
    bf_min = to_inches(opts.min_flange_width)
    bf_max = to_inches(opts.max_flange_width)
    tf_min = to_inches(opts.min_flange_thickness)
    tf_max = to_inches(opts.max_flange_thickness)
    tw_min = to_inches(opts.min_web_thickness)
    tw_max = to_inches(opts.max_web_thickness)
    
    WColumnNLPProblem(
        demand, geometry, opts,
        E_ksi, Fy_ksi,
        Pu_kip, Mux_kipft, Muy_kipft,
        KLx_in, KLy_in,
        d_min, d_max, bf_min, bf_max, tf_min, tf_max, tw_min, tw_max
    )
end

# ==============================================================================
# AbstractNLPProblem Interface: Core
# ==============================================================================

"""Number of design variables: d, bf, tf, tw."""
n_variables(::WColumnNLPProblem) = 4

"""Variable bounds for W column NLP: depth, flange width, flange/web thickness."""
function variable_bounds(p::WColumnNLPProblem)
    lb = [p.d_min, p.bf_min, p.tf_min, p.tw_min]
    ub = [p.d_max, p.bf_max, p.tf_max, p.tw_max]
    return (lb, ub)
end

"""Initial guess from axial capacity estimate with typical W proportions."""
function initial_guess(p::WColumnNLPProblem)
    # Estimate based on axial capacity: A ≈ Pu / (0.5 × Fy)
    A_est = p.Pu_kip / (0.5 * p.Fy_ksi)  # sq in
    
    # Start with typical W section proportions
    # For moderate columns: d ≈ 14", bf/d ≈ 0.7, tf ≈ 0.6", tw ≈ 0.4"
    d_guess = clamp(14.0, p.d_min, p.d_max)
    bf_guess = clamp(0.7 * d_guess, p.bf_min, p.bf_max)
    
    # Estimate tf and tw from area: A ≈ 2*bf*tf + (d-2tf)*tw
    # Simplify: A ≈ 2*bf*tf + d*tw, assume tf ≈ 1.5*tw
    # A ≈ 2*bf*1.5*tw + d*tw = tw*(3*bf + d)
    tw_guess = A_est / (3*bf_guess + d_guess)
    tw_guess = clamp(tw_guess, p.tw_min, p.tw_max)
    tf_guess = clamp(1.5 * tw_guess, p.tf_min, p.tf_max)
    
    return [d_guess, bf_guess, tf_guess, tw_guess]
end

"""Human-readable variable names for solver output."""
variable_names(::WColumnNLPProblem) = ["d (in)", "bf (in)", "tf (in)", "tw (in)"]

# ==============================================================================
# AbstractNLPProblem Interface: Objective
# ==============================================================================

"""Objective function: W section cross-sectional area (minimize weight)."""
function objective_fn(p::WColumnNLPProblem, x::Vector{Float64})
    d, bf, tf, tw = x
    # Cross-sectional area (minimize weight)
    return _w_area_smooth(d, bf, tf, tw)
end

"""
    _w_area_smooth(d, bf, tf, tw) -> Float64

Smooth W section cross-sectional area.
A = 2*bf*tf + (d - 2*tf)*tw
"""
@inline function _w_area_smooth(d::T, bf::T, tf::T, tw::T) where T<:Real
    return 2*bf*tf + (d - 2*tf)*tw
end

# ==============================================================================
# AbstractNLPProblem Interface: Constraints
# ==============================================================================

"""Number of constraints: 4 base + optional flange compactness."""
function n_constraints(p::WColumnNLPProblem)
    nc = 4  # H1-1 interaction, bf/d ratio, tf/tw ratio, web h/tw
    # Add flange compactness if required
    if p.opts.require_compact
        nc += 1
    end
    return nc
end

"""Human-readable constraint names for solver diagnostics."""
function constraint_names(p::WColumnNLPProblem)
    names = ["H1-1 P-M interaction", "bf/d ratio", "tf/tw ratio", "web slenderness"]
    if p.opts.require_compact
        push!(names, "flange compactness")
    end
    return names
end

"""Constraint bounds: all utilizations ≤ 1.0, no lower bound."""
function constraint_bounds(p::WColumnNLPProblem)
    nc = n_constraints(p)
    lb = fill(-Inf, nc)
    ub = ones(nc)   # All utilizations ≤ 1.0
    return (lb, ub)
end

"""
    constraint_fns(p::WColumnNLPProblem, x) -> Vector{Float64}

Evaluate smooth AISC 360 constraint utilizations for W column at design point `x`.
Includes E1/E7 compression with LTB flexure (F2), H1-1a/b P-M interaction,
bf/d and tf/tw proportioning, web slenderness, and optional flange compactness.
"""
function constraint_fns(p::WColumnNLPProblem, x::Vector{Float64})
    d, bf, tf, tw = x
    k = p.opts.smooth_k
    
    # Geometric properties (all smooth)
    A = _w_area_smooth(d, bf, tf, tw)
    Ix, Iy = _w_inertia_smooth(d, bf, tf, tw)
    rx = sqrt(Ix / A)
    ry = sqrt(Iy / A)
    
    # Slenderness for both axes
    KLx_rx = p.KLx_in / rx
    KLy_ry = p.KLy_in / ry
    KL_r_gov = _smooth_max(KLx_rx, KLy_ry; k=k)
    
    # Euler buckling stress (governing axis)
    Fe = _Fe_euler_smooth(p.E_ksi, KL_r_gov)
    
    # Critical stress (smooth column curve)
    Fcr = _Fcr_column_smooth(Fe, p.Fy_ksi; k=k)
    
    # For W sections, check local buckling of flanges and web
    # Flange slenderness: λf = bf / (2*tf)
    λf = bf / (2*tf)
    # Web slenderness: λw = (d - 2*tf - 2*k_fillet) / tw ≈ (d - 2*tf) / tw
    h = d - 2*tf
    λw = h / tw
    
    # Slenderness limits for compression (Table B4.1a)
    λr_f = 0.56 * sqrt(p.E_ksi / p.Fy_ksi)
    λr_w = 1.49 * sqrt(p.E_ksi / p.Fy_ksi)
    
    # Effective area (reduce for slender elements)
    Ae = _w_effective_area_smooth(d, bf, tf, tw, p.E_ksi, p.Fy_ksi, Fcr, λf, λw, λr_f, λr_w; k=k)
    
    # Compression capacity (AISC E1)
    φPn = 0.9 * Fcr * Ae  # kip
    
    # Flexural capacity (AISC F2 — with smooth LTB for beam-columns)
    Zx, Zy = _w_plastic_modulus_smooth(d, bf, tf, tw)
    Sx = Ix / (d / 2)               # Elastic section modulus (in³)
    ho = d - tf                      # Distance between flange centroids
    
    # Torsion constant  J ≈ (2 bf tf³ + h tw³) / 3
    J = (2*bf*tf^3 + _smooth_max(h, 0.1; k=k)*tw^3) / 3
    
    # rts (effective radius of gyration for LTB)
    rts_sq = Iy * _smooth_max(ho, 0.1; k=k) / (2 * _smooth_max(Sx, 0.01; k=k))
    rts = sqrt(_smooth_max(rts_sq, 0.01; k=k))
    
    # Mp (kip-in)
    Mp_x = p.Fy_ksi * Zx
    
    # Limiting unbraced lengths (AISC F2-5, F2-6)
    Lp = 1.76 * ry * sqrt(p.E_ksi / p.Fy_ksi)
    
    jc_term = J / (_smooth_max(Sx, 0.01; k=k) * _smooth_max(ho, 0.1; k=k))
    Lr_inner = jc_term + sqrt(jc_term^2 + 6.76 * (0.7 * p.Fy_ksi / p.E_ksi)^2)
    Lr = 1.95 * rts * (p.E_ksi / (0.7 * p.Fy_ksi)) * sqrt(Lr_inner)
    
    # Unbraced length for LTB: use column height from geometry (conservative)
    Lb_in = to_inches(p.geometry.Lb)
    
    # Elastic LTB critical stress (AISC F2-4)  — Cb = 1.0 for columns
    Lb_rts = Lb_in / _smooth_max(rts, 0.01; k=k)
    Fcr_ltb = π^2 * p.E_ksi / _smooth_max(Lb_rts^2, 0.01; k=k) *
              sqrt(1 + 0.078 * jc_term * Lb_rts^2)
    
    # Three-zone smooth blending (no Cb benefit for columns)
    Lb_frac = _smooth_max(Lb_in - Lp, 0.0; k=k) / _smooth_max(Lr - Lp, 0.01; k=k)
    Lb_frac_clamped = _smooth_min(Lb_frac, 1.0; k=k)
    Mn_inelastic_x = Mp_x - (Mp_x - 0.7*p.Fy_ksi*Sx) * Lb_frac_clamped
    Mn_elastic_x = Fcr_ltb * Sx
    
    Mn_x = _smooth_min(_smooth_min(Mn_inelastic_x, Mn_elastic_x; k=k), Mp_x; k=k)
    
    # Apply conservatism factor (0.95) for smooth blending at LTB transitions
    φMnx = 0.95 * 0.9 * Mn_x / 12.0   # kip-ft
    
    # Weak axis: no LTB, use Mp (conservative)
    φMny = 0.9 * p.Fy_ksi * Zy / 12.0  # kip-ft
    
    # AISC H1-1 P-M interaction (smooth)
    Pr_Pc = p.Pu_kip / _smooth_max(φPn, 0.001; k=k)
    Mrx_Mcx = p.Mux_kipft / _smooth_max(φMnx, 0.001; k=k)
    Mry_Mcy = p.Muy_kipft / _smooth_max(φMny, 0.001; k=k)
    
    # Smooth H1-1a/b transition
    α = _smooth_step(Pr_Pc, 0.2; k=k)
    interaction_a = Pr_Pc + (8.0/9.0) * (Mrx_Mcx + Mry_Mcy)
    interaction_b = Pr_Pc / 2.0 + (Mrx_Mcx + Mry_Mcy)
    util_h1 = α * interaction_a + (1 - α) * interaction_b
    
    # Apply conservatism factor (1.03) to account for accumulated smooth
    # approximation errors in compression, flexure, and H1-1 blending.
    util_h1 *= 1.03
    
    # Constraint 2: bf/d proportioning
    bf_d = bf / d
    util_bf_d = _smooth_max(p.opts.bf_d_min / _smooth_max(bf_d, 0.1; k=k),
                            bf_d / p.opts.bf_d_max; k=k)
    
    # Constraint 3: tf/tw proportioning
    tf_tw = tf / tw
    util_tf_tw = _smooth_max(p.opts.tf_tw_min / _smooth_max(tf_tw, 0.5; k=k),
                             tf_tw / p.opts.tf_tw_max; k=k)
    
    # Constraint 4: Web slenderness
    util_web = λw / (1.5 * λr_w)
    
    constraints = [util_h1, util_bf_d, util_tf_tw, util_web]
    
    # Constraint 5: Flange compactness (if required)
    if p.opts.require_compact
        λpf = 0.38 * sqrt(p.E_ksi / p.Fy_ksi)
        util_flange_compact = λf / λpf
        push!(constraints, util_flange_compact)
    end
    
    return constraints
end

# ==============================================================================
# Smooth W Section Geometric Properties
# ==============================================================================

"""
    _w_inertia_smooth(d, bf, tf, tw) -> (Ix, Iy)

Smooth moments of inertia for W section.
Ix = bf*d³/12 - (bf-tw)*(d-2*tf)³/12  (hollow I-shape approximation)
Iy = 2*(tf*bf³/12) + (d-2*tf)*tw³/12
"""
@inline function _w_inertia_smooth(d::T, bf::T, tf::T, tw::T) where T<:Real
    h = d - 2*tf  # Web height
    
    # Ix: moment of inertia about strong axis
    # Use parallel axis theorem: Ix = Ix_flanges + Ix_web
    # Flanges: 2 × [bf*tf³/12 + bf*tf*(d/2 - tf/2)²]
    Ix_flanges = 2 * (bf*tf^3/12 + bf*tf*(d/2 - tf/2)^2)
    Ix_web = tw * h^3 / 12
    Ix = Ix_flanges + Ix_web
    
    # Iy: moment of inertia about weak axis
    # Flanges dominate: 2 × tf*bf³/12
    Iy_flanges = 2 * tf * bf^3 / 12
    Iy_web = h * tw^3 / 12
    Iy = Iy_flanges + Iy_web
    
    return (Ix, Iy)
end

"""
    _w_section_modulus_smooth(d, bf, tf, tw) -> (Sx, Sy)

Elastic section modulus: S = I / c
"""
@inline function _w_section_modulus_smooth(d::T, bf::T, tf::T, tw::T) where T<:Real
    Ix, Iy = _w_inertia_smooth(d, bf, tf, tw)
    Sx = Ix / (d / 2)
    Sy = Iy / (bf / 2)
    return (Sx, Sy)
end

"""
    _w_plastic_modulus_smooth(d, bf, tf, tw) -> (Zx, Zy)

Plastic section modulus for W section.
Zx = bf*tf*(d-tf) + tw*(d-2*tf)²/4
Zy = bf²*tf/2 + (d-2*tf)*tw²/4
"""
@inline function _w_plastic_modulus_smooth(d::T, bf::T, tf::T, tw::T) where T<:Real
    h = d - 2*tf  # Web height
    
    # Zx: plastic modulus about strong axis
    # Flanges contribute: bf*tf at arm (d-tf)/2 from neutral axis, so 2×bf*tf×(d-tf)/2 = bf*tf*(d-tf)
    # Web contributes: tw*h²/4 (rectangular)
    Zx = bf*tf*(d - tf) + tw*h^2/4
    
    # Zy: plastic modulus about weak axis
    # Flanges: 2 × (bf/2)*tf × (bf/4) × 2 = bf²*tf/2
    # Web: (h/2)*tw × (tw/4) × 2 ≈ h*tw²/4
    Zy = bf^2*tf/2 + h*tw^2/4
    
    return (Zx, Zy)
end

"""
    _w_effective_area_smooth(d, bf, tf, tw, E, Fy, Fcr, λf, λw, λr_f, λr_w; k) -> Float64

Smooth effective area for W section compression per AISC E7.

Applies effective width reduction for slender flanges and/or web.
"""
function _w_effective_area_smooth(d::T, bf::T, tf::T, tw::T, E::T, Fy::T, Fcr::T,
                                   λf::T, λw::T, λr_f::T, λr_w::T; k::Real=20.0) where T<:Real
    h = d - 2*tf
    
    # Gross area
    A = _w_area_smooth(d, bf, tf, tw)
    
    # E7.1 constants for unstiffened elements (flanges)
    c1_f = 0.22
    c2_f = 1.49
    
    # E7.1 constants for stiffened elements (web)  
    c1_w = 0.18
    c2_w = 1.31
    
    # Flange effective width reduction
    # For W flanges, b = bf/2 (half-flange width, unstiffened)
    b_flange = bf / 2
    ΔA_f = _smooth_effective_width_reduction_unstiffened(b_flange, tf, λf, λr_f, Fy, Fcr, c1_f, c2_f; k=k)
    # Two half-flanges per flange, two flanges total
    ΔA_flanges = 4 * ΔA_f
    
    # Web effective width reduction (stiffened element)
    ΔA_web = _smooth_effective_width_reduction(h, tw, λw, λr_w, Fy, Fcr, c1_w, c2_w; k=k)
    
    # Effective area
    Ae = A - ΔA_flanges - ΔA_web
    
    # Ensure positive
    return _smooth_max(Ae, 0.1 * A; k=k)
end

"""
    _smooth_effective_width_reduction_unstiffened(b, t, λ, λr, Fy, Fcr, c1, c2; k) -> Float64

Smooth effective width reduction for unstiffened elements (W flanges).
"""
function _smooth_effective_width_reduction_unstiffened(b::T, t::T, λ::T, λr::T, Fy::T, Fcr::T,
                                                        c1::Real, c2::Real; k::Real=20.0) where T<:Real
    # Sigmoid: 1 when λ > λr (slender), 0 when λ ≤ λr
    slender_mask = _smooth_step(λ, λr; k=k)
    
    # Elastic local buckling stress (E7-5 style for unstiffened)
    λ_safe = _smooth_max(λ, 1.0; k=k)
    Fel = (c2 * λr / λ_safe)^2 * Fy
    
    # Effective width ratio (E7-3 style)
    Fcr_safe = _smooth_max(Fcr, 0.01 * Fy; k=k)
    ratio = sqrt(Fel / Fcr_safe)
    be_over_b = ratio * (1 - c1 * ratio)
    be_over_b = _smooth_clamp(be_over_b, zero(T), one(T); k=k)
    
    # Area reduction
    be = b * be_over_b
    ΔA = slender_mask * (b - be) * t
    
    return ΔA
end

# ==============================================================================
# W Section NLP Result
# ==============================================================================

"""
    WColumnNLPResult

Result from W section column NLP optimization.

# Fields
- `section`: Constructed `ISymmSection` from optimized dimensions
- `d_opt`, `bf_opt`, `tf_opt`, `tw_opt`: Continuous optimal values (inches)
- `d_final`, `bf_final`, `tf_final`, `tw_final`: Final dimensions (inches)
- `area`: Final cross-sectional area (sq in)
- `weight_per_ft`: Weight per linear foot (lb/ft)
- `Ix`, `Iy`: Moments of inertia (in⁴)
- `rx`, `ry`: Radii of gyration (in)
- `status`: Solver termination status
- `iterations`: Number of solver iterations
"""
struct WColumnNLPResult
    section::ISymmSection
    d_opt::Float64
    bf_opt::Float64
    tf_opt::Float64
    tw_opt::Float64
    d_final::Float64
    bf_final::Float64
    tf_final::Float64
    tw_final::Float64
    area::Float64
    weight_per_ft::Float64
    Ix::Float64
    Iy::Float64
    rx::Float64
    ry::Float64
    status::Symbol
    iterations::Int
end

"""
    build_w_nlp_result(problem, opt_result) -> WColumnNLPResult

Convert optimization result to `WColumnNLPResult`.
"""
function build_w_nlp_result(p::WColumnNLPProblem, opt_result)
    d_opt, bf_opt, tf_opt, tw_opt = opt_result.minimizer
    
    if p.opts.snap
        # Round to practical precision (1/16" increments)
        incr = 0.0625
        d_final = ceil(d_opt / incr) * incr
        bf_final = ceil(bf_opt / incr) * incr
        tf_final = ceil(tf_opt / incr) * incr
        tw_final = ceil(tw_opt / incr) * incr
    else
        d_final = d_opt
        bf_final = bf_opt
        tf_final = tf_opt
        tw_final = tw_opt
    end
    
    # Build ISymmSection from final dimensions (convert inches → Unitful)
    section = ISymmSection(
        d_final * u"inch", bf_final * u"inch",
        tw_final * u"inch", tf_final * u"inch";
        name = "NLP-W d=$(round(d_final, digits=2)) bf=$(round(bf_final, digits=2))",
        material = p.opts.material,
    )
    
    # Compute properties of final section
    A = _w_area_smooth(d_final, bf_final, tf_final, tw_final)
    Ix, Iy = _w_inertia_smooth(d_final, bf_final, tf_final, tw_final)
    rx = sqrt(Ix / A)
    ry = sqrt(Iy / A)
    
    # Weight per foot
    ρ_steel = 490.0  # lb/ft³
    weight_per_ft = A * ρ_steel / 144.0  # lb/ft
    
    return WColumnNLPResult(
        section,
        d_opt, bf_opt, tf_opt, tw_opt,
        d_final, bf_final, tf_final, tw_final,
        A, weight_per_ft,
        Ix, Iy, rx, ry,
        opt_result.status,
        opt_result.iterations
    )
end
