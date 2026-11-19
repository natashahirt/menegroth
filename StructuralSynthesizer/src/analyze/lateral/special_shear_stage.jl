# Special structural wall shear on Table 12.2-1 rows A1 and B4.
#
# ACI 318-19 §18.10.3.1, Eq. (18.10.3.1) (corpus: aci-318-19, page 323,
# rendered): the wall is designed for Ve = Ωv ωv Vu, not above 3 Vu.
# Table 18.10.3.1.2 takes Ωv at the critical section, for the combination
# that gives the largest value. §18.10.3.1.3 gives ωv.
# ACI 318-19 §21.2.4.1 (page 398, rendered) applies through §21.2.4(b)
# (page 397): φ for shear is 0.60 when Vn is less than the shear at the
# nominal moment strength. §18.10.4.6 (page 325) exempts walls designed by
# §18.10.6.2. Vn is Eq. (18.10.4.1) (page 324) with αc from the greater of
# the line and pier ratios (§18.10.4.2). The Chapter 11 cap 8λ√f′c·Acv per
# pier is kept; it is not less than the §18.10.4.4 limits. §18.10.4.3 sets
# ρl ≥ ρt when hw/ℓw ≤ 2.
#
# User decisions (deci-5685ffd8): a continuous line takes Ωv once at its base
# and applies it to every pier of the line (Fig. R18.10.3.1). Any other pier
# uses its own bottom section, with hwcs the stack above it. The shear at Mn
# is Mn,max·|Vu|/|Mu|, largest over the earthquake combinations. Mpr takes
# 1.25 fy in tension and compression bars, with φ = 1.
#
# User decision 2026-11-13: Ωv is paired with Vu case by case. Each
# earthquake action k gets Ωv,k = max(Mpr,k/Mu,k, 1.5) from the same case at
# the critical section, and Ve,k = min(Ωv,k·ωv·Vu,k, 3Vu,k). A case with no
# moment there takes Ve,k = 3Vu,k. The largest Ωv,k is kept as `Ωv` for
# callers that do not walk the cases.

"Check name on the special shear records."
const SPECIAL_WALL_SHEAR_CHECK = "special-wall shear"

"""
The terms one pier's special shear check reads.

`Ωv` and `ωv` are the critical-section factors. `Ωv_cases[k]` is the Ωv of
action `k` of the pier's action list, from the same case; it is `Inf` for
an earthquake case with no moment at the critical section, so that case
takes the 3Vu cap. Empty `Ωv_cases` means `Ωv` applies to every action;
otherwise `Ωv` is their largest. `φ_fixed` is set when φ does not depend on
Vn: 0.75 on the displacement route, and 0.60 on a flanged segment whose
return bars were not given to the section. Otherwise φ is 0.60 below
`shear_at_Mn_N` and 0.75 at or above it. `hw_m` is the height αc reads.
`hwcs_m` and `lw_m` are this pier's own stack and length.
"""
struct SpecialShearTerms
    Ωv::Float64
    ωv::Float64
    from_line_base::Bool
    φ_fixed::Union{Nothing, Float64}
    shear_at_Mn_N::Float64
    hw_m::Float64
    hwcs_m::Float64
    lw_m::Float64
    Ωv_cases::Vector{Float64}
end

SpecialShearTerms(Ωv, ωv, from_line_base, φ_fixed, shear_at_Mn_N, hw_m, hwcs_m, lw_m) =
    SpecialShearTerms(Ωv, ωv, from_line_base, φ_fixed, shear_at_Mn_N, hw_m, hwcs_m, lw_m,
                      Float64[])

"""
Ωv of each action in `actions`, paired by position with `critical`, the same
cases at the critical section. Non-earthquake actions get 1.0; they are not
amplified. An earthquake case whose moment at the critical section is under
1 N·m gets `Inf`. Returns the vector and the number of earthquake cases with
a moment.

# Citation
ACI 318-19 Table 18.10.3.1.2 (corpus: aci-318-19, page 323).
"""
function _case_overstrength(actions, critical, hwcs, lw, t, Ast, fc, fy, Es, ends, who;
                           flange=nothing)
    length(actions) == length(critical) || throw(ArgumentError(
        "special shear: $who has $(length(actions)) actions and its critical section " *
        "has $(length(critical)); the cases cannot be paired."))
    out = ones(length(actions))
    n_eq = 0
    for k in eachindex(actions)
        a, c = actions[k], critical[k]
        (a.combination === c.combination && a.alternative === c.alternative) ||
            throw(ArgumentError(
                "special shear: $who action $k is $(a.combination)/$(a.alternative) " *
                "but the critical section has $(c.combination)/$(c.alternative)."))
        a.combination in _BOUNDARY_EARTHQUAKE || continue
        Mu = abs(c.M)
        if Mu <= 1.0
            out[k] = Inf
            continue
        end
        n_eq += 1
        # Mpr: 1.25 fy in every bar, φ = 1 (ACI 318-19 §2.3, user decision).
        # The moment sign puts the flange in compression or tension.
        probable = _wall_section_moment(fc, 1.25 * fy, Es, lw, t, Ast, c.N, ends;
                                       flange = flange, moment = c.M)
        probable.converged || throw(ArgumentError(
            "special shear: $who has no probable moment at axial $(c.N) N."))
        out[k] = special_wall_overstrength(hwcs * u"m", lw * u"m",
                                           probable.Mn * u"N*m", Mu * u"N*m").Ωv
    end
    return out, n_eq
end

"Ωv of action `k`: its own case when the terms carry cases, else `Ωv`."
_action_Ωv(terms::SpecialShearTerms, k::Int) =
    isempty(terms.Ωv_cases) ? terms.Ωv : terms.Ωv_cases[k]

"Throw unless the terms' cases line up with `actions`."
function _require_case_count(terms::SpecialShearTerms, actions)
    isempty(terms.Ωv_cases) || length(terms.Ωv_cases) == length(actions) ||
        throw(ArgumentError(
            "special shear: $(length(terms.Ωv_cases)) Ωv cases for $(length(actions)) actions."))
    return nothing
end

"""
    special_shear_terms(struc, wall_index, grown_by_wall, lw_by_wall, material;
                        displacement) -> SpecialShearTerms

Ωv, ωv, and the φ rule for one solid pier on a special row.

A continuous line reads its base pier. Its hwcs is the line height and `ns`
the number of piers on it. Any other pier reads itself, with hwcs the stack
from its bottom up. When hwcs/ℓw > 1.5, Ωv needs Mpr, and each of this
pier's actions takes the Ωv of its own case at that section. A flange
includes the return's vertical bars from [`_boundary_flange`](@ref) in that
Mpr, on the face the case's moment compresses. φ compares Vn with the shear
at the nominal moment of the same section. The displacement route still
takes φ = 0.75.

# Citation
ACI 318-19 §18.10.3.1.2–§18.10.3.1.3 (corpus: aci-318-19, page 323).
ACI 318-19 §21.2.4.1 (page 398) and §18.10.4.6 (page 325).
"""
function special_shear_terms(struc, wall_index::Int, grown_by_wall, lw_by_wall, material;
                             displacement::Bool, end_bars=nothing)
    walls = struc.walls
    wall = walls[wall_index]
    line = wall_line_members(wall, walls)
    continuous = line[1].story == 0 && all(isempty(w.openings) for w in line)
    hw_line = ustrip(u"m", _line_height(line))
    if continuous
        base_index = findfirst(w -> w === line[1], walls)
        haskey(grown_by_wall, base_index) || throw(ArgumentError(
            "special shear: wall $wall_index is on a continuous line whose base " *
            "pier $base_index has no actions."))
        hwcs = hw_line
        ns = length(line)
    else
        base_index = wall_index
        hwcs = ustrip(u"m", _stacked_wall_height(wall))
        ns = count(w -> w.story >= wall.story, line)
    end
    base = walls[base_index]
    lw_cs = ustrip(u"m", lw_by_wall[base_index])
    t_cs = ustrip(u"m", base.thickness)
    assembly_cs = _assembly_of(struc.wall_mesh, base_index)
    flange_cs = _boundary_flange(base, walls, base_index, assembly_cs, hwcs * u"m")
    fc = ustrip(u"Pa", material.concrete.fc′)
    fy = ustrip(u"Pa", material.rebar.Fy)
    Es = ustrip(u"Pa", material.rebar.E)
    # Table 18.10.3.1.2 (corpus: aci-318-19, page 323).
    Ωv = 1.0
    Ωv_cases = Float64[]
    if hwcs / lw_cs > 1.5
        Ast = base.ρl * lw_cs * t_cs
        # Every pier of a line has the same cases in the same order, so the
        # base pier's action k is this pier's case k at the critical section.
        # The added end bars, when the base pier has them, are in Mpr, and so
        # are the return's bars inside the effective flange.
        Ωv_cases, n_eq = _case_overstrength(
            grown_by_wall[wall_index], grown_by_wall[base_index], hwcs, lw_cs, t_cs, Ast,
            fc, fy, Es, _end_bars_at(end_bars, base_index), "wall $wall_index";
            flange = flange_cs)
        n_eq > 0 || throw(ArgumentError(
            "special shear: wall $base_index has no earthquake combination with a moment, " *
            "so Table 18.10.3.1.2 is not evaluated."))
        Ωv = maximum(Ωv_cases[k] for k in eachindex(Ωv_cases)
                     if grown_by_wall[wall_index][k].combination in _BOUNDARY_EARTHQUAKE)
    end
    # §18.10.3.1.3 (corpus: aci-318-19, page 323).
    ωv = special_wall_dynamic_amplification(hwcs * u"m", lw_cs * u"m", ns).ωv
    lw = ustrip(u"m", lw_by_wall[wall_index])
    hwcs_self = ustrip(u"m", _stacked_wall_height(wall))
    φ_fixed = nothing
    at_Mn = Inf
    if displacement
        # §18.10.4.6 (corpus: aci-318-19, page 325).
        φ_fixed = WALL_PHI_SHEAR
    else
        flange_self = wall_index == base_index ? flange_cs :
            _boundary_flange(wall, walls, wall_index,
                             _assembly_of(struc.wall_mesh, wall_index), hwcs_self * u"m")
        at_Mn = _shear_at_nominal_moment(wall, lw, grown_by_wall[wall_index], fc, fy, Es,
                                        _end_bars_at(end_bars, wall_index);
                                        flange = flange_self)
    end
    return SpecialShearTerms(Ωv, ωv, continuous, φ_fixed, at_Mn,
                             max(hw_line, hwcs_self), hwcs_self, lw, Ωv_cases)
end

"""
    segment_special_shear_terms(wall, actions, material, lw_seg, hw_seg,
                                lw_wall, hw_wall, hw_stack, ns; flanged=false,
                                critical=actions) -> SpecialShearTerms

Ve, ωv, and φ for one vertical segment of a pierced special wall.

Lengths are metres. `lw_seg` and `hw_seg` are the segment. `lw_wall` and
`hw_wall` are the entire wall. αc reads the greater of those two hw/ℓw
ratios, stored as `hw_m` on the segment length. Ωv and ωv read `hw_stack`
and `ns`. The full line height is a valid `hw_stack`: the segment sits at
or above the base, so that height is at least the height above the segment.
`hwcs_m` is the height that makes the §18.10.4.3 floor apply when either
ratio is 2 or less.

`critical[k]` is action `k`'s case at the segment's bottom section, where
its Ωv is read.

`segment_flange` is the return steel whose station along the web falls
inside this segment, on the segment's own rectangle (`bf` equals the
segment thickness). `extra_ast` is that steel when it fills the whole
segment and is smeared with the web bars. The gross pier's flange concrete
is not attached. `flanged = true` without that steel still throws when
`hw_stack/ℓw > 1.5`: Mpr is not evaluated on a flange that was left out.

# Citation
ACI 318-19 §18.10.3.1 (corpus: aci-318-19, page 323).
ACI 318-19 §18.10.4.2 (page 324): the hw/ℓw used for Vn of a segment is the
greater of the entire wall and the segment.
ACI 318-19 §18.10.4.3 (page 324).
"""
function segment_special_shear_terms(wall, actions, material,
                                    lw_seg::Real, hw_seg::Real,
                                    lw_wall::Real, hw_wall::Real,
                                    hw_stack::Real, ns::Real; flanged::Bool=false,
                                    critical=actions, segment_flange=nothing,
                                    extra_ast::Real=0.0)
    lw_seg > 0 || throw(ArgumentError("segment shear: the segment length must be positive."))
    hw_seg > 0 || throw(ArgumentError("segment shear: the segment height must be positive."))
    lw_wall > 0 || throw(ArgumentError("segment shear: the wall length must be positive."))
    hw_wall > 0 || throw(ArgumentError("segment shear: the wall height must be positive."))
    hw_stack > 0 || throw(ArgumentError("segment shear: the stack height must be positive."))
    ratio_seg = hw_seg / lw_seg
    ratio_wall = hw_wall / lw_wall
    # §18.10.4.2 (corpus: aci-318-19, page 324).
    hw_alpha = max(ratio_seg, ratio_wall) * lw_seg
    # §18.10.4.3 applies when hw/ℓw ≤ 2. Either ratio can be the one.
    hw_floor = min(ratio_seg, ratio_wall) * lw_seg
    t = ustrip(u"m", wall.thickness)
    fc = ustrip(u"Pa", material.concrete.fc′)
    fy = ustrip(u"Pa", material.rebar.Fy)
    Es = ustrip(u"Pa", material.rebar.E)
    Ωv = 1.0
    Ωv_cases = Float64[]
    bars_missing = flanged && segment_flange === nothing && extra_ast <= 0
    if hw_stack / lw_seg > 1.5
        bars_missing && throw(ArgumentError(
            "segment shear: a flanged segment has hwcs/ℓw > 1.5. " *
            "Table 18.10.3.1.2 needs Mpr, and the flange bars are not in the section."))
        Ast = wall.ρl * lw_seg * t + extra_ast
        Ωv_cases, n_eq = _case_overstrength(actions, critical, hw_stack, lw_seg, t, Ast,
                                            fc, fy, Es, nothing, "the segment";
                                            flange = segment_flange)
        n_eq > 0 || throw(ArgumentError(
            "segment shear: no earthquake combination has a moment, " *
            "so Table 18.10.3.1.2 is not evaluated."))
        Ωv = maximum(Ωv_cases[k] for k in eachindex(Ωv_cases)
                     if actions[k].combination in _BOUNDARY_EARTHQUAKE)
    end
    ωv = special_wall_dynamic_amplification(hw_stack * u"m", lw_seg * u"m", ns).ωv
    φ_fixed = nothing
    at_Mn = Inf
    if bars_missing
        φ_fixed = 0.60
    else
        at_Mn = _shear_at_nominal_moment(wall, Float64(lw_seg), actions, fc, fy, Es,
                                        nothing; flange = segment_flange, extra_ast)
    end
    return SpecialShearTerms(Ωv, ωv, false, φ_fixed, at_Mn,
                             hw_alpha, hw_floor, Float64(lw_seg), Ωv_cases)
end

"""
Raise this segment's steel until Ve is covered, and return the terms.

`ρl` feeds Mpr, so Ωv can move. The loop stops when the ratios stop.
`critical` is as in [`segment_special_shear_terms`](@ref).
"""
function design_segment_special_shear!(wall, actions, material,
                                      lw_seg, hw_seg, lw_wall, hw_wall, hw_stack, ns;
                                      flanged::Bool=false, critical=actions,
                                      segment_flange=nothing, extra_ast::Real=0.0)
    passes = 2 * length(ORDINARY_WALL_RHO_GRID) + 2
    terms = segment_special_shear_terms(wall, actions, material, lw_seg, hw_seg,
                                        lw_wall, hw_wall, hw_stack, ns;
                                        flanged, critical, segment_flange, extra_ast)
    for _ in 1:passes
        _raise_for_special_shear!(wall, terms, actions, material) || return terms
        terms = segment_special_shear_terms(wall, actions, material, lw_seg, hw_seg,
                                            lw_wall, hw_wall, hw_stack, ns;
                                            flanged, critical, segment_flange, extra_ast)
    end
    throw(ArgumentError(
        "segment shear: the steel was still moving after $passes passes."))
end

# `nothing`, or the end bars stored for one pier.
function _end_bars_at(end_bars, index)
    end_bars === nothing && return nothing
    return get(end_bars, index, nothing)
end

"""
Nominal moment at `fy`. A rectangle uses the web section, or the end-bar
section when `ends` is set. A flange uses the flanged section, with the
return's bars and, when present, the added end bars. `moment` picks the
compression face: positive compresses the positive end. `Mn` is nominal.
"""
function _wall_section_moment(fc, fy, Es, lw, t, Ast, Nu, ends; flange=nothing, moment=0.0)
    if flange === nothing
        ends === nothing && return wall_moment_capacity_at_axial_si(fc, fy, Es, lw, t, Ast, Nu)
        return wall_end_bar_capacity_si(fc, fy, Es, lw, t, Ast, ends.area_m2, ends.inset_m, Nu)
    end
    As_end = ends === nothing ? 0.0 : ends.area_m2
    inset = ends === nothing ? 0.0 : ends.inset_m
    return _flange_capacity_si(fc, fy, Es, lw, t, Ast, Nu, flange, moment;
                              As_end = As_end, inset = inset)
end

"""
Mn,max·|Vu|/|Mu| at the pier's bottom section, largest over the earthquake
combinations. Mn,max is the largest nominal moment over those combinations'
axials. On a flange, each axial is taken with that combination's moment
sign, and the maximum of those moments is Mn,max. A combination with no
moment returns `Inf`, which keeps φ = 0.60. End bars and the return's bars,
when this pier has them, are in that moment.

# Citation
ACI 318-19 §21.2.4.1 (corpus: aci-318-19, page 398).
"""
function _shear_at_nominal_moment(wall, lw::Float64, actions, fc, fy, Es, ends=nothing;
                                 flange=nothing, extra_ast::Real=0.0)
    t = ustrip(u"m", wall.thickness)
    Ast = wall.ρl * lw * t + extra_ast
    Mn_max = 0.0
    n_eq = 0
    for a in actions
        a.combination in _BOUNDARY_EARTHQUAKE || continue
        n_eq += 1
        nominal = _wall_section_moment(fc, fy, Es, lw, t, Ast, a.N, ends;
                                      flange = flange, moment = a.M)
        nominal.converged && (Mn_max = max(Mn_max, nominal.Mn))
    end
    n_eq > 0 || throw(ArgumentError(
        "special shear: a special pier has no earthquake combination."))
    largest = 0.0
    for a in actions
        a.combination in _BOUNDARY_EARTHQUAKE || continue
        Mu = abs(a.M)
        Mu > 1.0 || return Inf
        largest = max(largest, Mn_max * abs(a.V) / Mu)
    end
    return largest
end

"""
    special_shear_phi(terms, Vn_N) -> Float64

0.60 when `Vn` is less than the shear at Mn, otherwise 0.75. Equality is
0.75. A fixed φ in `terms` wins.

# Citation
ACI 318-19 §21.2.4.1 (corpus: aci-318-19, page 398).
"""
function special_shear_phi(terms::SpecialShearTerms, Vn_N::Real)
    terms.φ_fixed === nothing || return terms.φ_fixed
    return Vn_N < terms.shear_at_Mn_N ? 0.60 : WALL_PHI_SHEAR
end

"""
    special_shear_demand(terms, action, k=0) -> Float64

Shear demand of one action: Ve on an earthquake combination, |V| otherwise.
`k` is the action's position in the pier's action list; it selects that
case's Ωv. Without `k` the largest Ωv is used.

# Citation
ACI 318-19 Eq. (18.10.3.1) (corpus: aci-318-19, page 323).
"""
function special_shear_demand(terms::SpecialShearTerms, action, k::Int = 0)
    V = abs(Float64(action.V))
    action.combination in _BOUNDARY_EARTHQUAKE || return V
    V > 0 || return 0.0
    Ωv = k == 0 ? terms.Ωv : _action_Ωv(terms, k)
    return ustrip(u"N", special_wall_design_shear(V * u"N", Ωv, terms.ωv).Ve)
end

"Nominal Eq. (18.10.4.1) shear, capped at 8λ√f′c·Acv, in newtons."
function _special_vn(terms::SpecialShearTerms, wall, ρt, material)
    fc = ustrip(u"Pa", material.concrete.fc′)
    fyt = ustrip(u"Pa", material.transverse.Fy)
    t = ustrip(u"m", wall.thickness)
    return wall_shear_capacity_si(fc, fyt, terms.lw_m, t, ρt, terms.hw_m;
                                  λ = material.concrete.λ).Vn
end

"True when every action's demand is within φVn at `ρt`."
function _special_shear_covers(terms, wall, ρt, actions, material)
    _require_case_count(terms, actions)
    Vn = _special_vn(terms, wall, ρt, material)
    φVn = special_shear_phi(terms, Vn) * Vn
    return all(k -> special_shear_demand(terms, actions[k], k) <= φVn * (1 + 1e-9),
               eachindex(actions))
end

"""
Raise `ρt` to the lightest grid ratio that covers the special shear, then
raise `ρl` to the §11.6.2(a) and §18.10.4.3 floors and walk it up until
flexure passes. Returns true when either ratio moved.

A demand the grid cannot cover leaves `ρt` at the top of the grid; the
record then fails.
"""
function _raise_for_special_shear!(wall, terms, actions, material, ends=nothing)
    ρl0 = wall.ρl
    ρt0 = wall.ρt
    chosen = wall.ρt
    if !_special_shear_covers(terms, wall, chosen, actions, material)
        chosen = ORDINARY_WALL_RHO_GRID[end]
        for r in ORDINARY_WALL_RHO_GRID
            r > wall.ρt + 1e-12 || continue
            if _special_shear_covers(terms, wall, r, actions, material)
                chosen = r
                break
            end
        end
    end
    wall.ρt = max(wall.ρt, chosen)
    floor = _rho_l_floor(wall.ρt, wall.ρt, terms.hwcs_m, terms.lw_m, wall.ρl)
    # §18.10.4.3 (corpus: aci-318-19, page 324): hw/ℓw ≤ 2 needs ρl ≥ ρt.
    terms.hwcs_m / terms.lw_m <= 2.0 && (floor = max(floor, wall.ρt))
    if floor > wall.ρl + 1e-12
        t = ustrip(u"m", wall.thickness)
        order = collect(actions)
        picked = floor
        for ρl in _rho_l_candidates(floor)
            picked = ρl
            if ends === nothing
                _flexure_passes!(terms.lw_m, t, ρl, material, order) && break
            else
                _end_flexure_passes(terms.lw_m, t, ρl, material, order, ends) && break
            end
        end
        wall.ρl = picked
    end
    return wall.ρl > ρl0 + 1e-12 || wall.ρt > ρt0 + 1e-12
end

# True when the end-bar section passes every action at this web ratio.
function _end_flexure_passes(lw, t, ρl, material, actions, ends)
    for a in actions
        check_wall_end_bar_flexure(lw * u"m", t * u"m", ρl, ends.area_m2 * u"m^2",
                                  ends.inset_m * u"m", material, a.N, a.M).passed || return false
    end
    return true
end

"""
    design_special_wall_shear!(struc, special, grown_by_wall, lw_by_wall, ρt_by_wall,
                               material; displacement, end_bars=nothing) -> Dict{Int, SpecialShearTerms}

Raise the steel of every special pier until its special shear check passes.

Raising `ρl` raises Mpr, and so Ωv on that line. The loop repeats until no
ratio moves. Ratios only grow on a finite grid, so it stops.
`displacement` holds the piers on the §18.10.6.2 route. `end_bars` is in Mpr
and in the shear at Mn.
"""
function design_special_wall_shear!(struc, special::AbstractVector{Int}, grown_by_wall,
                                    lw_by_wall, ρt_by_wall, material;
                                    displacement::AbstractSet{Int}, end_bars=nothing)
    terms = Dict{Int, SpecialShearTerms}()
    passes = 2 * length(ORDINARY_WALL_RHO_GRID) + 2
    for _ in 1:passes
        moved = false
        for idx in special
            found = special_shear_terms(struc, idx, grown_by_wall, lw_by_wall, material;
                                        displacement = idx in displacement, end_bars)
            terms[idx] = found
            wall = struc.walls[idx]
            ends = _end_bars_at(end_bars, idx)
            if _raise_for_special_shear!(wall, found, grown_by_wall[idx], material, ends)
                moved = true
                ρt_by_wall[idx] = wall.ρt
            end
        end
        moved || return terms
    end
    throw(ArgumentError(
        "special shear: the steel was still moving after $passes passes."))
end

"""
One special shear record per action. Demand is Ve on an earthquake
combination and |V| otherwise; capacity is φVn with the §21.2.4.1 φ.
The actions of `batches`, in order, are the pier's action list.
"""
function special_shear_records(wall, wall_index, direction, terms::SpecialShearTerms,
                               batches, material)
    # A pierced segment passes `(case, nothing, actions, nothing)` tuples. The
    # actions are the third element, where a strength batch keeps `.growns`.
    case_of(b) = b isa Tuple ? b[1] : b.case
    actions_of(b) = b isa Tuple ? b[3] : b.growns
    _require_case_count(terms, collect(Iterators.flatten(actions_of(b) for b in batches)))
    Vn = _special_vn(terms, wall, wall.ρt, material)
    φ = special_shear_phi(terms, Vn)
    φVn = φ * Vn
    records = WallCheckRecord[]
    k = 0
    for batch in batches
        for a in actions_of(batch)
            k += 1
            demand = special_shear_demand(terms, a, k)
            clause = "ACI 318-19 18.10.3.1 (Ωv = $(round(_action_Ωv(terms, k); digits = 3)), " *
                     "ωv = $(round(terms.ωv; digits = 3))), 18.10.4.1, 21.2.4.1 (φ = $φ)"
            push!(records, WallCheckRecord(
                wall_index, wall.story, direction, case_of(batch), a.combination, a.alternative,
                SPECIAL_WALL_SHEAR_CHECK, demand <= φVn * (1 + 1e-9),
                demand / max(φVn, 1e-9), demand, φVn, clause))
        end
    end
    return records
end
