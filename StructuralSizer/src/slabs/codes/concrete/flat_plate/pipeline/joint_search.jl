# =============================================================================
# Joint search: slab thickness, column sizes, and punching studs
# =============================================================================
# One analysis is scaled to every half-inch thickness (thickness_jump.jl).
# At each thickness each column takes its cheapest passing option, and the
# thickness with the lowest objective is chosen. The sizing loop confirms
# the choice with a real analysis. See docs/flat-plate-joint-sizing-plan.md.

"""Relative objective tolerance inside which the preferred candidate wins."""
const JOINT_TIE_RTOL = 0.01

"""
    material_objective(objective, V_concrete, V_steel, concrete, steel) -> Float64

Objective value of `V_concrete` and `V_steel` (m³, bare numbers) made of
`concrete` and `steel`. Same terms as the flat-plate grid search
(`_flat_plate_objective`): volume, mass, embodied carbon (`ecc`), or cost
per kg. `MinCost` requires both materials to carry a cost.
"""
function material_objective(obj::AbstractObjective, V_concrete::Real, V_steel::Real,
                            concrete, steel)
    obj isa MinVolume && return V_concrete + V_steel
    ρ_c = ustrip(u"kg/m^3", concrete.ρ)
    ρ_s = ustrip(u"kg/m^3", steel.ρ)
    obj isa MinWeight && return V_concrete * ρ_c + V_steel * ρ_s
    if obj isa MinCarbon
        return V_concrete * ρ_c * ustrip(u"kgCO2e/kg", concrete.ecc) +
               V_steel * ρ_s * ustrip(u"kgCO2e/kg", steel.ecc)
    end
    if obj isa MinCost
        (isnan(concrete.cost) || isnan(steel.cost)) &&
            throw(ArgumentError("MinCost requires a cost on both the concrete and the steel"))
        return V_concrete * ρ_c * concrete.cost + V_steel * ρ_s * steel.cost
    end
    throw(ArgumentError("Unsupported objective: $(typeof(obj))"))
end

"""
    joint_thickness_scan(thicknesses; lower_bound, slab_term, column_terms,
                         tie_rtol=JOINT_TIE_RTOL, preference=c -> 0) -> NamedTuple

Lowest-objective thickness among `thicknesses` (ascending).

- `lower_bound(h)`: a bound on the objective of any candidate at `h` or
  thicker. It must not decrease with `h`. The scan stops once it exceeds the
  best objective found, plus the tie tolerance.
- `slab_term(h)`: the slab's objective term, or `nothing` when the slab
  checks fail at `h`.
- `column_terms(h)`: one option per column, each with a `cost` field, or
  `nothing` when some column has no passing option at `h`.

Candidates within `tie_rtol` (relative) of the lowest objective are ranked
by `preference(candidate)` (higher first), then by objective.

Returns `(best, feasible, rejected)`. `best` is `nothing` when no thickness
is feasible. Each feasible candidate is `(h, J, slab, columns)`; each
rejected thickness is `(h, reason)` with reason `:slab` or `:columns`.
"""
function joint_thickness_scan(thicknesses; lower_bound, slab_term, column_terms,
                              tie_rtol::Float64 = JOINT_TIE_RTOL, preference = _ -> 0)
    feasible = NamedTuple[]
    rejected = NamedTuple[]
    best_J = Inf
    within(J) = J <= best_J + tie_rtol * abs(best_J)
    for h in thicknesses
        isfinite(best_J) && !within(lower_bound(h)) && break
        slab = slab_term(h)
        if slab === nothing
            push!(rejected, (h = h, reason = :slab))
            continue
        end
        cols = column_terms(h)
        if cols === nothing
            push!(rejected, (h = h, reason = :columns))
            continue
        end
        J = slab + sum(c -> c.cost, cols; init = 0.0)
        push!(feasible, (h = h, J = J, slab = slab, columns = cols))
        best_J = min(best_J, J)
    end
    isempty(feasible) && return (best = nothing, feasible = feasible, rejected = rejected)
    near = filter(c -> within(c.J), feasible)
    best = near[argmax([(preference(c), -c.J) for c in near])]
    return (best = best, feasible = feasible, rejected = rejected)
end

"""Plan area of `slab` in m², the sum of its cells' areas."""
function _joint_slab_area_m2(struc, slab)
    a(x) = x isa Unitful.Quantity ? ustrip(u"m^2", x) : Float64(x)
    return sum(i -> a(struc.cells[i].area), slab.cell_indices; init = 0.0)
end

"""Longitudinal steel area of the column's current section (zero when it has none)."""
function _joint_section_steel(col)
    s = col.base.section
    return s !== nothing && hasproperty(s, :As_total) ? s.As_total : 0.0u"m^2"
end

"""Gross area of `col` at plan size `c1 × c2` (circular columns use `c1` as the diameter)."""
_joint_gross_area(col, c1, c2) =
    col_shape(col) == :circular ? π / 4 * c1^2 : c1 * c2

"""
    _joint_column_term(col, c1, c2, Ast_floor, obj, column_opts) -> Float64

Objective of one story of `col` at `c1 × c2`: concrete over the column
length plus longitudinal steel. The steel is the larger of `Ast_floor`
(the bars of the axial and moment design) and ACI 318-11 §10.9.1's
minimum 0.01·Ag. A takeoff estimate for ranking; the bars that are built
come from the column design.
"""
function _joint_column_term(col, c1, c2, Ast_floor, obj, column_opts)
    L = ustrip(u"m", col.base.L)
    Ag = ustrip(u"m^2", _joint_gross_area(col, c1, c2))
    Ast = max(ustrip(u"m^2", Ast_floor), 0.01 * Ag)
    return material_objective(obj, (Ag - Ast) * L, Ast * L,
                              column_opts.material, column_opts.rebar_material)
end

"""
    _joint_stud_volume(studs, h, cover) -> Float64

Stud shank steel (m³) of a `ShearStudDesign`: area per peripheral line ×
number of lines × shank length, with the shank taken as `h − 2·cover`.
Rails and heads are not counted. A takeoff estimate for ranking.
"""
function _joint_stud_volume(studs, h, cover)
    studs === nothing && return 0.0
    L = max(ustrip(u"m", h - 2 * cover), 0.0)
    return ustrip(u"m^2", studs.Av_per_line) * studs.n_studs_per_rail * L
end

"""
    _joint_slab_rebar_volume(primary, secondary, columns, h, d, fc, fy, cover, bar_dia;
                             βt, struc, slab) -> Union{Nothing, Float64}

Slab reinforcing steel per plan area (m) from the strip design on the
(scaled) moments, placed as in [`_calc_rebar_volume_per_area`](@ref).
`nothing` when a strip section is inadequate at `h`, which Phase C would
answer with more depth.
"""
function _joint_slab_rebar_volume(primary, secondary, columns, h, d, fc, fy, cover, bar_dia;
                                  βt, struc, slab)
    ax = _get_span_axis(slab)
    pr = design_strip_reinforcement(primary, columns, h, d, fc, fy, cover;
                                    βt = βt, struc = struc, slab = slab, span_axis = ax)
    pr.section_adequate || return nothing
    vol = _direction_placed_volume(pr.column_strip_reinf, pr.middle_strip_reinf,
                                   pr.column_strip_width, pr.middle_strip_width,
                                   primary.l1, h)
    if secondary === nothing
        vol *= 2
    else
        d_inner = inner_layer_effective_depth(h, cover, bar_dia, bar_dia)
        sr = design_strip_reinforcement(secondary, columns, h, d_inner, fc, fy, cover;
                                        βt = βt, struc = struc, slab = slab,
                                        span_axis = (-ax[2], ax[1]))
        sr.section_adequate || return nothing
        vol += _direction_placed_volume(sr.column_strip_reinf, sr.middle_strip_reinf,
                                        sr.column_strip_width, sr.middle_strip_width,
                                        primary.l2, h)
    end
    return ustrip(u"m", vol / (primary.l1 * primary.l2))
end

"""
    _joint_column_option(i, col, h, d, primary, secondary, ctx) -> Union{Nothing, NamedTuple}

Cheapest passing option for column `i` at thickness `h` under the scaled
demand: the smallest size at or above `ctx.c_floor[i]` that passes punching
bare, or a smaller size with headed studs when `ctx.studs` is true. Sizes
follow the growth direction of `solve_column_for_punching`, as the punching
resolver does. Column sizes are restored before returning.

Returns `(c1, c2, studs, punching, cost)`, or `nothing` when no size within
`opts.max_column_size` passes.
"""
function _joint_column_option(i, col, h, d, primary, secondary, ctx)
    opts = ctx.opts
    c1_0, c2_0 = col.c1, col.c2
    col.c1, col.c2 = ctx.c_floor[i]
    kw = punching_axis_kwargs(ctx.struc, ctx.slab, col)
    Vu = primary.column_shears[i]
    Mub = primary.unbalanced_moments[i]
    Muy = secondary === nothing ? nothing : secondary.unbalanced_moments[i]
    demand = (Vu = Vu, Mub = Mub, Muy = Muy)
    check() = check_punching_for_column(col, Vu, Mub, d, h, ctx.fc;
        verbose = false, col_idx = i, λ = ctx.λ, φ_shear = ctx.φ_shear, Muy = Muy,
        _geom_cache = ctx.geom_cache, moment_transfer = ctx.moment_transfer, kw...)
    term(c1, c2) = _joint_column_term(col, c1, c2, ctx.Ast_floor[i], opts.objective,
                                      ctx.column_opts)

    pr0 = check()
    sizes = [(col.c1, col.c2)]
    if !pr0.ok
        Mx = secondary === nothing ? nothing : primary.column_moments[i]
        My = secondary === nothing ? nothing : secondary.column_moments[i]
        target = solve_column_for_punching(col, pr0.ratio, pr0.b0, d;
            shape_constraint = ctx.column_opts.shape_constraint,
            max_ar = ctx.column_opts.max_aspect_ratio,
            Mx = Mx, My = My, increment = ctx.column_opts.size_increment)
        grow = (target = target, c_max = opts.max_column_size,
                inc = ctx.column_opts.size_increment,
                shape = ctx.column_opts.shape_constraint,
                max_ar = ctx.column_opts.max_aspect_ratio)
        append!(sizes, _column_candidates(col, grow))
    end

    best = nothing
    for (k, (c1, c2)) in enumerate(sizes)
        cost_col = term(c1, c2)
        best !== nothing && cost_col >= best.cost && break
        col.c1, col.c2 = c1, c2
        pr = k == 1 ? pr0 : check()
        if pr.ok
            best = (c1 = c1, c2 = c2, studs = nothing, punching = pr, cost = cost_col)
            break
        end
        ctx.studs || continue
        reinf = _try_reinforcement(opts.punching_reinforcement, pr.vu, ctx.fc, pr.b0, d, h,
                                   col, opts, primary, demand;
                                   λ = ctx.λ, φ = ctx.φ_shear, punch_kwargs = kw)
        reinf.ok || continue
        stud_cost = opts.stud_weight * material_objective(
            opts.objective, 0.0, _joint_stud_volume(reinf.studs, h, ctx.cover),
            ctx.concrete, opts.stud_material)
        cost = cost_col + stud_cost
        if best === nothing || cost < best.cost
            best = (c1 = c1, c2 = c2, studs = reinf,
                    punching = _merge_reinforcement_result(pr, reinf), cost = cost)
        end
    end
    col.c1, col.c2 = c1_0, c2_0
    return best
end

"""
    _joint_scan_closures(primary, secondary, h0, ctx) -> NamedTuple

The shared ingredients of the thickness scan: the thickness list, the
scaled-demand accessor `at(h)` (one analysis scaled to each thickness via
`thickness_jump.jl`), `depth(h)`, the slab objective term `slab_term(h)`, the
concrete-only lower bound `concrete_term(h)`, and the tie `preference(c)`.

Both the production `joint_search` and the reference `brute_force_joint_optimum`
build their scan from this, so they are guaranteed to use *identical* demand
scaling, slab terms, depth checks, and tie rules — they differ only in the
column enumeration and the early-stop. That is precisely the pruning the proving
slice certifies, so sharing the closures keeps the comparison honest.
"""
function _joint_scan_closures(primary, secondary, h0, ctx)
    qu0 = governing_uniform_pressure(primary.qD, primary.qL)
    inch(x) = uconvert(u"inch", float(x))
    thicknesses = [inch(h0)]
    ctx.thicken && append!(thicknesses,
                           inch.(_thickness_candidates(h0, ctx.h_increment, ctx.h_max)))
    scaled = Dict{eltype(thicknesses), Any}()
    at = function (h)
        get!(scaled, h) do
            h ≈ h0 && return (primary, secondary)
            loads = loads_at_thickness(primary.qD, primary.qL, h0, h, ctx.γ)
            r = ustrip(loads.qu / qu0)
            dscale = r * ustrip((h0 / h)^3)
            (scale_moment_result(primary, r, dscale, loads.qD, loads.qu),
             _scale_secondary(secondary, r, dscale, loads.qD, loads.qu))
        end
    end
    depth(h) = effective_depth(h; cover = ctx.cover, bar_diameter = ctx.bar_dia)
    concrete_term(h) = material_objective(ctx.opts.objective,
                                          ctx.slab_area_m2 * ustrip(u"m", h), 0.0,
                                          ctx.concrete, ctx.rebar)

    function slab_term(h)
        sp, ss = at(h)
        ctx.depth_passes(h, sp, ss) || return nothing
        d = depth(h)
        walls = wall_reaction_punching(ctx.struc, ctx.slab, d, ctx.fc, sp.qu;
                                       λ = ctx.λ, ϕ = ctx.φ_shear,
                                       wall_transfer = wall_transfer_of(sp, ss))
        all(c -> c.ok, walls) || return nothing
        rebar = _joint_slab_rebar_volume(sp, ss, ctx.columns, h, d, ctx.fc, ctx.fy,
                                         ctx.cover, ctx.bar_dia;
                                         βt = ctx.βt, struc = ctx.struc, slab = ctx.slab)
        rebar === nothing && return nothing
        h_m = ustrip(u"m", h)
        return material_objective(ctx.opts.objective,
                                  ctx.slab_area_m2 * (h_m - rebar), ctx.slab_area_m2 * rebar,
                                  ctx.concrete, ctx.rebar)
    end

    function preference(c)
        p = ctx.preferred
        p === nothing && return 0
        score = p.h !== nothing && c.h ≈ p.h ? 1 : 0
        for (i, o) in enumerate(c.columns)
            s = get(p.columns, i, nothing)
            s !== nothing && o.c1 ≈ s[1] && o.c2 ≈ s[2] && (score += 1)
        end
        return score
    end

    return (thicknesses = thicknesses, at = at, depth = depth,
            concrete_term = concrete_term, slab_term = slab_term, preference = preference)
end

"""
    _joint_column_terms(cl, ctx, full) -> (h -> options | nothing)

The scan's `column_terms`: one option per column at `h`, or `nothing` if any
column has no passing option. `full=false` uses the production cheapest-passing
option (`_joint_column_option`); `full=true` uses the exhaustive reference
(`_joint_column_option_full`).
"""
function _joint_column_terms(cl, ctx, full::Bool)
    opt = full ? _joint_column_option_full : _joint_column_option
    return function (h)
        sp, ss = cl.at(h)
        d = cl.depth(h)
        out = NamedTuple[]
        for (i, col) in enumerate(ctx.columns)
            o = opt(i, col, h, d, sp, ss, ctx)
            o === nothing && return nothing
            push!(out, o)
        end
        return out
    end
end

"""
    joint_search(primary, secondary, h0, ctx) -> NamedTuple

Scan thicknesses from `h0` (the analyzed thickness) up to `ctx.h_max` with
demands scaled from `primary`/`secondary`, and return the scan result of
[`joint_thickness_scan`](@ref). With `ctx.thicken` false only `h0` is tried.

Each thickness must pass `ctx.depth_passes(h, scaled_primary,
scaled_secondary)` (deflection, one-way shear, flexure, transfer) and the
wall reaction punching checks, which no column option can change. The slab
term is concrete plus the strip-design rebar. The preference favours the
thickness of the floor above and its column sizes (`ctx.preferred`).

`ctx` carries `struc, slab, columns, opts, column_opts, fc, fy, λ, φ_shear,
cover, bar_dia, γ, h_increment, h_max, βt, slab_area_m2, c_floor,
Ast_floor, geom_cache, moment_transfer, depth_passes, studs, thicken,
concrete, rebar, preferred`.
"""
function joint_search(primary, secondary, h0, ctx)
    cl = _joint_scan_closures(primary, secondary, h0, ctx)
    result = joint_thickness_scan(cl.thicknesses; lower_bound = cl.concrete_term,
                                  slab_term = cl.slab_term,
                                  column_terms = _joint_column_terms(cl, ctx, false),
                                  preference = cl.preference)
    # Proving hook (default OFF ⇒ production is byte-identical): certify that the
    # concrete early-stop and the per-column cheapest-passing short-circuit never
    # skip a cheaper feasible design. See scripts/runners/joint_search_proving_slice.jl.
    get(ENV, "SS_PROVE_JOINT_SEARCH", "") == "1" && _record_joint_prove!(result, cl, ctx)
    return result
end

# =============================================================================
# Proving reference: exhaustive joint optimum (no prunings)
# =============================================================================

"""
    _full_size_grid(col, ctx, floor) -> Vector{Tuple}

Every column plan size on the `size_increment` grid from the per-column `floor`
up to `opts.max_column_size` — a SUPERSET of the sizes the production growth ray
(`_column_candidates`) visits. Square and circular columns enumerate the single
dimension; `:bounded`/`:free` enumerate the full 2-D grid, filtered (for
`:bounded`) by the aspect-ratio clamp. Reference-only; never used in production.
"""
function _full_size_grid(col, ctx, floor)
    inc  = ustrip(u"inch", ctx.column_opts.size_increment)
    cmax = ustrip(u"inch", ctx.opts.max_column_size)
    f1   = ustrip(u"inch", floor[1])
    f2   = ustrip(u"inch", floor[2])
    grid(lo) = lo:inc:(cmax + 1.0e-9)
    out = Tuple{typeof(col.c1), typeof(col.c2)}[]
    if col_shape(col) == :circular || ctx.column_opts.shape_constraint === :square
        for c in grid(max(f1, f2))
            push!(out, (c * u"inch", c * u"inch"))
        end
    else
        max_ar = ctx.column_opts.max_aspect_ratio
        for c1 in grid(f1), c2 in grid(f2)
            if ctx.column_opts.shape_constraint === :bounded
                ar = c1 / c2
                (ar > max_ar + 1.0e-9 || ar < 1.0 / max_ar - 1.0e-9) && continue
            end
            push!(out, (c1 * u"inch", c2 * u"inch"))
        end
    end
    return out
end

"""
    _joint_column_option_full(i, col, h, d, primary, secondary, ctx) -> option | nothing

The GLOBALLY cheapest passing option for column `i` at thickness `h`, enumerating
the entire `_full_size_grid` with NO cheapest-passing short-circuit. Uses the
identical punching check (`check_punching_for_column`), stud design
(`_try_reinforcement`), and cost term (`_joint_column_term`) as the production
[`_joint_column_option`](@ref), so any disagreement is a pruning defect, not a
mechanics difference. Reference-only. Column sizes are restored before returning.
"""
function _joint_column_option_full(i, col, h, d, primary, secondary, ctx)
    opts = ctx.opts
    c1_0, c2_0 = col.c1, col.c2
    kw = punching_axis_kwargs(ctx.struc, ctx.slab, col)
    Vu  = primary.column_shears[i]
    Mub = primary.unbalanced_moments[i]
    Muy = secondary === nothing ? nothing : secondary.unbalanced_moments[i]
    demand = (Vu = Vu, Mub = Mub, Muy = Muy)
    term(c1, c2) = _joint_column_term(col, c1, c2, ctx.Ast_floor[i], opts.objective,
                                      ctx.column_opts)
    best = nothing
    for (c1, c2) in _full_size_grid(col, ctx, ctx.c_floor[i])
        col.c1, col.c2 = c1, c2
        pr = check_punching_for_column(col, Vu, Mub, d, h, ctx.fc;
            verbose = false, col_idx = i, λ = ctx.λ, φ_shear = ctx.φ_shear, Muy = Muy,
            _geom_cache = ctx.geom_cache, moment_transfer = ctx.moment_transfer, kw...)
        cost_col = term(c1, c2)
        if pr.ok
            if best === nothing || cost_col < best.cost
                best = (c1 = c1, c2 = c2, studs = nothing, punching = pr, cost = cost_col)
            end
            continue
        end
        ctx.studs || continue
        reinf = _try_reinforcement(opts.punching_reinforcement, pr.vu, ctx.fc, pr.b0, d, h,
                                   col, opts, primary, demand;
                                   λ = ctx.λ, φ = ctx.φ_shear, punch_kwargs = kw)
        reinf.ok || continue
        stud_cost = opts.stud_weight * material_objective(
            opts.objective, 0.0, _joint_stud_volume(reinf.studs, h, ctx.cover),
            ctx.concrete, opts.stud_material)
        cost = cost_col + stud_cost
        if best === nothing || cost < best.cost
            best = (c1 = c1, c2 = c2, studs = reinf,
                    punching = _merge_reinforcement_result(pr, reinf), cost = cost)
        end
    end
    col.c1, col.c2 = c1_0, c2_0
    return best
end

"""
    brute_force_joint_optimum(primary, secondary, h0, ctx) -> scan result

The reference joint optimum over the SAME discrete grid `joint_search` searches,
with both prunings disabled: every thickness is scanned (`lower_bound = -Inf`, no
concrete early-stop) and every column size on the increment grid is evaluated (no
cheapest-passing short-circuit). Shares `joint_search`'s demand scaling, slab
terms, and punching checks, so it differs only by exhaustiveness.
"""
function brute_force_joint_optimum(primary, secondary, h0, ctx)
    cl = _joint_scan_closures(primary, secondary, h0, ctx)
    return joint_thickness_scan(cl.thicknesses; lower_bound = _ -> -Inf,
                                slab_term = cl.slab_term,
                                column_terms = _joint_column_terms(cl, ctx, true),
                                preference = cl.preference)
end

"""Accumulated proving-slice comparisons (`SS_PROVE_JOINT_SEARCH=1`); cleared by the runner."""
const JOINT_PROVE_LOG = NamedTuple[]

"""Run the exhaustive reference on the same closures and log it against `result`.

Compares the MINIMUM feasible objective of each scan (not `best.J`), so the check
is pure global optimality — independent of the 1% tie rule and the `preference`
that pick among near-ties. If the two prunings are valid, production's minimum
equals the exhaustive minimum exactly."""
function _record_joint_prove!(result, cl, ctx)
    bf = joint_thickness_scan(cl.thicknesses; lower_bound = _ -> -Inf,
                              slab_term = cl.slab_term,
                              column_terms = _joint_column_terms(cl, ctx, true),
                              preference = cl.preference)
    min_feasible(r) = isempty(r.feasible) ? nothing : minimum(c -> c.J, r.feasible)
    pj = min_feasible(result)
    bj = min_feasible(bf)
    relerr = (pj === nothing || bj === nothing) ? (pj === bj ? 0.0 : Inf) :
             abs(pj - bj) / max(abs(bj), 1.0)
    push!(JOINT_PROVE_LOG,
          (prod_minJ = pj, bf_minJ = bj, relerr = relerr,
           n_prod_feasible = length(result.feasible), n_bf_feasible = length(bf.feasible),
           prod_h = result.best === nothing ? nothing : ustrip(u"inch", result.best.h),
           bf_h   = bf.best   === nothing ? nothing : ustrip(u"inch", bf.best.h),
           n_thick = length(cl.thicknesses)))
    return nothing
end
