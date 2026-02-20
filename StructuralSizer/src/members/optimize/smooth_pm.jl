# ==============================================================================
# Smooth P-M Interaction for RC Column NLP
# ==============================================================================
# Analytical Whitney stress block formulation with smooth approximations.
# Replaces piecewise-linear generate_PM_diagram() + check_PM_capacity()
# for use in gradient-based NLP optimization (Ipopt).
#
# Problem: The standard P-M diagram is piecewise-linear with ~30 vertices,
# causing derivative discontinuities that prevent Ipopt convergence (reports
# ALMOST_LOCALLY_SOLVED or failed KKT at kink points).
#
# Solution: Compute P-M capacity analytically using:
#   1. Smooth steel stress clamp: log-sum-exp softmax instead of hard clip
#   2. Smooth φ factor: sigmoid transition instead of piecewise linear
#   3. Smooth abs/min: existing _smooth_min/_smooth_max from AISC utils
#   4. Bisection for neutral axis (output is smooth by implicit fn theorem)
#
# The result is C¹-continuous in all design variables (b, h, ρg or D, ρg),
# enabling reliable Ipopt convergence.
#
# Supports: Rectangular columns (b × h) and Circular columns (D)

# ==============================================================================
# Smooth Primitives (P-M specific)
# ==============================================================================
# Note: _smooth_max, _smooth_min, _smooth_step are imported from aisc/utils.jl

"""Smooth |x| ≈ softmax(x, -x). Avoids kink at x=0."""
@inline _pm_sabs(x; k::Real=200.0) = _smooth_max(x, -x; k=k)

"""
Smooth clamp of steel stress to [-fy, +fy].
Uses _smooth_min/_smooth_max (log-sum-exp) for C∞ transitions.
k_stress controls sharpness: higher = sharper clamp at ±fy.
"""
@inline function _pm_smooth_fs(ε::Float64, fy::Float64, Es::Float64;
                                k_stress::Float64=40.0)
    raw = Es * ε
    return _smooth_max(_smooth_min(raw, fy; k=k_stress), -fy; k=k_stress)
end

"""
Smooth ACI 318 φ factor for combined axial + flexure.

ACI 318-11 §9.3.2:
- εt ≥ 0.005: φ = 0.90 (tension-controlled)
- εt ≤ 0.002: φ = 0.65 (tied) or 0.75 (spiral)
- Between: linear interpolation

Replaced with smooth sigmoid for C¹-continuity.
"""
@inline function _pm_smooth_phi(εt::Float64; tie_type::Symbol=:tied)
    φ_min = tie_type == :spiral ? 0.75 : 0.65
    φ_max = 0.90
    # Sigmoid centered at midpoint of [0.002, 0.005]
    k = 2000.0
    center = 0.0035
    σ = 1.0 / (1.0 + exp(-k * (εt - center)))
    return φ_min + (φ_max - φ_min) * σ
end


# ==============================================================================
# Rectangular Column: Smooth Whitney Stress Block
# ==============================================================================

"""
    _smooth_PnMn(b, h, ρg, c, fc, fy, Es, εcu, β1; ...) -> NamedTuple

Compute nominal (Pn, Mn, φ, εt) for a rectangular RC column at neutral
axis depth `c` using the Whitney stress block with smooth approximations.

All inputs in ACI units: fc, fy in ksi; b, h, c, cover in inches.
Steel modeled as `n_layers` distributed uniformly from cover to d.

Returns (Pn, Mn, φ, εt) — all C¹-smooth in (b, h, ρg, c).
"""
function _smooth_PnMn(b::Float64, h::Float64, ρg::Float64, c::Float64,
                            fc::Float64, fy::Float64, Es::Float64,
                            εcu::Float64, β1::Float64;
                            cover::Float64=2.5, n_layers::Int=10,
                            tie_type::Symbol=:tied)
    k = 40.0  # Sharpness for dimensional smooth ops

    # Whitney stress block depth
    a = β1 * c
    # Smooth cap: a ≤ h (block can't exceed section) and a ≥ 0
    a_eff = _smooth_min(a, h; k=k)
    a_eff = _smooth_max(a_eff, 0.0; k=k)

    # Concrete compression (positive = compression)
    Cc = 0.85 * fc * a_eff * b
    Mc = Cc * (h / 2.0 - a_eff / 2.0)

    # Bar-count-adaptive steel distribution via window functions
    #
    # The RCColumnSection constructor has three bar-placement branches:
    #   n_act = 8   → 6 face + 2 side   (f_face = 0.75)     special
    #   n_act = 12  → 8 face + 4 side   (f_face = 0.67)     special
    #   all other n → remaining bars at faces (f_face = 1.0)  generic
    #
    # n_act = max(4, ceil_even(ρg·b·h / As_bar)), so:
    #   n_est ∈ (6, 8]  → n_act = 8   (special)
    #   n_est ∈ (10,12] → n_act = 12  (special)
    #   everything else → n_act = generic (f_face = 1.0)
    #
    # We approximate these intervals with smooth window functions
    # (product of two opposing sigmoids) which are C∞ and sharply
    # localised to the correct n_est range.  Unlike Gaussians, they
    # do NOT bleed into neighbouring intervals.
    #
    # Two conservatism mechanisms:
    #   a. Bar count hard cap at 32 (matches _build_nlp_trial_section)
    #   b. 5% capacity reduction in util/capacity functions (accounts for
    #      smooth-vs-discrete approximation errors in φ, stress clamp, etc.)

    d = h - cover
    As_bar_est = 0.79                       # #8 bar (in²)

    # Raw continuous bar count
    n_est_raw = ρg * b * h / As_bar_est

    # Hard cap at 32 bars (matches _build_nlp_trial_section constructor cap)
    # Using _smooth_min for NLP differentiability
    n_est = _smooth_min(n_est_raw, 32.0; k=2.0)
    As_total = n_est * As_bar_est

    # Window functions: 1 inside interval, 0 outside (steep sigmoid)
    _sig(x) = 1.0 / (1.0 + exp(-20.0 * x))
    w8  = _sig(n_est -  6.0) * _sig( 8.0 - n_est)   # n_est ∈ ~(6, 8)
    w12 = _sig(n_est - 10.0) * _sig(12.0 - n_est)   # n_est ∈ ~(10,12)

    # Face fraction: drops only inside the special-case windows
    f_face = 1.0 - 0.25 * w8 - 0.33 * w12
    f_face = _smooth_max(f_face, 0.60; k=20.0)       # Safety floor

    f_side = 1.0 - f_face

    n_side = n_layers - 2                   # Interior layers (side bars)
    As_face_each = f_face * As_total / 2.0  # Per face
    As_side_each = n_side > 0 ? f_side * As_total / n_side : 0.0

    # Smooth guard: prevent c ≤ 0 in strain computation
    c_safe = _smooth_max(c, 0.01; k=200.0)

    Ps = 0.0
    Ms = 0.0
    for i in 1:n_layers
        t = (i - 1) / max(n_layers - 1, 1)
        di = cover + t * (d - cover)        # Depth from compression face
        As_i = (i == 1 || i == n_layers) ? As_face_each : As_side_each
        εi = εcu * (c_safe - di) / c_safe   # Positive = compression
        fsi = _pm_smooth_fs(εi, fy, Es)
        Fi = As_i * fsi
        Ps += Fi
        Ms += Fi * (h / 2.0 - di)          # Moment about section centroid
    end

    # Net tensile strain at extreme tension bar
    εt = εcu * (d - c_safe) / c_safe

    # Total nominal capacity
    Pn = Cc + Ps
    Mn = _pm_sabs(Mc + Ms; k=100.0)       # Smooth absolute value
    φ = _pm_smooth_phi(εt; tie_type)

    return (Pn=Pn, Mn=Mn, φ=φ, εt=εt)
end


"""
    _smooth_find_c(b, h, ρg, Pu_kip, ...) -> Float64

Find neutral axis depth c* such that φ(c*)·Pn(c*) ≈ Pu_kip for a
rectangular column, using bisection.

The result c* is smooth w.r.t. (b, h, ρg) by the implicit function theorem:
if F(c, θ) = φ·Pn - Pu and ∂F/∂c ≠ 0, then c*(θ) inherits the smoothness
of F. Since all components use smooth approximations, F is C¹ and so is c*.
"""
function _smooth_find_c(b::Float64, h::Float64, ρg::Float64,
                              Pu_kip::Float64,
                              fc::Float64, fy::Float64, Es::Float64,
                              εcu::Float64, β1::Float64;
                              cover::Float64=2.5, n_layers::Int=10,
                              tie_type::Symbol=:tied)
    function residual(c)
        r = _smooth_PnMn(b, h, ρg, c, fc, fy, Es, εcu, β1;
                               cover, n_layers, tie_type)
        return r.φ * r.Pn - Pu_kip
    end

    c_lo, c_hi = 0.01, 5.0 * h
    f_lo = residual(c_lo)
    f_hi = residual(c_hi)

    # Edge cases: demand outside feasible range
    f_hi < 0.0 && return c_hi   # Pu exceeds max φPn → very large c
    f_lo > 0.0 && return c_lo   # Net tension demand → very small c

    # Bisection (50 iterations → precision ≈ 5h × 2⁻⁵⁰ ≈ 10⁻¹⁴ inches)
    for _ in 1:50
        c_mid = (c_lo + c_hi) / 2.0
        f_mid = residual(c_mid)
        abs(f_mid) < 1e-4 && return c_mid
        (f_mid > 0.0) ? (c_hi = c_mid) : (c_lo = c_mid)
    end
    return (c_lo + c_hi) / 2.0
end


"""
    _smooth_rc_pm_util(b, h, ρg, Pu_kip, Mu_kipft, mat; ...) -> Float64

Smooth P-M utilization for a rectangular RC column: Mu / φMn(at Pu).

Fully C¹-continuous in (b, h, ρg) for gradient-based NLP solvers.
Returns utilization ≤ 1.0 if section is adequate, > 1.0 if not.

# Arguments
- `b, h`: Section dimensions (inches)
- `ρg`: Gross reinforcement ratio
- `Pu_kip`: Factored axial load (kip, compression positive)
- `Mu_kipft`: Factored moment (kip-ft)
- `mat`: Named tuple (fc, fy, Es, εcu) in ksi units
"""
function _smooth_rc_pm_util(b::Float64, h::Float64, ρg::Float64,
                                  Pu_kip::Float64, Mu_kipft::Float64,
                                  mat::NamedTuple;
                                  cover::Float64=2.5, n_layers::Int=10,
                                  tie_type::Symbol=:tied)
    fc, fy, Es, εcu = mat.fc, mat.fy, mat.Es, mat.εcu
    β1 = clamp(0.85 - 0.05 * (fc * 1000.0 - 4000.0) / 1000.0, 0.65, 0.85)

    c_star = _smooth_find_c(b, h, ρg, Pu_kip, fc, fy, Es, εcu, β1;
                                  cover, n_layers, tie_type)

    r = _smooth_PnMn(b, h, ρg, c_star, fc, fy, Es, εcu, β1;
                           cover, n_layers, tie_type)

    # 10% conservatism: accounts for smooth-vs-discrete approximation errors
    # (φ sigmoid, steel stress clamp, finite layer count, bar distribution,
    # and utilization metric gap between smooth Mu/φMn and analytical P-M radial)
    φMn_kipft = r.φ * r.Mn / 12.0 * 0.90  # kip·in → kip·ft, with conservatism

    # Guard: negligible capacity → high utilization
    if φMn_kipft < 0.01
        return abs(Mu_kipft) > 0.01 ? 100.0 : 0.0
    end

    return abs(Mu_kipft) / φMn_kipft
end


"""
    _smooth_rc_pm_capacity(b, h, ρg, Pu_kip, mat; ...) -> (φMn_kipft, εt)

Compute smooth φMn capacity (kip·ft) at given Pu for a rectangular RC column.
Also returns net tensile strain εt for ductility checks.
Used by constraint_fns for biaxial interaction.
"""
function _smooth_rc_pm_capacity(b::Float64, h::Float64, ρg::Float64,
                                      Pu_kip::Float64, mat::NamedTuple;
                                      cover::Float64=2.5, n_layers::Int=10,
                                      tie_type::Symbol=:tied)
    fc, fy, Es, εcu = mat.fc, mat.fy, mat.Es, mat.εcu
    β1 = clamp(0.85 - 0.05 * (fc * 1000.0 - 4000.0) / 1000.0, 0.65, 0.85)

    c_star = _smooth_find_c(b, h, ρg, Pu_kip, fc, fy, Es, εcu, β1;
                                  cover, n_layers, tie_type)

    r = _smooth_PnMn(b, h, ρg, c_star, fc, fy, Es, εcu, β1;
                           cover, n_layers, tie_type)

    # 10% conservatism (consistent with _smooth_rc_pm_util)
    return (φMn_kipft = r.φ * r.Mn / 12.0 * 0.90, εt = r.εt)
end


# ==============================================================================
# Circular Column: Smooth Whitney Stress Block on Circular Section
# ==============================================================================

"""
    _smooth_PnMn(D, ρg, c, fc, fy, Es, εcu, β1; ...) -> NamedTuple

Compute nominal (Pn, Mn, φ, εt) for a circular RC column at neutral
axis depth `c` using the Whitney stress block with smooth approximations.

Uses analytical circular segment formulas for the concrete compression zone:
- Segment area: A = R²·arccos(y₀/R) - y₀·√(R² - y₀²)
- Centroid: ȳ = (2/3)·(R² - y₀²)^(3/2) / A

Steel modeled as `n_bars` uniformly spaced around the perimeter.
"""
function _smooth_PnMn(D::Float64, ρg::Float64, c::Float64,
                            fc::Float64, fy::Float64, Es::Float64,
                            εcu::Float64, β1::Float64;
                            cover::Float64=2.5, n_bars::Int=12,
                            tie_type::Symbol=:spiral)
    R = D / 2.0
    a = β1 * c

    # Coordinate system: y from center, positive upward (toward compression face)
    # Compression zone: y ∈ [R - a, R] (from top down)
    # y₀ = R - a is the bottom of the Whitney block

    y0 = R - a

    # Smooth clamp y₀ to (-R+ε, R-ε) for numerical stability of acos/sqrt
    y0s = _smooth_min(_smooth_max(y0, -R + 0.05; k=40.0), R - 0.05; k=40.0)

    # Circular segment area above y₀:
    # A = R²·arccos(y₀/R) - y₀·√(R² - y₀²)
    cos_arg = y0s / R
    cos_arg = _smooth_min(_smooth_max(cos_arg, -0.998; k=200.0), 0.998; k=200.0)
    Rsq_minus_y0sq = _smooth_max(R^2 - y0s^2, 0.001; k=200.0)
    seg_area = R^2 * acos(cos_arg) - y0s * sqrt(Rsq_minus_y0sq)

    # Centroid of compression zone (y from center, positive upward)
    # ȳ = (2/3)·(R² - y₀²)^(3/2) / A
    numer = (2.0 / 3.0) * Rsq_minus_y0sq^1.5
    centroid_y = seg_area > 0.01 ? numer / seg_area : 0.0

    # Concrete compression force and moment about center
    Cc = 0.85 * fc * seg_area
    Mc = Cc * centroid_y

    # Steel bars around perimeter
    r_s = _smooth_max(R - cover, 0.5; k=40.0)   # Bar center radius
    As_total = ρg * π * R^2
    As_bar = As_total / n_bars
    c_safe = _smooth_max(c, 0.01; k=200.0)

    Ps = 0.0
    Ms = 0.0
    for i in 1:n_bars
        θi = 2π * (i - 1) / n_bars
        yi = r_s * cos(θi)            # y from center (positive = compression side)
        di = R - yi                    # Depth from compression face
        εi = εcu * (c_safe - di) / c_safe
        fsi = _pm_smooth_fs(εi, fy, Es)
        Fi = As_bar * fsi
        Ps += Fi
        Ms += Fi * yi                 # Moment about center
    end

    # Net tensile strain at extreme tension bar (bottom bar at y = -r_s)
    d_extreme = R + r_s
    εt = εcu * (d_extreme - c_safe) / c_safe

    Pn = Cc + Ps
    Mn = _pm_sabs(Mc + Ms; k=100.0)
    φ = _pm_smooth_phi(εt; tie_type)

    return (Pn=Pn, Mn=Mn, φ=φ, εt=εt)
end


"""
    _smooth_find_c(D, ρg, Pu_kip, ...) -> Float64

Find neutral axis depth c* such that φ(c*)·Pn(c*) ≈ Pu_kip for a
circular column, using bisection.
"""
function _smooth_find_c(D::Float64, ρg::Float64, Pu_kip::Float64,
                              fc::Float64, fy::Float64, Es::Float64,
                              εcu::Float64, β1::Float64;
                              cover::Float64=2.5, n_bars::Int=12,
                              tie_type::Symbol=:spiral)
    function residual(c)
        r = _smooth_PnMn(D, ρg, c, fc, fy, Es, εcu, β1;
                               cover, n_bars, tie_type)
        return r.φ * r.Pn - Pu_kip
    end

    c_lo, c_hi = 0.01, 5.0 * D
    f_lo = residual(c_lo)
    f_hi = residual(c_hi)

    f_hi < 0.0 && return c_hi
    f_lo > 0.0 && return c_lo

    for _ in 1:50
        c_mid = (c_lo + c_hi) / 2.0
        f_mid = residual(c_mid)
        abs(f_mid) < 1e-4 && return c_mid
        (f_mid > 0.0) ? (c_hi = c_mid) : (c_lo = c_mid)
    end
    return (c_lo + c_hi) / 2.0
end


"""
    _smooth_rc_pm_util(D, ρg, Pu_kip, Mu_kipft, mat; ...) -> Float64

Smooth P-M utilization for a circular RC column: Mu / φMn(at Pu).
"""
function _smooth_rc_pm_util(D::Float64, ρg::Float64,
                                  Pu_kip::Float64, Mu_kipft::Float64,
                                  mat::NamedTuple;
                                  cover::Float64=2.5, n_bars::Int=12,
                                  tie_type::Symbol=:spiral)
    fc, fy, Es, εcu = mat.fc, mat.fy, mat.Es, mat.εcu
    β1 = clamp(0.85 - 0.05 * (fc * 1000.0 - 4000.0) / 1000.0, 0.65, 0.85)

    c_star = _smooth_find_c(D, ρg, Pu_kip, fc, fy, Es, εcu, β1;
                                  cover, n_bars, tie_type)

    r = _smooth_PnMn(D, ρg, c_star, fc, fy, Es, εcu, β1;
                           cover, n_bars, tie_type)

    # 10% conservatism (matches rectangular — accounts for smooth approx errors)
    φMn_kipft = r.φ * r.Mn / 12.0 * 0.90

    if φMn_kipft < 0.01
        return abs(Mu_kipft) > 0.01 ? 100.0 : 0.0
    end

    return abs(Mu_kipft) / φMn_kipft
end


"""
    _smooth_rc_pm_capacity(D, ρg, Pu_kip, mat; ...) -> (φMn_kipft, εt)

Compute smooth φMn capacity (kip·ft) at given Pu for a circular RC column.
"""
function _smooth_rc_pm_capacity(D::Float64, ρg::Float64,
                                      Pu_kip::Float64, mat::NamedTuple;
                                      cover::Float64=2.5, n_bars::Int=12,
                                      tie_type::Symbol=:spiral)
    fc, fy, Es, εcu = mat.fc, mat.fy, mat.Es, mat.εcu
    β1 = clamp(0.85 - 0.05 * (fc * 1000.0 - 4000.0) / 1000.0, 0.65, 0.85)

    c_star = _smooth_find_c(D, ρg, Pu_kip, fc, fy, Es, εcu, β1;
                                  cover, n_bars, tie_type)

    r = _smooth_PnMn(D, ρg, c_star, fc, fy, Es, εcu, β1;
                           cover, n_bars, tie_type)

    # 10% conservatism (matches rectangular)
    return (φMn_kipft = r.φ * r.Mn / 12.0 * 0.90, εt = r.εt)
end
