# Binary scene packet (version 1). See docs/src/reference/scene_format.md.

"""Magic `MGSC` as a little-endian `UInt32`."""
const SCENE_MAGIC = 0x4353474d
const SCENE_VERSION = 0x0001

const _SCENE_DTYPE_SIZE = Dict("f32" => 4, "u32" => 4, "u16" => 2, "u8" => 1)

"""One typed array inside a [`ScenePacket`](@ref). `count` is the number of scalars."""
struct SceneBuffer
    name::String
    dtype::String
    count::Int
    data::Vector{UInt8}
end

"""A versioned scene packet. `origin` is meters. `meta` holds counts, hashes, and display hints."""
struct ScenePacket
    stages::Vector{String}
    origin::NTuple{3, Float64}
    meta::Dict{String, Any}
    buffers::Vector{SceneBuffer}
end

function SceneBuffer(name::AbstractString, v::Vector{Float32})
    return SceneBuffer(String(name), "f32", length(v), _pod_bytes(v))
end
function SceneBuffer(name::AbstractString, v::Vector{UInt32})
    return SceneBuffer(String(name), "u32", length(v), _pod_bytes(v))
end
function SceneBuffer(name::AbstractString, v::Vector{UInt16})
    return SceneBuffer(String(name), "u16", length(v), _pod_bytes(v))
end
function SceneBuffer(name::AbstractString, v::Vector{UInt8})
    return SceneBuffer(String(name), "u8", length(v), copy(v))
end

function _pod_bytes(v::Vector{T}) where {T}
    n = sizeof(v)
    out = Vector{UInt8}(undef, n)
    GC.@preserve v out unsafe_copyto!(pointer(out), Ptr{UInt8}(pointer(v)), n)
    return out
end

function _pod_load(::Type{T}, data::Vector{UInt8}) where {T}
    nbytes = length(data)
    nbytes % sizeof(T) == 0 || error("scene buffer length $nbytes is not a multiple of $(sizeof(T))")
    out = Vector{T}(undef, nbytes ÷ sizeof(T))
    GC.@preserve data out unsafe_copyto!(Ptr{UInt8}(pointer(out)), pointer(data), nbytes)
    return out
end

"""Return the named buffer, or throw if the packet does not contain it."""
function scene_buffer(packet::ScenePacket, name::AbstractString)
    for b in packet.buffers
        b.name == name && return b
    end
    error("scene packet has no buffer \"$name\"")
end

scene_f32(packet::ScenePacket, name::AbstractString) = _pod_load(Float32, scene_buffer(packet, name).data)
scene_u32(packet::ScenePacket, name::AbstractString) = _pod_load(UInt32, scene_buffer(packet, name).data)
scene_u16(packet::ScenePacket, name::AbstractString) = _pod_load(UInt16, scene_buffer(packet, name).data)
scene_u8(packet::ScenePacket, name::AbstractString) = scene_buffer(packet, name).data

function _buffer_table(buffers::Vector{SceneBuffer})
    offset = 0
    table = Vector{Dict{String, Any}}(undef, length(buffers))
    for (i, b) in enumerate(buffers)
        haskey(_SCENE_DTYPE_SIZE, b.dtype) || error("scene buffer \"$(b.name)\" has unknown dtype $(b.dtype)")
        expected = b.count * _SCENE_DTYPE_SIZE[b.dtype]
        length(b.data) == expected || error(
            "scene buffer \"$(b.name)\" holds $(length(b.data)) bytes, expected $expected")
        offset = (offset + 7) & ~7
        table[i] = Dict{String, Any}(
            "name" => b.name, "dtype" => b.dtype, "count" => b.count, "offset" => offset)
        offset += length(b.data)
    end
    return table
end

function _header_dict(packet::ScenePacket)
    header = Dict{String, Any}(
        "version" => Int(SCENE_VERSION),
        "stages" => packet.stages,
        "units" => Dict{String, Any}(
            "position" => "m",
            "displacement" => "m",
            "rotation" => "rad",
            "force" => "N",
            "line_load" => "N/m",
            "stress" => "Pa",
        ),
        "origin" => [packet.origin[1], packet.origin[2], packet.origin[3]],
        "buffers" => _buffer_table(packet.buffers),
    )
    for (k, v) in packet.meta
        haskey(header, k) && error("scene meta key \"$k\" collides with a header field")
        header[k] = v
    end
    return header
end

function _align8(io::IO)
    extra = (8 - (position(io) % 8)) % 8
    extra == 0 && return
    write(io, zeros(UInt8, extra))
    return
end

"""Skip the zero padding `_align8` wrote. A read-only stream cannot be padded."""
function _skip_align8(io::IO)
    extra = (8 - (position(io) % 8)) % 8
    extra == 0 || skip(io, extra)
    return
end

"""
    write_scene(io, packet) -> Int
    write_scene(path, packet) -> Int

Write `packet` as a version-1 `.mgscene` payload. Returns the number of bytes written.
"""
function write_scene(io::IO, packet::ScenePacket)
    header = Vector{UInt8}(JSON3.write(_header_dict(packet)))
    start = position(io)
    write(io, UInt32(SCENE_MAGIC))
    write(io, UInt16(SCENE_VERSION))
    write(io, UInt16(0))
    write(io, UInt32(length(header)))
    write(io, header)
    _align8(io)
    for entry in _buffer_table(packet.buffers)
        while (position(io) % 8) != 0
            write(io, UInt8(0))
        end
        # Offsets are relative to the buffer region. Padding between buffers was
        # included in the table, so the file cursor and the table stay in step
        # as long as the region itself started 8-aligned.
        buf = scene_buffer(packet, entry["name"])
        write(io, buf.data)
    end
    return position(io) - start
end

function write_scene(path::AbstractString, packet::ScenePacket)
    open(path, "w") do io
        write_scene(io, packet)
    end
end

function _json_number(x)::Float64
    return Float64(x)
end

"""
    read_scene(io) -> ScenePacket
    read_scene(path) -> ScenePacket

Read a version-1 scene packet. Throws if the magic, version, or a buffer extent is wrong.
"""
function read_scene(io::IO)
    magic = read(io, UInt32)
    magic == SCENE_MAGIC || error("scene: bad magic 0x$(string(magic, base=16)); expected MGSC")
    version = read(io, UInt16)
    version == SCENE_VERSION || error("scene: unsupported version $version")
    _flags = read(io, UInt16)
    hlen = Int(read(io, UInt32))
    hlen >= 2 || error("scene: header length $hlen is not a JSON object")
    header = JSON3.read(read(io, hlen))
    _skip_align8(io)
    blob = read(io)

    stages = String[String(s) for s in header.stages]
    origin = (_json_number(header.origin[1]), _json_number(header.origin[2]), _json_number(header.origin[3]))

    buffers = SceneBuffer[]
    for entry in header.buffers
        dtype = String(entry.dtype)
        haskey(_SCENE_DTYPE_SIZE, dtype) || error("scene: unknown dtype \"$dtype\"")
        count = Int(entry.count)
        offset = Int(entry.offset)
        nbytes = count * _SCENE_DTYPE_SIZE[dtype]
        stop = offset + nbytes
        (offset >= 0 && stop <= length(blob)) || error(
            "scene: buffer \"$(entry.name)\" extent $offset:$stop is outside the $(length(blob))-byte region")
        push!(buffers, SceneBuffer(String(entry.name), dtype, count, blob[(offset + 1):stop]))
    end

    meta = Dict{String, Any}()
    for (k, v) in pairs(header)
        key = String(k)
        key in ("version", "stages", "units", "origin", "buffers") && continue
        meta[key] = v
    end
    return ScenePacket(stages, origin, meta, buffers)
end

function read_scene(path::AbstractString)
    return open(read_scene, path)
end

"""Write a scene for `model` to `path`. See [`build_scene`](@ref) for `stages` and `stations`."""
function export_scene(path::AbstractString, model; kwargs...)
    packet = build_scene(model; kwargs...)
    write_scene(path, packet)
    return packet
end
