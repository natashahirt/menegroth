# =============================================================================
# ACI 318-11 Spread (Isolated) Footing Design
# =============================================================================
#
# Full 7-step StructurePoint workflow:
#   1. Preliminary sizing (service loads → required area)
#   2. Two-way (punching) shear → minimum thickness
#   3. One-way (beam) shear → minimum thickness
#   4. Flexural reinforcement at face of column
#   5. Development length check
#   6. Column-footing bearing check (ACI 22.8)
#   7. Dowel design if bearing is insufficient
#
# Fully Unitful throughout — only strips at ACI √f'c formula boundaries.
# Uses shared punching_check() with biaxial unbalanced moment transfer.
# Reference: StructurePoint ACI 318-11, Wight 7th Ed. Ex 15-2.
# =============================================================================

# =============================================================================
# Solver Trace Contract (manual registry; function is documented)
# =============================================================================
TRACE_REGISTRY[(:design_footing, :checker)] =
    TracedFunctionMeta(:design_footing, :checker,
                       [:enter, :exit, :decision, :iteration, :failure], nothing,
                       @__FILE__, @__LINE__)

# ─────────────────────────────────────────────────────────────────────────────
# Internal Unitful helpers (also used by strip & mat footings)
# ─────────────────────────────────────────────────────────────────────────────

"""
Compute required flexural reinforcement for a rectangular section.

Iterates on lever arm jd until convergence. Returns total As for width `b`.
"""
function _flexural_steel_footing(Mu::Torque, b::Length, d::Length,
                                  fc::Pressure, fy::Pressure, ϕf::Float64)
    to_kipft(Mu) ≤ 0.0 && return 0.0u"inch^2"
    ustrip(fy) > 0 || throw(ArgumentError("fy must be positive"))
    ustrip(fc) > 0 || throw(ArgumentError("fc must be positive"))
    ustrip(b) > 0 || throw(ArgumentError("b must be positive"))
    ustrip(d) > 0 || throw(ArgumentError("d must be positive"))

    jd = 0.95 * d
    As = Mu / (ϕf * fy * jd)

    for _ in 1:20
        a = As * fy / (0.85 * fc * b)
        jd_new = max(d - a / 2, 0.5d)
        As_new = Mu / (ϕf * fy * jd_new)
        if abs(ustrip(u"inch^2", As_new - As)) < 0.001
            As = As_new
            break
        end
        As = As_new
    end

    # Tension-controlled check (ACI 21.2.2)
    a = As * fy / (0.85 * fc * b)
    β1_val = beta1(fc)
    c_depth = a / β1_val
    if ustrip(u"inch", c_depth) > 0
        εcu = 0.003  # ACI 318-11 §10.2.3
        εt = εcu * (d / c_depth - 1.0)
        εt < 0.005 && @warn "Section not tension-controlled (εt=$(round(εt, digits=4)))"
    end

    return As
end

"""ACI 7.6.1.1 — minimum reinforcement for footings (temperature/shrinkage)."""
function _min_steel_footing(b::Length, h::Length, fy::Pressure)
    fy_psi = ustrip(u"psi", fy)
    ρ_min = fy_psi ≤ 60000.0 ? 0.0018 : max(0.0014, 0.0018 * 60000.0 / fy_psi)
    return ρ_min * b * h
end

"""ACI 25.4.2 — simplified development length for deformed bars in tension."""
function _development_length_footing(bar_size::Int, fc::Pressure, fy::Pressure,
                                      λ::Float64, db::Length)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    fy_psi  = ustrip(u"psi", fy)
    db_in   = ustrip(u"inch", db)
    coeff   = bar_size ≤ 6 ? 25.0 : 20.0
    ld_in   = (fy_psi / (coeff * λ * sqrt_fc)) * db_in   # ψt = ψe = 1.0
    return max(ld_in, 12.0) * u"inch"
end

"""ACI 22.8 — bearing check at column-footing interface."""
function _bearing_check_footing(Pu::Force, c1::Length, c2::Length,
                                 B::Length, Lf::Length, h::Length,
                                 fc::Pressure, fc_col::Pressure,
                                 fy::Pressure, ϕb::Float64,
                                 pier_shape::Symbol)
    A1 = pier_shape == :circular ? π * (c1 / 2)^2 : c1 * c2

    if pier_shape == :circular
        A2 = π * (min(c1 + 4h, min(B, Lf)) / 2)^2
    else
        A2 = min(c1 + 4h, Lf) * min(c2 + 4h, B)
    end

    sqA = min(sqrt(A2 / A1), 2.0)
    Bn_footing = ϕb * min(0.85 * fc * A1 * sqA, 2 * 0.85 * fc * A1)
    Bn_column  = ϕb * 0.85 * fc_col * A1

    need_dowels = Pu > Bn_column
    As_dowels = 0.0u"inch^2"
    if need_dowels
        As_dowels = max((Pu - Bn_column) / (ϕb * fy), 0.005 * A1)
    end

    return (Bn_footing = Bn_footing, Bn_column = Bn_column,
            need_dowels = need_dowels, As_dowels = As_dowels,
            footing_ok = Pu ≤ Bn_footing)
end

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

"""
    design_footing(::SpreadFooting, demand, soil; opts) → SpreadFootingResult

Design a spread (isolated) footing per ACI 318-11 with full unbalanced-moment
punching shear transfer (ACI §8.4.4.2).

Uses the StructurePoint 7-step workflow:
1. Preliminary sizing from service loads and net allowable soil pressure
2. Two-way (punching) shear with biaxial Mux/Muy → governs thickness
3. One-way (beam) shear → thickness check
4. Flexural reinforcement at face of column
5. Development length verification
6. Column-footing bearing check (ACI 22.8)
7. Dowel design (if bearing insufficient)

# Arguments
- `demand::FoundationDemand`: Must include `Pu` (factored), `Ps` (service), and column
  geometry `c1`, `c2`, `shape` (used for punching, shear, bearing). `Mux`/`Muy` used for
  eccentric punching shear.
- `soil::Soil`: `qa` = net allowable bearing pressure.

# Keyword Arguments
- `opts::SpreadParams`: Material, cover, depth/size increments, and checks.
  Column dimensions are taken from `demand`, not from `opts`.

# Returns
`SpreadFootingResult` with SI output quantities.

# Example
```julia
d = FoundationDemand(1; Pu=912.0kip, Ps=670.0kip, c1=18u"inch", c2=18u"inch", shape=:rectangular)
s = Soil(5.37ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
opts = SpreadParams(material=RC_3000_60)
result = design_footing(SpreadFooting(), d, s; opts)
```
"""
function design_footing(::SpreadFooting,
    demand::FoundationDemand,
    soil::Soil;
    opts::SpreadParams = SpreadParams(),
    tc::Union{Nothing, TraceCollector} = nothing,
)
    StructuralSizer.emit!(tc, :checker, "design_footing_spread_aci", "foundation_group_$(demand.group_idx)", :enter;
                          qa_kPa=Float64(ustrip(u"kPa", soil.qa)),
                          Pu_kN=Float64(ustrip(u"kN", demand.Pu)),
                          Ps_kN=Float64(ustrip(u"kN", demand.Ps)),
                          c1_in=Float64(ustrip(u"inch", demand.c1)),
                          c2_in=Float64(ustrip(u"inch", demand.c2)),
                          shape=string(demand.shape),
                          min_depth_in=Float64(ustrip(u"inch", opts.min_depth)),
                          depth_increment_in=Float64(ustrip(u"inch", opts.depth_increment)),
                          size_increment_in=Float64(ustrip(u"inch", opts.size_increment)))
    # Column geometry: single source of truth is FoundationDemand (ACI 318-11)
    c1     = demand.c1
    c2     = demand.c2
    col_shape = demand.shape
    # Material / option extraction
    fc     = opts.material.concrete.fc′
    fy     = opts.material.rebar.Fy
    λ      = something(opts.λ, opts.material.concrete.λ)
    fc_col = something(opts.fc_col, fc)
    cover  = opts.cover
    db     = bar_diameter(opts.bar_size)
    Ab     = bar_area(opts.bar_size)
    ϕf     = opts.ϕ_flexure
    ϕv     = opts.ϕ_shear
    ϕb     = opts.ϕ_bearing
    Ps     = demand.Ps
    Pu     = demand.Pu
    qa     = soil.qa

    # =====================================================================
    # Step 1: Preliminary Sizing
    # =====================================================================
    A_req = Ps / qa
    B = sqrt(A_req)

    # Round up to size increment
    si = opts.size_increment
    B = ceil(ustrip(u"inch", B) / ustrip(u"inch", si)) * si

    # Minimum projection each side (6")
    min_B = max(c1, c2) + 2 * 6.0u"inch"
    B = max(B, min_B)
    Lf = B   # square footing

    # Factored net soil pressure
    qu = Pu / (B * Lf)

    # =====================================================================
    # Step 2 & 3: Thickness Iteration (Punching + One-Way Shear)
    # =====================================================================
    h = opts.min_depth
    h_incr = opts.depth_increment
    d = 0.0u"inch"
    punch = nothing

    for iter in 1:60
        d = h - cover - db
        d < 4.0u"inch" && (h += h_incr; continue)

        # Two-way (punching) shear with biaxial moments
        Ac = col_shape == :circular ?
             π * (c1 + d)^2 / 4 : (c1 + d) * (c2 + d)
        Vu_p = qu * (B * Lf - Ac)
        punch = punching_check(Vu_p, demand.Mux, demand.Muy, d, fc, c1, c2;
                               position = :interior, shape = col_shape,
                               λ = λ, ϕ = ϕv)

        # One-way shear in both directions
        ϕVc = ϕv * one_way_shear_capacity(fc, B, d; λ = λ)
        cant_x = (Lf - c1) / 2 - d
        cant_y = (B  - c2) / 2 - d
        ow_ok = true
        if cant_x > 0u"inch"
            Vu_x = uconvert(u"lbf", qu * B * cant_x)
            ow_ok = ow_ok && Vu_x ≤ ϕVc
        end
        if cant_y > 0u"inch"
            Vu_y = uconvert(u"lbf", qu * Lf * cant_y)
            ow_ok = ow_ok && Vu_y ≤ ϕVc
        end

        punch.ok && ow_ok && break
        h += h_incr
        if iter == 60
            StructuralSizer.emit!(tc, :checker, "design_footing_spread_aci", "foundation_group_$(demand.group_idx)", :failure;
                                  reason="depth_iteration_nonconvergence",
                                  h_in=Float64(ustrip(u"inch", h)),
                                  last_punch_ok=Bool(punch === nothing ? false : punch.ok),
                                  last_punch_ratio=punch === nothing ? nothing : Float64(punch.utilization),
                                  last_one_way_ok=Bool(ow_ok))
            error("Spread footing depth did not converge after 60 iterations (h=$h). " *
                  "Check bearing pressure, column dimensions, or increase max depth.")
        end
    end
    d = h - cover - db

    # =====================================================================
    # Step 4: Flexural Reinforcement (ACI 7.5)
    # =====================================================================
    cant_x = (Lf - c1) / 2
    cant_y = (B  - c2) / 2
    Mu_x = qu * B  * cant_x^2 / 2
    Mu_y = qu * Lf * cant_y^2 / 2

    As_x = max(_flexural_steel_footing(Mu_x, B,  d, fc, fy, ϕf),
               _min_steel_footing(B, h, fy))
    As_y = max(_flexural_steel_footing(Mu_y, Lf, d, fc, fy, ϕf),
               _min_steel_footing(Lf, h, fy))
    As_gov = max(As_x, As_y)

    # Bar selection
    n_bars = max(ceil(Int, As_gov / Ab), 2)
    max_s  = min(3h, 18.0u"inch")               # ACI 7.7.2.3
    n_bars = max(n_bars, ceil(Int, B / max_s))
    As_provided = n_bars * Ab

    # =====================================================================
    # Step 5: Development Length (ACI 25.4.2)
    # =====================================================================
    if opts.check_development
        ld    = _development_length_footing(opts.bar_size, fc, fy, λ, db)
        avail = min(cant_x, cant_y) - cover
        ld > avail && @warn "Development length: ld=$ld > available=$avail"
    end

    # =====================================================================
    # Step 6 & 7: Bearing & Dowels (ACI 22.8)
    # =====================================================================
    if opts.check_bearing
        bearing = _bearing_check_footing(Pu, c1, c2, B, Lf, h,
                                          fc, fc_col, fy, ϕb, col_shape)
        bearing.need_dowels && opts.check_dowels &&
            @info "Dowels required: As_dowels = $(bearing.As_dowels)"
    end

    # =====================================================================
    # Utilization
    # =====================================================================
    util_bearing = to_kip(Ps) / to_kip(qa * B * Lf)
    utilization  = max(punch.utilization, util_bearing)

    # =====================================================================
    # Result (SI output)
    # =====================================================================
    V_conc  = uconvert(u"m^3", B * Lf * h)
    bar_len = B - 2cover
    V_steel = uconvert(u"m^3", 2 * n_bars * Ab * bar_len)

    result = SpreadFootingResult{typeof(uconvert(u"m", B)),
                               typeof(V_conc),
                               typeof(Pu)}(
        uconvert(u"m", B),
        uconvert(u"m", Lf),
        uconvert(u"m", h),
        uconvert(u"m", d),
        uconvert(u"m", As_provided / B),   # As per unit width (m²/m = m)
        n_bars,
        uconvert(u"m", db),
        V_conc,
        V_steel,
        utilization,
    )
    StructuralSizer.emit!(tc, :checker, "design_footing_spread_aci", "foundation_group_$(demand.group_idx)", :exit;
                          B_m=Float64(ustrip(u"m", result.B)),
                          L_m=Float64(ustrip(u"m", result.L_ftg)),
                          D_m=Float64(ustrip(u"m", result.D)),
                          utilization=Float64(result.utilization))
    return result
    # (unreachable) — kept to avoid accidentally placing emit! after return
end
