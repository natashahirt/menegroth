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

`demand_N` is 75% of the design story shear. `capacity_N` is Σ φVn of the
walls in that direction. Both are newtons.
"""
struct InteractiveStoryShearCheck
    story::Int
    direction::Symbol
    demand_N::Float64
    capacity_N::Float64
    passed::Bool
end

"""One frame member under the 25% story shear. `kind` is `:column` or `:beam`."""
struct FrameMemberCheck
    kind::Symbol
    index::Int
    passed::Bool
    detail::String
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
Refuse row B.6 when a story's walls carry more than the project share.

Row A.3 and row F are not limited here. The measured shares are still returned
to the caller.
"""
function _refuse_building_frame_gravity!(row::Symbol, shares)
    row === :B6 || return shares
    for s in shares
        s.share <= _BUILDING_FRAME_WALL_GRAVITY_SHARE + 1e-9 && continue
        pct = round(100 * s.share; digits=1)
        throw(ArgumentError(
            "building frame system: story $(s.story) walls carry $(pct)% of the " *
            "unfactored dead vertical force. The project limit is " *
            "$(round(Int, 100 * _BUILDING_FRAME_WALL_GRAVITY_SHARE))%, chosen for " *
            "the 'relatively small percentage' in commentary C12.2.1 (corpus: " *
            "asce-7-22, PDF page 708). That percentage is not given a number in " *
            "ASCE 7-22. Use Table 12.2-1 row :A3 when the walls carry more."))
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

For each story and each principal direction, Σ φVn must be at least 75% of
the design story shear. Design story shear is the strength-level ELF Vx times
that story's `1/(1−θ)` factor. Where the sum is short, ρt walks up the grid
on the wall with the smallest ratio. A wall that has reached the shear cap
is left there, and the check fails.

# Citation
ASCE 7-22 §12.2.5.8 (corpus: asce-7-22, PDF page 179): the shear strength of
the shear walls shall be at least 75% of the design story shear at each story.
φVn is ACI 318-19 §11.5.4.3 (corpus: aci-318-19, PDF page 172). The `1/(1−θ)`
factor is ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188).
"""
function _enforce_interactive_wall_shear!(struc, elf, material, grown_by_wall, ρt_strength)
    groups = Dict{Tuple{Int, Symbol}, Vector{Int}}()
    for pier in struc.wall_mesh.piers
        wall = struc.walls[pier.wall_index]
        level = _elf_level_index(struc, elf, wall)
        dir = _pier_principal_direction(wall)
        push!(get!(groups, (level, dir), Int[]), pier.wall_index)
    end
    checks = InteractiveStoryShearCheck[]
    for level in eachindex(elf.levels), dir in (:X, :Y)
        idxs = get(groups, (level, dir), Int[])
        V = _design_story_shear_N(elf, dir, level)
        # ASCE 7-22 §12.2.5.8 (corpus: asce-7-22, PDF page 179).
        target = _INTERACTIVE_WALL_SHEAR_FRACTION * V
        stalled = Set{Int}()
        function capacity()
            return sum(_wall_phi_vn(struc.walls[i], material) for i in idxs; init=0.0)
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

"""Put a failing story-shear check on one wall so the design summary sees it."""
function _record_story_shear!(checks, shear, struc)
    for s in shear
        s.passed && continue
        idx = findfirst(w -> w.story == s.story &&
            _pier_principal_direction(w) === s.direction, struc.walls)
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

function _record_frame_members!(checks, struc, members::Vector{FrameMemberCheck})
    isempty(members) && return checks
    any(!c.passed, members) || return checks
    idx = first(eachindex(struc.walls))
    wall = struc.walls[idx]
    push!(checks[idx], WallCheckRecord(
        idx, wall.story, _pier_principal_direction(wall), :frame_quarter,
        :strength_1_2D_1_0E, :only, "interactive frame strength", false, 1.0,
        0.0, 0.0, "ASCE 7-22 12.2.5.8"))
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

"""Strength ELF cases scaled to 25% of the story forces, accidental torsion included."""
function _quarter_story_cases(elf)
    out = Tuple{Symbol, Symbol, Vector{Asap.AbstractLoad}}[]
    for case in elf.cases
        case.purpose === :strength || continue
        full = _elf_loads(elf.levels, case.Fx_kN, case.Mz_kN_m, case.direction)
        # ASCE 7-22 §12.2.5.8 (corpus: asce-7-22, PDF page 179): the frames
        # shall be capable of resisting at least 25% of the design story shear.
        push!(out, (case.direction, case.torsion, scale_story_loads(full,
            _INTERACTIVE_FRAME_SHEAR_FRACTION)))
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

"""Center-of-mass story drifts from a master displacement, in metres."""
function _master_story_drifts(levels, u, direction::Symbol)
    dof = direction === :x ? 1 : direction === :y ? 2 :
          throw(ArgumentError("drift direction must be :x or :y, got :$direction."))
    prev = 0.0
    drifts = Float64[]
    for lv in levels
        top = u[lv.master.globalID[dof]]
        push!(drifts, top - prev)
        prev = top
    end
    return drifts
end

"""
Solve the frame alone at 25% of each strength story force, on each earthquake
story stiffness. Equilibrium of the frame cut is required. θ from that solve,
divided by `(1+θ)`, must be within θmax.

# Citation
ASCE 7-22 §12.2.5.8 (corpus: asce-7-22, PDF page 179) and §12.8.7 (PDF page
188). The last sentence of §12.8.7 permits dividing θ from a P-delta analysis
by `(1 + θ)` before the θmax check.
"""
function _check_frame_only_stability!(struc, elf, second, inputs, seismic_system)
    _refuse_flat_plate(struc)
    model = struc.asap_model
    links = struc.asap_rigid_links
    cases = _quarter_story_cases(elf)
    loads = [c[3] for c in cases]
    θmax = stability_coefficient_limit(inputs.β, seismic_system.Cd; Ω0=seismic_system.Ω0)
    for key in _earthquake_gravity_keys(inputs.roof)
        haskey(second, key) || throw(ArgumentError(
            "interactive system: no story stiffness for gravity D=$(key.D) " *
            "L=$(key.L) roof=$(key.roof)."))
        Kg = second[key].Kg
        solved = Asap.solve(model, loads, links; geometric_stiffness=Kg, exclude_shells=true)
        for (i, (direction, torsion, case_loads)) in enumerate(cases)
            for lv in elf.levels
                z = lv.elevation_m - lv.story_height_m
                eq = check_story_cut_equilibrium(model, solved[i], struc.wall_mesh,
                    case_loads, z; fixed_end_from_loads=true, geometric_stiffness=Kg,
                    include_walls=false)
                eq.passed || throw(ArgumentError(
                    "interactive system: the frame-only cut at story $(lv.story) " *
                    "($direction, $torsion) is not in equilibrium (residual " *
                    "$(eq.residual)). The 25% check is not reported on that result."))
            end
            torsion === :none || continue
            drifts = _master_story_drifts(elf.levels, solved[i], direction)
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
"""
function _check_frame_member_strength(struc, basic, elf, second, inputs)
    material = inputs.material
    material isa ReinforcedConcreteMaterial || throw(ArgumentError(
        "interactive system: the frame check needs a ReinforcedConcreteMaterial."))
    fy = ustrip(u"ksi", material.rebar.Fy)
    fyt = ustrip(u"ksi", material.transverse.Fy)
    Es = ustrip(u"ksi", material.rebar.E)
    λ = material.concrete.λ
    col_checker = ACIColumnChecker(; include_slenderness=false, include_biaxial=true,
                                   fy_ksi=fy, Es_ksi=Es)
    beam_checker = ACIBeamChecker(; fy_ksi=fy, fyt_ksi=fyt, Es_ksi=Es, λ=λ)
    col_cache = Dict{UInt, ACIColumnCapacityCache}()
    beam_cache = Dict{UInt, ACIBeamCapacityCache}()
    cases = _quarter_story_cases(elf)
    loads = [c[3] for c in cases]
    solved = Dict{GravityStiffnessKey, Vector{Vector{Float64}}}()
    for key in _earthquake_gravity_keys(inputs.roof)
        solved[key] = Asap.solve(struc.asap_model, loads, struc.asap_rigid_links;
                                 geometric_stiffness=second[key].Kg, exclude_shells=true)
    end
    out = FrameMemberCheck[]
    rho = Float64(inputs.rho)
    for (kind, members) in ((:column, struc.columns), (:beam, struc.beams))
        for (i, member) in enumerate(members)
            els = _member_frame_elements(struc, member)
            isempty(els) && (push!(out, FrameMemberCheck(kind, i, false, "no frame element")); continue)
            ok, detail = _member_resists(kind, i, member, els, struc, basic, second, solved,
                                         cases, inputs, material, col_checker, beam_checker,
                                         col_cache, beam_cache, rho)
            push!(out, FrameMemberCheck(kind, i, ok, detail))
        end
    end
    return out
end

function _cached_column_capacity!(cache_of, checker, section, material)
    id = objectid(section)
    haskey(cache_of, id) && return cache_of[id]
    cache = ACIColumnCapacityCache(1)
    precompute_capacities!(checker, cache, [section], material, MinVolume())
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

"""True when every earthquake combination and every 25% case passes."""
function _member_resists(kind, index, member, els, struc, basic, second, solved, cases,
                         inputs, material, col_checker, beam_checker, col_cache, beam_cache, rho)
    geometry = StructuralSizer.ConcreteMemberGeometry(member.base.L; Lu=member.base.Lb,
                                      kx=member.base.Kx, ky=member.base.Ky, braced=false)
    section = member.base.section
    for combo in asce7_strength_combinations
        (combo.E != 0.0 || combo.Ev != 0.0) || continue
        key = _gravity_key(combo, inputs.roof)
        set = second[key]
        lateral = solved[key]
        for (k, (direction, torsion, _)) in enumerate(cases)
            for el in els
                D = _element_forces_from_u(el, set.u[1], basic.loads[1])
                L = _element_forces_from_u(el, set.u[2], basic.loads[2])
                C = _element_forces_from_u(el, set.u[3], basic.loads[3])
                eh = _element_forces_from_u(el, lateral[k], Asap.AbstractLoad[])
                stations = _combine_member_stations(combo, inputs.roof, D, L, C, eh,
                                                    inputs.SDS, rho)
                passed = if kind === :column
                    Pu, Mux, Muy = _column_demand_values(stations)
                    demand = RCColumnDemand(index; Pu=Pu * u"N", Mux=Mux * u"N*m",
                                            Muy=Muy * u"N*m")
                    cache = _cached_column_capacity!(col_cache, col_checker, section, material)
                    is_feasible(col_checker, cache, 1, section, material.concrete, demand, geometry)
                else
                    sag, hog, Vu, Nu = _beam_demand_values(el, stations)
                    demand = RCBeamDemand(index; Mu=sag * u"N*m", Mu_neg=hog * u"N*m",
                                          Vu=Vu * u"N", Nu=Nu * u"N")
                    cache = _cached_beam_capacity!(beam_cache, beam_checker, section,
                                                   material.concrete)
                    is_feasible(beam_checker, cache, 1, section, material.concrete, demand, geometry)
                end
                passed && continue
                return false, "$(combo.name) $direction $torsion does not pass"
            end
        end
    end
    return true, ""
end

"""
Frame half of §12.2.5.8.

A flat plate is refused. Members without a reinforced-concrete section are
recorded as failing and the frame is not solved, because there is nothing to
check. When every section is sized, the frame-only model is solved and each
beam and column is checked. θ above θmax throws: §12.8.7 says the structure
shall be redesigned.
"""
function _check_interactive_frames!(struc, basic, elf, second, inputs, seismic_system)
    missing = _missing_frame_sections(struc)
    # The frame-only solve runs either way. A missing section means the
    # strength check has nothing to use; the story shear and θ are still real.
    _check_frame_only_stability!(struc, elf, second, inputs, seismic_system)
    isempty(missing) || return missing
    return _check_frame_member_strength(struc, basic, elf, second, inputs)
end
