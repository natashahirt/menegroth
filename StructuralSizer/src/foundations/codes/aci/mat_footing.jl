# =============================================================================
# Mat Foundation Design — Public API + Rigid Method
# =============================================================================
#
# Public entry point `design_footing(::MatFoundation, ...)` dispatches on `opts.analysis_method`:
#   - RigidMat   → rigid strip. ACI 336.2R-88 §5.2 gates Kr. Moments are
#                  Bowles 5th ed. §9-2 and §10-6 (combined-footing statics).
#   - ShuklaAFM  → analytical method: Shukla (1984) + rigid envelope
#                  (ACI 336.2R §6.1.2 Steps 3–4)
#   - WinklerFEA → FEA plate on Winkler springs (ACI 336.2R §6.4/§6.7)
#
# Shared utilities (_mat_plan_sizing, _mat_result, _unique_spans) are used by
# all methods.  Method-specific code lives in mat_shukla.jl / mat_winkler_fea.jl.
#
# Fully Unitful throughout.
# =============================================================================

# =============================================================================
# Solver Trace Contract (manual registry; function is documented)
# =============================================================================
TRACE_REGISTRY[(:design_footing, :checker)] =
    TracedFunctionMeta(:design_footing, :checker,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)

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
    opts::MatParams;
    demands::Union{Vector{<:FoundationDemand}, Nothing} = nothing,
    soil::Union{Soil, Nothing} = nothing,
    walls::Vector{<:WallLineDemand} = WallLineDemand[],
    overhang_override::Union{Nothing, Length} = nothing,
)
    xs = [p[1] for p in positions]
    ys = [p[2] for p in positions]
    # Column coordinates stay `xs`/`ys`. Wall endpoints widen the plan only.
    box_x = typeof(1.0u"m")[]
    box_y = typeof(1.0u"m")[]
    for x in xs
        push!(box_x, uconvert(u"m", x))
    end
    for y in ys
        push!(box_y, uconvert(u"m", y))
    end
    for leg in walls
        push!(box_x, uconvert(u"m", leg.p1[1]), uconvert(u"m", leg.p2[1]))
        push!(box_y, uconvert(u"m", leg.p1[2]), uconvert(u"m", leg.p2[2]))
    end
    isempty(box_x) && throw(ArgumentError("A mat needs at least one column or one wall"))

    x_min, x_max = extrema(box_x)
    y_min, y_max = extrema(box_y)

    if overhang_override !== nothing
        # Development lengthened a plan that already met bearing and punching.
        overhang = overhang_override
    elseif opts.edge_overhang !== nothing
        # ── User-specified overhang ──
        overhang = opts.edge_overhang

    elseif demands !== nothing && soil !== nothing
        # ── First-principles auto-overhang ──

        # (a) Punching shear: ensure every outermost column is interior.
        #     Full 4-sided critical perimeter requires overhang ≥ c_max/2 + d/2
        #     beyond the column face (half column + half effective depth).
        #     ACI 318 §22.6.4.1 — critical section at d/2 from column face.
        db_max = bar_diameter(max(opts.bar_size_x, opts.bar_size_y))
        # d per ACI 318-11 §2.2 (corpus: aci-318-11, page 37): d = h − cover − db/2.
        d_est  = opts.min_depth - opts.cover - db_max / 2
        d_est  = max(d_est, 6.0u"inch")
        if isempty(demands)
            oh_punch = 0.0u"ft"
            Ps_total = 0.0u"N"
        else
            c_max = maximum(max(d.c1, d.c2) for d in demands)
            oh_punch = c_max / 2 + d_est / 2   # ACI 318 §22.6.4.1
            Ps_total = sum(d.Ps for d in demands)
        end
        for leg in walls, smp in leg.samples
            Ps_total += smp.Ps
        end

        # (b) Bearing: A_mat ≥ Ps_total / qa  (service-level check).
        #     Mat area = (gx + 2·oh) × (gy + 2·oh) where gx, gy = grid extent.
        #     Solve quadratic: 4·oh² + 2(gx+gy)·oh + (gx·gy − A_req) ≥ 0.
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
    xs_loc = isempty(xs) ? typeof(x_left)[] : xs .- x_left
    ys_loc = isempty(ys) ? typeof(y_bot)[] : ys .- y_bot

    # A wall line is a support of the strip, so it splits the span. With no
    # walls the spans stay the column spans.
    if isempty(walls)
        x_spans = _unique_spans(xs_loc)
        y_spans = _unique_spans(ys_loc)
    else
        x_spans = _unique_spans([x - x_left for x in box_x])
        y_spans = _unique_spans([y - y_bot for y in box_y])
    end

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
    B, Lm = plan.B, plan.Lm
    xs_loc, ys_loc = plan.xs_loc, plan.ys_loc

    # ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200): the two-way
    # critical section need not approach closer than d/2 to the column face.
    # A column has a full 4-sided perimeter iff the mat extends at least
    # `c/2 + d/2` beyond the column center on that side.
    # The earlier `overhang ± 0.5 ft` threshold conflated "leftmost column
    # in the grid" with "perimeter extends off the mat", which silently
    # misclassified centered single-column mats (overhang ≈ B/2) as corner.
    # A 0.5 ft tolerance keeps numerical noise from flipping classification.
    tol = 0.5u"ft"
    for j in eachindex(demands)
        c1j, c2j = demands[j].c1, demands[j].c2
        # Half-extent of the critical section, taken as the larger column
        # dimension to be conservative when c1 ≠ c2.
        half_crit = max(c1j, c2j) / 2 + d_eff / 2

        edge_left   = xs_loc[j]      < half_crit + tol
        edge_right  = (B  - xs_loc[j]) < half_crit + tol
        edge_bottom = ys_loc[j]      < half_crit + tol
        edge_top    = (Lm - ys_loc[j]) < half_crit + tol
        n_close_edges = edge_left + edge_right + edge_bottom + edge_top
        is_edge = n_close_edges >= 1
        is_corner = n_close_edges >= 2
        pos_sym = is_corner ? :corner : (is_edge ? :edge : :interior)
        # Bottom/top: free edge along local x (named c1) → :c1 (swap so
        # ACI c1 = named c2). Left/right: free edge along local y → :c2
        # (named c1 already perp to the edge). Corners use :corner and
        # skip edge orient. ACI 318-11 R11.11.7.2 (corpus: aci-318-11,
        # pages 209–211).
        edge_par = (edge_bottom || edge_top) ? :c1 : :c2
        Ac = if demands[j].shape == :circular
            A_full = π * (c1j + d_eff)^2 / 4
            is_corner ? A_full / 2 :       # 2-sided critical perimeter
            is_edge   ? A_full * 3 / 4 :   # 3-sided critical perimeter
                        A_full              # interior — full perimeter
        elseif is_corner
            (c1j + d_eff / 2) * (c2j + d_eff / 2)
        elseif is_edge
            # ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200): 3-sided
            # plan area inside the d/2 critical section. On ACI axes
            # (c1 perp to the free edge, R11.11.7.2 pages 209–211)
            # Ac = (c1 + d/2)×(c2 + d). :c1 swaps named axes so
            # Ac = (named_c2 + d/2)×(named_c1 + d). Left/right :c2
            # already matches named axes.
            edge_par === :c1 ?
                (c2j + d_eff / 2) * (c1j + d_eff) :
                (c1j + d_eff / 2) * (c2j + d_eff)
        else
            (c1j + d_eff) * (c2j + d_eff)
        end
        Vu_p = max(uconvert(u"lbf", demands[j].Pu - qu * Ac), 0.0u"lbf")
        pch = punching_check(Vu_p, demands[j].Mux, demands[j].Muy,
                              d_eff, fc, c1j, c2j;
                              position = pos_sym, shape = demands[j].shape,
                              λ = λ, ϕ = ϕv,
                              free_edge_parallel = edge_par)
        util = max(util, pch.utilization)
    end
    return util
end

"""
Bar counts the mat steel volume uses.

x-bars run along `B` and are spaced across `Lm`. y-bars run along `Lm` and
are spaced across `B`. The spacing limit is ACI 318-11 §7.6.5
(corpus: aci-318-11, page 96): primary flexural reinforcement in a slab is
not spaced farther apart than three times the thickness, nor farther than
18 in. Each layer is primary flexural steel, so the count is the larger of
`As / Ab` and one bar per that spacing.
"""
function mat_flexure_bar_counts(B, Lm, h, As_x_bot, As_x_top, As_y_bot, As_y_top, opts;
                                bar_size_x::Int = opts.bar_size_x,
                                bar_size_y::Int = opts.bar_size_y)
    Ab_x = bar_area(bar_size_x)
    Ab_y = bar_area(bar_size_y)
    # ACI 318-11 §7.6.5 (corpus: aci-318-11, page 96).
    max_s = min(3h, 18.0u"inch")
    return (
        n_xb = max(ceil(Int, As_x_bot / Ab_x), ceil(Int, Lm / max_s)),
        n_xt = max(ceil(Int, As_x_top / Ab_x), ceil(Int, Lm / max_s)),
        n_yb = max(ceil(Int, As_y_bot / Ab_y), ceil(Int, B / max_s)),
        n_yt = max(ceil(Int, As_y_top / Ab_y), ceil(Int, B / max_s)),
        Ab_x = Ab_x,
        Ab_y = Ab_y,
        len_x = B - 2 * opts.cover,
        len_y = Lm - 2 * opts.cover,
    )
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
    utilization;
    checks::FoundationUtilizations = FoundationUtilizations(),
    analysis::Symbol = :rigid,
    As_dowel = 0.0u"m^2",
    bar_size_x::Int = opts.bar_size_x,
    bar_size_y::Int = opts.bar_size_y,
)
    B, Lm = plan.B, plan.Lm
    cover = opts.cover
    N = length(demands)

    V_conc = uconvert(u"m^3", B * Lm * h)

    bars = mat_flexure_bar_counts(B, Lm, h, As_x_bot, As_x_top, As_y_bot, As_y_top, opts;
                                  bar_size_x = bar_size_x, bar_size_y = bar_size_y)
    n_xb, n_xt, n_yb, n_yt = bars.n_xb, bars.n_xt, bars.n_yb, bars.n_yt
    Ab_x, Ab_y = bars.Ab_x, bars.Ab_y
    len_x, len_y = bars.len_x, bars.len_y
    # Vertical dowels across a wall joint, developed in the thickness.
    # ACI 318-11 §15.8.2 (corpus: aci-318-11, page 275).
    n_dowel = 0
    if As_dowel > zero(As_dowel)
        n_dowel = ceil(Int, As_dowel / Ab_x)
    end
    V_steel = uconvert(u"m^3",
        (n_xb + n_xt) * Ab_x * len_x +
        (n_yb + n_yt) * Ab_y * len_y +
        n_dowel * Ab_x * max(h - cover, zero(h)))

    # `F` is unused as a field. A wall cell with no enclosed column has an
    # empty demand vector; the force parameter is then a newton.
    Pu_type = isempty(demands) ? typeof(1.0u"N") : typeof(demands[1].Pu)
    return MatFootingResult{typeof(uconvert(u"m", B)),
                            typeof(uconvert(u"m^2", As_x_bot)),
                            typeof(V_conc),
                            Pu_type}(
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
        analysis,
        checks,
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
    opts::MatParams = MatParams(),
    tc::Union{Nothing, TraceCollector} = nothing,
    walls::Vector{<:WallLineDemand} = WallLineDemand[],
    framed_I_B = 0.0u"m^4",
    framed_I_L = 0.0u"m^4",
)
    N = length(demands)
    length(positions) == N ||
        throw(DimensionMismatch("positions and demands must match"))

    method = opts.analysis_method
    StructuralSizer.emit!(tc, :checker, "design_footing_mat_aci", "", :enter;
                          n_columns=N,
                          analysis_method=string(typeof(method)),
                          qa_kPa=Float64(ustrip(u"kPa", soil.qa)))
    if method isa RigidMat
        _check_on_inapplicable(opts.on_inapplicable)
        result = _design_mat_rigid(demands, positions, soil; opts = opts, walls = walls, tc = tc)
        reason = _rigid_mat_inapplicable(result, demands, positions, soil, walls, opts;
                                         framed_I_B = framed_I_B, framed_I_L = framed_I_L)
        if reason !== nothing
            opts.on_inapplicable == :error && throw(ArgumentError(reason))
            soil.ks === nothing && throw(ArgumentError(
                reason * " Soil.ks is required to redesign the mat as a beam on elastic foundation."))
            @info "Rigid mat not used ($reason). Redesigning with Winkler, ACI 336.2R §6.1.2 Step 4."
            result = _design_mat_winkler_fea(demands, positions, soil, WinklerFEA();
                                             opts = opts, walls = walls)
        end
        StructuralSizer.emit!(tc, :checker, "design_footing_mat_aci", "", :exit;
                              status="ok",
                              B_m=Float64(ustrip(u"m", result.B)),
                              L_m=Float64(ustrip(u"m", result.L_ftg)),
                              D_m=Float64(ustrip(u"m", result.D)),
                              utilization=Float64(result.utilization))
        return result
    elseif method isa ShuklaAFM
        isempty(walls) || throw(ArgumentError(
            "Shukla's column formula does not take a wall line. Choose the rigid method or Winkler."))
        result = _design_mat_shukla(demands, positions, soil, method; opts = opts)
        StructuralSizer.emit!(tc, :checker, "design_footing_mat_aci", "", :exit;
                              status="ok",
                              B_m=Float64(ustrip(u"m", result.B)),
                              L_m=Float64(ustrip(u"m", result.L_ftg)),
                              D_m=Float64(ustrip(u"m", result.D)),
                              utilization=Float64(result.utilization))
        return result
    elseif method isa WinklerFEA
        result = _design_mat_winkler_fea(demands, positions, soil, method; opts = opts, walls = walls)
        StructuralSizer.emit!(tc, :checker, "design_footing_mat_aci", "", :exit;
                              status="ok",
                              B_m=Float64(ustrip(u"m", result.B)),
                              L_m=Float64(ustrip(u"m", result.L_ftg)),
                              D_m=Float64(ustrip(u"m", result.D)),
                              utilization=Float64(result.utilization))
        return result
    else
        StructuralSizer.emit!(tc, :checker, "design_footing_mat_aci", "", :failure;
                              reason="unknown_analysis_method",
                              analysis_method=string(typeof(method)))
        error("Unknown mat analysis method: $(typeof(method))")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Rigid Mat Method — combined-footing statics on each strip
# ─────────────────────────────────────────────────────────────────────────────

"""
Column and wall point loads in mat coordinates measured from the plan origin.

`xs` runs from the left edge, `ys` from the bottom edge. A wall sample is
placed at distance `s` from `p1` toward `p2`.
"""
function _mat_line_loads(plan, demands, walls)
    xs = Length[]
    ys = Length[]
    Ps = Force[]
    length(demands) == length(plan.xs_loc) || throw(ArgumentError(
        "mat strip: $(length(demands)) column loads and $(length(plan.xs_loc)) " *
        "column stations."))
    for (i, d) in enumerate(demands)
        push!(xs, plan.xs_loc[i])
        push!(ys, plan.ys_loc[i])
        push!(Ps, d.Pu)
    end
    for leg in walls
        dx = leg.p2[1] - leg.p1[1]
        dy = leg.p2[2] - leg.p1[2]
        span = hypot(ustrip(u"m", dx), ustrip(u"m", dy))
        for smp in leg.samples
            t = span <= 1e-9 ? 0.0 : ustrip(u"m", smp.s) / span
            push!(xs, leg.p1[1] + t * dx - plan.x_left)
            push!(ys, leg.p1[2] + t * dy - plan.y_bot)
            push!(Ps, smp.Pu)
        end
    end
    return xs, ys, Ps
end

"""
    _rigid_mat_strip_moments(qu, length_along, width_across, stations, loads)
        -> (M_pos, M_neg)

Moments of one rigid strip, both returned as positive torques.

The strip is a combined footing. Soil pressure `qu` is uniform over
`width_across`. Each entry of `loads` is a downward point load at the
matching `stations` coordinate, measured from the strip end along
`length_along`. The shear and moment diagrams are

    V(x) = ∫ qu·width dx − Σ P
    M(x) = ∫ V dx

`M_pos` is the largest positive moment: bottom steel, in the column
regions. `M_neg` is the magnitude of the largest negative moment: top
steel, between the columns.

# Citations
Bowles, Foundation Analysis and Design, 5th ed., §9-2 (corpus:
textbook-bowles-foundation-analysis-design-5e, PDF pages 502–504).
Column loads are point loads. §10-6 item 1 (PDF page 576) analyzes a
mat strip as that combined footing.
"""
function _rigid_mat_strip_moments(qu::Pressure, length_along::Length,
                                  width_across::Length,
                                  stations::Vector{<:Length},
                                  loads::Vector{<:Force})
    z = 0.0 * kip * u"ft"
    length(stations) == length(loads) || throw(ArgumentError(
        "mat strip: $(length(stations)) stations and $(length(loads)) loads."))
    isempty(loads) && return (M_pos = z, M_neg = z)
    diag = _strip_VM_diagram(length_along, width_across, qu, stations, loads;
                             include_stations=true)
    return (
        M_pos = max(maximum(diag.M_kipft), 0.0) * kip * u"ft",
        M_neg = max(-minimum(diag.M_kipft), 0.0) * kip * u"ft",
    )
end

"""
Cantilevers from a wall face out to a mat edge that has nothing else between.

ACI 318-11 §15.5.2 (corpus: aci-318-11, page 273) puts one-way shear at `d`
from the face. An interior wall, with a column or another wall between it
and the edge, is left to the strip shear. Returns `(dir, lip)` with `dir`
`:x` for a vertical wall and `lip` the clear projection in metres.
"""
function _mat_clear_lips(walls, plan)
    x0 = ustrip(u"m", plan.x_left)
    y0 = ustrip(u"m", plan.y_bot)
    Bm = ustrip(u"m", plan.B)
    Lm = ustrip(u"m", plan.Lm)
    col_x = [ustrip(u"m", x) for x in plan.xs]
    col_y = [ustrip(u"m", y) for y in plan.ys]
    vx = Float64[]
    hy = Float64[]
    for leg in walls
        dx = ustrip(u"m", leg.p2[1] - leg.p1[1])
        dy = ustrip(u"m", leg.p2[2] - leg.p1[2])
        (abs(dx) <= 1e-3 || abs(dy) <= 1e-3) || throw(ArgumentError(
            "Mat wall $(leg.idx) is not axis-aligned, so the shear at its face is not a straight projection"))
        abs(dx) <= 1e-3 && push!(vx, ustrip(u"m", (leg.p1[1] + leg.p2[1]) / 2))
        abs(dy) <= 1e-3 && push!(hy, ustrip(u"m", (leg.p1[2] + leg.p2[2]) / 2))
    end
    lips = Tuple{Symbol, Float64}[]
    for leg in walls
        dx = ustrip(u"m", leg.p2[1] - leg.p1[1])
        tw = ustrip(u"m", leg.tw)
        if abs(dx) <= 1e-3
            xw = ustrip(u"m", (leg.p1[1] + leg.p2[1]) / 2)
            _push_lip!(lips, :x, xw, tw, x0, x0 + Bm, col_x, vx)
        else
            yw = ustrip(u"m", (leg.p1[2] + leg.p2[2]) / 2)
            _push_lip!(lips, :y, yw, tw, y0, y0 + Lm, col_y, hy)
        end
    end
    return lips
end

function _push_lip!(lips, dir, coord, tw, lo, hi, columns, walls_at)
    face_lo = coord - tw / 2
    face_hi = coord + tw / 2
    _side_clear(lo, face_lo, columns, walls_at, coord) &&
        push!(lips, (dir, face_lo - lo))
    _side_clear(face_hi, hi, columns, walls_at, coord) &&
        push!(lips, (dir, hi - face_hi))
end

function _side_clear(lo, hi, columns, walls_at, self)
    hi - lo <= 1e-3 && return false
    for c in columns
        c > lo + 1e-3 && c < hi - 1e-3 && return false
    end
    for w in walls_at
        abs(w - self) <= 1e-3 && continue
        w > lo + 1e-3 && w < hi - 1e-3 && return false
    end
    return true
end

function _mat_wall_cantilever_util(walls, plan, qu, d_eff, fc, λ, ϕv)
    util = 0.0
    d = ustrip(u"m", d_eff)
    bw = 1.0u"m"
    Vc = ϕv * one_way_shear_capacity(fc, bw, d_eff; λ = λ)
    Vc_N = ustrip(u"N", Vc)
    Vc_N <= 0 && return Inf
    for (_, lip) in _mat_clear_lips(walls, plan)
        proj = max(lip - d, 0.0)
        proj <= 0 && continue
        Vu = ustrip(u"N", qu * (proj * u"m") * bw)
        util = max(util, Vu / Vc_N)
    end
    return util
end

"""
Nothing when the rigid strip method may be used.

ACI 336.2R Eq. (5-1) and §5.2 (pages 8–9): rigid at Kr ≥ 0.5, checked on
both plan widths and governed by the smaller. §6.1.2 Step 3 (page 11):
column spans stay under `1.75/λ` and column loads and adjacent spans vary
by at most 20%. A mat with no columns is gated on Kr alone.
"""
function _rigid_mat_inapplicable(result, demands, positions, soil, walls, opts;
                                 framed_I_B = 0.0u"m^4", framed_I_L = 0.0u"m^4")
    fc = opts.material.concrete.fc′
    Ec_c = Ec(fc)
    h, B, Lm = result.D, result.B, result.L_ftg
    # ACI 336.2R Eq. (5-2): Σ E' I_b of the concrete members framing into the
    # mat, divided by the width of the check. `framed_I_B` bends about the
    # axis of the strip whose width is B.
    Kr = min(ustrip(wall_footing_kr(Ec_c, soil.Es, B, h, walls; framed_I = framed_I_B)),
             ustrip(wall_footing_kr(Ec_c, soil.Es, Lm, h, walls; framed_I = framed_I_L)))
    if Kr < 0.5
        return "Kr = $(round(Kr, sigdigits = 3)) < 0.5 (ACI 336.2R Eq. 5-1 and §5.2, pages 8–9)"
    end
    length(demands) < 2 && return nothing
    if soil.ks === nothing
        return "Soil.ks is missing, so column spacing cannot be compared with 1.75/λ (ACI 336.2R §6.1.2 Step 3, page 11)"
    end
    return _column_spacing_reason(demands, positions, soil.ks, Ec_c, B, Lm, h)
end

function _column_spacing_reason(demands, positions, ks, Ec_c, B, Lm, h)
    limx = 1.75 / ustrip(u"m^-1", footing_lambda(ks, Ec_c, B, h))
    limy = 1.75 / ustrip(u"m^-1", footing_lambda(ks, Ec_c, Lm, h))
    xs = sort(unique(round.([ustrip(u"m", p[1]) for p in positions], digits = 4)))
    ys = sort(unique(round.([ustrip(u"m", p[2]) for p in positions], digits = 4)))
    sx, sy = diff(xs), diff(ys)
    if any(s -> s >= limx - 1e-6, sx) || any(s -> s >= limy - 1e-6, sy)
        return "a column span is not below 1.75/λ (ACI 336.2R §6.1.2 Step 3, page 11)"
    end
    if _adjacent_varies(sx) || _adjacent_varies(sy)
        return "adjacent column spans vary by more than 20% (ACI 336.2R §6.1.2 Step 3, page 11)"
    end
    Pus = [ustrip(u"N", d.Pu) for d in demands if ustrip(u"N", d.Pu) > 0]
    _varies_over_20(Pus) &&
        return "column loads vary by more than 20% (ACI 336.2R §6.1.2 Step 3, page 11)"
    return nothing
end

function _varies_over_20(xs)
    length(xs) < 2 && return false
    hi, lo = maximum(xs), minimum(xs)
    hi <= 0 && return false
    return (hi - lo) / hi > 0.20 + 1e-9
end

function _adjacent_varies(xs)
    length(xs) < 2 && return false
    for i in 1:(length(xs) - 1)
        hi = max(xs[i], xs[i + 1])
        lo = min(xs[i], xs[i + 1])
        hi <= 0 && continue
        (hi - lo) / hi > 0.20 + 1e-9 && return true
    end
    return false
end

"""
Lengths available past the §15.4.2 face, cover already removed.

ACI 318-11 §15.6.3 (corpus: aci-318-11, page 274) locates the critical
section where §15.4.2 (page 272) puts the maximum moment: the wall face,
or the column face. §15.6.2 develops the bar on each side of that face.
Bottom bars are governed by the shorter side (the clear lip, or the nearer
column-face projection a spread uses). Top bars use the other side.
"""
function _mat_flexure_avails(plan, demands, walls, cover)
    bot_x = Float64[]
    top_x = Float64[]
    bot_y = Float64[]
    top_y = Float64[]
    cover_m = ustrip(u"m", cover)
    for (dir, lip_m) in _mat_clear_lips(walls, plan)
        span = ustrip(u"m", dir == :x ? plan.B : plan.Lm)
        near = lip_m - cover_m
        far = span - lip_m - cover_m
        push!(dir == :x ? bot_x : bot_y, min(near, far))
        push!(dir == :x ? top_x : top_y, max(near, far))
    end
    for j in eachindex(demands)
        left = ustrip(u"m", plan.xs_loc[j] - demands[j].c1 / 2)
        right = ustrip(u"m", plan.B - plan.xs_loc[j] - demands[j].c1 / 2)
        down = ustrip(u"m", plan.ys_loc[j] - demands[j].c2 / 2)
        up = ustrip(u"m", plan.Lm - plan.ys_loc[j] - demands[j].c2 / 2)
        push!(bot_x, min(left, right) - cover_m)
        push!(top_x, max(left, right) - cover_m)
        push!(bot_y, min(down, up) - cover_m)
        push!(top_y, max(down, up) - cover_m)
    end
    oh = ustrip(u"m", plan.overhang)
    side(xs, fallback) = (isempty(xs) ? fallback : minimum(xs)) * u"m"
    return (
        bot_x = side(bot_x, oh - cover_m),
        top_x = side(top_x, ustrip(u"m", plan.B) - cover_m),
        bot_y = side(bot_y, oh - cover_m),
        top_y = side(top_y, ustrip(u"m", plan.Lm) - cover_m),
    )
end

"""`:straight` when Eq. (12-1) fits `avail` at this exact bar size."""
function _mat_straight_how(size, As, width, cover, fc, fy, λ, avail, max_s, top_bar)
    db = bar_diameter(size)
    n = max(ceil(Int, As / bar_area(size)), 2, ceil(Int, width / max_s))
    spacing = _bar_spacing(n, width, cover, db)
    ld = _development_length_footing(size, fc, fy, λ, db;
                                      clear_cover = cover, spacing = spacing,
                                      top_bar = top_bar)
    return ld <= avail ? :straight : nothing
end

"""`:hook` when a §12.5 hook fits `avail` and the tail fits in `h`."""
function _mat_hook_how(size, h, cover, fc, fy, λ, avail)
    tail_room = h - _hook_top(size, cover)
    tail_room < zero(tail_room) && return nothing
    ldh = _hooked_development_length(size, fc, fy, λ, bar_diameter(size);
                                      side_cover = cover, tail_cover = tail_room)
    return ldh <= avail ? :hook : nothing
end

"""
One bar size for both layers of one direction.

Straight Eq. (12-1) at the given bar, then at smaller bars. A §12.5 hook
is tried only after no straight bar fits. `layers` is
`(As, width, avail, top_bar)` for the bottom layer and the top layer.
"""
function _mat_direction_bars(bar_size, layers, h, cover, fc, fy, λ, max_s)
    for size in bar_size:-1:3
        all(_mat_straight_how(size, As, width, cover, fc, fy, λ, avail, max_s, top_bar) !== nothing
            for (As, width, avail, top_bar) in layers) || continue
        return (ok = true, size = size, how = size == bar_size ? :straight : :smaller_bar)
    end
    for size in bar_size:-1:3
        fits = true
        for (As, width, avail, top_bar) in layers
            straight = _mat_straight_how(size, As, width, cover, fc, fy, λ, avail, max_s, top_bar)
            hooked = _mat_hook_how(size, h, cover, fc, fy, λ, avail)
            straight === nothing && hooked === nothing && (fits = false)
        end
        fits || continue
        return (ok = true, size = size, how = :hook)
    end
    return (ok = false, size = bar_size, how = :larger_plan)
end

function _mat_flexural_anchorage(opts, plan, demands, walls, h, cover, fc, fy, λ,
                                  As_x_bot, As_x_top, As_y_bot, As_y_top)
    max_s = min(3h, 18.0u"inch")
    avail = _mat_flexure_avails(plan, demands, walls, cover)
    x = _mat_direction_bars(opts.bar_size_x, (
            (As_x_bot, plan.Lm, avail.bot_x, false),
            (As_x_top, plan.Lm, avail.top_x, true),
        ), h, cover, fc, fy, λ, max_s)
    y = _mat_direction_bars(opts.bar_size_y, (
            (As_y_bot, plan.B, avail.bot_y, false),
            (As_y_top, plan.B, avail.top_y, true),
        ), h, cover, fc, fy, λ, max_s)
    return x, y
end

function _design_mat_rigid(
    demands::Vector{<:FoundationDemand},
    positions::Vector{<:NTuple{2, <:Length}},
    soil::Soil;
    opts::MatParams = MatParams(),
    walls::Vector{<:WallLineDemand} = WallLineDemand[],
    tc::Union{Nothing, TraceCollector} = nothing,
)
    # Material / options. d uses these diameters on every plan attempt.
    # A smaller bar selected below does not raise d: the flexure and shear
    # checks keep the centroid of the bar the section was designed with.
    fc    = opts.material.concrete.fc′
    fy    = opts.material.rebar.Fy
    λ     = something(opts.λ, opts.material.concrete.λ)
    cover = opts.cover
    db_x  = bar_diameter(opts.bar_size_x)
    db_y  = bar_diameter(opts.bar_size_y)
    ϕf    = opts.ϕ_flexure
    ϕv    = opts.ϕ_shear
    db_eff = max(db_x, db_y) / 2
    h_incr = opts.depth_increment

    overhang_override = nothing
    for attempt in 1:40
        # ── Step 1: Plan Sizing (first-principles overhang) ──
        plan = _mat_plan_sizing(positions, opts; demands = demands, soil = soil,
                                walls = walls, overhang_override = overhang_override)
        B, Lm = plan.B, plan.Lm

        Pu_total = isempty(demands) ? 0.0u"N" : sum(d.Pu for d in demands)
        Ps_total = isempty(demands) ? 0.0u"N" : sum(d.Ps for d in demands)
        for leg in walls, smp in leg.samples
            Pu_total += smp.Pu
            Ps_total += smp.Ps
        end
        qu = Pu_total / (B * Lm)

        # Bearing utilization. Warned once, on the plan that is kept.
        util_bearing = to_kip(Ps_total) / to_kip(soil.qa * B * Lm)

        # ── Step 2: Thickness from Punching Shear (per-column dimensions) ──
        # Uses _mat_punching_util (with corner detection) so thickness iteration
        # and final utilization are computed by the same code path.
        # Effective depth per ACI 318-11 §2.2 (corpus: aci-318-11, page 37):
        # d = h − cover − db/2 to the centroid of the worst-case bar layer.
        # That centroid stays the specified bar. Stepping down for development
        # does not raise d.
        h = opts.min_depth

        # Step 4 strip moments do not depend on h; the depth search also requires
        # every flexural section to be tension-controlled. The edge cantilever is
        # already in the diagram: the strip runs the full plan length.
        x_sta, y_sta, P_sta = _mat_line_loads(plan, demands, walls)
        mom_x = _rigid_mat_strip_moments(qu, B, Lm, x_sta, P_sta)
        mom_y = _rigid_mat_strip_moments(qu, Lm, B, y_sta, P_sta)
        flex_pairs = ((mom_x.M_pos, Lm), (mom_x.M_neg, Lm), (mom_y.M_pos, B), (mom_y.M_neg, B))

        for iter in 1:60
            d_eff = h - cover - db_eff
            d_eff < 6.0u"inch" && (h += h_incr; continue)

            util_p = _mat_punching_util(demands, plan, qu, d_eff, fc, λ, ϕv)
            if !isempty(walls)
                util_p = max(util_p, _mat_wall_cantilever_util(walls, plan, qu, d_eff, fc, λ, ϕv))
            end
            embeds = isempty(walls) || _bar_develops_in(
                opts.bar_size_x, h - cover, fc, fy, λ, cover)
            util_p ≤ 1.0 && _footing_flexure_ok(flex_pairs, d_eff, fc, fy, ϕf) &&
                embeds && break
            h += h_incr
            iter == 60 && @warn "Mat footing thickness did not converge at h=$h"
        end

        d_eff = h - cover - db_eff

        # ── Step 4: Flexural Reinforcement via Strip Statics ──
        # Bowles 5th ed. §9-2 and §10-6 (corpus:
        # textbook-bowles-foundation-analysis-design-5e, PDF pages 502–504
        # and 576). Each direction is one combined footing across the full
        # mat width. Bottom steel is the positive moment; top steel is the
        # negative moment. `mom_x` and `mom_y` are computed before the
        # depth search above.

        As_x_bot = max(_flexural_steel_footing(mom_x.M_pos, Lm, d_eff, fc, fy, ϕf),
                       _min_steel_footing(Lm, h, fy))
        As_x_top = max(_flexural_steel_footing(mom_x.M_neg, Lm, d_eff, fc, fy, ϕf),
                       _min_steel_footing(Lm, h, fy))
        As_y_bot = max(_flexural_steel_footing(mom_y.M_pos, B, d_eff, fc, fy, ϕf),
                       _min_steel_footing(B, h, fy))
        As_y_top = max(_flexural_steel_footing(mom_y.M_neg, B, d_eff, fc, fy, ϕf),
                       _min_steel_footing(B, h, fy))

        # Kr is Eq. (5-1), applied by `design_footing` after this result exists.
        # The previous `Ec·Ig/(ks·B·L³)` warning was not that equation.

        # ── Utilization ──
        util_punch = _mat_punching_util(demands, plan, qu, d_eff, fc, λ, ϕv)
        if !isempty(walls)
            util_punch = max(util_punch, _mat_wall_cantilever_util(walls, plan, qu, d_eff, fc, λ, ϕv))
        end
        utilization = max(util_bearing, util_punch)

        bar_x = opts.bar_size_x
        bar_y = opts.bar_size_y
        anchorage = :straight
        if opts.check_development
            # §15.6.1: Chapter 12. Straight bars, then a smaller bar, then a
            # hook, then a larger plan. Dowels stay on `_bar_develops_in`.
            xfit, yfit = _mat_flexural_anchorage(
                opts, plan, demands, walls, h, cover, fc, fy, λ,
                As_x_bot, As_x_top, As_y_bot, As_y_top)
            if !(xfit.ok && yfit.ok)
                overhang_override = plan.overhang + opts.size_increment
                continue
            end
            bar_x = xfit.size
            bar_y = yfit.size
            anchorage = if attempt > 1
                :larger_plan
            elseif xfit.how == :hook || yfit.how == :hook
                :hook
            elseif xfit.how == :smaller_bar || yfit.how == :smaller_bar
                :smaller_bar
            else
                :straight
            end
        end
        util_bearing > 1.0 && @warn "Mat bearing exceeds allowable: util=$(round(util_bearing, digits=3))"
        StructuralSizer.emit!(tc, :checker, "design_footing_mat_aci", "flexural_development", :decision;
                              anchorage=String(anchorage),
                              bar_size_x=bar_x,
                              bar_size_y=bar_y)
        return _mat_build_result(plan, demands, opts, h, d_eff,
                                 As_x_bot, As_x_top, As_y_bot, As_y_top,
                                 utilization;
                                 checks = FoundationUtilizations(; bearing = Float64(util_bearing),
                                                                 punching = Float64(util_punch)),
                                 As_dowel = _mat_wall_dowels(walls, opts, fc, fy, ϕf),
                                 bar_size_x = bar_x,
                                 bar_size_y = bar_y)
    end
    error("Mat flexural reinforcement does not develop from the face within " *
          "40 plan increments (B=$(plan.B)). ACI 318-11 §15.6.3 " *
          "(corpus: aci-318-11, page 274).")
end

"""
Wall dowels on a mat: the greatest of joint tension, bearing excess, and
the §14.3.2 minimum.

Bearing is the supported wall's ϕ·0.85·f′c·A1 (ACI 318-11 §10.14.1 and
§9.3.2.4, corpus: aci-318-11, pages 162 and 128). The mat's f′c is used for
the wall. A1 is `solid × tw`.
"""
function _mat_wall_dowels(walls, opts, fc, fy, ϕf)
    isempty(walls) && return 0.0u"m^2"
    ϕb = 0.65
    As_b = 0.0u"m^2"
    for leg in walls
        Pu = sum(max(smp.Pu, zero(smp.Pu)) for smp in leg.samples; init = 0.0u"N")
        As_b += _interface_dowel_area(Pu, leg.solid * leg.tw, fc, fy, ϕb)
    end
    return max(_wall_tension_steel(walls, ϕf, fy),
               As_b,
               _wall_min_dowel(walls, opts.bar_size_x, fy))
end
