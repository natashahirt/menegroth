
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
    _require_nlp_objective(
        opts.objective, (MinWeight,); problem="steel W-column NLP")
    # Extract material properties in ksi
    E_ksi = to_ksi(opts.material.E)
    Fy_ksi = to_ksi(opts.material.Fy)
    
    # Convert demands to kip, kip-ft
    Pu_kip = to_kip(demand.Pu_c)
    Mux_kipft = to_kipft(demand.Mux)
    Mux_neg_kipft = to_kipft(demand.Mux_neg)
    Muy_kipft = to_kipft(demand.Muy)

    # Hogging Chapter F (Lb=L, Cb=1.0) when Mux_neg can govern.
    # Do not use deck-braced Lb for the hogging face.
    # AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
    # ENGINEERING JUDGMENT: hogging Cb=1.0 — SteelMemberGeometry has only sagging Cb.
    geometry_use = geometry
    if Mux_neg_kipft > 0 && _hogging_is_stricter(geometry)
        geometry_use = _hogging_chapter_f_geometry(geometry)
    end
    Mux_kipft = max(Mux_kipft, Mux_neg_kipft)
    
    # Effective lengths: KL = K*L for each axis
    L_in = to_inches(geometry_use.L)
    KLx_in = geometry_use.Kx * L_in
    KLy_in = geometry_use.Ky * L_in
    
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
        demand, geometry_use, opts,
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
