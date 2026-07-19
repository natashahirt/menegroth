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

# Include order matters: types before types that depend on them
include("building_types/tributary_cache.jl")
# Framing hierarchy types (Phase 4): defines FramingLevel{T} + joist patterns,
# referenced by Slab{T}.framing_levels — must precede cells.jl.
include("building_types/framing.jl")
include("building_types/cells.jl")
include("building_types/members.jl")
include("building_types/foundations.jl")
include("building_types/snapshot.jl")
include("building_types/skeleton.jl")
include("building_types/structure.jl")
# Framing hierarchy public API (attach_framing_level!): needs BuildingStructure
# + Slab, so it loads after structure.jl.
include("building_types/framing_api.jl")
