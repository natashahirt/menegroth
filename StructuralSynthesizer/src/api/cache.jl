# =============================================================================
# API Cache — Geometry hashing + skeleton/structure cache
# =============================================================================

using SHA

"""
    DesignCache

Caches the last `BuildingSkeleton` and `BuildingStructure` keyed by a hash
of the geometry fields. When only design parameters change, the server skips
skeleton/structure rebuild and re-runs `design_building` on the cached structure.
"""
mutable struct DesignCache
    geometry_hash::String
    skeleton::Union{BuildingSkeleton, Nothing}
    structure::Union{BuildingStructure, Nothing}
    last_result::Union{APIOutput, APIError, Nothing}
end

"""Create an empty `DesignCache` with no stored geometry or results."""
DesignCache() = DesignCache("", nothing, nothing, nothing)

"""
    compute_geometry_hash(input::APIInput) -> String

Compute a deterministic SHA-256 hash of the geometry portion of the input
(units, vertices, edges, supports, stories_z, faces). Params are excluded
so that parameter-only changes produce the same hash.
"""
function compute_geometry_hash(input::APIInput)
    ctx = SHA.SHA256_CTX()

    # Units
    SHA.update!(ctx, Vector{UInt8}(input.units))

    # Vertices
    for v in input.vertices
        for c in v
            SHA.update!(ctx, reinterpret(UInt8, [c]))
        end
    end

    # Edges — beams then columns
    for edge in input.edges.beams
        SHA.update!(ctx, reinterpret(UInt8, Int64.(edge)))
    end
    for edge in input.edges.columns
        SHA.update!(ctx, reinterpret(UInt8, Int64.(edge)))
    end
    for edge in input.edges.braces
        SHA.update!(ctx, reinterpret(UInt8, Int64.(edge)))
    end

    # Supports
    SHA.update!(ctx, reinterpret(UInt8, Int64.(input.supports)))

    # Stories Z
    SHA.update!(ctx, reinterpret(UInt8, Float64.(input.stories_z)))

    # Faces (sorted by category for determinism)
    for cat in sort(collect(keys(input.faces)))
        SHA.update!(ctx, Vector{UInt8}(cat))
        for poly in input.faces[cat]
            for coord in poly
                SHA.update!(ctx, reinterpret(UInt8, Float64.(coord)))
            end
        end
    end

    return bytes2hex(SHA.digest!(ctx))
end

"""
    is_geometry_cached(cache::DesignCache, hash::String) -> Bool

Check whether the cache holds a skeleton/structure for the given geometry hash.
"""
function is_geometry_cached(cache::DesignCache, hash::String)
    return !isempty(hash) && cache.geometry_hash == hash &&
           !isnothing(cache.skeleton) && !isnothing(cache.structure)
end
