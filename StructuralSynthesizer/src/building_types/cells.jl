# =============================================================================
# Site Conditions, Story, Cell, Slab, Segment
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
Edge tributaries are stored in `BuildingStructure._tributary_caches` (TributaryCache).
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

"""Total factored pressure with a specific load combination."""
total_factored_pressure(c::Cell, combo::LoadCombination) =
    factored_pressure(combo, c.sdl + c.self_weight, c.live_load)

"""Total factored pressure — envelope across a vector of combinations."""
total_factored_pressure(c::Cell, combos::AbstractVector{LoadCombination}) =
    envelope_pressure(combos, c.sdl + c.self_weight, c.live_load)

"""Total factored pressure (default strength: 1.2D + 1.6L)."""
total_factored_pressure(c::Cell) =
    factored_pressure(default_combo, c.sdl + c.self_weight, c.live_load)

# Volume type alias
const VolumeType = typeof(1.0u"m^3")
const MaterialVolumes = Dict{AbstractMaterial, VolumeType}

"""
    Slab{T}

Physical slab (one or more connected cells).

Note: `result` uses `AbstractFloorResult` (not parameterized) to allow 
reassignment during sizing (e.g., CIPSlabResult → FlatPlatePanelResult).

# Fields
- `cell_indices`: Vector of cell face indices in this slab
- `result`: Design result (any `AbstractFloorResult` subtype)
- `floor_type`: Slab system (`:flat_plate`, `:flat_slab`, `:one_way`, etc.)
- `spans`: Governing span info across all child cells
- `position`: `:corner`, `:edge`, or `:interior`
- `group_id`: Hash for grouping geometrically identical slabs
- `volumes`: Material → volume mapping (m³)
- `drop_panel`: `DropPanelGeometry` for flat slabs, `nothing` otherwise.
  Set by `_size_slab!(::FlatSlab, ...)` after the design pipeline returns.
"""
mutable struct Slab{T}
    cell_indices::Vector{Int}
    result::AbstractFloorResult  # Allow any floor result type (CIP, FlatPlate, Vault, etc.)
    floor_type::Symbol        # :one_way, :two_way, :pt_banded, :flat_plate, :flat_slab
    spans::SpanInfo{T}        # Governing spans across all child cells
    position::Symbol          # :corner, :edge, or :interior (derived from cells)
    group_id::Union{UInt64, Nothing}
    volumes::MaterialVolumes  # material → total volume (m³)
    drop_panel::Union{Nothing, StructuralSizer.DropPanelGeometry}  # Drop panel geometry (flat_slab only)
    # Full design output from size_flat_plate! (column P-M results, integrity check,
    # transfer reinforcement, ρ_prime).  Stored so downstream consumers (capture_design,
    # study scripts) don't lose the rich detail that slab.result alone can't carry.
    design_details::Union{Nothing, NamedTuple}  # NamedTuple from size_flat_plate!, or nothing
end

function Slab(cell_indices::Vector{Int}, result::AbstractFloorResult, spans::SpanInfo; 
              floor_type=:one_way, position::Symbol=:interior, group_id=nothing,
              volumes::MaterialVolumes=MaterialVolumes(),
              drop_panel=nothing, design_details=nothing)
    T = typeof(StructuralSizer.total_depth(result))
    spans_T = SpanInfo{T}(T(spans.primary), T(spans.secondary), spans.axis, T(spans.isotropic))
    Slab{T}(cell_indices, result, floor_type, spans_T, position, group_id, volumes, drop_panel, design_details)
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
