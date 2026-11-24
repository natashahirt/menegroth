# Build frame / loads / solved buffers from an Asap model.
# Displacements follow external/Asap/src/Analysis/displacements.jl (`unodal`).

const SCENE_STAGES = (:frame, :loads, :solved)
const SCENE_MIN_LENGTH = 1e-9

"""
    build_scene(model::Asap.Model; stages=(:frame, :loads, :solved), stations=9) -> ScenePacket

Build a scene packet from a processed (and, for `:solved`, solved) analysis model.

`stages` must be a subset of $(SCENE_STAGES). Unknown names throw. `stations`
is the number of sample points of the member-load particular solution, including
both ends, and must be at least 2.

Positions are meters relative to the minimum node coordinate. The structural
axis Z is up.

`resolve` (default `true`) controls the `:solved` stage: when `true` the model is
re-solved (a plain linkless solve) before the deflected buffers are read. Pass
`resolve = false` to visualize a solution the caller already produced — a
rigid-diaphragm (`solve!(model, links)`) solve, or a specific load case — whose
nodal displacements are already on the nodes; the builder then skips its own
solve and uses them as-is. (A rigid-diaphragm model *must* use `resolve = false`,
since a linkless re-solve of its master nodes is singular.)

`include_shells` (default `false`) appends shell (wall/slab) triangle geometry
for a hand-built model that carries `model.shell_elements` — the bare path
otherwise draws only frame centerlines. Off by default so the design-pipeline
scene builders (which add shells themselves) and existing callers are unchanged.
"""
function build_scene(model::Asap.Model; stages = SCENE_STAGES, stations::Int = 9,
                     resolve::Bool = true, include_shells::Bool = false)
    stage_list = Symbol[Symbol(s) for s in stages]
    for s in stage_list
        s in SCENE_STAGES || error(
            "unknown scene stage :$s; choose from $(SCENE_STAGES)")
    end
    stations >= 2 || error("scene: stations must be >= 2 (got $stations)")

    need_solved = :solved in stage_list
    _prepare_model!(model; solve = need_solved, resolve = resolve)

    elements = model.frame_elements
    nodes = model.nodes
    node_of = Dict{UInt, Int}(objectid(n) => i for (i, n) in enumerate(nodes))
    for (e, elem) in enumerate(elements)
        haskey(Asap.etype2DOF, typeof(elem)) || error(
            "scene: no DOF mask for $(typeof(elem)) (element $e)")
        L = ustrip(u"m", elem.length)
        L >= SCENE_MIN_LENGTH || error("scene: element $e has zero length ($(L) m)")
        haskey(node_of, objectid(elem.nodeStart)) || error("scene: element $e start node is not in the model")
        haskey(node_of, objectid(elem.nodeEnd)) || error("scene: element $e end node is not in the model")
    end

    origin = _scene_origin(nodes)
    buffers = SceneBuffer[]
    if :frame in stage_list
        append!(buffers, _frame_buffers(nodes, elements, node_of, origin))
    end
    if :loads in stage_list
        append!(buffers, _load_buffers(model, nodes, elements, node_of, origin))
    end
    max_disp = 0.0
    if need_solved
        solved, max_disp = _solved_buffers(model, nodes, elements, stations)
        append!(buffers, solved)
    end
    max_axial = 0.0
    if need_solved && !isempty(elements)
        axial, max_axial = _element_axial(model, elements)
        push!(buffers, SceneBuffer("element_axial", axial))
    end

    # Hand-built models carry their shells here (the design-pipeline builders add
    # these in `_with_building_buffers`, so this is opt-in to avoid double-emit).
    n_shell_tri = 0
    if include_shells && !isempty(model.shell_elements)
        faces, kinds, thickness, surf_stress, shell_axial = _shell_faces(model)
        if !isempty(faces)
            push!(buffers, SceneBuffer("shell_faces", faces))
            push!(buffers, SceneBuffer("shell_kind", kinds))
            push!(buffers, SceneBuffer("shell_thickness", thickness))
            length(surf_stress) == length(kinds) && !isempty(surf_stress) &&
                push!(buffers, SceneBuffer("shell_surface_stress", surf_stress))
            length(shell_axial) == length(kinds) && !isempty(shell_axial) &&
                push!(buffers, SceneBuffer("shell_axial", shell_axial))
            n_shell_tri = length(kinds)
        end
    end

    meta = Dict{String, Any}(
        "counts" => Dict{String, Any}(
            "nodes" => length(nodes),
            "elements" => length(elements),
            "shell_triangles" => n_shell_tri,
            "stations" => need_solved ? stations : 0,
        ),
        "stations" => need_solved ? stations : 0,
        "hashes" => Dict{String, Any}(
            "geometry" => _geometry_hash(nodes, elements, node_of),
            "analysis" => need_solved ? _analysis_hash(nodes) : "",
        ),
        "max_displacement" => max_disp,
        "max_axial_n" => max_axial,
        "suggested_scale" => _suggested_scale(elements, max_disp),
    )
    return ScenePacket(String[string(s) for s in stage_list], origin, meta, buffers)
end

"""
    build_scene(struc::BuildingStructure; kwargs...) -> ScenePacket

Scene of `struc.asap_model`, plus its shell triangles and footing boxes.
Footing sizes are the sized results (`footing_length`, `footing_width`,
`footing_depth`), centered on the support vertices. A mat uses its own
plan axes. A wall strip that turns a corner uses the extent of its legs.
"""
function build_scene(struc::BuildingStructure; kwargs...)
    packet = build_scene(struc.asap_model; kwargs...)
    footings = [_footing_row(struc, fdn,
                             StructuralSizer.footing_length(fdn.result),
                             StructuralSizer.footing_width(fdn.result),
                             StructuralSizer.footing_depth(fdn.result))
                for fdn in struc.foundations]
    return _with_building_buffers(packet, struc.asap_model, struc, footings, _column_vertex_offsets(struc))
end

"""
    build_scene(design::BuildingDesign; kwargs...) -> ScenePacket

Scene of the model that was solved. A story-shell floor keeps that shell
mesh. A grillage keeps that frame. A flat plate or flat slab keeps the shell
mesh from [`build_analysis_model!`](@ref), columns and walls, not the
generator's beams. Any other floor keeps the solved frame and draws each
slab cell as the triangles of its own vertices. [`build_analysis_model!`](@ref)
is used when there is no solved frame, and for a flat plate that has not yet
been meshed. Shell triangles deflect with the same nodal displacements as the
frame. Footings are
`design.foundations`, centered on the support columns with the design's
structural offsets, as the JSON visualization does. The dossier for each
footing also carries its type, analysis, walls, and reinforcement.
"""
function build_scene(design::BuildingDesign; kwargs...)
    _prefer_solve_scene!(design)
    isnothing(design.asap_model) && build_analysis_model!(design)
    model = design.asap_model
    struc = design.structure
    packet = build_scene(model; kwargs...)
    footings = Tuple[]
    for (idx, fdn) in enumerate(struc.foundations)
        res = get(design.foundations, idx, nothing)
        isnothing(res) && continue
        push!(footings, _footing_row(struc, fdn, res.length, res.width, res.depth))
    end
    packet = _with_building_buffers(packet, model, struc, footings, design.structural_offsets)
    packet = _with_shell_walls(packet, model)
    packet = _with_member_solids(packet, design, model)
    packet = _with_tributaries(packet, design)
    return _with_component_records(packet, design, model)
end

"""Centroid rectangle, width then depth, in the section's local y-z frame."""
function _rect_polygon(width_m::Float64, depth_m::Float64)
    y = width_m / 2
    z = depth_m / 2
    return [[-y, -z], [y, -z], [y, z], [-y, z]]
end

"""
Per frame element `(section_obj, orientation, section_name)` from the design's
column and beam results, or `nothing` when the element has no sized section.

A solid-head piece is not catalog-sized, so it has no design section. Its
outline is the rectangle the frame already uses for that piece, and the
first entry is that polygon instead of a section object. Elements map to
skeleton edges through `design.asap_model_frame_edge_indices`, as in the
JSON frame visualization.
"""
function _member_sections(design::BuildingDesign, model::Asap.Model)
    struc = design.structure
    by_edge = Dict{Int, Tuple{Any, Float64, String}}()
    for (col_idx, result) in design.columns
        col_idx > length(struc.columns) && continue
        sec = result.section_obj
        isnothing(sec) && continue
        col = struc.columns[col_idx]
        for seg_idx in segment_indices(col)
            seg_idx > length(struc.segments) && continue
            by_edge[struc.segments[seg_idx].edge_idx] = (sec, Float64(ustrip(col.θ)), string(result.section_size))
        end
    end
    for (beam_idx, result) in design.beams
        beam_idx > length(struc.beams) && continue
        sec = result.section_obj
        isnothing(sec) && continue
        for seg_idx in segment_indices(struc.beams[beam_idx])
            seg_idx > length(struc.segments) && continue
            by_edge[struc.segments[seg_idx].edge_idx] = (sec, 0.0, string(result.section_size))
        end
    end
    heads = solid_head_rectangles_m(struc)
    edge_beam = Dict{Int, Int}()
    for (bi, beam) in enumerate(struc.beams)
        haskey(heads, bi) || continue
        for seg_idx in segment_indices(beam)
            seg_idx > length(struc.segments) && continue
            edge_beam[struc.segments[seg_idx].edge_idx] = bi
        end
    end
    edges = design.asap_model_frame_edge_indices
    length(edges) == length(model.frame_elements) || error(
        "scene: analysis model has $(length(model.frame_elements)) frame elements but " *
        "$(length(edges)) edge indices; cannot attach sized sections")
    out = Vector{Union{Nothing, Tuple{Any, Float64, String}}}(undef, length(edges))
    for (k, edge_idx) in enumerate(edges)
        # A grown head is the pans left filled: a slab of the rib depth, not the
        # catalog T-beam that was sized for the rib before the head took it.
        bi = get(edge_beam, edge_idx, 0)
        rect = get(heads, bi, nothing)
        if rect !== nothing
            out[k] = (_rect_polygon(rect[1], rect[2]), 0.0, "solid head")
            continue
        end
        out[k] = get(by_edge, edge_idx, nothing)
    end
    return out
end

"""Plan polygons of every slab, in absolute metres. A slab with no interior is skipped."""
function _story_slab_polygons(struc)
    polys = Vector{NTuple{2, Float64}}[]
    for slab in struc.slabs
        poly = _slab_interior_polygon_m(struc, slab)
        poly === nothing && continue
        push!(polys, poly)
    end
    return polys
end

"""`true` when `(x, y)` is strictly inside one of `polys`."""
function _inside_any_slab(x::Float64, y::Float64, polys)
    for poly in polys
        _point_on_polygon_boundary(x, y, poly; tol = 1e-4) && continue
        _point_in_polygon_xy(x, y, poly) && return true
    end
    return false
end

"""
Which side of local `+y` the slab occupies, or `0` when the drawing stays centered.

`+1` and `-1` are the section width axis of [`_section_frame`](@ref). A probe
50 mm off the centerline asks only which side is inside the slab. That distance
is a drawing test, not a flange width. Both sides inside, or neither, keeps the
centered section: an interior T-beam, and a stem with no overhang.
"""
function _flange_draw_side(p1, p2, θ::Float64, sec, polys, origin::NTuple{3, Float64})
    sec isa StructuralSizer.RCTBeamSection || return 0
    bw = ustrip(u"m", sec.bw)
    bf = ustrip(u"m", StructuralSizer.flange_width(sec))
    bf > bw + 1e-6 || return 0
    frame = _section_frame(p1, p2, θ)
    frame === nothing && return 0
    mid = ((p1[1] + p2[1]) / 2 + origin[1], (p1[2] + p2[2]) / 2 + origin[2])
    probe = 0.05
    hits = Int[]
    for sign in (1, -1)
        x = mid[1] + sign * probe * frame.y[1]
        y = mid[2] + sign * probe * frame.y[2]
        _inside_any_slab(x, y, polys) && push!(hits, sign)
    end
    return length(hits) == 1 ? hits[1] : 0
end

"""
Section outline to draw, in the centroid frame of `section_polygon`.

`side` is `0` for the centered outline flexure uses. `+1` or `-1` moves only
the flange: the stem stays on the member axis, the outside face of the flange
is flush with the outside face of the stem, and the overhang lies on that side
of local `+y`. A flange no wider than the stem is left as stored. Bars stay
where the section placed them.
"""
function _edge_flange_outline(sec, side::Int)
    isnothing(sec) && return nothing
    centered = [[Float64(y), Float64(z)] for (y, z) in StructuralSizer.section_polygon(sec)]
    (side == 0 || !(sec isa StructuralSizer.RCTBeamSection)) && return centered
    bw = ustrip(u"m", sec.bw)
    bf = ustrip(u"m", StructuralSizer.flange_width(sec))
    bf > bw + 1e-6 || return centered
    length(centered) >= 5 || return centered
    z_bot = centered[1][2]
    z_flange_bot = centered[3][2]
    z_top = centered[5][2]
    if side > 0
        y_out = -bw / 2
        y_in = y_out + bf
        return [
            [y_out, z_bot], [bw / 2, z_bot], [bw / 2, z_flange_bot],
            [y_in, z_flange_bot], [y_in, z_top], [y_out, z_top],
        ]
    end
    y_out = bw / 2
    y_in = y_out - bf
    return [
        [-bw / 2, z_bot], [y_out, z_bot], [y_out, z_top],
        [y_in, z_top], [y_in, z_flange_bot], [-bw / 2, z_flange_bot],
    ]
end

"""
`+1` or `-1` when any piece of the member has the slab on only that side of
its width axis. `0` when the drawing stays centered. `elem_ids` are 0-based.
"""
function _member_flange_side(model, elem_ids, sec, polys, origin::NTuple{3, Float64})
    sec isa StructuralSizer.RCTBeamSection || return 0
    for e in elem_ids
        0 <= e < length(model.frame_elements) || continue
        p1, p2 = _eccentric_ends(model.frame_elements[e + 1], origin)
        side = _flange_draw_side(p1, p2, 0.0, sec, polys, origin)
        side == 0 || return side
    end
    return 0
end

"""
Stem of a concrete T-beam, seated with its top on the slab soffit.

The flange is the shell, so it is not extruded again. The polygon is the
stem, centered on its own centroid. A story-shell element already carries
that offset in its eccentricity, and its axis is left alone. A concentric
rib under a shell moves down the section depth axis by half the slab
thickness plus half the stem. `nothing` when there is no separate slab:
the full T, flange included, stays on the node.
"""
function _rib_stem_below_slab(sec::StructuralSizer.RCTBeamSection, elem, p1, p2, θ, model, origin)
    stem = ustrip(u"m", sec.h - sec.hf)
    stem > 1e-6 || return nothing
    poly = _rect_polygon(ustrip(u"m", sec.bw), stem)
    _element_eccentricity(elem)[3] != 0 && return (poly, p1, p2)
    h_slab = _shell_thickness_near(model, p1, p2, origin)
    h_slab === nothing && return nothing
    frame = _section_frame(p1, p2, θ)
    frame === nothing && return nothing
    drop = h_slab / 2 + stem / 2
    shift = [-drop * frame.z[k] for k in 1:3]
    return (poly, p1 .+ shift, p2 .+ shift)
end

"""Slab thickness, in metres, of the nearest horizontal shell to the member midpoint."""
function _shell_thickness_near(model, p1, p2, origin::NTuple{3, Float64})
    mx = (p1[1] + p2[1]) / 2 + origin[1]
    my = (p1[2] + p2[2]) / 2 + origin[2]
    mz = (p1[3] + p2[3]) / 2 + origin[3]
    best = Inf
    h = nothing
    for sh in model.shell_elements
        zs = Float64[ustrip(u"m", n.position[3]) for n in sh.nodes]
        maximum(zs) - minimum(zs) > 0.05 && continue
        cz = sum(zs) / length(zs)
        abs(cz - mz) > 0.25 && continue
        xs = Float64[ustrip(u"m", n.position[1]) for n in sh.nodes]
        ys = Float64[ustrip(u"m", n.position[2]) for n in sh.nodes]
        d = hypot(sum(xs) / length(xs) - mx, sum(ys) / length(ys) - my)
        d < best || continue
        best = d
        h = Float64(sh.thickness)
    end
    return best < 8 && h !== nothing && h > 0 ? h : nothing
end

"""
Sized member solids: each element's section polygon swept along its eccentric
section axis with `_build_frame_element_mesh` (the JSON sized-mode mesh). A
concentric element stays on the node line. Hollow sections are left to the
centerline, as in the JSON path. Adds `member_solid_position`,
`member_solid_faces` (0-based into the solid positions),
`member_solid_element` (one element index per triangle), and the header list
`element_section`.

A concrete T-beam with the slab on one side is drawn with the flange on that
side. The width used by flexure is unchanged.
"""
function _with_member_solids(packet::ScenePacket, design::BuildingDesign, model::Asap.Model)
    sections = _member_sections(design, model)
    polys = _story_slab_polygons(design.structure)
    origin = packet.origin
    pos = Float32[]
    faces = UInt32[]
    owner = UInt32[]
    names = String[]
    # A solid head is the bays cast solid, not another rib extrusion. Those
    # frame elements keep the name "solid head" and the region is drawn instead.
    head_drawn = _append_solid_head_regions!(pos, faces, owner, design, origin)
    for (e, elem) in enumerate(model.frame_elements)
        entry = sections[e]
        push!(names, isnothing(entry) ? "" : entry[3])
        isnothing(entry) && continue
        e in head_drawn && continue
        sec, θ, _ = entry
        p1, p2 = _eccentric_ends(elem, origin)
        # A rib under a drawn slab keeps its flange in that slab. The solid is
        # the stem, and the top of the stem meets the soffit. A T with no
        # plate keeps the flange, which is then the only slab in the picture.
        rib = sec isa StructuralSizer.RCTBeamSection ?
            _rib_stem_below_slab(sec, elem, p1, p2, θ, model, origin) : nothing
        if rib !== nothing
            p1, p2 = rib[2], rib[3]
        end
        poly = if rib !== nothing
            rib[1]
        elseif sec isa Vector
            sec
        elseif sec isa StructuralSizer.RCTBeamSection
            side = _flange_draw_side(p1, p2, θ, sec, polys, origin)
            _edge_flange_outline(sec, side)
        else
            isempty(StructuralSizer.section_polygon_inner(sec)) || continue
            [[Float64(y), Float64(z)] for (y, z) in StructuralSizer.section_polygon(sec)]
        end
        verts, tris = _build_frame_element_mesh(poly, p1, p2, θ)
        isempty(tris) && continue
        base = length(pos) ÷ 3
        for v in verts
            push!(pos, Float32(v[1]), Float32(v[2]), Float32(v[3]))
        end
        for t in tris
            push!(faces, UInt32(base + t[1] - 1), UInt32(base + t[2] - 1), UInt32(base + t[3] - 1))
            push!(owner, UInt32(e - 1))
        end
    end
    meta = copy(packet.meta)
    meta["element_section"] = names
    kind = analysis_scene_kind(model)
    meta["analysis_model"] = String(kind)
    if kind === :story_shell
        drawn = analysis_drawn_only(model)
        meta["analysis_state"] = join(sort!(unique(String.(values(drawn.states)))), ", ")
        meta["drawn_only_elements"] = sort!([e - 1 for e in drawn.frames])
    end
    counts = copy(meta["counts"])
    counts["member_solid_triangles"] = length(owner)
    meta["counts"] = counts
    extra = isempty(owner) ? SceneBuffer[] : SceneBuffer[
        SceneBuffer("member_solid_position", pos),
        SceneBuffer("member_solid_faces", faces),
        SceneBuffer("member_solid_element", owner),
    ]
    return ScenePacket(packet.stages, packet.origin, meta, vcat(packet.buffers, extra))
end

"""
The bays cast solid, as one prism per bay.

The top of the prism is the top of the sized slab. The slab is centered on
the analysis elevation, and the head depth runs from that top down to the
rib soffit. Frame elements of those pieces are returned so their beam
extrusion is not drawn over the prism. A level whose ribs are not sized yet
adds nothing.
"""
function _append_solid_head_regions!(pos, faces, owner, design::BuildingDesign, origin)
    drawn = Set{Int}()
    struc = design.structure
    edges = getproperty(design, :asap_model_frame_edge_indices)
    edge_elem = Dict{Int, Int}(e => k for (k, e) in enumerate(edges))
    for slab in struc.slabs
        for level in slab.framing_levels
            isempty(level.solid_heads) && continue
            depth = _scene_head_depth(struc, level)
            depth === nothing && continue
            elems = _solid_head_frame_elements(struc, level, edge_elem)
            isempty(elems) && continue
            arr, _ = grillage_bays(struc, slab, level)
            z = _slab_face_z_m(struc, slab)
            h = depth
            z_top, z_bot = _solid_head_band(z, h, _scene_topping_m(slab))
            z_top -= origin[3]
            z_bot -= origin[3]
            for head in level.solid_heads
                for bi in head.bays
                    1 <= bi <= length(arr.bays) || continue
                    loop = arr.bays[bi].loop
                    length(loop) < 3 && continue
                    xy = [(arr.nodes[i][1] - origin[1], arr.nodes[i][2] - origin[2]) for i in loop]
                    _extrude_plan_polygon!(pos, faces, owner, xy, z_top, z_bot, first(elems))
                end
            end
            union!(drawn, elems)
        end
    end
    return drawn
end

"""
Vertical band of a solid head, structural Z up, before the scene origin.

`z` is the analysis elevation. The sized slab is centered on it, so the head's
top is half a topping above that line. `depth` is the full head, from that top
to the rib soffit. With no topping the prism stays centered on `z`.
"""
function _solid_head_band(z::Real, depth::Real, topping)
    h = Float64(depth)
    t = topping === nothing ? nothing : Float64(topping)
    if t === nothing || !(0 < t <= h)
        return (z + h / 2, z - h / 2)
    end
    top = z + t / 2
    return (top, top - h)
end

"""Sized slab thickness in metres, or `nothing` when the slab has no result."""
function _scene_topping_m(slab)
    slab.result === nothing && return nothing
    return Float64(ustrip(u"m", _story_metres(thickness(slab))))
end

"""Deepest concrete rib outside the head, in metres, or `nothing`.

A level that is not concrete ribs keeps the beam drawing, so this returns
`nothing` instead of raising.
"""
function _scene_head_depth(struc, level)
    depths = Float64[]
    gid = level.solid_group_id
    for bi in level_member_indices(struc, level)
        gid !== nothing && group_id(struc.beams[bi]) == gid && continue
        sec = section(struc.beams[bi])
        sec === nothing && continue
        h = _concrete_rib_depth(sec)
        h === nothing && return nothing
        push!(depths, ustrip(u"m", h))
    end
    return isempty(depths) ? nothing : maximum(depths)
end

"""1-based frame elements of a level's solid-head pieces."""
function _solid_head_frame_elements(struc, level, edge_elem)
    out = Int[]
    gid = level.solid_group_id
    gid === nothing && return out
    for bi in level_member_indices(struc, level)
        group_id(struc.beams[bi]) == gid || continue
        for si in segment_indices(struc.beams[bi])
            k = get(edge_elem, struc.segments[si].edge_idx, 0)
            k > 0 && push!(out, k)
        end
    end
    return unique!(out)
end

"""A plan polygon extruded from `z_top` down to `z_bot`. `elem` is 1-based."""
function _extrude_plan_polygon!(pos, faces, owner, xy, z_top, z_bot, elem::Int)
    n = length(xy)
    n >= 3 || return pos
    base = length(pos) ÷ 3
    for (x, y) in xy
        push!(pos, Float32(x), Float32(y), Float32(z_top))
    end
    for (x, y) in xy
        push!(pos, Float32(x), Float32(y), Float32(z_bot))
    end
    function tri(a, b, c)
        push!(faces, UInt32(base + a), UInt32(base + b), UInt32(base + c))
        push!(owner, UInt32(elem - 1))
    end
    for i in 1:(n - 2)
        tri(0, i, i + 1)
        tri(n, n + i + 1, n + i)
    end
    for i in 0:(n - 1)
        j = mod(i + 1, n)
        tri(i, j, n + j)
        tri(i, n + j, n + i)
    end
    return pos
end

"""
`shell_wall`: the `struc.walls` index (1-based, the wall record's
`design_index`) of each `shell_faces` triangle, 0 for a triangle that is not a
wall. The index comes from the wall mesher, so a pier meshed on offset column
centerlines still names its own wall.
"""
function _with_shell_walls(packet::ScenePacket, model::Asap.Model)
    isempty(model.shell_elements) && return packet
    walls = analysis_shell_walls(model)
    walls === nothing && error(
        "scene: the analysis model has no wall index list; build it with build_analysis_model!")
    length(walls) == length(model.shell_elements) || error(
        "scene: analysis model has $(length(model.shell_elements)) shells but " *
        "$(length(walls)) wall indices; rebuild it with build_analysis_model!")
    for (sh, iw) in zip(model.shell_elements, walls)
        (sh.id === :wall) == (iw > 0) || error(
            "scene: shell $(sh.id) has wall index $iw; the wall index list is out of date")
    end
    buf = SceneBuffer("shell_wall", UInt32.(walls))
    return ScenePacket(packet.stages, packet.origin, packet.meta, vcat(packet.buffers, [buf]))
end

"""Shell kind codes in `shell_kind`. See docs/src/reference/scene_format.md."""
const SHELL_KIND_SLAB = 0x00
const SHELL_KIND_WALL = 0x01
const SHELL_KIND_PATCH = 0x02
const SHELL_KIND_OTHER = 0x03

function _shell_kind(id::Symbol)::UInt8
    id === :wall && return SHELL_KIND_WALL
    id in (:drop_panel, :col_patch, :patch) && return SHELL_KIND_PATCH
    id in (:story, :panel) && return SHELL_KIND_SLAB
    startswith(String(id), "slab") && return SHELL_KIND_SLAB
    return SHELL_KIND_OTHER
end

function _with_building_buffers(packet::ScenePacket, model::Asap.Model, struc::BuildingStructure,
                                footings, offsets)
    extra = SceneBuffer[]
    faces, kinds, thickness, stress, axial = _shell_faces(model)
    if !isempty(faces)
        push!(extra, SceneBuffer("shell_faces", faces))
        push!(extra, SceneBuffer("shell_kind", kinds))
        push!(extra, SceneBuffer("shell_thickness", thickness))
    end
    if length(stress) == length(kinds) && !isempty(stress)
        push!(extra, SceneBuffer("shell_surface_stress", stress))
    end
    if length(axial) == length(kinds) && !isempty(axial)
        push!(extra, SceneBuffer("shell_axial", axial))
    end
    centers, sizes, support_nodes, support_counts, footing_kinds = _footing_arrays(
        model, struc, footings, offsets, packet.origin)
    if !isempty(centers)
        push!(extra, SceneBuffer("footing_center", centers))
        push!(extra, SceneBuffer("footing_size", sizes))
        push!(extra, SceneBuffer("footing_kind", footing_kinds))
        push!(extra, SceneBuffer("footing_support_node", support_nodes))
        push!(extra, SceneBuffer("footing_support_count", support_counts))
    end
    isempty(extra) && return packet
    meta = copy(packet.meta)
    counts = copy(meta["counts"])
    counts["shell_triangles"] = length(kinds)
    counts["footings"] = length(centers) ÷ 3
    if !isempty(stress)
        meta["max_surface_stress_pa"] = maximum(abs, stress)
    end
    meta["counts"] = counts
    return ScenePacket(packet.stages, packet.origin, meta, vcat(packet.buffers, extra))
end

"""
0-based triangle indices into the node table, one kind code per triangle, and
the signed surface stress and vertical membrane force once the model is solved.

Stress is the same scalar the JSON view stores as `face_surface_stress`: the
dominant principal stress at the top or bottom surface, in pascals, tension
positive. Axial is [`_shell_vertical_force`](@ref), newtons per metre, tension
positive. An unsolved model (nodal displacement not yet assigned) returns
empty stress and axial vectors rather than fields of zeros.
"""
function _shell_faces(model::Asap.Model)
    node_of = Dict{UInt, Int}(objectid(n) => i for (i, n) in enumerate(model.nodes))
    faces = UInt32[]
    kinds = UInt8[]
    thickness = Float32[]
    solved = !isempty(model.nodes) && isassigned(model.nodes[1].displacement, 1)
    surf = Float64[]
    axial = Float64[]
    bending = Float64[]
    membrane = Float64[]
    shear = Float64[]
    vm = Float64[]
    ws = Asap.ShellForcesWorkspace()
    for elem in model.shell_elements
        length(elem.nodes) == 3 || error(
            "scene: shell $(elem.id) has $(length(elem.nodes)) nodes; only triangles are supported")
        for n in elem.nodes
            i = get(node_of, objectid(n), 0)
            i == 0 && error("scene: a shell node of $(elem.id) is not in the analysis model")
            push!(faces, UInt32(i - 1))
        end
        push!(kinds, _shell_kind(elem.id))
        push!(thickness, Float32(elem.thickness))
        # A panel triangle drawn on the solved frame was not in that solve.
        if solved && elem.elementID != 0
            _append_shell_analytical!(bending, membrane, shear, vm, surf, elem, model.u, ws;
                                      axial = axial)
        end
    end
    return faces, kinds, thickness, Float32.(surf), Float32.(axial)
end

"""
Column centerline offsets, meters, keyed by skeleton vertex. The same map
`to_asap!` bakes into `struc.asap_model`.
"""
function _column_vertex_offsets(struc::BuildingStructure)
    offsets = Dict{Int, NTuple{2, Float64}}()
    skel = struc.skeleton
    for col in struc.columns
        off = col.structural_offset
        (off[1] == 0.0 && off[2] == 0.0) && continue
        for seg_idx in segment_indices(col)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            (edge_idx < 1 || edge_idx > length(skel.edge_indices)) && continue
            v1, v2 = skel.edge_indices[edge_idx]
            offsets[v1] = off
            offsets[v2] = off
        end
    end
    return offsets
end

"""
0-based analysis-model node for a skeleton support vertex. Skeleton nodes stay
at the front of the model (`_merge_shell_nodes` appends mesh nodes), and the
position has to match the vertex plus its structural offset.
"""
function _checked_support_node(model::Asap.Model, vertex_idx::Int, expected::NTuple{3, Float64})
    (1 <= vertex_idx <= length(model.nodes)) || error(
        "scene: support vertex $vertex_idx is not a node of the analysis model ($(length(model.nodes)) nodes)")
    node = model.nodes[vertex_idx]
    actual = ntuple(i -> ustrip(u"m", node.position[i]), 3)
    for k in 1:3
        abs(actual[k] - expected[k]) <= 1e-3 || error(
            "scene: analysis node $vertex_idx is at $(actual) m, not the support at $(expected) m")
    end
    return UInt32(vertex_idx - 1)
end

"""Support-node indices for one footing. Empty `support_indices` yields an empty list."""
function _footing_support_nodes(model::Asap.Model, struc::BuildingStructure, support_indices, offsets)
    out = UInt32[]
    skel = struc.skeleton
    for sup_idx in support_indices
        (1 <= sup_idx <= length(struc.supports)) || error(
            "scene: foundation support index $sup_idx is outside the support list")
        v_idx = struc.supports[sup_idx].vertex_idx
        (1 <= v_idx <= length(skel.vertices)) || error(
            "scene: support vertex $v_idx is outside the skeleton")
        c = Meshes.coords(skel.vertices[v_idx])
        off = get(offsets, v_idx, (0.0, 0.0))
        expected = (ustrip(u"m", c.x) + off[1], ustrip(u"m", c.y) + off[2], ustrip(u"m", c.z))
        push!(out, _checked_support_node(model, v_idx, expected))
    end
    return out
end

# `footing_kind`. A file written before this buffer is all spreads.
const _FOOTING_KIND = Dict{Symbol, UInt8}(
    :spread => 0x00,
    :strip => 0x01,
    :combined => 0x02,
    :mat => 0x03,
    :wall_strip => 0x04,
)

"""Byte stored in `footing_kind` for a foundation type the scene can draw."""
function _footing_kind(ftype::Symbol)
    haskey(_FOOTING_KIND, ftype) && return _FOOTING_KIND[ftype]
    known = join(sort(string.(keys(_FOOTING_KIND))), ", ")
    error("scene: $ftype foundations are not drawn; expected one of $known")
end

"""
One footing row: supports, plan length, plan width, depth, type, and the
grade-wall centerlines that footing carries. Length is `L_ftg` and width is `B`.
"""
function _footing_row(struc, fdn, L, W, D)
    segs = NTuple{4, Float64}[]
    for i in fdn.wall_indices
        1 <= i <= length(struc.walls) || continue
        w = struc.walls[i]
        push!(segs, (w.x1, w.y1, w.x2, w.y2))
    end
    return (fdn.support_indices, L, W, D, fdn.foundation_type, segs)
end

"""
Plan size `(x, y)` in meters.

A mat stores `B` across X and `L_ftg` across Y. A spread or a strip stores
`L_ftg` along its long axis and `B` across it. Supports that span farther in
Y put that long axis on Y. One support keeps the length on X.
"""
function _footing_plan_xy(ftype::Symbol, L::Real, W::Real, xs, ys)
    ftype === :mat && return (float(W), float(L))
    span_x = isempty(xs) ? 0.0 : maximum(xs) - minimum(xs)
    span_y = isempty(ys) ? 0.0 : maximum(ys) - minimum(ys)
    span_y > span_x + 1e-3 && return (float(W), float(L))
    return (float(L), float(W))
end

"""`:x` or `:y` when a wall centerline is axis-aligned, otherwise `:other`."""
function _leg_axis(x1, y1, x2, y2)
    dx, dy = x2 - x1, y2 - y1
    len = hypot(dx, dy)
    len < 1e-6 && return nothing
    abs(dy) <= 1e-3 && return :x
    abs(dx) <= 1e-3 && return :y
    return :other
end

"""True when every wall centerline shares one axis. An empty list is one strip."""
function _legs_colinear(segs)
    axis = nothing
    for (x1, y1, x2, y2) in segs
        leg = _leg_axis(x1, y1, x2, y2)
        leg === nothing && continue
        axis === nothing && (axis = leg)
        axis == leg || return false
    end
    return axis !== :other
end

"""
Axis-aligned extent of wall centerlines thickened by `half_w` on each side.
The corner inside an L is inside this box. The dossier says so.
"""
function _leg_extent(segs, half_w)
    xmin = ymin = Inf
    xmax = ymax = -Inf
    found = false
    for (x1, y1, x2, y2) in segs
        dx, dy = x2 - x1, y2 - y1
        len = hypot(dx, dy)
        len < 1e-9 && continue
        found = true
        px, py = -dy / len * half_w, dx / len * half_w
        for (x, y) in ((x1, y1), (x2, y2))
            xmin = min(xmin, x + px, x - px)
            xmax = max(xmax, x + px, x - px)
            ymin = min(ymin, y + py, y - py)
            ymax = max(ymax, y + py, y - py)
        end
    end
    found || return nothing
    return (xmin, xmax, ymin, ymax)
end

"""
Footing box centers, sizes, and kinds from footing rows.
The center is the box centroid, half a depth below the lowest support, relative
to `origin`. Size is `(x, y, depth)` in meters.
`offsets` maps a support vertex to its structural `(dx, dy)` in meters.
`footing_support_node` is the flat list of 0-based analysis nodes, and
`footing_support_count` is how many of those belong to each footing.
A straight footing is centered on its supports. A wall strip that turns a
corner is the extent of its legs.
"""
function _footing_arrays(model::Asap.Model, struc::BuildingStructure, footings, offsets, origin::NTuple{3, Float64})
    centers = Float32[]
    sizes = Float32[]
    support_nodes = UInt32[]
    support_counts = UInt32[]
    kinds = UInt8[]
    for (support_indices, Lq, Wq, Dq, ftype, segs) in footings
        nodes = _footing_support_nodes(model, struc, support_indices, offsets)
        isempty(nodes) && continue
        xs = Float64[]
        ys = Float64[]
        zs = Float64[]
        for node_index in nodes
            n = model.nodes[Int(node_index) + 1]
            push!(xs, ustrip(u"m", n.position[1]))
            push!(ys, ustrip(u"m", n.position[2]))
            push!(zs, ustrip(u"m", n.position[3]))
        end
        append!(support_nodes, nodes)
        push!(support_counts, UInt32(length(nodes)))
        L = ustrip(u"m", Lq)
        W = ustrip(u"m", Wq)
        D = ustrip(u"m", Dq)
        (L > 0 && W > 0 && D > 0) || error(
            "scene: footing has a non-positive size ($(L), $(W), $(D)) m")
        z_mid = minimum(zs) - D / 2
        extent = ftype === :wall_strip && !_legs_colinear(segs) ? _leg_extent(segs, W / 2) : nothing
        if extent === nothing
            sx, sy = _footing_plan_xy(ftype, L, W, xs, ys)
            cx = sum(xs) / length(xs) - origin[1]
            cy = sum(ys) / length(ys) - origin[2]
        else
            xmin, xmax, ymin, ymax = extent
            sx, sy = xmax - xmin, ymax - ymin
            cx = (xmin + xmax) / 2 - origin[1]
            cy = (ymin + ymax) / 2 - origin[2]
        end
        (sx > 0 && sy > 0) || error(
            "scene: footing has a non-positive plan ($(sx), $(sy)) m")
        push!(centers, Float32(cx), Float32(cy), Float32(z_mid - origin[3]))
        push!(sizes, Float32(sx), Float32(sy), Float32(D))
        push!(kinds, _footing_kind(ftype))
    end
    return centers, sizes, support_nodes, support_counts, kinds
end

function _prepare_model!(model::Asap.Model; solve::Bool, resolve::Bool = true)
    model.processed || Asap.process!(model)
    # process! allocates a zero displacement vector, so `isempty(model.u)` is not
    # a signal that the model has been solved. The solved stage always solves,
    # then copies joint results onto the nodes — unless `resolve = false`, where
    # the caller has already produced the displacements it wants drawn (a
    # rigid-diaphragm `solve!(model, links)` or a specific load case) and a plain
    # re-solve would discard them (or be singular for a master/slave model).
    if solve && resolve
        Asap.solve!(model)
        Asap.post_process!(model)
    end
    if solve
        _displacements_ready(model) || error(
            resolve ? "scene: post_process! did not fill nodal displacements" :
                      "scene: resolve=false but the model has no solved nodal " *
                      "displacements; solve!(model[, links]) + post_process!(model) first")
    end
    return model
end

function _displacements_ready(model::Asap.Model)
    isempty(model.nodes) && return true
    d = first(model.nodes).displacement
    return isassigned(d, 1)
end

function _scene_origin(nodes)
    isempty(nodes) && return (0.0, 0.0, 0.0)
    xs = Float64[]
    ys = Float64[]
    zs = Float64[]
    for n in nodes
        push!(xs, ustrip(u"m", n.position[1]))
        push!(ys, ustrip(u"m", n.position[2]))
        push!(zs, ustrip(u"m", n.position[3]))
    end
    return (minimum(xs), minimum(ys), minimum(zs))
end

function _frame_buffers(nodes, elements, node_of, origin)
    pos = Vector{Float32}(undef, 3 * length(nodes))
    for (i, n) in enumerate(nodes)
        pos[3i - 2] = Float32(ustrip(u"m", n.position[1]) - origin[1])
        pos[3i - 1] = Float32(ustrip(u"m", n.position[2]) - origin[2])
        pos[3i]     = Float32(ustrip(u"m", n.position[3]) - origin[3])
    end
    pairs = Vector{UInt32}(undef, 2 * length(elements))
    types = Vector{UInt8}(undef, length(elements))
    stories = zeros(UInt16, length(elements))
    eccentricity = Vector{Float32}(undef, 4 * length(elements))
    for (e, elem) in enumerate(elements)
        pairs[2e - 1] = UInt32(node_of[objectid(elem.nodeStart)] - 1)
        pairs[2e]     = UInt32(node_of[objectid(elem.nodeEnd)] - 1)
        types[e] = _element_type_code(elem)
        ex = _element_eccentricity(elem)
        eccentricity[4e - 3] = ex[1]
        eccentricity[4e - 2] = ex[2]
        eccentricity[4e - 1] = ex[3]
        eccentricity[4e]     = ex[4]
    end
    return SceneBuffer[
        SceneBuffer("node_position", pos),
        SceneBuffer("element_nodes", pairs),
        SceneBuffer("element_type", types),
        SceneBuffer("element_story", stories),
        SceneBuffer("element_eccentricity", eccentricity),
    ]
end

"""`(e_start_f1, e_end_f1, e_f2, e_f3)` in meters. An element without the field is concentric."""
function _element_eccentricity(elem)
    hasproperty(elem, :eccentricity) || return ntuple(_ -> 0.0f0, 4)
    ecc = elem.eccentricity
    return ntuple(i -> Float32(ecc[i]), 4)
end

"""End points of the section axis. A concentric element stays on the node line.

The offset is `eccentricity` along the element's local axes, the same four
numbers Asap stores. Nonzero eccentricity with unset axes is an error.
"""
function _eccentric_ends(elem, origin::NTuple{3, Float64})
    p1 = [ustrip(u"m", elem.nodeStart.position[k]) - origin[k] for k in 1:3]
    p2 = [ustrip(u"m", elem.nodeEnd.position[k]) - origin[k] for k in 1:3]
    e1, e2, ef2, ef3 = _element_eccentricity(elem)
    if e1 == 0 && e2 == 0 && ef2 == 0 && ef3 == 0
        return p1, p2
    end
    f1, f2, f3 = elem.LCS
    (sum(abs2, f1) > 0.25 && sum(abs2, f2) > 0.25) || error(
        "frame element $(elem.id) has eccentricity but its local axes are unset")
    shift(p, axial) = [p[k] + axial * f1[k] + ef2 * f2[k] + ef3 * f3[k] for k in 1:3]
    return shift(p1, e1), shift(p2, e2)
end

"""0 beam, 1 column, 2 brace. A near-vertical member with no name hint is a column."""
function _element_type_code(elem)::UInt8
    name = lowercase(string(elem.id))
    if occursin("brace", name) || occursin("strut", name)
        return 0x02
    elseif occursin("col", name)
        return 0x01
    end
    abs(elem.LCS[1][3]) >= 0.866 && return 0x01
    return 0x00
end

"""Bit `i` is set when DOF `i+1` is restrained (`node.dof` is `false` for a restraint)."""
function _fixity_bits(node)::UInt8
    bits = UInt8(0)
    for i in 1:min(6, length(node.dof))
        if node.dof[i] == false
            bits |= UInt8(1) << (i - 1)
        end
    end
    return bits
end

"""
Nodes of wall shells, and the ends of column elements.

A node that belongs to a wall and is not the end of a column is held by the
wall. The scene does not draw a support arrow there. A column end keeps its
arrow, including where a wall frames into that column.
"""
function _wall_and_column_nodes(model, elements)
    wall_nodes = Set{UInt}()
    for sh in model.shell_elements
        _shell_kind(sh.id) == SHELL_KIND_WALL || continue
        for n in sh.nodes
            push!(wall_nodes, objectid(n))
        end
    end
    column_ends = Set{UInt}()
    for elem in elements
        _element_type_code(elem) == 0x01 || continue
        push!(column_ends, objectid(elem.nodeStart))
        push!(column_ends, objectid(elem.nodeEnd))
    end
    return wall_nodes, column_ends
end

function _load_buffers(model, nodes, elements, node_of, origin)
    support_index = UInt32[]
    support_fixity = UInt8[]
    drawn = analysis_drawn_only(model)
    wall_nodes, column_ends = _wall_and_column_nodes(model, elements)
    for (i, n) in enumerate(nodes)
        drawn !== nothing && i in drawn.nodes && continue
        bits = _fixity_bits(n)
        # A rotation that stays fixed while every translation is free is an
        # unused degree of freedom (the beam twist that the frame leaves
        # fixed), not a support. Drawing it puts a support on every joint.
        (bits & 0x07) == 0x00 && continue
        # The wall is the support. An arrow is drawn only where a column
        # meets the ground, not along the wall that holds the floor.
        id = objectid(n)
        id in wall_nodes && !(id in column_ends) && continue
        push!(support_index, UInt32(i - 1))
        push!(support_fixity, bits)
    end

    force_index = UInt32[]
    force = Float32[]
    moment_index = UInt32[]
    moment = Float32[]
    line_elem = UInt32[]
    line = Float32[]
    point_elem = UInt32[]
    point_pos = Float32[]
    point = Float32[]

    elem_of = Dict{UInt, Int}(objectid(elem) => e for (e, elem) in enumerate(elements))
    for load in model.loads
        if load isa Asap.NodeForce
            i = get(node_of, objectid(load.node), 0)
            i == 0 && error("scene: NodeForce references a node that is not in the model")
            push!(force_index, UInt32(i - 1))
            _push_xyz!(force, load.value, u"N")
        elseif load isa Asap.NodeMoment
            i = get(node_of, objectid(load.node), 0)
            i == 0 && error("scene: NodeMoment references a node that is not in the model")
            push!(moment_index, UInt32(i - 1))
            _push_xyz!(moment, load.value, u"N*m")
        elseif load isa Asap.LineLoad
            e = get(elem_of, objectid(load.element), 0)
            e == 0 && error("scene: LineLoad references an element that is not in the model")
            push!(line_elem, UInt32(e - 1))
            _push_xyz!(line, load.value, u"N/m")
        elseif load isa Asap.GravityLoad
            # Member self-weight stays in the solved model. It is not drawn.
            # Every load arrow is scaled to the same length, so the beam's own
            # weight would read as the floor load.
            continue
        elseif load isa Asap.PointLoad
            e = get(elem_of, objectid(load.element), 0)
            e == 0 && error("scene: PointLoad references an element that is not in the model")
            push!(point_elem, UInt32(e - 1))
            push!(point_pos, Float32(load.position))
            _push_xyz!(point, load.value, u"N")
        end
    end

    arrow_at, arrow_dir = _area_load_arrows(model, origin)
    return SceneBuffer[
        SceneBuffer("support_index", support_index),
        SceneBuffer("support_fixity", support_fixity),
        SceneBuffer("node_force_index", force_index),
        SceneBuffer("node_force", Float32.(force)),
        SceneBuffer("node_moment_index", moment_index),
        SceneBuffer("node_moment", Float32.(moment)),
        SceneBuffer("line_load_element", line_elem),
        SceneBuffer("line_load", Float32.(line)),
        SceneBuffer("point_load_element", point_elem),
        SceneBuffer("point_load_position", point_pos),
        SceneBuffer("point_load", Float32.(point)),
        SceneBuffer("load_arrow_position", arrow_at),
        SceneBuffer("load_arrow_vector", arrow_dir),
    ]
end

"""
One arrow per 3 m cell for shell area loads, including self-weight (which is
an `AreaLoad`). The vector is the mean pressure (Pa) times its direction, so
a uniform floor is one downward field rather than one arrow per triangle.
"""
function _area_load_arrows(model, origin; spacing::Float64 = 3.0)
    acc = Dict{UInt, Tuple{Any, NTuple{3, Float64}}}()
    for load in model.loads
        load isa Asap.AreaLoad || continue
        p = ustrip(u"Pa", load.pressure)
        d = load.direction .* p
        for shell in load.shells
            id = objectid(shell)
            prev = get(acc, id, nothing)
            v = isnothing(prev) ? (0.0, 0.0, 0.0) : prev[2]
            acc[id] = (shell, (v[1] + d[1], v[2] + d[2], v[3] + d[3]))
        end
    end
    cells = Dict{NTuple{3, Int}, NTuple{7, Float64}}()
    for (_, (shell, vec)) in acc
        c = (0.0, 0.0, 0.0)
        for n in shell.nodes
            c = (c[1] + ustrip(u"m", n.position[1]),
                 c[2] + ustrip(u"m", n.position[2]),
                 c[3] + ustrip(u"m", n.position[3]))
        end
        n = length(shell.nodes)
        c = (c[1] / n, c[2] / n, c[3] / n)
        key = (floor(Int, c[1] / spacing), floor(Int, c[2] / spacing), floor(Int, c[3] / spacing))
        prev = get(cells, key, (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0))
        cells[key] = (prev[1] + c[1], prev[2] + c[2], prev[3] + c[3],
                      prev[4] + vec[1], prev[5] + vec[2], prev[6] + vec[3], prev[7] + 1)
    end
    at = Float32[]
    dir = Float32[]
    for (_, s) in cells
        s[7] == 0 && continue
        push!(at, Float32(s[1] / s[7] - origin[1]), Float32(s[2] / s[7] - origin[2]), Float32(s[3] / s[7] - origin[3]))
        push!(dir, Float32(s[4] / s[7]), Float32(s[5] / s[7]), Float32(s[6] / s[7]))
    end
    return at, dir
end

function _push_xyz!(dest::Vector{Float32}, values, unit)
    for v in values
        push!(dest, Float32(ustrip(unit, v)))
    end
    return dest
end

function _solved_buffers(model, nodes, elements, stations::Int)
    disp = Vector{Float32}(undef, 3 * length(nodes))
    rot = Vector{Float32}(undef, 3 * length(nodes))
    max_disp = 0.0
    for (i, n) in enumerate(nodes)
        d = n.displacement
        ux = ustrip(u"m", d[1])
        uy = ustrip(u"m", d[2])
        uz = ustrip(u"m", d[3])
        disp[3i - 2] = Float32(ux)
        disp[3i - 1] = Float32(uy)
        disp[3i]     = Float32(uz)
        rot[3i - 2] = Float32(ustrip(d[4]))
        rot[3i - 1] = Float32(ustrip(d[5]))
        rot[3i]     = Float32(ustrip(d[6]))
        mag = sqrt(ux^2 + uy^2 + uz^2)
        mag > max_disp && (max_disp = mag)
    end

    local_dof = Vector{Float32}(undef, 12 * length(elements))
    lcs = Vector{Float32}(undef, 9 * length(elements))
    ug = Vector{Float64}(undef, 12)
    ul = Vector{Float64}(undef, 12)
    load_elem = UInt32[]
    particular = Float32[]
    elemental = Asap.get_elemental_loads(model)

    for (e, elem) in enumerate(elements)
        Asap._fill_uglobal!(ug, elem)
        mul!(ul, elem.R, ug)
        mask = Asap.etype2DOF[typeof(elem)]
        @inbounds for i in 1:12
            ul[i] *= mask[i]
        end
        Asap.release_end_rotations!(ul, elem, ustrip(u"m", elem.length))
        @inbounds for i in 1:12
            local_dof[(e - 1) * 12 + i] = Float32(ul[i])
        end
        @inbounds for axis in 1:3
            v = elem.LCS[axis]
            for k in 1:3
                lcs[(e - 1) * 9 + (axis - 1) * 3 + k] = Float32(v[k])
            end
        end

        loads = elemental[elem.elementID]
        isempty(loads) && continue
        dy, dz = _particular_yz(elem, loads, stations)
        push!(load_elem, UInt32(e - 1))
        for s in 1:stations
            push!(particular, Float32(dy[s]), Float32(dz[s]))
        end
    end

    buffers = SceneBuffer[
        SceneBuffer("node_displacement", disp),
        SceneBuffer("node_rotation", rot),
        SceneBuffer("element_local_dof", local_dof),
        SceneBuffer("element_lcs", lcs),
        SceneBuffer("load_element", load_elem),
        SceneBuffer("load_particular", particular),
    ]
    return buffers, max_disp
end

"""Member-load displacement in local y and z, sampled at `stations` points including the ends."""
function _particular_yz(elem, loads, stations::Int)
    base = Asap.ElementDisplacements(elem, Asap.AbstractLoad[]; resolution = stations)
    full = Asap.ElementDisplacements(elem, loads; resolution = stations)
    dy = full.ulocal[2, :] .- base.ulocal[2, :]
    dz = full.ulocal[3, :] .- base.ulocal[3, :]
    return dy, dz
end

function _suggested_scale(elements, max_disp::Float64)
    max_disp > 1e-12 || return 1.0
    isempty(elements) && return 1.0
    avg = sum(ustrip(u"m", e.length) for e in elements) / length(elements)
    return clamp((avg * 0.1) / max_disp, 0.01, 200.0)
end

function _geometry_hash(nodes, elements, node_of)
    h = UInt(0)
    for n in nodes
        for p in n.position
            h = hash(round(ustrip(u"m", p); digits = 6), h)
        end
    end
    for elem in elements
        h = hash(node_of[objectid(elem.nodeStart)], h)
        h = hash(node_of[objectid(elem.nodeEnd)], h)
    end
    return string(h; base = 16)
end

function _analysis_hash(nodes)
    h = UInt(0)
    for n in nodes
        for i in 1:3
            h = hash(round(ustrip(u"m", n.displacement[i]); digits = 8), h)
        end
    end
    return string(h; base = 16)
end
