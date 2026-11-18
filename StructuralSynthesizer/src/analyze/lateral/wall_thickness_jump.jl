# =============================================================================
# Wall thickness jump
# =============================================================================
# One lateral (or gravity) analysis predicts the next inch thicknesses.
# `:all` confirms with one remesh: every wall moves together, so the
# in-plane forces still apply. A finer grouping remeshes and solves again,
# because the groups no longer share one stiffness.

"""
Ωv, ωv, and φ from the analysis, held while the thickness changes.

φ stays at the analyzed value. A wall that was at 0.60 is not given 0.75
at a greater thickness. `Ωv_cases` is as on [`SpecialShearTerms`](@ref),
indexed by the trial's actions.
"""
struct WallThicknessShear
    Ωv::Float64
    ωv::Float64
    φ::Float64
    "Height αc reads [m]."
    hw_m::Float64
    "Stack height for §18.10.4.3 [m]."
    hwcs_m::Float64
    Ωv_cases::Vector{Float64}
end

WallThicknessShear(Ωv, ωv, φ, hw_m, hwcs_m) =
    WallThicknessShear(Ωv, ωv, φ, hw_m, hwcs_m, Float64[])

"""One pier's frozen demand, ready to re-check at another thickness."""
struct WallThicknessTrial
    wall::Wall
    actions::Vector{CombinedWallAction}
    "Unfactored self-weight axial force of this stack at the analyzed thickness [N]."
    N_self0::Float64
    lw::Unitful.Length
    Moop::Unitful.Quantity
    material::ReinforcedConcreteMaterial
    hw::Unitful.Length
    assembly::Union{Nothing, WallAssembly}
    boundary::Symbol
    "Special-wall shear factors, or `nothing` for an ordinary pier."
    shear::Union{Nothing, WallThicknessShear}
    "Dead and live pressures that pair `Moop` with each combination, or `nothing`."
    slab_basis
end

function WallThicknessTrial(wall, actions, N_self0, lw, Moop, material, hw,
                            assembly, boundary, shear)
    return WallThicknessTrial(wall, actions, N_self0, lw, Moop, material, hw,
                              assembly, boundary, shear, nothing)
end

"""Inch grid the jump walks. CIP walls are specified in whole inches."""
const WALL_THICKNESS_INCREMENT = 1.0u"inch"

"Smallest whole-inch thickness that is at least `t`."
function _inch_ceiling(t)
    inc = ustrip(u"m", WALL_THICKNESS_INCREMENT)
    return ceil(ustrip(u"m", t) / inc - 1e-9) * inc * u"m"
end
"""Practical ceiling when shear and drift do not ask for more."""
const WALL_THICKNESS_DEFAULT_MAX = 24.0u"inch"
"""Starting thickness catalog. A hard constraint errors past this."""
const WALL_THICKNESS_HARD_MAX = 36.0u"inch"
"How far a soft thickness catalog steps when the current limit fails."
const WALL_THICKNESS_CATALOG_STEP = 12.0u"inch"
"Top of the soft thickness catalog. Past this, the jump errors."
const WALL_THICKNESS_CATALOG_TOP = 72.0u"inch"

"`:hard` and `:soft` are the thickness-catalog constraints."
function _require_catalog_constraint(constraint::Symbol)
    constraint in (:hard, :soft) || throw(ArgumentError(
        "wall_catalog_constraint :$constraint is not :hard or :soft"))
    return constraint
end

"Whole inches, for a catalog warning."
_thickness_inches(t) = round(Int, ustrip(u"inch", t))

"""
Raise `limit` until it covers `need`.

`:hard` errors when `need` is past `limit`. `:soft` steps by
[`WALL_THICKNESS_CATALOG_STEP`](@ref) up to [`WALL_THICKNESS_CATALOG_TOP`](@ref)
and warns once. A need past the top errors on either constraint.
"""
function _raise_catalog_limit(need, limit; constraint::Symbol)
    _require_catalog_constraint(constraint)
    need_m = ustrip(u"m", need)
    limit_m = ustrip(u"m", limit)
    need_m <= limit_m + 1e-4 && return limit
    top = WALL_THICKNESS_CATALOG_TOP
    if constraint === :hard
        throw(ArgumentError(
            "wall thickness catalog is hard at $(_thickness_inches(limit)) in; " *
            "the demand needs $(_thickness_inches(need)) in."))
    end
    step = ustrip(u"m", WALL_THICKNESS_CATALOG_STEP)
    top_m = ustrip(u"m", top)
    bumped = limit_m
    while bumped + 1e-6 < need_m && bumped + 1e-6 < top_m
        bumped = min(top_m, bumped + step)
    end
    bumped_q = bumped * u"m"
    if need_m > bumped + 1e-4
        throw(ArgumentError(
            "wall thickness catalog stops at $(_thickness_inches(top)) in; " *
            "the demand needs $(_thickness_inches(need)) in."))
    end
    @warn "Wall thickness catalog: nothing through $(_thickness_inches(limit)) in " *
          "covers the demand; raising the limit to $(_thickness_inches(bumped_q)) in."
    return bumped_q
end

"""
One step past `limit` when no thickness in the catalog passes.

`:hard`, and a soft catalog already at the top, error.
"""
function _bump_wall_catalog(limit; constraint::Symbol)
    _require_catalog_constraint(constraint)
    top = WALL_THICKNESS_CATALOG_TOP
    if constraint === :hard || ustrip(u"m", limit) >= ustrip(u"m", top) - 1e-6
        stop = ustrip(u"m", limit) < ustrip(u"m", top) ? limit : top
        throw(ArgumentError(
            "wall thickness catalog is :$constraint and stops at " *
            "$(_thickness_inches(stop)) in, and no thickness in it passes."))
    end
    bumped = min(top, limit + WALL_THICKNESS_CATALOG_STEP)
    @warn "Wall thickness catalog: no thickness through $(_thickness_inches(limit)) in " *
          "passes; raising the limit to $(_thickness_inches(bumped)) in."
    return bumped
end

"""
    shared_wall_thickness(walls) -> thickness or nothing

The one thickness every wall carries, or `nothing` when the set is empty or
the thicknesses differ by more than 1 mm. The jump keeps relative stiffness
by moving that one value.
"""
function shared_wall_thickness(walls)
    isempty(walls) && return nothing
    t0 = walls[1].thickness
    t0m = ustrip(u"m", t0)
    t0m > 0 || return nothing
    for w in walls
        abs(ustrip(u"m", w.thickness) - t0m) <= 1e-3 || return nothing
    end
    return t0
end

"""
Groupings for [`wall_thickness_groups`](@ref), coarsest first.

`:all` is one thickness. `:story` steps by story. `:wall_line` is one
connected collinear run over every story. `:pier_stack` is one pier repeated
up the height. `:wall_line_story` is that run on one story. `:pier` is each
wall. [`propose_wall_thicknesses`](@ref) sizes every one of these. `:all`
keeps relative stiffness, so its confirm is a single remesh. The others
re-solve.
"""
const WALL_THICKNESS_GROUPINGS = (
    :all, :story, :wall_line, :pier_stack, :wall_line_story, :pier,
)

"""
Thickness jumps this grouping may make; the stage runs one more analysis
than this.

`:all` keeps relative stiffness, so one jump normally confirms. A finer
grouping can move shear onto a wall that was not the worst one, so the loop
may re-solve until nothing grows. Past the cap, the last analysis stands,
its failing checks stay on the record, and the stage reports that the
thickness had not settled.
"""
function _wall_thickness_pass_cap(grouping::Symbol)
    return grouping === :all ? 2 : 6
end

"""
    wall_thickness_groups(walls; grouping=:all) -> Vector{Int}

Group id of each wall, compact from 1. An empty list returns an empty vector.
An unknown `grouping` throws.
"""
function wall_thickness_groups(walls; grouping::Symbol=:all)
    grouping in WALL_THICKNESS_GROUPINGS || throw(ArgumentError(
        "wall thickness grouping :$grouping is not one of " *
        "$(join(WALL_THICKNESS_GROUPINGS, ", "))"))
    n = length(walls)
    n == 0 && return Int[]
    raw = if grouping === :all
        fill(1, n)
    elseif grouping === :pier
        collect(1:n)
    elseif grouping === :story
        [w.story for w in walls]
    elseif grouping === :pier_stack
        members = _wall_plan_stack_members(walls)
        [minimum(members[i]) for i in 1:n]
    elseif grouping === :wall_line
        _wall_line_roots(walls)
    else
        line = _wall_line_roots(walls)
        [line[i] * 1_000_003 + walls[i].story for i in 1:n]
    end
    return _compact_group_ids(raw)
end

"""Throw unless `wall_thickness_grouping` names one partition in [`WALL_THICKNESS_GROUPINGS`](@ref)."""
function _require_wall_thickness_grouping(params)
    g = params.wall_thickness_grouping
    g in WALL_THICKNESS_GROUPINGS || throw(ArgumentError(
        "wall_thickness_grouping :$g is not one of $(join(WALL_THICKNESS_GROUPINGS, ", "))"))
    return nothing
end

"""
    _thickness_group_members(walls; grouping=:all) -> Vector{Vector{Int}}

Indices into `walls` for each group, in the order [`wall_thickness_groups`](@ref)
first sees them.
"""
function _thickness_group_members(walls; grouping::Symbol=:all)
    ids = wall_thickness_groups(walls; grouping)
    isempty(ids) && return Vector{Int}[]
    groups = [Int[] for _ in 1:maximum(ids)]
    for (i, g) in enumerate(ids)
        push!(groups[g], i)
    end
    return groups
end

"Renumber `raw` keys as 1, 2, … in first-seen order."
function _compact_group_ids(raw::Vector{Int})
    ids = Dict{Int, Int}()
    out = similar(raw)
    next = 0
    for (i, key) in enumerate(raw)
        out[i] = get!(ids, key) do
            next += 1
        end
    end
    return out
end

"Plan line of one wall: unit direction, offset, and the station interval. `nothing` when the wall has no length."
function _wall_line_geom(w)
    dx = w.x2 - w.x1
    dy = w.y2 - w.y1
    L = hypot(dx, dy)
    L < 1e-9 && return nothing
    ux, uy = dx / L, dy / L
    if ux < -1e-12 || (abs(ux) <= 1e-12 && uy < 0)
        ux = -ux
        uy = -uy
    end
    offset = -uy * w.x1 + ux * w.y1
    s1 = ux * w.x1 + uy * w.y1
    s2 = ux * w.x2 + uy * w.y2
    return (ux=ux, uy=uy, offset=offset, s0=min(s1, s2), s1=max(s1, s2))
end

"True when the two plan lines touch or overlap within `tol` metres."
function _collinear_wall_run(a, b; tol::Float64=1e-3)
    (a === nothing || b === nothing) && return false
    abs(a.ux * b.ux + a.uy * b.uy) >= 1 - 1e-8 || return false
    abs(a.offset - b.offset) <= tol || return false
    return max(a.s0, b.s0) - min(a.s1, b.s1) <= tol
end

"Union-find root of each wall's connected collinear run."
function _wall_line_roots(walls; tol::Float64=1e-3)
    n = length(walls)
    parent = collect(1:n)
    function find(i)
        while parent[i] != i
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    geom = [_wall_line_geom(w) for w in walls]
    for i in 1:(n - 1), j in (i + 1):n
        _collinear_wall_run(geom[i], geom[j]; tol) || continue
        ra, rb = find(i), find(j)
        ra != rb && (parent[rb] = ra)
    end
    return [find(i) for i in 1:n]
end

"""
Unfactored self-weight of this pier plus every wall stacked above it [N].

The cut is at this pier's base. Density is the reinforced-concrete material
used in the check.
"""
function pier_self_weight_N(wall, t, lw, ρ)
    t_m = t isa Unitful.Length ? ustrip(u"m", t) : Float64(t)
    lw_m = lw isa Unitful.Length ? ustrip(u"m", lw) : Float64(lw)
    h_m = ustrip(u"m", _stacked_wall_height(wall))
    ρ_kg = ustrip(u"kg/m^3", ρ)
    return ρ_kg * t_m * lw_m * h_m * 9.80665
end

"""
    wall_thickness_scale_applies(t0, trials) -> Bool

True when axial dead load can be split into self-weight and tributary.

A stored 1.4D axial below 1.4 times the geometric self-weight is not that
split, so the scale is refused. Mixed thicknesses are refused by
[`shared_wall_thickness`](@ref) before this is called.
"""
function wall_thickness_scale_applies(t0, trials::AbstractVector{WallThicknessTrial})
    t0m = ustrip(u"m", t0)
    t0m > 0 || return false
    isempty(trials) && return true
    for trial in trials
        trial.N_self0 >= -1.0 || return false
        N14 = _action_axial(trial.actions, :strength_1_4D)
        N14 === nothing && continue
        trib = N14 / 1.4 - trial.N_self0
        trib >= -1.0e3 || return false
    end
    return true
end

function _action_axial(actions, name::Symbol)
    for a in actions
        a.combination === name && a.alternative === :only && return a.N
    end
    return nothing
end

function _combo_named(name::Symbol)
    for c in asce7_strength_combinations
        c.name === name && return c
    end
    throw(ArgumentError(
        "wall thickness jump: no strength combination named $(name)"))
end

"""
    scale_wall_action(action, t, t0, N_self0, SDS) -> CombinedWallAction

New axial force at thickness `t`. Lateral V and M stay.

Dead self-weight in `N` scales with `t/t0`. `Ev = 0.2 SDS D` (ASCE 7-22
Eq. 12.4-4a, corpus: asce-7-22, PDF page 183) follows that dead effect.
"""
function scale_wall_action(action::CombinedWallAction, t, t0, N_self0, SDS)
    t_m = ustrip(u"m", t)
    t0_m = ustrip(u"m", t0)
    t0_m > 0 || throw(ArgumentError("wall thickness jump: analyzed thickness must be positive"))
    Δ = N_self0 * (t_m / t0_m - 1.0)
    combo = _combo_named(action.combination)
    γ = combo.D + combo.Ev * 0.2 * Float64(SDS)
    return CombinedWallAction(action.combination, action.alternative,
                              action.N + γ * Δ, action.V, action.M,
                              action.Vo, action.Mo)
end

"""
Story shear filed on whichever wall is most nearly along the axis.

The ratio scales as t0/t only when every wall thickens by the same factor,
so a group proposal keeps this check even when another wall holds the record.
"""
const _INTERACTIVE_WALL_SHEAR = "interactive wall shear"

"""
True when a thicker wall is not the remedy for a failing `check`.

Interactive frame strength is a frame problem. Reported out-of-plane
resultants are not strength checks. Net axial tension makes the §11.5.3
bearing method inapplicable at any thickness.
"""
function _thickness_unresponsive(check::AbstractString)
    return check == "interactive frame strength" ||
           occursin("reported", check) ||
           occursin("net axial tension", check)
end

"""
    wall_result_needs_thickness(result) -> Bool

True when a story drift failed or a pier check failed that thickness can fix.
"""
function wall_result_needs_thickness(result::OrdinaryWallResult)
    any(c -> !c.passes, result.drift) && return true
    for records in values(result.checks)
        for r in records
            r.passed && continue
            _thickness_unresponsive(r.check) && continue
            return true
        end
    end
    return false
end

"""
Thickness the failing §11.5.3 geometric gates ask for, or `t0` when none fail.

Table 11.3.1.1 records `h_min / h` and the slenderness gate records
`k lc / (32 h)`. Both are geometry over thickness, so `t0 · ratio` is the
thickness that meets the gate with no new analysis.
"""
function _geometric_thickness_need(result::OrdinaryWallResult, t0)
    t_need = t0
    for records in values(result.checks)
        for r in records
            r.passed && continue
            (occursin("thickness below minimum", r.check) ||
             occursin("too slender for simplified method", r.check)) || continue
            isfinite(r.ratio) || continue
            t_need = max(t_need, t0 * r.ratio)
        end
    end
    return t_need
end

"""
Linear capacity in thickness: frozen demand, Vn ~ t, so the ratio scales as t0/t.
"""
function _linear_capacity_ratio(result::OrdinaryWallResult, name::AbstractString)
    rmax = 0.0
    for records in values(result.checks)
        for r in records
            r.check == name || continue
            rmax = max(rmax, r.ratio)
        end
    end
    return rmax
end

function _drift_scale(drift)
    isempty(drift) && return 1.0
    s = 1.0
    for c in drift
        c.allowable_m > 0 || continue
        s = max(s, c.drift_m / c.allowable_m)
    end
    return s
end

"""
    wall_thickness_candidates(t0; increment, t_max, t_hard) -> Vector

Inch stations strictly above `t0`, up to `t_max` and not past `t_hard`.
"""
function wall_thickness_candidates(t0::Unitful.Length;
                                   increment=WALL_THICKNESS_INCREMENT,
                                   t_max=WALL_THICKNESS_DEFAULT_MAX,
                                   t_hard=WALL_THICKNESS_HARD_MAX)
    t0m = ustrip(u"m", t0)
    inc = ustrip(u"m", increment)
    tmax = min(ustrip(u"m", t_hard), max(ustrip(u"m", t_max), t0m + inc))
    inc > 0 || throw(ArgumentError("wall thickness jump: increment must be positive"))
    first = ceil((t0m + 1e-9) / inc) * inc
    first > tmax + 1e-12 && return typeof(1.0u"m")[]
    out = typeof(1.0u"m")[]
    t = first
    while t <= tmax + 1e-12
        push!(out, t * u"m")
        t += inc
    end
    return out
end

"""
    wall_thickness_passes(t, t0, trials, drift; SDS=0) -> Bool

Re-pick ρ and rerun the ordinary checks at `t`. Drift is the analyzed value
times t0/t. Interactive wall shear is the analyzed ratio times t0/t.
"""
function wall_thickness_passes(t, t0, trials, drift;
                               SDS::Real=0.0,
                               interactive_ratio::Real=0.0)
    t_m = ustrip(u"m", t)
    t0_m = ustrip(u"m", t0)
    scale = t0_m / t_m
    interactive_ratio * scale <= 1.0 + 1e-9 || return false
    for c in drift
        c.drift_m * scale <= c.allowable_m + 1e-12 || return false
    end
    for trial in trials
        actions = CombinedWallAction[
            scale_wall_action(a, t, t0, trial.N_self0, SDS) for a in trial.actions]
        wall = trial.wall
        t_save = wall.thickness
        ρl_save = wall.ρl
        ρt_save = wall.ρt
        wall.thickness = convert(typeof(t_save), t)
        wall.ρl = 0.0025
        wall.ρt = 0.0025
        passed = false
        try
            ρt_strength = select_ordinary_wall_reinforcement!(
                wall, actions, trial.material;
                hw=trial.hw, lw=trial.lw, Moop=trial.Moop,
                slab_basis=trial.slab_basis)
            shear_ok = true
            if trial.shear !== nothing
                terms = _trial_shear_terms(trial)
                _raise_for_special_shear!(wall, terms, actions, trial.material)
                Vn = _special_vn(terms, wall, wall.ρt, trial.material)
                φVn = trial.shear.φ * Vn
                shear_ok = all(k -> special_shear_demand(terms, actions[k], k) <= φVn * (1 + 1e-9),
                               eachindex(actions))
                ρt_strength === nothing || (ρt_strength = max(Float64(ρt_strength), wall.ρt))
            end
            records = check_ordinary_wall(
                wall, actions;
                material=trial.material, wall_index=1, case=:jump,
                boundary=trial.boundary, assembly=trial.assembly,
                hw=trial.hw, ρt_strength=ρt_strength, lw=trial.lw,
                Moop=trial.Moop, slab_basis=trial.slab_basis)
            passed = shear_ok && all(r -> r.passed || _thickness_unresponsive(r.check), records)
        finally
            wall.thickness = t_save
            wall.ρl = ρl_save
            wall.ρt = ρt_save
        end
        passed || return false
    end
    return true
end

"""
    propose_wall_thickness(t0, trials, drift; SDS=0, result=nothing,
                           constraint=:soft, t_limit=WALL_THICKNESS_HARD_MAX) -> thickness

Thinnest inch above `t0` the proxy accepts, and not below what the failing
Table 11.3.1.1 and slenderness gates ask for.

`t_limit` is the thickness catalog. `:hard` errors when no thickness in it
passes, or when the geometric need is past it. `:soft` raises the limit by
[`WALL_THICKNESS_CATALOG_STEP`](@ref), warns, and tries again, up to
[`WALL_THICKNESS_CATALOG_TOP`](@ref).

When the self-weight scale does not apply, the frozen demand cannot be
moved. Only the geometric gates are then used: the return is the first
inch that meets them, or `t0` (no jump) when they already pass.
"""
function propose_wall_thickness(t0, trials, drift;
                                SDS::Real=0.0,
                                result::Union{Nothing, OrdinaryWallResult}=nothing,
                                constraint::Symbol=:soft,
                                t_limit=WALL_THICKNESS_HARD_MAX)
    t_geom = result === nothing ? t0 : _geometric_thickness_need(result, t0)
    t_need = t_geom
    if result !== nothing
        r_int = _linear_capacity_ratio(result, _INTERACTIVE_WALL_SHEAR)
        t_need = max(t_need, t0 * max(r_int, _drift_scale(result.drift), 1.0))
        for trial in trials
            demand = _trial_shear_demand(trial)
            demand <= 0 && continue
            fc = ustrip(u"Pa", trial.material.concrete.fc′)
            fyt = ustrip(u"Pa", trial.material.transverse.Fy)
            λ = trial.material.concrete.λ
            hw_cap = trial.shear === nothing ? ustrip(u"m", trial.hw) : trial.shear.hw_m
            cap = StructuralSizer.wall_shear_capacity_si(
                fc, fyt, ustrip(u"m", trial.lw), ustrip(u"m", t0), 0.0,
                hw_cap; λ=λ)
            ϕ = trial.shear === nothing ? WALL_PHI_SHEAR : trial.shear.φ
            ϕmax = ϕ * cap.Vn_max
            ϕmax > 0 || continue
            t_need = max(t_need, t0 * demand / ϕmax)
        end
    end
    # The grid is whole inches. A need that falls between inches has to
    # include the next inch, or the search stops on a thickness that is
    # still short of φVn.
    _require_catalog_constraint(constraint)
    limit = t_limit
    ask = max(t_need, t_geom)
    if ustrip(u"m", ask) > ustrip(u"m", limit) + 1e-4
        limit = _raise_catalog_limit(ask, limit; constraint)
    end
    interactive_ratio = result === nothing ? 0.0 :
        _linear_capacity_ratio(result, _INTERACTIVE_WALL_SHEAR)
    while true
        found = _first_passing_thickness(
            t0, trials, drift, t_geom, limit; SDS, interactive_ratio)
        found !== nothing && return found
        limit = _bump_wall_catalog(limit; constraint)
    end
end

"""
Thinnest inch on the grid up to `limit` that the proxy accepts.

`nothing` when the grid has a candidate and none of them pass. `t0` when
there is nothing thicker to try and the geometric gate does not ask for
more, or when the self-weight scale does not apply and the gate already
passes.
"""
function _first_passing_thickness(t0, trials, drift, t_geom, limit; SDS, interactive_ratio)
    candidates = wall_thickness_candidates(t0; t_max=limit, t_hard=limit)
    t_geom_m = ustrip(u"m", t_geom) - 1e-9
    filter!(t -> ustrip(u"m", t) >= t_geom_m, candidates)
    if isempty(candidates)
        return ustrip(u"m", t_geom) > ustrip(u"m", t0) + 1e-4 ? nothing : t0
    end
    if !wall_thickness_scale_applies(t0, trials)
        return ustrip(u"m", t_geom) > ustrip(u"m", t0) + 1e-9 ? first(candidates) : t0
    end
    for t in candidates
        wall_thickness_passes(t, t0, trials, drift; SDS, interactive_ratio) && return t
    end
    return nothing
end

"True when `proposed` is more than 0.1 mm thicker than `current`."
function _thickness_grows(current, proposed)
    return ustrip(u"m", proposed) > ustrip(u"m", current) + 1e-4
end

"The shared length, or `nothing` when `targets` differ by more than 1 mm."
function _uniform_length(targets)
    isempty(targets) && return nothing
    t0 = ustrip(u"m", first(targets))
    for t in targets
        abs(ustrip(u"m", t) - t0) <= 1e-3 || return nothing
    end
    return first(targets)
end

"""
True when this group has to get thicker.

Drift and interactive story shear are building results. They count for
every group, because both scale only when every wall thickens together.
Any other failing check counts only for the walls in `indices`.
"""
function _group_needs_thickness(result::OrdinaryWallResult, indices)
    any(c -> !c.passes, result.drift) && return true
    for records in values(result.checks)
        for r in records
            r.check == _INTERACTIVE_WALL_SHEAR || continue
            r.passed && continue
            return true
        end
    end
    keep = Set(indices)
    for (i, records) in result.checks
        i in keep || continue
        for r in records
            r.passed && continue
            r.check == _INTERACTIVE_WALL_SHEAR && continue
            _thickness_unresponsive(r.check) && continue
            return true
        end
    end
    return false
end

"""
The result [`propose_wall_thickness`](@ref) should see for one group.

Drift stays. Interactive story shear stays, including a record filed on a
wall outside the group. Every other check is limited to `indices`.
"""
function _result_for_group(result::OrdinaryWallResult, indices)
    keep = Set(indices)
    checks = Dict{Int, Vector{WallCheckRecord}}()
    for (i, records) in result.checks
        kept = [r for r in records if i in keep || r.check == _INTERACTIVE_WALL_SHEAR]
        isempty(kept) && continue
        checks[i] = kept
    end
    boundary = Dict{Int, SpecialBoundaryDecision}(
        i => d for (i, d) in result.boundary if i in keep)
    opening_edges = Dict{Int, Vector{SpecialBoundaryDecision}}(
        i => d for (i, d) in result.opening_edges if i in keep)
    return OrdinaryWallResult(
        checks, result.drift, result.max_story_stability, result.pdelta_multipliers,
        result.gravity_shares, result.interactive_shear, result.frame_members,
        result.type5_horizontal_irregularity, result.nonparallel_elements,
        result.orthogonal_combination, boundary, opening_edges,
        Dict(i => b for (i, b) in result.end_bars if i in keep),
        result.induced)
end

"Trials whose wall is one of `indices`, in the order `trials` already has."
function _trials_for_group(walls, trials, indices)
    keep = Set(objectid(walls[i]) for i in indices)
    return [t for t in trials if objectid(t.wall) in keep]
end

"""
    propose_wall_thicknesses(walls, trials, result; grouping=:all, SDS=0) -> Vector

One thickness per wall, read from this analysis.

A group that passes keeps its thickness. A group that fails is
[`propose_wall_thickness`](@ref) on that group's trials and checks. The
group that contains every wall uses `trials` and `result` unchanged, so
`:all` is the single-thickness proposal. A pier whose special-boundary
decision records a web shortfall then rises on its own, even when its
group passed.

Drift and interactive story shear are handed to every group. When they
govern and the walls start at one thickness, every grouping proposes that
same thickness. A local check moves only the groups that contain it. The
thickest proposal is the `:all` proposal when a thicker wall is not a
worse wall.

`:all` that is already mixed returns the thicknesses it was given. Any
other group that is already mixed throws: that grouping asked for one
thickness there.
"""
function propose_wall_thicknesses(walls, trials, result::OrdinaryWallResult;
                                  grouping::Symbol=:all, SDS::Real=0.0,
                                  constraint::Symbol=:soft,
                                  t_limit=WALL_THICKNESS_HARD_MAX)
    targets = [w.thickness for w in walls]
    n = length(walls)
    for indices in _thickness_group_members(walls; grouping)
        _group_needs_thickness(result, indices) || continue
        t0 = shared_wall_thickness(walls[indices])
        if t0 === nothing
            grouping === :all && continue
            throw(ArgumentError(
                "wall thickness grouping :$grouping has more than one thickness " *
                "in one group (walls $(join(indices, ", ")))"))
        end
        whole = length(indices) == n
        sub_trials = whole ? trials : _trials_for_group(walls, trials, indices)
        sub = whole ? result : _result_for_group(result, indices)
        t1 = propose_wall_thickness(t0, sub_trials, sub.drift; SDS, result=sub,
                                   constraint, t_limit)
        for i in indices
            targets[i] = convert(typeof(targets[i]), t1)
        end
    end
    # ACI 318-19 §18.10.6.4(b) (corpus: aci-318-19, page 327): where an
    # element is required, the compression-zone width is at least hu/16.
    # §18.10.6.4(c)'s 12 in. floor is already inside that width, and only
    # when a single critical section was stated. The shortfall is the web's.
    # This pier grows to the next inch that covers it. Another pier, and a
    # row with no decision, stays at the thickness the group proposed.
    _raise_boundary_thickness!(targets, walls, result; constraint, t_limit)
    return targets
end

"""
Raise a pier to the next inch that covers its §18.10.6.4 web shortfall.

A missing decision, a shortfall of `nothing`, or a shortfall the present
thickness already covers leaves that pier. The inch is the jump's grid.
`:hard` errors when that inch is past `t_limit`. `:soft` raises the limit
until the inch is inside it, and errors past the catalog top.
"""
function _raise_boundary_thickness!(targets, walls, result::OrdinaryWallResult;
                                   constraint::Symbol=:soft,
                                   t_limit=WALL_THICKNESS_HARD_MAX)
    inc = ustrip(u"m", WALL_THICKNESS_INCREMENT)
    limit = t_limit
    gaps = Dict{Int, Float64}()
    for (i, decision) in result.boundary
        _note_boundary_gap!(gaps, i, decision)
    end
    for (i, edges) in result.opening_edges
        for decision in edges
            _note_boundary_gap!(gaps, i, decision)
        end
    end
    for (i, gap) in gaps
        gap > 1e-4 || continue
        need = ustrip(u"m", walls[i].thickness) + gap
        if need > ustrip(u"m", limit) + 1e-4
            limit = _raise_catalog_limit(need * u"m", limit; constraint)
        end
        snapped = min(ustrip(u"m", limit), ceil((need - 1e-9) / inc) * inc)
        snapped > ustrip(u"m", targets[i]) + 1e-4 || continue
        targets[i] = convert(typeof(targets[i]), snapped * u"m")
    end
    return targets
end

"Keep the larger web shortfall when a wall has more than one."
function _note_boundary_gap!(gaps, i, decision)
    gap = decision.thickness_shortfall_m
    gap === nothing && return gaps
    gaps[i] = max(get(gaps, i, 0.0), gap)
    return gaps
end

"""
    apply_wall_thickness!(struc, params, t)
    apply_wall_thickness!(struc, params, targets)

`t` sets every wall. `targets` is one thickness per wall; a wall that is
not growing keeps its reinforcement. A grown wall's ρ returns to 0.0025.
When the targets agree, this is the single-thickness jump. The building
is meshed once, and `params.wall_thickness` is set when the walls then
share one thickness.
"""
function apply_wall_thickness!(struc::BuildingStructure, params::DesignParameters, t;
                               tc = nothing)
    t_m = uconvert(u"m", t)
    for w in struc.walls
        w.thickness = convert(typeof(w.thickness), t_m)
        w.ρl = 0.0025
        w.ρt = 0.0025
    end
    params.wall_thickness = t_m
    update_analysis!(struc, :geometry; params, tc)
    return t_m
end

function apply_wall_thickness!(struc::BuildingStructure, params::DesignParameters,
                               targets::AbstractVector; tc = nothing)
    n = length(struc.walls)
    length(targets) == n || throw(ArgumentError(
        "wall thickness jump: $(length(targets)) thicknesses for $n walls"))
    any(_thickness_grows(w.thickness, t) for (w, t) in zip(struc.walls, targets)) ||
        return targets
    # One target means every group landed on the same inch. Each group
    # proposes at least its own thickness, so that inch is not a reduction.
    uniform = _uniform_length(targets)
    if uniform !== nothing
        apply_wall_thickness!(struc, params, uniform; tc)
        return targets
    end
    for (w, t) in zip(struc.walls, targets)
        _thickness_grows(w.thickness, t) || continue
        t_m = uconvert(u"m", t)
        w.thickness = convert(typeof(w.thickness), t_m)
        w.ρl = 0.0025
        w.ρt = 0.0025
    end
    shared = shared_wall_thickness(struc.walls)
    shared === nothing || (params.wall_thickness = uconvert(u"m", shared))
    update_analysis!(struc, :geometry; params, tc)
    return targets
end

function _trial_for_pier(struc, wall_index, grown, lw, Moop, material, boundary, assembly,
                        terms=nothing; slab_basis=nothing)
    wall = struc.walls[wall_index]
    N_self = pier_self_weight_N(wall, wall.thickness, lw, material.concrete.ρ)
    return WallThicknessTrial(wall, grown, N_self, lw, Moop, material,
                              _stacked_wall_height(wall), assembly, boundary,
                              _thickness_shear(terms, wall, material), slab_basis)
end

"The analyzed special-shear factors, or `nothing` for an ordinary pier."
function _thickness_shear(terms, wall, material)
    terms === nothing && return nothing
    φ = terms.φ_fixed
    if φ === nothing
        φ = special_shear_phi(terms, _special_vn(terms, wall, wall.ρt, material))
    end
    return WallThicknessShear(terms.Ωv, terms.ωv, φ, terms.hw_m, terms.hwcs_m,
                              terms.Ωv_cases)
end

"""
Largest shear the jump sizes for: Ve on an earthquake combination, |V|
otherwise. Each action takes its own case's Ωv.
"""
function _trial_shear_demand(trial)
    trial.shear === nothing && return maximum(a -> abs(a.V), trial.actions; init = 0.0)
    terms = _trial_shear_terms(trial)
    _require_case_count(terms, trial.actions)
    return maximum(k -> special_shear_demand(terms, trial.actions[k], k),
                   eachindex(trial.actions); init = 0.0)
end

"Frozen Ωv, ωv, and φ, with this pier's length, for one thickness trial."
function _trial_shear_terms(trial)
    sh = trial.shear
    return SpecialShearTerms(sh.Ωv, sh.ωv, false, sh.φ, Inf,
                            sh.hw_m, sh.hwcs_m, ustrip(u"m", trial.lw), sh.Ωv_cases)
end
