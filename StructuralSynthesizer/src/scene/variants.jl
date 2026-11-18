# Several solved designs of one geometry, in one .mgscene.
# Spec: docs/src/reference/scene_format.md (version 2).
#
# A block is stored once, named by the SHA-256 of its uncompressed bytes.
# A design is a manifest of those names. Shared data is whatever more than
# one manifest points at; it is counted, never declared. Appending a design
# writes the blocks the file does not already have and a new index at the end.
# Earlier bytes stay where they are. `compact_variants!` rewrites the file
# without blocks no design uses.

using SHA
using CodecZlib

const VARIANT_VERSION = 0x0002
const _RECORD_BLOCK = UInt32(1)
const _RECORD_INDEX = UInt32(2)
const _QUANT_FULL_SCALE = Int16(32767)

# Stored dtype codes. `i16` is a quantized display field; the viewer expands it.
const _VARIANT_DTYPE = Dict(
    "f32" => UInt16(1), "u32" => UInt16(2), "u16" => UInt16(3),
    "u8" => UInt16(4), "i16" => UInt16(5), "json" => UInt16(6),
)
const _VARIANT_DTYPE_NAME = Dict(v => k for (k, v) in _VARIANT_DTYPE)

"""
Which element a `DesignParameters` field belongs to. A field that differs
between stored designs and is missing from this table is an error: the file
does not guess where a new choice should appear.
"""
const PARAM_ANCHOR = Dict{Symbol, String}(
    :floor => "slab",
    :tributary_axis => "slab",
    :scoped_floor_overrides => "slab",
    :pattern_loading => "slab",
    :columns => "column",
    :uniform_column_sizing => "column",
    :column_I_factor => "column",
    :beams => "beam",
    :collinear_grouping => "beam",
    :member_group_overrides => "beam",
    :framing_opts => "beam",
    :beam_I_factor => "beam",
    :foundation_options => "footing",
    :lateral => "wall",
    :wall_inputs => "wall",
    :wall_thickness => "wall",
    :jump_wall_thickness => "wall",
    :wall_thickness_grouping => "wall",
    :wall_catalog_constraint => "wall",
    :wall_thickness_limit => "wall",
    :name => "none",
    :description => "none",
    :loads => "none",
    :materials => "none",
    :fire_rating => "none",
    :fire_protection => "none",
    :deflection_limit => "none",
    :optimize_for => "none",
    :load_combinations => "none",
    :diaphragm_mode => "none",
    :diaphragm_E => "none",
    :diaphragm_ν => "none",
    :diaphragm_construction => "none",
    :diaphragm_irregularities => "none",
    :semirigid_stiffness_factors => "none",
    :default_frame_E => "none",
    :default_frame_G => "none",
    :default_frame_ρ => "none",
    :max_iterations => "none",
    :rib_head_stirrups => "beam",
    :rib_depth_step => "beam",
    :min_rib_void => "beam",
    :solid_fraction_max => "beam",
    :geometry_is_centerline => "none",
    :display_units => "none",
    :visualization_target_edge_m => "none",
    :skip_visualization => "none",
    :visualization_detail => "none",
)

function _le_bytes(x::T) where {T <: Base.BitInteger}
    n = sizeof(T)
    u = unsigned(x)
    out = Vector{UInt8}(undef, n)
    for k in 1:n
        out[k] = UInt8((u >> (8 * (k - 1))) & 0xff)
    end
    return out
end

_le_bytes(x::Float32) = _le_bytes(reinterpret(UInt32, x))
_le_bytes(x::Float64) = _le_bytes(reinterpret(UInt64, x))

function _require_little_endian()
    reinterpret(UInt8, [UInt32(0x01020304)])[1] == 0x04 ||
        error("variant scene requires a little-endian machine")
end

function _axis_label(value::NamedTuple)
    if haskey(value, :n_xi) && haskey(value, :n_eta)
        return "grillage $(Int(value.n_xi))×$(Int(value.n_eta))"
    end
    if haskey(value, :module_spacing)
        sp = value.module_spacing
        return "waffle $(sp[1])×$(sp[2]) m"
    end
    if haskey(value, :spacing)
        return "joists at $(value.spacing)"
    end
    return isempty(value) ? "beam grid" : "framing"
end

_axis_label(value::StructuralSizer.AbstractFloorOptions) = string(StructuralSizer.floor_symbol(value))

function _axis_label(value)
    label = value === nothing ? "none" :
            value isa Symbol ? string(value) :
            value isa Bool ? (value ? "true" : "false") :
            value isa AbstractString ? String(value) :
            string(value)
    return length(label) > 80 ? string(nameof(typeof(value))) : label
end

"""Hash and short label of every `DesignParameters` field. An unmapped field throws."""
function param_snapshot(params::DesignParameters)
    snap = Dict{String, Any}()
    for field in fieldnames(DesignParameters)
        haskey(PARAM_ANCHOR, field) || error(
            "DesignParameters field :$field has no variant anchor")
        value = getfield(params, field)
        snap[string(field)] = Dict{String, Any}(
            "hash" => content_hash(value),
            "label" => _axis_label(value),
        )
    end
    return snap
end

"""
    variant_axes(snapshots) -> Vector

The fields whose hash is not the same in every snapshot, each tagged with its
anchor (`slab`, `column`, `beam`, `footing`, `wall`, or `none`).
"""
function variant_axes(snapshots)
    isempty(snapshots) && return Any[]
    fields = collect(keys(snapshots[1]))
    for snap in snapshots
        Set(keys(snap)) == Set(fields) || error(
            "variant parameter snapshots do not have the same fields")
    end
    axes = Any[]
    for field in sort(fields)
        sym = Symbol(field)
        haskey(PARAM_ANCHOR, sym) || error(
            "DesignParameters field :$field has no variant anchor")
        hashes = [snap[field]["hash"] for snap in snapshots]
        length(unique(hashes)) == 1 && continue
        push!(axes, Dict{String, Any}("field" => field, "anchor" => PARAM_ANCHOR[sym]))
    end
    return axes
end

function _variant_id(snapshot::Dict)
    ctx = SHA.SHA256_CTX()
    for field in sort(collect(keys(snapshot)))
        SHA.update!(ctx, Vector{UInt8}(field))
        SHA.update!(ctx, Vector{UInt8}(snapshot[field]["hash"]))
    end
    return bytes2hex(SHA.digest!(ctx))[1:12]
end

"""
Designs that differ from `current_id` only in axes anchored at `anchor`.
A design that also changes some other axis is not offered.
"""
function variant_neighbors(index, current_id::AbstractString, anchor::AbstractString)
    current = nothing
    for variant in index["variants"]
        variant["id"] == current_id && (current = variant)
    end
    current === nothing && error("variant \"$current_id\" is not in the scene")
    mine = [axis for axis in index["axes"] if axis["anchor"] == anchor]
    other = [axis for axis in index["axes"] if axis["anchor"] != anchor]
    out = Any[]
    for variant in index["variants"]
        variant["id"] == current_id && continue
        same_elsewhere = all(axis -> current["params"][axis["field"]]["hash"] ==
            variant["params"][axis["field"]]["hash"], other)
        same_elsewhere || continue
        differs = any(axis -> current["params"][axis["field"]]["hash"] !=
            variant["params"][axis["field"]]["hash"], mine)
        differs && push!(out, variant)
    end
    return out
end

"""
Geometry identity of a structure, excluding parameters, story elevations, and
framing auto-generation. Joist and secondary edges, landing vertices, and the
host-edge splits those landings make are omitted, so the hash is the building
before `materialize_level!`. Two designs of one building share it. A different
outline, grid, or opening does not.
"""
function structure_geometry_hash(struc::BuildingStructure)
    skel = struc.skeleton
    ctx = SHA.SHA256_CTX()
    landings = Set(get(skel.groups_vertices, :framing_landings, Int[]))
    skip = Set{Int}()
    for key in (:joists, :secondary)
        for edge in get(skel.groups_edges, key, Int[])
            push!(skip, edge)
        end
    end
    # A host split reuses the original edge as the first sub-edge and appends
    # the rest. Hash the original endpoints, and skip the appended sub-edges.
    chain_ends = Dict{Int, NTuple{2, Int}}()
    for (key, chain) in skel.edge_chains
        isempty(chain) && continue
        key == hash((:framing_host_chain, chain[1])) || continue
        chain_ends[chain[1]] = (skel.edge_indices[chain[1]][1], skel.edge_indices[chain[end]][2])
        for edge in @view chain[2:end]
            push!(skip, edge)
        end
    end
    for (i, vertex) in enumerate(skel.vertices)
        i in landings && continue
        coords = Meshes.coords(vertex)
        for comp in (coords.x, coords.y, coords.z)
            SHA.update!(ctx, _le_bytes(round(ustrip(u"m", comp); digits = 6)))
        end
    end
    for (i, edge) in enumerate(skel.edge_indices)
        i in skip && continue
        a, b = get(chain_ends, i, edge)
        SHA.update!(ctx, _le_bytes(Int64(a)))
        SHA.update!(ctx, _le_bytes(Int64(b)))
    end
    for face in skel.face_vertex_indices
        kept = [vertex for vertex in face if !(vertex in landings)]
        SHA.update!(ctx, _le_bytes(Int64(length(kept))))
        for vertex in kept
            SHA.update!(ctx, _le_bytes(Int64(vertex)))
        end
    end
    if !isempty(skel.openings)
        SHA.update!(ctx, Vector{UInt8}("openings"))
        for opening in skel.openings
            SHA.update!(ctx, _le_bytes(Int64(opening.story)))
            for (x, y) in opening.loop
                SHA.update!(ctx, _le_bytes(round(Float64(x); digits = 6)))
                SHA.update!(ctx, _le_bytes(round(Float64(y); digits = 6)))
            end
        end
    end
    if !isempty(skel.wall_openings)
        SHA.update!(ctx, Vector{UInt8}("wall_openings"))
        for spec in skel.wall_openings
            opening = spec.opening
            SHA.update!(ctx, _le_bytes(Int64(spec.v1)))
            SHA.update!(ctx, _le_bytes(Int64(spec.v2)))
            SHA.update!(ctx, _le_bytes(Int64(spec.story)))
            for value in (opening.s0, opening.z0, opening.width, opening.height)
                SHA.update!(ctx, _le_bytes(round(Float64(value); digits = 6)))
            end
            SHA.update!(ctx, Vector{UInt8}(string(opening.kind)))
        end
    end
    return bytes2hex(SHA.digest!(ctx))
end

# --- splitting one scene into shareable parts --------------------------------

function _maybe_buffer(packet::ScenePacket, name::AbstractString)
    for buffer in packet.buffers
        buffer.name == name && return buffer
    end
    return nothing
end

_f32(packet, name) = (b = _maybe_buffer(packet, name); b === nothing ? Float32[] : scene_f32(packet, name))
_u32(packet, name) = (b = _maybe_buffer(packet, name); b === nothing ? UInt32[] : scene_u32(packet, name))
_u16(packet, name) = (b = _maybe_buffer(packet, name); b === nothing ? UInt16[] : scene_u16(packet, name))
_u8(packet, name) = (b = _maybe_buffer(packet, name); b === nothing ? UInt8[] : scene_u8(packet, name))

function _take(values::Vector{T}, index::Int, stride::Int) where {T}
    start = (index - 1) * stride
    return values[(start + 1):(start + stride)]
end

function _frame_parts(packet::ScenePacket)
    types = _u8(packet, "element_type")
    n = length(types)
    n == 0 && return Any[]
    stories = _u16(packet, "element_story")
    length(stories) == n || error("element_story has $(length(stories)) values for $n elements")
    endpoints = _u32(packet, "element_nodes")
    length(endpoints) == 2n || error("element_nodes has $(length(endpoints)) values for $n elements")
    position = _f32(packet, "node_position")
    displacement = _f32(packet, "node_displacement")
    isempty(displacement) || length(displacement) == length(position) || error(
        "node_displacement does not match node_position")
    eccentricity = _f32(packet, "element_eccentricity")
    local_dof = _f32(packet, "element_local_dof")
    lcs = _f32(packet, "element_lcs")
    axial = _f32(packet, "element_axial")
    names = get(packet.meta, "element_section", nothing)
    names === nothing && (names = fill("", n))
    length(names) == n || error("element_section has $(length(names)) names for $n elements")
    grouped = Dict{UInt16, Vector{Int}}()
    for element in 1:n
        push!(get!(grouped, stories[element], Int[]), element)
    end
    parts = Any[]
    for story in sort(collect(keys(grouped)))
        elements = grouped[story]
        globals = Int[]
        local_of = Dict{Int, Int}()
        for element in elements
            for slot in 0:1
                global_node = Int(endpoints[(element - 1) * 2 + slot + 1])
                if !haskey(local_of, global_node)
                    local_of[global_node] = length(globals)
                    push!(globals, global_node)
                end
            end
        end
        pos = Float32[]
        disp = Float32[]
        for node in globals
            append!(pos, _take(position, node + 1, 3))
            isempty(displacement) || append!(disp, _take(displacement, node + 1, 3))
        end
        pairs = UInt32[]
        etype = UInt8[]
        estory = UInt16[]
        ecc = Float32[]
        dof = Float32[]
        axes = Float32[]
        force = Float32[]
        sections = String[]
        for element in elements
            for slot in 0:1
                global_node = Int(endpoints[(element - 1) * 2 + slot + 1])
                push!(pairs, UInt32(local_of[global_node]))
            end
            push!(etype, types[element])
            push!(estory, stories[element])
            isempty(eccentricity) || append!(ecc, _take(eccentricity, element, 4))
            isempty(local_dof) || append!(dof, _take(local_dof, element, 12))
            isempty(lcs) || append!(axes, _take(lcs, element, 9))
            isempty(axial) || push!(force, axial[element])
            push!(sections, String(names[element]))
        end
        blocks = Dict{String, Any}(
            "node_position" => pos,
            "element_nodes" => pairs,
            "element_type" => etype,
            "element_story" => estory,
        )
        isempty(disp) || (blocks["node_displacement"] = disp)
        isempty(ecc) || (blocks["element_eccentricity"] = ecc)
        isempty(dof) || (blocks["element_local_dof"] = dof)
        isempty(axes) || (blocks["element_lcs"] = axes)
        isempty(force) || (blocks["element_axial"] = force)
        push!(parts, Dict{String, Any}(
            "id" => "frame:$(story)",
            "role" => "frame",
            "globals" => globals,
            "elements" => [element - 1 for element in elements],
            "sections" => sections,
            "blocks" => blocks,
        ))
    end
    sort!(parts, by = part -> part["id"])
    return parts
end

function _segment_distance(px, py, x1, y1, x2, y2)
    dx = x2 - x1
    dy = y2 - y1
    len2 = dx * dx + dy * dy
    len2 < 1e-12 && return hypot(px - x1, py - y1)
    t = clamp(((px - x1) * dx + (py - y1) * dy) / len2, 0.0, 1.0)
    return hypot(px - (x1 + t * dx), py - (y1 + t * dy))
end

_component_list(packet) = get(packet.meta, "components", nothing)

function _components_of(packet, kind::String)
    raw = _component_list(packet)
    raw === nothing && return Any[]
    return [record for record in raw if String(get(record, "kind", "")) == kind]
end

function _shell_owner(packet, triangle::Int, kind::UInt8, centroid, shell_wall)
    slabs = _components_of(packet, "slab")
    walls = _components_of(packet, "wall")
    if isempty(slabs) && isempty(walls)
        return kind == 0x01 ? "wall:all" : "slab:all"
    end
    x, y, z = centroid
    if kind == 0x01 && !isempty(shell_wall)
        idx = Int(shell_wall[triangle])
        idx > 0 || error("shell triangle $triangle is a wall and shell_wall names no wall")
        any(w -> get(w, "design_index", nothing) == idx, walls) || error(
            "shell triangle $triangle names wall $idx and the scene has no record for it")
        return "wall:$(idx)"
    end
    if kind == 0x01
        isempty(walls) && error("shell triangle $triangle is a wall and the scene has no wall component")
        best = nothing
        best_d = Inf
        tied = false
        for wall in walls
            drawing = wall["drawing"]
            distance = _segment_distance(x, y, drawing["x1_m"], drawing["y1_m"], drawing["x2_m"], drawing["y2_m"])
            z0 = get(wall["bind"], "z0_m", nothing)
            z1 = get(wall["bind"], "z1_m", nothing)
            if z0 isa Number && z1 isa Number && !(min(z0, z1) - 0.2 <= z <= max(z0, z1) + 0.2)
                continue
            end
            distance > 0.5 && continue
            if best === nothing || distance < best_d - 1e-3
                best = String(wall["id"])
                best_d = distance
                tied = false
            elseif abs(distance - best_d) <= 1e-3
                tied = true
            end
        end
        best === nothing && error("shell triangle $triangle matches no wall")
        tied && error("shell triangle $triangle matches more than one wall")
        return best
    end
    kind in (0x00, 0x02) || error("shell triangle $triangle has unknown kind $kind")
    isempty(slabs) && error("shell triangle $triangle is a slab and the scene has no slab component")
    matches = String[]
    for slab in slabs
        # A solid head is drawn as its own prism. It is filed as a slab so the
        # dossier can name it, and it does not own the plate's triangles.
        drawing = get(slab, "drawing", nothing)
        drawing isa AbstractDict && get(drawing, "solid_head", false) === true && continue
        bind = get(slab, "bind", nothing)
        bind isa AbstractDict || error("slab $(slab["id"]) has no elevation_m")
        elevation = get(bind, "elevation_m", nothing)
        elevation isa Number || error("slab $(slab["id"]) has no elevation_m")
        abs(z - Float64(elevation)) <= 0.5 && push!(matches, String(slab["id"]))
    end
    if length(matches) > 1
        nearest = _nearest_plan_slab(slabs, matches, x, y)
        nearest === nothing || return nearest
    end
    length(matches) == 1 || error(
        "shell triangle $triangle matches $(isempty(matches) ? "no slab" : "more than one slab")")
    return matches[1]
end

"""The elevation match whose plan ring is nearest `(x, y)`. A tie takes the smaller design index."""
function _nearest_plan_slab(slabs, matches, x, y)
    best = nothing
    best_key = nothing
    for slab in slabs
        id = String(slab["id"])
        id in matches || continue
        center = _plan_centroid(slab)
        center === nothing && continue
        key = (hypot(x - center[1], y - center[2]), Int(get(slab, "design_index", 0)))
        if best_key === nothing || key < best_key
            best = id
            best_key = key
        end
    end
    return best
end

function _plan_centroid(record)
    rings = get(get(record, "bind", Dict()), "plan_m", nothing)
    rings isa AbstractVector || return nothing
    sx = sy = 0.0
    n = 0
    for ring in rings
        for p in ring
            sx += Float64(p[1])
            sy += Float64(p[2])
            n += 1
        end
    end
    return n == 0 ? nothing : (sx / n, sy / n)
end

function _shell_parts(packet::ScenePacket)
    faces = _u32(packet, "shell_faces")
    isempty(faces) && return Any[]
    kinds = _u8(packet, "shell_kind")
    n = length(kinds)
    length(faces) == 3n || error("shell_faces has $(length(faces)) values for $n triangles")
    position = _f32(packet, "node_position")
    displacement = _f32(packet, "node_displacement")
    thickness = _f32(packet, "shell_thickness")
    stress = _f32(packet, "shell_surface_stress")
    axial = _f32(packet, "shell_axial")
    length(thickness) == n || error("shell_thickness has $(length(thickness)) values for $n triangles")
    isempty(stress) || length(stress) == n || error(
        "shell_surface_stress has $(length(stress)) values for $n triangles")
    isempty(axial) || length(axial) == n || error(
        "shell_axial has $(length(axial)) values for $n triangles")
    shell_wall = _u32(packet, "shell_wall")
    isempty(shell_wall) || length(shell_wall) == n || error(
        "shell_wall has $(length(shell_wall)) values for $n triangles")
    origin = packet.origin
    grouped = Dict{String, Vector{Int}}()
    for triangle in 1:n
        ids = _take(faces, triangle, 3)
        x = y = z = 0.0
        for id in ids
            x += position[id * 3 + 1]
            y += position[id * 3 + 2]
            z += position[id * 3 + 3]
        end
        centroid = (x / 3 + origin[1], y / 3 + origin[2], z / 3 + origin[3])
        owner = _shell_owner(packet, triangle, kinds[triangle], centroid, shell_wall)
        push!(get!(grouped, owner, Int[]), triangle)
    end
    parts = Any[]
    for id in sort(collect(keys(grouped)))
        triangles = grouped[id]
        globals = Int[]
        local_of = Dict{Int, Int}()
        for triangle in triangles
            for id_node in _take(faces, triangle, 3)
                node = Int(id_node)
                if !haskey(local_of, node)
                    local_of[node] = length(globals)
                    push!(globals, node)
                end
            end
        end
        pos = Float32[]
        disp = Float32[]
        for node in globals
            append!(pos, _take(position, node + 1, 3))
            isempty(displacement) || append!(disp, _take(displacement, node + 1, 3))
        end
        local_faces = UInt32[]
        local_kinds = UInt8[]
        local_thickness = Float32[]
        local_stress = Float32[]
        local_axial = Float32[]
        local_wall = UInt32[]
        for triangle in triangles
            for id_node in _take(faces, triangle, 3)
                push!(local_faces, UInt32(local_of[Int(id_node)]))
            end
            push!(local_kinds, kinds[triangle])
            push!(local_thickness, thickness[triangle])
            isempty(stress) || push!(local_stress, stress[triangle])
            isempty(axial) || push!(local_axial, axial[triangle])
            isempty(shell_wall) || push!(local_wall, shell_wall[triangle])
        end
        blocks = Dict{String, Any}(
            "node_position" => pos,
            "shell_faces" => local_faces,
            "shell_kind" => local_kinds,
            "shell_thickness" => local_thickness,
        )
        isempty(disp) || (blocks["node_displacement"] = disp)
        isempty(local_stress) || (blocks["shell_surface_stress"] = local_stress)
        isempty(local_axial) || (blocks["shell_axial"] = local_axial)
        isempty(local_wall) || (blocks["shell_wall"] = local_wall)
        push!(parts, Dict{String, Any}(
            "id" => id,
            "role" => "shell",
            "blocks" => blocks,
        ))
    end
    return parts
end

function _assembled_maps(frame_parts)
    node_of = Dict{Int, Int}()
    element_of = Dict{Int, Int}()
    cursor = 0
    element_cursor = 0
    for part in frame_parts
        for (local_index, global_node) in enumerate(part["globals"])
            haskey(node_of, global_node) || (node_of[global_node] = cursor + local_index - 1)
        end
        cursor += length(part["globals"])
        for element in part["elements"]
            element_of[element] = element_cursor
            element_cursor += 1
        end
    end
    return node_of, element_of
end

function _remap_index(values::Vector{UInt32}, mapping::Dict{Int, Int}; sentinel::Union{Nothing, UInt32} = nothing)
    out = similar(values)
    for (i, value) in enumerate(values)
        if sentinel !== nothing && value == sentinel
            out[i] = value
            continue
        end
        haskey(mapping, Int(value)) || error("scene index $value is not in the assembled frame")
        out[i] = UInt32(mapping[Int(value)])
    end
    return out
end

function _index_part(packet, role, names, mapping; sentinel = nothing)
    blocks = Dict{String, Any}()
    for name in names
        values = _u32(packet, name)
        isempty(values) && continue
        blocks[name] = _remap_index(values, mapping; sentinel = name in ("tributary_element",) ? sentinel : nothing)
    end
    return blocks
end

function _value_part(packet, names)
    blocks = Dict{String, Any}()
    for name in names
        buffer = _maybe_buffer(packet, name)
        buffer === nothing && continue
        isempty(buffer.data) && continue
        if buffer.dtype == "f32"
            blocks[name] = scene_f32(packet, name)
        elseif buffer.dtype == "u32"
            blocks[name] = scene_u32(packet, name)
        elseif buffer.dtype == "u16"
            blocks[name] = scene_u16(packet, name)
        elseif buffer.dtype == "u8"
            blocks[name] = copy(buffer.data)
        else
            error("scene buffer \"$name\" has unknown dtype $(buffer.dtype)")
        end
    end
    return blocks
end

function _remap_components(components, node_of, element_of)
    components === nothing && return Any[]
    copied = deepcopy(components)
    for record in copied
        bind = get(record, "bind", nothing)
        bind === nothing && continue
        if haskey(bind, "frame_elements")
            bind["frame_elements"] = Int[element_of[e] for e in bind["frame_elements"]]
        end
        if haskey(bind, "support_nodes")
            bind["support_nodes"] = Int[node_of[n] for n in bind["support_nodes"]]
        end
    end
    return copied
end

"""Parts of one scene. Frame and shell nodes are numbered locally. Index buffers use the assembled frame."""
function variant_parts(packet::ScenePacket)
    frames = _frame_parts(packet)
    shells = _shell_parts(packet)
    node_of, element_of = _assembled_maps(frames)
    loads = merge(
        _index_part(packet, "loads",
            ("support_index", "node_force_index", "node_moment_index"), node_of),
        _index_part(packet, "loads",
            ("line_load_element", "point_load_element", "load_element"), element_of),
        _value_part(packet, (
            "support_fixity", "node_force", "node_moment", "line_load",
            "point_load_position", "point_load", "load_particular",
        )),
    )
    arrows = _value_part(packet, ("load_arrow_position", "load_arrow_vector"))
    footings = merge(
        _index_part(packet, "footings", ("footing_support_node",), node_of),
        _value_part(packet, ("footing_center", "footing_size", "footing_kind", "footing_support_count")),
    )
    solids = merge(
        _index_part(packet, "solids", ("member_solid_element",), element_of),
        _value_part(packet, ("member_solid_position", "member_solid_faces")),
    )
    tributary = merge(
        _index_part(packet, "tributary", ("tributary_element",), element_of; sentinel = UInt32(0xffffffff)),
        _value_part(packet, ("tributary_position", "tributary_count", "tributary_kind", "tributary_cell")),
    )
    parts = Any[]
    for part in frames
        stored = Dict{String, Any}(
            "id" => part["id"], "role" => "frame", "sections" => part["sections"], "blocks" => part["blocks"])
        push!(parts, stored)
    end
    append!(parts, shells)
    for (id, role, blocks) in (("loads", "loads", loads), ("arrows", "arrows", arrows),
                               ("footings", "footings", footings), ("solids", "solids", solids),
                               ("tributary", "tributary", tributary))
        isempty(blocks) && continue
        push!(parts, Dict{String, Any}("id" => id, "role" => role, "blocks" => blocks))
    end
    return parts, _remap_components(_component_list(packet), node_of, element_of)
end

# --- content-addressed blocks ------------------------------------------------

const _QUANTIZED = Set(("node_displacement", "shell_surface_stress"))

function _quantize(values::Vector{Float32})
    peak = isempty(values) ? 0.0f0 : maximum(abs, values)
    scale = peak == 0 ? 1.0f0 : peak / Float32(_QUANT_FULL_SCALE)
    stored = Vector{Int16}(undef, length(values))
    for i in eachindex(values)
        step = round(Int, values[i] / scale)
        stored[i] = Int16(clamp(step, -Int(_QUANT_FULL_SCALE), Int(_QUANT_FULL_SCALE)))
    end
    raw = Vector{UInt8}(undef, 2 * length(stored))
    for i in eachindex(stored)
        bits = reinterpret(UInt16, stored[i])
        raw[2i - 1] = UInt8(bits & 0x00ff)
        raw[2i] = UInt8(bits >> 8)
    end
    return raw, scale
end

function _block_hash(dtype::String, count::Int, scale::Float32, raw::Vector{UInt8})
    ctx = SHA.SHA256_CTX()
    SHA.update!(ctx, Vector{UInt8}(dtype))
    SHA.update!(ctx, _le_bytes(UInt32(count)))
    SHA.update!(ctx, _le_bytes(scale))
    SHA.update!(ctx, raw)
    return bytes2hex(SHA.digest!(ctx))
end

function _block_payload(hash::String, dtype::String, count::Int, scale::Float32, storage::UInt8, raw::Vector{UInt8})
    gzip = Vector{UInt8}(transcode(GzipCompressor, raw))
    return vcat(
        hex2bytes(hash),
        UInt8[0x01, storage],
        _le_bytes(_VARIANT_DTYPE[dtype]),
        _le_bytes(UInt32(count)),
        _le_bytes(scale),
        gzip,
    )
end

function _store!(pool::Dict{String, Vector{UInt8}}, raw::Vector{UInt8}, dtype::String, scale::Float32, storage::UInt8)
    count = dtype == "i16" ? length(raw) ÷ 2 : dtype == "json" ? length(raw) : length(raw) ÷ _SCENE_DTYPE_SIZE[dtype]
    hash = _block_hash(dtype, count, scale, raw)
    haskey(pool, hash) || (pool[hash] = _block_payload(hash, dtype, count, scale, storage, raw))
    return hash
end

function _store_array!(pool, name::String, values)
    if name in _QUANTIZED && values isa Vector{Float32}
        raw, scale = _quantize(values)
        return _store!(pool, raw, "i16", scale, 0x01)
    end
    if values isa Vector{Float32}
        return _store!(pool, _pod_bytes(values), "f32", 1.0f0, 0x00)
    elseif values isa Vector{UInt32}
        return _store!(pool, _pod_bytes(values), "u32", 1.0f0, 0x00)
    elseif values isa Vector{UInt16}
        return _store!(pool, _pod_bytes(values), "u16", 1.0f0, 0x00)
    elseif values isa Vector{UInt8}
        return _store!(pool, values, "u8", 1.0f0, 0x00)
    end
    error("variant block \"$name\" has no encoder for $(typeof(values))")
end

function _store_json!(pool, value)
    raw = Vector{UInt8}(JSON3.write(value))
    return _store!(pool, raw, "json", 1.0f0, 0x00)
end

function _address_parts!(pool, parts)
    addressed = Any[]
    for part in parts
        blocks = Dict{String, Any}()
        for (name, values) in part["blocks"]
            isempty(values) && continue
            blocks[name] = _store_array!(pool, name, values)
        end
        isempty(blocks) && continue
        stored = Dict{String, Any}("id" => part["id"], "role" => part["role"], "blocks" => blocks)
        haskey(part, "sections") && (stored["sections"] = part["sections"])
        push!(addressed, stored)
    end
    return addressed
end

# --- file --------------------------------------------------------------------

function _write_record(io::IO, kind::UInt32, payload::Vector{UInt8})
    write(io, kind)
    write(io, UInt32(length(payload)))
    write(io, payload)
    pad = (8 - (position(io) % 8)) % 8
    pad == 0 || write(io, zeros(UInt8, pad))
    return
end

function _plain_json(value)
    value isa JSON3.Object && return Dict{String, Any}(String(k) => _plain_json(v) for (k, v) in pairs(value))
    value isa JSON3.Array && return Any[_plain_json(v) for v in value]
    return value
end

"""Read the latest index and every block payload. Orphan blocks from a dropped design are still here."""
function _read_variant_file(io::IO)
    magic = read(io, UInt32)
    magic == SCENE_MAGIC || error("scene: bad magic 0x$(string(magic, base = 16)); expected MGSC")
    version = read(io, UInt16)
    version == VARIANT_VERSION || error(
        version == SCENE_VERSION ? "scene: version 1 holds one design; this reader expects version 2" :
                                   "scene: unsupported version $version")
    _ = read(io, UInt16)
    blocks = Dict{String, Vector{UInt8}}()
    index = nothing
    while !eof(io)
        kind = read(io, UInt32)
        nbytes = Int(read(io, UInt32))
        payload = read(io, nbytes)
        pad = (8 - (position(io) % 8)) % 8
        pad == 0 || read(io, pad)
        if kind == _RECORD_BLOCK
            length(payload) >= 32 || error("scene: block record is shorter than its hash")
            blocks[bytes2hex(payload[1:32])] = payload
        elseif kind == _RECORD_INDEX
            index = _plain_json(JSON3.read(String(payload)))
        else
            error("scene: unknown record type $kind")
        end
    end
    index === nothing && error("scene: version 2 file has no index")
    return index, blocks
end

function read_variant_index(path::AbstractString)
    return open(io -> _read_variant_file(io)[1], path)
end

"""Hashes of the block records currently in the file, including orphans."""
function variant_stored_hashes(path::AbstractString)
    return open(path) do io
        Set(keys(_read_variant_file(io)[2]))
    end
end

function _referenced_hashes(index)
    used = Set{String}()
    for variant in index["variants"]
        push!(used, variant["components"], variant["design_trace"])
        for part in variant["parts"]
            for hash in values(part["blocks"])
                push!(used, String(hash))
            end
        end
    end
    return used
end

function _write_variant_file(io::IO, index, blocks::Dict{String, Vector{UInt8}})
    _require_little_endian()
    write(io, UInt32(SCENE_MAGIC))
    write(io, UInt16(VARIANT_VERSION))
    write(io, UInt16(0))
    for hash in sort(collect(keys(blocks)))
        _write_record(io, _RECORD_BLOCK, blocks[hash])
    end
    _write_record(io, _RECORD_INDEX, Vector{UInt8}(JSON3.write(index)))
    return
end

function _meta_number(meta, key, default = 0.0)
    value = get(meta, key, default)
    return value isa Number ? Float64(value) : default
end

"""
    append_variant!(path, packet; geometry_hash, params, summary=Dict())
    append_variant!(path, design)

Add one solved design. The geometry hash must match the file. The same
parameter snapshot cannot be stored twice. Display displacements and surface
stress are stored as 16-bit steps of their own maximum. Node rotations are not
written.
"""
function append_variant!(path::AbstractString, packet::ScenePacket;
                         geometry_hash::AbstractString, params::DesignParameters,
                         summary::AbstractDict = Dict{String, Any}())
    _require_little_endian()
    snapshot = param_snapshot(params)
    id = _variant_id(snapshot)
    parts, components = variant_parts(packet)
    index = nothing
    existing = Dict{String, Vector{UInt8}}()
    if isfile(path)
        index, existing = open(_read_variant_file, path)
        index["geometry_hash"] == geometry_hash || error(
            "scene geometry hash does not match this file")
        any(variant -> variant["id"] == id, index["variants"]) && error(
            "this parameterization is already in the scene")
    end
    pool = copy(existing)
    addressed = _address_parts!(pool, parts)
    trace = get(packet.meta, "design_trace", Dict{String, Any}())
    variant = Dict{String, Any}(
        "id" => id,
        "params" => snapshot,
        "summary" => Dict{String, Any}(string(k) => v for (k, v) in pairs(summary)),
        "origin" => [packet.origin...],
        "stages" => packet.stages,
        "stations" => Int(_meta_number(packet.meta, "stations")),
        "max_displacement" => _meta_number(packet.meta, "max_displacement"),
        "max_axial_n" => _meta_number(packet.meta, "max_axial_n"),
        "max_surface_stress_pa" => _meta_number(packet.meta, "max_surface_stress_pa"),
        "suggested_scale" => _meta_number(packet.meta, "suggested_scale", 1.0),
        "analysis_model" => String(get(packet.meta, "analysis_model", "")),
        "counts" => get(packet.meta, "counts", Dict{String, Any}()),
        "components" => _store_json!(pool, components),
        "design_trace" => _store_json!(pool, trace),
        "parts" => addressed,
    )
    variants = index === nothing ? Any[] : copy(index["variants"])
    push!(variants, variant)
    written = Dict{String, Any}(
        "version" => 2,
        "geometry_hash" => geometry_hash,
        "axes" => variant_axes([item["params"] for item in variants]),
        "variants" => variants,
    )
    fresh = Dict(hash => payload for (hash, payload) in pool if !haskey(existing, hash))
    open(path, isfile(path) ? "a" : "w") do io
        if position(io) == 0
            write(io, UInt32(SCENE_MAGIC))
            write(io, UInt16(VARIANT_VERSION))
            write(io, UInt16(0))
        end
        for hash in sort(collect(keys(fresh)))
            _write_record(io, _RECORD_BLOCK, fresh[hash])
        end
        _write_record(io, _RECORD_INDEX, Vector{UInt8}(JSON3.write(written)))
    end
    return id
end

function append_variant!(path::AbstractString, design::BuildingDesign)
    isnothing(design.asap_model) && build_analysis_model!(design)
    packet = build_scene(design)
    return append_variant!(path, packet;
        geometry_hash = structure_geometry_hash(design.structure),
        params = design.params,
        summary = _summary_record(design))
end

"""
    write_design_variants(path, struc, params)

Solve `struc` once per `DesignParameters` and append each design to a new file.
The structure is restored after every solve. Refuses to overwrite `path`.
"""
function write_design_variants(path::AbstractString, struc::BuildingStructure, params::AbstractVector{<:DesignParameters})
    isempty(params) && error("write_design_variants needs at least one DesignParameters")
    isfile(path) && error("refusing to overwrite $path; append_variant! adds a design to an existing file")
    ids = String[]
    for item in params
        design = design_building(struc, item)
        push!(ids, append_variant!(path, design))
    end
    return ids
end

"""Append an index that no longer lists `id`. Its blocks stay until `compact_variants!`."""
function drop_variant!(path::AbstractString, id::AbstractString)
    index, _ = open(_read_variant_file, path)
    kept = [variant for variant in index["variants"] if variant["id"] != id]
    length(kept) == length(index["variants"]) && error("variant \"$id\" is not in the scene")
    isempty(kept) && error("refusing to drop the only design in the scene")
    index["variants"] = kept
    index["axes"] = variant_axes([variant["params"] for variant in kept])
    open(path, "a") do io
        _write_record(io, _RECORD_INDEX, Vector{UInt8}(JSON3.write(index)))
    end
    return index
end

"""Rewrite the file with only the blocks the current index still names."""
function compact_variants!(path::AbstractString)
    index, blocks = open(_read_variant_file, path)
    used = _referenced_hashes(index)
    kept = Dict(hash => payload for (hash, payload) in blocks if hash in used)
    open(path, "w") do io
        _write_variant_file(io, index, kept)
    end
    return index
end

# --- assemble one design back into a scene packet ---------------------------

function _u16_at(bytes, i)
    return UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
end

function _u32_at(bytes, i)
    return UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) |
           (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
end

function _decode_block(payload::Vector{UInt8})
    length(payload) >= 44 || error("scene: block record is truncated")
    payload[33] == 0x01 || error("scene: unknown block codec")
    storage = payload[34]
    dtype = get(_VARIANT_DTYPE_NAME, _u16_at(payload, 35), nothing)
    dtype === nothing && error("scene: unknown block dtype code")
    count = Int(_u32_at(payload, 37))
    scale = reinterpret(Float32, _u32_at(payload, 41))
    raw = Vector{UInt8}(transcode(GzipDecompressor, payload[45:end]))
    bytes2hex(payload[1:32]) == _block_hash(dtype, count, scale, raw) ||
        error("scene: block hash does not match its bytes")
    if storage == 0x01
        dtype == "i16" || error("scene: quantized block is not i16")
        length(raw) == 2count || error("scene: quantized block has $(length(raw)) bytes for $count values")
        values = Vector{Float32}(undef, count)
        for i in 1:count
            bits = _u16_at(raw, 2i - 1)
            values[i] = Float32(reinterpret(Int16, bits)) * scale
        end
        return "f32", _pod_bytes(values)
    end
    if dtype == "json"
        length(raw) == count || error("scene: json block length does not match its count")
        return "json", String(raw)
    end
    width = _SCENE_DTYPE_SIZE[dtype]
    length(raw) == count * width || error("scene: block has $(length(raw)) bytes, expected $(count * width)")
    return dtype, raw
end

function _part_bytes(decoded, part, name)
    hash = get(part["blocks"], name, nothing)
    hash === nothing && return UInt8[]
    dtype, values = decoded[String(hash)]
    dtype == "json" && error("scene: part block \"$name\" is JSON")
    return values
end

function _concat_bytes(chunks)
    return isempty(chunks) ? UInt8[] : vcat(chunks...)
end

function _offset_u32(raw::Vector{UInt8}, add::Int)
    isempty(raw) && return raw
    values = _pod_load(UInt32, raw)
    return _pod_bytes(UInt32[value + UInt32(add) for value in values])
end

"""
Assemble one stored design into a version-1 packet the rest of the scene code
can read. Node order is frame parts, then shell parts, each in id order.
`node_rotation` is absent. Displacements are within half a quantization step
of the values that were stored.
"""
function materialize_variant(path::AbstractString, id::AbstractString)
    index, payloads = open(_read_variant_file, path)
    variant = nothing
    for item in index["variants"]
        item["id"] == id && (variant = item)
    end
    variant === nothing && error("variant \"$id\" is not in the scene")
    decoded = Dict{String, Any}()
    for part in variant["parts"]
        for hash in values(part["blocks"])
            key = String(hash)
            haskey(decoded, key) && continue
            decoded[key] = _decode_block(payloads[key])
        end
    end
    frames = [part for part in variant["parts"] if part["role"] == "frame"]
    shells = [part for part in variant["parts"] if part["role"] == "shell"]
    sort!(frames, by = part -> part["id"])
    sort!(shells, by = part -> part["id"])
    function named(role)
        matches = [part for part in variant["parts"] if part["role"] == role]
        length(matches) > 1 && error("scene: more than one $role part")
        return isempty(matches) ? nothing : matches[1]
    end
    node_bytes = UInt8[]
    disp_bytes = UInt8[]
    element_bytes = Dict{String, Vector{UInt8}}()
    element_names = ("element_nodes", "element_type", "element_story", "element_eccentricity",
                     "element_local_dof", "element_lcs", "element_axial")
    sections = String[]
    node_cursor = 0
    for part in frames
        pos = _part_bytes(decoded, part, "node_position")
        pairs = _offset_u32(_part_bytes(decoded, part, "element_nodes"), node_cursor)
        append!(node_bytes, pos)
        append!(disp_bytes, _part_bytes(decoded, part, "node_displacement"))
        element_bytes["element_nodes"] = vcat(get(element_bytes, "element_nodes", UInt8[]), pairs)
        for name in element_names
            name == "element_nodes" && continue
            element_bytes[name] = vcat(get(element_bytes, name, UInt8[]), _part_bytes(decoded, part, name))
        end
        append!(sections, String.(get(part, "sections", String[])))
        node_cursor += length(pos) ÷ 12
    end
    shell_bytes = Dict{String, Vector{UInt8}}()
    for part in shells
        faces = _offset_u32(_part_bytes(decoded, part, "shell_faces"), node_cursor)
        shell_bytes["shell_faces"] = vcat(get(shell_bytes, "shell_faces", UInt8[]), faces)
        for name in ("shell_kind", "shell_thickness", "shell_surface_stress", "shell_axial", "shell_wall", "node_position", "node_displacement")
            name == "shell_faces" && continue
            chunk = name in ("node_position", "node_displacement") ?
                _part_bytes(decoded, part, name) : _part_bytes(decoded, part, name)
            shell_bytes[name] = vcat(get(shell_bytes, name, UInt8[]), chunk)
        end
        node_cursor += length(_part_bytes(decoded, part, "node_position")) ÷ 12
    end
    append!(node_bytes, get(shell_bytes, "node_position", UInt8[]))
    append!(disp_bytes, get(shell_bytes, "node_displacement", UInt8[]))
    buffers = SceneBuffer[]
    function push_raw(name, dtype, raw)
        isempty(raw) && return
        width = _SCENE_DTYPE_SIZE[dtype]
        length(raw) % width == 0 || error("assembled $name is not a whole number of $dtype values")
        push!(buffers, SceneBuffer(name, dtype, length(raw) ÷ width, raw))
    end
    push_raw("node_position", "f32", node_bytes)
    push_raw("node_displacement", "f32", disp_bytes)
    for (name, raw) in element_bytes
        dtype = name in ("element_type",) ? "u8" : name == "element_story" ? "u16" :
                name in ("element_nodes",) ? "u32" : "f32"
        name == "element_axial" && (dtype = "f32")
        push_raw(name, dtype, raw)
    end
    for name in ("shell_faces", "shell_kind", "shell_thickness", "shell_surface_stress", "shell_axial", "shell_wall")
        dtype = name in ("shell_faces", "shell_wall") ? "u32" : name == "shell_kind" ? "u8" : "f32"
        push_raw(name, dtype, get(shell_bytes, name, UInt8[]))
    end
    for role in ("loads", "arrows", "footings", "solids", "tributary")
        part = named(role)
        part === nothing && continue
        for (name, hash) in part["blocks"]
            dtype, raw = decoded[String(hash)]
            push_raw(String(name), dtype, raw)
        end
    end
    components = _decode_block(payloads[variant["components"]])[2]
    trace = _decode_block(payloads[variant["design_trace"]])[2]
    origin = variant["origin"]
    meta = Dict{String, Any}(
        "stations" => variant["stations"],
        "max_displacement" => variant["max_displacement"],
        "max_axial_n" => variant["max_axial_n"],
        "max_surface_stress_pa" => variant["max_surface_stress_pa"],
        "suggested_scale" => variant["suggested_scale"],
        "counts" => variant["counts"],
        "element_section" => sections,
        "analysis_model" => String(get(variant, "analysis_model", "")),
        "components" => _plain_json(JSON3.read(components)),
        "design_trace" => _plain_json(JSON3.read(trace)),
        "hashes" => Dict{String, Any}("geometry" => index["geometry_hash"]),
    )
    return ScenePacket(String[String(s) for s in variant["stages"]],
        (Float64(origin[1]), Float64(origin[2]), Float64(origin[3])), meta, buffers)
end
