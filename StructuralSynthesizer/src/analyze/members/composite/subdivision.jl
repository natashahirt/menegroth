# -----------------------------------------------------------------------------
# Composite mesh: hogging and sagging on one bay, openings, unshored stages
# -----------------------------------------------------------------------------

const _COMPOSITE_MESH_KEY = -1
const _N_COMPOSITE_CHILDREN = 4

"""Analysis-cache bucket for the composite beam mesh. Key 0 is the pattern solve."""
function _composite_mesh(struc::BuildingStructure)
    return get(struc._analysis_caches, _COMPOSITE_MESH_KEY, nothing)
end

function _composite_mesh!(struc::BuildingStructure)
    return get!(() -> Dict{Symbol, Any}(), struc._analysis_caches, _COMPOSITE_MESH_KEY)
end

"""
Record the section names accepted on one composite sizing pass.

`:section_passes` is a vector of `(pass, names)` pairs. Pass 2 confirms
the section on its own solved deflection. That section may be the pass-1
choice or the same steel shape with the stud layout the deflection check
counted. A third entry is the confirmation of a section the catalog chose
after that confirmation failed. A failed confirmation is not kept.
"""
function _note_composite_section_pass!(struc::BuildingStructure, pass::Int, sections)
    mesh = _composite_mesh(struc)
    mesh === nothing && return nothing
    hist = get!(() -> Vector{Tuple{Int,Vector{Union{Nothing,String}}}}(), mesh, :section_passes)
    names = Vector{Union{Nothing,String}}(undef, length(sections))
    for (i, s) in pairs(sections)
        names[i] = (s === nothing || !hasproperty(s, :name) || getfield(s, :name) === nothing) ?
            nothing : String(getfield(s, :name))
    end
    push!(hist, (pass, names))
    return hist
end

"""
Element indices that carry this skeleton edge.

One index, the edge itself, until [`_subdivide_composite_edge!`](@ref) replaces
the loaded span with children. The parent stays at `edge_idx` so every reader
that indexes `model.frame_elements` by skeleton edge still finds a slot. Its section
is zero, so it adds no stiffness.
"""
function _frame_element_indices(struc::BuildingStructure, edge_idx::Int)
    mesh = _composite_mesh(struc)
    mesh === nothing && return [edge_idx]
    kids = get(get(mesh, :children, Dict{Int, Vector{Int}}()), edge_idx, nothing)
    return kids === nothing ? [edge_idx] : kids
end

_release_symbol(el::Asap.Element{Asap.FixedFixed}) = :fixedfixed
_release_symbol(el::Asap.Element{Asap.FreeFixed}) = :freefixed
_release_symbol(el::Asap.Element{Asap.FixedFree}) = :fixedfree
_release_symbol(el::Asap.Element{Asap.FreeFree}) = :freefree
_release_symbol(el::Asap.Element) = :joist

"""End release of each child. A released end stays on the child that touches it."""
function _child_releases(parent_rel::Symbol, n::Int)
    n == 1 && return [parent_rel]
    parent_rel === :joist && return fill(:joist, n)
    rels = fill(:fixedfixed, n)
    (parent_rel === :freefixed || parent_rel === :freefree) && (rels[1] = :freefixed)
    (parent_rel === :fixedfree || parent_rel === :freefree) && (rels[end] = :fixedfree)
    return rels
end

function _width_at(ld::Asap.TributaryLoad, s::Float64)
    pos = ld.positions
    w = ld.widths
    s <= pos[1] && return w[1]
    s >= pos[end] && return w[end]
    i = searchsortedlast(pos, s)
    i >= length(pos) && return w[end]
    denom = pos[i + 1] - pos[i]
    t = denom == 0 ? 0.0 : (s - pos[i]) / denom
    return w[i] + t * (w[i + 1] - w[i])
end

"""One tributary load per child, covering that child's fraction of the parent."""
function _split_tributary(ld::Asap.TributaryLoad, children)
    n = length(children)
    out = Asap.TributaryLoad[]
    for (i, child) in enumerate(children)
        a = (i - 1) / n
        b = i / n
        pts = Float64[a]
        for p in ld.positions
            a + 1e-12 < p < b - 1e-12 && push!(pts, p)
        end
        push!(pts, b)
        local_pos = [(p - a) / (b - a) for p in pts]
        local_pos[1] = 0.0
        local_pos[end] = 1.0
        widths = [_width_at(ld, a + s * (b - a)) for s in local_pos]
        push!(out, Asap.TributaryLoad(child, local_pos, widths, ld.pressure,
                                      ld.direction, ld.id))
    end
    return out
end

function _split_element_load(ld, children)
    if ld isa Asap.TributaryLoad
        return _split_tributary(ld, children)
    elseif ld isa Asap.GravityLoad
        return [Asap.GravityLoad(c, ld.factor, ld.id) for c in children]
    elseif ld isa Asap.LineLoad
        return [Asap.LineLoad(c, ld.value, ld.id) for c in children]
    elseif ld isa Asap.PointLoad
        n = length(children)
        i = clamp(floor(Int, ld.position * n) + 1, 1, n)
        local_s = clamp(ld.position * n - (i - 1), 1e-6, 1 - 1e-6)
        return [Asap.PointLoad(children[i], local_s, ld.value, ld.id)]
    end
    return nothing
end

"""
Load list wide enough for a split edge.

[`_child_releases`](@ref) keeps a released end on the child that touches it
and fixes the pieces in between, so one parent load becomes loads of more
than one release. A vector typed on the parent's release cannot store them.
Lists that already accept every load (`AbstractLoad`, an unparameterized
`TributaryLoad`) are returned as they are.
"""
function _loads_for_split(loads)
    isconcretetype(eltype(loads)) || return loads
    widened = Asap.AbstractLoad[]
    sizehint!(widened, length(loads))
    append!(widened, loads)
    return widened
end

"""Move every load that names `parent` onto `children`. Unknown load types stay."""
function _retarget_element_loads!(loads, parent, children)
    loads = _loads_for_split(loads)
    i = 1
    while i <= length(loads)
        ld = loads[i]
        if !(hasproperty(ld, :element) && ld.element === parent)
            i += 1
            continue
        end
        repl = _split_element_load(ld, children)
        if repl === nothing
            i += 1
            continue
        end
        splice!(loads, i)
        for (k, r) in enumerate(repl)
            insert!(loads, i + k - 1, r)
        end
        i += length(repl)
    end
    return loads
end

function _retarget_parent_loads!(struc::BuildingStructure, parent, children)
    model = struc.asap_model
    model.loads = _retarget_element_loads!(model.loads, parent, children)
    for dict in (struc.cell_tributary_loads, struc.cell_dead_loads, struc.cell_live_loads)
        for (k, loads) in dict
            dict[k] = _retarget_element_loads!(loads, parent, children)
        end
    end
    model._elemental_loads = nothing
    return struc
end

"""
    _subdivide_composite_edge!(struc, edge_idx; n=4) -> Vector{Int}

Split one skeleton-edge frame element into `n` equal children.

The parent element keeps its index and loses its stiffness and its loads.
Children are appended. Idempotent: a second call returns the existing children.
`Asap.process!` is the caller's job, after every edge that needs it has been split.
"""
function _subdivide_composite_edge!(struc::BuildingStructure, edge_idx::Int;
                                    n::Int = _N_COMPOSITE_CHILDREN)
    mesh = _composite_mesh!(struc)
    children = get!(() -> Dict{Int, Vector{Int}}(), mesh, :children)
    haskey(children, edge_idx) && return children[edge_idx]
    model = struc.asap_model
    parent = model.frame_elements[edge_idx]
    p1 = parent.nodeStart.position
    p2 = parent.nodeEnd.position
    interior = Asap.Node[]
    for i in 1:(n - 1)
        t = i / n
        pos = [p1[k] + t * (p2[k] - p1[k]) for k in eachindex(p1)]
        # Same start as every other frame node: translations free, rotations
        # fixed. `_free_new_composite_rotations!` frees the bending rotations
        # the children actually anchor. Leaving twist free on a released beam
        # is a mechanism: a bending release drops torsion on the end piece,
        # and the interior nodes then twist together.
        node = Asap.Node(pos, [true, true, true, false, false, false], :composite_split)
        push!(model.nodes, node)
        push!(interior, node)
    end
    chain = [parent.nodeStart; interior; parent.nodeEnd]
    rels = _child_releases(_release_symbol(parent), n)
    steel = parent.section
    idxs = Int[]
    for i in 1:n
        el = Asap.Element(chain[i], chain[i + 1], steel, :composite_child;
                          release = rels[i], eccentricity = parent.eccentricity)
        push!(model.frame_elements, el)
        push!(idxs, length(model.frame_elements))
    end
    children[edge_idx] = idxs
    steel_map = get!(() -> Dict{Int, Asap.Section}(), mesh, :steel)
    for i in idxs
        steel_map[i] = steel
    end
    kids = [model.frame_elements[i] for i in idxs]
    _retarget_parent_loads!(struc, parent, kids)
    # A released element with zero area is singular in the release condensation.
    # The parent keeps the skeleton index and adds nothing; the end release
    # lives on the child that touches that end.
    zero = _zero_wall_frame_section(steel.E, steel.G)
    model.frame_elements[edge_idx] = Asap.Element(parent.nodeStart, parent.nodeEnd, zero,
                                            :composite_parent; release = :fixedfixed)
    _clear_unshored_stage!(mesh)
    return idxs
end

"""
Free bending rotations on composite split nodes.

New split nodes are born with rotations fixed, matching
[`_create_offset_nodes`](@ref). This applies the same rule as the model
build: a rotation is freed only when the elements at the node couple it to
a translation or to a support. Twist that a released end does not anchor
stays fixed.
"""
function _free_new_composite_rotations!(model)
    shells = hasproperty(model, :shell_elements) ? model.shell_elements : Asap.ShellElement[]
    _free_restrained_node_rotations!(model.nodes, model.frame_elements, shells)
    return model
end

include("openings.jl")

"""Drop staged displacements and any patterned-live force cache."""
function _clear_unshored_stage!(mesh)
    delete!(mesh, :stage)
    delete!(mesh, :pattern_dead)
    delete!(mesh, :pattern_forces)
    return mesh
end

"""
Child element indices sized unshored.

The set is per element, so one building can mix shored and unshored composite
beams. A mesh that still carries the old single `:shored` flag and no set
treats every child as unshored when that flag is false.
"""
function _unshored_indices(mesh)
    haskey(mesh, :unshored) && return mesh[:unshored]::Set{Int}
    s = Set{Int}()
    get(mesh, :shored, true) && return s
    children = get(mesh, :children, nothing)
    children === nothing && return s
    for idxs in values(children)
        for i in idxs
            push!(s, i)
        end
    end
    return s
end

_has_unshored(mesh) = !isempty(_unshored_indices(mesh))

function _ensure_unshored!(mesh)
    haskey(mesh, :unshored) && return mesh[:unshored]::Set{Int}
    s = _unshored_indices(mesh)
    mesh[:unshored] = s
    delete!(mesh, :shored)
    return s
end

"""Record whether these child elements are shored. Shored leaves the unshored set."""
function _note_shoring!(mesh, idxs, shored::Bool)
    s = _ensure_unshored!(mesh)
    if shored
        for i in idxs
            delete!(s, i)
        end
    else
        for i in idxs
            push!(s, i)
        end
    end
    return s
end

"""Composite child element indices of these member groups. Parents are omitted."""
function _composite_child_ids(struc::BuildingStructure, group_ids)
    ids = Set{Int}()
    for gid in group_ids
        mg = get(struc.member_groups, gid, nothing)
        mg === nothing && continue
        for m_idx in mg.member_indices
            m_idx > length(struc.beams) && continue
            for si in segment_indices(struc.beams[m_idx])
                edge = struc.segments[si].edge_idx
                for i in _frame_element_indices(struc, edge)
                    i == edge && continue
                    push!(ids, i)
                end
            end
        end
    end
    return ids
end

"""Cell-dead, self-weight, wall, drop-panel, and fire-coating weight stay on the steel section.

Fire coating is taken as applied before the slab is composite (user decision
2026-11-09), so the bare steel carries it.

A patterned live load is everything else in the case. ACI 318-11 §13.7.6.3
reduces that live load to three-quarters on the alternate-span cases
(corpus: aci-318-11, page 261). The full-load case is unscaled (§13.7.6.4,
same page).
"""
function _cell_dead_load_ids(struc::BuildingStructure)
    ids = Set{UInt}()
    for loads in values(struc.cell_dead_loads)
        for ld in loads
            push!(ids, objectid(ld))
        end
    end
    return ids
end

function _is_pattern_dead_load(ld, dead_ids::Set{UInt})
    objectid(ld) in dead_ids && return true
    ld isa Asap.GravityLoad && return true
    ld isa Asap.NodeForce && ld.id === DROP_PANEL_LOAD_ID && return true
    ld isa Asap.LineLoad && ld.id === FIRE_COATING_LOAD_ID && return true
    return ld isa Asap.AreaLoad && ld.id === :wall_self_weight
end

function _partition_pattern_loads(struc::BuildingStructure, case)
    dead_ids = _cell_dead_load_ids(struc)
    dead = Asap.AbstractLoad[]
    live = Asap.AbstractLoad[]
    for ld in case
        if _is_pattern_dead_load(ld, dead_ids)
            push!(dead, ld)
        else
            push!(live, ld)
        end
    end
    return dead, live
end

function _sample_frame_forces(model, u, loads; resolution::Int)
    by = _loads_by_id(loads)
    forces = Dict{Int, NamedTuple}()
    empty_loads = Asap.AbstractLoad[]
    for el in model.frame_elements
        forces[el.elementID] = _element_forces_from_u(
            el, u, get(by, el.elementID, empty_loads); resolution = resolution)
    end
    return forces
end

_add_stage_forces(d, l) = (
    P = d.P .+ l.P, My = d.My .+ l.My, Vy = d.Vy .+ l.Vy,
    Mz = d.Mz .+ l.Mz, Vz = d.Vz .+ l.Vz)

"""
Sample pattern dead load while the steel stiffness is still factorized.

AISC 360-22 Commentary §I3.1b (corpus: aisc-360-22, PDF p. 500): load applied
before the concrete has cured is resisted by the steel section alone. No-op
when pattern cases were never solved. Does not change `model.u`.
"""
function _capture_pattern_dead!(struc::BuildingStructure; resolution::Int = 200)
    _get_pattern_solve_cache(struc) === nothing && return nothing
    mesh = _composite_mesh(struc)
    mesh === nothing && return nothing
    cases = _generate_pattern_cases(struc)
    length(cases) <= 1 && return nothing
    dead, _ = _partition_pattern_loads(struc, cases[1])
    model = struc.asap_model
    u = isempty(dead) ? zeros(model.nDOFs) : Asap.solve(model, dead)
    forces = _sample_frame_forces(model, u, dead; resolution = resolution)
    mesh[:pattern_dead] = (u = u, forces = forces, resolution = resolution)
    delete!(mesh, :pattern_forces)
    return mesh[:pattern_dead]
end

"""
Dead on steel, each live pattern on the composite stiffness.

The dead forces were sampled while the steel section was on the element.
Each live pattern is one load vector on the composite factorization already
in hand. Forces are added. The two displacement vectors are not pushed back
through one stiffness. Returns `nothing` when the beam is shored, when no
pattern solve exists, or when the steel-stage dead load was not captured.
"""
function _unshored_pattern_forces(struc::BuildingStructure; resolution::Int = 200)
    mesh = _composite_mesh(struc)
    mesh === nothing && return nothing
    _has_unshored(mesh) || return nothing
    _get_pattern_solve_cache(struc) === nothing && return nothing
    cached = get(mesh, :pattern_forces, nothing)
    if cached !== nothing && cached.resolution == resolution
        return cached.cases
    end
    dead = get(mesh, :pattern_dead, nothing)
    (dead === nothing || dead.resolution != resolution) && return nothing
    cases = _generate_pattern_cases(struc)
    length(cases) <= 1 && return nothing
    model = struc.asap_model
    out = Vector{Dict{Int, NamedTuple}}(undef, length(cases))
    for (i, case) in enumerate(cases)
        _, live = _partition_pattern_loads(struc, case)
        u_L = isempty(live) ? zeros(model.nDOFs) : Asap.solve(model, live)
        live_forces = _sample_frame_forces(model, u_L, live; resolution = resolution)
        summed = Dict{Int, NamedTuple}()
        for (id, dforce) in dead.forces
            lforce = get(live_forces, id, nothing)
            lforce === nothing && continue
            summed[id] = _add_stage_forces(dforce, lforce)
        end
        out[i] = summed
    end
    mesh[:pattern_forces] = (cases = out, resolution = resolution)
    return out
end

"""
Rebuild the steel-stage pattern dead load after a stiffness change.

Swaps the composite children back to the steel section, samples dead load,
then restores the composite section. Used when a pattern refresh follows a
section change that did not already capture the steel stage.
"""
function _recapture_unshored_pattern_dead!(struc::BuildingStructure;
                                           resolution::Int = 200)
    mesh = _composite_mesh(struc)
    mesh === nothing && return nothing
    _has_unshored(mesh) || return nothing
    children = get(mesh, :children, nothing)
    (children === nothing || isempty(children)) && return nothing
    _with_bare_steel(struc) do model
        _capture_pattern_dead!(struc; resolution = resolution)
    end
    delete!(mesh, :pattern_forces)
    return get(mesh, :pattern_dead, nothing)
end
"""
Run `f(model)` with the stored steel section on every unshored composite child,
then put the sections back.

Shored children stay on their composite section. No unshored children runs `f`
on the model as it is. A throw still restores the sections.
"""
function _with_bare_steel(f, struc::BuildingStructure)
    model = struc.asap_model
    mesh = _composite_mesh(struc)
    steel = mesh === nothing ? nothing : get(mesh, :steel, nothing)
    unshored = mesh === nothing ? Set{Int}() : _unshored_indices(mesh)
    if isempty(unshored) || steel === nothing
        return f(model)
    end
    saved = Dict{Int, Asap.Section}()
    for i in unshored
        haskey(steel, i) || continue
        el = model.frame_elements[i]
        saved[i] = el.section
        el.section = steel[i]
    end
    isempty(saved) && return f(model)
    Asap.update!(model; values_only = true)
    try
        return f(model)
    finally
        for (i, sec) in saved
            model.frame_elements[i].section = sec
        end
        Asap.update!(model; values_only = true)
    end
end

"""
Dead on the steel inertia, live on the composite inertia.

AISC 360-22 Commentary §I3.1b (corpus: aisc-360-22, PDF p. 500): loads applied
before the concrete has cured are resisted by the steel section alone. For an
unshored continuous beam those two stiffnesses change the moments, not only
the construction-stage strength check. Shored construction uses one composite
stiffness, so this returns `nothing`.

Forces are recovered while each stage's section is still on the element.
Displacements are not added and then pushed back through one stiffness.
"""
function _unshored_stage!(struc::BuildingStructure; resolution::Int = 200)
    mesh = _composite_mesh(struc)
    mesh === nothing && return nothing
    _has_unshored(mesh) || return nothing
    children = get(mesh, :children, nothing)
    (children === nothing || isempty(children)) && return nothing
    cached = get(mesh, :stage, nothing)
    if cached !== nothing && get(cached, :resolution, resolution) == resolution
        return cached
    end
    dead = Asap.AbstractLoad[]
    for loads in values(struc.cell_dead_loads)
        append!(dead, loads)
    end
    live = Asap.AbstractLoad[]
    for loads in values(struc.cell_live_loads)
        append!(live, loads)
    end
    # No split loads. The full-load solve already on the model is the demand.
    # Recording an empty stage avoids factorizing steel and composite for zeros.
    if isempty(dead) && isempty(live)
        n = struc.asap_model.nDOFs
        stage = (u_D = zeros(n), u_L = zeros(n),
                 forces = Dict{Int, NamedTuple}(), resolution = resolution)
        mesh[:stage] = stage
        return stage
    end
    # Pattern dead load and the dead-load forces, on the steel section.
    u_D, forces_D = _with_bare_steel(struc) do model
        _capture_pattern_dead!(struc; resolution = resolution)
        u_D = isempty(dead) ? zeros(model.nDOFs) : Asap.solve(model, dead)
        by_D = _loads_by_id(dead)
        forces_D = Dict{Int, NamedTuple}()
        unshored = _unshored_indices(mesh)
        for idxs in values(children)
            for i in idxs
                i in unshored || continue
                el = model.frame_elements[i]
                forces_D[el.elementID] = _element_forces_from_u(
                    el, u_D, get(by_D, el.elementID, Asap.AbstractLoad[]);
                    resolution = resolution)
            end
        end
        return (u_D, forces_D)
    end
    model = struc.asap_model
    u_L = isempty(live) ? zeros(model.nDOFs) : Asap.solve(model, live)
    by_L = _loads_by_id(live)
    summed = Dict{Int, NamedTuple}()
    unshored = _unshored_indices(mesh)
    for idxs in values(children)
        for i in idxs
            i in unshored || continue
            el = model.frame_elements[i]
            id = el.elementID
            d = forces_D[id]
            l = _element_forces_from_u(el, u_L, get(by_L, id, Asap.AbstractLoad[]);
                                       resolution = resolution)
            summed[id] = _add_stage_forces(d, l)
        end
    end
    stage = (u_D = u_D, u_L = u_L, forces = summed, resolution = resolution)
    mesh[:stage] = stage
    return stage
end

"""
    _unshored_service_profiles(struc, dead, live, idxs; resolution) -> Union{Nothing, NamedTuple}

Service deflection profiles of frame elements `idxs` for an unshored composite
floor: `dead` solved and sampled with the bare steel section on every unshored
child, `live` solved and sampled on the current (composite) sections. Returns
`(D = Dict(i => profile), L = Dict(i => profile))`, or `nothing` when no beam is
unshored (one stiffness carries both cases).

AISC 360-22 Commentary §I3.1b (corpus: aisc-360-22, PDF p. 500): load applied
before the concrete has cured is resisted by the steel section alone. `dead` is
the full unfactored dead set of `_service_dead_live_loads` (slab, self-weight,
fire coating, drop panels, walls), so all of it is placed on the steel. Each
case is sampled while its own section is on the element, because the member-load
part of the deflection divides by that section's `EI`.
"""
function _unshored_service_profiles(struc::BuildingStructure, dead, live, idxs;
                                    resolution::Int)
    mesh = _composite_mesh(struc)
    (mesh === nothing || !_has_unshored(mesh)) && return nothing
    model = struc.asap_model
    links = struc.asap_rigid_links
    by_D = Asap.frame_loads_by_element(model, dead)
    by_L = Asap.frame_loads_by_element(model, live)
    D = _with_bare_steel(struc) do m
        u_D = Asap.solve(m, Vector{Asap.AbstractLoad}[dead], links)[1]
        Dict(i => Asap.element_deflection_profile(m.frame_elements[i], u_D, by_D[i];
                                                  resolution = resolution) for i in idxs)
    end
    u_L = Asap.solve(model, Vector{Asap.AbstractLoad}[live], links)[1]
    L = Dict(i => Asap.element_deflection_profile(model.frame_elements[i], u_L, by_L[i];
                                                  resolution = resolution) for i in idxs)
    return (D = D, L = L)
end

function _loads_by_id(loads)
    by = Dict{Int, Vector{Asap.AbstractLoad}}()
    for load in loads
        hasproperty(load, :element) || continue
        id = load.element.elementID
        push!(get!(() -> Asap.AbstractLoad[], by, id), load)
    end
    return by
end

"""
Write per-element composite inertia for the beams that were just sized.

Pass 1 subdivides each composite bay. The steel solve places hogging and
sagging. The composite solve is the full-load displacement. For an unshored
beam those two solves are also the staged dead and live results, so the
confirmation pass reads the cache instead of factorizing again.

Returns true when a confirmation pass should run.
"""
function _install_composite_analysis!(struc::BuildingStructure, result, group_ids,
                                      payloads, material, shored::Bool;
                                      resolution::Int = 200, service = nothing)
    jobs = NamedTuple[]
    grew = false
    installed = Int[]
    mesh = _composite_mesh!(struc)
    _clear_unshored_stage!(mesh)
    for (g_idx, gid) in enumerate(group_ids)
        payload = payloads[g_idx]
        payload isa PerStationComposite || continue
        chosen = result.sections[g_idx]
        mg = struc.member_groups[gid]
        beams = [struc.beams[i] for i in mg.member_indices]
        brace = _group_flexure_bracing(struc, mg.member_indices)
        svc = service === nothing ? nothing : service[g_idx]
        for (bi, beam) in enumerate(beams)
            for si in segment_indices(beam)
                edge = struc.segments[si].edge_idx
                before = haskey(get(mesh, :children, Dict{Int, Vector{Int}}()), edge)
                append!(installed, _subdivide_composite_edge!(struc, edge))
                grew |= !before
            end
            push!(jobs, (; beam, chosen, field = payload.fields[bi],
                         ctx = payload.ctx, brace, service = svc))
        end
    end
    isempty(jobs) && return false
    _note_shoring!(mesh, installed, shored)
    model = struc.asap_model
    # New nodes need a full process before the moment field can see the children.
    # Children are still steel. This solve places hogging and sagging.
    # Free rotations before process! so the DOF map includes them.
    grew && _free_new_composite_rotations!(model)
    if grew
        Asap.process!(model)
    else
        Asap.update!(model; values_only = true)
    end
    Asap.solve!(model)
    for job in jobs
        _write_beam_composite_ix!(struc, job.beam, job.chosen, material, job.field, job.ctx;
                                  _brace_kwargs(job.brace)..., service = job.service)
    end
    if shored
        Asap.update!(model; values_only = true)
        Asap.solve!(model)
    else
        # Steel factorization is still current: writing Ix does not rebuild K.
        # `installed` is that factorization. Other unshored beams are not.
        _seed_unshored_stage!(struc; resolution = resolution,
                              steel_k_ids = Set(installed))
    end
    return true
end

"""
Put bare steel on unshored children that are composite in the current factorization.

`skip` are children whose element section may already be the composite inertia
while the factorization is still steel (the pass just installed). They are
included in the update only when some other unshored child needs one. Returns
the sections to restore. Empty when the factorization was already right.
"""
function _hold_unshored_steel!(struc::BuildingStructure, skip::Set{Int})
    saved = Dict{Int, Asap.Section}()
    mesh = _composite_mesh(struc)
    mesh === nothing && return saved
    steel = get(mesh, :steel, nothing)
    steel === nothing && return saved
    model = struc.asap_model
    others = Int[]
    for i in _unshored_indices(mesh)
        i in skip && continue
        haskey(steel, i) || continue
        model.frame_elements[i].section === steel[i] && continue
        push!(others, i)
    end
    isempty(others) && return saved
    for i in others
        el = model.frame_elements[i]
        saved[i] = el.section
        el.section = steel[i]
    end
    for i in skip
        haskey(steel, i) || continue
        el = model.frame_elements[i]
        el.section === steel[i] && continue
        saved[i] = el.section
        el.section = steel[i]
    end
    Asap.update!(model; values_only = true)
    return saved
end

function _restore_held!(model, held)
    for (i, sec) in held
        model.frame_elements[i].section = sec
    end
    return model
end

"""
Dead on the steel factorization already in hand, live on one composite factorization.

`model.u` is left as the full-load composite displacement. The stage cache
holds the split so a later demand pass does not factorize either stiffness again.
Shored construction does not call this.
"""
function _seed_unshored_stage!(struc::BuildingStructure; resolution::Int = 200,
                               steel_k_ids = nothing)
    mesh = _composite_mesh!(struc)
    model = struc.asap_model
    children = mesh[:children]
    skip = steel_k_ids === nothing ? Set{Int}() : steel_k_ids
    held = _hold_unshored_steel!(struc, skip)
    dead = Asap.AbstractLoad[]
    for loads in values(struc.cell_dead_loads)
        append!(dead, loads)
    end
    live = Asap.AbstractLoad[]
    for loads in values(struc.cell_live_loads)
        append!(live, loads)
    end
    if isempty(dead) && isempty(live)
        # Pattern dead load, while the steel factorization from install is current.
        _capture_pattern_dead!(struc; resolution = resolution)
        _restore_held!(model, held)
        Asap.update!(model; values_only = true)
        Asap.solve!(model)
        n = model.nDOFs
        stage = (u_D = zeros(n), u_L = zeros(n),
                 forces = Dict{Int, NamedTuple}(), resolution = resolution)
        mesh[:stage] = stage
        return stage
    end
    # Element K is still the steel mesh for `skip`. Other unshored beams were
    # swapped to steel by `_hold_unshored_steel!` when they were not. Sample
    # dead before rebuilding K on the composite inertia.
    _capture_pattern_dead!(struc; resolution = resolution)
    u_D = isempty(dead) ? zeros(model.nDOFs) : Asap.solve(model, dead)
    by_D = _loads_by_id(dead)
    forces_D = Dict{Int, NamedTuple}()
    unshored = _unshored_indices(mesh)
    for idxs in values(children)
        for i in idxs
            i in unshored || continue
            el = model.frame_elements[i]
            forces_D[el.elementID] = _element_forces_from_u(
                el, u_D, get(by_D, el.elementID, Asap.AbstractLoad[]);
                resolution = resolution)
        end
    end
    _restore_held!(model, held)
    Asap.update!(model; values_only = true)
    u_L = isempty(live) ? zeros(model.nDOFs) : Asap.solve(model, live)
    by_L = _loads_by_id(live)
    summed = Dict{Int, NamedTuple}()
    for idxs in values(children)
        for i in idxs
            i in unshored || continue
            el = model.frame_elements[i]
            id = el.elementID
            d = forces_D[id]
            l = _element_forces_from_u(el, u_L, get(by_L, id, Asap.AbstractLoad[]);
                                       resolution = resolution)
            summed[id] = _add_stage_forces(d, l)
        end
    end
    Asap.solve!(model)
    stage = (u_D = u_D, u_L = u_L, forces = summed, resolution = resolution)
    mesh[:stage] = stage
    return stage
end

"""
Solve a changed composite section and store the stage for the confirmation.

The steel solve places hogging and sagging for the new section. One composite
factorization then carries live load and the full-load displacement.
"""
function _reanalyze_changed_composite!(struc::BuildingStructure, result, group_ids,
                                       payloads, material, shored::Bool;
                                       resolution::Int = 200, service = nothing)
    _refresh_composite_ix!(struc, result, group_ids, payloads, material; service = service)
    mesh = _composite_mesh!(struc)
    model = struc.asap_model
    # Only this pass's children go back to steel. Other composite beams keep
    # the stiffness the previous pass installed.
    own = _composite_child_ids(struc, group_ids)
    steel_map = get(mesh, :steel, Dict{Int, Asap.Section}())
    for i in own
        haskey(steel_map, i) || continue
        model.frame_elements[i].section = steel_map[i]
    end
    Asap.update!(model; values_only = true)
    Asap.solve!(model)
    for (g_idx, gid) in enumerate(group_ids)
        payload = payloads[g_idx]
        payload isa PerStationComposite || continue
        chosen = result.sections[g_idx]
        mg = struc.member_groups[gid]
        brace = _group_flexure_bracing(struc, mg.member_indices)
        svc = service === nothing ? nothing : service[g_idx]
        for (bi, m_idx) in enumerate(mg.member_indices)
            _write_beam_composite_ix!(struc, struc.beams[m_idx], chosen, material,
                                      payload.fields[bi], payload.ctx;
                                      _brace_kwargs(brace)..., service = svc)
        end
    end
    if shored
        Asap.update!(model; values_only = true)
        Asap.solve!(model)
    else
        _seed_unshored_stage!(struc; resolution = resolution, steel_k_ids = own)
    end
    return struc
end

"""Put the zero parent back after a sizing pass rewrites the skeleton edge.

Children and the stage cache stay. The assembled stiffness is still the
composite mesh until the next update.
"""
function _restore_composite_parents!(struc::BuildingStructure)
    mesh = _composite_mesh(struc)
    mesh === nothing && return struc
    children = get(mesh, :children, nothing)
    (children === nothing || isempty(children)) && return struc
    model = struc.asap_model
    for (edge, idxs) in children
        isempty(idxs) && continue
        sec = model.frame_elements[first(idxs)].section
        model.frame_elements[edge].section = _zero_wall_frame_section(sec.E, sec.G)
    end
    return struc
end

"""Put the new steel section on the children, then the composite inertia."""
function _refresh_composite_ix!(struc::BuildingStructure, result, group_ids,
                                payloads, material; service = nothing)
    mesh = _composite_mesh(struc)
    mesh === nothing && return struc
    _clear_unshored_stage!(mesh)
    steel_map = get!(() -> Dict{Int, Asap.Section}(), mesh, :steel)
    model = struc.asap_model
    for (g_idx, gid) in enumerate(group_ids)
        payload = payloads[g_idx]
        payload isa PerStationComposite || continue
        chosen = result.sections[g_idx]
        asap_sec = StructuralSizer.to_asap_section(chosen, material)
        mg = struc.member_groups[gid]
        brace = _group_flexure_bracing(struc, mg.member_indices)
        for (bi, m_idx) in enumerate(mg.member_indices)
            beam = struc.beams[m_idx]
            field = payload.fields[bi]
            for si in segment_indices(beam)
                edge = struc.segments[si].edge_idx
                parent = model.frame_elements[edge]
                parent.section = asap_sec
                for i in _frame_element_indices(struc, edge)
                    i == edge && continue
                    model.frame_elements[i].section = asap_sec
                    steel_map[i] = asap_sec
                end
                parent.section = _zero_wall_frame_section(asap_sec.E, asap_sec.G)
            end
            svc = service === nothing ? nothing : service[g_idx]
            _write_beam_composite_ix!(struc, beam, chosen, material, field, payload.ctx;
                                      _brace_kwargs(brace)..., service = svc)
        end
    end
    return struc
end

"""Longest segment `Lb` and smallest segment `Cb` in one beam group.

`member_group_demands` stores this pair on `SteelMemberGeometry`. The
composite stud search uses it for the bare-steel flexural strength.
"""
function _group_flexure_bracing(struc::BuildingStructure, member_indices)
    Lb = 0.0
    Cb = Inf
    nseg = 0
    for m_idx in member_indices
        for si in segment_indices(struc.beams[m_idx])
            seg = struc.segments[si]
            Lb = max(Lb, to_meters(seg.Lb))
            Cb = min(Cb, float(seg.Cb))
            nseg += 1
        end
    end
    nseg == 0 && return nothing
    return (; Lb = Lb * u"m", Cb = Cb)
end

_brace_kwargs(::Nothing) = (;)
_brace_kwargs(brace) = (; Lb = brace.Lb, Cb = brace.Cb)

"""
Per-group inputs for the stud `I_need` the catalog counted.

`variable_inertia` is the flag on that group's payload. When it is true the
checker used the solved deflection and `I_need` stays unset. Otherwise
`_I_required_for_composite` uses this group's δ, `I_ref`, and span with the
beam options' deflection limits, the same call as `is_feasible`.
"""
function _composite_install_service(demands, geometries, opts, payloads)
    checker = AISCChecker(;
        deflection_limit = opts.deflection_limit,
        total_deflection_limit = opts.total_deflection_limit)
    return map(enumerate(payloads)) do (i, payload)
        payload isa PerStationComposite || return nothing
        d = demands[i]
        return (
            checker = checker,
            variable_inertia = payload.variable_inertia,
            shored = payload.ctx.shored,
            L_m = to_meters(geometries[i].L),
            I_ref = Asap.to_meters_fourth(d.I_ref),
            δ_LL = to_meters(d.δ_max_LL),
            δ_total = to_meters(d.δ_max_total),
        )
    end
end

"""
`I_LB` the stud layout has to reach, or `nothing` when the check used the solved deflection.

The service check on a continuous beam is Eq. C-I3-5, so the layout is asked
for the positive inertia that produces that service inertia. A beam with one
sagging region, and the region of greatest positive moment when there are
several, is the region the checker applies this to.
"""
function _composite_I_need(section, field, ctx, regions, service)
    (service === nothing || service.variable_inertia || isempty(regions)) && return nothing
    # AISC 360-22 Commentary Eq. C-I3-1 (corpus: aisc-360-22, PDF p. 502):
    # I_LB grows with ΣQn between the maximum positive moment and the adjacent
    # zero. Eq. C-I3-5 on the same page checks a continuous beam on
    # 0.6 I_LB + 0.4 I_neg. Same two calls as is_feasible.
    I_need = StructuralSizer._I_required_for_composite(
        service.checker, service.shored, service.L_m, service.I_ref,
        service.δ_LL, service.δ_total)
    if I_need !== nothing && StructuralSizer.moment_field_has_negative(field.demand_of_s)
        I_neg = composite_negative_inertia(section, ctx)
        I_need = positive_inertia_for_service(I_need, I_neg; continuous = true)
    end
    return I_need
end

"""
    _write_beam_composite_ix!(struc, beam, section, material, field, ctx; Lb, Cb, service)

Write each element's composite inertia from the studs the check counted.

`Lb` and `Cb` are the group values from [`_group_flexure_bracing`](@ref).
When they are omitted, the steel strength is taken at the member span with
`Cb = 1`. `service` is one entry from [`_composite_install_service`](@ref).
The region of greatest positive moment is asked for that `I_LB`. The other
regions stay on strength, as the checker does.
"""
function _write_beam_composite_ix!(struc, beam, section, material, field, ctx;
                                   Lb = nothing, Cb = nothing, service = nothing)
    L = field.L_beam === nothing ? _beam_span_length(beam) : field.L_beam
    slab = field.slab === nothing ? ctx.slab : field.slab
    # Same ϕMn the checker caches. AISC 360-16 §F1, ϕ_b = 0.90
    # (corpus: aisc-360-16, p. 102). Commentary Eq. C-I3-1
    # (corpus: aisc-360-22, PDF p. 502) takes ΣQn as the anchors placed
    # between the maximum positive moment and the adjacent zero; this
    # strength decides how many of those anchors the search requires.
    Lb_use = Lb === nothing ? uconvert(u"m", L) : uconvert(u"m", Lb)
    Cb_use = Cb === nothing ? 1.0 : Cb
    ϕMn_steel = get_ϕMn(section, material; Lb = Lb_use, Cb = Cb_use,
                        axis = :strong, ϕ = 0.9)
    M_of_s, _ = beam_signed_moment_field(struc, beam)
    regions = positive_moment_regions(M_of_s)
    I_need = _composite_I_need(section, field, ctx, regions, service)
    primary_peak = isempty(regions) ? nothing : argmax(r -> r.M_peak, regions).s_peak
    I_for(region) = (I_need === nothing || region.s_peak != primary_peak) ? nothing : I_need
    function anchors(region)
        b = b_eff_at_station(slab, L, region.s_peak;
                             left = field.left, right = field.right,
                             supports = field.supports)
        lay = design_shear_anchors(section, material, slab, ctx.anchor, b, L,
                                   region.M_peak * u"N*m";
                                   ϕMn_steel = ϕMn_steel,
                                   shear_spans = region_shear_spans(region, L),
                                   slip_checked = ctx.slip_checked,
                                   I_need = I_for(region))
        # A failing probe is the minimum row count. Installing it after the
        # catalog counted a higher I_LB would put too few studs on the beam.
        if I_for(region) !== nothing && !lay.ok
            throw(ArgumentError(
                "Shear anchors for this composite beam do not reach the I_LB " *
                "the deflection check counted ($(lay.reason))."))
        end
        return lay
    end
    layouts = Dict{Any, Any}()
    for region in regions
        layouts[region] = anchors(region)
    end
    ΣQn_at = region -> begin
        lay = get(layouts, region, nothing)
        return (lay === nothing ? anchors(region) : lay).ΣQn
    end
    _store_stud_placement!(struc, beam, place_shear_anchors(
        section, ctx.anchor, slab, regions, [layouts[r] for r in regions], L))
    _record_composite_stiffness!(struc, beam, section, material, slab, ΣQn_at;
                                 left = field.left, right = field.right,
                                 supports = field.supports,
                                 Asr = ctx.Asr, d_rebar = ctx.d_rebar)
    apply_composite_element_stiffness!(struc, beam, section, material, slab, ΣQn_at;
                                       left = field.left, right = field.right,
                                       supports = field.supports,
                                       Asr = ctx.Asr, d_rebar = ctx.d_rebar)
    return struc
end

"""Keep the stud stations written with the composite stiffness of `beam`."""
function _store_stud_placement!(struc::BuildingStructure, beam::Beam,
                                layout::StructuralSizer.ShearAnchorLayout)
    mesh = _composite_mesh!(struc)
    placed = get!(() -> IdDict{Beam, StructuralSizer.ShearAnchorLayout}(),
                  mesh, :stud_placements)
    placed[beam] = layout
    # The beam object can be replaced after sizing. The index survives that.
    by_index = get!(() -> Dict{Int, StructuralSizer.ShearAnchorLayout}(),
                    mesh, :stud_placement_index)
    idx = findfirst(b -> b === beam, struc.beams)
    idx === nothing || (by_index[idx] = layout)
    return layout
end

"""Stud stations for `beam`, or `nothing` when composite stiffness was not written."""
function composite_stud_placement(struc::BuildingStructure, beam::Beam)
    mesh = _composite_mesh(struc)
    mesh === nothing && return nothing
    placed = get(mesh, :stud_placements, nothing)
    if placed !== nothing
        hit = get(placed, beam, nothing)
        hit === nothing || return hit
    end
    by_index = get(mesh, :stud_placement_index, nothing)
    by_index === nothing && return nothing
    idx = findfirst(b -> b === beam, struc.beams)
    if idx === nothing
        segs = segment_indices(beam)
        idx = findfirst(b -> segment_indices(b) == segs, struc.beams)
    end
    idx === nothing && return nothing
    return get(by_index, idx, nothing)
end

"""
    stud_positions_by_element(struc) -> Dict{Int, NamedTuple}

Each entry is `(pts, d_sa, l_sa, z_flange)`. `pts` are `(s_local, y)` in
metres for one analysis element. `s_local` is measured from that element's
start node, along the same station axis as [`beam_signed_moment_field`](@ref).
The last element of a beam includes a stud that lands on its end. `d_sa` and
`l_sa` are the shank diameter and length. `z_flange` is the top of steel in
the section frame, metres.
"""
function stud_positions_by_element(struc::BuildingStructure)
    out = Dict{Int, NamedTuple}()
    mesh = _composite_mesh(struc)
    mesh === nothing && return out
    placed = get(mesh, :stud_placements, nothing)
    placed === nothing && return out
    model = struc.asap_model
    model === nothing && return out
    for (beam, layout) in placed
        isempty(layout.s) && continue
        spans = Tuple{Int, Float64, Float64}[]
        acc = 0.0
        for si in segment_indices(beam)
            seg = struc.segments[si]
            for el_idx in _frame_element_indices(struc, seg.edge_idx)
                el = model.frame_elements[el_idx]
                L = Float64(Asap.ElementProps(el).L)
                push!(spans, (el.elementID, acc, acc + L))
                acc += L
            end
        end
        for (k, (eid, s0, s1)) in enumerate(spans)
            pts = studs_on_interval(layout, s0, s1; include_end = k == length(spans))
            isempty(pts) && continue
            out[eid] = (pts = pts, d_sa = layout.d_sa, l_sa = layout.l_sa,
                        z_flange = layout.z_flange)
        end
    end
    return out
end

