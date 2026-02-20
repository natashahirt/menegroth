# =============================================================================
# Tributary Accessors for BuildingStructure
# =============================================================================
#
# Higher-level convenience functions for accessing tributary data stored in
# BuildingStructure._tributary_caches (TributaryCache).
#
# These operate on BuildingStructure and provide a clean API for:
# - Column tributary areas (Voronoi)
# - Cell edge tributaries (straight skeleton / directed)
# - Strip geometry (column/middle strip split)
#
# =============================================================================
# UNIT CONVENTION - Explicit Unitful Storage
# =============================================================================
#
# TributaryCache stores Unitful quantities directly:
#   - Areas:       AreaQuantity    (e.g., 45.2 m²)
#   - Lengths:     LengthQuantity  (e.g., 3.5 m)
#   - Polygons:    NTuple{2, LengthQuantity} (e.g., (3.5 m, 2.1 m))
#
# All accessor functions return Unitful quantities:
#   At = column_tributary_area(struc, col)  # → 45.2 m²
#   by_cell = column_tributary_by_cell(struc, col)  # Dict{Int, AreaQuantity}
#
# For visualization, strip units:
#   area_val = ustrip(u"m^2", At)  # → 45.2 (Float64)
#
# =============================================================================

"""
    tributary_cache_key(behavior, axis) -> TributaryCacheKey

Create a cache key for tributary lookup.

# Examples
```julia
key = tributary_cache_key(:one_way, [1.0, 0.0])  # One-way along X
key = tributary_cache_key(:two_way, nothing)     # Isotropic
key = tributary_cache_key(OneWaySpanning(), [0.0, 1.0])  # One-way along Y
```
"""
tributary_cache_key(behavior::Symbol, axis) = TributaryCacheKey(behavior, 
    isnothing(axis) ? UInt64(0) : hash((round(axis[1], digits=6), round(axis[2], digits=6))))
tributary_cache_key(behavior::SpanningBehavior, axis) = TributaryCacheKey(behavior, axis)

# =============================================================================
# Column (Vertex) Tributary Accessors
# =============================================================================

"""
    get_cached_column_tributary(struc, story, vertex_idx)

Get cached Voronoi tributary for a column, or nothing if not cached.
"""
function get_cached_column_tributary(struc::BuildingStructure, story::Int, vertex_idx::Int)
    return get_vertex_tributary(struc._tributary_caches, story, vertex_idx)
end

"""
    cache_column_tributary!(struc, story, vertex_idx, total_area, by_cell, polygons)

Store column Voronoi tributary in the cache.

# Arguments
- `total_area`: Area quantity (e.g., `45.2u"m^2"`)
- `by_cell`: Dict{Int, AreaQuantity} mapping cell_idx → area
- `polygons`: Dict{Int, Vector{NTuple{2, LengthQuantity}}} for visualization
"""
function cache_column_tributary!(struc::BuildingStructure, story::Int, vertex_idx::Int,
                                  total_area::AreaQuantity,
                                  by_cell::Dict{Int, AreaQuantity},
                                  polygons::Dict{Int, Vector{NTuple{2, LengthQuantity}}})
    result = ColumnTributaryResult(total_area, by_cell, polygons)
    set_vertex_tributary!(struc._tributary_caches, story, vertex_idx, result)
    return result
end

"""
    column_tributary_area(struc, col)

Get total tributary area for a column from the cache.

Returns the area as a Unitful quantity (e.g., `45.2 m²`), or `nothing` if not computed.

# Example
```julia
At = column_tributary_area(struc, col)  # → 45.2 m²
isnothing(At) && error("Tributaries not computed!")
```
"""
function column_tributary_area(struc::BuildingStructure, col)
    cached = get_vertex_tributary(struc._tributary_caches, col.story, col.vertex_idx)
    isnothing(cached) && return nothing
    return cached.total_area  # Already Unitful
end

"""
    column_tributary_by_cell(struc, col)

Get per-cell tributary area breakdown for a column from the cache.
Returns Dict{Int, AreaQuantity} (cell_idx → area), or empty Dict if not computed.

# Example
```julia
by_cell = column_tributary_by_cell(struc, col)
for (cell_idx, area) in by_cell
    println("Cell \$cell_idx: \$area")  # e.g., "Cell 3: 22.5 m²"
end
```
"""
function column_tributary_by_cell(struc::BuildingStructure, col)
    cached = get_vertex_tributary(struc._tributary_caches, col.story, col.vertex_idx)
    isnothing(cached) && return Dict{Int, AreaQuantity}()
    return cached.by_cell
end

"""
    column_tributary_polygons(struc, col)

Get tributary polygon vertices for a column from the cache (for visualization).
Returns Dict{Int, Vector{NTuple{2, LengthQuantity}}} (cell_idx → polygon vertices), 
or empty Dict if not computed.

# Example
```julia
polygons = column_tributary_polygons(struc, col)
for (cell_idx, verts) in polygons
    for (x, y) in verts
        println("(\$x, \$y)")  # e.g., "(3.5 m, 2.1 m)"
    end
end
```
"""
function column_tributary_polygons(struc::BuildingStructure, col)
    cached = get_vertex_tributary(struc._tributary_caches, col.story, col.vertex_idx)
    isnothing(cached) && return Dict{Int, Vector{NTuple{2, LengthQuantity}}}()
    return cached.polygons
end

# =============================================================================
# Cell Edge Tributary Accessors
# =============================================================================

"""
    get_cached_edge_tributaries(struc, behavior, axis, cell_idx)

Get cached edge tributaries for a cell, or nothing if not cached.

# Arguments
- `struc`: BuildingStructure
- `behavior`: :one_way, :two_way, :beamless (or SpanningBehavior type)
- `axis`: Direction vector [vx, vy] or nothing for isotropic
- `cell_idx`: Cell index
"""
function get_cached_edge_tributaries(struc::BuildingStructure, behavior, axis, cell_idx::Int)
    key = tributary_cache_key(behavior, axis)
    return get_edge_tributaries(struc._tributary_caches, key, cell_idx)
end

"""
    cache_edge_tributaries!(struc, behavior, axis, cell_idx, tributaries; strip_geometry=nothing)

Store edge tributaries in the cache.
"""
function cache_edge_tributaries!(struc::BuildingStructure, behavior, axis, cell_idx::Int, 
                                  tributaries::Vector{<:TributaryPolygon};
                                  strip_geometry::Union{PanelStripGeometry, Nothing}=nothing)
    key = tributary_cache_key(behavior, axis)
    result = CellTributaryResult(tributaries, strip_geometry)
    set_edge_tributaries!(struc._tributary_caches, key, cell_idx, result)
    return result
end

"""
    cell_edge_tributaries(struc, cell_idx, behavior, axis)

Get edge tributaries for a cell from the cache.
Returns Vector{TributaryPolygon} or nothing if not computed.
"""
function cell_edge_tributaries(struc::BuildingStructure, cell_idx::Int, behavior, axis)
    cached = get_cached_edge_tributaries(struc, behavior, axis, cell_idx)
    isnothing(cached) && return nothing
    return cached.edge_tributaries
end

"""
    cell_edge_tributaries(struc, cell_idx)

Get edge tributaries for a cell using its floor_type to determine behavior/axis.
Returns Vector{TributaryPolygon} or nothing if not computed.
"""
function cell_edge_tributaries(struc::BuildingStructure, cell_idx::Int)
    cell = struc.cells[cell_idx]
    ft = StructuralSizer.floor_type(cell.floor_type)
    behavior = StructuralSizer.spanning_behavior(ft)
    axis = StructuralSizer.resolve_tributary_axis(ft, cell.spans)
    return cell_edge_tributaries(struc, cell_idx, behavior, axis)
end

"""
    cell_strip_geometry(struc, cell_idx, behavior, axis)

Get strip geometry (column/middle strip split) for a cell from the cache.
Returns PanelStripGeometry or nothing if not computed.
"""
function cell_strip_geometry(struc::BuildingStructure, cell_idx::Int, behavior, axis)
    cached = get_cached_edge_tributaries(struc, behavior, axis, cell_idx)
    isnothing(cached) && return nothing
    return cached.strip_geometry
end

"""
    has_cell_tributaries(struc, cell_idx, behavior, axis)

Check if edge tributaries are cached for a cell.
"""
function has_cell_tributaries(struc::BuildingStructure, cell_idx::Int, behavior, axis)
    return !isnothing(get_cached_edge_tributaries(struc, behavior, axis, cell_idx))
end

# =============================================================================
# Cache Management
# =============================================================================

"""
    clear_geometry_caches!(struc)

Clear all geometry-dependent caches: tributaries AND analysis models
(FEA meshes, EFM frames, etc.).  Call when the skeleton changes.
"""
function clear_geometry_caches!(struc::BuildingStructure)
    clear!(struc._tributary_caches)
    empty!(struc._analysis_caches)
end



# =============================================================================
# Analysis Cache Accessors
# =============================================================================

"""
    _get_analysis_cache(struc, slab_idx, method) -> cache or nothing

Lazily retrieve or create an analysis cache for a (slab, method) pair.
DDM is stateless (returns nothing).  EFM and FEA caches are created on
first access and persist across design runs until `clear_geometry_caches!`.
"""
function _get_analysis_cache(struc, slab_idx::Int, method)
    # Import method types from StructuralSizer
    SR = StructuralSizer
    method isa SR.DDM && return nothing

    key = method isa SR.FEA ? :fea : :efm
    slab_caches = get!(struc._analysis_caches, slab_idx, Dict{Symbol, Any}())
    return get!(slab_caches, key) do
        key == :fea ? SR.FEAModelCache() : SR.EFMModelCache()
    end
end
