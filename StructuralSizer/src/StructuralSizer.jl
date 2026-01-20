module StructuralSizer

using Logging
using CSV
using StructuralBase
using StructuralUnits  # Shared unit definitions (kip, ksi, psf)
using Unitful
using QuadGK: quadgk
using Roots: find_zero, Brent, Order0

# Register custom units at package load time (not precompile time)
function __init__()
    Unitful.register(StructuralUnits)
end

# Types (Metal, etc.)
include("types.jl")

# Members (materials, sections, codes, optimization)
include("members/_members.jl")

# Slabs (types, codes, optimization)
include("slabs/_slabs.jl")

# === Exports ===

# Types
export Metal, Concrete, ISymmSection

# Demand types
export AbstractDemand, MemberDemand

# Objectives
export AbstractObjective, MinWeight, MinVolume, MinCost, MinCarbon
export objective_value, total_objective

# Optimization
export optimize_member_groups_discrete

# Materials - Steel
export A992_Steel, S355_Steel, Rebar_40, Rebar_60, Rebar_75, Rebar_80
# Materials - Concrete
export NWC_4000, NWC_6000, NWC_GGBS, NWC_PFA

# Section Interface (generic)
export area, depth, width, weight_per_length

# Sections
export W, W_names, all_W, preferred_W
export Rebar, rebar, rebar_sizes, all_rebar
export update!, update, geometry, get_coords

# Capacity Interface (generic)
export get_Mn, get_Vn, get_Pn, get_Tn
export get_ϕMn, get_ϕVn, get_ϕPn, get_ϕTn
export check_interaction

# AISC-specific
export get_slenderness, is_compact
export get_Lp_Lr, get_Fcr_LTB, get_Fcr_flexural, get_Fe, get_Cv1
export check_PM_interaction, check_PMxMy_interaction

# =============================================================================
# Floor System Types
# =============================================================================

# Abstract hierarchy
export AbstractFloorSystem
export AbstractConcreteSlab, AbstractSteelFloor, AbstractTimberFloor

# CIP Concrete types
export OneWay, TwoWay, FlatPlate, FlatSlab, PTBanded, Waffle
export HollowCore, Vault

# Steel floor types
export CompositeDeck, NonCompositeDeck, JoistRoofDeck

# Timber floor types
export CLT, DLT, NLT, MassTimberJoist

# Custom
export ShapedSlab

# Support conditions
export SupportCondition, SIMPLE, ONE_END_CONT, BOTH_ENDS_CONT, CANTILEVER

# Floor sizing options + guidance
export FloorOptions, CIPOptions, VaultOptions
export required_floor_options, floor_options_help

# Type mapping utilities
export floor_type, floor_symbol, infer_floor_type

# =============================================================================
# Floor Result Types
# =============================================================================

export AbstractFloorResult
export CIPSlabResult, ProfileResult
export CompositeDeckResult, JoistDeckResult
export TimberPanelResult, TimberJoistResult
export VaultResult, ShapedSlabResult
export total_thrust

# Common interface
export self_weight, total_depth, volume_per_area
export has_structural_effects, apply_effects!
export required_materials
export load_distribution, get_gravity_loads, LoadDistributionType
export DISTRIBUTION_ONE_WAY, DISTRIBUTION_TWO_WAY, DISTRIBUTION_POINT, DISTRIBUTION_CUSTOM

# Material volumes interface
export materials, material_volumes

# =============================================================================
# Floor Sizing Interface
# =============================================================================

export size_floor

# =============================================================================
# Vault Analysis (advanced)
# =============================================================================

export vault_stress_symmetric, vault_stress_asymmetric
export solve_equilibrium_rise
export parabolic_arc_length, vault_volume_per_area

# =============================================================================
# SlabGroup Geometry Extraction
# =============================================================================

# Point types
export Point2D, Point3D

# Geometry types
export CellGeometry, SlabGeometry, SlabGroupGeometry

# Extraction functions
export extract_cell_geometry, extract_slab_geometry, extract_slabgroup_geometry

# Accessors
export get_vertices, get_all_vertices, get_cell_polygons
export total_area, cell_count, slab_count

# =============================================================================
# Tributary Area (Straight Skeleton)
# =============================================================================

export TributaryResult
export get_tributary_polygons_isotropic
export get_tributary_polygons_isotropic_dcel

# DCEL types (for advanced users)
export DCEL, DCELVertex, HalfEdge, DCELFace
export validate_dcel, extract_face_polygon, extract_face_polygon_by_edges
export diagnose_vertex, insert_artificial_bisectors!

end # module
