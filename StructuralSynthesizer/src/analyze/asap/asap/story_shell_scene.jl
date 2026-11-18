# =============================================================================
# Scene model of the story shells the floors were sized on
# =============================================================================

"""
Drawing-only parts of a model from [`story_shell_scene_model`](@ref): 1-based
node and frame-element indices that take no part in the solve, and the state
each story was saved in (`:cracked_service` or `:factored`). Weak keys, as
`_ANALYSIS_SHELL_WALLS`.
"""
const _ANALYSIS_DRAWN_ONLY = WeakKeyDict{Asap.Model, NamedTuple}()

"""`:story_shell`, `:grillage`, or absent (the display mesh)."""
const _ANALYSIS_SCENE_KIND = WeakKeyDict{Asap.Model, Symbol}()

"""Which analysis [`build_analysis_model!`](@ref) stored: `:story_shell`, `:grillage`, or `:display_mesh`."""
analysis_scene_kind(model::Asap.Model) = get(_ANALYSIS_SCENE_KIND, model, :display_mesh)

"""
    analysis_drawn_only(model) -> NamedTuple or nothing

`(nodes, frames, states)` for a model from [`story_shell_scene_model`](@ref),
`nothing` for any other model.
"""
analysis_drawn_only(model::Asap.Model) = get(_ANALYSIS_DRAWN_ONLY, model, nothing)

"""
    story_shell_scene_model(design) -> Asap.Model or nothing

The story shells the design's floors and beams were sized on, one per story,
with the frame model's columns drawn around them. `nothing` unless every
slab carries a solved story shell (`design_details.shell_scene`).

Each story is the copy [`solve_story_shell!`](@ref) kept: the settled
cracked service state the deflection checks read (dead plus full live load,
cracked plates and beam webs, column springs), or the gross factored solve
when the service solve was off. The stories share no node, so solving them
together gives each story's own answer.

The model starts with one node per skeleton vertex, so footings find their
supports by vertex index as in [`build_analysis_model!`](@ref). Those nodes
and the columns on them are fully restrained and take no part in the solve.
Columns enter the story solve only as its rotational springs.

Sets `design.asap_model` and `design.asap_model_frame_edge_indices`. A beam
piece maps to the skeleton edge of its beam nearest the piece midpoint.
"""
function story_shell_scene_model(design::BuildingDesign)
    struc = design.structure
    isempty(struc.slabs) && return nothing
    scenes = Dict{Int, Any}()
    n_floor = 0
    for slab in struc.slabs
        slab.floor_type === :grade && continue
        n_floor += 1
        dd = slab.design_details
        scene = dd isa NamedTuple ? get(dd, :shell_scene, nothing) : nothing
        scene === nothing && return nothing
        scenes[scene.level] = scene
    end
    n_floor == 0 && return nothing

    skel = struc.skeleton
    all_fixed = Set(1:length(skel.vertices))
    drawn = _create_offset_nodes(skel, design.structural_offsets, all_fixed)
    nodes = copy(drawn)
    frames = Asap.FrameElement[]
    shells = Asap.ShellElement[]
    loads = Asap.AbstractLoad[]
    springs = Asap.Spring[]
    edges = Int[]
    states = Dict{Int, Symbol}()
    shell_walls = Int[]
    for level in sort!(collect(keys(scenes)))
        scene = scenes[level]
        story = copy_solved_model(scene.model)
        # A story shell is meshed in plan, at z = 0. The scene is the building,
        # so each story's nodes move up to that story's elevation.
        z = ustrip(u"m", _story_metres(struc.skeleton.stories[level].elevation))
        for n in story.nodes
            n.position[3] += z * u"m"
        end
        append!(nodes, story.nodes)
        for el in story.frame_elements
            push!(frames, el)
            push!(edges, _story_piece_edge(struc, scene.beam_index, el))
        end
        nsh = length(story.shell_elements)
        ids = get(scene, :shell_walls, nothing)
        if ids === nothing || length(ids) != nsh
            append!(shell_walls, zeros(Int, nsh))
        else
            append!(shell_walls, ids)
        end
        append!(shells, story.shell_elements)
        append!(loads, story.loads)
        append!(springs, story.springs)
        states[level] = scene.state
    end

    n_story_frames = length(frames)
    src = struc.asap_model.frame_elements
    for edge_idx in get(skel.groups_edges, :columns, Int[])
        v1, v2 = skel.edge_indices[edge_idx]
        el = Asap.Element(drawn[v1], drawn[v2], src[edge_idx].section, :column)
        el.Ψ = src[edge_idx].Ψ
        push!(frames, el)
        push!(edges, edge_idx)
    end

    model = Asap.Model(nodes, frames, shells, loads)
    Asap.process!(model)
    isempty(springs) || Asap.add_springs!(model, springs)
    design.asap_model = model
    design.asap_model_frame_edge_indices = edges
    _ANALYSIS_SHELL_WALLS[model] = shell_walls
    _ANALYSIS_DRAWN_ONLY[model] = (nodes = Set(1:length(drawn)),
                                   frames = Set((n_story_frames + 1):length(frames)),
                                   states = states)
    _ANALYSIS_SCENE_KIND[model] = :story_shell
    return model
end

"""
    grillage_scene_model(design) -> Asap.Model or nothing

The building frame a grillage floor was solved on, or `nothing` unless every
slab is a grillage.

A grillage owns its panel (ACI 318-19 §8.2.1, corpus: aci-318-19, page 101).
The ribs are the frame members, noded at every crossing, and the panel load
is the line load on those members. The scene is a copy of that frame, so a
later solve does not change the structure's own model. Each rib bay is also
drawn as two triangles of those same nodes, so the slab picture deflects with
the ribs. The triangles are not solved again: their element id stays 0 and
the scene records no surface stress.

Sets `design.asap_model` and `design.asap_model_frame_edge_indices`. Skeleton
edge `i` is frame element `i`, as in [`to_asap!`](@ref).
"""
function grillage_scene_model(design::BuildingDesign)
    struc = design.structure
    floors = [s for s in struc.slabs if s.floor_type !== :grade]
    isempty(floors) && return nothing
    all(s -> _grillage_level(s) !== nothing, floors) || return nothing
    src = struc.asap_model
    n_edges = length(struc.skeleton.edge_indices)
    length(src.frame_elements) == n_edges || error(
        "scene: the grillage frame has $(length(src.frame_elements)) elements " *
        "for $n_edges skeleton edges")
    model = copy_solved_model(src)
    design.asap_model = model
    design.asap_model_frame_edge_indices = collect(1:length(model.frame_elements))
    isempty(model.shell_elements) ||
        (_ANALYSIS_SHELL_WALLS[model] = _copied_shell_walls(struc, src, model))
    panels = _rib_slab_panels(model, struc)
    if !isempty(panels)
        append!(model.shell_elements, panels)
        prior = get(_ANALYSIS_SHELL_WALLS, model, Int[])
        _ANALYSIS_SHELL_WALLS[model] = vcat(prior, zeros(Int, length(panels)))
    end
    _ANALYSIS_SCENE_KIND[model] = :grillage
    return model
end

"""
Display triangles of a grillage slab, two per rib bay.

The corners are nodes of the solved frame. Nothing is added and nothing is
solved: each triangle keeps element id 0, so the scene stores no surface
stress. A bay whose centroid lies outside every designed slab is left out.
"""
function _rib_slab_panels(model::Asap.Model, struc)
    owners = Tuple{Vector{NTuple{2, Float64}}, Float64, Symbol, Float64}[]
    for (si, slab) in enumerate(struc.slabs)
        slab.floor_type === :grade && continue
        t = thickness(slab)
        t > zero(t) || continue
        poly = _slab_interior_polygon_m(struc, slab)
        poly === nothing && continue
        z = _slab_story_z(struc, slab)
        z === nothing && continue
        push!(owners, (poly, Float64(ustrip(u"m", _story_metres(t))), Symbol("slab_$si"), z))
    end
    isempty(owners) && return Asap.ShellTri3[]
    E = uconvert(u"Pa", NWC_4000.E)
    ν = NWC_4000.ν
    xy(n) = (ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2]))
    zz(n) = ustrip(u"m", n.position[3])
    adj = Dict{UInt, Vector{Asap.Node}}()
    nodeof = Dict{UInt, Asap.Node}()
    for el in model.frame_elements
        a, b = el.nodeStart, el.nodeEnd
        nodeof[objectid(a)] = a
        nodeof[objectid(b)] = b
        abs(zz(a) - zz(b)) > 0.05 && continue
        push!(get!(() -> Asap.Node[], adj, objectid(a)), b)
        push!(get!(() -> Asap.Node[], adj, objectid(b)), a)
    end
    for (k, nbrs) in adj
        ox, oy = xy(nodeof[k])
        sort!(nbrs, by = m -> begin
            mx, my = xy(m)
            atan(my - oy, mx - ox)
        end)
    end
    used = Set{Tuple{UInt, UInt}}()
    panels = Asap.ShellTri3[]
    for (ka, nbrs) in adj
        a = nodeof[ka]
        for b in nbrs
            (objectid(a), objectid(b)) in used && continue
            face = Asap.Node[]
            u, v = a, b
            closed = false
            for _ in 1:10000
                push!(face, u)
                push!(used, (objectid(u), objectid(v)))
                nbrs_v = get(adj, objectid(v), Asap.Node[])
                idx = findfirst(n -> n === u, nbrs_v)
                idx === nothing && break
                nxt = nbrs_v[mod1(idx - 1, length(nbrs_v))]
                u, v = v, nxt
                if u === a && v === b
                    closed = true
                    break
                end
            end
            (closed && length(face) >= 3) || continue
            _plan_loop_area(face, xy) > 1e-4 || continue
            cx = sum(xy(n)[1] for n in face) / length(face)
            cy = sum(xy(n)[2] for n in face) / length(face)
            cz = sum(zz(n) for n in face) / length(face)
            owner = nothing
            for (poly, thick, id, z) in owners
                abs(cz - z) <= 0.05 || continue
                _point_in_polygon_xy(cx, cy, poly) || continue
                owner = (thick, id)
                break
            end
            owner === nothing && continue
            thick, id = owner
            for i in 3:length(face)
                push!(panels, Asap.ShellTri3((face[1], face[i - 1], face[i]), thick * u"m", E, ν; id = id))
            end
        end
    end
    return panels
end

"Signed plan area of a node loop, square metres."
function _plan_loop_area(face, xy)
    area = 0.0
    for i in eachindex(face)
        ax, ay = xy(face[i])
        bx, by = xy(face[mod1(i + 1, length(face))])
        area += ax * by - bx * ay
    end
    return area / 2
end

"Mean elevation, in metres, of the skeleton vertices of `slab`."
function _slab_story_z(struc, slab)
    zs = Float64[]
    skel = struc.skeleton
    for ci in slab.cell_indices
        1 <= ci <= length(struc.cells) || continue
        face = struc.cells[ci].face_idx
        1 <= face <= length(skel.face_vertex_indices) || continue
        for v in skel.face_vertex_indices[face]
            push!(zs, _vertex_z_m(skel, v))
        end
    end
    isempty(zs) && return nothing
    return sum(zs) / length(zs)
end

"""
    port_analysis_model!(design) -> Asap.Model or nothing

Put the solved analysis frame on `design.asap_model` when no scene model is there.

The frame that was solved is `design.structure.asap_model`. A grillage scene is
that frame copied by [`grillage_scene_model`](@ref). Skipping visualization, or
a scene build that throws, used to leave `design.asap_model` empty. Skeleton
edge `i` is frame element `i` when the two counts match, as in `to_asap!`.
"""
function port_analysis_model!(design::BuildingDesign)
    design.asap_model === nothing || return design.asap_model
    try
        scene = grillage_scene_model(design)
        scene === nothing || return scene
    catch err
        @warn "The grillage scene was not copied from the solved frame" exception = (err, catch_backtrace())
    end
    src = design.structure.asap_model
    (src === nothing || isempty(src.frame_elements)) && return nothing
    model = copy_solved_model(src)
    design.asap_model = model
    n = length(model.frame_elements)
    n_edges = length(design.structure.skeleton.edge_indices)
    design.asap_model_frame_edge_indices = collect(1:n)
    n == n_edges || @warn "Solved frame has $n elements for $n_edges skeleton edges"
    isempty(model.shell_elements) ||
        (_ANALYSIS_SHELL_WALLS[model] = _copied_shell_walls(design.structure, src, model))
    return model
end

"""
Wall index of each shell in `copy`, using the source model's objects.

`copy` is a `deepcopy` of `src`, so the shells correspond in order. Pier
ownership lives on `struc.wall_mesh` and names the source triangles. A shell
that is not a pier is index 0.
"""
function _copied_shell_walls(struc, src::Asap.Model, copy::Asap.Model)
    length(src.shell_elements) == length(copy.shell_elements) || error(
        "scene: the copied frame has $(length(copy.shell_elements)) shells " *
        "and its source has $(length(src.shell_elements))")
    of = Dict{UInt, Int}()
    for pier in struc.wall_mesh.piers
        for sh in pier.shells
            of[objectid(sh)] = pier.wall_index
        end
    end
    walls = Int[]
    for (src_sh, sh) in zip(src.shell_elements, copy.shell_elements)
        iw = get(of, objectid(src_sh), 0)
        (sh.id === :wall) == (iw > 0) || error(
            "scene: shell $(sh.id) has wall index $iw")
        push!(walls, iw)
    end
    return walls
end

"""Skeleton edge of beam `beam_index[el.id]` nearest the midpoint of piece `el`."""
function _story_piece_edge(struc, beam_index, el)
    bi = get(beam_index, el.id, nothing)
    bi === nothing && error("scene: story shell piece $(el.id) names no beam")
    vc = struc.skeleton.geometry.vertex_coords
    mid = [(ustrip(u"m", el.nodeStart.position[k]) + ustrip(u"m", el.nodeEnd.position[k])) / 2
           for k in 1:3]
    best, best_d = 0, Inf
    for seg_idx in segment_indices(struc.beams[bi])
        edge_idx = struc.segments[seg_idx].edge_idx
        v1, v2 = struc.skeleton.edge_indices[edge_idx]
        a = @view vc[v1, :]
        b = @view vc[v2, :]
        ab = b .- a
        L2 = sum(abs2, ab)
        t = L2 > 0 ? clamp(sum((mid .- a) .* ab) / L2, 0.0, 1.0) : 0.0
        d = sum(abs2, mid .- (a .+ t .* ab))
        d < best_d && ((best, best_d) = (edge_idx, d))
    end
    best == 0 && error("scene: beam $bi has no skeleton edge")
    return best
end

"""
    solved_panel_scene_model(design) -> Asap.Model or nothing

The solved frame, plus one triangle fan of each designed slab cell.

The fan uses the cell corners and, on a composite edge, the child nodes
already on that solved frame, so the drawn slab shares the beam's
displacements. It creates no node and it is not solved again. A grade cell is
left out: that floor type is not designed. `nothing` when the structure has
no solved frame.
"""
function solved_panel_scene_model(design::BuildingDesign)
    struc = design.structure
    src = struc.asap_model
    (src === nothing || isempty(src.frame_elements)) && return nothing
    model = copy_solved_model(src)
    n = length(model.frame_elements)
    n_edges = length(struc.skeleton.edge_indices)
    design.asap_model_frame_edge_indices = _scene_frame_edges(struc, n)
    n == n_edges || @warn "Solved frame has $n elements for $n_edges skeleton edges"
    walls = isempty(src.shell_elements) ? Int[] : _copied_shell_walls(struc, src, model)
    panels = Asap.ShellTri3[]
    for (si, slab) in enumerate(struc.slabs)
        slab.floor_type === :grade && continue
        t = thickness(slab)
        t > zero(t) || continue
        id = Symbol("slab_$si")
        E = uconvert(u"Pa", NWC_4000.E)
        for ci in slab.cell_indices
            struc.cells[ci].floor_type === :grade && continue
            boundary = _panel_boundary_nodes(model, struc, struc.cells[ci].face_idx)
            append!(panels, _fan_nodes(boundary, t, E, NWC_4000.ν, id))
        end
    end
    append!(model.shell_elements, panels)
    _ANALYSIS_SHELL_WALLS[model] = vcat(walls, zeros(Int, length(panels)))
    _ANALYSIS_SCENE_KIND[model] = :solved_frame
    design.asap_model = model
    return model
end

"""
Skeleton edge of each solved frame element.

A frame that was not subdivided is one element per skeleton edge. A composite
beam replaces the loaded span with child elements; those children belong to
the same edge. An element with no edge stays 0.
"""
function _scene_frame_edges(struc, n_elements::Int)
    n_skel = length(struc.skeleton.edge_indices)
    edges = zeros(Int, n_elements)
    for edge_idx in 1:min(n_skel, n_elements)
        edges[edge_idx] = edge_idx
    end
    for edge_idx in 1:n_skel
        for el in _frame_element_indices(struc, edge_idx)
            1 <= el <= n_elements || continue
            edges[el] = edge_idx
        end
    end
    return edges
end

"""Triangles of one cell face, fanned from its first vertex. No added nodes."""
function _panel_fan(nodes, vert_indices, t, E, ν, id)
    length(vert_indices) < 3 && return Asap.ShellTri3[]
    chosen = Asap.Node[]
    for v in vert_indices
        1 <= v <= length(nodes) || return Asap.ShellTri3[]
        push!(chosen, nodes[v])
    end
    return _fan_nodes(chosen, t, E, ν, id)
end

"""
Nodes around one cell, in face order.

Corners are the skeleton vertices. A composite edge also contributes the
child nodes already on the solved frame, walking from this corner to the
next. A chain that does not join those two corners is left as the corners,
so a node that was not in the solve is never invented.
"""
function _panel_boundary_nodes(model, struc, face_idx)
    skel = struc.skeleton
    verts = skel.face_vertex_indices[face_idx]
    length(verts) < 3 && return Asap.Node[]
    edges = skel.face_edge_indices[face_idx]
    n = length(model.nodes)
    if length(edges) != length(verts) || any(v -> !(1 <= v <= n), verts)
        return Asap.Node[model.nodes[v] for v in verts if 1 <= v <= n]
    end
    out = Asap.Node[]
    for i in eachindex(verts)
        n1 = model.nodes[verts[i]]
        n2 = model.nodes[verts[mod1(i + 1, length(verts))]]
        chain = _edge_nodes_between(model, struc, edges[i], n1, n2)
        for k in 1:(length(chain) - 1)
            push!(out, chain[k])
        end
    end
    return out
end

"""Child nodes of one skeleton edge, ordered from `n1` to `n2`."""
function _edge_nodes_between(model, struc, edge_idx, n1, n2)
    els = Asap.Element[]
    n_frame = length(model.frame_elements)
    for i in _frame_element_indices(struc, edge_idx)
        1 <= i <= n_frame || continue
        push!(els, model.frame_elements[i])
    end
    length(els) <= 1 && return Asap.Node[n1, n2]
    chain = Asap.Node[els[1].nodeStart]
    joined = true
    for el in els
        if el.nodeStart !== chain[end]
            joined = false
            break
        end
        push!(chain, el.nodeEnd)
    end
    joined || return Asap.Node[n1, n2]
    if chain[1] === n2 && chain[end] === n1
        reverse!(chain)
    elseif !(chain[1] === n1 && chain[end] === n2)
        return Asap.Node[n1, n2]
    end
    return chain
end

"""
Fan one convex cell.

Nodes inserted along an edge are collinear with that edge, so a fan from the
first corner would drop them. Each positive-area corner is clipped off until
the loop is a triangle. A collinear triple is skipped and stays in the loop
until a real corner is removed.
"""
function _fan_nodes(chosen, t, E, ν, id)
    length(chosen) < 3 && return Asap.ShellTri3[]
    poly = collect(chosen)
    out = Asap.ShellTri3[]
    guard = length(poly) * length(poly) + 3
    while length(poly) >= 3 && guard > 0
        guard -= 1
        made = false
        for i in eachindex(poly)
            prev = poly[mod1(i - 1, length(poly))]
            here = poly[i]
            nxt = poly[mod1(i + 1, length(poly))]
            _panel_area_m(prev, here, nxt) > 1e-6 || continue
            sh = Asap.ShellTri3((prev, here, nxt), t, E, ν; id = id)
            Asap.populate_globalID!(sh)
            push!(out, sh)
            deleteat!(poly, i)
            made = true
            break
        end
        made || break
    end
    return out
end

function _panel_area_m(a, b, c)
    ax, ay = ustrip(u"m", a.position[1]), ustrip(u"m", a.position[2])
    bx, by = ustrip(u"m", b.position[1]), ustrip(u"m", b.position[2])
    cx, cy = ustrip(u"m", c.position[1]), ustrip(u"m", c.position[2])
    return abs((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)) / 2
end

"""
Keep a story-shell or grillage scene. A flat plate keeps the shell mesh
[`build_analysis_model!`](@ref) solved, columns and walls with no beam grid.
Anything else is replaced with the solved frame and the cell-face panels.
"""
function _prefer_solve_scene!(design::BuildingDesign)
    model = design.asap_model
    if model !== nothing && analysis_scene_kind(model) in (:story_shell, :grillage, :solved_frame)
        return model
    end
    _kept_plate_mesh(model) && return model
    if _shell_plate_floors(design)
        # The skeleton frame still has the generator's beams. They are not the
        # plate. Drawing them shows their sag while the slab, fanned from the
        # cell corners, barely moves.
        return build_analysis_model!(design)
    end
    story_shell_scene_model(design) !== nothing && return design.asap_model
    local grill = nothing
    try
        grill = grillage_scene_model(design)
    catch err
        @warn "The grillage scene was not copied from the solved frame" exception = (err, catch_backtrace())
    end
    grill !== nothing && return design.asap_model
    return solved_panel_scene_model(design)
end

"True when `build_analysis_model!` stored this model and it contains a slab shell."
function _kept_plate_mesh(model)
    model === nothing && return false
    haskey(_ANALYSIS_SCENE_KIND, model) || return false
    _ANALYSIS_SCENE_KIND[model] === :display_mesh || return false
    return any(sh -> startswith(String(sh.id), "slab"), model.shell_elements)
end

"""
Floors sized as a flat plate or flat slab, with a roof of the same plate.

A grade cell is the support level. A roof is the same plate when every other
designed floor is a flat plate or flat slab.
"""
function _shell_plate_floors(design::BuildingDesign)
    designed = [s for s in design.structure.slabs if s.floor_type !== :grade]
    isempty(designed) && return false
    any(s -> s.floor_type in (:flat_plate, :flat_slab), designed) || return false
    return all(s -> s.floor_type in (:flat_plate, :flat_slab, :roof), designed)
end
