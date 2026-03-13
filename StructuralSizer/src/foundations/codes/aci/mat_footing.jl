# =============================================================================
# Mat Foundation Design — Public API + Rigid Method
# =============================================================================
#
# Public entry point `design_footing(::MatFoundation, ...)` dispatches on `opts.analysis_method`:
#   - RigidMat   → rigid body analysis (ACI 336.2R-88 §4.2, strip statics)
#   - ShuklaAFM  → analytical method: Shukla (1984) + rigid envelope
#                  (ACI 336.2R §6.1.2 Steps 3–4)
#   - WinklerFEA → FEA plate on Winkler springs (ACI 336.2R §6.4/§6.7)
#
# Shared utilities (_mat_plan_sizing, _mat_result, _unique_spans) are used by
# all methods.  Method-specific code lives in mat_shukla.jl / mat_winkler_fea.jl.
#
# Fully Unitful throughout.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Shared utilities
# ─────────────────────────────────────────────────────────────────────────────

"""Extract sorted span lengths from sorted unique column coordinates."""
function _unique_spans(coords::Vector{<:Length})
    vals = sort(unique(round.(ustrip.(u"ft", coords); digits = 3)))
    length(vals) < 2 && return Length[]
    return [(vals[i + 1] - vals[i]) * u"ft" for i in 1:length(vals) - 1]
end

"""
    _mat_plan_sizing(positions, opts; demands, soil) → NamedTuple

Shared Step 1 for all mat methods: compute plan dimensions, overhang, and
local coordinate system.  Returns a NamedTuple with all geometric quantities.

When `demands` and `soil` are provided the auto-overhang is derived from
first principles rather than the old `min_span / 6` heuristic:

1. **Punching (ACI 318 §22.6)** — overhang ≥ `c_max/2 + d_est/2` so that
   every outermost column has a full 4-sided critical perimeter (interior
   condition).  This eliminates the severe 2- or 3-sided reductions for
   corner/edge positions.

2. **Bearing (ACI 336.2R §3)** — mat area ≥ `Ps_total / qa`.  Solved as a
   quadratic for the required overhang beyond the column grid.

3. **Minimum floor** — 2 ft for construction tolerance.

If demands/soil are not provided (backward compatibility), falls back to
`max(min_span / 6, 2 ft)`.
"""
function _mat_plan_sizing(
    positions::Vector{<:NTuple{2, <:Length}},
    opts::MatFootingOptions;
    demands::Union{Vector{<:FoundationDemand}, Nothing} = nothing,
    soil::Union{Soil, Nothing} = nothing,
)
    xs = [p[1] for p in positions]
    ys = [p[2] for p in positions]

    x_min, x_max = extrema(xs)
    y_min, y_max = extrema(ys)

    if opts.edge_overhang !== nothing
        # ── User-specified overhang ──
        overhang = opts.edge_overhang

    elseif demands !== nothing && soil !== nothing
        # ── First-principles auto-overhang ──

        # (a) Punching shear: ensure every outermost column is interior.
        #     Full 4-sided critical perimeter requires overhang ≥ c_max/2 + d/2
        #     beyond the column face (half column + half effective depth).
        #     ACI 318 §22.6.4.1 — critical section at d/2 from column face.
        c_max = maximum(max(d.c1, d.c2) for d in demands)
        db_max = bar_diameter(max(opts.bar_size_x, opts.bar_size_y))
        d_est  = opts.min_depth - opts.cover - db_max
        d_est  = max(d_est, 6.0u"inch")
        oh_punch = c_max / 2 + d_est / 2   # ACI 318 §22.6.4.1

        # (b) Bearing: A_mat ≥ Ps_total / qa  (service-level check).
        #     Mat area = (gx + 2·oh) × (gy + 2·oh) where gx, gy = grid extent.
        #     Solve quadratic: 4·oh² + 2(gx+gy)·oh + (gx·gy − A_req) ≥ 0.
        Ps_total = sum(d.Ps for d in demands)
        ustrip(soil.qa) > 0 || error("Allowable soil bearing pressure (qa) must be positive")
        A_req = Ps_total / soil.qa    # required area (Length²)
        gx = x_max - x_min
        gy = y_max - y_min
        grid_area = gx * gy

        if ustrip(u"ft^2", grid_area) < 1e-6
            # Single column or co-linear columns: need full area from overhang.
            # For a square mat centred on the column, side = √A_req.
            side = sqrt(uconvert(u"ft^2", A_req))   # → ft
            oh_bearing = max(side / 2, 2.0u"ft")
        elseif uconvert(u"ft^2", A_req) > uconvert(u"ft^2", grid_area)
            # Grid alone is not enough; solve the quadratic for oh
            gx_ft = ustrip(u"ft", gx)
            gy_ft = ustrip(u"ft", gy)
            A_req_ft2 = ustrip(u"ft^2", A_req)
            deficit = A_req_ft2 - gx_ft * gy_ft
            # 4·oh² + 2(gx+gy)·oh − deficit = 0
            a_q = 4.0
            b_q = 2.0 * (gx_ft + gy_ft)
            c_q = -deficit
            oh_bearing = ((-b_q + sqrt(b_q^2 - 4 * a_q * c_q)) / (2 * a_q)) * u"ft"
            oh_bearing = max(oh_bearing, 0.0u"ft")
        else
            oh_bearing = 0.0u"ft"
        end

        # (c) Combine: take the governing requirement, enforce 2 ft minimum.
        overhang = max(oh_punch, oh_bearing, 2.0u"ft")

    else
        # ── Fallback heuristic (no demand/soil data available) ──
        x_sp = _unique_spans(xs)
        y_sp = _unique_spans(ys)
        min_span = min(
            isempty(x_sp) ? 20.0u"ft" : minimum(x_sp),
            isempty(y_sp) ? 20.0u"ft" : minimum(y_sp))
        overhang = max(min_span / 6, 2.0u"ft")
    end

    B  = (x_max - x_min) + 2overhang   # width  (x-direction)
    Lm = (y_max - y_min) + 2overhang   # length (y-direction)

    x_left = x_min - overhang
    y_bot  = y_min - overhang
    xs_loc = xs .- x_left
    ys_loc = ys .- y_bot

    x_spans = _unique_spans(xs_loc)
    y_spans = _unique_spans(ys_loc)

    return (
        B = B, Lm = Lm, overhang = overhang,
        xs = xs, ys = ys,
        xs_loc = xs_loc, ys_loc = ys_loc,
        x_left = x_left, y_bot = y_bot,
        x_spans = x_spans, y_spans = y_spans,
    )
end

"""
    _mat_punching_util(demands, plan, qu, d_eff, fc, λ, ϕv) → Float64

Compute the governing punching utilization across all columns.
Uses per-column dimensions from `demands[j].c1`, `demands[j].c2`, `demands[j].shape`.
Reused by all mat methods.
"""
function _mat_punching_util(demands, plan, qu, d_eff, fc, λ, ϕv)
    util = 0.0
    B, Lm, overhang = plan.B, plan.Lm, plan.overhang
    xs_loc, ys_loc = plan.xs_loc, plan.ys_loc

    for j in eachindex(demands)
        c1j, c2j = demands[j].c1, demands[j].c2
        is_edge = (
            xs_loc[j] < overhang + 0.5u"ft" ||
            xs_loc[j] > (B - overhang - 0.5u"ft") ||
            ys_loc[j] < overhang + 0.5u"ft" ||
            ys_loc[j] > (Lm - overhang - 0.5u"ft")
        )
        pos_sym = is_edge ? :edge : :interior
        # Corner detection: within tolerance of two edges simultaneously
        n_close_edges = (
            (xs_loc[j] < overhang + 0.5u"ft") +
            (xs_loc[j] > (B - overhang - 0.5u"ft")) +
            (ys_loc[j] < overhang + 0.5u"ft") +
            (ys_loc[j] > (Lm - overhang - 0.5u"ft"))
        )
        is_corner = n_close_edges >= 2
        Ac = if demands[j].shape == :circular
            A_full = π * (c1j + d_eff)^2 / 4
            is_corner ? A_full / 2 :       # 2-sided critical perimeter
            is_edge   ? A_full * 3 / 4 :   # 3-sided critical perimeter
                        A_full              # interior — full perimeter
        else
            is_corner ? (c1j + d_eff / 2) * (c2j + d_eff / 2) :
            is_edge   ? (c1j + d_eff / 2) * (c2j + d_eff) :
                        (c1j + d_eff) * (c2j + d_eff)
        end
        pos_sym = is_corner ? :corner : pos_sym
        Vu_p = max(uconvert(u"lbf", demands[j].Pu - qu * Ac), 0.0u"lbf")
        pch = punching_check(Vu_p, demands[j].Mux, demands[j].Muy,
                              d_eff, fc, c1j, c2j;
                              position = pos_sym, shape = demands[j].shape,
                              λ = λ, ϕ = ϕv)
        util = max(util, pch.utilization)
    end
    return util
end

"""
    _mat_build_result(plan, demands, opts, h, d_eff, As_x_bot, As_x_top,
                      As_y_bot, As_y_top, utilization) → MatFootingResult

Shared result construction: compute volumes and return MatFootingResult in SI.
"""
function _mat_build_result(
    plan, demands, opts,
    h, d_eff,
    As_x_bot, As_x_top, As_y_bot, As_y_top,
    utilization
)
    B, Lm = plan.B, plan.Lm
    cover = opts.cover
    N = length(demands)

    V_conc = uconvert(u"m^3", B * Lm * h)

    Ab_x = bar_area(opts.bar_size_x)
    Ab_y = bar_area(opts.bar_size_y)
    n_xb = ceil(Int, As_x_bot / Ab_x)
    n_xt = ceil(Int, As_x_top / Ab_x)
    n_yb = ceil(Int, As_y_bot / Ab_y)
    n_yt = ceil(Int, As_y_top / Ab_y)
    len_x = B  - 2cover
    len_y = Lm - 2cover
    V_steel = uconvert(u"m^3",
        (n_xb + n_xt) * Ab_x * len_x +
        (n_yb + n_yt) * Ab_y * len_y)

    return MatFootingResult{typeof(uconvert(u"m", B)),
                            typeof(uconvert(u"m^2", As_x_bot)),
                            typeof(V_conc),
                            typeof(demands[1].Pu)}(
        uconvert(u"m", B),
        uconvert(u"m", Lm),
        uconvert(u"m", h),
        uconvert(u"m", d_eff),
        uconvert(u"m^2", As_x_bot),
        uconvert(u"m^2", As_x_top),
        uconvert(u"m^2", As_y_bot),
        uconvert(u"m^2", As_y_top),
        N,
        V_conc, V_steel,
        utilization,
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# Public API — dispatches on analysis_method
# ─────────────────────────────────────────────────────────────────────────────

"""
    design_footing(::MatFoundation, demands, positions, soil; opts) → MatFootingResult

Design a mat foundation per ACI 336.2R / ACI 318-11.

Dispatches on `opts.analysis_method`:
- `RigidMat()`   — rigid body, strip statics (ACI 336.2R §4.2)
- `ShuklaAFM()`  — analytical: Shukla + rigid envelope (ACI 336.2R §6.1.2)
- `WinklerFEA()` — FEA plate on Winkler springs (ACI 336.2R §6.4)

# Arguments
- `demands::Vector{FoundationDemand}`: Factored & service loads per column.
- `positions::Vector{NTuple{2,<:Length}}`: (x, y) column positions.
- `soil::Soil`: `qa` = net allowable bearing pressure; `ks` required for
  flexible methods (ShuklaAFM can derive from q_u if ks is missing).

# Returns
`MatFootingResult` with SI output quantities.
"""
function design_footing(::MatFoundation,
    demands::Vector{<:FoundationDemand},
    positions::Vector{<:NTuple{2, <:Length}},
    soil::Soil;
    opts::MatFootingOptions = MatFootingOptions()
)
    N = length(demands)
    length(positions) == N ||
        throw(DimensionMismatch("positions and demands must match"))

    method = opts.analysis_method
    if method isa RigidMat
        return _design_mat_rigid(demands, positions, soil; opts = opts)
    elseif method isa ShuklaAFM
        return _design_mat_shukla(demands, positions, soil, method; opts = opts)
    elseif method isa WinklerFEA
        return _design_mat_winkler_fea(demands, positions, soil, method; opts = opts)
    else
        error("Unknown mat analysis method: $(typeof(method))")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Rigid Mat Method — ACI 336.2R-88 §4.2 (Kramrisch strip statics)
# ─────────────────────────────────────────────────────────────────────────────

"""
Governing moment for a strip of the mat in one direction.

Treats column-line strips as continuous beams: negative ≈ wL²/10,
positive ≈ wL²/12 (interior); end spans use wL²/11.

Returns (M_pos, M_neg) both as positive Unitful Torques.
"""
function _rigid_mat_strip_moments(qu::Pressure, trib_width::Length,
                                   spans::Vector{<:Length})
    w = qu * trib_width  # force per length

    M_neg = zero(w * spans[1]^2)
    M_pos = zero(w * spans[1]^2)

    n = length(spans)
    for (i, Ls) in enumerate(spans)
        wL2 = w * Ls^2
        if n == 1
            M_neg = max(M_neg, wL2 / 2)
        elseif i == 1 || i == n
            M_neg = max(M_neg, wL2 / 10)
            M_pos = max(M_pos, wL2 / 11)
        else
            M_neg = max(M_neg, wL2 / 10)
            M_pos = max(M_pos, wL2 / 12)
        end
    end

    return (M_pos = M_pos, M_neg = M_neg)
end

"""
    _design_mat_rigid(demands, positions, soil; opts) → MatFootingResult

Rigid mat analysis: uniform pressure, strip statics for moments, punching
shear at each column.  Reference: ACI 336.2R-88 §4.2.
"""
function _design_mat_rigid(
    demands::Vector{<:FoundationDemand},
    positions::Vector{<:NTuple{2, <:Length}},
    soil::Soil;
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

    # ── Step 1: Plan Sizing (first-principles overhang) ──
    plan = _mat_plan_sizing(positions, opts; demands = demands, soil = soil)
    B, Lm = plan.B, plan.Lm

    Pu_total = sum(d.Pu for d in demands)
    Ps_total = sum(d.Ps for d in demands)
    qu = Pu_total / (B * Lm)

    # Bearing utilization
    util_bearing = to_kip(Ps_total) / to_kip(soil.qa * B * Lm)
    util_bearing > 1.0 && @warn "Mat bearing exceeds allowable: util=$(round(util_bearing, digits=3))"

    # ── Step 2: Thickness from Punching Shear (per-column dimensions) ──
    # Uses _mat_punching_util (with corner detection) so thickness iteration
    # and final utilization are computed by the same code path.
    h = opts.min_depth
    h_incr = opts.depth_increment

    for iter in 1:60
        d_eff = h - cover - max(db_x, db_y)
        d_eff < 6.0u"inch" && (h += h_incr; continue)

        util_p = _mat_punching_util(demands, plan, qu, d_eff, fc, λ, ϕv)
        util_p ≤ 1.0 && break
        h += h_incr
        iter == 60 && @warn "Mat footing thickness did not converge at h=$h"
    end

    d_eff = h - cover - max(db_x, db_y)

    # ── Step 4: Flexural Reinforcement via Strip Statics ──
    avg_trib_x = isempty(plan.y_spans) ? Lm : sum(plan.y_spans) / length(plan.y_spans)
    mom_x = _rigid_mat_strip_moments(qu, avg_trib_x, plan.x_spans)

    avg_trib_y = isempty(plan.x_spans) ? B : sum(plan.x_spans) / length(plan.x_spans)
    mom_y = _rigid_mat_strip_moments(qu, avg_trib_y, plan.y_spans)

    As_x_bot = max(_flexural_steel_footing(mom_x.M_pos, Lm, d_eff, fc, fy, ϕf),
                   _min_steel_footing(Lm, h, fy))
    As_x_top = max(_flexural_steel_footing(mom_x.M_neg, Lm, d_eff, fc, fy, ϕf),
                   _min_steel_footing(Lm, h, fy))
    As_y_bot = max(_flexural_steel_footing(mom_y.M_pos, B, d_eff, fc, fy, ϕf),
                   _min_steel_footing(B, h, fy))
    As_y_top = max(_flexural_steel_footing(mom_y.M_neg, B, d_eff, fc, fy, ϕf),
                   _min_steel_footing(B, h, fy))

    # ── Step 5: Relative Stiffness (Kr) — informational ──
    if soil.ks !== nothing
        Ec_psi = ustrip(u"psi", Ec(fc))
        Ig_in4 = ustrip(u"inch", B) * ustrip(u"inch", h)^3 / 12.0
        ks_pci = ustrip(u"lbf/inch^3", soil.ks)
        Kr = Ec_psi * Ig_in4 / (ks_pci * ustrip(u"inch", B) * ustrip(u"inch", Lm)^3)
        Kr < 0.5 && @warn "Kr=$(round(Kr, digits=3)) < 0.5 — flexible analysis may be needed"
    end

    # ── Utilization ──
    util_punch = _mat_punching_util(demands, plan, qu, d_eff, fc, λ, ϕv)
    utilization = max(util_bearing, util_punch)

    return _mat_build_result(plan, demands, opts, h, d_eff,
                             As_x_bot, As_x_top, As_y_bot, As_y_top,
                             utilization)
end
