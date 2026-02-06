# =============================================================================
# Building Types for StructuralSynthesizer
# =============================================================================
#
# Core data structures for representing buildings:
# - BuildingSkeleton: geometry (vertices, edges, faces)
# - BuildingStructure: analytical layer (cells, members, tributaries)
# - TributaryCache: cached tributary computations
#
# =============================================================================
# Data Hierarchy
# =============================================================================
#
# BuildingStructure
# ├── skeleton::BuildingSkeleton        # Geometry (vertices, edges, faces)
# ├── site::SiteConditions              # Environment (soil, wind, seismic, snow)
# │
# ├── cells[]::Cell                     # Per-face load data (loads, floor_type)
# ├── slabs[]::Slab                     # Slab groupings + sizing results
# │
# ├── segments[]::Segment               # Per-edge geometry data
# ├── beams[]::Beam                     # Horizontal members
# ├── columns[]::Column                 # Vertical members (vertex_idx, c1, c2)
# ├── struts[]::Strut                   # Diagonal members
# │
# ├── supports[]::Support               # Per-node reactions
# ├── foundations[]::Foundation         # Foundation elements + results
# │
# ├── tributaries::TributaryCache       # All tributary data (single source of truth)
# │   ├── edge[key][cell_idx]           # Edge tributaries (keyed by axis/behavior)
# │   └── vertex[story][vertex_idx]     # Column Voronoi tributaries
# │
# ├── *_groups                          # Optimization groupings (hash → indices)
# └── asap_model                        # Analysis backend (ASAP)
#
# Tributary Access (use accessor functions in core/tributary_accessors.jl):
#   column_tributary_area(struc, col)     → total area (m²)
#   column_tributary_by_cell(struc, col)  → Dict{cell_idx → area}
#   cell_edge_tributaries(struc, cell_idx)
#
# =============================================================================

using Dates

# =============================================================================
# Re-exports from StructuralSizer
# =============================================================================

const TributaryPolygon = StructuralSizer.TributaryPolygon
const PanelStripGeometry = StructuralSizer.PanelStripGeometry
const SpanInfo = StructuralSizer.SpanInfo
const vertices = StructuralSizer.vertices

# Spanning behavior traits
const SpanningBehavior = StructuralSizer.SpanningBehavior
const OneWaySpanning = StructuralSizer.OneWaySpanning
const TwoWaySpanning = StructuralSizer.TwoWaySpanning
const BeamlessSpanning = StructuralSizer.BeamlessSpanning

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

TributaryCacheKey(behavior::Symbol) = TributaryCacheKey(behavior, UInt64(0))

# Accept AbstractVector, Tuple, or Nothing for axis
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
result = struc.tributaries.vertex[story][vertex_idx]
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

# =============================================================================
# Site Conditions
# =============================================================================

"""
    SiteConditions

Site-level environmental and geotechnical parameters for structural design.
Referenced by `BuildingStructure` for foundation, wind, and seismic design.
"""
Base.@kwdef mutable struct SiteConditions
    # Geotechnical
    soil::Union{StructuralSizer.Soil, Nothing} = nothing
    
    # Wind (ASCE 7)
    wind_speed::Union{typeof(1.0u"m/s"), Nothing} = nothing
    exposure_category::Symbol = :C
    topographic_factor::Float64 = 1.0
    
    # Seismic (ASCE 7)
    Ss::Union{Float64, Nothing} = nothing
    S1::Union{Float64, Nothing} = nothing
    site_class::Symbol = :D
    risk_category::Symbol = :II
    
    # Snow / Rain
    ground_snow_load::Union{typeof(1.0u"kN/m^2"), Nothing} = nothing
end

# =============================================================================
# Story
# =============================================================================

mutable struct Story{T}
    elevation::T
    vertices::Vector{Int}
    edges::Vector{Int}
    faces::Vector{Int}
end

Story{T}(elev::T) where T = Story{T}(elev, Int[], Int[], Int[])

"""Grouping of geometrically identical cells (for slab sizing optimization)."""
mutable struct CellGroup
    hash::UInt64
    cell_indices::Vector{Int}
end

CellGroup(hash::UInt64) = CellGroup(hash, Int[])

# =============================================================================
# Cell
# =============================================================================

"""
Per-face analysis data (one bay).

# Tributary Access
Edge tributaries are stored in `BuildingStructure.tributaries` (TributaryCache).
Use accessor functions:
- `cell_edge_tributaries(struc, cell_idx)` → Vector{TributaryPolygon}
- `cache_edge_tributaries!(struc, behavior, axis, cell_idx, tribs)`
"""
mutable struct Cell{T, A, P}
    face_idx::Int
    area::A
    spans::SpanInfo{T}
    sdl::P
    live_load::P
    self_weight::P
    floor_type::Symbol
    position::Symbol          # :corner, :edge, or :interior
end

function Cell(face_idx::Int, area::A, spans::SpanInfo{T}, 
              sdl::P, live_load::P; position::Symbol=:interior) where {T, A, P}
    Cell{T, A, P}(face_idx, area, spans, sdl, live_load, zero(P), :unknown, position)
end

"""Total factored pressure (SDL + LL + SW)."""
total_factored_pressure(c::Cell) = (c.sdl + c.self_weight) * Constants.DL_FACTOR + c.live_load * Constants.LL_FACTOR

# Volume type alias
const VolumeType = typeof(1.0u"m^3")
const MaterialVolumes = Dict{AbstractMaterial, VolumeType}

"""Physical slab (one or more connected cells).

Note: `result` uses `AbstractFloorResult` (not parameterized) to allow 
reassignment during sizing (e.g., CIPSlabResult → FlatPlatePanelResult).
"""
mutable struct Slab{T}
    cell_indices::Vector{Int}
    result::AbstractFloorResult  # Allow any floor result type (CIP, FlatPlate, Vault, etc.)
    floor_type::Symbol        # :one_way, :two_way, :pt_banded, :flat_plate
    spans::SpanInfo{T}        # Governing spans across all child cells
    position::Symbol          # :corner, :edge, or :interior (derived from cells)
    group_id::Union{UInt64, Nothing}
    volumes::MaterialVolumes  # material → total volume (m³)
end

function Slab(cell_indices::Vector{Int}, result::AbstractFloorResult, spans::SpanInfo; 
              floor_type=:one_way, position::Symbol=:interior, group_id=nothing,
              volumes::MaterialVolumes=MaterialVolumes())
    T = typeof(StructuralSizer.total_depth(result))
    spans_T = SpanInfo{T}(T(spans.primary), T(spans.secondary), spans.axis, T(spans.isotropic))
    Slab{T}(cell_indices, result, floor_type, spans_T, position, group_id, volumes)
end

# Single-cell slab convenience
Slab(cell_idx::Int, result::AbstractFloorResult, spans::SpanInfo; kwargs...) = 
    Slab([cell_idx], result, spans; kwargs...)

# Interface for Slab to mirror Result interface
thickness(s::Slab) = StructuralSizer.total_depth(s.result)
self_weight(s::Slab) = StructuralSizer.self_weight(s.result)
structural_effects(s::Slab) = StructuralSizer.structural_effects(s.result)

"""
Backend-agnostic edge load specs produced from slabs.

These are converted to analysis-backend loads (e.g. ASAP) in `to_asap!`.
All magnitudes are expected to be plain Float64 in base SI.
"""
abstract type AbstractEdgeLoadSpec end

"""Constant line load on an edge (global line-load vector in N/m)."""
struct EdgeLineLoadSpec <: AbstractEdgeLoadSpec
    edge_idx::Int
    w::NTuple{3, Float64}
end

"""Optimization grouping for similar slabs (pure grouping logic)."""
mutable struct SlabGroup
    hash::UInt64
    slab_indices::Vector{Int}
end

SlabGroup(hash::UInt64) = SlabGroup(hash, Int[])

"""Per-edge analysis data (one per skeleton edge / ASAP element)."""
mutable struct Segment{T}
    edge_idx::Int
    L::T
    Lb::T
    Cb::Float64
end

function Segment(edge_idx::Int, L::T; Lb=L, Cb=1.0) where T
    Segment{T}(edge_idx, L, Lb, Float64(Cb))
end

# =============================================================================
# Member Type Hierarchy
# =============================================================================

"""Abstract base for all structural members (beams, columns, struts)."""
abstract type AbstractMember{T} end

"""
    MemberBase{T}

Shared fields for all member types. Uses composition pattern.
"""
@kwdef mutable struct MemberBase{T}
    segment_indices::Vector{Int} = Int[]
    L::T                                    # Total length
    Lb::T                                   # Unbraced length (governing)
    Kx::Float64 = 1.0                       # Effective length factor (strong axis)
    Ky::Float64 = 1.0                       # Effective length factor (weak axis)
    Cb::Float64 = 1.0                       # Moment gradient factor
    group_id::Union{UInt64, Nothing} = nothing
    section::Union{AbstractSection, Nothing} = nothing
    volumes::MaterialVolumes = MaterialVolumes()
end

"""
    Beam{T} <: AbstractMember{T}

Horizontal member (gravity framing system).

# Fields
- `base::MemberBase{T}`: Shared member properties
- `tributary_width`: Width of tributary area for load calculations
- `role::Symbol`: `:girder` (primary), `:beam` (secondary), `:joist` (repetitive), `:infill`
"""
@kwdef mutable struct Beam{T} <: AbstractMember{T}
    base::MemberBase{T}
    tributary_width::Union{T, Nothing} = nothing
    role::Symbol = :beam
end

"""
    Column{T} <: AbstractMember{T}

Vertical member (columns).

# Fields
- `base::MemberBase{T}`: Shared member properties
- `vertex_idx::Int`: Skeleton vertex index (column location)
- `c1`, `c2`: Cross-section dimensions (for punching shear, etc.)
- `story::Int`: Story index (0 = ground level)
- `position::Symbol`: `:interior`, `:edge`, `:corner` (for punching shear coefficients)
- `braced`: Whether column is part of a braced frame (no sway amplification needed)
- `story_properties`: Optional story-level data for sway magnification (populated after analysis)

# Tributary Access
Tributary areas are stored in `BuildingStructure.tributaries` (TributaryCache).
Use accessor functions:
- `column_tributary_area(struc, col)` → total area (m²)
- `column_tributary_by_cell(struc, col)` → Dict{Int, Float64}
- `column_tributary_polygons(struc, col)` → Dict{Int, Vector{NTuple{2,Float64}}}

# Braced vs Sway Frames
- `braced=true` (default): Column is part of a braced frame. Only P-δ (member) effects apply.
- `braced=false`: Column is part of a sway (unbraced) frame. Both P-δ and P-Δ (story) effects apply.

For sway frames:
- Steel: AISC Chapter C requires B1/B2 moment amplification (not yet implemented)
- RC: ACI 318-19 §6.6.4.6 requires δs magnification at ends + δns along length

# Story Properties for Sway Magnification
For sway frame analysis (ACI 318-19 §6.6.4.6), columns need access to story-level 
properties. After structural analysis, call `compute_story_properties!(struc)` to 
populate the `story_properties` field with:
- `ΣPu`: Sum of factored axial loads on all columns in story
- `ΣPc`: Sum of critical buckling loads for all columns
- `Vus`: Factored story shear
- `Δo`: First-order story drift
- `lc`: Story height (center-to-center of joints)
"""
@kwdef mutable struct Column{T} <: AbstractMember{T}
    base::MemberBase{T}
    vertex_idx::Int = 0
    c1::Union{T, Nothing} = nothing
    c2::Union{T, Nothing} = nothing
    story::Int = 0
    position::Symbol = :interior
    # Unit vectors pointing along boundary edges (edges that belong to only one face).
    # Empty for interior columns; 1 direction for edge columns; 2+ for corners.
    # Used for DDM/EFM to determine if column is an exterior support for a given span direction.
    boundary_edge_dirs::Vector{NTuple{2, Float64}} = NTuple{2, Float64}[]
    braced::Bool = true  # Default: braced frame (no sway amplification)
    story_properties::Union{Nothing, @NamedTuple{ΣPu::Float64, ΣPc::Float64, Vus::Float64, Δo::Float64, lc::Float64}} = nothing
    # Cell indices in this column's tributary area (populated by compute_vertex_tributaries!)
    tributary_cell_indices::Set{Int} = Set{Int}()
    # Cell tributary areas in m² (populated by compute_vertex_tributaries!)
    tributary_cell_areas::Dict{Int, Float64} = Dict{Int, Float64}()
end

"""
    Strut{T} <: AbstractMember{T}

Diagonal member (lateral bracing system).

# Fields
- `base::MemberBase{T}`: Shared member properties
- `brace_type::Symbol`: `:tension_only`, `:compression_only`, `:both`
"""
@kwdef mutable struct Strut{T} <: AbstractMember{T}
    base::MemberBase{T}
    brace_type::Symbol = :both
end

# -----------------------------------------------------------------------------
# Convenience constructors
# -----------------------------------------------------------------------------

function Beam(seg_indices::Vector{Int}, L::T; Lb=L, Kx=1.0, Ky=1.0, Cb=1.0, 
              group_id=nothing, role=:beam, tributary_width=nothing) where T
    base = MemberBase{T}(
        segment_indices=seg_indices, L=L, Lb=Lb,
        Kx=Float64(Kx), Ky=Float64(Ky), Cb=Float64(Cb),
        group_id=group_id, section=nothing, volumes=MaterialVolumes()
    )
    Beam{T}(base=base, tributary_width=tributary_width, role=role)
end

Beam(seg_idx::Int, L::T; kwargs...) where T = Beam([seg_idx], L; kwargs...)

function Column(seg_indices::Vector{Int}, L::T; Lb=L, Kx=1.0, Ky=1.0, Cb=1.0,
                group_id=nothing, vertex_idx=0, c1=nothing, c2=nothing,
                story=0, position=:interior, boundary_edge_dirs=NTuple{2, Float64}[],
                braced=true, story_properties=nothing) where T
    base = MemberBase{T}(
        segment_indices=seg_indices, L=L, Lb=Lb,
        Kx=Float64(Kx), Ky=Float64(Ky), Cb=Float64(Cb),
        group_id=group_id, section=nothing, volumes=MaterialVolumes()
    )
    Column{T}(base=base, vertex_idx=vertex_idx, c1=c1, c2=c2,
              story=story, position=position, boundary_edge_dirs=boundary_edge_dirs,
              braced=braced, story_properties=story_properties)
end

Column(seg_idx::Int, L::T; kwargs...) where T = Column([seg_idx], L; kwargs...)

function Strut(seg_indices::Vector{Int}, L::T; Lb=L, Kx=1.0, Ky=1.0, Cb=1.0,
               group_id=nothing, brace_type=:both) where T
    base = MemberBase{T}(
        segment_indices=seg_indices, L=L, Lb=Lb,
        Kx=Float64(Kx), Ky=Float64(Ky), Cb=Float64(Cb),
        group_id=group_id, section=nothing, volumes=MaterialVolumes()
    )
    Strut{T}(base=base, brace_type=brace_type)
end

Strut(seg_idx::Int, L::T; kwargs...) where T = Strut([seg_idx], L; kwargs...)

# -----------------------------------------------------------------------------
# Accessors (delegate to base)
# -----------------------------------------------------------------------------

segment_indices(m::AbstractMember) = m.base.segment_indices
member_length(m::AbstractMember) = m.base.L
unbraced_length(m::AbstractMember) = m.base.Lb
group_id(m::AbstractMember) = m.base.group_id
section(m::AbstractMember) = m.base.section
volumes(m::AbstractMember) = m.base.volumes

# Setters
set_group_id!(m::AbstractMember, gid) = (m.base.group_id = gid)
set_section!(m::AbstractMember, sec) = (m.base.section = sec)
set_volumes!(m::AbstractMember, vols) = (m.base.volumes = vols)

"""Optimization grouping for similar members (pure grouping logic + shared section for ASAP)."""
mutable struct MemberGroup
    hash::UInt64
    member_indices::Vector{Int}
    section::Union{AbstractSection, Nothing}  # Shared section for ASAP element updates
end

MemberGroup(hash::UInt64) = MemberGroup(hash, Int[], nothing)

# =============================================================================
# Supports and Foundations
# =============================================================================

# Re-export from StructuralSizer
const FoundationDemand = StructuralSizer.FoundationDemand
const AbstractFoundationResult = StructuralSizer.AbstractFoundationResult

"""Per-support analysis data (one support node location)."""
mutable struct Support{T, F, M}
    vertex_idx::Int             # Index into skeleton.vertices
    node_idx::Int               # Index into asap_model.nodes  
    forces::NTuple{3, F}        # (Fx, Fy, Fz) reaction forces
    moments::NTuple{3, M}       # (Mx, My, Mz) reaction moments
    foundation_type::Symbol     # :spread, :combined, :pile, etc.
end

function Support(vertex_idx::Int, node_idx::Int; 
                 forces=(0.0u"kN", 0.0u"kN", 0.0u"kN"),
                 moments=(0.0u"kN*m", 0.0u"kN*m", 0.0u"kN*m"),
                 foundation_type=:spread)
    F = typeof(forces[1])
    M = typeof(moments[1])
    Support{typeof(1.0u"m"), F, M}(vertex_idx, node_idx, forces, moments, foundation_type)
end

# Convenience: access reactions as combined tuple
function reactions(s::Support)
    return (s.forces..., s.moments...)
end

"""Physical foundation element (one or more supports share a foundation)."""
mutable struct Foundation{T, R<:AbstractFoundationResult}
    support_indices::Vector{Int}  # Indices into struc.supports
    result::R
    foundation_type::Symbol
    group_id::Union{UInt64, Nothing}
    volumes::MaterialVolumes  # concrete + rebar materials → volumes
end

function Foundation(support_indices::Vector{Int}, result::R; 
                    foundation_type=:spread, group_id=nothing,
                    volumes::MaterialVolumes=MaterialVolumes()) where {R<:AbstractFoundationResult}
    T = typeof(result.B)
    Foundation{T, R}(support_indices, result, foundation_type, group_id, volumes)
end

# Single-support foundation convenience
Foundation(support_idx::Int, result::R; kwargs...) where {R<:AbstractFoundationResult} = 
    Foundation([support_idx], result; kwargs...)

# Convenience accessors for foundation volumes (from result)
concrete_volume(f::Foundation) = StructuralSizer.concrete_volume(f.result)
steel_volume(f::Foundation) = StructuralSizer.steel_volume(f.result)

"""Optimization grouping for similar foundations (pure grouping logic)."""
mutable struct FoundationGroup
    hash::UInt64
    foundation_indices::Vector{Int}
end

FoundationGroup(hash::UInt64) = FoundationGroup(hash, Int[])

# =============================================================================
# Skeleton Lookup (for O(1) vertex/edge/face queries)
# =============================================================================

const COORD_DIGITS = 6  # Rounding precision for coordinate hashing

"""
    SkeletonLookup

Cached lookup indices for O(1) vertex/edge/face queries on a BuildingSkeleton.
Stored in `skel.lookup` and automatically used by `add_vertex!`, `add_element!`, etc.

Enable with `enable_lookup!(skel)` before building, or `build_lookup!(skel)` after.
"""
mutable struct SkeletonLookup
    vertex_index::Dict{NTuple{3, Float64}, Int}
    edge_index::Dict{Tuple{Int, Int}, Int}
    face_index::Dict{Vector{Int}, Int}
    version::Int
end

SkeletonLookup() = SkeletonLookup(
    Dict{NTuple{3, Float64}, Int}(),
    Dict{Tuple{Int, Int}, Int}(),
    Dict{Vector{Int}, Int}(),
    0
)

"""Geometric and topological representation of a building."""
mutable struct BuildingSkeleton{T} <: AbstractBuildingSkeleton
    vertices::Vector{Meshes.Point}
    edges::Vector{Meshes.Segment}
    faces::Vector{Meshes.Polygon}
    edge_indices::Vector{Tuple{Int, Int}}
    face_vertex_indices::Vector{Vector{Int}}
    face_edge_indices::Vector{Vector{Int}}
    graph::Graphs.SimpleGraph{Int}
    groups_vertices::Dict{Symbol, Vector{Int}}
    groups_edges::Dict{Symbol, Vector{Int}}
    groups_faces::Dict{Symbol, Vector{Int}}
    stories::Dict{Int, Story{T}}
    stories_z::Vector{T}
    # O(1) lookup tables (optional, enable with enable_lookup! or build_lookup!)
    lookup::Union{SkeletonLookup, Nothing}

    function BuildingSkeleton{T}() where T
        new{T}(
            Meshes.Point[], Meshes.Segment[], Meshes.Polygon[],
            Tuple{Int, Int}[], Vector{Int}[], Vector{Int}[],
            Graphs.SimpleGraph(0),
            Dict{Symbol, Vector{Int}}(), Dict{Symbol, Vector{Int}}(), Dict{Symbol, Vector{Int}}(),
            Dict{Int, Story{T}}(), T[],
            nothing  # lookup disabled by default
        )
    end
end

"""
Analytical layer wrapping a BuildingSkeleton.

# Architecture
- `skeleton`: Geometric representation (vertices, edges, faces)
- `cells/slabs`: Floor system definitions and sizing
- `segments/beams/columns/struts`: Member definitions
- `supports/foundations`: Boundary conditions and foundations
- `tributaries`: Cached tributary computations (keyed by axis/behavior)
- `asap_model`: Analysis model (ASAP backend)

# Tributary Caching
Tributary computations are stored in `tributaries::TributaryCache`, keyed by
(spanning_behavior, axis_direction). This allows multiple tributary configurations
to coexist without recalculation:
- One-way along X, one-way along Y, two-way isotropic, etc.
- Voronoi (column) tributaries are per-story

# Design Generation
Use `design_building(struc, params)` to generate a `BuildingDesign` from this
structure. Multiple designs can be generated with different parameters.
"""
mutable struct BuildingStructure{T, A, P} <: AbstractBuildingStructure
    skeleton::BuildingSkeleton{T}
    
    # ─── Floor Systems ───
    cells::Vector{Cell{T, A, P}}
    cell_groups::Dict{UInt64, CellGroup}
    slabs::Vector{Slab{T}}
    slab_groups::Dict{UInt64, SlabGroup}
    
    # ─── Framing Members ───
    segments::Vector{Segment{T}}
    beams::Vector{Beam{T}}
    columns::Vector{Column{T}}
    struts::Vector{Strut{T}}
    member_groups::Dict{UInt64, MemberGroup}
    
    # ─── Foundations ───
    supports::Vector{Support{T, typeof(1.0u"kN"), typeof(1.0u"kN*m")}}
    foundations::Vector{Foundation{T, <:AbstractFoundationResult}}
    foundation_groups::Dict{UInt64, FoundationGroup}
    
    # ─── Environment ───
    site::SiteConditions
    
    # ─── Cached Tributaries ───
    tributaries::TributaryCache
    
    # ─── Analysis Backend ───
    asap_model::Asap.Model
    cell_tributary_loads::Dict{Int, Vector{Asap.TributaryLoad}}
end

function BuildingStructure(skel::BuildingSkeleton{T}) where T
    A = typeof(1.0u"m^2")
    P = typeof(1.0u"kN/m^2")
    F = typeof(1.0u"kN")
    M = typeof(1.0u"kN*m")
    BuildingStructure{T, A, P}(
        skel,
        Cell{T, A, P}[], Dict{UInt64, CellGroup}(),
        Slab{T}[], Dict{UInt64, SlabGroup}(),
        Segment{T}[], Beam{T}[], Column{T}[], Strut{T}[], Dict{UInt64, MemberGroup}(),
        Support{T, F, M}[], Foundation{T, AbstractFoundationResult}[], Dict{UInt64, FoundationGroup}(),
        SiteConditions(),
        TributaryCache(),
        Asap.Model(Asap.Node[], Asap.Element[], Asap.AbstractLoad[]),
        Dict{Int, Vector{Asap.TributaryLoad}}()
    )
end

function BuildingStructure{T, A, P}(skel::BuildingSkeleton{T}) where {T, A, P}
    F = typeof(1.0u"kN")
    M = typeof(1.0u"kN*m")
    BuildingStructure{T, A, P}(
        skel,
        Cell{T, A, P}[], Dict{UInt64, CellGroup}(),
        Slab{T}[], Dict{UInt64, SlabGroup}(),
        Segment{T}[], Beam{T}[], Column{T}[], Strut{T}[], Dict{UInt64, MemberGroup}(),
        Support{T, F, M}[], Foundation{T, AbstractFoundationResult}[], Dict{UInt64, FoundationGroup}(),
        SiteConditions(),
        TributaryCache(),
        Asap.Model(Asap.Node[], Asap.Element[], Asap.AbstractLoad[]),
        Dict{Int, Vector{Asap.TributaryLoad}}()
    )
end

"""Iterator over all members (beams, columns, struts)."""
all_members(struc::BuildingStructure) = Iterators.flatten((struc.beams, struc.columns, struc.struts))
