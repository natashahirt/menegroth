
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
    _require_nlp_objective(
        opts.objective, (MinWeight,); problem="steel HSS column NLP")
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
