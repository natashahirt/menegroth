# Table 12.2-1 row F, and the building-frame gravity gate for row B.6.
#
# §12.2.5.8 is one sentence. The numbers below that the sentence does not
# state are marked as project choices at the constant.

# Project limit, not an ASCE number. C12.2.1 (corpus: asce-7-22, PDF page 708)
# says that in a building frame system the gravity load on bearing walls
# "should represent a relatively small percentage of the floor or roof area."
# This stage uses 20% of the story's unfactored dead vertical force.
const _BUILDING_FRAME_WALL_GRAVITY_SHARE = 0.20

# ASCE 7-22 §12.2.5.8 (corpus: asce-7-22, PDF page 179).
const _INTERACTIVE_WALL_SHEAR_FRACTION = 0.75
const _INTERACTIVE_FRAME_SHEAR_FRACTION = 0.25

"""Wall share of one story's unfactored dead vertical force. Compression is positive."""
struct WallGravityShare
    story::Int
    wall_N::Float64
    total_N::Float64
    share::Float64
end

"""
One story and one direction of the §12.2.5.8 wall check.

`demand_N` is 75% of the design story shear. `capacity_N` is Σ φVn·|cos α|
of the walls, with α between the wall and that plan axis. Both are newtons.
"""
struct InteractiveStoryShearCheck
    story::Int
    direction::Symbol
    demand_N::Float64
    capacity_N::Float64
    passed::Bool
end

"""
One frame member under the 25% story shear. `kind` is `:column` or `:beam`.

`governing_check` and `governing_ratio` come from `explain_feasibility` on the
worst row. `governing_ratio` is `NaN` when the member was not checked (no
section, or no frame element). `case_label` is the load row that governed.
"""
struct FrameMemberCheck
    kind::Symbol
    index::Int
    passed::Bool
    detail::String
    governing_check::String
    governing_ratio::Float64
    case_label::String
    function FrameMemberCheck(kind::Symbol, index::Integer, passed::Bool, detail::AbstractString,
                              governing_check::AbstractString = "",
                              governing_ratio::Real = passed ? 0.0 : NaN,
                              case_label::AbstractString = "")
        return new(kind, Int(index), passed, String(detail), String(governing_check),
                   Float64(governing_ratio), String(case_label))
    end
end

"""
    _wall_dead_load_shares(struc, basic, elf) -> Vector{WallGravityShare}

Unfactored dead load. The wall part is the pier axial at the story cut. The
total is every wall and frame member through that cut.

# Citation
ASCE 7-22 §11.2, bearing wall and building frame system (corpus: asce-7-22,
PDF page 101). The share is reported for every row. Only row B.6 is limited.
"""
function _wall_dead_load_shares(struc, basic, elf)
    if any(lv -> lv.master === nothing, elf.levels)
        return _wall_dead_load_shares_first_order(struc, basic, elf)
    end
    model = struc.asap_model
    masters = [(lv.elevation_m, lv.master) for lv in elf.levels]
    base = first(elf.levels).elevation_m - first(elf.levels).story_height_m
    base_master = get(_elf_masters(struc), round(Int, base * 1000), nothing)
    profiles = story_axial_profiles(model, basic.u[1], struc.wall_mesh, masters, base;
                                    loads=basic.loads[1], base_master=base_master)
    qmap = _fixed_end_by_element(basic.loads[1])
    shares = WallGravityShare[]
    for (prof, lv) in zip(profiles, elf.levels)
        wall = 0.0
        for pier in struc.wall_mesh.piers
            abs(_pier_bottom(pier) - prof.z_bottom_m) <= WALL_CUT_ZTOL_M || continue
            for c in _cut_contributions(pier.shells, basic.u[1], prof.z_bottom_m; qmap=qmap)
                wall += -c.fz
            end
        end
        total = story_axial_total(prof)
        total > 1.0 || throw(ArgumentError(
            "ordinary wall stage: story $(lv.story) has no unfactored dead " *
            "vertical force, so the wall share is undefined."))
        push!(shares, WallGravityShare(lv.story, wall, total, wall / total))
    end
    return shares
end

"""
Same wall share, from the story cut, when the diaphragm has no rigid master.

The total is the vertical force through that cut. There is no story
geometric stiffness in the displacement.
"""
function _wall_dead_load_shares_first_order(struc, basic, elf)
    qmap = _fixed_end_by_element(basic.loads[1])
    base = first(elf.levels).elevation_m - first(elf.levels).story_height_m
    shares = WallGravityShare[]
    for (i, lv) in enumerate(elf.levels)
        zbot = i == 1 ? base : elf.levels[i - 1].elevation_m
        contrib = _story_cut_contributions(struc.asap_model, basic.u[1],
                                           struc.wall_mesh, zbot; qmap=qmap)
        isempty(contrib) && throw(ArgumentError(
            "ordinary wall stage: no wall or frame member crosses z = $(zbot) m."))
        total = sum(c -> -c.fz, contrib)
        wall = 0.0
        for pier in struc.wall_mesh.piers
            abs(_pier_bottom(pier) - zbot) <= WALL_CUT_ZTOL_M || continue
            for c in _cut_contributions(pier.shells, basic.u[1], zbot; qmap=qmap)
                wall += -c.fz
            end
        end
        total > 1.0 || throw(ArgumentError(
            "ordinary wall stage: story $(lv.story) has no unfactored dead " *
            "vertical force, so the wall share is undefined."))
        push!(shares, WallGravityShare(lv.story, wall, total, wall / total))
    end
    return shares
end

"""
Refuse a building-frame shear-wall row when a story's walls carry more than
the project share.

`:B6` points at the ordinary bearing-wall row `:A3`. `:B4` points at the
special bearing-wall row `:A1`. Bearing-wall rows and row F are not limited
here. The measured shares are still returned to the caller.
"""
function _refuse_building_frame_gravity!(row::Symbol, shares)
    bearing = row === :B6 ? :A3 : row === :B4 ? :A1 : nothing
    bearing === nothing && return shares
    for s in shares
        s.share <= _BUILDING_FRAME_WALL_GRAVITY_SHARE + 1e-9 && continue
        pct = round(100 * s.share; digits=1)
        throw(ArgumentError(
            "building frame system: story $(s.story) walls carry $(pct)% of the " *
            "unfactored dead vertical force. The project limit is " *
            "$(round(Int, 100 * _BUILDING_FRAME_WALL_GRAVITY_SHARE))%, chosen for " *
            "the 'relatively small percentage' in commentary C12.2.1 (corpus: " *
            "asce-7-22, PDF page 708). That percentage is not given a number in " *
            "ASCE 7-22. Use Table 12.2-1 row :$bearing when the walls carry more."))
    end
    return shares
end

"""Design story shear in newtons: strength-level Vx times the §12.8.7 factor."""
function _design_story_shear_N(elf::ElfStoryAnalysis, direction::Symbol, level::Int)
    d = direction === :X ? :x : direction === :Y ? :y :
        throw(ArgumentError("story shear direction must be :X or :Y, got :$direction."))
    vx = 0.0
    found = false
    for case in elf.cases
        case.purpose === :strength || continue
        case.direction === d || continue
        found = true
        vx = max(vx, abs(case.Vx_kN[level]))
    end
    found || throw(ArgumentError(
        "interactive system: no strength case in direction $d."))
    mult = 0.0
    for case in elf.cases
        case.purpose === :drift || continue
        case.direction === d || continue
        m = case.multiplier[level]
        m === nothing && throw(ArgumentError(
            "interactive system: a drift case has no P-delta multiplier."))
        mult = max(mult, Float64(m))
    end
    mult > 0 || throw(ArgumentError(
        "interactive system: direction $d has no drift multiplier."))
    # Vx is kN. φVn is N.
    return vx * 1000.0 * mult
end

"""In-plane design shear strength φVn of one wall, in newtons."""
function _wall_phi_vn(wall, material)
    lw = wall_length(wall)
    t = ustrip(u"m", wall.thickness)
    hw = ustrip(u"m", _stacked_wall_height(wall))
    fc = ustrip(u"Pa", material.concrete.fc′)
    fyt = ustrip(u"Pa", material.transverse.Fy)
    λ = material.concrete.λ
    return wall_shear_capacity_si(fc, fyt, lw, t, wall.ρt, hw; λ=λ).ϕVn
end

"""Raise ρt by one grid step. False at the top of the grid."""
function _bump_rho_t!(wall)
    for r in ORDINARY_WALL_RHO_GRID
        r > wall.ρt + 1e-12 || continue
        wall.ρt = r
        return true
    end
    return false
end

"""
Walk ρl up from the §11.6.2 floor after ρt has changed.

A ratio already on the wall is not reduced. The flexure screen is the one
the member selector uses.
"""
function _reraise_vertical_ratio!(wall, actions, material, ρt_strength)
    lw = wall_length(wall)
    t = ustrip(u"m", wall.thickness)
    hw_m = ustrip(u"m", _stacked_wall_height(wall))
    floor_l = _rho_l_floor(wall.ρt, ρt_strength, hw_m, lw, wall.ρl)
    order = collect(actions)
    chosen = floor_l
    for ρl in _rho_l_candidates(floor_l)
        chosen = ρl
        _flexure_passes!(lw, t, ρl, material, order) && break
    end
    wall.ρl = chosen
    return wall
end

"""
    _enforce_interactive_wall_shear!(...) -> Vector{InteractiveStoryShearCheck}

For each story and each plan axis, Σ φVn·|cos α| must be at least 75% of
the design story shear. Design story shear is the strength-level ELF Vx times
that story's `1/(1−θ)` factor. Where the sum is short, ρt walks up the grid
on the contributing wall with the smallest ratio. A wall that has reached the
shear cap is left there, and the check fails.

A wall along the axis has `|cos α| = 1`. A wall across it contributes nothing
and is not raised for that axis.

# Engineering judgment
§12.2.5.8 does not say how a wall at an angle to the axis counts. User
decision 2026-11-03: its in-plane φVn counts by `|cos α|`, the share of that
strength along the axis, on each axis separately.

# Citation
ASCE 7-22 §12.2.5.8 (corpus: asce-7-22, PDF page 179): the shear strength of
the shear walls shall be at least 75% of the design story shear at each story.
φVn is ACI 318-19 §11.5.4.3 (corpus: aci-318-19, PDF page 172). The `1/(1−θ)`
factor is ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188).
"""
function _enforce_interactive_wall_shear!(struc, elf, material, grown_by_wall, ρt_strength,
                                        directions::AbstractVector{Symbol})
    axis = elf.plan_axis
    by_level = Dict{Int, Vector{Int}}()
    for pier in struc.wall_mesh.piers
        wall = struc.walls[pier.wall_index]
        # A pierced wall is not in the gross-pier action list. Its shear is
        # the segment check.
        isempty(wall.openings) || continue
        push!(get!(by_level, _elf_level_index(struc, elf, wall), Int[]), pier.wall_index)
    end
    checks = InteractiveStoryShearCheck[]
    wall_dirs = [_wall_direction(d) for d in directions]
    for level in eachindex(elf.levels), dir in wall_dirs
        cosine = Dict{Int, Float64}()
        for i in get(by_level, level, Int[])
            c = _pier_axis_cosine(struc.walls[i], axis, dir)
            c > 1e-8 && (cosine[i] = c)
        end
        idxs = collect(keys(cosine))
        V = _design_story_shear_N(elf, dir, level)
        # ASCE 7-22 §12.2.5.8 (corpus: asce-7-22, PDF page 179).
        target = _INTERACTIVE_WALL_SHEAR_FRACTION * V
        stalled = Set{Int}()
        function capacity()
            return sum(cosine[i] * _wall_phi_vn(struc.walls[i], material) for i in idxs;
                       init=0.0)
        end
        cap = capacity()
        while cap + 1.0 < target
            bumped = false
            for i in sort(idxs; by=j -> (struc.walls[j].ρt, j))
                i in stalled && continue
                before = _wall_phi_vn(struc.walls[i], material)
                _bump_rho_t!(struc.walls[i]) || (push!(stalled, i); continue)
                after = _wall_phi_vn(struc.walls[i], material)
                if after <= before + 1.0
                    push!(stalled, i)
                    continue
                end
                bumped = true
                break
            end
            bumped || break
            cap = capacity()
        end
        for i in idxs
            _reraise_vertical_ratio!(struc.walls[i], grown_by_wall[i], material,
                                     ρt_strength[i])
        end
        cap = capacity()
        push!(checks, InteractiveStoryShearCheck(
            elf.levels[level].story, dir, target, cap, cap + 1.0 >= target))
    end
    return checks
end

"""
Put a failing story-shear check on one wall so the design summary sees it.

The wall is the one on that story most nearly along the axis.
"""
function _record_story_shear!(checks, shear, struc, plan_axis::NTuple{2, Float64}=(1.0, 0.0))
    for s in shear
        s.passed && continue
        idx = nothing
        best = 1e-8
        for (i, w) in enumerate(struc.walls)
            w.story == s.story || continue
            c = _pier_axis_cosine(w, plan_axis, s.direction)
            c > best || continue
            best = c
            idx = i
        end
        idx === nothing && (idx = first(eachindex(struc.walls)))
        ratio = s.capacity_N > 0 ? s.demand_N / s.capacity_N : Inf
        push!(checks[idx], WallCheckRecord(
            idx, s.story, s.direction, :story_shear, :strength_1_2D_1_0E, :only,
            "interactive wall shear", false, ratio, s.demand_N, s.capacity_N,
            "ASCE 7-22 12.2.5.8"))
    end
    return checks
end

function _refuse_flat_plate(struc)
    for cell in struc.cells
        cell.floor_type === :flat_plate || continue
        throw(ArgumentError(
            "interactive system: a flat plate has no slab-column frame in this " *
            "model, so §12.2.5.8 cannot check that the frames resist 25% of the " *
            "design story shear. ASCE 7-22 §12.2.5.8 (corpus: asce-7-22, PDF page 179)."))
    end
    return nothing
end

"""`:column` or `:beam` members whose section is not a reinforced-concrete frame section."""
function _missing_frame_sections(struc)
    out = FrameMemberCheck[]
    for (kind, members) in ((:column, struc.columns), (:beam, struc.beams))
        for (i, member) in enumerate(members)
            sec = member.base.section
            ok = kind === :column ?
                 (sec isa RCColumnSection || sec isa RCCircularSection) :
                 sec isa RCBeamSection
            ok && continue
            why = sec === nothing ? "has no sized section" :
                  "section is $(typeof(sec).name.name), not a reinforced-concrete frame section"
            push!(out, FrameMemberCheck(kind, i, false, why))
        end
    end
    return out
end

"""
Frame-member failures are stored on each column and beam result
(`seismic_frame`), not as a wall record. A thicker wall does not fix them.
The call remains so the stage has one place that used to file the placeholder.
"""
function _record_frame_members!(checks, struc, members::Vector{FrameMemberCheck},
                                plan_axis::NTuple{2, Float64}=(1.0, 0.0))
    return checks
end

"""Skeleton edges of one column or beam."""
function _member_edge_indices(struc, member)
    return [struc.segments[i].edge_idx for i in member.base.segment_indices]
end

"""Frame elements of one member. A subdivided edge contributes each child."""
function _member_frame_elements(struc, member)
    els = []
    for edge in _member_edge_indices(struc, member)
        for i in _frame_element_indices(struc, edge)
            push!(els, struc.asap_model.frame_elements[i])
        end
    end
    return els
end

"""`:x` / `:y` as the wall in-plane symbol `:X` / `:Y`."""
function _wall_direction(direction::Symbol)
    direction === :x && return :X
    direction === :y && return :Y
    throw(ArgumentError("interactive system: direction must be :x or :y, got :$direction."))
end

"""
Seismic effects scaled to 25% of the story forces, accidental torsion included.

Only effects whose 100% axis is in `directions` are kept. Each entry is
`(direction, torsion, label, loads)`.
"""
function _quarter_story_cases(struc, elf, directions::AbstractVector{Symbol},
                              effects::AbstractVector{SeismicEffectCase})
    out = Tuple{Symbol, Symbol, Symbol, Vector{Asap.AbstractLoad}}[]
    for effect in effects
        effect.direction in directions || continue
        full = seismic_effect_loads(struc, elf, effect)
        # ASCE 7-22 §12.2.5.8 (corpus: asce-7-22, PDF page 179): the frames
        # shall be capable of resisting at least 25% of the design story shear.
        push!(out, (effect.direction, effect.torsion, effect.label,
                    scale_story_loads(full, _INTERACTIVE_FRAME_SHEAR_FRACTION)))
    end
    isempty(out) && throw(ArgumentError(
        "interactive system: the ELF analysis has no strength case."))
    return out
end

"""Factored-gravity keys of the two earthquake combinations."""
function _earthquake_gravity_keys(roof::Symbol)
    keys = GravityStiffnessKey[]
    for combo in asce7_strength_combinations
        (combo.E != 0.0 || combo.Ev != 0.0) || continue
        _pushkey!(keys, _gravity_key(combo, roof))
    end
    return keys
end

"""Master story drifts along the unit plan vector `d`, in metres."""
function _master_story_drifts(levels, u, d::NTuple{2, Float64})
    prev = 0.0
    drifts = Float64[]
    for lv in levels
        gid = lv.master.globalID
        top = u[gid[1]] * d[1] + u[gid[2]] * d[2]
        push!(drifts, top - prev)
        prev = top
    end
    return drifts
end

"""
Solve the frame alone at 25% of each seismic effect, on each earthquake story
stiffness. Equilibrium of the frame cut is required for every effect. θ from
the 25% one-direction case without torsion, divided by `(1+θ)`, must be within
θmax on each axis in `directions`.

# Citation
ASCE 7-22 §12.2.5.8 (corpus: asce-7-22, PDF page 179) and §12.8.7 (PDF page
188). The last sentence of §12.8.7 permits dividing θ from a P-delta analysis
by `(1 + θ)` before the θmax check. θ is defined there for one direction of
story shear, so the orthogonal sums are not given a θ.
"""
function _check_frame_only_stability!(struc, elf, second, inputs, seismic_system, directions,
                                      effects::AbstractVector{SeismicEffectCase})
    _refuse_flat_plate(struc)
    model = struc.asap_model
    links = struc.asap_rigid_links
    cases = _quarter_story_cases(struc, elf, directions, effects)
    stability = _quarter_story_cases(struc, elf, directions,
        [e for e in seismic_effect_cases(elf; orthogonal=false) if e.torsion === :none])
    loads = vcat([c[4] for c in cases], [c[4] for c in stability])
    θmax = stability_coefficient_limit(inputs.β, seismic_system.Cd; Ω0=seismic_system.Ω0)
    # One reduced symbolic factorization is reused across every gravity key: the
    # P-Δ `K_G` changes, the frame-only reduced pattern does not (#7 phase 2b).
    factor_cache = _lateral_factor_cache(struc)
    for key in _earthquake_gravity_keys(inputs.roof)
        haskey(second, key) || throw(ArgumentError(
            "interactive system: no story stiffness for gravity D=$(key.D) " *
            "L=$(key.L) roof=$(key.roof)."))
        Kg = second[key].Kg
        solved = Asap.solve(model, loads, links;
                            geometric_stiffness=Kg, exclude_shells=true,
                            factor_cache=factor_cache)
        for (i, (_, _, label, case_loads)) in enumerate(cases)
            for lv in elf.levels
                z = lv.elevation_m - lv.story_height_m
                eq = check_story_cut_equilibrium(model, solved[i], struc.wall_mesh,
                    case_loads, z; fixed_end_from_loads=true, geometric_stiffness=Kg,
                    include_walls=false)
                eq.passed || throw(ArgumentError(
                    "interactive system: the frame-only cut at story $(lv.story) " *
                    "($label) is not in equilibrium (residual " *
                    "$(eq.residual)). The 25% check is not reported on that result."))
            end
        end
        for (s, (direction, _, _, _)) in enumerate(stability)
            u = solved[length(cases) + s]
            drifts = _master_story_drifts(elf.levels, u, elf_direction_vector(elf, direction))
            for (k, lv) in enumerate(elf.levels)
                Vx = _INTERACTIVE_FRAME_SHEAR_FRACTION * abs(elf.cases[_strength_case_index(elf, direction)].Vx_kN[k])
                θ = stability_coefficient(lv.px_kN, lv.story_height_m, Vx, abs(drifts[k]))
                # ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188).
                θ_check = θ / (1 + θ)
                θ_check <= θmax + 1e-9 && continue
                throw(ArgumentError(
                    "interactive system: frame-only θ = $(θ_check) at story $(lv.story) " *
                    "in direction $direction exceeds θmax = $(θmax). The structure is " *
                    "potentially unstable and shall be redesigned. ASCE 7-22 §12.8.7 " *
                    "(corpus: asce-7-22, PDF page 188) and §12.2.5.8 (PDF page 179)."))
            end
        end
    end
    return nothing
end

"""Index of the strength case with no accidental torsion in `direction` (`:x` or `:y`)."""
function _strength_case_index(elf, direction::Symbol)
    for (i, case) in enumerate(elf.cases)
        case.purpose === :strength || continue
        case.direction === direction || continue
        case.torsion === :none || continue
        return i
    end
    throw(ArgumentError(
        "interactive system: no strength case in direction $direction without torsion."))
end

"""Station forces of one element, combined the way a wall action is combined."""
function _combine_member_stations(combo, roof, D, L, companion, eh, SDS, rho)
    n = length(D.P)
    length(L.P) == n && length(companion.P) == n && length(eh.P) == n ||
        throw(ArgumentError("interactive system: station counts differ between cases."))
    P = Vector{Float64}(undef, n)
    My = Vector{Float64}(undef, n)
    Vy = Vector{Float64}(undef, n)
    Mz = Vector{Float64}(undef, n)
    Vz = Vector{Float64}(undef, n)
    for i in 1:n
        # Ev = 0.2 SDS D on the axial force only, matching the pier combination.
        ev = vertical_seismic_load_effect(SDS, D.P[i])
        P[i] = _factored_component(combo, roof, D.P[i], L.P[i], companion.P[i],
                                   0.0, rho * eh.P[i], ev)
        My[i] = _factored_component(combo, roof, D.My[i], L.My[i], companion.My[i],
                                    0.0, rho * eh.My[i], 0.0)
        Vy[i] = _factored_component(combo, roof, D.Vy[i], L.Vy[i], companion.Vy[i],
                                    0.0, rho * eh.Vy[i], 0.0)
        Mz[i] = _factored_component(combo, roof, D.Mz[i], L.Mz[i], companion.Mz[i],
                                    0.0, rho * eh.Mz[i], 0.0)
        Vz[i] = _factored_component(combo, roof, D.Vz[i], L.Vz[i], companion.Vz[i],
                                    0.0, rho * eh.Vz[i], 0.0)
    end
    return (P=P, My=My, Vy=Vy, Mz=Mz, Vz=Vz)
end

"""Compression-positive axial and the two end-moment envelopes, in SI."""
function _column_demand_values(stations)
    min_P = minimum(stations.P)
    Pu = min_P < 0 ? -min_P : 0.0
    Mux = maximum(abs, stations.My)
    Muy = maximum(abs, stations.Mz)
    return Pu, Mux, Muy
end

function _beam_demand_values(el, stations)
    sag, hog = _asap_signed_My_envelopes(el, stations.My)
    Vu = max(maximum(abs, stations.Vz), maximum(abs, stations.Vy))
    min_P = minimum(stations.P)
    max_P = maximum(stations.P)
    Nu = min_P < 0 ? -min_P : 0.0
    if max_P > Nu
        Nu = -max_P
    end
    return sag, hog, Vu, Nu
end

"""
Check sized beams and columns for the 25% story shear.

Moments already include story P-delta, so the column checker does not magnify
them again. ACI 318-19 §6.7 (corpus: aci-318-19, PDF page 84) is the linear
elastic second-order analysis. The moment magnifier of §6.6 is the other method.

Returns one result per member. An empty section list is the caller's problem:
this function is only called when every section is a reinforced-concrete one.

A member group that fails gets a section floor in `struc.frame_section_floors`
when `member_opts` can resize it (see [`_raise_frame_floors!`](@ref)).
Each kind is checked with the concrete and rebar it was sized with (see
[`_frame_checkers`](@ref)).
"""
function _check_frame_member_strength(struc, basic, elf, second, inputs, directions,
                                      effects::AbstractVector{SeismicEffectCase};
                                      member_opts = (columns = nothing, beams = nothing),
                                      beam_opts_by_group = Dict{UInt64, Any}(),
                                      uniform_columns::Symbol = :off)
    frame = _frame_checkers(inputs.material, member_opts; beam_opts_by_group)
    cases = _quarter_story_cases(struc, elf, directions, effects)
    loads = [c[4] for c in cases]
    solved = Dict{GravityStiffnessKey, Vector{Vector{Float64}}}()
    # One reduced symbolic factorization is reused across every gravity key: the
    # P-Δ `K_G` changes, the frame-only reduced pattern does not (#7 phase 2b).
    factor_cache = _lateral_factor_cache(struc)
    for key in _earthquake_gravity_keys(inputs.roof)
        solved[key] = Asap.solve(struc.asap_model, loads, struc.asap_rigid_links;
                                 geometric_stiffness=second[key].Kg, exclude_shells=true,
                                 factor_cache=factor_cache)
    end
    out = FrameMemberCheck[]
    rows = Dict{Tuple{Symbol, Int}, Vector{Tuple{String, Any}}}()
    rho = Float64(inputs.rho)
    for (kind, members) in ((:column, struc.columns), (:beam, struc.beams))
        for (i, member) in enumerate(members)
            els = _member_frame_elements(struc, member)
            isempty(els) && (push!(out, FrameMemberCheck(kind, i, false, "no frame element")); continue)
            member_rows = _member_demand_rows(kind, i, els, basic, second, solved, cases,
                                              inputs, rho)
            rows[(kind, i)] = member_rows
            rep = _member_frame_report(kind, member, member.base.section, member_rows, frame)
            push!(out, FrameMemberCheck(kind, i, rep.passed, rep.detail, rep.governing_check,
                                        rep.governing_ratio, rep.case_label))
        end
    end
    return _raise_frame_floors!(out, struc, rows, member_opts, frame;
                                beam_opts_by_group, uniform_columns)
end

"""
    _frame_checkers(wall_material, member_opts) -> NamedTuple

Checker, concrete, and capacity cache for each frame member kind:
`(column = (checker, concrete, cache), beam = (checker, concrete, cache))`.

A column is checked with the concrete and rebar of `member_opts.columns`, and a
beam with those of `member_opts.beams` (longitudinal and transverse), when
those are the concrete options the members were sized with. Otherwise the
kind falls back to `wall_material`, the `ReinforcedConcreteMaterial` of the
wall inputs. The column checker never magnifies moments: the row F forces
already include story P-delta.
"""
function _column_checker_bundle(wall_material, col_opts)
    col_concrete, col_rebar = col_opts isa StructuralSizer.ConcreteColumnOptions ?
        (col_opts.material, col_opts.rebar_material) :
        (wall_material.concrete, wall_material.rebar)
    checker = ACIColumnChecker(; include_slenderness=false, include_biaxial=true,
                               fy_ksi=ustrip(u"ksi", col_rebar.Fy),
                               Es_ksi=ustrip(u"ksi", col_rebar.E))
    return (checker = checker, concrete = col_concrete,
            cache = Dict{UInt, ACIColumnCapacityCache}())
end

"""Checker, concrete, and capacity cache for one beam options object."""
function _beam_checker_bundle(wall_material, beam_opts)
    concrete, rebar, stirrup = beam_opts isa StructuralSizer.ConcreteBeamOptions ?
        (beam_opts.material, beam_opts.rebar_material,
         StructuralSizer.get_transverse_rebar(beam_opts)) :
        (wall_material.concrete, wall_material.rebar, wall_material.transverse)
    checker = ACIBeamChecker(; fy_ksi=ustrip(u"ksi", rebar.Fy),
                             fyt_ksi=ustrip(u"ksi", stirrup.Fy),
                             Es_ksi=ustrip(u"ksi", rebar.E),
                             λ=concrete.λ)
    return (checker = checker, concrete = concrete,
            cache = Dict{UInt, ACIBeamCapacityCache}())
end

function _frame_checkers(wall_material, member_opts; beam_opts_by_group = Dict{UInt64, Any}())
    wall_material isa ReinforcedConcreteMaterial || throw(ArgumentError(
        "interactive system: the frame check needs a ReinforcedConcreteMaterial."))
    column = _column_checker_bundle(wall_material, member_opts.columns)
    beam = _beam_checker_bundle(wall_material, member_opts.beams)
    bundles = Dict{UInt, Any}(objectid(member_opts.beams) => beam)
    beam_for = function (member)
        gid = group_id(member)
        opts = gid === nothing ? member_opts.beams : get(beam_opts_by_group, gid, member_opts.beams)
        return get!(bundles, objectid(opts)) do
            _beam_checker_bundle(wall_material, opts)
        end
    end
    return (column = column, beam = beam, beam_for = beam_for)
end

"""The beam checker for `member`, or the building-wide one when `frame` has no lookup."""
function _beam_bundle(frame, member)
    return hasproperty(frame, :beam_for) ? frame.beam_for(member) : frame.beam
end

function _cached_column_capacity!(cache_of, checker, section, concrete)
    id = objectid(section)
    haskey(cache_of, id) && return cache_of[id]
    cache = ACIColumnCapacityCache(1)
    precompute_capacities!(checker, cache, [section], concrete, MinVolume())
    cache_of[id] = cache
    return cache
end

function _cached_beam_capacity!(cache_of, checker, section, concrete)
    id = objectid(section)
    haskey(cache_of, id) && return cache_of[id]
    cache = ACIBeamCapacityCache(1)
    precompute_capacities!(checker, cache, [section], concrete, MinVolume())
    cache_of[id] = cache
    return cache
end

"""Loads in `loads` that act on frame element `el`.

Shell area loads have no frame element. A tributary or line load on another
member is not this element's station diagram; its effect is already in the
solved end forces.
"""
function _loads_on_element(loads, el)
    id = el.elementID
    return [ld for ld in loads if hasproperty(ld, :element) && ld.element.elementID == id]
end

"""
`(label, demand)` for every earthquake combination, every 25% case, and every
frame element of one member. A column demand is an `RCColumnDemand`, a beam
demand an `RCBeamDemand`, both in kip and kip·ft as the member sizers build
them. Mixed force and moment quantities do not promote to one demand type.
Station diagrams use only the loads on that element.
"""
function _member_demand_rows(kind, index, els, basic, second, solved, cases, inputs, rho)
    kip(F_N) = ustrip(uconvert(Asap.kip, F_N * u"N"))
    kipft(M_Nm) = ustrip(uconvert(Asap.kip * u"ft", M_Nm * u"N*m"))
    rows = Tuple{String, Any}[]
    dead = [_loads_on_element(basic.loads[1], el) for el in els]
    live = [_loads_on_element(basic.loads[2], el) for el in els]
    roof = [_loads_on_element(basic.loads[3], el) for el in els]
    for combo in asce7_strength_combinations
        (combo.E != 0.0 || combo.Ev != 0.0) || continue
        key = _gravity_key(combo, inputs.roof)
        set = second[key]
        lateral = solved[key]
        for (k, (_, _, label, _)) in enumerate(cases)
            for (j, el) in enumerate(els)
                D = _element_forces_from_u(el, set.u[1], dead[j])
                L = _element_forces_from_u(el, set.u[2], live[j])
                C = _element_forces_from_u(el, set.u[3], roof[j])
                eh = _element_forces_from_u(el, lateral[k], Asap.AbstractLoad[])
                stations = _combine_member_stations(combo, inputs.roof, D, L, C, eh,
                                                    inputs.SDS, rho)
                demand = if kind === :column
                    Pu, Mux, Muy = _column_demand_values(stations)
                    # Story P-delta is already in these forces (ACI 318-19 §6.7).
                    RCColumnDemand(index; Pu=kip(Pu), Mux=kipft(Mux), Muy=kipft(Muy),
                                   magnify=false)
                else
                    sag, hog, Vu, Nu = _beam_demand_values(el, stations)
                    RCBeamDemand(index; Mu=kipft(sag), Mu_neg=kipft(hog),
                                 Vu=kip(Vu), Nu=kip(Nu))
                end
                push!(rows, ("$(combo.name) $label", demand))
            end
        end
    end
    return rows
end

"""Geometry the row F check uses. Story P-delta is already in the forces."""
function _member_frame_geometry(member)
    return StructuralSizer.ConcreteMemberGeometry(member.base.L; Lu=member.base.Lb,
                                                  kx=member.base.Kx, ky=member.base.Ky,
                                                  braced=false)
end

"""Checker bundle and its capacity cache for one section."""
function _member_frame_bundle(kind, member, section, frame)
    k = kind === :column ? frame.column : _beam_bundle(frame, member)
    cache = kind === :column ?
        _cached_column_capacity!(k.cache, k.checker, section, k.concrete) :
        _cached_beam_capacity!(k.cache, k.checker, section, k.concrete)
    return k, cache
end

"""`(passed, detail)`: whether `section` passes every row of one member. `frame` is [`_frame_checkers`](@ref)."""
function _member_resists(kind, member, section, rows, frame)
    geometry = _member_frame_geometry(member)
    k, cache = _member_frame_bundle(kind, member, section, frame)
    for (label, demand) in rows
        is_feasible(k.checker, cache, 1, section, k.concrete, demand, geometry) ||
            return false, "$label does not pass"
    end
    return true, ""
end

"""
Pass/fail and the governing check of the installed section, from
`explain_feasibility` on every row. The catalog walk stays on
[`_member_resists`](@ref). A failing row outranks a passing one; otherwise the
higher ratio governs.
"""
function _member_frame_report(kind, member, section, rows, frame)
    isempty(rows) && return (passed = true, detail = "", governing_check = "",
                             governing_ratio = 0.0, case_label = "")
    geometry = _member_frame_geometry(member)
    k, cache = _member_frame_bundle(kind, member, section, frame)
    worst = nothing
    worst_label = ""
    for (label, demand) in rows
        expl = explain_feasibility(k.checker, cache, 1, section, k.concrete, demand, geometry)
        if worst === nothing ||
           (!expl.passed, expl.governing_ratio) > (!worst.passed, worst.governing_ratio)
            worst = expl
            worst_label = label
        end
    end
    detail = worst.passed ? "" : "$worst_label does not pass"
    return (passed = worst.passed, detail = detail, governing_check = worst.governing_check,
            governing_ratio = worst.governing_ratio, case_label = worst_label)
end

"""
Sizing catalog and objective of `opts` when it can keep a row F section floor,
`:nlp` when NLP sizing takes the row F rows as constraints instead, else a
reason string. Mirrors the concrete discrete and NLP sizing paths.
"""
function _frame_floor_catalog(kind::Symbol, opts)
    expected = kind === :column ? StructuralSizer.ConcreteColumnOptions :
                                  StructuralSizer.ConcreteBeamOptions
    opts isa expected ||
        return "the $(kind) options are not $(nameof(expected)), so it is not resized"
    if opts.sizing_strategy === :nlp
        # The frame check refuses T-sections, so a T-beam group never gets here
        # with a section to compare.
        kind === :beam && opts.include_flange &&
            return "T-beam sizing cannot keep a section floor, so it is not resized"
        return :nlp
    end
    opts.sizing_strategy === :discrete ||
        return "the $(kind) options are not :discrete or :nlp, so it is not resized"
    (opts.materials === nothing && opts.n_max_sections == 0) ||
        return "the $(kind) options use several materials or n_max_sections, so it is not resized"
    if kind === :beam && opts.include_flange
        return "T-beam sizing cannot keep a section floor, so it is not resized"
    end
    cat = if opts.custom_catalog !== nothing
        opts.custom_catalog
    elseif kind === :column
        StructuralSizer.rc_column_catalog(opts.section_shape, opts.catalog)
    else
        StructuralSizer.rc_beam_catalog(opts.catalog)
    end
    obj = s -> StructuralSizer.objective_value(opts.objective, s, opts.material, 1.0u"m";
                                               rebar=opts.rebar_material,
                                               transverse=StructuralSizer.get_transverse_rebar(opts))
    return (catalog = cat, objective = obj)
end

"""
Rows member `i` of `kind` has to pass: those stored for it in earlier rounds,
then this round's `current` rows that are not already stored.
"""
function _rows_with_stored(struc, kind, member, i, current)
    T = kind === :column ? StructuralSizer.RCColumnDemand : StructuralSizer.RCBeamDemand
    gid = group_id(member)
    stored = gid === nothing ? Tuple{String, Any}[] :
        [r for r in get(struc.frame_floor_demands, gid, Tuple{String, Any}[])
         if r[2] isa T && r[2].member_idx == i]
    for r in current
        r in stored || push!(stored, r)
    end
    return stored
end

"""
Store the row F rows of group `gid`'s members in `cohort` as that group's
floor demands. `accumulate` keeps the rows stored in earlier rounds, so a
group's constraints only grow.
"""
function _store_frame_floor_rows!(struc, kind, members, cohort, gid, rows;
                                  accumulate::Bool = false)
    stored = accumulate ? copy(get(struc.frame_floor_demands, gid, Tuple{String, Any}[])) :
                          Tuple{String, Any}[]
    for i in cohort
        group_id(members[i]) == gid || continue
        for row in rows[(kind, i)]
            row in stored || push!(stored, row)
        end
    end
    struc.frame_floor_demands[gid] = stored
    return nothing
end

"""
Give each failing member group the lightest catalog section that passes the
row F rows of every member in the group, this round's and those stored in
earlier rounds. The section goes in `struc.frame_section_floors`. The rows go
in `struc.frame_floor_demands`, one vector per group: the union of that
group's members over every round. Concrete discrete sizing then keeps any
catalog section that passes those rows (see [`_frame_floor_mask`](@ref)), so
a floor can relax below the section it replaced. The stored rows only grow,
so the floor's objective never falls from one round to the next.

NLP options have no catalog. A failing NLP group gets no section, only its
rows in `struc.frame_floor_demands`, added to the rows of earlier rounds.
Column and beam NLP constrain every stored row, so the constraints only grow.

The walk uses the checker of the row F check itself. The member sizer checks
the gravity combinations, with slenderness, on whatever it chooses. A group
with no passing section keeps its section and stays failing, and no rows are
stored for it.

A beam group is walked in its own catalog (`beam_opts_by_group`, from the
framing level that sizes it). With `uniform_columns` of `:per_story` or
`:building`, a failing column floors every sizing group in that uniformity
group, and the section has to pass every column in it.

Returns `checks` with the detail of each failing member updated.
"""
function _raise_frame_floors!(checks, struc, rows, member_opts, frame;
                              beam_opts_by_group = Dict{UInt64, Any}(),
                              uniform_columns::Symbol = :off)
    members_of = Dict(:column => struc.columns, :beam => struc.beams)
    note = Dict{Tuple{Symbol, Int}, String}()
    # (kind, indices that must pass, group ids that receive the floor, indices to annotate)
    work = Tuple{Symbol, Vector{Int}, Vector{UInt64}, Vector{Int}}[]
    handled = Set{Tuple{Symbol, Int}}()
    if uniform_columns !== :off
        cohorts = Dict{Int, Vector{Int}}()
        for (i, col) in enumerate(struc.columns)
            key = uniform_columns === :building ? 0 : col.story
            push!(get!(Vector{Int}, cohorts, key), i)
        end
        for idxs in values(cohorts)
            failing = [i for i in idxs
                       if any(c -> c.kind === :column && c.index == i && !c.passed &&
                              haskey(rows, (:column, i)), checks)]
            isempty(failing) && continue
            cohort = [i for i in idxs if haskey(rows, (:column, i))]
            gids = UInt64[]
            for i in cohort
                gid = group_id(struc.columns[i])
                gid === nothing && continue
                gid in gids || push!(gids, gid)
            end
            if isempty(gids)
                for i in failing
                    note[(:column, i)] = "the member has no sizing group, so it is not resized"
                    push!(handled, (:column, i))
                end
                continue
            end
            push!(work, (:column, cohort, gids, failing))
            foreach(i -> push!(handled, (:column, i)), failing)
        end
    end
    pending = Dict{Tuple{Symbol, UInt64}, Vector{Int}}()
    for c in checks
        c.passed && continue
        (:column, c.index) in handled && continue
        haskey(rows, (c.kind, c.index)) || continue
        gid = group_id(members_of[c.kind][c.index])
        if gid === nothing
            note[(c.kind, c.index)] = "the member has no sizing group, so it is not resized"
            continue
        end
        push!(get!(pending, (c.kind, gid), Int[]), c.index)
    end
    for ((kind, gid), idxs) in pending
        group = [i for (i, m) in enumerate(members_of[kind])
                 if group_id(m) == gid && haskey(rows, (kind, i))]
        push!(work, (kind, group, UInt64[gid], idxs))
    end
    for (kind, cohort, gids, failing) in work
        opts = kind === :column ? member_opts.columns :
               get(beam_opts_by_group, first(gids), member_opts.beams)
        source = _frame_floor_catalog(kind, opts)
        if source isa String
            foreach(i -> note[(kind, i)] = source, failing)
            continue
        end
        if source === :nlp
            for gid in gids
                _store_frame_floor_rows!(struc, kind, members_of[kind], cohort, gid, rows;
                                         accumulate = true)
            end
            foreach(i -> note[(kind, i)] =
                "the row F rows are kept as constraints for NLP member sizing", failing)
            continue
        end
        needed = Dict(i => _rows_with_stored(struc, kind, members_of[kind][i], i,
                                             rows[(kind, i)])
                      for i in cohort)
        order = sort(collect(eachindex(source.catalog));
                     by = j -> (source.objective(source.catalog[j]), j))
        chosen = nothing
        for j in order
            s = source.catalog[j]
            all(i -> first(_member_resists(kind, members_of[kind][i], s, needed[i], frame)),
                cohort) || continue
            chosen = s
            break
        end
        msg = if chosen === nothing
            "no catalog section passes this round's and the stored row F rows, so it is not resized"
        else
            for gid in gids
                struc.frame_section_floors[gid] = chosen
                _store_frame_floor_rows!(struc, kind, members_of[kind], cohort, gid, rows;
                                         accumulate = true)
            end
            "the lightest section that passes is set as the group's floor for member sizing"
        end
        foreach(i -> note[(kind, i)] = msg, failing)
    end
    return [haskey(note, (c.kind, c.index)) ?
                FrameMemberCheck(c.kind, c.index, c.passed,
                                 "$(c.detail); $(note[(c.kind, c.index)])",
                                 c.governing_check, c.governing_ratio, c.case_label) :
                c
            for c in checks]
end

"""
Frame half of §12.2.5.8.

A flat plate is refused. Members without a reinforced-concrete section are
recorded as failing and the frame is not solved, because there is nothing to
check. When every section is sized, the frame-only model is solved and each
beam and column is checked. θ above θmax throws: §12.8.7 says the structure
shall be redesigned. A failing group may get a section floor from
`member_opts` (`columns` and `beams`, the design's member options).
"""
function _check_interactive_frames!(struc, basic, elf, second, inputs, seismic_system, directions,
                                    effects::AbstractVector{SeismicEffectCase};
                                    member_opts = (columns = nothing, beams = nothing),
                                    beam_opts_by_group = Dict{UInt64, Any}(),
                                    uniform_columns::Symbol = :off)
    missing = _missing_frame_sections(struc)
    # The frame-only solve runs either way. A missing section means the
    # strength check has nothing to use; the story shear and θ are still real.
    _check_frame_only_stability!(struc, elf, second, inputs, seismic_system, directions, effects)
    isempty(missing) || return missing
    return _check_frame_member_strength(struc, basic, elf, second, inputs, directions, effects;
                                        member_opts, beam_opts_by_group, uniform_columns)
end
