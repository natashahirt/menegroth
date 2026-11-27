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
#   7. Development length check (ACI 318-11 §12.2 / §15.6.3)
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
                            n_pts::Int = 500,
                            include_stations::Bool = false,
                            ex::Length = 0.0u"ft")
    # Strip to common units for the numerical loop
    L_ft  = ustrip(u"ft", L)
    B_ft  = ustrip(u"ft", B)
    qu_ksf = ustrip(ksf, qu)
    pos_ft = [ustrip(u"ft", p) for p in col_pos]
    Pu_kip = [to_kip(P) for P in col_Pu]
    ex_ft = ustrip(u"ft", ex)

    w = qu_ksf * B_ft  # kip/ft upward at the average pressure
    xs  = collect(range(0.0, L_ft, length = n_pts))
    # The positive peak sits at a column. A uniform grid can step over it.
    if include_stations
        xs = sort(unique(vcat(xs, [p for p in pos_ft if 0.0 <= p <= L_ft])))
    end
    Vv  = zeros(length(xs))
    Mv  = zeros(length(xs))

    # ACI 336.2R §3.2.1 Eq. (3-1) (corpus: aci-336-combined-footings-mats,
    # page 6): q = (P/A)(1 ± 6e/L) along the strip when the resultant is
    # offset by `ex` and the whole base stays in compression. The width
    # integral of that line is w(x) = w (1 + 6 (ex/L) (2x/L − 1)). `ex = 0`
    # keeps the uniform expressions below, unchanged.
    linear = L_ft > 0 && abs(ex_ft) > 1e-9
    k = linear ? 6 * ex_ft / L_ft : 0.0

    for i in eachindex(xs)
        x = xs[i]
        V_cols = 0.0
        M_cols = 0.0
        for (xc, Pc) in zip(pos_ft, Pu_kip)
            if xc ≤ x + 1e-6
                V_cols += Pc
                M_cols += Pc * (x - xc)
            end
        end
        if linear
            V_soil = w * ((1 - k) * x + k * x^2 / L_ft)
            M_soil = w * ((1 - k) * x^2 / 2 + (2 * k / L_ft) * x^3 / 6)
        else
            V_soil = w * x
            M_soil = w * x^2 / 2.0
        end
        Vv[i] = V_soil - V_cols
        Mv[i] = M_soil - M_cols
    end

    # Re-tag
    return (x_ft = xs, V_kip = Vv, M_kipft = Mv)
end

"""
    _strip_free_edge_parallel(strip_axis) → Symbol

Map strip layout axis to `free_edge_parallel` for the free END.

Production `FoundationDemand.c1` is `column.c1` (∥ global X at θ = 0;
`StructuralSynthesizer` members.jl). `_support_positions_along_axis`
lays the strip on Y when Δy > Δx. The free end is the short edge,
perpendicular to the strip axis:

- `:y` (Y-layout): free end along X = named c1 → `:c1` (ACI c1 = named c2)
- `:x` (X-layout): free end along Y = named c2 → `:c2` (named c1 already perp)

ACI 318-11 R11.11.7.2 (corpus: aci-318-11, pages 209–211). Do not invent
a swap on X-layout.
"""
function _strip_free_edge_parallel(strip_axis::Symbol)
    strip_axis === :y && return :c1
    strip_axis === :x && return :c2
    throw(ArgumentError("strip_axis must be :x or :y; got :$strip_axis"))
end

"""
    _strip_edge_Ac(c1, c2, d, is_edge, edge_par)

Plan area inside the punching critical section for `Vu = Pu − qu·Ac`.

ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200): critical section at
d/2 from each column face. Interior: `(c1 + d)×(c2 + d)`. Edge, on ACI
axes (c1 perp to the free end, R11.11.7.2 pages 209–211):
`(c1 + d/2)×(c2 + d)`. When `edge_par === :c1` the named axes swap so
`Ac = (named_c2 + d/2)×(named_c1 + d)`.
"""
function _strip_edge_Ac(c1, c2, d, is_edge::Bool, edge_par::Symbol)
    is_edge || return (c1 + d) * (c2 + d)
    return edge_par === :c1 ?
        (c2 + d / 2) * (c1 + d) :
        (c1 + d / 2) * (c2 + d)
end

"""
    _strip_c_across_along(c1, c2, strip_axis) → (c_across, c_along)

Across-strip face (transverse cantilever / transverse ld) is named c1
on a Y-layout (B is in X) and named c2 on an X-layout. Along-strip face
(band width / longitudinal ld) is the other. Same mapping as the one-way
face offset (ACI 318-11 §11.1.3.1, corpus: aci-318-11, page 166).
"""
function _strip_c_across_along(c1, c2, strip_axis::Symbol)
    strip_axis === :y && return (c1, c2)
    strip_axis === :x && return (c2, c1)
    throw(ArgumentError("strip_axis must be :x or :y; got :$strip_axis"))
end

"""
    _strip_flexure_pairs(diag, B, qu, d, demands, strip_axis) -> Vector

`(Mu, b)` for every flexural section the strip design reinforces: the peak
sagging and hogging moments over width `B` (Step 4), and each column's
transverse band, width `c_along + d`, with Mu at the column face (§15.4.2,
Step 5). The depth search checks all of them for tension control.
"""
function _strip_flexure_pairs(diag, B, qu, d, demands, strip_axis::Symbol)
    pairs = Any[(maximum(diag.M_kipft) * kip * u"ft", B),
                (-minimum(diag.M_kipft) * kip * u"ft", B)]
    for dem in demands
        c_across, c_along = _strip_c_across_along(dem.c1, dem.c2, strip_axis)
        bw = c_along + d
        push!(pairs, ((qu * ((B - c_across) / 2)^2 / 2) * bw, bw))
    end
    return pairs
end

"""
Moments of one combination about the footing centroid.

`positions` lie on the strip axis. `M_along` is the moment whose
eccentricity runs along that axis, `M_across` the moment across the width.
A vertical force at `x` contributes `P (x − x_c)`. A moment about global y
shifts the resultant along global x, and a moment about global x shifts it
along global y (ACI 336.2R §4.1, corpus: aci-336-combined-footings-mats,
page 7: moments from lateral forces, taken about the centroid).

Returns `(P_N, M_along_Nm, M_across_Nm)`.
"""
function _strip_combo_moments(column_actions, k, positions, x_center, strip_axis)
    P = 0.0
    M_along = 0.0
    M_across = 0.0
    xc = ustrip(u"m", x_center)
    for (j, col) in enumerate(column_actions)
        a = col[k]
        dx = ustrip(u"m", positions[j]) - xc
        P += a.P
        if strip_axis === :x
            M_along += a.P * dx + a.My
            M_across += a.Mx
        else
            M_along += a.P * dx + a.Mx
            M_across += a.My
        end
    end
    return P, M_along, M_across
end

"""
    _strip_aggregate_actions(column_actions, positions, x_bar, strip_axis)
        -> Vector{FootingAction}

One whole-strip rigid-body action per combination for the global-stability
checks (sliding/overturning/uplift). [`_strip_combo_moments`](@ref) gives the
combination's total vertical `ΣP` and the moments about the footing centroid:
`M_along` (eccentricity on the strip axis) goes in the `Mx` slot that
[`footing_stability_utils`](@ref) pairs with `L`, and `M_across` in the `My`
slot paired with `B`. The horizontal base shears sum directly (`ΣHx`, `ΣHy`);
their resultant magnitude is what the sliding check uses, so global x/y axes
are fine. Returns `[]` when there are no per-column actions.
"""
function _strip_aggregate_actions(column_actions, positions, x_bar, strip_axis)
    isempty(column_actions) && return FootingAction[]
    K = length(first(column_actions))
    out = Vector{FootingAction}(undef, K)
    for k in 1:K
        P, M_along, M_across = _strip_combo_moments(
            column_actions, k, positions, x_bar, strip_axis)
        Hx = sum(col[k].Hx for col in column_actions)
        Hy = sum(col[k].Hy for col in column_actions)
        out[k] = FootingAction(first(column_actions)[k].label, P, M_along, M_across, Hx, Hy)
    end
    return out
end

function _strip_validate_actions(column_service, column_strength, n)
    se = isempty(column_service)
    st = isempty(column_strength)
    se == st || throw(ArgumentError(
        "Strip footing: pass both the service and the strength actions, or neither."))
    se && return 0
    length(column_service) == n || throw(ArgumentError(
        "Strip footing: $(length(column_service)) service columns and $n demands."))
    length(column_strength) == n || throw(ArgumentError(
        "Strip footing: $(length(column_strength)) strength columns and $n demands."))
    ns = length(first(column_service))
    nu = length(first(column_strength))
    slab = [a.label for a in first(column_service)]
    ulab = [a.label for a in first(column_strength)]
    for col in column_service
        length(col) == ns || throw(ArgumentError(
            "Strip footing: service combinations are not aligned across columns."))
        [a.label for a in col] == slab || throw(ArgumentError(
            "Strip footing: service combination labels differ between columns."))
    end
    for col in column_strength
        length(col) == nu || throw(ArgumentError(
            "Strip footing: strength combinations are not aligned across columns."))
        [a.label for a in col] == ulab || throw(ArgumentError(
            "Strip footing: strength combination labels differ between columns."))
    end
    return ns
end

"""
`:ok`, `:lengthen`, or `:widen`.

The footing stays centered on the gravity resultant. Each service
combination must keep `q_max ≤ qa` and `q_min ≥ 0`, and each compressive
strength combination must stay in the kern. ACI 336.2R §3.2.1 Eq. (3-1)
(corpus: aci-336-combined-footings-mats, page 6). A resultant outside the
kern is not converted to partial contact.
"""
function _strip_actions_plan_fit(B, L, x_bar, positions,
                                 column_service, column_strength, qa, strip_axis)
    need_len = false
    need_wide = false
    for (actions, service) in ((column_service, true), (column_strength, false))
        isempty(actions) && continue
        for k in eachindex(first(actions))
            P, M_along, M_across = _strip_combo_moments(
                actions, k, positions, x_bar, strip_axis)
            P <= 0 && continue
            qe = _eccentric_soil_pressure(
                P * u"N", M_along * u"N*m", M_across * u"N*m", B, L)
            in_kern = _eccentric_in_kern(qe)
            pressure_ok = !service || qe.q_max <= qa
            in_kern && pressure_ok && continue
            ex = abs(ustrip(u"m", qe.ex))
            ey = abs(ustrip(u"m", qe.ey))
            Lm = ustrip(u"m", L)
            Bm = max(ustrip(u"m", B), 1e-12)
            if !in_kern && Lm > 0 && ex / Lm >= ey / Bm
                need_len = true
            else
                need_wide = true
            end
        end
    end
    need_len && return :lengthen
    need_wide && return :widen
    return :ok
end

"""
Grow `B` and `L` until every combination fits, without moving the centroid
off `x_bar`. Returns `(B, L, col_pos_local)`.
"""
function _grow_strip_plan_for_actions(B, L, x_bar, positions,
                                      column_service, column_strength,
                                      qa, w_incr, strip_axis)
    function placed(Lv)
        x_left = _canonical_ft(x_bar) - Lv / 2
        return [_canonical_ft(p) - x_left for p in positions]
    end
    if isempty(column_service)
        return B, L, placed(L)
    end

    # The strip stays centered on `x_bar`; a failing combination outside the
    # kern lengthens the strip, one over pressure within the kern widens it.
    function step((Bv, Lv))
        fit = _strip_actions_plan_fit(Bv, Lv, x_bar, positions,
                                       column_service, column_strength, qa, strip_axis)
        fit == :ok && return (true, (Bv, Lv))
        fit == :lengthen && return (false, (Bv, _canonical_ft(Lv + w_incr)))
        return (false, (_canonical_inch(Bv + w_incr), Lv))
    end
    onfail((Bv, Lv)) = error(
        "Strip footing plan did not keep every ASCE 7-22 combination in the " *
        "ACI 336.2R §3.2.1 kern, with service q_max ≤ qa, after 80 size " *
        "increments (B=$Bv, L=$Lv). Eq. (3-1) is not applied as full contact " *
        "when q_min < 0 (corpus: aci-336-combined-footings-mats, page 6). " *
        "The centroid stays on the gravity resultant.")
    B, L = _grow_until_fit((B, L); step = step, onfail = onfail)
    return B, L, placed(L)
end

"""
Width-average pressure at `x`, and the pressure at the pressed edge of
the width, from Eq. (3-1).
"""
function _strip_q_station(qu, ex, ey, L, B, x)
    Lf = ustrip(u"m", L)
    Bf = ustrip(u"m", B)
    xf = ustrip(u"m", x)
    along = Lf == 0 ? 0.0 : 6 * ustrip(u"m", ex) / Lf * (2 * xf / Lf - 1)
    across = Bf == 0 ? 0.0 : 6 * abs(ustrip(u"m", ey)) / Bf
    return qu * (1 + along), qu * (1 + along + across)
end

"""
True when this strength combination's own column forces pass punching,
one-way shear, and flexure on the current section.

Longitudinal shear uses the linear soil line from Eq. (3-1). Punching
subtracts the width-average pressure at the column. The transverse
cantilever uses the pressed-edge pressure at that station.
"""
function _strip_one_case_ok(Pu_vec, Mux, Muy, ex, ey, qu, L, B, d,
                            col_pos_local, demands, strip_axis, strip_edge_par,
                            fc, fy, λ, ϕv, ϕf)
    N = length(demands)
    d_ft = ustrip(u"ft", d)
    all_punch_ok = true
    for (j, xc) in enumerate(col_pos_local)
        Pu_vec[j] <= zero(Pu_vec[j]) && continue
        cj1 = demands[j].c1
        cj2 = demands[j].c2
        is_edge = (j == 1 && ustrip(u"ft", xc) < d_ft) ||
                  (j == N && ustrip(u"ft", L - xc) < d_ft)
        pos_sym = is_edge ? :edge : :interior
        Ac = _strip_edge_Ac(cj1, cj2, d, is_edge, strip_edge_par)
        q_col, _ = _strip_q_station(qu, ex, ey, L, B, xc)
        Vu_p = max(uconvert(u"lbf", Pu_vec[j] - q_col * Ac), 0.0u"lbf")
        pch = punching_check(Vu_p, Mux[j], Muy[j], d, fc, cj1, cj2;
                              position = pos_sym, shape = demands[j].shape,
                              λ = λ, ϕ = ϕv,
                              free_edge_parallel = strip_edge_par)
        if !pch.ok
            all_punch_ok = false
            break
        end
    end
    all_punch_ok || return false
    ϕVc_kip = to_kip(ϕv * one_way_shear_capacity(fc, B, d; λ = λ))
    col_face_ft = [ustrip(u"ft", (strip_axis === :y ? demands[j].c2 :
                                  demands[j].c1) / 2) for j in 1:N]
    diag = _strip_VM_diagram(L, B, qu, col_pos_local, Pu_vec; ex = ex)
    Vu_max_kip = 0.0
    for (i, x) in enumerate(diag.x_ft)
        min_dist = minimum(abs(x - ustrip(u"ft", col_pos_local[j])) - col_face_ft[j]
                           for j in 1:N)
        if min_dist ≥ d_ft - 0.01
            Vu_max_kip = max(Vu_max_kip, abs(diag.V_kip[i]))
        end
    end
    Vu_max_kip ≤ ϕVc_kip || return false
    pairs = Any[(maximum(diag.M_kipft) * kip * u"ft", B),
                (-minimum(diag.M_kipft) * kip * u"ft", B)]
    for (j, dem) in enumerate(demands)
        c_across, c_along = _strip_c_across_along(dem.c1, dem.c2, strip_axis)
        bw = c_along + d
        _, q_edge = _strip_q_station(qu, ex, ey, L, B, col_pos_local[j])
        cant = (B - c_across) / 2
        push!(pairs, ((q_edge * cant^2 / 2) * bw, bw))
    end
    return _footing_flexure_ok(pairs, d, fc, fy, ϕf)
end

function _strip_strength_cases_ok(column_strength, positions, x_bar, strip_axis,
                                  L, B, d, col_pos_local, demands, strip_edge_par,
                                  fc, fy, λ, ϕv, ϕf)
    isempty(column_strength) && return true
    N = length(demands)
    for k in eachindex(first(column_strength))
        P, M_along, M_across = _strip_combo_moments(
            column_strength, k, positions, x_bar, strip_axis)
        P <= 0 && continue
        qe = _eccentric_soil_pressure(
            P * u"N", M_along * u"N*m", M_across * u"N*m", B, L)
        _eccentric_in_kern(qe) || return false
        Pu_vec = [column_strength[j][k].P * u"N" for j in 1:N]
        Mux = [column_strength[j][k].Mx * u"N*m" for j in 1:N]
        Muy = [column_strength[j][k].My * u"N*m" for j in 1:N]
        _strip_one_case_ok(Pu_vec, Mux, Muy, qe.ex, qe.ey, qe.qu, L, B, d,
                           col_pos_local, demands, strip_axis, strip_edge_par,
                           fc, fy, λ, ϕv, ϕf) || return false
    end
    return true
end

"""
Largest top, bottom, and transverse areas among the strength combinations,
each designed from that combination's own diagram.
"""
function _strip_strength_steel(column_strength, positions, x_bar, strip_axis,
                               L, B, d, col_pos_local, demands,
                               fc, fy, ϕf)
    z = 0.0u"inch^2"
    As_top = As_bot = As_trans = z
    isempty(column_strength) && return As_top, As_bot, As_trans
    for k in eachindex(first(column_strength))
        P, M_along, M_across = _strip_combo_moments(
            column_strength, k, positions, x_bar, strip_axis)
        P <= 0 && continue
        qe = _eccentric_soil_pressure(
            P * u"N", M_along * u"N*m", M_across * u"N*m", B, L)
        _eccentric_in_kern(qe) || continue
        Pu_vec = [col[k].P * u"N" for col in column_strength]
        diag = _strip_VM_diagram(L, B, qe.qu, col_pos_local, Pu_vec; ex = qe.ex)
        M_pos = maximum(diag.M_kipft) * kip * u"ft"
        M_neg = -minimum(diag.M_kipft) * kip * u"ft"
        As_top = max(As_top, _flexural_steel_footing(M_neg, B, d, fc, fy, ϕf))
        As_bot = max(As_bot, _flexural_steel_footing(M_pos, B, d, fc, fy, ϕf))
        for (j, dem) in enumerate(demands)
            c_across, c_along = _strip_c_across_along(dem.c1, dem.c2, strip_axis)
            bw = c_along + d
            _, q_edge = _strip_q_station(qe.qu, qe.ex, qe.ey, L, B, col_pos_local[j])
            Mu = (q_edge * ((B - c_across) / 2)^2 / 2) * bw
            As_trans = max(As_trans, _flexural_steel_footing(Mu, bw, d, fc, fy, ϕf))
        end
    end
    return As_top, As_bot, As_trans
end

"""
    _strip_tensile_As(demands, ϕ_tension, fy) → As

Total tensile interface steel for columns with `Pu < 0`:

    As = Σ |Pu| / (ϕ_tension · fy)

The interface reinforcement that transfers the net tensile force is a
tension tie, so it is tension-controlled: `ϕ_tension = 0.90` per
ACI 318-11 §9.3.2.1 (corpus: aci-318-11, page 126) — not the bearing
`ϕ = 0.65`. The tie requirement itself is ACI 318-11 §15.8.1.2(b)
(corpus: aci-318-11, page 275). An empty demand list returns zero area.
Compression-only demands also return zero.
"""
function _strip_tensile_As(demands, ϕ_tension, fy)
    As = 0.0u"inch^2"
    isempty(demands) && return As
    zP = zero(first(demands).Pu)
    for dem in demands
        if dem.Pu < zP
            As += abs(dem.Pu) / (ϕ_tension * fy)
        end
    end
    return As
end

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

# =============================================================================
# Solver Trace Contract (manual registry; function is documented)
# =============================================================================
TRACE_REGISTRY[(:design_footing, :checker)] =
    TracedFunctionMeta(:design_footing, :checker,
                       [:enter, :exit, :decision, :iteration, :failure], nothing,
                       @__FILE__, @__LINE__)

"""
    design_footing(::StripFooting, demands, positions, soil; opts) → StripFootingResult

Design a strip (combined) footing supporting N ≥ 2 columns per ACI 318-11.

Rigid analysis: uniform soil pressure when the footing centroid aligns with
the resultant of column loads.  Punching check at each column includes
unbalanced moments from `FoundationDemand.Mux`/`Muy`.

Development is a limit state (ACI 318-11 §15.6.3 / Eq. (12-1)): a bar
that does not fit steps down, then a 90-degree hook, then a longer or
wider plan, and the shear and flexure checks run again. Column-footing
bearing and dowels follow ACI 318-11 §10.14.1.

# Arguments
- `demands::Vector{FoundationDemand}`: Factored & service loads per column.
- `positions::Vector{<:Length}`: Column center-line positions along strip axis.
- `soil::Soil`: `qa` = net allowable bearing pressure.

# Keyword Arguments
- `opts::StripParams`
- `strip_axis`: `:x` (default) or `:y`. Production `FoundationDemand.c1` is
  `column.c1` (∥ global X). Y-layout (`Δy > Δx`) must pass `:y` so the
  free end is treated as parallel to named c1.
- `column_service`, `column_strength`: one [`FootingAction`](@ref) vector
  per column, same combination order on every column. Both empty, or both
  filled. The plan stays centered on the gravity resultant in `demands`.
  Each allowable-stress combination must satisfy ACI 336.2R §3.2.1
  Eq. (3-1) with `q_max ≤ qa`, and each strength combination is designed
  from its own column forces. Empty lists keep the single demand.

# Returns
`StripFootingResult` with SI output quantities.
"""
function design_footing(::StripFooting,
    demands::Vector{<:FoundationDemand},
    positions::Vector{<:Length},
    soil::Soil;
    opts::StripParams = StripParams(),
    tc::Union{Nothing, TraceCollector} = nothing,
    strip_axis::Symbol = :x,
    column_service::Vector{Vector{FootingAction}} = Vector{FootingAction}[],
    column_strength::Vector{Vector{FootingAction}} = Vector{FootingAction}[],
)
    N = length(demands)
    N ≥ 2 || throw(ArgumentError("Strip footing requires ≥ 2 columns (got $N)"))
    length(positions) == N ||
        throw(DimensionMismatch("positions length must match demands"))
    opts.analysis_method isa RigidMat || throw(ArgumentError(
        "A combined column strip is designed as a rigid member (ACI 336.2R " *
        "§5.2, corpus: aci-336-combined-footings-mats, page 9); " *
        "$(typeof(opts.analysis_method)) is a mat/wall method. Use RigidMat(), " *
        "or a mat for a flexible analysis."))
    _strip_validate_actions(column_service, column_strength, N)

    strip_edge_par = _strip_free_edge_parallel(strip_axis)

    StructuralSizer.emit!(tc, :checker, "design_footing_strip_aci", "", :enter;
                          n_columns=N,
                          qa_kPa=Float64(ustrip(u"kPa", soil.qa)))

    # Material / options
    fc     = opts.material.concrete.fc′
    fy     = opts.material.rebar.Fy
    λ      = something(opts.λ, opts.material.concrete.λ)
    cover  = opts.cover
    db_l   = bar_diameter(opts.bar_size_long)
    db_t   = bar_diameter(opts.bar_size_trans)
    ϕf     = opts.ϕ_flexure
    ϕv     = opts.ϕ_shear
    ϕb     = opts.ϕ_bearing
    w_incr = opts.width_increment

    # Per-column dimensions from demands (c1, c2, shape).

    # =====================================================================
    # Step 1: Plan Sizing
    # =====================================================================
    Pu_vec = [d.Pu for d in demands]
    Ps_vec = [d.Ps for d in demands]
    Pu_total = sum(Pu_vec)
    Ps_total = sum(Ps_vec)

    # ACI 318-11 §15.8.1.2(b) (corpus: aci-318-11, page 275): reinforcement,
    # dowels, or mechanical connectors shall transfer any computed tensile
    # force across the interface.  The tie is tension-controlled, so size it
    # with ϕ_flexure = 0.90 (ACI 318-11 §9.3.2.1, corpus: aci-318-11, page
    # 126) — not the bearing ϕ (0.65). Design it into the bar schedule /
    # ld / V_steel — do not leave it as a log-only field.
    As_tensile_tot = _strip_tensile_As(demands, ϕf, fy)
    # A strength combination can put a column in tension that gravity does
    # not. Size the tie for the heaviest combination, not a mix of them.
    # ACI 318-11 §15.8.1.2(b) (corpus: aci-318-11, page 275).
    if !isempty(column_strength)
        for k in eachindex(first(column_strength))
            As_k = 0.0u"inch^2"
            for col in column_strength
                Pk = col[k].P * u"N"
                Pk < zero(Pk) && (As_k += abs(Pk) / (ϕf * fy))
            end
            As_tensile_tot = max(As_tensile_tot, As_k)
        end
    end
    ld_tensile = As_tensile_tot > zero(As_tensile_tot) ?
        _development_length_footing(opts.bar_size_long, fc, fy, λ, db_l;
                                    clear_cover = cover) :
        0.0u"inch"

    # Load resultant of signed service loads (negative = tension). Do not zero
    # tension columns: that drops the couple and parks x_bar on the
    # compression column (ACI 318-11 §15.8.1.2, corpus: aci-318-11, page 275).
    # Existing strip layout — no new eccentricity formula.
    x_bar = sum(Ps_vec .* positions) / Ps_total

    # Whole-strip rigid-body actions for the global-stability checks, built
    # once from the service (ASD) combinations about the fixed centroid x_bar.
    # Opt-in: empty unless `opts.stability` is set and service actions exist.
    stab_actions = (opts.stability !== nothing && !isempty(column_service)) ?
        _strip_aggregate_actions(column_service, positions, x_bar, strip_axis) :
        FootingAction[]

    x_min = minimum(positions)
    x_max = maximum(positions)

    # Symmetric footing about resultant → L/2 each side
    half_L_left  = x_bar - x_min + 1.0u"ft"
    half_L_right = x_max - x_bar + 1.0u"ft"
    half_L = max(half_L_left, half_L_right)
    L = 2 * half_L

    # Round up to increment, then stay in ft. Mixing the ceil result (inch)
    # with x_bar (ft) promotes through SI; converting that Quantity back
    # to inch is FT_TO_M/IN_TO_M, not ×12 — including when the leftover is
    # already inch-tagged. Convert after ustrip(inch) for every unit; the
    # helper snaps |overhang| ≤ 1e-12 in after face subtraction so a
    # flush 1 ft / 24 in face stays exact zero (ACI 318-11 §10.14.1,
    # corpus: aci-318-11, page 162).
    L = _canonical_ft(ceil(ustrip(u"inch", L) / ustrip(u"inch", w_incr)) * w_incr)

    # Column positions relative to left edge of footing. Recomputed when
    # development lengthens the strip, which stays centered on the resultant.
    x_left = _canonical_ft(x_bar) - L / 2
    col_pos_local = [_canonical_ft(p) - x_left for p in positions]

    bar_long = opts.bar_size_long
    bar_trans = opts.bar_size_trans
    anchorage = :straight
    developed = false
    B = 0.0u"inch"
    # Assigned inside the attempt loop. Declared here so the sized
    # section is visible after the loop.
    h = opts.min_depth
    d = h - cover - db_l / 2
    qu = Pu_total / (L * L)
    As_top = As_bot = As_trans = 0.0u"inch^2"
    band_w = 0.0u"inch"
    band_ws = typeof(band_w)[]
    for dev_attempt in 1:40
        x_left = _canonical_ft(x_bar) - L / 2
        col_pos_local = [_canonical_ft(p) - x_left for p in positions]

    # Across-strip face is named c1 on a Y-layout (B ∥ X); named c2 on an X-layout.
    c_across_max = maximum(first(_strip_c_across_along(dem.c1, dem.c2, strip_axis))
                           for dem in demands)

    # Minimum width from bearing (service loads); will be widened if h becomes
    # unreasonable — an engineer would never draw a footing deeper than wide.
    # Floor B at the largest across-strip face so every column face fits.
    # Mu later uses each column's own c_across. A face wider than B would
    # make (B − c_across)/2 negative, and cant² would still invent a moment.
    B_min = Ps_total / (soil.qa * L)
    B_min = ceil(ustrip(u"inch", B_min) / ustrip(u"inch", w_incr)) * w_incr
    # max(inch, 2 ft, c_across) would promote through SI; keep B imperial.
    # A later attempt keeps a width already grown for shear or development.
    B_floor = _canonical_inch(max(B_min, 2.0u"ft", c_across_max))
    # Global-stability width floor (ASCE 7-22 §2.4 counteracting combinations;
    # Bowles 5e §4.x). Growing B adds adhesion area, passive width, and self-
    # weight, so sliding/uplift can only improve as the kern sizing then grows
    # B and L further. Evaluated at min_depth and the current L (both floors):
    # the final thicker, longer footing is strictly more stable. Overturning
    # is left to the stricter kern sizing. No-op when stability is off.
    if !isempty(stab_actions)
        B_floor = _stability_min_width(stab_actions, soil, opts.stability,
                                       L, opts.min_depth, B_floor, w_incr)
    end
    B = dev_attempt == 1 ? B_floor : _canonical_inch(max(B, B_floor))

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
        B, L, col_pos_local = _grow_strip_plan_for_actions(
            B, L, x_bar, positions, column_service, column_strength,
            soil.qa, w_incr, strip_axis)
        qu = Pu_total / (B * L)
        h = opts.min_depth
        depth_ok = false

        for iter in 1:80       # inner h-ratchet loop
            # Effective depth d per ACI 318-11 §2.2 — distance from extreme
            # compression fiber to centroid of longitudinal tension steel
            # (corpus: aci-318-11, page 37).  Single layer ⇒ d = h − cover − db/2.
            d = h - cover - db_l / 2
            d < 4.0u"inch" && (h += h_incr; continue)

            # ACI 318-11 §12.2.1 (corpus: aci-318-11, page 214): ld ≥ 12 in.
            # Tensile interface dowels (15.8.1.2(b), page 275) embed into the
            # footing; require h − cover ≥ ld before accepting this thickness.
            if As_tensile_tot > zero(As_tensile_tot) && opts.check_development
                h - cover < ld_tensile && (h += h_incr; continue)
            end

            # --- Two-way (punching) at each column ---
            all_punch_ok = true
            for (j, xc) in enumerate(col_pos_local)
                # ACI 318-11 §15.8.1.2 — tensile force across the interface
                # is not a punching (compression) demand (corpus: aci-318-11,
                # page 275).
                demands[j].Pu <= zero(demands[j].Pu) && continue
                cj1 = demands[j].c1
                cj2 = demands[j].c2
                d_ft = ustrip(u"ft", d)
                is_edge = (j == 1 && ustrip(u"ft", xc) < d_ft) ||
                          (j == N && ustrip(u"ft", L - xc) < d_ft)
                pos_sym = is_edge ? :edge : :interior

                Ac = _strip_edge_Ac(cj1, cj2, d, is_edge, strip_edge_par)
                Vu_p = uconvert(u"lbf", demands[j].Pu - qu * Ac)
                Vu_p = max(Vu_p, 0.0u"lbf")

                pch = punching_check(Vu_p, demands[j].Mux, demands[j].Muy,
                                      d, fc, cj1, cj2;
                                      position = pos_sym, shape = demands[j].shape,
                                      λ = λ, ϕ = ϕv,
                                      free_edge_parallel = strip_edge_par)
                if !pch.ok
                    all_punch_ok = false
                    break
                end
            end

            # --- One-way shear from V(x) diagram ---
            ϕVc = ϕv * one_way_shear_capacity(fc, B, d; λ = λ)
            ϕVc_kip = to_kip(ϕVc)
            d_ft = ustrip(u"ft", d)
            # ACI 318-11 §11.1.3.1 (corpus: aci-318-11, page 166): Vu at a
            # distance d from the column face. Along-strip face is named c2
            # on a Y-layout (production c1 ∥ X); named c1 on an X-layout.
            col_face_ft = [ustrip(u"ft", (strip_axis === :y ? demands[j].c2 :
                                          demands[j].c1) / 2) for j in 1:N]
            diag_t = _strip_VM_diagram(L, B, qu, col_pos_local, Pu_vec)
            Vu_max_kip = 0.0
            for (i, x) in enumerate(diag_t.x_ft)
                min_dist = minimum(abs(x - ustrip(u"ft", col_pos_local[j])) - col_face_ft[j]
                                   for j in 1:N)
                if min_dist ≥ d_ft - 0.01
                    Vu_max_kip = max(Vu_max_kip, abs(diag_t.V_kip[i]))
                end
            end
            ow_ok = Vu_max_kip ≤ ϕVc_kip
            flex_ok = _footing_flexure_ok(
                _strip_flexure_pairs(diag_t, B, qu, d, demands, strip_axis), d, fc, fy, ϕf)

            combos_ok = _strip_strength_cases_ok(
                column_strength, positions, x_bar, strip_axis,
                L, B, d, col_pos_local, demands, strip_edge_par,
                fc, fy, λ, ϕv, ϕf)
            if all_punch_ok && ow_ok && flex_ok && combos_ok
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

    d = h - cover - db_l / 2  # ACI 318-11 §2.2 — centroid of tension reinforcement

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
    # ACI 318-11 §15.4.1 / §15.4.2(a) (corpus: aci-318-11, pages 272–273):
    # Mu at the face of each column. Across-strip face is named c1 on a
    # Y-layout (B ∥ X); named c2 on an X-layout. Band width is that
    # column's along-strip face + d.
    # Strip width B is still floored at c_across_max (largest column) so
    # the footing covers every face. Each band's cantilever is
    # (B − that column's c_across) / 2. Using c_across_max for every band
    # shortens the cantilever and under-sizes Mu at a smaller column.
    c_across_1, c_along_1 = _strip_c_across_along(demands[1].c1, demands[1].c2, strip_axis)
    bw_1 = c_along_1 + d
    band_ws = Vector{typeof(bw_1)}(undef, N)
    band_ws[1] = bw_1
    Mu_1 = (qu * ((B - c_across_1) / 2)^2 / 2) * band_ws[1]
    As_trans = max(_flexural_steel_footing(Mu_1, band_ws[1], d, fc, fy, ϕf),
                   _min_steel_footing(band_ws[1], h, fy))
    for j in 2:N
        c_across, c_along = _strip_c_across_along(demands[j].c1, demands[j].c2, strip_axis)
        cant_j = (B - c_across) / 2
        bw = c_along + d
        band_ws[j] = bw
        Mu_j = (qu * cant_j^2 / 2) * bw
        As_j = max(_flexural_steel_footing(Mu_j, bw, d, fc, fy, ϕf),
                   _min_steel_footing(bw, h, fy))
        As_trans = max(As_trans, As_j)
    end
    # Widest band governs the shared bar count's spacing check. Equal
    # columns keep the previous single band width.
    band_w = maximum(band_ws)

    # Each strength combination keeps its own diagram. The bars cover the
    # largest of those areas and the gravity diagram above.
    As_top_k, As_bot_k, As_trans_k = _strip_strength_steel(
        column_strength, positions, x_bar, strip_axis,
        L, B, d, col_pos_local, demands, fc, fy, ϕf)
    As_top = max(As_top, As_top_k, As_min)
    As_bot = max(As_bot, As_bot_k, As_min)
    As_trans = max(As_trans, As_trans_k)

    # =====================================================================
    # Step 6: Development (ACI 318-11 §15.6.3)
    # =====================================================================
    # Critical section is the column face (§15.4.2). The short projection
    # governs: longitudinal, the nearer end; transverse, the largest column.
    if !opts.check_development
        anchorage = dev_attempt == 1 ? :straight : :larger_plan
        developed = true
        break
    end
    max_s = min(3h, 18.0u"inch")
    avail_long = zero(cover)
    avail_trans = zero(cover)
    for (j, xc) in enumerate(col_pos_local)
        c_across, c_along = _strip_c_across_along(demands[j].c1, demands[j].c2, strip_axis)
        face_to_end = min(xc, L - xc) - c_along / 2 - cover
        proj = (B - c_across) / 2 - cover
        if j == 1
            avail_long = face_to_end
            avail_trans = proj
        else
            avail_long = min(avail_long, face_to_end)
            avail_trans = min(avail_trans, proj)
        end
    end
    long_fit = _one_way_anchorage(opts.bar_size_long, max(As_top, As_bot), B,
                                  h, cover, fc, fy, λ, avail_long, max_s)
    trans_fit = _one_way_anchorage(opts.bar_size_trans, As_trans, band_w,
                                   h, cover, fc, fy, λ, avail_trans, max_s)
    if long_fit.ok && trans_fit.ok
        bar_long = long_fit.size
        bar_trans = trans_fit.size
        # d stays the depth the flexure and shear checks used. A smaller
        # bar raises the true centroid; the reported d is the smaller one.
        bar_long == opts.bar_size_long || (db_l = bar_diameter(bar_long))
        db_t = bar_diameter(bar_trans)
        grew = dev_attempt > 1
        anchorage = if grew
            :larger_plan
        elseif long_fit.how == :hook || trans_fit.how == :hook
            :hook
        elseif long_fit.how == :smaller_bar || trans_fit.how == :smaller_bar
            :smaller_bar
        else
            :straight
        end
        developed = true
        break
    end
    long_fit.ok || (L = _canonical_ft(L + w_incr))
    trans_fit.ok || (B = _canonical_inch(B + w_incr))
    end
    developed || error(
        "Strip footing bars do not develop from the column face after 40 " *
        "plan increments (ACI 318-11 §15.6.3, corpus: aci-318-11, page 274). " *
        "L=$L, B=$B.")

    # =====================================================================
    # Step 7: Bearing & Dowels at Each Column (ACI 22.8)
    # =====================================================================
    # As_tensile_tot was computed once in Step 1 (`_strip_tensile_As`).
    n_tensile = 0
    sqA_gov = 1.0
    Bn_gov = 0.0u"N"
    have_brg = false
    if As_tensile_tot > zero(As_tensile_tot)
        Ab_l_sched = bar_area(bar_long)
        db_l = bar_diameter(bar_long)
        ld_tensile = _development_length_footing(bar_long, fc, fy, λ, db_l;
                                                  clear_cover = cover)
        n_tensile = max(ceil(Int, As_tensile_tot / Ab_l_sched), 1)
        if opts.check_development
            avail_dowel = h - cover
            ld_tensile > avail_dowel && error(
                "Strip tensile interface steel (ACI 318-11 §15.8.1.2(b), " *
                "corpus: aci-318-11, page 275) ld=$ld_tensile > embedment " *
                "h−cover=$avail_dowel (ACI 318-11 §12.2.1, page 214).")
        end
    end
    if opts.check_bearing
        fc_col_val = something(opts.fc_col, fc)
        zP = zero(eltype(Pu_vec))
        for (j, dem) in enumerate(demands)
            if dem.Pu < zP
                # Tensile Pu is not a concrete bearing (compression) demand;
                # As_tensile is already in the bar schedule above.
                @info "Strip col #$j: tensile interface (ACI 318-11 §15.8.1.2(b)), As_dowels = $(abs(dem.Pu) / (ϕf * fy))"
                continue
            end
            # ACI 318-11 §10.14.1 / §15.8.1.1 (corpus: aci-318-11, pages 162,
            # 274): A2 frustum pairs along-strip face with L and across-strip
            # face with B. Helper is named-axis (c1∥Lf, c2∥B) for spread.
            # Circular diameter is named c1 — do not feed remapped c_along
            # into the cone branch (unequal c1≠c2 would inflate A1).
            c_across, c_along = _strip_c_across_along(dem.c1, dem.c2, strip_axis)
            c_brg1, c_brg2 = dem.shape == :circular ?
                (dem.c1, dem.c2) : (c_along, c_across)
            # Per-face §10.14.1 gate + clipped 1V:2H A2: station along L
            # (named Lf in the helper) and mid-width. End overhang =
            # min(xc, L−xc) − c_along/2 (circular: named c1/2). Do not use
            # overall L vs c_along, and do not unlock centered min(c+4h, L).
            # col_pos_local is canonical ft; helper converts to inch (every
            # unit, including leftover-inch after SI round-trip) and snaps
            # |overhang| ≤ 1e-12 in after face subtraction so a flush
            # station is exact zero. Re-canonicalize B/2 (not a raw half).
            bearing = _bearing_check_footing(
                dem.Pu, c_brg1, c_brg2, B, L, h,
                fc, fc_col_val, fy, ϕb, dem.shape;
                col_along = col_pos_local[j], col_across = _canonical_inch(B / 2))
            Bn_j = uconvert(u"N", bearing.Bn_footing)
            if !have_brg || bearing.sqA < sqA_gov
                sqA_gov = bearing.sqA
                Bn_gov = Bn_j
                have_brg = true
            end
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
    if !isempty(column_service)
        for k in eachindex(first(column_service))
            P, M_along, M_across = _strip_combo_moments(
                column_service, k, positions, x_bar, strip_axis)
            P <= 0 && continue
            qe = _eccentric_soil_pressure(
                P * u"N", M_along * u"N*m", M_across * u"N*m", B, L)
            util_bearing = max(util_bearing,
                ustrip(u"kPa", qe.q_max) / ustrip(u"kPa", soil.qa))
        end
    end

    util_punch = 0.0
    for (j, xc) in enumerate(col_pos_local)
        demands[j].Pu <= zero(demands[j].Pu) && continue
        cj1, cj2 = demands[j].c1, demands[j].c2
        d_ft = ustrip(u"ft", d)
        is_edge = (j == 1 && ustrip(u"ft", xc) < d_ft) ||
                  (j == N && ustrip(u"ft", L - xc) < d_ft)
        pos_sym = is_edge ? :edge : :interior
        Ac = _strip_edge_Ac(cj1, cj2, d, is_edge, strip_edge_par)
        Vu_p = max(uconvert(u"lbf", demands[j].Pu - qu * Ac), 0.0u"lbf")
        pch = punching_check(Vu_p, demands[j].Mux, demands[j].Muy,
                              d, fc, cj1, cj2;
                              position = pos_sym, shape = demands[j].shape,
                              λ = λ, ϕ = ϕv,
                              free_edge_parallel = strip_edge_par)
        util_punch = max(util_punch, pch.utilization)
    end
    if !isempty(column_strength)
        for k in eachindex(first(column_strength))
            P, M_along, M_across = _strip_combo_moments(
                column_strength, k, positions, x_bar, strip_axis)
            P <= 0 && continue
            qe = _eccentric_soil_pressure(
                P * u"N", M_along * u"N*m", M_across * u"N*m", B, L)
            for (j, xc) in enumerate(col_pos_local)
                Pj = column_strength[j][k].P * u"N"
                Pj <= zero(Pj) && continue
                cj1, cj2 = demands[j].c1, demands[j].c2
                d_ft = ustrip(u"ft", d)
                is_edge = (j == 1 && ustrip(u"ft", xc) < d_ft) ||
                          (j == N && ustrip(u"ft", L - xc) < d_ft)
                Ac = _strip_edge_Ac(cj1, cj2, d, is_edge, strip_edge_par)
                q_col, _ = _strip_q_station(qe.qu, qe.ex, qe.ey, L, B, xc)
                Vu_p = max(uconvert(u"lbf", Pj - q_col * Ac), 0.0u"lbf")
                pch = punching_check(Vu_p,
                                      column_strength[j][k].Mx * u"N*m",
                                      column_strength[j][k].My * u"N*m",
                                      d, fc, cj1, cj2;
                                      position = is_edge ? :edge : :interior,
                                      shape = demands[j].shape,
                                      λ = λ, ϕ = ϕv,
                                      free_edge_parallel = strip_edge_par)
                util_punch = max(util_punch, pch.utilization)
            end
        end
    end

    utilization = max(util_bearing, util_punch)

    # =====================================================================
    # Global stability (sliding / overturning / uplift) of the whole strip
    # =====================================================================
    # Evaluated on the final plan (B, L, h) over the whole-strip ASD actions.
    # The width floor already keeps sliding/uplift ≤ 1; this reports the
    # realized values and folds them into the governing utilization. NaN when
    # stability is off so the fields read "not checked".
    util_sliding = util_overturning = util_uplift = NaN
    if !isempty(stab_actions)
        su = footing_stability_utils(stab_actions, B, L, h, soil, opts.stability)
        util_sliding, util_overturning, util_uplift = su.sliding, su.overturning, su.uplift
        utilization = max(utilization, util_sliding, util_overturning, util_uplift)
    end

    # =====================================================================
    # Result (SI output)
    # =====================================================================
    As_top_m2 = uconvert(u"m^2", As_top)
    As_bot_m2 = uconvert(u"m^2", As_bot)
    As_trans_m2 = uconvert(u"m^2", As_trans)

    V_conc = uconvert(u"m^3", B * L * h)

    # Approximate steel volume
    Ab_l = bar_area(bar_long)
    Ab_t = bar_area(bar_trans)

    # Maximum spacing for primary flexural reinforcement in slabs / footings:
    # ACI 318-11 §7.6.5 (corpus: aci-318-11, page 96) — `min(3h, 18 in.)`.
    # Maximum spacing for shrinkage/temperature reinforcement: ACI 318-11
    # §7.12.2.2 (corpus: aci-318-11, page 106) — `min(5h, 18 in.)`.
    max_s_flex = min(3h, 18.0u"inch")
    max_s_TS   = min(5h, 18.0u"inch")

    # Bar count per direction is the larger of (As / A_bar) and the count
    # required to keep spacing ≤ max_s.  Spacing is approximated as
    # (section width) / n_bars; the small overrun from cover/end clearance
    # is ignored, matching the spread footing convention.
    n_top  = max(ceil(Int, As_top   / Ab_l), ceil(Int, B / max_s_flex))
    n_bot  = max(ceil(Int, As_bot   / Ab_l), ceil(Int, B / max_s_flex))
    n_tran = max(ceil(Int, As_trans / Ab_t), ceil(Int, band_w / max_s_flex))
    bar_len_long  = L - 2cover
    bar_len_trans = B - 2cover

    # Inter-band transverse temperature/shrinkage steel — ACI 318-11
    # §7.12.2.1 (corpus: aci-318-11, page 106). Each column band is that
    # column's along-strip face + d. Equal columns: sum(band_ws) = N·band_w.
    # The remaining footing length still requires minimum T&S steel
    # transverse to the strip's long axis. The bar count is the larger of
    # (As_min / A_bar) and (inter-band length / max_s_TS) so the §7.12.2.2
    # spacing limit is satisfied.
    inter_band_length = max(L - sum(band_ws), zero(L))
    As_min_inter = _min_steel_footing(inter_band_length, h, fy)
    n_tran_inter = max(ceil(Int, As_min_inter / Ab_t),
                       ceil(Int, inter_band_length / max_s_TS))

    V_steel = uconvert(u"m^3",
        (n_top + n_bot) * Ab_l * bar_len_long +
        (N * n_tran + n_tran_inter) * Ab_t * bar_len_trans +
        n_tensile * Ab_l * max(h - cover, zero(h)))

    result = StripFootingResult{typeof(uconvert(u"m", B)),
                              typeof(As_bot_m2),
                              typeof(V_conc),
                              typeof(Bn_gov)}(
        uconvert(u"m", B),
        uconvert(u"m", L),
        uconvert(u"m", h),
        uconvert(u"m", d),
        As_bot_m2, As_top_m2, As_trans_m2,
        N,
        V_conc, V_steel,
        utilization,
        uconvert(u"m^2", As_tensile_tot),
        Bn_gov,
        sqA_gov,
        :rigid,
        FoundationUtilizations(; bearing = Float64(util_bearing),
                               punching = Float64(util_punch),
                               sliding = Float64(util_sliding),
                               overturning = Float64(util_overturning),
                               uplift = Float64(util_uplift)),
    )
    StructuralSizer.emit!(tc, :checker, "design_footing_strip_aci", "", :exit;
                          B_m=Float64(ustrip(u"m", result.B)),
                          L_m=Float64(ustrip(u"m", result.L_ftg)),
                          D_m=Float64(ustrip(u"m", result.D)),
                          utilization=Float64(result.utilization),
                          anchorage=String(anchorage),
                          bar_size_long=bar_long,
                          bar_size_trans=bar_trans)
    return result
end

