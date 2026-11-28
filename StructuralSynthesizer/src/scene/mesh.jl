# Solid meshes from a scene packet.
#
# Columns are the swept `member_solid_*` triangles. Each shell triangle is
# extruded so the panels on one plane share a top and each thickness hangs
# below it, the same prism `buildShellVolumes` draws. A wall stays centered
# on its analysis surface. A spread footing is the box
# `footing_center` and `footing_size` already describe. Positions are meters,
# structural Z up, with the scene origin added.

"""One named triangle mesh. `positions` is xyz, `faces` is 0-based into that list."""
struct SceneMesh
    name::String
    positions::Vector{Float64}
    faces::Vector{Int}
end

function _scene_has_buffer(packet::ScenePacket, name::AbstractString)
    return any(b -> b.name == name, packet.buffers)
end

function _xyz(pos::Vector{Float32}, index::Integer)
    i = Int(index) * 3
    return (Float64(pos[i + 1]), Float64(pos[i + 2]), Float64(pos[i + 3]))
end

function _push_xyz!(out::Vector{Float64}, p::NTuple{3, Float64}, origin::NTuple{3, Float64})
    push!(out, p[1] + origin[1], p[2] + origin[2], p[3] + origin[3])
    return nothing
end

"""Extrude shell triangles of the given kinds. Degenerate or zero-thickness triangles are skipped."""
function _extrude_shells(pos::Vector{Float32}, faces::Vector{UInt32}, kinds::Vector{UInt8},
                         thickness::Vector{Float32}, keep::Set{UInt8}, origin::NTuple{3, Float64})
    length(faces) == length(kinds) * 3 || error(
        "scene mesh: $(length(kinds)) shell kinds but $(length(faces) ÷ 3) faces")
    length(thickness) == length(kinds) || error(
        "scene mesh: $(length(thickness)) thicknesses for $(length(kinds)) shell triangles")
    out_pos = Float64[]
    out_faces = Int[]
    for t in eachindex(kinds)
        kinds[t] in keep || continue
        h = Float64(thickness[t])
        h > 0 || continue
        base_f = (t - 1) * 3
        a = _xyz(pos, faces[base_f + 1])
        b = _xyz(pos, faces[base_f + 2])
        c = _xyz(pos, faces[base_f + 3])
        e1 = (b[1] - a[1], b[2] - a[2], b[3] - a[3])
        e2 = (c[1] - a[1], c[2] - a[2], c[3] - a[3])
        nx = e1[2] * e2[3] - e1[3] * e2[2]
        ny = e1[3] * e2[1] - e1[1] * e2[3]
        nz = e1[1] * e2[2] - e1[2] * e2[1]
        len = hypot(nx, ny, nz)
        len < 1e-9 && continue
        low, high = -h / 2, h / 2
        inv = (nz < 0 ? -1 : 1) / len
        up = (nx * inv, ny * inv, nz * inv)
        base = length(out_pos) ÷ 3
        for p in (a, b, c)
            _push_xyz!(out_pos, (p[1] + up[1] * low, p[2] + up[2] * low, p[3] + up[3] * low), origin)
        end
        for p in (a, b, c)
            _push_xyz!(out_pos, (p[1] + up[1] * high, p[2] + up[2] * high, p[3] + up[3] * high), origin)
        end
        # Two caps, then the three quads. Same winding as the viewer prism.
        append!(out_faces, (base, base + 2, base + 1, base + 3, base + 4, base + 5))
        for (i, j, k, m) in ((0, 1, 4, 3), (1, 2, 5, 4), (2, 0, 3, 5))
            append!(out_faces, (base + i, base + j, base + k, base + i, base + k, base + m))
        end
    end
    return out_pos, out_faces
end

"""A rectangular box centered at `center` with full side lengths `size`, structural axes."""
function _box_mesh(center::NTuple{3, Float64}, size::NTuple{3, Float64}, origin::NTuple{3, Float64})
    hx, hy, hz = size[1] / 2, size[2] / 2, size[3] / 2
    signs = ((-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
             (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1))
    pos = Float64[]
    for (sx, sy, sz) in signs
        _push_xyz!(pos, (center[1] + sx * hx, center[2] + sy * hy, center[3] + sz * hz), origin)
    end
    # 0-based corners. Bottom, top, then four sides.
    faces = Int[
        0, 2, 1,  0, 3, 2,
        4, 5, 6,  4, 6, 7,
        0, 1, 5,  0, 5, 4,
        1, 2, 6,  1, 6, 5,
        2, 3, 7,  2, 7, 6,
        3, 0, 4,  3, 4, 7,
    ]
    return pos, faces
end

"""
    scene_meshes(packet) -> Vector{SceneMesh}

Columns, slabs, walls, and footings that the scene can draw as solids.
An empty group is omitted. Throws when the packet has shell triangles and no thickness.
"""
function scene_meshes(packet::ScenePacket)
    origin = packet.origin
    meshes = SceneMesh[]
    if _scene_has_buffer(packet, "member_solid_position") && _scene_has_buffer(packet, "member_solid_faces")
        raw = scene_f32(packet, "member_solid_position")
        faces = scene_u32(packet, "member_solid_faces")
        if !isempty(faces)
            pos = Float64[]
            for i in 1:3:length(raw)
                _push_xyz!(pos, (Float64(raw[i]), Float64(raw[i + 1]), Float64(raw[i + 2])), origin)
            end
            push!(meshes, SceneMesh("columns", pos, Int.(faces)))
        end
    end
    if _scene_has_buffer(packet, "shell_faces")
        faces = scene_u32(packet, "shell_faces")
        if !isempty(faces)
            _scene_has_buffer(packet, "shell_kind") || error("scene mesh: shell faces have no shell_kind")
            _scene_has_buffer(packet, "shell_thickness") || error(
                "scene mesh: shell faces have no shell_thickness")
            _scene_has_buffer(packet, "node_position") || error("scene mesh: shell faces have no node_position")
            pos = scene_f32(packet, "node_position")
            kinds = scene_u8(packet, "shell_kind")
            thickness = scene_f32(packet, "shell_thickness")
            for (name, keep) in (("slabs", Set{UInt8}([0x00, 0x02])), ("walls", Set{UInt8}([0x01])))
                epos, efaces = _extrude_shells(pos, faces, kinds, thickness, keep, origin)
                isempty(efaces) && continue
                push!(meshes, SceneMesh(name, epos, efaces))
            end
        end
    end
    if _scene_has_buffer(packet, "footing_center") && _scene_has_buffer(packet, "footing_size")
        center = scene_f32(packet, "footing_center")
        size = scene_f32(packet, "footing_size")
        length(center) == length(size) || error(
            "scene mesh: $(length(center) ÷ 3) footing centers and $(length(size) ÷ 3) sizes")
        pos = Float64[]
        faces = Int[]
        for i in 1:3:length(center)
            bpos, bfaces = _box_mesh(
                (Float64(center[i]), Float64(center[i + 1]), Float64(center[i + 2])),
                (Float64(size[i]), Float64(size[i + 1]), Float64(size[i + 2])),
                origin)
            base = length(pos) ÷ 3
            append!(pos, bpos)
            append!(faces, bfaces .+ base)
        end
        isempty(faces) || push!(meshes, SceneMesh("footings", pos, faces))
    end
    return meshes
end

"""
    write_scene_obj(io, packet)
    write_scene_obj(path, packet)

Write `scene_meshes(packet)` as a Wavefront OBJ. One object per group.
Vertices are meters, structural Z up, in absolute coordinates.
"""
function write_scene_obj(io::IO, packet::ScenePacket)
    meshes = scene_meshes(packet)
    isempty(meshes) && error("scene mesh: the packet has no solid geometry")
    println(io, "# menegroth scene mesh")
    println(io, "# units m")
    println(io, "# Z up")
    vbase = 0
    for mesh in meshes
        println(io, "o ", mesh.name)
        pos = mesh.positions
        for i in 1:3:length(pos)
            println(io, "v ", pos[i], " ", pos[i + 1], " ", pos[i + 2])
        end
        faces = mesh.faces
        for t in 1:3:length(faces)
            println(io, "f ", faces[t] + 1 + vbase, " ", faces[t + 1] + 1 + vbase, " ", faces[t + 2] + 1 + vbase)
        end
        vbase += length(pos) ÷ 3
    end
    return meshes
end

function write_scene_obj(path::AbstractString, packet::ScenePacket)
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    return open(path, "w") do io
        write_scene_obj(io, packet)
    end
end

"""
    export_scene_meshes(scene_path, obj_path) -> Vector{SceneMesh}

Read a scene packet and write its solids as an OBJ. Returns the meshes written.
"""
function export_scene_meshes(scene_path::AbstractString, obj_path::AbstractString)
    return write_scene_obj(obj_path, read_scene(scene_path))
end
