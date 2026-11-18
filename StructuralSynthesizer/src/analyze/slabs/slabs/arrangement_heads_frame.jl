# Solid heads on a rib arrangement, checked on the solved building model.
#
# The building model already holds the ribs, the girders, the columns, and
# the solid-head pieces, with their sections. The checks read their demands
# from it for the full load and every pattern case (ACI 318-11 §13.7.6,
# corpus: aci-318-11, page 261), so the head sees the same load path the ribs
# were sized on.
#
# Punching at the column takes only the shear and moment the slab's own
# members deliver to the joint. Beams framing into the column carry their
# share, and the remainder is checked as for flat slabs (ACI 318-11 R13.6.8
# and §13.6.8.4, page 257). The section is [`column_head_section`](@ref), at
# d/2 outside the head outline (§11.11.1.2, page 200). One-way shear of each
# rib leaving the head is at that rib's own d from the face (§11.1.3.1,
# page 166), on the piece that holds that point. Hogging is at the face.

"""
    _element_end_actions(el, u, loads) -> Vector{Float64}

Global end actions on `el`, start node then end node, force then moment:
`K u + Q`, where `Q` is the fixed-end force of `loads` on this element.
The force `el` puts on a node is the negative of its block.
"""
function _element_end_actions(el, u, loads)
    F = el.K * u[el.globalID]
    for ld in loads
        ld isa Asap.ElementLoad || continue
        ld.element === el || continue
        F .+= transpose(el.R) * Asap.q(ld)
    end
    return F
end

"""
    _slab_joint_demand(model, members, u, load_map) -> (Vu, (Mx, My))

Downward force, N, and global moment, N·m, that `members` put on the joint
they share. `members` are `(element index, joint at start)`.
"""
function _slab_joint_demand(model, members, u, load_map)
    F = zeros(3)
    M = zeros(3)
    for (k, at_start) in members
        el = model.frame_elements[k]
        Fe = _element_end_actions(el, u, _case_loads(load_map, el))
        o = at_start ? 0 : 6
        @views F .-= Fe[(o + 1):(o + 3)]
        @views M .-= Fe[(o + 4):(o + 6)]
    end
    return -F[3], (M[1], M[2])
end

"""Frame elements at elevation `z`, and the elements meeting each node."""
function _level_frame_adjacency(model, z::Float64; tol::Float64 = 1e-3)
    adj = Dict{UInt, Vector{Int}}()
    for (k, el) in enumerate(model.frame_elements)
        ps, pe = _node_xyz_m(el.nodeStart), _node_xyz_m(el.nodeEnd)
        (abs(ps[3] - z) <= tol && abs(pe[3] - z) <= tol) || continue
        push!(get!(adj, objectid(el.nodeStart), Int[]), k)
        push!(get!(adj, objectid(el.nodeEnd), Int[]), k)
    end
    return adj
end

"""`(element, joint at start)` for each element in `ks` with an end at `xyz`."""
function _elements_ending_at(model, ks, xyz; tol::Float64 = 1e-3)
    out = Tuple{Int, Bool}[]
    for k in ks
        el = model.frame_elements[k]
        ps, pe = _node_xyz_m(el.nodeStart), _node_xyz_m(el.nodeEnd)
        if all(abs(ps[i] - xyz[i]) <= tol for i in 1:3)
            push!(out, (k, true))
        elseif all(abs(pe[i] - xyz[i]) <= tol for i in 1:3)
            push!(out, (k, false))
        end
    end
    return out
end

"""Rib web `(bw, d, h)` of beam `bi` when it is a concrete rib of `level`, else `nothing`."""
function _level_rib_dims(struc, level, bi)
    bi === nothing && return nothing
    beam = struc.beams[bi]
    _level_rib(level, beam) || return nothing
    sec = section(beam)
    sec === nothing && throw(ArgumentError("rib beam $bi leaves a solid head and is not sized"))
    return _rib_web_dims(sec)
end

"""Element of `path` that holds the point `x` metres from its start."""
function _frame_path_element_at(model, path, x::Float64)
    s = 0.0
    for (k, _) in path
        s += Asap.ElementProps(model.frame_elements[k]).L
        x <= s + 1e-9 && return k
    end
    return path[end][1]
end

"""Length, metres, of a path of frame elements."""
_frame_path_length(model, path) =
    sum(Asap.ElementProps(model.frame_elements[k]).L for (k, _) in path)

"""
The concrete ribs of `level` that leave `head`, on the building frame.

Each is `(path, outward)`: `path` walks collinear frame elements away from
the head face, as `(element index, from start)`. A girder leaving the head is
a beam with its own checks and is not listed.
"""
function _frame_leaving_ribs(struc, level, arr, owners, head, z, adj, element_beam)
    model = struc.asap_model
    ribs = NamedTuple[]
    for rib in _arrangement_leaving_ribs(arr, head, length(arr.edges))
        e1, from_start = rib.path[1]
        a, b = arr.edges[e1]
        face = arr.nodes[from_start ? a : b]
        ks = _frame_element_indices(struc, owners[e1])
        hits = _elements_ending_at(model, ks, (face[1], face[2], z))
        isempty(hits) && throw(ArgumentError(
            "the rib leaving the solid head at $(face) m has no frame element at the face"))
        k, at_start = hits[1]
        _level_rib_dims(struc, level, get(element_beam, k, nothing)) === nothing && continue
        push!(ribs, (path = _collinear_path(model, adj, k, at_start), outward = rib.outward))
    end
    return ribs
end

"""
    check_arrangement_head_on_frame(struc, level, arr, owners, head, cases; kwargs...)
        -> NamedTuple

Column punching, rib one-way shear, and stem compression of one head, from
the solved building model, governed over `cases` (`(u, load map)` pairs).

`members` are this level's rib elements at the column joint. `q_dead` is the
smallest factored dead pressure on the slab, subtracted over the area inside
the punching section, which every case carries. The result has the fields of
[`govern_solid_head_checks`](@ref), plus `section`, `column_check`, and
`n_cases`.
"""
function check_arrangement_head_on_frame(struc, level, arr, owners, head, cases;
                                         z::Float64, adj, element_beam, members,
                                         q_dead::Pressure,
                                         concrete::StructuralSizer.Concrete,
                                         d_head::Length, fy::Pressure,
                                         topping::Union{Nothing, Length} = nothing,
                                         free_loops = ())
    model = struc.asap_model
    section = StructuralSizer.column_head_section(arr, head, d_head; free_loops = free_loops)
    pts = [(p[1] * u"m", p[2] * u"m") for p in section.points]
    αs = section.closed ? 40 : 30
    inside = uconvert(u"N", q_dead * section.area)
    ribs = _frame_leaving_ribs(struc, level, arr, owners, head, z, adj, element_beam)
    worst = nothing
    all_ok = true
    for (u, load_map) in cases
        Vu_N, (Mx, My) = _slab_joint_demand(model, members, u, load_map)
        # The slab's upward pull on a column is not a downward punching shear.
        Vu = max(Vu_N * u"N" - inside, 0.0u"N")
        column = StructuralSizer.punching_check_general(
            Vu, Mx * u"N*m", My * u"N*m", d_head, concrete.fc′, pts;
            closed = section.closed, αs = αs, λ = concrete.λ)
        col = (ok = column.ok, ratio = column.utilization, direction = column.direction)
        one_way = NamedTuple[]
        hogging = NamedTuple[]
        for rib in ribs
            face = _level_rib_dims(struc, level, element_beam[rib.path[1][1]])
            reach = _frame_path_length(model, rib.path)
            x = min(ustrip(u"m", face[2]), max(reach - 1e-6, 0.0))
            at = something(_level_rib_dims(struc, level,
                                           get(element_beam, _frame_path_element_at(model, rib.path, x),
                                               nothing)), face)
            Vu_rib = _path_shear(model, rib.path, u, load_map, x)
            chk = StructuralSizer.check_rib_shear_at_head(Vu_rib, at[1], at[2], concrete.fc′;
                                                          λ = concrete.λ)
            push!(one_way, merge(chk, (outward = rib.outward, bw = at[1], d = at[2])))
            stem = topping === nothing ? nothing : face[3] - topping
            if stem !== nothing && stem < zero(stem)
                throw(ArgumentError("the topping is deeper than the rib, got $topping in $(face[3])"))
            end
            Mu = _path_hogging(model, rib.path, u, load_map, 0.0)
            hog = StructuralSizer.check_rib_hogging_at_head(Mu, face[1], face[2], concrete.fc′, fy;
                                                            stem = stem)
            push!(hogging, merge(hog, (outward = rib.outward, bw = face[1], d = face[2])))
        end
        governed = StructuralSizer.govern_solid_head_checks(col, one_way, hogging; Vu = Vu)
        all_ok &= governed.ok
        if worst === nothing || governed.ratio > worst.governed.ratio
            worst = (governed = governed, column = column)
        end
    end
    return merge(worst.governed, (ok = all_ok, section = section, column_check = worst.column,
                                  n_cases = length(cases)))
end

"""Load cases the head checks envelope: the full load, then each pattern case."""
function _head_frame_cases(struc, params)
    model = struc.asap_model
    cases = Tuple{Vector{Float64}, Any}[(model.u, Asap.get_elemental_loads(model))]
    patterns = _pattern_demand_cases(struc, params)
    patterns === nothing || append!(cases, patterns)
    return cases
end

"""Smallest factored dead pressure on the slab's cells."""
function _slab_factored_dead_pressure(struc, slab, params)
    combo = governing_combo(params)
    return minimum(uconvert(u"Pa", combo.D * (struc.cells[ci].sdl + struc.cells[ci].self_weight))
                   for ci in slab.cell_indices)
end

"""
    check_building_heads(struc, slab, level, arr, owners, heads, params; kwargs...)
        -> Vector{NamedTuple}

[`check_arrangement_head_on_frame`](@ref) for each head of one slab, on the
building model as solved now.
"""
function check_building_heads(struc, slab, level, arr, owners, heads, params;
                              concrete, d_head, fy, topping, free_loops)
    model = struc.asap_model
    z = _slab_face_z_m(struc, slab)
    adj = _level_frame_adjacency(model, z)
    element_beam = _element_beam_map(struc)
    on_level = Set(level_member_indices(struc, level))
    rib_elements = Int[k for (k, bi) in element_beam
                       if bi in on_level && _level_rib(level, struc.beams[bi])]
    cases = _head_frame_cases(struc, params)
    q_dead = _slab_factored_dead_pressure(struc, slab, params)
    return map(heads) do head
        xyz = (head.column[1], head.column[2], z)
        members = _elements_ending_at(model, rib_elements, xyz)
        check_arrangement_head_on_frame(struc, level, arr, owners, head, cases;
            z = z, adj = adj, element_beam = element_beam, members = members,
            q_dead = q_dead, concrete = concrete, d_head = d_head, fy = fy,
            topping = topping, free_loops = free_loops)
    end
end

"""
    resolve_building_heads!(struc, slab, level, arr, owners, heads, params; kwargs...)
        -> NamedTuple

Check each head on the building model, grow every failing head one step,
re-solve the building, and check again.

A step follows [`_head_growth_directions`](@ref), skips bays another head
holds, and is refused when the solid bays would pass `max_solid_fraction`
or when the grown outline is not one critical section. A head whose growth
ratio does not fall after its step stops growing. Returns `(ok, heads,
checks, steps, stop)` with `stop` one of `:passed`, `:stopped`, `:solid_cap`.
"""
function resolve_building_heads!(struc, slab, level, arr, owners, heads, params;
                                 concrete, d_head, fy, topping, free_loops,
                                 max_solid_fraction = nothing)
    heads = copy(heads)
    kw = (concrete = concrete, d_head = d_head, fy = fy, topping = topping,
          free_loops = free_loops)
    stuck = falses(length(heads))
    capped = false
    steps = 0
    checks = check_building_heads(struc, slab, level, arr, owners, heads, params; kw...)
    while true
        all(c -> c.ok, checks) && return (ok = true, heads = heads, checks = checks,
                                          steps = steps, stop = :passed)
        open = [i for i in eachindex(heads) if _head_grows(checks[i]) && !stuck[i]]
        grew = Int[]
        for i in open
            taken = [b for (k, h) in enumerate(heads) if k != i for b in h.bays]
            grown = nothing
            for dir in _head_growth_directions(checks[i])
                step = try
                    StructuralSizer.grow_checked_column_head(arr, heads[i],
                        merge(checks[i], (direction = dir,)); taken = taken, free_loops = free_loops)
                catch err
                    err isa ArgumentError || rethrow()
                    nothing
                end
                (step === nothing || step.bays == heads[i].bays) && continue
                trial = copy(heads)
                trial[i] = step
                # ENGINEERING JUDGMENT: growth stops once the solid bays cover
                # more than `max_solid_fraction` of the rib arrangement.
                if max_solid_fraction !== nothing &&
                        _solid_fraction(arr, trial) > Float64(max_solid_fraction) + 1e-9
                    capped = true
                    continue
                end
                ok_outline = try
                    StructuralSizer.column_head_section(arr, step, d_head; free_loops = free_loops)
                    true
                catch err
                    err isa ArgumentError || rethrow()
                    false
                end
                ok_outline || continue
                grown = step
                break
            end
            if grown === nothing
                stuck[i] = true
                _trace_head_step(heads[i], checks[i], "no side can grow")
            else
                _trace_head_step(heads[i], checks[i], "grows to $(length(grown.bays)) bays")
                heads[i] = grown
                push!(grew, i)
            end
        end
        isempty(grew) && return (ok = false, heads = heads, checks = checks, steps = steps,
                                 stop = capped ? :solid_cap : :stopped)
        steps += 1
        steps <= length(arr.bays) || throw(ArgumentError(
            "the solid heads grew once for every bay and have not passed"))
        before = checks
        level.solid_heads = heads
        _expand_solid_to_heads!(struc, slab, level, arr, owners, heads)
        apply_solid_head_frame_sections!(struc)
        _ensure_frame_demands!(struc)
        checks = check_building_heads(struc, slab, level, arr, owners, heads, params; kw...)
        for i in grew
            _head_growth_ratio(checks[i]) < _head_growth_ratio(before[i]) - 1e-9 ||
                (stuck[i] = true)
        end
    end
end
