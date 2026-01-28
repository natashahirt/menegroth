# Core types for StructuralSynthesizer
#
# =============================================================================
# Data Hierarchy
# =============================================================================
#
# BuildingStructure
# ├── site::SiteConditions              # Site-level (soil, wind, seismic, snow)
# ├── skeleton::BuildingSkeleton        # Geometry (vertices, edges, faces)
# │
# ├── cells[]                           # Per-face load data
# ├── slabs[]
# │   ├── result::AbstractFloorResult   # Sizing result (thickness, etc.)
# │   └── volumes: {Material → Volume}  # For EC calculation
# │
# ├── segments[]                        # Per-edge geometry data
# ├── beams[]::Beam                     # Horizontal members (gravity framing)
# │   ├── base::MemberBase              # Shared: L, Lb, section, volumes
# │   ├── role::Symbol                  # :girder, :beam, :joist, :infill
# │   └── tributary_width
# ├── columns[]::Column                 # Vertical members
# │   ├── base::MemberBase
# │   ├── vertex_idx, story, position   # :interior, :edge, :corner
# │   └── c1, c2, tributary_area        # For punching shear / sizing
# ├── struts[]::Strut                   # Diagonal members (lateral)
# │   ├── base::MemberBase
# │   └── brace_type                    # :tension_only, :compression_only, :both
# │
# ├── supports[]                        # Per-node reactions
# ├── foundations[]
# │   ├── result::AbstractFoundationResult
# │   └── volumes: {Material → Volume}
# │
# └── *_groups                          # Pure grouping logic (hash + indices)
#
# EC Calculation: Σ(volume × ρ × ecc) for each material in element.volumes
# =============================================================================

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

# Re-export from StructuralSizer
const TributaryPolygon = StructuralSizer.TributaryPolygon
const SpanInfo = StructuralSizer.SpanInfo
const vertices = StructuralSizer.vertices

"""Grouping of geometrically identical cells (for slab sizing optimization)."""
mutable struct CellGroup
    hash::UInt64
    cell_indices::Vector{Int}
end

CellGroup(hash::UInt64) = CellGroup(hash, Int[])

# =============================================================================
# Cell
# =============================================================================

"""Per-face analysis data (one bay)."""
mutable struct Cell{T, A, P}
    face_idx::Int
    area::A
    spans::SpanInfo{T}
    sdl::P
    live_load::P
    self_weight::P
    floor_type::Symbol
    position::Symbol          # :corner, :edge, or :interior
    # Tributary results (one polygon per edge)
    tributary::Union{Vector{TributaryPolygon}, Nothing}
end

function Cell(face_idx::Int, area::A, spans::SpanInfo{T}, 
              sdl::P, live_load::P; position::Symbol=:interior) where {T, A, P}
    Cell{T, A, P}(face_idx, area, spans, sdl, live_load, zero(P), :unknown, position, nothing)
end

"""Total factored pressure (SDL + LL + SW)."""
total_factored_pressure(c::Cell) = (c.sdl + c.self_weight) * Constants.DL_FACTOR + c.live_load * Constants.LL_FACTOR

# Volume type alias
const VolumeType = typeof(1.0u"m^3")
const MaterialVolumes = Dict{AbstractMaterial, VolumeType}

"""Physical slab (one or more connected cells)."""
mutable struct Slab{T, R<:AbstractFloorResult}
    cell_indices::Vector{Int}
    result::R
    floor_type::Symbol        # :one_way, :two_way, :pt_banded, :flat_plate
    spans::SpanInfo{T}        # Governing spans across all child cells
    position::Symbol          # :corner, :edge, or :interior (derived from cells)
    group_id::Union{UInt64, Nothing}
    volumes::MaterialVolumes  # material → total volume (m³)
end

function Slab(cell_indices::Vector{Int}, result::R, spans::SpanInfo; 
              floor_type=:one_way, position::Symbol=:interior, group_id=nothing,
              volumes::MaterialVolumes=MaterialVolumes()) where {R<:AbstractFloorResult}
    T = typeof(StructuralSizer.total_depth(result))
    spans_T = SpanInfo{T}(T(spans.primary), T(spans.secondary), spans.axis, T(spans.isotropic))
    Slab{T, R}(cell_indices, result, floor_type, spans_T, position, group_id, volumes)
end

# Single-cell slab convenience
Slab(cell_idx::Int, result::R, spans::SpanInfo; kwargs...) where {R<:AbstractFloorResult} = 
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
- `tributary_area::Union{Float64, Nothing}`: Total Voronoi tributary area (m²)
- `tributary_by_slab::Dict{Int, Float64}`: Per-cell area breakdown (cell_idx → area in m²)
- `tributary_polygons::Dict{Int, Vector{NTuple{2,Float64}}}`: Per-cell polygon vertices for visualization
- `story::Int`: Story index (0 = ground level)
- `position::Symbol`: `:interior`, `:edge`, `:corner` (for punching shear coefficients)
"""
@kwdef mutable struct Column{T} <: AbstractMember{T}
    base::MemberBase{T}
    vertex_idx::Int = 0
    c1::Union{T, Nothing} = nothing
    c2::Union{T, Nothing} = nothing
    tributary_area::Union{Float64, Nothing} = nothing  # Total tributary area (m²)
    tributary_by_slab::Dict{Int, Float64} = Dict{Int, Float64}()  # cell_idx → area (m²)
    tributary_polygons::Dict{Int, Vector{NTuple{2,Float64}}} = Dict{Int, Vector{NTuple{2,Float64}}}()  # cell_idx → polygon vertices (m)
    story::Int = 0
    position::Symbol = :interior
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
                tributary_area=nothing, tributary_by_slab=Dict{Int,Float64}(),
                tributary_polygons=Dict{Int,Vector{NTuple{2,Float64}}}(),
                story=0, position=:interior) where T
    base = MemberBase{T}(
        segment_indices=seg_indices, L=L, Lb=Lb,
        Kx=Float64(Kx), Ky=Float64(Ky), Cb=Float64(Cb),
        group_id=group_id, section=nothing, volumes=MaterialVolumes()
    )
    Column{T}(base=base, vertex_idx=vertex_idx, c1=c1, c2=c2,
              tributary_area=tributary_area, tributary_by_slab=tributary_by_slab,
              tributary_polygons=tributary_polygons, story=story, position=position)
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

"""Analytical layer wrapping a BuildingSkeleton."""
mutable struct BuildingStructure{T, A, P} <: AbstractBuildingStructure
    skeleton::BuildingSkeleton{T}
    # Slabs
    cells::Vector{Cell{T, A, P}}
    cell_groups::Dict{UInt64, CellGroup}
    slabs::Vector{Slab{T, <:AbstractFloorResult}}
    slab_groups::Dict{UInt64, SlabGroup}
    # Framing (segments + typed members)
    segments::Vector{Segment{T}}
    beams::Vector{Beam{T}}
    columns::Vector{Column{T}}
    struts::Vector{Strut{T}}
    member_groups::Dict{UInt64, MemberGroup}  # Groups can span beam/column/strut
    # Foundations
    supports::Vector{Support{T, typeof(1.0u"kN"), typeof(1.0u"kN*m")}}
    foundations::Vector{Foundation{T, <:AbstractFoundationResult}}
    foundation_groups::Dict{UInt64, FoundationGroup}
    # Site conditions
    site::SiteConditions
    # Analysis
    asap_model::Asap.Model
    cell_tributary_loads::Dict{Int, Vector{Asap.TributaryLoad}}  # cell_idx → loads for updates
end

function BuildingStructure(skel::BuildingSkeleton{T}) where T
    A = typeof(1.0u"m^2")
    P = typeof(1.0u"kN/m^2")
    F = typeof(1.0u"kN")
    M = typeof(1.0u"kN*m")
    BuildingStructure{T, A, P}(
        skel,
        Cell{T, A, P}[], Dict{UInt64, CellGroup}(),
        Slab{T, AbstractFloorResult}[], Dict{UInt64, SlabGroup}(),
        Segment{T}[], Beam{T}[], Column{T}[], Strut{T}[], Dict{UInt64, MemberGroup}(),
        Support{T, F, M}[], Foundation{T, AbstractFoundationResult}[], Dict{UInt64, FoundationGroup}(),
        SiteConditions(),
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
        Slab{T, AbstractFloorResult}[], Dict{UInt64, SlabGroup}(),
        Segment{T}[], Beam{T}[], Column{T}[], Strut{T}[], Dict{UInt64, MemberGroup}(),
        Support{T, F, M}[], Foundation{T, AbstractFoundationResult}[], Dict{UInt64, FoundationGroup}(),
        SiteConditions(),
        Asap.Model(Asap.Node[], Asap.Element[], Asap.AbstractLoad[]),
        Dict{Int, Vector{Asap.TributaryLoad}}()
    )
end

"""Iterator over all members (beams, columns, struts)."""
all_members(struc::BuildingStructure) = Iterators.flatten((struc.beams, struc.columns, struc.struts))
