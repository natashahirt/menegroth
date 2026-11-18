# Wall footing: one straight wall, or an L or a T that does not close a cell.
#
# The column method of this name is unchanged. A wall is a line, so it is not
# a FoundationDemand and it is not punched.
#
#   design_footing(::StripFooting, legs::Vector{WallLineDemand}, soil)
#
# Plan from unfactored load and allowable pressure (ACI 318-11 §15.2.2,
# page 271). Soil pressure is linear when the footing is rigid (ACI 336.2R
# §3.2 and §4.2, pages 6–7; rigid when Kr ≥ 0.5, Eq. (5-1) and §5.2, pages
# 8–9). Below that, a straight wall is redesigned as a beam on elastic
# foundation (§5.4, page 9) with the end springs doubled (§3.3.1, page 7).
# A corner that is not rigid is refused: §5.4 is a line, and partial contact
# on an L is not Eq. (3-2).

const _WALL_ON_INAPPLICABLE = (:fallback, :error)

function _check_on_inapplicable(s::Symbol)
    s in _WALL_ON_INAPPLICABLE || throw(ArgumentError(
        "on_inapplicable must be :fallback or :error; got :$s"))
    return s
end

"""
    design_footing(::StripFooting, legs, soil; opts) → StripFootingResult

Design one wall footing under `legs`. `n_columns` is 0. `B * L_ftg` is the
contact area. `analysis` is `:rigid` or `:winkler`.
"""
function design_footing(::StripFooting,
                        legs::Vector{<:WallLineDemand},
                        soil::Soil;
                        opts::StripParams = StripParams(),
                        tc::Union{Nothing, TraceCollector} = nothing)
    _check_on_inapplicable(opts.on_inapplicable)
    _validate_wall_legs(legs)
    StructuralSizer.emit!(tc, :checker, "design_footing_wall_aci", "", :enter;
                          n_legs = length(legs),
                          qa_kPa = Float64(ustrip(u"kPa", soil.qa)))
    plan = _size_wall_plan(legs, soil; step = opts.width_increment)
    fc = opts.material.concrete.fc′
    kr = wall_footing_kr(Ec(fc), soil.Es, plan.B * u"m", opts.min_depth, legs)
    rigid = kr >= 0.5
    if !rigid
        result = _wall_not_rigid(legs, soil, opts, plan, kr, tc)
    else
        result = _design_wall_rigid(legs, soil, opts, plan, tc)
    end
    StructuralSizer.emit!(tc, :checker, "design_footing_wall_aci", "", :exit;
                          analysis = String(result.analysis),
                          B_m = Float64(ustrip(u"m", result.B)),
                          L_m = Float64(ustrip(u"m", result.L_ftg)),
                          utilization = Float64(result.utilization))
    return result
end

function design_footing(::StripFooting, leg::WallLineDemand, soil::Soil;
                        opts::StripParams = StripParams(),
                        tc::Union{Nothing, TraceCollector} = nothing)
    design_footing(StripFooting(), WallLineDemand[leg], soil; opts = opts, tc = tc)
end

function _wall_not_rigid(legs, soil, opts, plan, kr, tc)
    msg = "Wall footing Kr = $(round(kr, digits=3)) < 0.5, so linear soil " *
          "pressure does not apply (ACI 336.2R §5.2, corpus: " *
          "aci-336-combined-footings-mats, page 9)."
    if opts.on_inapplicable === :error || !plan.straight
        extra = plan.straight ? "" :
            " A corner is not the line footing of §5.4, so it is not " *
            "switched to a beam on elastic foundation."
        throw(ArgumentError(msg * extra))
    end
    soil.ks === nothing && throw(ArgumentError(
        msg * " The beam-on-elastic-foundation fallback (ACI 336.2R §5.4) " *
        "needs Soil.ks."))
    StructuralSizer.emit!(tc, :checker, "design_footing_wall_aci", "", :decision;
                          fallback = "winkler", Kr = Float64(kr))
    return _design_wall_winkler(legs, soil, opts, plan)
end

# ── Factored pressure on a frozen plan ──────────────────────────────────────

function _factored_coeff(legs, plan)
    if plan.straight
        Pu = sbar = 0.0
        for smp in legs[1].samples
            p = _n(smp.Pu)
            Pu += p
            sbar += p * _m(smp.s)
        end
        abs(Pu) > 0 || throw(ArgumentError(
            "Wall footing has no factored vertical load"))
        x = plan.x0 + sbar / Pu
        return _linear_pressure(Pu, x, 0.0, plan.section), Pu
    end
    fac = _factored_resultant_m(legs)
    abs(fac.Pu) > 0 || throw(ArgumentError(
        "Wall footing has no factored vertical load"))
    return _linear_pressure(fac.Pu, fac.x, fac.y, plan.section), fac.Pu
end

function _q_bounds(coeff, rects)
    qs = [_q_at(coeff, x, y) for (x, y) in _union_vertices(rects)]
    return extrema(qs)
end

"""Drop stations closer than 1 µm, after sorting."""
function _unique_stations!(xs)
    sort!(xs)
    i = 1
    while i < length(xs)
        if xs[i + 1] - xs[i] < 1e-6
            deleteat!(xs, i + 1)
        else
            i += 1
        end
    end
    return xs
end

"""Point loads in the straight footing's local frame, newtons downward."""
function _straight_loads(leg, plan; service::Bool = false)
    loads = Tuple{Float64, Float64}[]
    for smp in leg.samples
        p = service ? _n(smp.Ps) : _n(smp.Pu)
        push!(loads, (plan.x0 + _m(smp.s), p))
    end
    return loads
end

"""
Shear and moment of a straight rigid footing. `M` is in N·m, positive when
the bottom is in tension, matching `_strip_VM_diagram`. Soil is the linear
pressure `coeff` (factored, N/m²) integrated across the width.
"""
function _straight_extremes(plan, coeff, loads)
    B = plan.B
    α = (coeff.a - coeff.b * coeff.cx) * B
    β = coeff.b * B
    xs = Float64[0.0, plan.along]
    for (x, _) in loads
        push!(xs, x)
    end
    _unique_stations!(xs)
    Mbot = Mtop = Vmax = 0.0
    for x in xs
        Vsoil = α * x + β * x^2 / 2
        Msoil = α * x^2 / 2 + β * x^3 / 6
        V = Vsoil
        M = Msoil
        for (xc, P) in loads
            xc < x - 1e-9 || continue
            V -= P
            M -= P * (x - xc)
        end
        Mbot = max(Mbot, M)
        Mtop = max(Mtop, -M)
        Vmax = max(Vmax, abs(V))
    end
    return (Mbot = Mbot, Mtop = Mtop, Vmax = Vmax)
end

"""
True when some bar from No. 3 up to the longitudinal bar develops inside
`h − cover`. ACI 318-11 §12.2.1 (corpus: aci-318-11, page 214) and §15.8.2.
The minimum of §15.8.2.2 is included, so a wall with no tension still has
to be thick enough for its dowels.
"""
function _dowels_fit(legs, plan, h, fc, fy, λ, ϕf, ϕb, opts)
    opts.check_development || return true
    As_b, _, _ = _wall_bearing(legs, plan, h, fc, fy, ϕb, opts)
    As = max(_wall_tension_steel(legs, ϕf, fy), As_b,
             _wall_min_dowel(legs, opts.bar_size_long, fy))
    As <= zero(As) && return true
    return _bar_develops_in(opts.bar_size_long, h - opts.cover, fc, fy, λ, opts.cover)
end

# ── Rigid design ────────────────────────────────────────────────────────────

function _design_wall_rigid(legs, soil, opts, plan, tc)
    coeff, Pu = _factored_coeff(legs, plan)
    qmin, qmax = _q_bounds(coeff, plan.rects)
    if qmin < -1.0
        msg = "Factored pressure lifts an edge of this wall footing. " *
              "ACI 336.2R Eq. (3-2) to (3-4) (page 6) cover a rectangle " *
              "with the resultant outside the middle third; that partial " *
              "contact is not applied here."
        plan.straight && opts.on_inapplicable === :fallback ||
            throw(ArgumentError(msg))
        soil.ks === nothing && throw(ArgumentError(msg * " Soil.ks is required " *
            "for the beam-on-elastic-foundation fallback (ACI 336.2R §5.4)."))
        return _design_wall_winkler(legs, soil, opts, plan)
    end
    fc = opts.material.concrete.fc′
    fy = opts.material.rebar.Fy
    λ = something(opts.λ, opts.material.concrete.λ)
    cover = opts.cover
    db = bar_diameter(opts.bar_size_long)
    ϕf, ϕv, ϕb = opts.ϕ_flexure, opts.ϕ_shear, opts.ϕ_bearing
    B = plan.B * u"m"
    qa = soil.qa

    h = opts.min_depth
    extremes = _wall_extremes(legs, plan, coeff)
    passed = false
    d = h - cover - db / 2
    q_gov = max(qmax, 0.0) * u"Pa"
    util_shear = 0.0
    for _ in 1:60
        d = h - cover - db / 2
        # ACI 318-11 §15.7 (corpus: aci-318-11, page 274): at least 6 in.
        # above the bottom reinforcement. The same floor the mat search uses.
        if d < 6.0u"inch"
            h += opts.depth_increment
            continue
        end
        util_shear, flex_ok = _wall_section_ok(
            legs, plan, extremes, q_gov, d, h, B, fc, fy, λ, ϕf, ϕv)
        if util_shear <= 1.0 && flex_ok && _dowels_fit(legs, plan, h, fc, fy, λ, ϕf, ϕb, opts)
            passed = true
            break
        end
        h += opts.depth_increment
    end
    passed || @warn("Wall footing thickness did not converge at h = $h")

    _wall_finish(legs, soil, opts, plan, extremes, q_gov, qmax, h, d, B,
                 fc, fy, λ, ϕf, ϕv, ϕb, util_shear, :rigid)
end

function _wall_extremes(legs, plan, coeff)
    if plan.straight
        return _straight_extremes(plan, coeff, _straight_loads(legs[1], plan))
    end
    return _corner_extremes(plan, coeff, legs)
end

"""Longitudinal shear and moment of a corner footing, from cutting planes."""
function _corner_extremes(plan, coeff, legs)
    loads = Tuple{Float64, Float64, Float64}[]
    for leg in legs
        for smp in leg.samples
            x, y = _station_xy_m(leg, smp.s)
            push!(loads, (x, y, _n(smp.Pu)))
        end
    end
    ap = coeff.a - coeff.b * coeff.cx - coeff.c * coeff.cy
    Mbot = Mtop = Vmax = 0.0
    for rect in plan.rects
        long_x = (rect.x1 - rect.x0) >= (rect.y1 - rect.y0)
        span = long_x ? (rect.x1 - rect.x0) : (rect.y1 - rect.y0)
        for k in 0:20
            if long_x
                cut = rect.x0 + span * k / 20
                F, M = _side_force_moment(plan.rects, ap, coeff.b, coeff.c,
                                           loads, cut, true)
            else
                cut = rect.y0 + span * k / 20
                F, M = _side_force_moment(plan.rects, ap, coeff.b, coeff.c,
                                           loads, cut, false)
            end
            Mbot = max(Mbot, M)
            Mtop = max(Mtop, -M)
            Vmax = max(Vmax, abs(F))
        end
    end
    return (Mbot = Mbot, Mtop = Mtop, Vmax = Vmax)
end

"""
Net vertical force and moment, on the positive side of a cut, of the linear
soil pressure minus the point loads. Moment is positive for bottom tension.
"""
function _side_force_moment(rects, ap, b, c, loads, cut, along_x::Bool)
    F = M = 0.0
    clipped = _Aabb[]
    for r in rects
        piece = along_x ? _clip_above(r, cut, true) : _clip_above(r, cut, false)
        piece === nothing || push!(clipped, piece)
    end
    for (sgn, r) in _ie_terms(clipped)
        m = _rect_raw(r)
        dF = ap * m.A + b * m.sx + c * m.sy
        if along_x
            dM = ap * (m.sx - cut * m.A) + b * (m.sxx - cut * m.sx) +
                 c * (m.sxy - cut * m.sy)
        else
            dM = ap * (m.sy - cut * m.A) + c * (m.syy - cut * m.sy) +
                 b * (m.sxy - cut * m.sx)
        end
        F += sgn * dF
        M += sgn * dM
    end
    for (x, y, P) in loads
        coord = along_x ? x : y
        coord > cut + 1e-9 || continue
        F -= P
        M -= P * (coord - cut)
    end
    return F, M
end

function _clip_above(r::_Aabb, cut, along_x::Bool)
    if along_x
        x0 = max(r.x0, cut)
        return x0 >= r.x1 - 1e-12 ? nothing : _Aabb(x0, r.x1, r.y0, r.y1)
    else
        y0 = max(r.y0, cut)
        return y0 >= r.y1 - 1e-12 ? nothing : _Aabb(r.x0, r.x1, y0, r.y1)
    end
end

function _wall_section_ok(legs, plan, extremes, q_gov, d, h, B, fc, fy, λ, ϕf, ϕv)
    Vu = extremes.Vmax * u"N"
    ϕVc = ϕv * one_way_shear_capacity(fc, B, d; λ = λ)
    util_long = ustrip(u"N", ϕVc) > 0 ? ustrip(u"N", Vu) / ustrip(u"N", ϕVc) : Inf
    util_proj = 0.0
    flex_pairs = Any[]
    bw = 1.0u"m"
    for leg in legs
        m = (B - leg.tw) / 2
        Mu = q_gov * m^2 / 2 * bw
        push!(flex_pairs, (Mu, bw))
        lip = m - d
        if lip > zero(lip)
            Vu_p = q_gov * lip * bw
            ϕVc_p = ϕv * one_way_shear_capacity(fc, bw, d; λ = λ)
            util_proj = max(util_proj,
                            ustrip(u"N", Vu_p) / ustrip(u"N", ϕVc_p))
        end
    end
    Mbot = extremes.Mbot * u"N*m"
    Mtop = extremes.Mtop * u"N*m"
    push!(flex_pairs, (Mbot, B), (Mtop, B))
    flex_ok = _footing_flexure_ok(flex_pairs, d, fc, fy, ϕf)
    return max(util_long, util_proj), flex_ok
end

# ── Winkler beam for one straight wall ──────────────────────────────────────

function _design_wall_winkler(legs, soil, opts, plan)
    length(legs) == 1 && plan.straight || throw(ArgumentError(
        "The beam-on-elastic-foundation fallback is for one straight wall " *
        "(ACI 336.2R §5.4, corpus: aci-336-combined-footings-mats, page 9)."))
    fc = opts.material.concrete.fc′
    fy = opts.material.rebar.Fy
    λ = something(opts.λ, opts.material.concrete.λ)
    cover = opts.cover
    db = bar_diameter(opts.bar_size_long)
    ϕf, ϕv, ϕb = opts.ϕ_flexure, opts.ϕ_shear, opts.ϕ_bearing
    ks = soil.ks
    B = plan.B * u"m"
    h = opts.min_depth
    service_loads = _straight_loads(legs[1], plan; service = true)
    factored_loads = _straight_loads(legs[1], plan)
    passed = false
    d = h - cover - db / 2
    extremes = (Mbot = 0.0, Mtop = 0.0, Vmax = 0.0)
    q_gov = 0.0u"Pa"
    util_shear = 0.0
    q_service_max = 0.0
    for _ in 1:60
        d = h - cover - db / 2
        if d < 6.0u"inch"
            h += opts.depth_increment
            continue
        end
        EI = ustrip(u"N*m^2", Ec(fc) * (B * h^3 / 12))
        reactions, qmax_s = _winkler_reactions(plan, ks, EI, service_loads)
        q_service_max = qmax_s
        reactions_u, qmax_u = _winkler_reactions(plan, ks, EI, factored_loads)
        q_gov = max(qmax_u, 0.0) * u"Pa"
        extremes = _straight_extremes_from_reactions(plan, reactions_u, factored_loads)
        util_shear, flex_ok = _wall_section_ok(
            legs, plan, extremes, q_gov, d, h, B, fc, fy, λ, ϕf, ϕv)
        bearing_ok = q_service_max <= ustrip(u"Pa", soil.qa) * (1 + 1e-6)
        if util_shear <= 1.0 && flex_ok && bearing_ok &&
           _dowels_fit(legs, plan, h, fc, fy, λ, ϕf, ϕb, opts)
            passed = true
            break
        end
        h += opts.depth_increment
    end
    passed || @warn("Wall footing on elastic soil did not converge at h = $h " *
                    "(ACI 336.2R §5.4)")
    _wall_finish(legs, soil, opts, plan, extremes, q_gov, q_service_max, h, d, B,
                 fc, fy, λ, ϕf, ϕv, ϕb, util_shear, :winkler)
end

"""
Nodal soil reactions for a beam on a compression-only Winkler foundation.
End springs are doubled (ACI 336.2R §3.3.1, page 7). Returns the upward
reactions and the largest service-style contact pressure `k_s · v`.
"""
function _winkler_reactions(plan, ks, EI, loads)
    Lf = plan.along
    B = plan.B
    n = clamp(ceil(Int, Lf / 0.25), 8, 80)
    xs = collect(range(0.0, Lf, length = n))
    trib = zeros(n)
    for i in 1:n - 1
        half = (xs[i + 1] - xs[i]) / 2
        trib[i] += half
        trib[i + 1] += half
    end
    trib[1] *= 2
    trib[end] *= 2
    ks_pa = ustrip(u"N/m^3", ks)
    F = zeros(2n)
    nodal = _beam_nodal_forces(xs, loads)
    for i in 1:n
        F[2i - 1] = nodal[i]
    end
    active = trues(n)
    v = zeros(n)
    k = zeros(n)
    for _ in 1:20
        k .= 0.0
        for i in 1:n
            active[i] && (k[i] = ks_pa * B * trib[i])
        end
        any(k .> 0) || error(
            "Wall footing lost every soil spring (ACI 336.2R §3.3). The load " *
            "is not carried by the ground.")
        K = _beam_stiffness(xs, EI, k)
        u = K \ F
        v .= u[1:2:end]
        changed = false
        for i in 1:n
            if active[i] && v[i] < -1e-9
                active[i] = false
                changed = true
            elseif !active[i] && v[i] > 1e-9
                active[i] = true
                changed = true
            end
        end
        changed || break
    end
    reactions = Tuple{Float64, Float64}[]
    qmax = 0.0
    for i in 1:n
        active[i] || continue
        R = k[i] * v[i]
        R > 0 && push!(reactions, (xs[i], R))
        qmax = max(qmax, ks_pa * v[i])
    end
    return reactions, qmax
end

function _beam_nodal_forces(xs, loads)
    F = zeros(length(xs))
    for (x, P) in loads
        if x <= xs[1] + 1e-12
            F[1] += P
            continue
        elseif x >= xs[end] - 1e-12
            F[end] += P
            continue
        end
        i = searchsortedlast(xs, x)
        le = xs[i + 1] - xs[i]
        t = (x - xs[i]) / le
        F[i] += P * (1 - t)
        F[i + 1] += P * t
    end
    return F
end

function _beam_stiffness(xs, EI, k_node)
    n = length(xs)
    K = zeros(n * 2, n * 2)
    for i in 1:n - 1
        le = xs[i + 1] - xs[i]
        le > 0 || continue
        c = EI / le^3
        ke = c .* [12.0  6le    -12.0  6le;
                   6le   4le^2  -6le   2le^2;
                   -12.0 -6le   12.0   -6le;
                   6le   2le^2  -6le   4le^2]
        dofs = [2i - 1, 2i, 2i + 1, 2i + 2]
        K[dofs, dofs] += ke
    end
    for i in 1:n
        K[2i - 1, 2i - 1] += k_node[i]
    end
    return K
end

function _straight_extremes_from_reactions(plan, reactions, loads)
    # Upward spring reactions are negative downward loads.
    combined = Tuple{Float64, Float64}[]
    for (x, P) in loads
        push!(combined, (x, P))
    end
    ups = Tuple{Float64, Float64}[]
    for (x, R) in reactions
        push!(ups, (x, R))
    end
    return _extremes_up_down(plan.along, ups, combined)
end

function _extremes_up_down(Lf, ups, downs)
    xs = Float64[0.0, Lf]
    for (x, _) in ups
        push!(xs, x)
    end
    for (x, _) in downs
        push!(xs, x)
    end
    _unique_stations!(xs)
    Mbot = Mtop = Vmax = 0.0
    for x in xs
        V = 0.0
        M = 0.0
        for (xc, R) in ups
            xc < x - 1e-9 || continue
            V += R
            M += R * (x - xc)
        end
        for (xc, P) in downs
            xc < x - 1e-9 || continue
            V -= P
            M -= P * (x - xc)
        end
        Mbot = max(Mbot, M)
        Mtop = max(Mtop, -M)
        Vmax = max(Vmax, abs(V))
    end
    return (Mbot = Mbot, Mtop = Mtop, Vmax = Vmax)
end

# ── Steel, dowels, result ───────────────────────────────────────────────────

function _wall_finish(legs, soil, opts, plan, extremes, q_gov, q_service_peak,
                      h, d, B, fc, fy, λ, ϕf, ϕv, ϕb, util_shear, analysis)
    As_trans = _wall_transverse_steel(legs, plan, q_gov, h, d, B, fc, fy, ϕf)

    As_min_beam = _beam_min_steel(fc, fy, B, d)
    As_min_slab = _min_steel_footing(B, h, fy)
    As_floor = max(As_min_beam, As_min_slab)
    Mbot = extremes.Mbot * u"N*m"
    Mtop = extremes.Mtop * u"N*m"
    As_bot = max(_flexural_steel_footing(Mbot, B, d, fc, fy, ϕf), As_floor)
    As_top = max(_flexural_steel_footing(Mtop, B, d, fc, fy, ϕf), As_floor)

    As_tension = _wall_tension_steel(legs, ϕf, fy)
    As_bearing, Bn, sqA = _wall_bearing(legs, plan, h, fc, fy, ϕb, opts)
    As_dowel = max(As_tension, As_bearing, _wall_min_dowel(legs, opts.bar_size_long, fy))

    if opts.check_development && !_dowels_fit(legs, plan, h, fc, fy, λ, ϕf, ϕb, opts)
        @warn("Wall dowels do not develop in h − cover = $(h - opts.cover) " *
              "(ACI 318-11 §12.2.1, corpus: aci-318-11, page 214; §15.8.2).")
    end

    q_allow = ustrip(u"Pa", soil.qa)
    util_bearing = q_allow > 0 ? max(q_service_peak, 0.0) / q_allow : Inf
    # `q_service_peak` is a Pa float for the Winkler path and a Pa float from
    # `_q_bounds` for the rigid path. Both are service or factored; the rigid
    # caller passes the factored peak, so compare that path on Pu/Ps below.
    util_q = _service_util(legs, plan, soil)
    if analysis === :winkler
        util_q = max(util_q, q_service_peak / ustrip(u"Pa", soil.qa))
    end
    utilization = max(util_shear, util_q)

    L_report = plan.area / plan.B * u"m"
    V_conc = uconvert(u"m^3", L_report * B * h)
    V_steel = _wall_steel_volume(opts, h, B, L_report, As_bot, As_top, As_trans, As_dowel, fy)
    Bn_out = uconvert(u"N", Bn)
    result = StripFootingResult{typeof(uconvert(u"m", B)),
                                typeof(uconvert(u"m^2", As_bot)),
                                typeof(V_conc),
                                typeof(Bn_out)}(
        uconvert(u"m", B),
        uconvert(u"m", L_report),
        uconvert(u"m", h),
        uconvert(u"m", d),
        uconvert(u"m^2", As_bot),
        uconvert(u"m^2", As_top),
        uconvert(u"m^2", As_trans),
        0,
        V_conc,
        V_steel,
        Float64(utilization),
        uconvert(u"m^2", As_tension),
        Bn_out,
        Float64(sqA),
        analysis,
        FoundationUtilizations(; bearing = Float64(util_q),
                               one_way_shear = Float64(util_shear)),
    )
    return result
end

function _wall_transverse_steel(legs, plan, q_gov, h, d, B, fc, fy, ϕf)
    bw = 1.0u"m"
    As_unit = _min_steel_footing(bw, h, fy)
    for leg in legs
        m = (B - leg.tw) / 2
        Mu = q_gov * m^2 / 2 * bw
        As_unit = max(As_unit, _flexural_steel_footing(Mu, bw, d, fc, fy, ϕf))
    end
    # §15.4.3: uniform across the width, along the whole contact.
    return As_unit * (plan.along * u"m" / bw)
end

function _service_util(legs, plan, soil)
    Ps = sum(_n(smp.Ps) for leg in legs for smp in leg.samples)
    q = Ps / plan.area
    return q / ustrip(u"Pa", soil.qa)
end

function _beam_min_steel(fc, fy, B, d)
    # The column strip's beam minimum: max(3√f'c, 200 psi) / fy · b · d.
    fc_psi = ustrip(u"psi", fc)
    fy_psi = ustrip(u"psi", fy)
    return max(3.0 * sqrt(fc_psi) / fy_psi, 200.0 / fy_psi) *
           ustrip(u"inch", B) * ustrip(u"inch", d) * u"inch^2"
end

"""Tensile interface steel, ACI 318-11 §15.8.1.2(b), page 275. φ is flexure."""
function _wall_tension_steel(legs, ϕf, fy)
    T = 0.0u"N"
    for leg in legs
        for smp in leg.samples
            smp.Pu < zero(smp.Pu) && (T += -smp.Pu)
        end
    end
    T <= zero(T) && return 0.0u"m^2"
    return uconvert(u"m^2", T / (ϕf * fy))
end

"""
Minimum vertical reinforcement crossing the wall-footing joint.

ACI 318-11 §15.8.2.2 (corpus: aci-318-11, page 275) requires the minimum of
§14.3.2 (page 264): 0.0012 when the bars are No. 5 or smaller and fy is at
least 60 ksi, otherwise 0.0015 for other deformed bars.
"""
function _wall_min_dowel(legs, bar_size, fy)
    # ACI 318-11 §14.3.2 (corpus: aci-318-11, page 264): ρℓ is 0.0012 for
    # No. 5 and smaller at fy ≥ 60 ksi, otherwise 0.0015. §15.8.2.2 (page 275)
    # requires that ratio across the joint. The area is ρℓ times the concrete
    # that exists at the base, `leg.solid`, not the centerline through a door.
    ρ = bar_size <= 5 && ustrip(u"psi", fy) >= 60_000.0 ? 0.0012 : 0.0015
    As = 0.0u"m^2"
    for leg in legs
        As += ρ * leg.tw * leg.solid
    end
    return As
end

"""
Dowel area for compression above the supported member's bearing strength.

ACI 318-11 §15.8.1.2(a) (corpus: aci-318-11, page 275) and §10.14.1
(page 162): the supported member's bearing strength is ϕ·0.85·f′c·A1.
§15.8.2.1's 0.005Ag is a column minimum and is not added for a wall.
"""
function _interface_dowel_area(Pu, A1, fc_col, fy, ϕb)
    Pu <= zero(Pu) && return 0.0u"m^2"
    A1 <= zero(A1) && return 0.0u"m^2"
    Bn = ϕb * 0.85 * fc_col * A1
    Pu > Bn || return 0.0u"m^2"
    return max((Pu - Bn) / (ϕb * fy), 0.0u"m^2")
end

"""
True when some bar from No. 3 up to `bar_size` develops in `avail`.

`avail` is the footing thickness above the cover. ACI 318-11 §12.2.1
(corpus: aci-318-11, page 214) is applied inside
[`_development_length_footing`](@ref).
"""
function _bar_develops_in(bar_size::Int, avail, fc, fy, λ, clear_cover)
    avail <= zero(avail) && return false
    for size in bar_size:-1:3
        db = bar_diameter(size)
        _development_length_footing(size, fc, fy, λ, db;
                                     clear_cover = clear_cover) <= avail && return true
    end
    return false
end

function _wall_bearing(legs, plan, h, fc, fy, ϕb, opts)
    opts.check_bearing || return (0.0u"m^2", 0.0u"N", 1.0)
    fc_col = something(opts.fc_col, fc)
    As = 0.0u"m^2"
    Bn = 0.0u"N"
    sqA = 1.0
    have = false
    if plan.straight
        leg = legs[1]
        Pu = sum(max(smp.Pu, zero(smp.Pu)) for smp in leg.samples)
        Pu <= zero(Pu) && return (0.0u"m^2", 0.0u"N", 1.0)
        L = _leg_length_m(leg) * u"m"
        col_along = (plan.x0 + _leg_length_m(leg) / 2) * u"m"
        bearing = _bearing_check_footing(
            Pu, L, leg.tw, plan.B * u"m", plan.along * u"m", h,
            fc, fc_col, fy, ϕb, :rectangular;
            col_along = col_along, col_across = (plan.B / 2) * u"m")
        # §15.8.2.1's 0.005 Ag is a column minimum. A wall uses §15.8.2.2,
        # applied by the caller. A1 is the concrete at the base.
        As = _interface_dowel_area(Pu, leg.solid * leg.tw, fc_col, fy, ϕb)
        return As, bearing.Bn_footing, bearing.sqA
    end
    for (i, leg) in enumerate(legs)
        Pu = sum(max(smp.Pu, zero(smp.Pu)) for smp in leg.samples)
        Pu <= zero(Pu) && continue
        rect = plan.rects[i]
        along = max(rect.x1 - rect.x0, rect.y1 - rect.y0) * u"m"
        across = min(rect.x1 - rect.x0, rect.y1 - rect.y0) * u"m"
        L = _leg_length_m(leg) * u"m"
        bearing = _bearing_check_footing(
            Pu, L, leg.tw, across, along, h,
            fc, fc_col, fy, ϕb, :rectangular;
            col_along = along / 2, col_across = across / 2)
        As += _interface_dowel_area(Pu, leg.solid * leg.tw, fc_col, fy, ϕb)
        if !have || bearing.sqA < sqA
            sqA = bearing.sqA
            Bn = bearing.Bn_footing
            have = true
        end
    end
    return As, Bn, sqA
end

function _wall_steel_volume(opts, h, B, L, As_bot, As_top, As_trans, As_dowel, fy)
    cover = opts.cover
    Ab_l = bar_area(opts.bar_size_long)
    Ab_t = bar_area(opts.bar_size_trans)
    max_s = min(3h, 18.0u"inch")          # ACI 318-11 §7.6.5, page 96
    max_ts = min(5h, 18.0u"inch")         # ACI 318-11 §7.12.2.2, page 106
    n_bot = max(ceil(Int, As_bot / Ab_l), ceil(Int, B / max_s))
    n_top = max(ceil(Int, As_top / Ab_l), ceil(Int, B / max_s))
    n_tr = max(ceil(Int, As_trans / Ab_t), ceil(Int, L / max_ts))
    n_dowel = As_dowel > zero(As_dowel) ? max(ceil(Int, As_dowel / Ab_l), 0) : 0
    return uconvert(u"m^3",
        (n_bot + n_top) * Ab_l * max(L - 2cover, zero(L)) +
        n_tr * Ab_t * max(B - 2cover, zero(B)) +
        n_dowel * Ab_l * max(h - cover, zero(h)))
end
