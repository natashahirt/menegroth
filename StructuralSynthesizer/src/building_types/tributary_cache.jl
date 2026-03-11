# =============================================================================
# Tributary Cache Types
# =============================================================================

"""
Key for tributary cache lookups.

Tributaries depend on:
- `behavior`: Spanning behavior (:one_way, :two_way, :beamless)
- `axis_hash`: Hash of axis direction (or 0 for isotropic)

This allows caching multiple tributary configurations without recalculation.
"""
struct TributaryCacheKey
    behavior::Symbol           # :one_way, :two_way, :beamless
    axis_hash::UInt64          # hash of axis vector (0 for isotropic)
end

"""Isotropic cache key (axis hash = 0) from a bare symbol."""
TributaryCacheKey(behavior::Symbol) = TributaryCacheKey(behavior, UInt64(0))

# Accept AbstractVector, Tuple, or Nothing for axis
"""Construct a `TributaryCacheKey` from a `SpanningBehavior` and optional axis direction."""
function TributaryCacheKey(behavior::SpanningBehavior, axis::Union{Nothing, AbstractVector, Tuple})
    bsym = if behavior isa OneWaySpanning
        :one_way
    elseif behavior isa TwoWaySpanning
        :two_way
    else
        :beamless
    end
    
    axis_h = if isnothing(axis) || (behavior isa TwoWaySpanning)
        UInt64(0)  # Isotropic - no axis
    else
        # Normalize axis and hash (convert to mutable vector first)
        ax = [Float64(axis[1]), Float64(axis[2])]
        norm = hypot(ax[1], ax[2])
        if norm > 1e-12
            ax[1] /= norm
            ax[2] /= norm
            # Ensure consistent direction (positive x, or positive y if x≈0)
            if ax[1] < -1e-9 || (abs(ax[1]) < 1e-9 && ax[2] < 0)
                ax[1] = -ax[1]
                ax[2] = -ax[2]
            end
        end
        hash((round(ax[1], digits=6), round(ax[2], digits=6)))
    end
    
    return TributaryCacheKey(bsym, axis_h)
end

Base.hash(k::TributaryCacheKey, h::UInt) = hash((k.behavior, k.axis_hash), h)
Base.:(==)(a::TributaryCacheKey, b::TributaryCacheKey) = 
    a.behavior == b.behavior && a.axis_hash == b.axis_hash

"""Cached tributary results for a single cell."""
struct CellTributaryResult
    edge_tributaries::Vector{TributaryPolygon}    # One per edge
    strip_geometry::Union{PanelStripGeometry, Nothing}  # Column/middle strip split
end

# Import concrete Unitful type aliases from Asap (via StructuralSizer)
using Asap: AreaQuantity, LengthQuantity

"""
Cached Voronoi tributary for a column.

All values are Unitful quantities - no ambiguity about units:
- `total_area`: Area (m²)
- `by_cell`: Dict mapping cell_idx → Area (m²)
- `polygons`: Dict mapping cell_idx → vertices as (Length, Length) tuples

Example:
```julia
result = struc._tributary_caches.vertex[story][vertex_idx]
At = result.total_area  # → 45.2 m²
```
"""
struct ColumnTributaryResult
    total_area::AreaQuantity                                      # e.g., 45.2 m²
    by_cell::Dict{Int, AreaQuantity}                              # cell_idx → area
    polygons::Dict{Int, Vector{NTuple{2, LengthQuantity}}}        # cell_idx → [(x,y), ...]
end

"""
Cache of all tributary computations for a BuildingStructure.

Keyed by (behavior, axis) so multiple configurations can coexist.
Computing tributaries for a new configuration adds to the cache without
discarding previous results.

All values are stored as explicit Unitful quantities (no ambiguity):
- Areas as `AreaQuantity` (e.g., `45.2u"m^2"`)
- Coordinates as `LengthQuantity` (e.g., `3.5u"m"`)

Use accessor functions in `tributary_accessors.jl`:
```julia
At = column_tributary_area(struc, col)  # → 45.2 m²
```
"""
mutable struct TributaryCache
    # Edge tributaries (for beam loading)
    # key → (cell_idx → CellTributaryResult)
    edge::Dict{TributaryCacheKey, Dict{Int, CellTributaryResult}}
    
    # Vertex/column tributaries (for punching shear)
    # story_idx → Dict(vertex_idx → ColumnTributaryResult)
    vertex::Dict{Int, Dict{Int, ColumnTributaryResult}}
    
    # Timestamps for cache management
    edge_computed::Dict{TributaryCacheKey, DateTime}
    vertex_computed::Dict{Int, DateTime}
end

"""Create an empty `TributaryCache` with no stored results."""
TributaryCache() = TributaryCache(
    Dict{TributaryCacheKey, Dict{Int, CellTributaryResult}}(),
    Dict{Int, Dict{Int, ColumnTributaryResult}}(),
    Dict{TributaryCacheKey, DateTime}(),
    Dict{Int, DateTime}()
)

# -----------------------------------------------------------------------------
# TributaryCache Direct Methods (low-level)
# -----------------------------------------------------------------------------

"""Check if edge tributaries are cached for the given key."""
has_edge_tributaries(cache::TributaryCache, key::TributaryCacheKey) = 
    haskey(cache.edge, key)

"""Check if vertex tributaries are cached for the given story."""
has_vertex_tributaries(cache::TributaryCache, story::Int) = 
    haskey(cache.vertex, story)

"""Get cached edge tributaries, or nothing if not cached."""
function get_edge_tributaries(cache::TributaryCache, key::TributaryCacheKey, cell_idx::Int)
    haskey(cache.edge, key) || return nothing
    haskey(cache.edge[key], cell_idx) || return nothing
    return cache.edge[key][cell_idx]
end

"""Store edge tributaries in cache."""
function set_edge_tributaries!(cache::TributaryCache, key::TributaryCacheKey, 
                               cell_idx::Int, result::CellTributaryResult)
    if !haskey(cache.edge, key)
        cache.edge[key] = Dict{Int, CellTributaryResult}()
        cache.edge_computed[key] = now()
    end
    cache.edge[key][cell_idx] = result
end

"""Get cached vertex tributaries for a column, or nothing."""
function get_vertex_tributary(cache::TributaryCache, story::Int, vertex_idx::Int)
    haskey(cache.vertex, story) || return nothing
    haskey(cache.vertex[story], vertex_idx) || return nothing
    return cache.vertex[story][vertex_idx]
end

"""Store vertex tributary in cache."""
function set_vertex_tributary!(cache::TributaryCache, story::Int, 
                               vertex_idx::Int, result::ColumnTributaryResult)
    if !haskey(cache.vertex, story)
        cache.vertex[story] = Dict{Int, ColumnTributaryResult}()
        cache.vertex_computed[story] = now()
    end
    cache.vertex[story][vertex_idx] = result
end

"""Clear all cached tributaries."""
function clear!(cache::TributaryCache)
    empty!(cache.edge)
    empty!(cache.vertex)
    empty!(cache.edge_computed)
    empty!(cache.vertex_computed)
end
