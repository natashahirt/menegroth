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
geometry = ConcreteMemberGeometry(4.0; k=1.0)    # 4m, k=1.0
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
    # Build material tuple for P-M calculations
    mat = (
        fc = fc_ksi(opts.grade),
        fy = fy_ksi(opts.rebar_grade),
        Es = 29000.0,
        εcu = 0.003
    )
    
    # Convert demands to ACI units (kip, kip-ft)
    Pu_kip = _extract_force_kip(demand.Pu)
    Mux_kipft = _extract_moment_kipft(demand.Mux)
    Muy_kipft = _extract_moment_kipft(demand.Muy)
    
    # Convert dimension bounds to inches
    b_min = ustrip(u"inch", uconvert(u"inch", opts.min_dim))
    b_max = ustrip(u"inch", uconvert(u"inch", opts.max_dim))
    
    RCColumnNLPProblem(
        demand, geometry, opts, mat,
        Pu_kip, Mux_kipft, Muy_kipft,
        b_min, b_max
    )
end

# Helper: extract force in kip (handles both Unitful and raw Float64)
function _extract_force_kip(P)
    if P isa Unitful.Quantity
        return ustrip(kip, uconvert(kip, P))
    else
        return Float64(P)  # Assume already in kip
    end
end

# Helper: extract moment in kip-ft (handles both Unitful and raw Float64)
function _extract_moment_kipft(M)
    if M isa Unitful.Quantity
        return ustrip(kip*u"ft", uconvert(kip*u"ft", M))
    else
        return Float64(M)  # Assume already in kip-ft
    end
end

# ==============================================================================
# AbstractNLPProblem Interface: Core
# ==============================================================================

n_variables(::RCColumnNLPProblem) = 3

function variable_bounds(p::RCColumnNLPProblem)
    lb = [p.b_min, p.b_min, 0.01]   # ACI min ρ = 0.01
    ub = [p.b_max, p.b_max, 0.08]   # ACI max ρ = 0.08
    return (lb, ub)
end

function initial_guess(p::RCColumnNLPProblem)
    # Estimate from simplified axial capacity: Ag ≈ Pu / (0.40 × f'c)
    Ag_est = p.Pu_kip / (0.40 * p.mat.fc)
    c0 = sqrt(max(Ag_est, p.b_min^2))
    c0 = clamp(c0, p.b_min, p.b_max)
    return [c0, c0, 0.02]  # Start square at 2% reinforcement
end

variable_names(::RCColumnNLPProblem) = ["b (in)", "h (in)", "ρg"]

# ==============================================================================
# AbstractNLPProblem Interface: Objective
# ==============================================================================

function objective_fn(p::RCColumnNLPProblem, x::Vector{Float64})
    b, h, ρ = x
    Ag = b * h  # Gross area (sq in)
    
    # Objective depends on what we're minimizing
    obj = p.opts.objective
    
    if obj isa MinVolume
        # Just concrete area
        value = Ag
    elseif obj isa MinWeight
        # Total weight: concrete + steel
        # γ_concrete ≈ 150 pcf, γ_steel ≈ 490 pcf
        # Weight ∝ Ag × [(1-ρ) × 150 + ρ × 490] = Ag × [150 + ρ × 340]
        γ_concrete = 150.0  # pcf
        γ_steel = 490.0     # pcf
        value = Ag * ((1 - ρ) * γ_concrete + ρ * γ_steel)
    elseif obj isa MinCost
        # Total cost: concrete + rebar
        # Typical costs: concrete ~$4/ft³ (in place), rebar ~$1/lb ≈ $490/ft³
        # Cost ∝ Ag × [(1-ρ) × cost_c + ρ × cost_s]
        cost_concrete = 4.0    # $/ft³ of concrete volume
        cost_steel = 490.0     # $/ft³ of steel volume (≈ $1/lb)
        value = Ag * ((1 - ρ) * cost_concrete + ρ * cost_steel)
    elseif obj isa MinCarbon
        # Embodied carbon: concrete + steel
        # ECC concrete ≈ 400 kgCO2/m³ ≈ 11 kgCO2/ft³
        # ECC steel ≈ 1.8 kgCO2/kg ≈ 1800 kgCO2/ton ≈ 45 kgCO2/ft³
        ecc_concrete = 11.0   # kgCO2/ft³
        ecc_steel = 45.0      # kgCO2/ft³
        value = Ag * ((1 - ρ) * ecc_concrete + ρ * ecc_steel)
    else
        # Default: minimize concrete area
        value = Ag
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

function n_constraints(p::RCColumnNLPProblem)
    # 1 constraint for P-Mx, +1 for biaxial if Muy > 0
    return p.Muy_kipft > 1e-6 ? 2 : 1
end

function constraint_names(p::RCColumnNLPProblem)
    if p.Muy_kipft > 1e-6
        return ["P-Mx utilization", "biaxial utilization"]
    else
        return ["P-M utilization"]
    end
end

function constraint_bounds(p::RCColumnNLPProblem)
    nc = n_constraints(p)
    lb = fill(-Inf, nc)   # No lower bound
    ub = fill(1.0, nc)    # utilization ≤ 1.0
    return (lb, ub)
end

function constraint_fns(p::RCColumnNLPProblem, x::Vector{Float64})
    b, h, ρ = x
    
    # Build trial section
    section = _build_nlp_trial_section(b, h, ρ, p.opts)
    if isnothing(section)
        # Infeasible configuration → large constraint violation
        return fill(100.0, n_constraints(p))
    end
    
    # Generate P-M diagram (use fewer points for speed in optimization)
    diagram = generate_PM_diagram(section, p.mat; n_intermediate=8)
    
    # Apply slenderness magnification if enabled
    Mux_design = p.Mux_kipft
    if p.opts.include_slenderness
        # Use magnify_moment_nonsway with M1=M2 (conservative)
        result = magnify_moment_nonsway(
            section, p.mat, p.geometry,
            p.Pu_kip, p.Mux_kipft, p.Mux_kipft;
            βdns = p.opts.βdns
        )
        if isinf(result.δns)
            # Buckling failure → large constraint violation
            return fill(100.0, n_constraints(p))
        end
        Mux_design = result.Mc
    end
    
    # P-M capacity check
    check = check_PM_capacity(diagram, p.Pu_kip, Mux_design)
    util_x = check.utilization
    
    # Return constraints
    if p.Muy_kipft > 1e-6
        # Biaxial: Bresler load contour (Mux/φMnx)^α + (Muy/φMny)^α ≤ 1
        φMnx = max(check.φMn_at_Pu, 1e-6)
        φMny = φMnx  # Assume square or symmetric section for y-axis
        
        # For non-square sections, should use y-axis diagram
        # but for simplicity use same capacity (conservative for b < h)
        util_biax = (Mux_design/φMnx)^1.5 + (p.Muy_kipft/φMny)^1.5
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
    build_nlp_result(problem, opt_result) -> RCColumnNLPResult

Convert optimization result to `RCColumnNLPResult` with practical section.
"""
function build_nlp_result(p::RCColumnNLPProblem, opt_result)
    b_opt, h_opt, ρ_opt = opt_result.minimizer
    
    # Round to practical dimensions
    incr = ustrip(u"inch", p.opts.dim_increment)
    b_final = ceil(b_opt / incr) * incr
    h_final = ceil(h_opt / incr) * incr
    
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
    E_ksi = ustrip(ksi, opts.material.E)
    Fy_ksi = ustrip(ksi, opts.material.Fy)
    
    # Convert demands to kip, kip-ft
    Pu_kip = _to_kip_force(demand.Pu_c)
    Mux_kipft = _to_kipft_moment(demand.Mux)
    Muy_kipft = _to_kipft_moment(demand.Muy)
    
    # Effective length: KL = max(Kx*L, Ky*L) for weak axis (conservative)
    L_in = ustrip(u"inch", geometry.L * u"m")
    KL_in = max(geometry.Kx, geometry.Ky) * L_in
    
    # Convert dimension bounds to inches
    B_min = ustrip(u"inch", opts.min_outer)
    B_max = ustrip(u"inch", opts.max_outer)
    t_min = ustrip(u"inch", opts.min_thickness)
    t_max = ustrip(u"inch", opts.max_thickness)
    
    HSSColumnNLPProblem(
        demand, geometry, opts,
        E_ksi, Fy_ksi,
        Pu_kip, Mux_kipft, Muy_kipft,
        KL_in,
        B_min, B_max, t_min, t_max
    )
end

# Helper: convert force to kip
function _to_kip_force(P)
    if P isa Unitful.Quantity
        return ustrip(kip, uconvert(kip, P))
    else
        return Float64(P) / 4448.22  # Assume N → kip
    end
end

# Helper: convert moment to kip-ft
function _to_kipft_moment(M)
    if M isa Unitful.Quantity
        return ustrip(kip*u"ft", uconvert(kip*u"ft", M))
    else
        return Float64(M) / 1355.82  # Assume N·m → kip·ft
    end
end

# ==============================================================================
# AbstractNLPProblem Interface: Core
# ==============================================================================

n_variables(::HSSColumnNLPProblem) = 3

function variable_bounds(p::HSSColumnNLPProblem)
    lb = [p.B_min, p.B_min, p.t_min]
    ub = [p.B_max, p.B_max, p.t_max]
    return (lb, ub)
end

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

variable_names(::HSSColumnNLPProblem) = ["B (in)", "H (in)", "t (in)"]

# ==============================================================================
# AbstractNLPProblem Interface: Objective
# ==============================================================================

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

function n_constraints(p::HSSColumnNLPProblem)
    # Compression utilization + b/t ratio constraint
    nc = 2
    # Add flexure if moment demand exists
    if p.Mux_kipft > 1e-6 || p.Muy_kipft > 1e-6
        nc += 1
    end
    return nc
end

function constraint_names(p::HSSColumnNLPProblem)
    names = ["compression utilization", "min b/t ratio"]
    if p.Mux_kipft > 1e-6 || p.Muy_kipft > 1e-6
        push!(names, "flexure utilization")
    end
    return names
end

function constraint_bounds(p::HSSColumnNLPProblem)
    nc = n_constraints(p)
    lb = fill(-Inf, nc)
    ub = ones(nc)   # All utilizations ≤ 1.0
    return (lb, ub)
end

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
    
    # Compression capacity
    φPn = 0.9 * Fcr * Ae  # kip
    
    # Compression utilization
    util_compression = p.Pu_kip / _smooth_max(φPn, 0.001; k=k)
    
    # b/t ratio constraint (ensure fabricable)
    b = H - 3*t  # Clear height
    b_t = b / t
    # Constraint: b_t ≥ min_b_t → min_b_t - b_t ≤ 0 → (min_b_t - b_t)/min_b_t ≤ 0
    # Transform to ≤ 1 form: (min_b_t / b_t) ≤ 1
    util_bt = p.opts.min_b_t / _smooth_max(b_t, 1.0; k=k)
    
    constraints = [util_compression, util_bt]
    
    # Flexure utilization (if moment exists)
    if p.Mux_kipft > 1e-6 || p.Muy_kipft > 1e-6
        Sx, Sy = _hss_section_modulus_smooth(B, H, t)
        Zx, Zy = _hss_plastic_modulus_smooth(B, H, t)
        
        # Flexural capacity (conservative: use Mp = Fy × Z)
        φMnx = 0.9 * p.Fy_ksi * Zx / 12.0  # kip-ft
        φMny = 0.9 * p.Fy_ksi * Zy / 12.0  # kip-ft
        
        # Combined moment utilization (linear interaction)
        Mu_total = p.Mux_kipft / _smooth_max(φMnx, 0.001; k=k) + 
                   p.Muy_kipft / _smooth_max(φMny, 0.001; k=k)
        
        push!(constraints, Mu_total)
    end
    
    return constraints
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
    E_ksi = ustrip(ksi, opts.material.E)
    Fy_ksi = ustrip(ksi, opts.material.Fy)
    
    # Convert demands to kip, kip-ft
    Pu_kip = _to_kip_force(demand.Pu_c)
    Mux_kipft = _to_kipft_moment(demand.Mux)
    Muy_kipft = _to_kipft_moment(demand.Muy)
    
    # Effective lengths: KL = K*L for each axis
    L_in = ustrip(u"inch", geometry.L * u"m")
    KLx_in = geometry.Kx * L_in
    KLy_in = geometry.Ky * L_in
    
    # Convert dimension bounds to inches
    d_min = ustrip(u"inch", opts.min_depth)
    d_max = ustrip(u"inch", opts.max_depth)
    bf_min = ustrip(u"inch", opts.min_flange_width)
    bf_max = ustrip(u"inch", opts.max_flange_width)
    tf_min = ustrip(u"inch", opts.min_flange_thickness)
    tf_max = ustrip(u"inch", opts.max_flange_thickness)
    tw_min = ustrip(u"inch", opts.min_web_thickness)
    tw_max = ustrip(u"inch", opts.max_web_thickness)
    
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

n_variables(::WColumnNLPProblem) = 4

function variable_bounds(p::WColumnNLPProblem)
    lb = [p.d_min, p.bf_min, p.tf_min, p.tw_min]
    ub = [p.d_max, p.bf_max, p.tf_max, p.tw_max]
    return (lb, ub)
end

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

variable_names(::WColumnNLPProblem) = ["d (in)", "bf (in)", "tf (in)", "tw (in)"]

# ==============================================================================
# AbstractNLPProblem Interface: Objective
# ==============================================================================

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

function n_constraints(p::WColumnNLPProblem)
    nc = 4  # compression util, bf/d ratio, tf/tw ratio, web h/tw
    # Add flexure if moment demand exists
    if p.Mux_kipft > 1e-6 || p.Muy_kipft > 1e-6
        nc += 1
    end
    # Add flange compactness if required
    if p.opts.require_compact
        nc += 1
    end
    return nc
end

function constraint_names(p::WColumnNLPProblem)
    names = ["compression utilization", "bf/d ratio", "tf/tw ratio", "web slenderness"]
    if p.Mux_kipft > 1e-6 || p.Muy_kipft > 1e-6
        push!(names, "flexure utilization")
    end
    if p.opts.require_compact
        push!(names, "flange compactness")
    end
    return names
end

function constraint_bounds(p::WColumnNLPProblem)
    nc = n_constraints(p)
    lb = fill(-Inf, nc)
    ub = ones(nc)   # All utilizations ≤ 1.0
    return (lb, ub)
end

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
    # Flanges (Case 1): λr = 0.56√(E/Fy)
    λr_f = 0.56 * sqrt(p.E_ksi / p.Fy_ksi)
    # Web (Case 5): λr = 1.49√(E/Fy)
    λr_w = 1.49 * sqrt(p.E_ksi / p.Fy_ksi)
    
    # Effective area (reduce for slender elements)
    Ae = _w_effective_area_smooth(d, bf, tf, tw, p.E_ksi, p.Fy_ksi, Fcr, λf, λw, λr_f, λr_w; k=k)
    
    # Compression capacity
    φPn = 0.9 * Fcr * Ae  # kip
    
    # Constraint 1: Compression utilization
    util_compression = p.Pu_kip / _smooth_max(φPn, 0.001; k=k)
    
    # Constraint 2: bf/d proportioning
    bf_d = bf / d
    # Require bf_d_min ≤ bf/d ≤ bf_d_max
    # Transform to: max((bf_d_min/bf_d), (bf_d/bf_d_max)) ≤ 1
    util_bf_d = _smooth_max(p.opts.bf_d_min / _smooth_max(bf_d, 0.1; k=k),
                            bf_d / p.opts.bf_d_max; k=k)
    
    # Constraint 3: tf/tw proportioning
    tf_tw = tf / tw
    util_tf_tw = _smooth_max(p.opts.tf_tw_min / _smooth_max(tf_tw, 0.5; k=k),
                             tf_tw / p.opts.tf_tw_max; k=k)
    
    # Constraint 4: Web slenderness (prevent extremely slender webs)
    # Use λw / λr_w as utilization (want ≤ some limit, say 1.5 for slender OK)
    util_web = λw / (1.5 * λr_w)
    
    constraints = [util_compression, util_bf_d, util_tf_tw, util_web]
    
    # Constraint 5: Flexure utilization (if moment exists)
    if p.Mux_kipft > 1e-6 || p.Muy_kipft > 1e-6
        Zx, Zy = _w_plastic_modulus_smooth(d, bf, tf, tw)
        
        # Flexural capacity (plastic for compact, reduced for noncompact)
        φMnx = 0.9 * p.Fy_ksi * Zx / 12.0  # kip-ft
        φMny = 0.9 * p.Fy_ksi * Zy / 12.0  # kip-ft
        
        # Combined moment utilization
        util_flexure = p.Mux_kipft / _smooth_max(φMnx, 0.001; k=k) + 
                       p.Muy_kipft / _smooth_max(φMny, 0.001; k=k)
        
        push!(constraints, util_flexure)
    end
    
    # Constraint 6: Flange compactness (if required)
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
- `d_opt`, `bf_opt`, `tf_opt`, `tw_opt`: Continuous optimal values (inches)
- `d_final`, `bf_final`, `tf_final`, `tw_final`: Final dimensions (inches)
- `area`: Final cross-sectional area (sq in)
- `weight_per_ft`: Weight per linear foot (lb/ft)
- `Ix`, `Iy`: Moments of inertia (in⁴)
- `rx`, `ry`: Radii of gyration (in)
- `catalog_match`: Name of nearest catalog W section (if snap_to_catalog)
- `status`: Solver termination status
- `iterations`: Number of solver iterations
"""
struct WColumnNLPResult
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
    catalog_match::Union{String, Nothing}
    status::Symbol
    iterations::Int
end

"""
    build_w_nlp_result(problem, opt_result) -> WColumnNLPResult

Convert optimization result to `WColumnNLPResult`.
"""
function build_w_nlp_result(p::WColumnNLPProblem, opt_result)
    d_opt, bf_opt, tf_opt, tw_opt = opt_result.minimizer
    
    # Round to practical precision (1/16" increments)
    incr = 0.0625
    d_final = ceil(d_opt / incr) * incr
    bf_final = ceil(bf_opt / incr) * incr
    tf_final = ceil(tf_opt / incr) * incr
    tw_final = ceil(tw_opt / incr) * incr
    
    # Compute properties of final section
    A = _w_area_smooth(d_final, bf_final, tf_final, tw_final)
    Ix, Iy = _w_inertia_smooth(d_final, bf_final, tf_final, tw_final)
    rx = sqrt(Ix / A)
    ry = sqrt(Iy / A)
    
    # Weight per foot
    ρ_steel = 490.0  # lb/ft³
    weight_per_ft = A * ρ_steel / 144.0  # lb/ft
    
    # Find nearest catalog section if requested
    catalog_match = nothing
    if p.opts.snap_to_catalog
        catalog_match = _find_nearest_w_section(d_final, bf_final, A)
    end
    
    return WColumnNLPResult(
        d_opt, bf_opt, tf_opt, tw_opt,
        d_final, bf_final, tf_final, tw_final,
        A, weight_per_ft,
        Ix, Iy, rx, ry,
        catalog_match,
        opt_result.status,
        opt_result.iterations
    )
end

"""
    _find_nearest_w_section(d, bf, A) -> String

Find the nearest catalog W section by depth and area.
Returns the section name (e.g., "W14X90").
"""
function _find_nearest_w_section(d::Real, bf::Real, A::Real)
    # Get all W sections
    catalog = all_W()
    
    # Score each section: minimize |d_diff| + 0.5*|bf_diff| + 0.3*|A_diff_pct|
    best_score = Inf
    best_name = "W14X90"  # Default fallback
    
    for w in catalog
        d_sec = ustrip(u"inch", w.d)
        bf_sec = ustrip(u"inch", w.bf)
        A_sec = ustrip(u"inch^2", w.A)
        
        d_diff = abs(d - d_sec) / d
        bf_diff = abs(bf - bf_sec) / bf
        A_diff = abs(A - A_sec) / A
        
        score = d_diff + 0.5*bf_diff + 0.3*A_diff
        
        if score < best_score
            best_score = score
            best_name = w.name
        end
    end
    
    return best_name
end
