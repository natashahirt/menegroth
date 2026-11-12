# Opening segments of a pierced wall.
#
# The ordinary-wall stage sends a wall with openings here instead of
# checking it on its gross length. The strength combinations are the
# same ones a solid pier uses.

"""
Check every pierced wall on its segments.

A solid wall stays on the gross-pier path. A wall with openings is absent
from that path. Vertical segments use [`check_pier_segment`](@ref) on the
same strength combinations as a solid pier. A `:wall` segment takes the
second-order actions when the story stiffness was built, and the first-order
actions otherwise. A `:column` segment is checked only when its own end
moments satisfy §6.6.4.3(a); then `k = 1` and the end-moment ratio uses the
§6.2.5.1 sign. Otherwise the column check is withheld. A horizontal segment longer than four times its depth uses the beam
designers. A shorter segment is one diagonal strut and one tie. On a pier
of row A1 or B4 a horizontal segment is a §18.10.7 coupling beam. ℓn/h ≥ 4
is a §18.6 beam, ℓn/h < 2 with the shear above 4λ√f′c·Acw is a diagonal
beam, and the beams in between use §18.6.3 through §18.6.5. A vertical
segment there is designed for Ve and the §21.2.4.1 φ.

# Citations
ACI 318-19 §6.6.4.3(a) (corpus: `aci-318-19`, PDF p. 81): nonsway when the
second-order increase in end moments does not exceed 5 percent.
ACI 318-19 §6.6.4.4.3 (PDF p. 81): `k = 1.0` for a nonsway member.
ACI 318-19 Table 20.5.1.3.1 (PDF p. 384): 1½ in clear cover for a column
not exposed to weather and not cast against ground.
"""
function _design_pierced_segments!(checks, struc, basic, second;
                                  material_of, boundary::Symbol, plan_axis,
                                  max_ρl::Real, max_ρt::Real,
                                  wind=nothing, elf=nothing, effects=nothing,
                                  rho=nothing, SDS=nothing,
                                  opening_edges=nothing, fc_floor=nothing,
                                  row_x=nothing, row_y=nothing)
    walls = struc.walls
    pierced = [i for (i, wall) in enumerate(walls) if !isempty(wall.openings)]
    isempty(pierced) && return (0, Float64(max_ρl), Float64(max_ρt))
    before = Dict(i => (walls[i].ρl, walls[i].ρt) for i in pierced)
    by = _shells_by_wall(struc)
    layout = wall_segment_layout(walls, struc.skeleton; shells_by_wall=by)
    isempty(layout.segments) && throw(ArgumentError(
        "ordinary wall stage: a wall has openings and the segment layout is empty."))
    roof = basic.symbols[3]
    gravity_reports = _segment_force_reports(walls, layout, basic.u, basic.loads)
    wind_loads = _wind_case_loads(struc, wind)
    wind_u = wind === nothing ? nothing :
        _stored_story_displacements(struc.asap_model, wind.displacements, length(wind.cases))
    wind_reports = _first_order_case_reports(struc, layout, wind_loads; displacements=wind_u)
    qe_loads = _seismic_case_loads(struc, elf, effects)
    qe_u = elf === nothing || effects === nothing ? nothing :
        seismic_effect_displacements(elf, effects)
    qe_reports = _first_order_case_reports(struc, layout, qe_loads; displacements=qe_u)
    prepared = _pierced_second_order(walls, layout, basic, second, wind, elf, effects)
    vertical = [seg for seg in layout.segments if seg.kind === :vertical]
    for (j, seg) in enumerate(vertical)
        owner_i = _segment_owner_index(walls, seg)
        wall = walls[owner_i]
        material = material_of(wall, owner_i)
        lw = joined_clear_length(wall, walls, owner_i) * u"m"
        Moop = _slab_moment_into_wall(struc, wall, lw)
        batches = _segment_strength_batches(
            j, roof, gravity_reports, wind_reports, qe_reports, prepared, wind, effects;
            rho, SDS)
        direction = _pier_axis_direction(wall, plan_axis)
        special = opening_edges !== nothing && effects !== nothing &&
            _pier_on_special_row(direction, row_x, row_y)
        if special
            line = wall_line_members(wall, walls)
            hw_line = ustrip(u"m", _line_height(line))
            lw_line = joined_clear_length(wall, walls, owner_i)
            flanged = _boundary_flange(
                wall, walls, owner_i, _assembly_of(struc.wall_mesh, owner_i),
                hw_line * u"m") !== nothing
            shear_actions = CombinedWallAction[]
            for batch in batches
                append!(shear_actions, batch.second_bottom)
                append!(shear_actions, batch.second_top)
            end
            # The full line height is hwcs. The segment is at or above the
            # base, so this is at least the height above its bottom section.
            terms = design_segment_special_shear!(
                wall, shear_actions, material,
                seg.s1 - seg.s0, seg.z1 - seg.z0, lw_line, hw_line, hw_line, length(line);
                flanged)
            shaped = [(b.case, nothing, vcat(b.second_bottom, b.second_top), nothing)
                      for b in batches]
            extra = special_shear_records(
                wall, owner_i, direction, terms, shaped, material)
            # Filed with the ordinary records below.
            segment_shear = extra
        else
            segment_shear = WallCheckRecord[]
        end
        records = _check_vertical_segment(
            wall, seg, batches, prepared !== nothing;
            material, wall_index=owner_i, boundary, plan_axis, direction, Moop)
        append!(records, segment_shear)
        _copy_segment_reinforcement!(walls, seg, wall)
        _file_on_segment!(checks, walls, seg, records)
        if special
            quake = CombinedWallAction[]
            for batch in batches
                for action in batch.second_bottom
                    action.combination in _BOUNDARY_EARTHQUAKE || continue
                    push!(quake, action)
                end
            end
            # §18.10.6.3 (corpus: aci-318-19, page 327) names the edges
            # around openings. This segment is its own rectangle. Its
            # height is the unsupported height of that pier.
            push!(get!(opening_edges, owner_i, SpecialBoundaryDecision[]),
                special_boundary_decision(
                    wall, walls, owner_i, nothing, quake, material;
                    fc_floor,
                    section_length = (seg.s1 - seg.s0) * u"m",
                    hu_override = (seg.z1 - seg.z0) * u"m"))
        end
    end
    horizontal = [seg for seg in layout.segments if seg.kind === :horizontal]
    for (j, seg) in enumerate(horizontal)
        owner_i = _segment_owner_index(walls, seg)
        wall = walls[owner_i]
        direction = _pier_axis_direction(wall, plan_axis)
        material = material_of(wall, owner_i)
        if effects !== nothing && row_x !== nothing && row_y !== nothing &&
                _pier_on_special_row(direction, row_x, row_y)
            batches = _segment_strength_batches(
                j, roof, gravity_reports, wind_reports, qe_reports, prepared,
                wind, effects; rho, SDS, which=:horizontal)
            at_start = CombinedWallAction[]
            at_end = CombinedWallAction[]
            for batch in batches
                append!(at_start, batch.second_bottom)
                append!(at_end, batch.second_top)
            end
            records = check_coupling_beam(
                wall, owner_i, direction, seg, at_start, at_end, material; SDS)
            _file_on_segment!(checks, walls, seg, records)
            continue
        end
        records = if seg.design === :beam || seg.design === :stm
            batches = _segment_strength_batches(
                j, roof, gravity_reports, wind_reports, qe_reports, prepared,
                wind, effects; rho, SDS, which=:horizontal)
            at_start = CombinedWallAction[]
            at_end = CombinedWallAction[]
            for batch in batches
                append!(at_start, batch.second_bottom)
                append!(at_end, batch.second_top)
            end
            recs = if seg.design === :beam
                check_spandrel_beam(wall, seg, at_start, at_end;
                                    material, wall_index=owner_i, direction)
            else
                check_spandrel_deep_beam(wall, seg, at_start, at_end;
                                    material, wall_index=owner_i, direction)
            end
            # Both routes may raise the owner wall. The other walls of the
            # segment keep that steel.
            _copy_segment_reinforcement!(walls, seg, wall)
            recs
        else
            [unchecked_horizontal_segment(wall, owner_i, direction, seg.design)]
        end
        _file_on_segment!(checks, walls, seg, records)
    end
    n_raised = 0
    ρl = Float64(max_ρl)
    ρt = Float64(max_ρt)
    for i in pierced
        haskey(checks, i) || throw(ArgumentError(
            "ordinary wall stage: wall $i has openings and no segment check was recorded."))
        ρl0, ρt0 = before[i]
        (walls[i].ρl > ρl0 + 1e-12 || walls[i].ρt > ρt0 + 1e-12) && (n_raised += 1)
        ρl = max(ρl, walls[i].ρl)
        ρt = max(ρt, walls[i].ρt)
    end
    return (n_raised, ρl, ρt)
end

"Shell triangles of each wall, in wall-index order."
function _shells_by_wall(struc)
    by = [Asap.ShellTri3[] for _ in struc.walls]
    for pier in struc.wall_mesh.piers
        append!(by[pier.wall_index], pier.shells)
    end
    return by
end

"One [`segment_opening_forces`](@ref) report per displacement."
function _segment_force_reports(walls, layout, displacements, load_lists)
    length(displacements) == length(load_lists) || throw(ArgumentError(
        "ordinary wall stage: $(length(displacements)) displacements and " *
        "$(length(load_lists)) load lists."))
    return [segment_opening_forces(walls, layout, displacements[i];
                                   loads=load_lists[i], fixed_end_from_loads=true)
            for i in eachindex(displacements)]
end

"Second-order gravity, wind, and seismic reports. `nothing` when that solve was not built."
function _pierced_second_order(walls, layout, basic, second, wind, elf, effects)
    second === nothing && return nothing
    isempty(second) && return nothing
    sample = first(values(second))
    if wind !== nothing && sample.nwind != length(wind.cases)
        throw(ArgumentError(
            "ordinary wall stage: the story stiffness has $(sample.nwind) wind " *
            "components and the wind analysis has $(length(wind.cases)) cases."))
    end
    nqe = effects === nothing ? 0 : length(effects)
    sample.nqe == nqe || throw(ArgumentError(
        "ordinary wall stage: the story stiffness has $(sample.nqe) seismic " *
        "components and $(nqe) seismic effects."))
    effects !== nothing && elf === nothing && throw(ArgumentError(
        "ordinary wall stage: seismic segment forces need the ELF analysis."))
    gravity = Dict{Any, Vector{SegmentForceReport}}()
    wind_reports = [Dict{Any, SegmentForceReport}() for _ in 1:sample.nwind]
    qe_reports = [Dict{Any, SegmentForceReport}() for _ in 1:sample.nqe]
    # The lateral component was solved on `K_G`. Nodal story forces have no
    # element fixed-end force, matching `_second_order_lateral`.
    empty_loads = Asap.AbstractLoad[]
    for (key, set) in second
        gravity[key] = _segment_force_reports(walls, layout, set.u[1:3], basic.loads)
        for i in 1:set.nwind
            wind_reports[i][key] = segment_opening_forces(
                walls, layout, set.u[3 + i];
                loads=empty_loads, fixed_end_from_loads=true)
        end
        for k in 1:set.nqe
            qe_reports[k][key] = segment_opening_forces(
                walls, layout, set.u[3 + set.nwind + k];
                loads=empty_loads, fixed_end_from_loads=true)
        end
    end
    return (gravity=gravity, wind=wind_reports, qe=qe_reports)
end

"Unfactored dead, floor live, and roof actions at the two ends of vertical segment `j`."
function _segment_gravity_ends(reports, j::Int, roof::Symbol; which::Symbol=:vertical)
    length(reports) == 3 || throw(ArgumentError(
        "ordinary wall stage: a segment gravity cut needs three basic cases."))
    faces = [_report_end_pair(reports[i], j, which) for i in 1:3]
    return (
        PierGravityActions(roof, faces[1][1], faces[2][1], faces[3][1]),
        PierGravityActions(roof, faces[1][2], faces[2][2], faces[3][2]),
    )
end

"Bottom and top, or spandrel start and end, of one segment in a force report."
function _report_end_pair(report, j::Int, which::Symbol)
    if which === :vertical
        j <= length(report.vertical) || throw(ArgumentError(
            "ordinary wall stage: vertical segment $j is outside the force report."))
        row = report.vertical[j]
        return row.bottom, row.top
    elseif which === :horizontal
        j <= length(report.horizontal) || throw(ArgumentError(
            "ordinary wall stage: horizontal segment $j is outside the force report."))
        row = report.horizontal[j]
        return _spandrel_wall_action(row.at_start), _spandrel_wall_action(row.at_end)
    else
        throw(ArgumentError(
            "ordinary wall stage: a segment end is :$which. Use :vertical or :horizontal."))
    end
end

function _spandrel_wall_action(action::SpandrelEndAction)
    return WallAction(action.N, action.V, action.M, action.Vo, action.Mo)
end

"""
Design one coupling beam and return its check records.

ℓn/h ≥ 4 is §18.6, including the width and span limits. A beam between the
two limits uses §18.6.3 through §18.6.5. ℓn/h < 2 with Vu at or above
4λ√f′c·Acw is a diagonal beam. `Vu` for that choice is the largest earthquake
shear. Flexure and diagonal strength are designed for the largest factored
action.

# Citation
ACI 318-19 §18.10.7.1–§18.10.7.4 (corpus: aci-318-19, PDF pages 332–334).
"""
function check_coupling_beam(wall, wall_index, direction, seg, at_start, at_end, material; SDS=nothing)
    (isempty(at_start) || isempty(at_end)) && throw(ArgumentError(
        "coupling beam: both ends need a strength combination."))
    ℓn = (seg.s1 - seg.s0) * u"m"
    h = (seg.z1 - seg.z0) * u"m"
    bw = wall.thickness
    Vu_eq = 0.0
    Mu = 0.0
    Vu = 0.0
    Pu = 0.0
    flexure_action = first(at_start)
    for action in Iterators.flatten((at_start, at_end))
        abs(action.M) > Mu && (Mu = abs(action.M); flexure_action = action)
        abs(action.V) > Vu && (Vu = abs(action.V))
        Pu = max(Pu, action.N)
        action.combination in _BOUNDARY_EARTHQUAKE || continue
        Vu_eq = max(Vu_eq, abs(action.V))
    end
    fc = material.concrete.fc′
    fy = material.rebar.Fy
    fyt = material.transverse.Fy
    Es = material.rebar.E
    route = coupling_beam_route(ℓn, h, Vu_eq * u"N", material.concrete.λ, fc, h * bw)
    if route.route === :diagonal
        return [_coupling_diagonal_record(
            wall, wall_index, direction, flexure_action, ℓn, h, bw,
            Vu * u"N", fc, fy, fyt, route)]
    end
    Vg = _coupling_gravity_shear(at_start, at_end, SDS)
    designed = design_special_coupling_beam(
        ℓn, h, bw, Mu * u"N*m",
        _coupling_end_axial(at_start, SDS) * u"N",
        _coupling_end_axial(at_end, SDS) * u"N",
        Vg * u"N", max(Pu, 0.0) * u"N",
        fc, fy, fyt, Es; λ=material.concrete.λ,
        dimensions = route.route === :moment_frame)
    return _coupling_moment_records(
        wall, wall_index, direction, flexure_action, Mu, designed, route)
end

"Largest factored gravity shear, plus 0.2 SDS times the unfactored dead shear."
function _coupling_gravity_shear(at_start, at_end, SDS)
    grav = 0.0
    dead = 0.0
    for action in Iterators.flatten((at_start, at_end))
        combo = _combo_named(action.combination)
        (combo.E == 0 && combo.W == 0 && combo.Ev == 0) || continue
        grav = max(grav, abs(action.V))
        action.combination === :strength_1_4D && (dead = max(dead, abs(action.V) / 1.4))
    end
    ev = SDS === nothing ? 0.0 : 0.2 * Float64(SDS) * dead
    return grav + ev
end

"Most compressive axial at one end. Vertical earthquake is added to the dead compression."
function _coupling_end_axial(actions, SDS)
    best = 0.0
    dead = 0.0
    for action in actions
        combo = _combo_named(action.combination)
        (combo.E == 0 && combo.W == 0 && combo.Ev == 0) || continue
        best = max(best, action.N)
        action.combination === :strength_1_4D && (dead = max(dead, action.N / 1.4))
    end
    ev = SDS === nothing ? 0.0 : 0.2 * Float64(SDS) * max(dead, 0.0)
    return best + ev
end

function _coupling_moment_records(wall, wall_index, direction, action, Mu, designed, route)
    clause = route.route === :moment_frame ? "ACI 318-19 18.6" : "ACI 318-19 18.6.3–18.6.5"
    records = WallCheckRecord[]
    if designed.dimensions !== nothing
        dims = designed.dimensions
        width_ratio = ustrip(u"m", dims.width_limit) / max(ustrip(u"m", wall.thickness), 1e-9)
        push!(records, WallCheckRecord(
            wall_index, wall.story, direction, :opening,
            action.combination, action.alternative,
            "coupling-beam dimensions", dims.span_ok && dims.width_ok, width_ratio,
            ustrip(u"m", wall.thickness), ustrip(u"m", dims.width_limit),
            clause * " 18.6.2.1; ℓn/h = $(round(route.aspect; digits=2))"))
    end
    φMn = ustrip(u"N*m", designed.φMn)
    push!(records, WallCheckRecord(
        wall_index, wall.story, direction, :opening,
        action.combination, action.alternative,
        "coupling-beam flexure", designed.flexure_ok,
        φMn > 0 ? Mu / φMn : Inf, Mu, φMn,
        clause * (designed.bars === nothing ? "" :
            "; $(designed.bars.n_bars) No. $(designed.bars.bar_size) each face") *
        (isempty(designed.reason) ? "" : "; " * designed.reason)))
    Ve = ustrip(u"N", designed.Ve)
    φVn = ustrip(u"N", designed.φVn)
    hoop_in = round(ustrip(u"inch", designed.stirrup_spacing); digits=1)
    push!(records, WallCheckRecord(
        wall_index, wall.story, direction, :opening,
        action.combination, action.alternative,
        "coupling-beam shear", designed.shear_ok,
        φVn > 0 ? Ve / φVn : Inf, Ve, φVn,
        clause * " 18.6.5; hoops No. $(designed.stirrup_bar) at $(hoop_in) in" *
        (designed.vc_omitted ? "; Vc = 0" : "")))
    return records
end

function _coupling_diagonal_record(wall, wall_index, direction, action, ℓn, h, bw, Vu, fc, fy, fyt, route)
    designed = design_diagonal_coupling_beam(ℓn, h, bw, Vu, fc, fy, fyt)
    demand = ustrip(u"N", Vu)
    capacity = ustrip(u"N", designed.φVn)
    bars = designed.bars > 0 ? "; $(designed.bars) No. $(designed.bar) in $(designed.layers) layers" : ""
    tie_in = round(ustrip(u"inch", designed.tie_spacing); digits=1)
    tie = designed.tie > 0 ? "; No. $(designed.tie) ties at $(tie_in) in" : ""
    return WallCheckRecord(
        wall_index, wall.story, direction, :opening,
        action.combination, action.alternative,
        "coupling-beam diagonal", designed.ok,
        capacity > 0 ? demand / capacity : Inf, demand, capacity,
        "ACI 318-19 18.10.7.4, 21.2.4.4 (φ = 0.85); ℓn/h = $(round(route.aspect; digits=2))" *
        bars * tie * (isempty(designed.reason) ? "" : "; " * designed.reason))
end

"First-order and second-order strength actions at both ends, one batch per basic case."
function _segment_strength_batches(j, roof, gravity_reports, wind_reports, qe_reports,
                                 prepared, wind, effects; rho, SDS, which::Symbol=:vertical)
    gb, gt = _segment_gravity_ends(gravity_reports, j, roof; which)
    fb = _gravity_strength_actions(gb)
    ft = _gravity_strength_actions(gt)
    batches = []
    if prepared === nothing
        push!(batches, (case=:D, first_bottom=fb, first_top=ft,
                        second_bottom=fb, second_top=ft))
    else
        sb, st = _paired_gravity(j, roof, prepared.gravity; which)
        push!(batches, (case=:D, first_bottom=fb, first_top=ft,
                        second_bottom=sb, second_top=st))
    end
    if wind !== nothing
        for (i, case) in enumerate(wind.cases)
            wb, wt = _report_end_pair(wind_reports[i], j, which)
            first_b = _wind_strength_actions(gb, wb)
            first_t = _wind_strength_actions(gt, wt)
            if prepared === nothing
                second_b, second_t = first_b, first_t
            else
                second_b, second_t = _paired_wind(j, roof, prepared.gravity, prepared.wind[i]; which)
            end
            push!(batches, (case=_wind_case_symbol(i, case),
                            first_bottom=first_b, first_top=first_t,
                            second_bottom=second_b, second_top=second_t))
        end
    end
    if effects !== nothing
        (rho === nothing || SDS === nothing) && throw(ArgumentError(
            "ordinary wall stage: a seismic segment check needs rho and SDS."))
        for k in eachindex(effects)
            qb, qt = _report_end_pair(qe_reports[k], j, which)
            first_b = _seismic_strength_actions(gb, qb, rho, SDS)
            first_t = _seismic_strength_actions(gt, qt, rho, SDS)
            if prepared === nothing
                second_b, second_t = first_b, first_t
            else
                second_b, second_t = _paired_seismic(
                    j, roof, prepared.gravity, prepared.qe[k], rho, SDS; which)
            end
            push!(batches, (case=effects[k].label,
                            first_bottom=first_b, first_top=first_t,
                            second_bottom=second_b, second_top=second_t))
        end
    end
    return batches
end

function _paired_gravity(j, roof, gravity_by_key; which::Symbol=:vertical)
    bottom = CombinedWallAction[]
    top = CombinedWallAction[]
    for (combo, alt, key) in _gravity_readings(roof)
        haskey(gravity_by_key, key) || throw(ArgumentError(
            "ordinary wall stage: no second-order segment cut for gravity $key."))
        gb, gt = _segment_gravity_ends(gravity_by_key[key], j, roof; which)
        push!(bottom, combine_wall_action(combo, gb; alternative=alt))
        push!(top, combine_wall_action(combo, gt; alternative=alt))
    end
    return bottom, top
end

function _paired_wind(j, roof, gravity_by_key, wind_by_key; which::Symbol=:vertical)
    bottom = CombinedWallAction[]
    top = CombinedWallAction[]
    for (combo, alt, key) in _wind_readings(roof)
        gb, gt = _segment_gravity_ends(gravity_by_key[key], j, roof; which)
        wb, wt = _report_end_pair(wind_by_key[key], j, which)
        push!(bottom, combine_wall_action(combo, gb; wind=wb, alternative=alt))
        push!(top, combine_wall_action(combo, gt; wind=wt, alternative=alt))
    end
    return bottom, top
end

function _paired_seismic(j, roof, gravity_by_key, qe_by_key, rho, SDS; which::Symbol=:vertical)
    bottom = CombinedWallAction[]
    top = CombinedWallAction[]
    for (combo, alt, key) in _seismic_readings(roof)
        gb, gt = _segment_gravity_ends(gravity_by_key[key], j, roof; which)
        qb, qt = _report_end_pair(qe_by_key[key], j, which)
        push!(bottom, combine_wall_action(combo, gb; qe=qb, rho, SDS, alternative=alt))
        push!(top, combine_wall_action(combo, gt; qe=qt, rho, SDS, alternative=alt))
    end
    return bottom, top
end

function _wind_case_loads(struc, wind)
    wind === nothing && return Vector{Asap.AbstractLoad}[]
    return [_wind_loads(struc, wind.levels, c.Fx_kN, c.Fy_kN, c.Mz_kN_m, wind.centroids)
            for c in wind.cases]
end

function _seismic_case_loads(struc, elf, effects)
    effects === nothing && return Vector{Asap.AbstractLoad}[]
    elf === nothing && throw(ArgumentError(
        "ordinary wall stage: seismic segment forces need the ELF analysis."))
    return [seismic_effect_loads(struc, elf, e) for e in effects]
end

"First-order cuts of each lateral case. Empty when there is no case."
function _first_order_case_reports(struc, layout, loads; displacements=nothing)
    isempty(loads) && return SegmentForceReport[]
    u = displacements === nothing ?
        Asap.solve(struc.asap_model, loads, lateral_solve_links(struc)) : displacements
    length(u) == length(loads) || throw(ArgumentError(
        "ordinary wall stage: $(length(u)) stored displacements and " *
        "$(length(loads)) lateral cases."))
    return _segment_force_reports(struc.walls, layout, u, loads)
end

"""
Check one vertical segment.

A column segment needs the story stiffness and a passing §6.6.4.3(a) test.
`k` is then 1. The cover is the column row of Table 20.5.1.3.1. A wall
segment is the ordinary-wall check on the design actions.
"""
function _check_vertical_segment(wall, seg, batches, have_second::Bool;
                               material, wall_index::Int, boundary::Symbol,
                               plan_axis, direction::Symbol, Moop)
    if seg.design === :column
        nonsway = have_second && all(batch -> story_end_moments_are_nonsway(
            batch.first_bottom, batch.first_top,
            batch.second_bottom, batch.second_top), batches)
        nonsway || return [withheld_column_segment(wall, wall_index, direction)]
        # ACI 318-19 Table 20.5.1.3.1 (corpus: aci-318-19, PDF p. 384).
        # Beams, columns, pedestals, and tension ties, not exposed to weather
        # and not cast against ground: 1½ in.
        cover = 1.5u"inch"
        ratio = _governing_segment_ratio(batches)
        records = WallCheckRecord[]
        for batch in batches
            append!(records, check_pier_segment(
                wall, seg, batch.second_bottom, batch.second_top;
                material, wall_index, case=batch.case, boundary, plan_axis,
                k=1.0, braced=true, M1_over_M2=ratio, cover))
        end
        return records
    end
    seg.design === :wall || throw(ArgumentError(
        "ordinary wall stage: a vertical segment is routed :$(seg.design)."))
    records = WallCheckRecord[]
    for batch in batches
        append!(records, check_pier_segment(
            wall, seg, batch.second_bottom, batch.second_top;
            material, wall_index, case=batch.case, boundary, plan_axis, Moop))
    end
    return records
end

"Most negative end-moment ratio across the design combinations, both axes."
function _governing_segment_ratio(batches)
    ratio = 0.0
    for batch in batches
        for i in eachindex(batch.second_bottom)
            b = batch.second_bottom[i]
            t = batch.second_top[i]
            r = min(segment_end_moment_ratio(b.M, t.M),
                    segment_end_moment_ratio(b.Mo, t.Mo))
            r < ratio && (ratio = r)
        end
    end
    return ratio
end

function _segment_owner_index(walls, seg)
    isempty(seg.wall_indices) && throw(ArgumentError(
        "ordinary wall stage: a $(seg.kind) segment has no wall."))
    return argmin(j -> (walls[j].story, j), seg.wall_indices)
end

function _copy_segment_reinforcement!(walls, seg, owner)
    for i in seg.wall_indices
        walls[i].ρl = owner.ρl
        walls[i].ρt = owner.ρt
    end
    return nothing
end

"File `records` on every wall the segment belongs to."
function _file_on_segment!(checks, walls, seg, records)
    for i in seg.wall_indices
        bucket = get!(checks, i, WallCheckRecord[])
        wall = walls[i]
        for rec in records
            if rec.wall_index == i && rec.story == wall.story
                push!(bucket, rec)
            else
                push!(bucket, WallCheckRecord(
                    i, wall.story, rec.direction, rec.case, rec.combination,
                    rec.alternative, rec.check, rec.passed, rec.ratio,
                    rec.demand, rec.capacity, rec.clause))
            end
        end
    end
    return nothing
end
