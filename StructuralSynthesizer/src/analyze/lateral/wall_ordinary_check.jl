# Ordinary-wall checks for one pier.
#
# The numerical checks already live in StructuralSizer. This file only maps one
# pier's concurrent (N, M, V) onto those functions and keeps the record.
# Thickness and reinforcement are the wall's given values. A joined leg is
# checked on the clear length the caller passes.

"""
    check_ordinary_wall(wall, actions; material, wall_index, case, boundary,
                        assembly=nothing, hw=nothing, ρt_strength=nothing,
                        lw=nothing) -> Vector{WallCheckRecord}

Run the ordinary checks on one pier for each strength combination in
`actions`. Each action is one concurrent `(N, M, V)`.

The checks are the existing ones:

- in-plane shear, `check_wall_inplane_shear` (ACI 318-19 §11.5.4.3)
- minimum reinforcement, `check_wall_min_reinforcement` (ACI 318-19 §11.6.2)
- in-plane axial-flexure, `check_wall_inplane_flexure` (ACI 318-19 §22.2 and §22.4.2.1)
- empirical bearing, `check_wall_bearing_empirical` (ACI 318-19 §11.5.3)

Out-of-plane shear and moment are reported on a joined leg and are not a
strength check. An isolated pier does not record them.

`material` is a `ReinforcedConcreteMaterial`. A plain concrete is refused:
this check does not assume a rebar grade. `boundary` selects the bearing-wall
`k` (`:restrained`, `:pinned`, or `:cantilever`). `case` names the basic case
the combination was built from.

`hw`, when passed, is the total wall height used by the shear and minimum-
reinforcement checks. When omitted, the height is this pier plus every
`wall_above`. The bearing unsupported height stays this story's height: the
floors brace the pier, and `boundary` supplies `k`.

The empirical method's eccentricity is out of plane (the resultant within the
middle third of the thickness, §11.5.3.1). `Moop` is the slab's factored
moment about the wall's weak axis. `e = Moop / N`. Inside the middle third
the empirical method is the axial check. Outside it, that method does not
apply and the pier is checked for the magnified out-of-plane moment
(§6.6.4.5 and §22.2). A tensile axial force makes the bearing method
inapplicable; that result is recorded as a failure.

`ρt_strength`, when passed, is the transverse ratio required for shear
strength. §11.6.2(a) says the vertical minimum need not exceed it. The
default leaves the existing equation unchanged.

`plan_axis` only sets the `direction` label: `:X`, `:Y`, or `:skew` for a
pier on neither plan axis. The checks use the pier's own in-plane axes.

`lw`, when passed, is that clear length. A joined `assembly` without it
throws: the centerline would count the corner twice. A failing check is
recorded. The wall is not resized.
"""
function check_ordinary_wall(wall::Wall, actions::AbstractVector{CombinedWallAction};
                             material,
                             wall_index::Int,
                             case::Symbol,
                             boundary::Symbol,
                             assembly::Union{Nothing,WallAssembly}=nothing,
                             hw::Union{Nothing,Unitful.Length}=nothing,
                             ρt_strength::Union{Nothing,Real}=nothing,
                             plan_axis::NTuple{2, Float64}=(1.0, 0.0),
                             lw::Union{Nothing,Unitful.Length}=nothing,
                             Moop::Unitful.Quantity=0.0u"N*m",
                             slab_basis=nothing,
                             ends=nothing)
    material isa ReinforcedConcreteMaterial || throw(ArgumentError(
        "ordinary wall check: material must be a ReinforcedConcreteMaterial " *
        "(concrete plus rebar). A plain concrete has no fy or fyt, and this " *
        "check does not assume a grade."))
    isempty(actions) && throw(ArgumentError(
        "ordinary wall check: there is no strength combination to check."))
    if assembly !== nothing && assembly.joined && lw === nothing
        throw(ArgumentError(
            "ordinary wall check: wall $wall_index is part of a joined assembly. " *
            "Pass lw from joined_clear_length. The centerline length counts " *
            "the corner twice."))
    end
    _require_wall_concrete(wall, material)

    lw_m = lw === nothing ? wall_length(wall) : ustrip(u"m", lw)
    lw = lw_m * u"m"
    lw_m > 0 || throw(ArgumentError("ordinary wall check: the pier has no length."))
    direction = _pier_axis_direction(wall, plan_axis)
    section = WallSection(lw, wall.thickness; ρl=wall.ρl, ρt=wall.ρt)
    height = hw === nothing ? _stacked_wall_height(wall) : hw
    ustrip(u"m", height) > 0 || throw(ArgumentError(
        "ordinary wall check: the wall height must be positive."))
    story_height = wall.base.L
    ustrip(u"m", story_height) > 0 || throw(ArgumentError(
        "ordinary wall check: the story height must be positive."))

    records = WallCheckRecord[]
    for action in actions
        # Shear strength is unsigned. The sign of V is the pier tangent.
        shear = check_wall_inplane_shear(section, material, abs(action.V), height)
        push!(records, _ordinary_record(wall_index, wall.story, direction, case, action, shear))
        for reinf in check_wall_min_reinforcement(section; hw=height, ρt_strength)
            push!(records, _ordinary_record(wall_index, wall.story, direction, case, action, reinf))
        end
        flexure = ends === nothing ? check_wall_inplane_flexure(section, material, action.N, action.M) :
                  check_wall_end_bar_flexure(lw, wall.thickness, wall.ρl,
                                            ends.area_m2 * u"m^2", ends.inset_m * u"m",
                                            material, action.N, action.M)
        push!(records, _ordinary_record(wall_index, wall.story, direction, case, action, flexure))
        moment = _action_slab_moment(Moop, action, slab_basis)
        e = _out_of_plane_eccentricity(action.N, moment)
        # Inside h/6 the simplified method applies with this eccentricity.
        # Outside it, §11.5.3.1 does not, and the magnified weak-axis moment does.
        if e <= section.t / 6
            bearing = check_wall_bearing_empirical(section, material.concrete, action.N;
                                                   e=e, lc=story_height, lu=lw,
                                                   boundary=boundary, foundation=false)
            push!(records, _ordinary_record(wall_index, wall.story, direction, case, action, bearing))
        else
            push!(records, _ordinary_record(
                wall_index, wall.story, direction, case, action,
                _out_of_plane_strength(section, material, action.N, moment, story_height)))
        end
        if assembly !== nothing && assembly.joined
            # Reported only. ratio 0 keeps a passing design from treating
            # this as the governing strength check.
            push!(records, WallCheckRecord(
                wall_index, wall.story, direction, case,
                action.combination, action.alternative,
                "out-of-plane shear (reported)", true, 0.0,
                abs(action.Vo), 0.0,
                "reported; out-of-plane design is not this check"))
            push!(records, WallCheckRecord(
                wall_index, wall.story, direction, case,
                action.combination, action.alternative,
                "out-of-plane moment (reported)", true, 0.0,
                abs(action.Mo), 0.0,
                "reported; out-of-plane design is not this check"))
        end
    end
    return records
end

"""
Slab moment that belongs with this action.

`Moop` is the envelope the slab stored, over `1.4D` and `1.2D + 1.6L`.
`basis` comes from [`_governing_slab_basis`](@ref). The scale is this
combination's slab moment over that envelope, and it is not allowed to
exceed 1.

With `basis.faces`, each wall face's moment is `max(αD·D + αL·L, 0)` from
its own dead and live parts, and the combination's slab moment is the
largest over the faces. Otherwise the scale is this combination's gravity
pressure on the governing slab over the larger of `1.4 qD` and
`1.2 qD + 1.6 qL`.

A floor's live factor is the combination's `L`, and the `:W` reading of
combination 3 drops floor live. A roof's live factor is the combination's
factor on `:Lr`. Wind and `Eh` do not scale the slab moment.

No basis leaves the envelope on every action.
"""
function _action_slab_moment(Moop, action, basis)
    basis === nothing && return Moop
    combo = nothing
    for c in asce7_strength_combinations
        c.name === action.combination || continue
        combo = c
        break
    end
    combo === nothing && return Moop
    # Combination 3's :W reading keeps the roof live and drops floor live.
    live_factor(roof) = roof ? combo.Lr : (action.alternative === :W ? 0.0 : combo.L)
    faces = hasproperty(basis, :faces) ? basis.faces : nothing
    if faces !== nothing && !isempty(faces)
        face_moment(f, αD, αL) = max(αD * f.D + αL * f.L, 0.0)
        env = maximum(f -> max(face_moment(f, 1.4, 0.0), face_moment(f, 1.2, 1.6)), faces)
        env > 0 || return Moop
        m = maximum(f -> face_moment(f, combo.D, live_factor(f.roof)), faces)
        return Moop * min(m / env, 1.0)
    end
    q = combo.D * basis.qD + live_factor(basis.roof) * basis.qL
    q_gov = max(1.4 * basis.qD, 1.2 * basis.qD + 1.6 * basis.qL)
    q_gov > 1.0 || return Moop
    return Moop * min(q / q_gov, 1.0)
end

"""e = M/N. No moment is concentric. Moment with no compression is outside the wall."""
function _out_of_plane_eccentricity(N, Moop)
    M = abs(Moop)
    M <= 1.0u"N*m" && return 0.0u"m"
    N_N = N isa Unitful.Quantity ? ustrip(u"N", N) : Float64(N)
    N_N > 1.0 || return M / 1.0u"N"
    return M / (N_N * u"N")
end

"""
Magnified weak-axis strength. Instability of §6.6.4.5.2 is a failure.
Ig is the pier bent through its thickness.
"""
function _out_of_plane_strength(section::WallSection, material, N, Moop, lu)
    lw = ustrip(u"m", section.lw)
    t = ustrip(u"m", section.t)
    Ig = lw * t^3 / 12
    fc = ustrip(u"Pa", material.concrete.fc′)
    Ec = StructuralSizer.wall_modulus_si(fc)
    Pu = N isa Unitful.Quantity ? ustrip(u"N", N) : Float64(N)
    M = ustrip(u"N*m", Moop)
    mag = StructuralSizer.nonsway_slenderness_moment(Pu, M, Ec, Ig, ustrip(u"m", lu))
    if !mag.stable
        return CheckResult("out-of-plane slenderness: Pu ≥ 0.75 Pc", false,
                           Inf, Pu, 0.75 * mag.Pc, "ACI 318-19 6.6.4.5.2")
    end
    return StructuralSizer.check_wall_out_of_plane_axial_flexure(
        section, material, N, mag.Mc * u"N*m")
end

function _ordinary_record(wall_index, story, direction, case, action, result::CheckResult)
    return WallCheckRecord(wall_index, story, direction, case,
                           action.combination, action.alternative,
                           result.name, result.passed, result.ratio,
                           result.demand, result.capacity, result.code_clause)
end

"""
`:X` or `:Y` when the pier tangent is parallel to the first or second plan
axis, otherwise `:skew`. This is the label on the record. The in-plane
checks themselves use the pier's own tangent at any angle.
"""
function _pier_axis_direction(wall, plan_axis::NTuple{2, Float64}=(1.0, 0.0))
    tx, ty, _, _ = _pier_plan_axes(wall)
    return _plan_vector_direction((tx, ty), plan_axis)
end

"""`|cos α|` between the pier tangent and plan axis `:X` or `:Y`."""
function _pier_axis_cosine(wall, plan_axis::NTuple{2, Float64}, direction::Symbol)
    tx, ty, _, _ = _pier_plan_axes(wall)
    e = plan_axis_vector(plan_axis, direction === :X ? :x : direction === :Y ? :y :
        throw(ArgumentError("wall axis direction must be :X or :Y, got :$direction.")))
    return abs(tx * e[1] + ty * e[2])
end

"""This pier plus every wall stacked above it. A cycle is refused."""
function _stacked_wall_height(wall)
    h = wall.base.L
    seen = Set{UInt}()
    above = wall.wall_above
    while above !== nothing
        id = objectid(above)
        id in seen && throw(ArgumentError(
            "ordinary wall check: wall_above forms a cycle."))
        push!(seen, id)
        h += above.base.L
        above = above.wall_above
    end
    return h
end

function _require_wall_concrete(wall, material)
    wall.concrete === nothing && return nothing
    fc_wall = ustrip(u"Pa", wall.concrete.fc′)
    fc_mat = ustrip(u"Pa", material.concrete.fc′)
    isapprox(fc_wall, fc_mat; rtol=1e-6) || throw(ArgumentError(
        "ordinary wall check: wall.concrete f'c does not match the " *
        "reinforced-concrete material."))
    return nothing
end

# Search grid for ordinary-wall reinforcement ratios. Not an ACI maximum.
# 0.0025 is §11.6.2. Steps of 0.0005 run through 0.0200.
const ORDINARY_WALL_RHO_GRID = collect(0.0025:0.0005:0.0200)

"""
Transverse ratio that makes φVn equal `Vu`, before the 0.0025 floor.

`nothing` when `Vu` is above the §11.5.4.2 cap, so no ratio works.
Zero when the concrete term alone covers `Vu`.

# Citation
ACI 318-19 Eq. (11.5.4.3) (corpus: aci-318-19, PDF page 172):
`Vn = (αc·λ·√f'c + ρt·fyt)·Acv`, with `Vn` limited by §11.5.4.2.
"""
function _rho_t_for_shear_strength(fc, fyt, λ, lw, t, hw, Vu)
    Vu = abs(Float64(Vu))
    cap0 = wall_shear_capacity_si(fc, fyt, lw, t, 0.0, hw; λ=λ)
    # ACI 318-19 §11.5.4.2. φ = 0.75, §21.2.1.
    ϕmax = WALL_PHI_SHEAR * cap0.Vn_max
    Vu <= cap0.ϕVn && return 0.0
    Vu > ϕmax + 1.0 && return nothing
    # Eq. (11.5.4.3) is linear in ρt below the cap. The probe sits below it.
    ρ_probe = 1e-4
    cap_p = wall_shear_capacity_si(fc, fyt, lw, t, ρ_probe, hw; λ=λ)
    slope = (cap_p.ϕVn - cap0.ϕVn) / ρ_probe
    slope > 0 || return nothing
    return max(0.0, (Vu - cap0.ϕVn) / slope)
end

"""Next grid ratio at or above `target`, or the caller's ratio when it already is."""
function _rho_on_grid(required::Float64, floor::Float64)
    target = max(required, 0.0025)
    floor >= target - 1e-12 && return floor
    for r in ORDINARY_WALL_RHO_GRID
        r >= target - 1e-12 && return r
    end
    return nothing
end

"""
Grid ratio at or above `chosen` whose shear check passes.

The solved ratio can sit a rounding step under the grid point that was
selected. The next grid value is used only when that point still fails
`check_wall_inplane_shear`.
"""
function _rho_t_covering_shear(chosen::Float64, material, lw, t, hw, Vu)
    function covers(ρ)
        section = WallSection(lw * u"m", t * u"m"; ρl=0.0025, ρt=ρ)
        return check_wall_inplane_shear(section, material, Vu, hw).passed
    end
    covers(chosen) && return chosen
    for r in ORDINARY_WALL_RHO_GRID
        r > chosen + 1e-12 || continue
        covers(r) && return r
    end
    return max(chosen, ORDINARY_WALL_RHO_GRID[end])
end

"""
Vertical-ratio floor from §11.6.2(a).

The equation is `0.0025 + 0.5·(2.5 − hw/lw)·(ρt − 0.0025)`, and not less
than 0.0025. It need not exceed `ρt_strength`. A caller ratio above that
floor is kept.
"""
function _rho_l_floor(ρt::Float64, ρt_strength, hw, lw, caller::Float64)
    hwlw = lw > 0 ? hw / lw : Inf
    # ACI 318-19 Eq. (11.6.2) (corpus: aci-318-19, PDF page 173).
    formula = max(0.0025, 0.0025 + 0.5 * (2.5 - hwlw) * (ρt - 0.0025))
    if ρt_strength !== nothing
        formula = min(formula, max(Float64(ρt_strength), 0.0025))
    end
    return max(caller, formula)
end

function _rho_l_candidates(floor::Float64)
    out = Float64[floor]
    for r in ORDINARY_WALL_RHO_GRID
        r > floor + 1e-12 && push!(out, r)
    end
    return out
end

"Move the failing action to the front so the next ratio rejects it first."
function _promote_action!(actions, i::Int)
    i == 1 && return actions
    failed = actions[i]
    deleteat!(actions, i)
    pushfirst!(actions, failed)
    return actions
end

"""
True when every action's axial-flexure check passes at `ρl`.

The closed form screens each action. The strain-compatibility check runs
only after that screen passes, because the recorded check uses the lesser
of the two capacities.
"""
function _flexure_passes!(lw, t, ρl, material, actions)
    fc = ustrip(u"Pa", material.concrete.fc′)
    fy = ustrip(u"Pa", material.rebar.Fy)
    Es = ustrip(u"Pa", material.rebar.E)
    section = WallSection(lw * u"m", t * u"m"; ρl=ρl, ρt=0.0025)
    screened = Int[]
    for i in eachindex(actions)
        Nu = Float64(actions[i].N)
        Mu = abs(Float64(actions[i].M))
        ax = wall_pure_axial_capacity_si(fc, fy, lw, t, ρl)
        # ACI 318-19 §22.4.2.1, φ = 0.65 for non-spiral transverse steel.
        if Nu > 0.65 * ax.Pn_max
            _promote_action!(actions, i)
            return false
        end
        card = wall_axial_flexure_capacity_si(fc, fy, Es, lw, t, ρl, Nu)
        if Mu > max(card.φMn, 0.0)
            _promote_action!(actions, i)
            return false
        end
        push!(screened, i)
    end
    for i in screened
        a = actions[i]
        chk = check_wall_inplane_flexure(section, material, a.N, a.M)
        chk.passed && continue
        _promote_action!(actions, i)
        return false
    end
    return true
end

function _out_of_plane_passes(lw, t, ρl, ρt, material, actions, Moop, hw, basis=nothing)
    ustrip(u"N*m", Moop) <= 1.0 && return true
    section = WallSection(lw * u"m", t * u"m"; ρl=ρl, ρt=ρt)
    for a in actions
        moment = _action_slab_moment(Moop, a, basis)
        ustrip(u"N*m", moment) <= 1.0 && continue
        _out_of_plane_eccentricity(a.N, moment) <= section.t / 6 && continue
        _out_of_plane_strength(section, material, a.N, moment, hw).passed || return false
    end
    return true
end

"""
    select_ordinary_wall_reinforcement!(wall, actions, material; hw, lw=nothing) -> ρt_strength

Set `wall.ρt`, then `wall.ρl`, to the lightest ratios that pass the pier's
strength checks at the current thickness. Thickness is unchanged. `lw`,
when passed, is the clear length of a joined leg. Otherwise the centerline
length is used.

`ρt` is solved from the largest `|V|` and rounded up on the grid from
0.0025. `ρl` then walks upward from the §11.6.2 floor and stops at the
first value that passes every action. Returns the transverse ratio
required for shear strength, or `nothing` when the shear is above the
§11.5.4.2 cap.

The ratios already on the wall are not a floor. A demand the grid cannot
cover leaves the wall at the top of the grid.
"""
function select_ordinary_wall_reinforcement!(wall::Wall, actions, material; hw::Unitful.Length,
                             lw::Union{Nothing,Unitful.Length}=nothing,
                             Moop::Unitful.Quantity=0.0u"N*m",
                             slab_basis=nothing,
                             ends=nothing)
    material isa ReinforcedConcreteMaterial || throw(ArgumentError(
        "ordinary wall reinforcement: material must be a ReinforcedConcreteMaterial."))
    isempty(actions) && throw(ArgumentError(
        "ordinary wall reinforcement: there is no strength combination."))
    lw = lw === nothing ? wall_length(wall) : ustrip(u"m", lw)
    lw > 0 || throw(ArgumentError("ordinary wall reinforcement: the pier has no length."))
    t = ustrip(u"m", wall.thickness)
    t > 0 || throw(ArgumentError("ordinary wall reinforcement: the thickness must be positive."))
    hw_m = ustrip(u"m", hw)
    hw_m > 0 || throw(ArgumentError("ordinary wall reinforcement: the wall height must be positive."))
    fc = ustrip(u"Pa", material.concrete.fc′)
    fyt = ustrip(u"Pa", material.transverse.Fy)
    λ = material.concrete.λ
    Vu = maximum(a -> abs(Float64(a.V)), actions)
    ρt_strength = _rho_t_for_shear_strength(fc, fyt, λ, lw, t, hw_m, Vu)
    required_t = ρt_strength === nothing ? Inf : ρt_strength
    # 0.0 is not a carried ratio. The grid floor is 0.0025 inside `_rho_on_grid`.
    chosen_t = _rho_on_grid(required_t, 0.0)
    if chosen_t === nothing
        chosen_t = ORDINARY_WALL_RHO_GRID[end]
    elseif ρt_strength !== nothing
        chosen_t = _rho_t_covering_shear(chosen_t, material, lw, t, hw, Vu)
    end
    wall.ρt = chosen_t
    floor_l = _rho_l_floor(chosen_t, ρt_strength, hw_m, lw, 0.0)
    order = collect(actions)
    chosen_l = floor_l
    for ρl in _rho_l_candidates(floor_l)
        chosen_l = ρl
        _flexure_passes!(lw, t, ρl, material, order) || continue
        _out_of_plane_passes(lw, t, ρl, wall.ρt, material, order, Moop, hw, slab_basis) && break
    end
    wall.ρl = chosen_l
    return ρt_strength
end
