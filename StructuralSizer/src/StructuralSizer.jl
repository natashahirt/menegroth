module StructuralSizer

using Logging
using CSV
using StructuralBase
using StructuralBase: StructuralUnits  # Shared unit definitions (kip, ksi, psf)
using Unitful
using QuadGK: quadgk
using Roots: find_zero, Brent, Order0

# Register custom units at package load time (not precompile time)
function __init__()
    Unitful.register(StructuralUnits)
end

# Types (Metal, etc.)
include("types.jl")

# Materials
include("materials/_materials.jl")

# Members (sections, codes, optimization)
include("members/_members.jl")

# Slabs (types, codes, optimization)
include("slabs/_slabs.jl")

# Foundations (types, soils, design codes)
include("foundations/_foundations.jl")

# === Exports ===

# Types
export Metal, StructuralSteel, RebarSteel, Concrete, ISymmSection

# Demand types
export AbstractDemand, MemberDemand

# Objectives
export AbstractObjective, MinWeight, MinVolume, MinCost, MinCarbon
export objective_value, total_objective

# =============================================================================
# Capacity Checker Interface
# =============================================================================
export AbstractCapacityChecker, AbstractCapacityCache, AbstractMemberGeometry
export create_cache, is_feasible, precompute_capacities!, get_objective_coeff

# Geometry types (material-specific)
export SteelMemberGeometry, TimberMemberGeometry, ConcreteMemberGeometry

# Checkers
export AISCChecker, AISCCapacityCache  # Steel (implemented)
export NDSChecker, Timber              # Timber (stub)
export ACIChecker                      # Concrete (stub)

# Optimization
export optimize_discrete

# Materials - Steel
export A992_Steel, S355_Steel, Rebar_40, Rebar_60, Rebar_75, Rebar_80
# Materials - Concrete
export NWC_4000, NWC_6000, NWC_GGBS, NWC_PFA

# Section Interface (generic)
export area, depth, width, weight_per_length

# =============================================================================
# Sections - Steel
# =============================================================================
export W, W_names, all_W, preferred_W
export Rebar, rebar, rebar_sizes, all_rebar
export update!, update, geometry, get_coords
export HSSSection  # (stub)

# =============================================================================
# Sections - Timber (stubs)
# =============================================================================
export GlulamSection
export STANDARD_GLULAM_WIDTHS, GLULAM_LAM_THICKNESS

# =============================================================================
# Sections - Concrete (stubs)
# =============================================================================
export RCBeamSection, rho

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
export FloorOptions, CIPOptions, VaultOptions, CompositeDeckOptions, TimberOptions
export required_floor_options, floor_options_help
export result_materials

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
export has_structural_effects, apply_effects!, structural_effects
export required_materials
export load_distribution, get_gravity_loads, LoadDistributionType
export DISTRIBUTION_ONE_WAY, DISTRIBUTION_TWO_WAY, DISTRIBUTION_POINT, DISTRIBUTION_CUSTOM
export default_tributary_axis, resolve_tributary_axis

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
# Tributary Area (Straight Skeleton)
# =============================================================================

export TributaryPolygon
export vertices  # for converting parametric → absolute coords
export get_tributary_polygons
export get_tributary_polygons_isotropic

# Span calculations
export SpanInfo, governing_spans
export short_span, long_span, two_way_span
export get_polygon_span

# =============================================================================
# Foundation Types
# =============================================================================

# Abstract hierarchy
export AbstractFoundation
export AbstractShallowFoundation, AbstractDeepFoundation

# Shallow foundation types
export SpreadFooting, CombinedFooting, StripFooting, MatFoundation

# Deep foundation types
export DrivenPile, DrilledShaft, Micropile

# Soil properties
export Soil
export LOOSE_SAND, MEDIUM_SAND, DENSE_SAND
export SOFT_CLAY, STIFF_CLAY, HARD_CLAY

# Foundation result types
export AbstractFoundationResult
export SpreadFootingResult, CombinedFootingResult, PileCapResult

# Foundation demand
export FoundationDemand

# Type mapping
export foundation_type, foundation_symbol

# Common interface
export concrete_volume, steel_volume, footprint_area, utilization

# Design functions
export design_spread_footing, check_spread_footing

end # module
