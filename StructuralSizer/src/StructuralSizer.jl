module StructuralSizer

using Logging
using CSV
using Reexport
using Unitful
using QuadGK: quadgk
using Roots: find_zero, Brent, Order0
import Meshes  # For geometry operations in EFM

# =============================================================================
# Asap (units + FEM)
# =============================================================================
# Asap is the canonical source for units and type aliases.
# Import everything we need and re-export for downstream packages.

using Asap

# Re-export units for downstream packages
@reexport using Asap: kip, ksi, psf, ksf, pcf
@reexport using Asap: GRAVITY, STANDARD_GRAVITY

# Re-export type aliases (dimension-based, for function signatures)
@reexport using Asap: Length, Area, Volume
@reexport using Asap: SecondMomentOfArea, TorsionalConstant, MomentOfInertia, WarpingConstant
@reexport using Asap: Pressure, Force, Moment, Torque
@reexport using Asap: LinearLoad, AreaLoad, Density, Acceleration

# Re-export concrete type aliases (for struct fields)
@reexport using Asap: LengthQuantity, AreaQuantity, VolumeQuantity
@reexport using Asap: PressureQuantity, ForceQuantity, MomentQuantity, ForcePerLength

# Re-export conversion helpers
@reexport using Asap: to_inches, to_sqinches, to_ksi, to_kip, to_kipft
@reexport using Asap: to_meters, to_pascals, to_newtons, to_newton_meters, to_newtons_per_meter
@reexport using Asap: asfloat, maybe_asfloat

# Register custom units at package load time (not precompile time)
function __init__()
    Unitful.register(Asap)
end

# =============================================================================
# Local Modules
# =============================================================================

# Abstract types (AbstractMaterial, AbstractSection, etc.)
include("types.jl")

# Constants (ECC coefficients, load factors, standard loads)
include("Constants.jl")

# Materials (includes material types: Metal, Concrete, Timber)
include("materials/_materials.jl")

# Optimization infrastructure (shared abstractions + solvers)
include("optimize/_optimize.jl")

# Members (sections, codes, member-specific optimization)
include("members/_members.jl")

# Slabs (types, codes, optimization)
include("slabs/_slabs.jl")

# Foundations (types, soils, design codes)
include("foundations/_foundations.jl")

# Visualization interface (traits for section geometry - no GLMakie dependency)
include("visualization/_visualization.jl")

# === Exports ===

# Abstract types (from types.jl)
export AbstractMaterial, AbstractDesignCode, AbstractSection
export AbstractStructuralSynthesizer, AbstractBuildingSkeleton, AbstractBuildingStructure

# Constants module
export Constants

# Material types
export Metal, StructuralSteel, RebarSteel, Concrete, ReinforcedConcreteMaterial, ISymmSection

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
export ACIChecker                      # Concrete beam (stub)
export ACIColumnChecker, ACIColumnCapacityCache  # Concrete column (implemented)

# Optimization - Discrete (MIP)
export optimize_discrete
export size_columns
export to_steel_demands, to_rc_demands
export to_steel_geometry, to_concrete_geometry, convert_geometries

# Optimization - Continuous (NLP)
export AbstractNLPProblem
export n_variables, variable_bounds, initial_guess, evaluate
export objective_fn, constraint_fns, constraint_bounds, n_constraints
export variable_names, constraint_names, problem_summary
export optimize_continuous
export VaultNLPProblem, optimize_vault
export RCColumnNLPProblem, RCColumnNLPResult, build_nlp_result  # RC column NLP
export size_column_nlp, size_columns_nlp                         # RC column NLP API
export HSSColumnNLPProblem, HSSColumnNLPResult, build_hss_nlp_result  # HSS column NLP
export size_hss_nlp, size_hss_columns_nlp                             # HSS column NLP API
export WColumnNLPProblem, WColumnNLPResult, build_w_nlp_result        # W section NLP
export size_w_nlp, size_w_columns_nlp                                 # W section NLP API

# Sizing options (clean API)
export SteelColumnOptions, ConcreteColumnOptions, SteelBeamOptions
export NLPColumnOptions, NLPHSSOptions, NLPWOptions  # Continuous optimization options
export ColumnOptions  # Union type for dispatch
export steel_column_catalog, rc_column_catalog

# Material display
export material_name

# Materials - Steel
export A992_Steel, S355_Steel, Rebar_40, Rebar_60, Rebar_75, Rebar_80, Stud_51
# Materials - Concrete
export NWC_3000, NWC_4000, NWC_5000, NWC_6000, NWC_GGBS, NWC_PFA
export RC_3000_60, RC_4000_60, RC_5000_60, RC_6000_60, RC_5000_75, RC_6000_75, RC_GGBS_60
export Earthen_500, Earthen_1000, Earthen_2000, Earthen_4000, Earthen_8000
export concrete_fc, concrete_fc_mpa, concrete_E, concrete_wc

# Section Interface (generic)
export section_area, section_depth, section_width, weight_per_length

# =============================================================================
# Sections - Steel
# =============================================================================
export W, W_names, all_W, preferred_W
export Rebar, rebar, rebar_sizes, all_rebar
export update!, update, geometry, get_coords

# HSS sections (rectangular and round)
export AbstractHollowSection, AbstractRectHollowSection, AbstractRoundHollowSection
export HSSRectSection, is_square, governing_slenderness
export HSSRoundSection, PipeSection, slenderness  # PipeSection is alias for HSSRoundSection
export HSS, HSS_names, all_HSS
export HSSRound, HSSRound_names, all_HSSRound
export PIPE, PIPE_names, all_PIPE  # Aliases for HSSRound

# =============================================================================
# Sections - Timber (stubs)
# =============================================================================
export GlulamSection
export STANDARD_GLULAM_WIDTHS, GLULAM_LAM_THICKNESS

# =============================================================================
# Sections - Concrete
# =============================================================================
export RCBeamSection, rho
export RCColumnSection, RebarLocation, scale_column_section
export RCCircularSection, circular_compression_zone
export RCColumnDemand
# RC column catalog functions
export standard_rc_columns, standard_rc_circular_columns
export square_rc_columns, rectangular_rc_columns, low_capacity_rc_columns, high_capacity_rc_columns, all_rc_rect_columns
export standard_circular_columns, low_capacity_circular_columns, high_capacity_circular_columns, all_rc_circular_columns
export standard_rc_circular_columns, common_rc_circular_columns, all_rc_circular_columns
export effective_depth, compression_steel_depth, moment_of_inertia, radius_of_gyration, n_bars
export extreme_tension_depth, get_bar_depths, bar_depth_from_compression

# Asap conversion
export to_asap_section

# Capacity Interface (generic)
export get_Mn, get_Vn, get_Pn, get_Tn
export get_ϕMn, get_ϕVn, get_ϕPn, get_ϕTn
export check_interaction

# AISC-specific
export get_slenderness, is_compact
export get_Lp_Lr, get_Fcr_LTB, get_Fcr_flexural, get_Fe, get_Cv1
export check_PM_interaction, check_PMxMy_interaction
# AISC Appendix 8 - Moment Amplification (B1/B2)
export compute_Cm, compute_Pe1, compute_B1
export compute_RM, compute_Pe_story, compute_B2
export amplify_moments, amplify_axial
# AISC Chapter H3 - Torsion for HSS
export torsional_constant_rect_hss, torsional_constant_round_hss
export get_Fcr_torsion
export check_combined_torsion_interaction, can_neglect_torsion

# ACI Material Utilities
export beta1, Ec, Ec_ksi, fr, fc_ksi, fy_ksi, Es_ksi, εcu
export to_material_tuple

# ACI Column P-M Interaction
export ControlPointType, PURE_COMPRESSION, MAX_COMPRESSION, FS_ZERO, FS_HALF_FY
export BALANCED, TENSION_CONTROLLED, PURE_BENDING, PURE_TENSION, INTERMEDIATE
export calculate_PM_at_c, c_from_εt
export pure_compression_capacity, max_compression_capacity
export phi_factor, calculate_phi_PM_at_c
export PMDiagramPoint, PMInteractionDiagram, PMDiagramRect, PMDiagramCircular
export generate_PM_diagram, get_nominal_curve, get_factored_curve
export get_control_points, get_control_point
export check_PM_capacity, capacity_at_axial, capacity_at_moment, utilization_ratio
# Y-axis P-M diagram (rectangular biaxial support)
export calculate_PM_at_c_yaxis, calculate_phi_PM_at_c_yaxis
export generate_PM_diagram_yaxis, generate_PM_diagrams_biaxial
export effective_depth_yaxis
# Column reinforcement design for fixed dimensions
export design_column_reinforcement, resize_column_with_reinforcement
# Slenderness
export slenderness_ratio, should_consider_slenderness
export effective_stiffness, critical_buckling_load
export magnification_factor_nonsway, calc_Cm, minimum_moment
export magnify_moment_nonsway, magnification_factor_sway, magnify_moment_sway
export concrete_modulus
# Sway frame magnification (complete procedure)
export SwayStoryProperties, stability_index, is_sway_frame
export B2StoryProperties  # AISC B2 moment amplification
export magnification_factor_sway_Q
export effective_stiffness_sway, critical_buckling_load_sway
export magnify_moment_sway_complete
# Biaxial bending
export bresler_reciprocal_load, check_bresler_reciprocal
export bresler_load_contour, pca_load_contour
export check_biaxial_capacity, check_biaxial_simple
export check_biaxial_rectangular, check_biaxial_auto

# Options helpers
export get_rebar_fy, get_transverse_rebar, get_transverse_bar_diameter

# =============================================================================
# Floor System Types
# =============================================================================

# Abstract hierarchy
export AbstractFloorSystem
export AbstractConcreteSlab, AbstractSteelFloor, AbstractTimberFloor

# CIP Concrete types
export OneWay, TwoWay, FlatPlate, FlatSlab, PTBanded, Waffle
export HollowCore, Vault
export floor_system  # Symbol → Type converter

# Steel floor types
export CompositeDeck, NonCompositeDeck, JoistRoofDeck

# Timber floor types
export CLT, DLT, NLT, MassTimberJoist

# Custom
export ShapedSlab

# Spanning behavior traits
export SpanningBehavior, OneWaySpanning, TwoWaySpanning, BeamlessSpanning
export spanning_behavior, is_one_way, is_two_way, is_beamless, requires_column_tributaries

# Support conditions
export SupportCondition, SIMPLE, ONE_END_CONT, BOTH_ENDS_CONT, CANTILEVER

# Floor sizing options + guidance
export FloorOptions, FlatPlateOptions, OneWayOptions, VaultOptions, CompositeDeckOptions, TimberOptions
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
export total_thrust, is_adequate

# Flat plate design results
export StripReinforcement, FlatPlatePanelResult, ShearStudDesign, PunchingCheckResult
export deflection_ok, punching_ok, max_punching_ratio, deflection_ratio

# Flat plate calculations (ACI 318)
export Ec, β1, fr
export min_thickness_flat_plate, clear_span
export total_static_moment, distribute_moments_mddm, distribute_moments_aci
export required_reinforcement, minimum_reinforcement, effective_depth, max_bar_spacing
export punching_perimeter, punching_capacity_interior, punching_demand, check_punching_shear
export cracked_moment_of_inertia, effective_moment_of_inertia, cracking_moment
export immediate_deflection, long_term_deflection_factor, deflection_limit
export MDDM_COEFFICIENTS, ACI_DDM_LONGITUDINAL
export estimate_column_size, estimate_column_size_from_span
export face_of_support_moment

# EFM section properties and stiffnesses (ACI 318 Section 8.11)
export slab_moment_of_inertia, column_moment_of_inertia, torsional_constant_C
export slab_beam_stiffness_Ksb, column_stiffness_Kc, torsional_member_stiffness_Kt
export equivalent_column_stiffness_Kec, distribution_factor_DF, carryover_factor_COF
export fixed_end_moment_FEM

# Slab sizing dispatcher (routes to appropriate sizing function by floor type)
export size_slabs!
export size_slab!

# Flat plate design pipeline (internal; do not export)

# Common interface
export self_weight, total_depth, volume_per_area
export has_structural_effects, apply_effects!
export required_materials
export load_distribution, get_gravity_loads, LoadDistributionType
export DISTRIBUTION_ONE_WAY, DISTRIBUTION_TWO_WAY, DISTRIBUTION_POINT, DISTRIBUTION_CUSTOM
export default_tributary_axis, resolve_tributary_axis

# Material volumes interface
export materials, material_volumes

# (Removed) Floor span-based sizing interface (`size_floor`) — use `size_slab!`/`size_slabs!`.

# =============================================================================
# Vault Analysis (advanced)
# =============================================================================

# Analysis methods (dispatch types)
export VaultAnalysisMethod, HaileAnalytical, ShellFEA

# Core analysis functions
export vault_stress_symmetric, vault_stress_asymmetric
export solve_equilibrium_rise
export parabolic_arc_length, vault_volume_per_area, get_vault_properties

# =============================================================================
# Tributary Area - Re-exported from Asap
# =============================================================================
# Generic tributary computation has moved to Asap. Re-export for convenience.

using Asap: TributaryPolygon, TributaryBuffers, VertexTributary, SpanInfo
using Asap: get_tributary_polygons, get_tributary_polygons_isotropic, get_tributary_polygons_one_way
using Asap: compute_voronoi_tributaries
using Asap: get_polygon_span, governing_spans, short_span, long_span, two_way_span
using Asap: vertices  # Re-export for parametric → absolute coords (also extended in strips.jl)

export TributaryPolygon, TributaryBuffers
export VertexTributary
export get_tributary_polygons, get_tributary_polygons_isotropic, get_tributary_polygons_one_way
export compute_voronoi_tributaries
export SpanInfo, get_polygon_span, governing_spans
export short_span, long_span, two_way_span
export vertices

# =============================================================================
# ACI Strip Geometry (Column/Middle Strip Split) - Local
# =============================================================================

export ColumnStripPolygon, MiddleStripPolygon, PanelStripGeometry
export split_tributary_at_half_depth, compute_panel_strips
export verify_rectangular_strips

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

# =============================================================================
# Section Visualization Interface
# =============================================================================

# Geometry traits
export AbstractSectionGeometry
export SolidRect, HollowRect, HollowRound, IShape

# Trait assignment and getters
export section_geometry
export section_thickness
export section_flange_width, section_flange_thickness, section_web_thickness
export has_rebar, section_rebar_positions, section_rebar_radius

# =============================================================================
# Re-exports (at end to avoid world-age issues in Julia 1.12+)
# =============================================================================
@reexport using .Constants

end # module
