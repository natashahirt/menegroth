# =============================================================================
# BuildingStructure
# =============================================================================

"""
Analytical layer wrapping a BuildingSkeleton.

# Architecture
- `skeleton`: Geometric representation (vertices, edges, faces)
- `cells/slabs`: Floor system definitions and sizing
- `segments/beams/columns/struts`: Member definitions
- `supports/foundations`: Boundary conditions and foundations
- `asap_model`: Analysis model (ASAP backend)

# Geometry-Dependent Caches
All caches that depend on skeleton geometry live here and are cleared together
by `clear_geometry_caches!(struc)` when the skeleton changes.

- `_tributary_caches`: Edge/vertex tributary computations (keyed by axis/behavior)
- `_analysis_caches`: Per-slab, per-method analysis model caches (FEA mesh,
  EFM frame, etc.).  Lazily populated: `Dict{Int, Dict{Symbol, Any}}` where
  outer key = slab index, inner key = method (`:fea`, `:efm`).

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
    slab_parallel_batches::Vector{Vector{Int}}  # coloring for concurrent sizing
    
    # ─── Framing Members ───
    segments::Vector{Segment{T}}
    beams::Vector{Beam{T}}
    columns::Vector{Column{T}}
    struts::Vector{Strut{T}}
    member_groups::Dict{UInt64, MemberGroup}
    
    # ─── Foundations ───
    supports::Vector{Support{T, typeof(1.0u"kN"), typeof(1.0u"kN*m"), typeof(1.0u"inch")}}
    foundations::Vector{Foundation{T, <:AbstractFoundationResult}}
    foundation_groups::Dict{UInt64, FoundationGroup}
    
    # ─── Environment ───
    site::SiteConditions
    
    # ─── Geometry-Dependent Caches ───
    _tributary_caches::TributaryCache
    _analysis_caches::Dict{Int, Dict{Symbol, Any}}
    
    # ─── Analysis Backend ───
    asap_model::Asap.Model
    cell_tributary_loads::Dict{Int, Vector{Asap.TributaryLoad}}
    cell_dead_loads::Dict{Int, Vector{Asap.TributaryLoad}}   # Pattern loading: dead-only
    cell_live_loads::Dict{Int, Vector{Asap.TributaryLoad}}   # Pattern loading: live-only
    
    # ─── Design Snapshot (for parametric studies) ───
    _snapshot::Union{Nothing, DesignSnapshot{T, P}}
end

function BuildingStructure(skel::BuildingSkeleton{T}) where T
    A = typeof(1.0u"m^2")
    P = typeof(1.0u"kN/m^2")
    F = typeof(1.0u"kN")
    M = typeof(1.0u"kN*m")
    Lc = typeof(1.0u"inch")
    BuildingStructure{T, A, P}(
        skel,
        Cell{T, A, P}[], Dict{UInt64, CellGroup}(),
        Slab{T}[], Dict{UInt64, SlabGroup}(), Vector{Int}[],
        Segment{T}[], Beam{T}[], Column{T}[], Strut{T}[], Dict{UInt64, MemberGroup}(),
        Support{T, F, M, Lc}[], Foundation{T, AbstractFoundationResult}[], Dict{UInt64, FoundationGroup}(),
        SiteConditions(),
        TributaryCache(),
        Dict{Int, Dict{Symbol, Any}}(),
        Asap.Model(Asap.Node[], Asap.Element[], Asap.AbstractLoad[]),
        Dict{Int, Vector{Asap.TributaryLoad}}(),
        Dict{Int, Vector{Asap.TributaryLoad}}(),
        Dict{Int, Vector{Asap.TributaryLoad}}(),
        nothing,  # _snapshot
    )
end

function BuildingStructure{T, A, P}(skel::BuildingSkeleton{T}) where {T, A, P}
    F = typeof(1.0u"kN")
    M = typeof(1.0u"kN*m")
    Lc = typeof(1.0u"inch")
    BuildingStructure{T, A, P}(
        skel,
        Cell{T, A, P}[], Dict{UInt64, CellGroup}(),
        Slab{T}[], Dict{UInt64, SlabGroup}(), Vector{Int}[],
        Segment{T}[], Beam{T}[], Column{T}[], Strut{T}[], Dict{UInt64, MemberGroup}(),
        Support{T, F, M, Lc}[], Foundation{T, AbstractFoundationResult}[], Dict{UInt64, FoundationGroup}(),
        SiteConditions(),
        TributaryCache(),
        Dict{Int, Dict{Symbol, Any}}(),
        Asap.Model(Asap.Node[], Asap.Element[], Asap.AbstractLoad[]),
        Dict{Int, Vector{Asap.TributaryLoad}}(),
        Dict{Int, Vector{Asap.TributaryLoad}}(),
        Dict{Int, Vector{Asap.TributaryLoad}}(),
        nothing,  # _snapshot
    )
end

"""Iterator over all members (beams, columns, struts)."""
all_members(struc::BuildingStructure) = Iterators.flatten((struc.beams, struc.columns, struc.struts))
