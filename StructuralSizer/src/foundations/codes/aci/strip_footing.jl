# =============================================================================
# ACI 318-11 Strip / Combined Footing Design (Rigid Analysis)
# =============================================================================
#
# Supports N ≥ 2 columns along a single line.
# Assumes rigid footing (Kr > 0.5) → uniform or linear soil pressure.
#
# Workflow:
#   1. Plan sizing (L, B) to align centroid with load resultant
#   2. Shear and moment diagrams via statics
#   3. Two-way (punching) shear at each column
#   4. One-way (beam) shear at critical sections
#   5. Longitudinal reinforcement (top + bottom)
#   6. Transverse reinforcement under column bands
#   7. Development length check (ACI 25.4.2)
#   8. Column-footing bearing & dowels at each column (ACI 22.8)
#
# Fully Unitful throughout — uses shared punching_check() with unbalanced moments.
# Reference: StructurePoint ACI 318-11 Combined Footing, Wight 7th Ed. Ex 15-5.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

"""
Compute shear V(x) and moment M(x) along a rigid strip footing via statics.

Columns apply downward point loads; uniform soil pressure acts upward.
Returns `(x, V, M)` vectors at `n_pts` stations along `[0, L]`.

NOTE: This function briefly strips units internally for the tight numerical
loop, then re-tags the output (legitimate boundary per Asap convention).
"""
function _strip_VM_diagram(L::Length, B::Length, qu::Pressure,
                            col_pos::Vector{<:Length},
                            col_Pu::Vector{<:Force};
                            n_pts::Int = 500)
    # Strip to common units for the numerical loop
    L_ft  = ustrip(u"ft", L)
    B_ft  = ustrip(u"ft", B)
    qu_ksf = ustrip(ksf, qu)
    pos_ft = [ustrip(u"ft", p) for p in col_pos]
    Pu_kip = [to_kip(P) for P in col_Pu]

    w = qu_ksf * B_ft  # kip/ft upward
    xs  = collect(range(0.0, L_ft, length = n_pts))
    Vv  = zeros(n_pts)
    Mv  = zeros(n_pts)

    for i in 1:n_pts
        x = xs[i]
        V_soil = w * x
        V_cols = 0.0
        M_cols = 0.0
        for (xc, Pc) in zip(pos_ft, Pu_kip)
            if xc ≤ x + 1e-6
                V_cols += Pc
                M_cols += Pc * (x - xc)
            end
        end
        Vv[i] = V_soil - V_cols
        Mv[i] = w * x^2 / 2.0 - M_cols
    end

    # Re-tag
    return (x_ft = xs, V_kip = Vv, M_kipft = Mv)
end

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

"""
    design_footing(::StripFooting, demands, positions, soil; opts) → StripFootingResult

Design a strip (combined) footing supporting N ≥ 2 columns per ACI 318-11.

Rigid analysis: uniform soil pressure when the footing centroid aligns with
the resultant of column loads.  Punching check at each column includes
unbalanced moments from `FoundationDemand.Mux`/`Muy`.

Includes development length verification (ACI 25.4.2) and column-footing
bearing check with dowel design (ACI 22.8) at each column.

# Arguments
- `demands::Vector{FoundationDemand}`: Factored & service loads per column.
- `positions::Vector{<:Length}`: Column center-line positions along strip axis.
- `soil::Soil`: `qa` = net allowable bearing pressure.

# Keyword Arguments
- `opts::StripFootingOptions`

# Returns
`StripFootingResult` with SI output quantities.
"""
function design_footing(::StripFooting,
    demands::Vector{<:FoundationDemand},
    positions::Vector{<:Length},
    soil::Soil;
    opts::StripFootingOptions = StripFootingOptions()
)
    N = length(demands)
    N ≥ 2 || throw(ArgumentError("Strip footing requires ≥ 2 columns (got $N)"))
    length(positions) == N ||
        throw(DimensionMismatch("positions length must match demands"))

    # Material / options
    fc     = opts.material.concrete.fc′
    fy     = opts.material.rebar.Fy
    λ      = something(opts.λ, opts.material.concrete.λ)
    cover  = opts.cover
    db_l   = bar_diameter(opts.bar_size_long)
    db_t   = bar_diameter(opts.bar_size_trans)
    ϕf     = opts.ϕ_flexure
    ϕv     = opts.ϕ_shear
    w_incr = opts.width_increment

    # Per-column dimensions from demands (c1, c2, shape).

    # =====================================================================
    # Step 1: Plan Sizing
    # =====================================================================
    Pu_vec = [d.Pu for d in demands]
    Ps_vec = [d.Ps for d in demands]
    Pu_total = sum(Pu_vec)
    Ps_total = sum(Ps_vec)

    # Load resultant position
    x_bar = sum(Ps_vec .* positions) / Ps_total

    x_min = minimum(positions)
    x_max = maximum(positions)

    # Symmetric footing about resultant → L/2 each side
    half_L_left  = x_bar - x_min + 1.0u"ft"
    half_L_right = x_max - x_bar + 1.0u"ft"
    half_L = max(half_L_left, half_L_right)
    L = 2 * half_L

    # Round up to increment
    L = ceil(ustrip(u"inch", L) / ustrip(u"inch", w_incr)) * w_incr

    # Column positions relative to left edge of footing
    x_left = x_bar - L / 2
    col_pos_local = positions .- x_left

    # Minimum width from bearing (service loads); will be widened if h becomes
    # unreasonable — an engineer would never draw a footing deeper than wide.
    B_min = Ps_total / (soil.qa * L)
    B_min = ceil(ustrip(u"inch", B_min) / ustrip(u"inch", w_incr)) * w_incr
    B_min = max(B_min, 2.0u"ft")
    B = B_min

    # =====================================================================
    # Steps 2–3: Iterate (B, h) — widen B when h exceeds practical limits
    # =====================================================================
    # Inner loop: ratchet h up for fixed B until shear OK.
    # Outer loop: if h > max_depth_ratio × B, widen B and restart h.
    # This mirrors what an engineer does: narrow strips → too deep → widen.
    h_ratio = opts.max_depth_ratio       # default 0.5 (Wight Ex 15-5: h/B ≈ 0.42)
    h = opts.min_depth
    h_incr = opts.depth_increment
    converged = false

    for _outer in 1:30     # outer B-widening loop
        qu = Pu_total / (B * L)
        h = opts.min_depth
        depth_ok = false

        for iter in 1:80       # inner h-ratchet loop
            d = h - cover - db_l
            d < 4.0u"inch" && (h += h_incr; continue)

            # --- Two-way (punching) at each column ---
            all_punch_ok = true
            for (j, xc) in enumerate(col_pos_local)
                cj1 = demands[j].c1
                cj2 = demands[j].c2
                d_ft = ustrip(u"ft", d)
                is_edge = (j == 1 && ustrip(u"ft", xc) < d_ft) ||
                          (j == N && ustrip(u"ft", L - xc) < d_ft)
                pos_sym = is_edge ? :edge : :interior

                Ac = (cj1 + d) * (cj2 + d)
                if is_edge
                    Ac = (cj1 + d / 2) * (cj2 + d)
                end
                Vu_p = uconvert(u"lbf", demands[j].Pu - qu * Ac)
                Vu_p = max(Vu_p, 0.0u"lbf")

                pch = punching_check(Vu_p, demands[j].Mux, demands[j].Muy,
                                      d, fc, cj1, cj2;
                                      position = pos_sym, shape = demands[j].shape,
                                      λ = λ, ϕ = ϕv)
                if !pch.ok
                    all_punch_ok = false
                    break
                end
            end

            # --- One-way shear from V(x) diagram ---
            ϕVc = ϕv * one_way_shear_capacity(fc, B, d; λ = λ)
            ϕVc_kip = to_kip(ϕVc)
            d_ft = ustrip(u"ft", d)
            # Per-column c1 half-widths for critical section offset
            col_c1_ft = [ustrip(u"ft", demands[j].c1) for j in 1:N]
            diag_t = _strip_VM_diagram(L, B, qu, col_pos_local, Pu_vec)
            Vu_max_kip = 0.0
            for (i, x) in enumerate(diag_t.x_ft)
                min_dist = minimum(abs(x - ustrip(u"ft", col_pos_local[j])) - col_c1_ft[j] / 2
                                   for j in 1:N)
                if min_dist ≥ d_ft - 0.01
                    Vu_max_kip = max(Vu_max_kip, abs(diag_t.V_kip[i]))
                end
            end
            ow_ok = Vu_max_kip ≤ ϕVc_kip

            if all_punch_ok && ow_ok
                depth_ok = true
                break
            end
            h += h_incr
        end

        # If shear is satisfied AND h is practical, accept this B
        if depth_ok && h ≤ h_ratio * B
            converged = true
            break
        end

        # Otherwise widen B and retry
        B += w_incr
    end
    converged || @warn "Strip footing (B, h) did not converge; B=$B, h=$h"

    d = h - cover - db_l

    # Recompute qu for the final B
    qu = Pu_total / (B * L)

    # =====================================================================
    # Step 4: Longitudinal Reinforcement
    # =====================================================================
    diag = _strip_VM_diagram(L, B, qu, col_pos_local, Pu_vec)
    M_max_pos = maximum(diag.M_kipft) * kip * u"ft"        # sagging (bottom tension)
    M_max_neg = -minimum(diag.M_kipft) * kip * u"ft"       # hogging (top tension)

    As_top = _flexural_steel_footing(M_max_neg, B, d, fc, fy, ϕf)
    As_bot = _flexural_steel_footing(M_max_pos, B, d, fc, fy, ϕf)

    # Minimum (beam ACI 9.6.1.2 + slab 7.6.1.1)
    fc_psi = ustrip(u"psi", fc)
    fy_psi = ustrip(u"psi", fy)
    As_min_beam = max(3.0 * sqrt(fc_psi) / fy_psi, 200.0 / fy_psi) *
                  ustrip(u"inch", B) * ustrip(u"inch", d) * u"inch^2"
    As_min_slab = _min_steel_footing(B, h, fy)
    As_min = max(As_min_beam, As_min_slab)

    As_top = max(As_top, As_min)
    As_bot = max(As_bot, As_min)

    # =====================================================================
    # Step 5: Transverse Reinforcement (under column bands)
    # =====================================================================
    # Use max c2 across all columns for governing transverse cantilever.
    c2_max = maximum(dem.c2 for dem in demands)
    c1_max = maximum(dem.c1 for dem in demands)
    cant_trans = (B - c2_max) / 2
    Mu_trans_per_ft = qu * cant_trans^2 / 2     # moment per unit length
    band_w = c1_max + d
    Mu_band = Mu_trans_per_ft * band_w
    As_trans = max(_flexural_steel_footing(Mu_band, band_w, d, fc, fy, ϕf),
                   _min_steel_footing(band_w, h, fy))

    # =====================================================================
    # Step 6: Development Length (ACI 25.4.2)
    # =====================================================================
    if opts.check_development
        ld_long = _development_length_footing(opts.bar_size_long, fc, fy, λ, db_l)
        ld_trans = _development_length_footing(opts.bar_size_trans, fc, fy, λ, db_t)

        # Longitudinal bars: available = distance from column face to nearer footing end
        for (j, xc) in enumerate(col_pos_local)
            avail_long = min(xc, L - xc) - demands[j].c1 / 2 - cover
            ld_long > avail_long && @warn(
                "Strip col #$j: longitudinal ld=$ld_long > available=$avail_long")
        end

        # Transverse bars: available = cantilever beyond smallest column (most critical)
        c2_min = minimum(dem.c2 for dem in demands)
        avail_trans = (B - c2_min) / 2 - cover
        ld_trans > avail_trans && @warn(
            "Strip transverse: ld=$ld_trans > available=$avail_trans")
    end

    # =====================================================================
    # Step 7: Bearing & Dowels at Each Column (ACI 22.8)
    # =====================================================================
    if opts.check_bearing
        fc_col_val = something(opts.fc_col, fc)
        ϕb = opts.ϕ_bearing
        for (j, dem) in enumerate(demands)
            bearing = _bearing_check_footing(
                dem.Pu, dem.c1, dem.c2, B, L, h,
                fc, fc_col_val, fy, ϕb, dem.shape)
            if bearing.need_dowels && opts.check_dowels
                @info "Strip col #$j: dowels required, As_dowels = $(bearing.As_dowels)"
            end
            if !bearing.footing_ok
                @warn "Strip col #$j: bearing capacity exceeded " *
                      "(Pu=$(round(to_kip(dem.Pu), digits=0)) kip, " *
                      "Bn=$(round(to_kip(bearing.Bn_footing), digits=0)) kip)"
            end
        end
    end

    # =====================================================================
    # Utilization
    # =====================================================================
    util_bearing = to_kip(Ps_total) / to_kip(soil.qa * B * L)

    util_punch = 0.0
    for (j, xc) in enumerate(col_pos_local)
        cj1, cj2 = demands[j].c1, demands[j].c2
        d_ft = ustrip(u"ft", d)
        is_edge = (j == 1 && ustrip(u"ft", xc) < d_ft) ||
                  (j == N && ustrip(u"ft", L - xc) < d_ft)
        pos_sym = is_edge ? :edge : :interior
        Ac = is_edge ? (cj1 + d / 2) * (cj2 + d) :
                       (cj1 + d) * (cj2 + d)
        Vu_p = max(uconvert(u"lbf", demands[j].Pu - qu * Ac), 0.0u"lbf")
        pch = punching_check(Vu_p, demands[j].Mux, demands[j].Muy,
                              d, fc, cj1, cj2;
                              position = pos_sym, shape = demands[j].shape,
                              λ = λ, ϕ = ϕv)
        util_punch = max(util_punch, pch.utilization)
    end

    utilization = max(util_bearing, util_punch)

    # =====================================================================
    # Result (SI output)
    # =====================================================================
    As_top_m2 = uconvert(u"m^2", As_top)
    As_bot_m2 = uconvert(u"m^2", As_bot)
    As_trans_m2 = uconvert(u"m^2", As_trans)

    V_conc = uconvert(u"m^3", B * L * h)

    # Approximate steel volume
    Ab_l = bar_area(opts.bar_size_long)
    Ab_t = bar_area(opts.bar_size_trans)
    n_top  = ceil(Int, As_top / Ab_l)
    n_bot  = ceil(Int, As_bot / Ab_l)
    n_tran = ceil(Int, As_trans / Ab_t)
    bar_len_long  = L - 2cover
    bar_len_trans = B - 2cover
    V_steel = uconvert(u"m^3",
        (n_top + n_bot) * Ab_l * bar_len_long +
        N * n_tran * Ab_t * bar_len_trans)

    return StripFootingResult{typeof(uconvert(u"m", B)),
                              typeof(As_bot_m2),
                              typeof(V_conc),
                              typeof(demands[1].Pu)}(
        uconvert(u"m", B),
        uconvert(u"m", L),
        uconvert(u"m", h),
        uconvert(u"m", d),
        As_bot_m2, As_top_m2, As_trans_m2,
        N,
        V_conc, V_steel,
        utilization,
    )
end

