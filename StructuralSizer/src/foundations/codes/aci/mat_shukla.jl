# =============================================================================
# Analytical Flexible Method for Mat Foundations
# =============================================================================
#
# Implements the ACI 336.2R-88 §6.1.2 design procedure, Steps 3–4:
#
#   Step 3 — Rigid-body strip statics (Kramrisch) for baseline moments.
#   Step 4 — Approximate flexible analysis (Shukla 1984, Kelvin-Bessel
#            superposition on an infinite Winkler plate) for localised
#            moment peaks under/between columns.
#
# The final reinforcement is the **envelope** (face-by-face maximum) of
# the rigid and Shukla moments.  This satisfies global equilibrium via
# the rigid solution while capturing flexible-method peaks.
#
# References:
#   - ACI 336.2R-88 §6.1.2 Steps 3–4
#   - Shukla, S.N. (1984). "A Simplified Method for Design of Mats on
#     Elastic Foundations." ACI Journal, 81(5), 469–475.
#   - ACI 336.2R-88 §3.3.2 Eq. 3-8 (subgrade modulus size scaling)
# =============================================================================

using SpecialFunctions: besselk

# ─────────────────────────────────────────────────────────────────────────────
# Shukla k_v1 chart data (from Shukla 1984, digitised)
# ─────────────────────────────────────────────────────────────────────────────
#
# x-axis: q_u / 2000 (q_u in lbf/ft², divided by 2000)
# y-axis: k_v1 / 2000 (k_v1 in lbf/ft³, divided by 2000)
#
# Two curves: fine-grained and coarse-grained soils.
# Data loaded from StructuralSizer/src/foundations/data/k_dataset.csv.

const _SHUKLA_FINE_X = [1.0101301484811500, 1.28307800146931, 1.6827639196867300,
    2.164845756188960, 2.5516314054822800, 2.957363061016790,
    3.3437038734506500, 3.7680580175104000, 4.002507262298730]

const _SHUKLA_FINE_Y = [25.936684887004700, 44.33506999440580, 75.4989249775897,
    114.6428836212420, 148.97451623991500, 186.49077637511900,
    229.5523323605340, 276.6022551880780, 300.53582621706700]

const _SHUKLA_COARSE_X = [0.9713080225653610, 1.1996306506076100, 1.3835302522764200,
    1.6561950272631100, 1.9668326941611800, 2.328100883607760,
    2.644703408393940, 3.031044220827800, 3.3600617379641300,
    3.663763993826200, 3.859835949558200]

const _SHUKLA_COARSE_Y = [37.82090598440370, 56.98933065532550, 72.9596479048858,
    96.91343879112210, 125.64922591646500, 160.76100802728300,
    197.43645909859900, 240.49801508401300, 283.5292412835570,
    323.3724699903620, 350.46033875000800]

"""
    _linear_interp(xs, ys, x) → Float64

Simple piecewise linear interpolation with linear extrapolation at boundaries.
"""
function _linear_interp(xs::Vector{Float64}, ys::Vector{Float64}, x::Float64)
    n = length(xs)
    # Extrapolate below
    if x <= xs[1]
        slope = (ys[2] - ys[1]) / (xs[2] - xs[1])
        return ys[1] + slope * (x - xs[1])
    end
    # Extrapolate above
    if x >= xs[n]
        slope = (ys[n] - ys[n-1]) / (xs[n] - xs[n-1])
        return ys[n] + slope * (x - xs[n])
    end
    # Interpolate
    for i in 1:(n-1)
        if xs[i] <= x <= xs[i+1]
            t = (x - xs[i]) / (xs[i+1] - xs[i])
            return ys[i] + t * (ys[i+1] - ys[i])
        end
    end
    return ys[n]  # fallback
end

"""
    _shukla_kv1(q_u, grain) → Unitful force/length³

Look up the basic modulus of subgrade reaction k_v1 for a 1 ft × 1 ft plate
from Shukla (1984) chart data.

# Arguments
- `q_u::Pressure`: Unconfined compressive strength of soil.
- `grain::Symbol`: `:fine` or `:coarse`.
"""
function _shukla_kv1(q_u::Pressure, grain::Symbol)
    x = ustrip(u"lbf/ft^2", q_u) / 2000.0
    if grain == :fine
        y = _linear_interp(_SHUKLA_FINE_X, _SHUKLA_FINE_Y, x)
    elseif grain == :coarse
        y = _linear_interp(_SHUKLA_COARSE_X, _SHUKLA_COARSE_Y, x)
    else
        error("grain must be :fine or :coarse, got :$grain")
    end
    return y * 2000.0u"lbf/ft^3"
end

# ─────────────────────────────────────────────────────────────────────────────
# Kelvin-Bessel functions  (Shukla 1984, Eqs. 1–4)
# ─────────────────────────────────────────────────────────────────────────────
#
# Z₃(x) = -(2/π) kei(x)     where kei(x) = Im[K₀(x·e^(iπ/4))]
# Z₄(x) = -(2/π) ker(x)     where ker(x) = Re[K₀(x·e^(iπ/4))]
#
# Primes use K₁ via d/dx K₀(z) = -K₁(z)·dz/dx.
#
# All accept dimensionless real arguments.

const _KELVIN_ROT = exp(im * π / 4)

function _Z3(x::Real)
    x = Float64(x)
    return -(2 / π) * imag(besselk(0, x * _KELVIN_ROT))
end

function _Z3_prime(x::Real)
    x = Float64(x)
    return -(2 / π) * imag(-_KELVIN_ROT * besselk(1, x * _KELVIN_ROT))
end

function _Z4(x::Real)
    x = Float64(x)
    return -(2 / π) * real(besselk(0, x * _KELVIN_ROT))
end

function _Z4_prime(x::Real)
    x = Float64(x)
    return -(2 / π) * real(-_KELVIN_ROT * besselk(1, x * _KELVIN_ROT))
end

# ─────────────────────────────────────────────────────────────────────────────
# Core analysis: build moment/shear/deflection fields for given thickness
# ─────────────────────────────────────────────────────────────────────────────

"""
    _shukla_analysis(h, positions, demands, Ec, μ, ks)
        → (M_x_tot, M_y_tot, Q_tot, δ_tot, q_pressure, L, ks_used)

Build closed-form moment, shear, deflection, and soil pressure functions
for a mat of thickness `h` on a Winkler foundation with modulus `ks`.

All returned functions accept Unitful (x, y) positions in the global
coordinate system of the column positions.

- `M_x_tot(x, y)`, `M_y_tot(x, y)`: Bending moments per unit length
- `Q_tot(x, y)`: Shear force per unit length
- `δ_tot(x, y)`: Vertical deflection
- `q_pressure(x, y)`: Soil bearing pressure = ks × δ

# Arguments
- `h::Length`: Mat thickness.
- `positions`: Column (x, y) positions.
- `demands`: Column loads (uses Pu).
- `Ec::Pressure`: Concrete elastic modulus.
- `μ::Float64`: Poisson's ratio of concrete.
- `ks`: Modulus of subgrade reaction (force/length³).
"""
function _shukla_analysis(
    h::Length,
    positions::Vector{<:NTuple{2, <:Length}},
    demands::Vector{<:FoundationDemand},
    Ec::Pressure,
    μ::Float64,
    ks  # force/length³
)
    # Flexural rigidity — ACI 336.2R notation
    D = (Ec * h^3) / (12 * (1 - μ^2))

    # Radius of effective stiffness
    L = (D / ks)^(0.25)

    # Equivalent column radii (map rectangular to circular for singularity capping)
    # Expressed as r_col / L (dimensionless). Using default column size.
    default_col = 18.0u"inch"
    r_col_over_L = Float64(ustrip(Unitful.NoUnits, sqrt(default_col^2 / π) / L))
    equiv_radii = fill(r_col_over_L, length(demands))

    P = [d.Pu for d in demands]
    pos = positions

    # ── Per-column radial functions (capped at equiv radius to avoid singularity) ──

    # Radial moment M_r (Shukla Eq. 3)
    function M_r_i(i, r_over_L)
        ξ = max(equiv_radii[i], r_over_L)
        -(P[i] / 4) * (_Z4(ξ) - (1 - μ) * _Z3_prime(ξ) / ξ)
    end

    # Tangential moment M_t (Shukla Eq. 4)
    function M_t_i(i, r_over_L)
        ξ = max(equiv_radii[i], r_over_L)
        -(P[i] / 4) * (μ * _Z4(ξ) + (1 - μ) * _Z3_prime(ξ) / ξ)
    end

    # Shear Q (Shukla Eq. 5)
    function Q_i(i, r_over_L)
        ξ = max(equiv_radii[i], r_over_L)
        -(P[i] / (4 * L)) * _Z4_prime(ξ)
    end

    # Deflection δ (Shukla Eq. 2)
    function δ_i(i, r_over_L)
        ξ = max(equiv_radii[i], r_over_L)
        (P[i] * L^2 / (4 * D)) * _Z3(ξ)
    end

    # ── Convert polar (M_r, M_t) to Cartesian (M_x, M_y) per column ──

    function M_x_col(i, dx, dy)
        r = sqrt(dx^2 + dy^2)
        r_L = ustrip(Unitful.NoUnits, r / L)
        θ = atan(ustrip(u"m", dy), ustrip(u"m", dx))
        Mr = M_r_i(i, r_L)
        Mt = M_t_i(i, r_L)
        Mr * cos(θ)^2 + Mt * sin(θ)^2
    end

    function M_y_col(i, dx, dy)
        r = sqrt(dx^2 + dy^2)
        r_L = ustrip(Unitful.NoUnits, r / L)
        θ = atan(ustrip(u"m", dy), ustrip(u"m", dx))
        Mr = M_r_i(i, r_L)
        Mt = M_t_i(i, r_L)
        Mr * sin(θ)^2 + Mt * cos(θ)^2
    end

    # ── Superposition across all columns ──

    function M_x_tot(x, y)
        sum(M_x_col(i, x - pos[i][1], y - pos[i][2]) for i in eachindex(pos))
    end

    function M_y_tot(x, y)
        sum(M_y_col(i, x - pos[i][1], y - pos[i][2]) for i in eachindex(pos))
    end

    function Q_tot(x, y)
        sum(begin
            r = sqrt((x - pos[i][1])^2 + (y - pos[i][2])^2)
            Q_i(i, ustrip(Unitful.NoUnits, r / L))
        end for i in eachindex(pos))
    end

    function δ_tot(x, y)
        sum(begin
            r = sqrt((x - pos[i][1])^2 + (y - pos[i][2])^2)
            δ_i(i, ustrip(Unitful.NoUnits, r / L))
        end for i in eachindex(pos))
    end

    q_pressure(x, y) = ks * δ_tot(x, y)

    return M_x_tot, M_y_tot, Q_tot, δ_tot, q_pressure, L
end

# ─────────────────────────────────────────────────────────────────────────────
# Shukla design driver
# ─────────────────────────────────────────────────────────────────────────────

"""
    _design_mat_shukla(demands, positions, soil, method; opts) → MatFootingResult

Analytical mat design per ACI 336.2R-88 §6.1.2 (Steps 3–4).

Iterates on thickness h to satisfy:
  1. Bearing pressure ≤ qa at columns, center, and corners (Shukla field).
  2. Punching shear at each column (ACI 318 via `punching_check()`).

Flexural reinforcement is the **envelope** (face-by-face max) of:
  - Rigid strip statics (Kramrisch, ACI 336.2R Step 3) — satisfies statics.
  - Shukla infinite-plate moments (Step 4) — captures localised peaks.

# References
- ACI 336.2R-88 §6.1.2 Steps 3–4.
- Shukla (1984), ACI Journal 81(5).
"""
function _design_mat_shukla(
    demands::Vector{<:FoundationDemand},
    positions::Vector{<:NTuple{2, <:Length}},
    soil::Soil,
    method::ShuklaAFM;
    opts::MatFootingOptions = MatFootingOptions()
)
    N = length(demands)

    # Material / options
    fc    = opts.material.concrete.fc′
    fy    = opts.material.rebar.Fy
    λ     = something(opts.λ, opts.material.concrete.λ)
    cover = opts.cover
    db_x  = bar_diameter(opts.bar_size_x)
    db_y  = bar_diameter(opts.bar_size_y)
    ϕf    = opts.ϕ_flexure
    ϕv    = opts.ϕ_shear
    μ     = 0.2  # Poisson's ratio of concrete (ACI typical)

    # Concrete modulus — ACI 318 §19.2.2.1
    Ec = 57000.0u"psi" * sqrt(ustrip(u"psi", fc))

    # ── Step 1: Plan Sizing (first-principles overhang) ──
    plan = _mat_plan_sizing(positions, opts; demands = demands, soil = soil)
    B, Lm = plan.B, plan.Lm

    Ps_total = sum(d.Ps for d in demands)

    # Bearing utilization (service loads, rigid assumption for initial check)
    util_bearing = to_kip(Ps_total) / to_kip(soil.qa * B * Lm)
    util_bearing > 1.0 && @warn "Mat bearing exceeds allowable: util=$(round(util_bearing, digits=3))"

    # ── Step 2: Determine subgrade modulus k_s ──
    if soil.ks !== nothing
        # Use directly provided modulus
        ks = soil.ks
    elseif method.q_u !== nothing
        # Shukla chart lookup + ACI 336.2R §3.3.2 Eq. 3-8 size scaling
        kv1 = _shukla_kv1(method.q_u, method.grain)
        B_min = min(B, Lm)
        n = method.ks_exponent
        # ACI 336.2R Eq. 3-8: ks = kv1 × (Bp/Bm)^n, Bp = 1 ft
        ks = kv1 * (1.0u"ft" / B_min)^n
    else
        error("ShuklaAFM requires either soil.ks or method.q_u to be provided")
    end

    # Per-column dimensions are on demands[j].c1, demands[j].c2, demands[j].shape

    # ── Step 4: Iterate on thickness h ──
    h = opts.min_depth
    h_incr = opts.depth_increment

    # Pre-define mat sampling grid for bearing check
    mat_corners = [
        (plan.x_left, plan.y_bot),
        (plan.x_left + B, plan.y_bot),
        (plan.x_left, plan.y_bot + Lm),
        (plan.x_left + B, plan.y_bot + Lm),
    ]
    mat_center = (plan.x_left + B / 2, plan.y_bot + Lm / 2)

    local M_x_f, M_y_f, q_f  # saved for flexure + equilibrium steps

    for iter in 1:80
        d_eff = h - cover - max(db_x, db_y)
        d_eff < 6.0u"inch" && (h += h_incr; continue)

        # Run Shukla analysis for this thickness
        M_x_f, M_y_f, _, _, q_f, Leff = _shukla_analysis(
            h, positions, demands, Ec, μ, ks)

        # ── Bearing check at critical locations ──
        bearing_ok = true
        check_locs = vcat([(p[1], p[2]) for p in positions], [mat_center], mat_corners)
        for loc in check_locs
            q_val = q_f(loc[1], loc[2])
            # Service-level check: compare to allowable bearing
            if uconvert(u"lbf/ft^2", q_val) > soil.qa
                bearing_ok = false
                break
            end
        end

        # ── Punching shear check at each column (per-column dimensions) ──
        qu_punch = sum(d.Pu for d in demands) / (B * Lm)
        punch_ok = true
        for j in 1:N
            c1j, c2j = demands[j].c1, demands[j].c2
            is_edge = (
                plan.xs_loc[j] < plan.overhang + 0.5u"ft" ||
                plan.xs_loc[j] > (B - plan.overhang - 0.5u"ft") ||
                plan.ys_loc[j] < plan.overhang + 0.5u"ft" ||
                plan.ys_loc[j] > (Lm - plan.overhang - 0.5u"ft")
            )
            pos_sym = is_edge ? :edge : :interior
            Ac = if demands[j].shape == :circular
                π * (c1j + d_eff)^2 / 4
            else
                is_edge ? (c1j + d_eff / 2) * (c2j + d_eff) :
                          (c1j + d_eff) * (c2j + d_eff)
            end
            Vu_p = max(uconvert(u"lbf", demands[j].Pu - qu_punch * Ac), 0.0u"lbf")

            pch = punching_check(Vu_p, demands[j].Mux, demands[j].Muy,
                                  d_eff, fc, c1j, c2j;
                                  position = pos_sym, shape = demands[j].shape,
                                  λ = λ, ϕ = ϕv)
            if !pch.ok
                punch_ok = false
                break
            end
        end

        (bearing_ok && punch_ok) && break
        h += h_incr
        iter == 80 && @warn "Shukla mat thickness did not converge at h=$h"
    end

    d_eff = h - cover - max(db_x, db_y)

    # ── Step 4b: Vertical equilibrium check ──
    # Shukla is an infinite-plate solution; integrating soil pressure q = ks·δ
    # over the finite mat domain should capture most (~90%+) of the total load.
    # A large shortfall indicates the mat overhang is too small for this method.
    Pu_total = sum(d.Pu for d in demands)
    eq_nx, eq_ny = 40, 40
    eq_xs = range(plan.x_left, plan.x_left + B, length=eq_nx)
    eq_ys = range(plan.y_bot, plan.y_bot + Lm, length=eq_ny)
    eq_dx = B / (eq_nx - 1)
    eq_dy = Lm / (eq_ny - 1)
    # Trapezoidal integration of q(x,y) over mat domain
    q_integral = sum(
        let w_x = (ix == 1 || ix == eq_nx) ? 0.5 : 1.0
            w_y = (iy == 1 || iy == eq_ny) ? 0.5 : 1.0
            w_x * w_y * q_f(eq_xs[ix], eq_ys[iy]) * eq_dx * eq_dy
        end
        for ix in 1:eq_nx, iy in 1:eq_ny)
    eq_ratio = ustrip(Unitful.NoUnits, q_integral / Pu_total)
    eq_shortfall = 1.0 - eq_ratio
    # Warn only if shortfall is extreme (>20% of load not captured by mat)
    eq_shortfall > 0.20 && @warn(
        "Shukla equilibrium: only $(round(100*eq_ratio, digits=1))% of total load " *
        "captured by soil pressure over mat (infinite-plate effect)")

    # ── Step 5a: Shukla moments — sample flexible moment field ──
    x_res = max(4 * length(plan.x_spans), 5)
    y_res = max(4 * length(plan.y_spans), 5)

    x_range = range(plan.x_left, plan.x_left + B, length = x_res)
    y_range = range(plan.y_bot, plan.y_bot + Lm, length = y_res)

    # Shukla moment functions return M per unit length (dim = Force).
    Mx_pos = zero(demands[1].Pu)
    Mx_neg = zero(demands[1].Pu)
    My_pos = zero(demands[1].Pu)
    My_neg = zero(demands[1].Pu)

    for x in x_range, y in y_range
        mx = M_x_f(x, y)
        my = M_y_f(x, y)
        Mx_pos = max(Mx_pos, mx)
        Mx_neg = max(Mx_neg, -mx)
        My_pos = max(My_pos, my)
        My_neg = max(My_neg, -my)
    end

    # Convert Shukla per-unit-length peaks to total moments (Force × Length).
    # Shukla sign convention: positive → bottom tension (sagging).
    M_shukla_x_bot = Mx_pos * Lm    # sagging → As_bot
    M_shukla_x_top = Mx_neg * Lm    # hogging → As_top
    M_shukla_y_bot = My_pos * B
    M_shukla_y_top = My_neg * B

    # ── Step 5b: Rigid strip moments — ACI 336.2R §6.1.2 Step 3 ──
    # These satisfy global statics exactly.
    qu_rigid = sum(d.Pu for d in demands) / (B * Lm)

    avg_trib_x = isempty(plan.y_spans) ? Lm : sum(plan.y_spans) / length(plan.y_spans)
    mom_x_rigid = _rigid_mat_strip_moments(qu_rigid, avg_trib_x, plan.x_spans)

    avg_trib_y = isempty(plan.x_spans) ? B : sum(plan.x_spans) / length(plan.x_spans)
    mom_y_rigid = _rigid_mat_strip_moments(qu_rigid, avg_trib_y, plan.y_spans)

    # ── Step 5c: Envelope — face-by-face max (ACI 336.2R §6.1.2 Steps 3+4) ──
    M_env_x_bot = max(M_shukla_x_bot, mom_x_rigid.M_pos)   # sagging
    M_env_x_top = max(M_shukla_x_top, mom_x_rigid.M_neg)   # hogging
    M_env_y_bot = max(M_shukla_y_bot, mom_y_rigid.M_pos)
    M_env_y_top = max(M_shukla_y_top, mom_y_rigid.M_neg)

    # Design reinforcement from enveloped moments.
    As_x_bot = max(_flexural_steel_footing(M_env_x_bot, Lm, d_eff, fc, fy, ϕf),
                   _min_steel_footing(Lm, h, fy))
    As_x_top = max(_flexural_steel_footing(M_env_x_top, Lm, d_eff, fc, fy, ϕf),
                   _min_steel_footing(Lm, h, fy))
    As_y_bot = max(_flexural_steel_footing(M_env_y_bot, B, d_eff, fc, fy, ϕf),
                   _min_steel_footing(B, h, fy))
    As_y_top = max(_flexural_steel_footing(M_env_y_top, B, d_eff, fc, fy, ϕf),
                   _min_steel_footing(B, h, fy))

    # ── Utilization ──
    qu_final = sum(d.Pu for d in demands) / (B * Lm)
    util_punch = _mat_punching_util(demands, plan, qu_final, d_eff, fc, λ, ϕv)
    utilization = max(util_bearing, util_punch)

    return _mat_build_result(plan, demands, opts, h, d_eff,
                             As_x_bot, As_x_top, As_y_bot, As_y_top,
                             utilization)
end
