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
@reexport using Asap: GRAVITY

# Re-export type aliases (dimension-based, for function signatures)
@reexport using Asap: Length, Area, Volume, SectionModulus
@reexport using Asap: SecondMomentOfArea, TorsionalConstant, MomentOfInertia, WarpingConstant
@reexport using Asap: Pressure, Force, Moment, Torque
@reexport using Asap: LinearLoad, AreaLoadQuantity, Density, Acceleration

# Re-export concrete type aliases (for struct fields)
@reexport using Asap: LengthQuantity, AreaQuantity, VolumeQuantity
@reexport using Asap: PressureQuantity, ForceQuantity, MomentQuantity, ForcePerLength

# Re-export conversion helpers
@reexport using Asap: to_inches, to_sqinches, to_ksi, to_kip, to_kipft
@reexport using Asap: to_meters, to_pascals, to_newtons, to_newton_meters, to_newtons_per_meter
@reexport using Asap: asfloat, maybe_asfloat

# Register custom units and reset C-pointer caches at package load time (not precompile time)
function __init__()
    Unitful.register(Asap)
    _reset_gurobi_env!()   # clear stale Gurobi.Env pointer from precompilation

    # Skip heavy solver init when we're inside a precompilation worker subprocess
    # (e.g. when StructuralSynthesizer precompiles and loads us as a dependency).
    # Gurobi C-pointers and JuMP model state are not safe in that context.
    ccall(:jl_generating_output, Cint, ()) != 0 && return

    # Eagerly initialize Gurobi so the license handshake (~5 s) happens during
    # `using StructuralSizer` rather than surprising users mid-pipeline.
    if _HAS_GUROBI[]
        try _get_gurobi_env() catch; end
    end
    # Warm up the JuMP → solver bridge with a trivial MIP so that the first real
    # optimize_discrete() call doesn't pay ~2-3 s of JIT compilation.
    _warmup_jump_solvers()
end

# =============================================================================
# Local Modules
# =============================================================================

# Abstract types (AbstractMaterial, AbstractSection, etc.)
include("types.jl")

# Constants (ECC coefficients, PCA stiffness factors)
include("Constants.jl")

# Load infrastructure (combinations, gravity loads, pattern loading)
include("loads/_loads.jl")

# Materials (includes material types: Metal, Concrete, Timber)
include("materials/_materials.jl")

# Optimization infrastructure (shared abstractions + solvers)
include("optimize/_optimize.jl")

# Shared design code math (ACI material props, Whitney block, deflection, rebar)
# Must come after materials/ (uses Concrete, ReinforcedConcreteMaterial types)
# Must come before members/ and slabs/ (they call these functions)
include("codes/_codes.jl")

# Members (sections, codes, member-specific optimization)
include("members/_members.jl")

# Slabs (types, codes, optimization)
include("slabs/_slabs.jl")

# Foundations (types, soils, design codes)
include("foundations/_foundations.jl")

# Visualization interface (traits for section geometry - no GLMakie dependency)
include("visualization/_visualization.jl")

# =============================================================================
# Exports
# =============================================================================

# --- Abstract types ---
export AbstractMaterial, AbstractDesignCode, AbstractSection
export AbstractStructuralSynthesizer, AbstractBuildingSkeleton, AbstractBuildingStructure
export AbstractDemand, MemberDemand, AbstractMemberGeometry
export AbstractObjective, MinWeight, MinVolume, MinCost, MinCarbon
export objective_value, total_objective
export Constants

# --- Load combinations ---
export LoadCombination, factored_pressure, factored_load, envelope_pressure
export strength_1_4D, strength_1_2D_1_6L, strength_1_2D_1_6Lr
export strength_1_2D_1_0W, strength_1_2D_1_0E
export strength_0_9D_1_0W, strength_0_9D_1_0E
export ASD, service, default_combo
export asce7_strength_combinations, gravity_combinations

# --- Gravity loads ---
export GravityLoads, load_map
export default_loads, office_loads, residential_loads, assembly_loads
export retail_loads, storage_loads, parking_loads, hospital_loads, school_loads

# --- Pattern loading ---
export PatternLoadCase, FULL_LOAD, CHECKERBOARD_ODD, CHECKERBOARD_EVEN, ADJACENT_PAIRS
export requires_pattern_loading, generate_load_patterns, apply_load_pattern
export factored_pattern_loads, pattern_case_name

# --- Materials ---
export Metal, StructuralSteel, RebarSteel, Concrete, ReinforcedConcreteMaterial
export Timber, NDSChecker
export material_name
export A992_Steel, S355_Steel, Rebar_40, Rebar_60, Rebar_75, Rebar_80, Stud_51
export NWC_3000, NWC_4000, NWC_5000, NWC_6000, NWC_GGBS, NWC_PFA
export RC_3000_60, RC_4000_60, RC_5000_60, RC_6000_60, RC_5000_75, RC_6000_75, RC_GGBS_60
export Earthen_500, Earthen_1000, Earthen_2000, Earthen_4000, Earthen_8000
export concrete_fc, concrete_fc_mpa, concrete_E, concrete_wc
export AggregateType, siliceous, carbonate, sand_lightweight, lightweight

# --- Fire protection ---
export FireProtection, NoFireProtection, SFRM, IntumescentCoating, CustomCoating
export SurfaceCoating, coating_weight_per_foot

# --- Fire resistance (ACI 216.1) ---
export min_thickness_fire, min_cover_fire_slab, min_cover_fire_beam
export min_dimension_fire_column, min_cover_fire_column
export sfrm_thickness_x772, intumescent_thickness_n643, compute_surface_coating

# --- Section interface ---
export section_area, section_depth, section_width, weight_per_length, bounding_box
export Ix, Iy, Sx, Sy
export to_asap_section

# --- Sections: Steel (W shapes) ---
export ISymmSection, W, W_names, all_W, preferred_W
export Rebar, rebar, rebar_sizes, all_rebar
export update!, update, geometry, get_coords

# --- Sections: Steel (HSS) ---
export AbstractHollowSection, AbstractRectHollowSection, AbstractRoundHollowSection
export HSSRectSection, is_square, governing_slenderness
export HSSRoundSection, PipeSection, slenderness
export HSS, HSS_names, all_HSS
export HSSRound, HSSRound_names, all_HSSRound
export PIPE, PIPE_names, all_PIPE

# --- Sections: Timber ---
export GlulamSection, STANDARD_GLULAM_WIDTHS, GLULAM_LAM_THICKNESS

# --- Sections: Concrete ---
export RCBeamSection, rho, gross_moment_of_inertia, section_modulus_bottom, is_doubly_reinforced
export RCTBeamSection, flange_width, flange_thickness, gross_centroid_from_top
export standard_rc_tbeams, small_rc_tbeams, large_rc_tbeams
export RCColumnSection, RebarLocation, scale_column_section
export RCCircularSection, circular_compression_zone
export RCColumnDemand, RCBeamDemand
export standard_rc_columns, standard_rc_circular_columns
export square_rc_columns, rectangular_rc_columns, low_capacity_rc_columns, high_capacity_rc_columns, all_rc_rect_columns
export standard_circular_columns, low_capacity_circular_columns, high_capacity_circular_columns
export common_rc_circular_columns, all_rc_circular_columns
export effective_depth, compression_steel_depth, moment_of_inertia, radius_of_gyration, n_bars
export extreme_tension_depth, get_bar_depths, bar_depth_from_compression

# --- Capacity checkers ---
export AbstractCapacityChecker, AbstractCapacityCache
export create_cache, is_feasible, precompute_capacities!, get_objective_coeff
export SteelMemberGeometry, TimberMemberGeometry, ConcreteMemberGeometry
export AISCChecker, AISCCapacityCache
export ACIBeamChecker, ACIBeamCapacityCache
export ACIColumnChecker, ACIColumnCapacityCache

# --- Capacity interface ---
export get_Mn, get_Vn, get_Pn, get_Tn
export get_ϕMn, get_ϕVn, get_ϕPn, get_ϕTn
export check_interaction

# --- AISC 360-16 ---
export get_slenderness, is_compact
export get_Lp_Lr, get_Fcr_LTB, get_Fcr_flexural, get_Fe, get_Cv1
export check_PM_interaction, check_PMxMy_interaction
export compute_Cm, compute_Pe1, compute_B1
export compute_RM, compute_Pe_story, compute_B2
export amplify_moments, amplify_axial
export torsional_constant_rect_hss, torsional_constant_round_hss
export get_Fcr_torsion, check_combined_torsion_interaction, can_neglect_torsion
export dg9_Wno, dg9_Sw1, dg9_torsional_parameter
export torsion_case3_derivatives, torsion_case1_derivatives
export torsional_stresses_ksi, check_torsion_yielding, design_w_torsion

# --- ACI 318: material utilities ---
export beta1, Ec, Ec_ksi, fr, fc_ksi, fy_ksi, Es_ksi, εcu, β1
export to_material_tuple

# --- ACI 318: beam design ---
export beam_min_depth, beam_effective_depth, beam_min_reinforcement
export stress_block_depth, neutral_axis_depth, tensile_strain
export is_tension_controlled, flexure_phi
export beam_max_bar_spacing, select_beam_bars
export max_singly_reinforced, compression_steel_stress
export design_beam_flexure_doubly, design_beam_flexure
export effective_flange_width, design_tbeam_flexure
export moment_weighted_avg_depth, effective_flange_width_from_tributary
export Vc_beam, Vs_max_beam, Vs_required
export min_shear_reinforcement, max_stirrup_spacing
export design_stirrups, design_beam_shear, design_beam_deflection, design_tbeam_deflection
export torsion_section_properties, torsion_section_properties_tbeam
export threshold_torsion, cracking_torsion
export torsion_section_adequate, torsion_adequacy_ratio
export torsion_transverse_reinforcement, torsion_longitudinal_reinforcement
export min_torsion_transverse, min_torsion_longitudinal
export max_torsion_stirrup_spacing, design_beam_torsion

# --- ACI 318: column P-M interaction ---
export ControlPointType, PURE_COMPRESSION, MAX_COMPRESSION, FS_ZERO, FS_HALF_FY
export BALANCED, TENSION_CONTROLLED, PURE_BENDING, PURE_TENSION, INTERMEDIATE
export calculate_PM_at_c, c_from_εt
export pure_compression_capacity, max_compression_capacity
export phi_factor, calculate_phi_PM_at_c
export PMDiagramPoint, PMInteractionDiagram, PMDiagramRect, PMDiagramCircular
export generate_PM_diagram, get_nominal_curve, get_factored_curve
export get_control_points, get_control_point
export check_PM_capacity, capacity_at_axial, capacity_at_moment, utilization_ratio
export BendingAxis, StrongAxis, WeakAxis
export generate_PM_diagrams_biaxial
# calculate_PM_at_c, calculate_phi_PM_at_c, generate_PM_diagram, effective_depth
# now dispatch on WeakAxis() for y-axis bending

# --- ACI 318: column design ---
export design_column_reinforcement, resize_column_with_reinforcement
export slenderness_ratio, should_consider_slenderness
export effective_stiffness, critical_buckling_load
export magnification_factor_nonsway, calc_Cm, minimum_moment
export magnify_moment_nonsway, magnification_factor_sway, magnify_moment_sway
export SwayStoryProperties, stability_index, is_sway_frame
export B2StoryProperties, magnification_factor_sway_Q
export effective_stiffness_sway, critical_buckling_load_sway, magnify_moment_sway_complete

# --- ACI 318: biaxial bending ---
export bresler_reciprocal_load, check_bresler_reciprocal
export bresler_load_contour, pca_load_contour
export check_biaxial_capacity, check_biaxial_simple
export check_biaxial_rectangular, check_biaxial_auto

# --- Rebar helpers ---
export get_rebar_fy, get_transverse_rebar, get_transverse_bar_diameter

# --- Optimization: discrete (MIP) ---
export optimize_discrete
export size_columns, size_beams, size_members
export to_steel_demands, to_rc_demands
export to_steel_geometry, to_concrete_geometry, convert_geometries

# --- Optimization: continuous (NLP) ---
export AbstractNLPProblem
export n_variables, variable_bounds, initial_guess, evaluate
export objective_fn, constraint_fns, constraint_bounds, n_constraints
export variable_names, constraint_names, problem_summary
export optimize_continuous
export VaultNLPProblem, optimize_vault
export RCColumnNLPProblem, RCColumnNLPResult, build_rc_column_nlp_result
export size_rc_column_nlp, size_rc_columns_nlp
export RCCircularNLPProblem, RCCircularNLPResult, build_rc_circular_nlp_result
# size_rc_column_nlp / size_rc_columns_nlp now dispatch on Type{RCCircularSection}
export RCBeamNLPProblem, RCBeamNLPResult, build_rc_beam_nlp_result
export size_rc_beam_nlp, size_rc_beams_nlp
export RCTBeamNLPProblem, RCTBeamNLPResult, build_rc_tbeam_nlp_result
export size_rc_tbeam_nlp, size_rc_tbeams_nlp, size_tbeams
export HSSColumnNLPProblem, HSSColumnNLPResult, build_hss_nlp_result
export size_hss_nlp, size_hss_columns_nlp
export WColumnNLPProblem, WColumnNLPResult, build_w_nlp_result
export size_w_nlp, size_w_columns_nlp
export SteelWBeamNLPProblem, build_w_beam_nlp_result
export size_steel_w_beam_nlp, size_steel_w_beams_nlp
export SteelHSSBeamNLPProblem, build_hss_beam_nlp_result
export size_steel_hss_beam_nlp, size_steel_hss_beams_nlp

# --- Sizing options ---
export SteelMemberOptions, SteelColumnOptions, SteelBeamOptions
export ConcreteColumnOptions, ConcreteBeamOptions
export NLPColumnOptions, NLPHSSOptions, NLPWOptions, NLPBeamOptions
export ColumnOptions, BeamOptions, MemberOptions
export steel_column_catalog, rc_column_catalog, rc_beam_catalog
export standard_rc_beams, small_rc_beams, large_rc_beams, all_rc_beams

# --- Floor system types ---
export AbstractFloorSystem, AbstractConcreteSlab, AbstractSteelFloor, AbstractTimberFloor
export OneWay, TwoWay, FlatPlate, FlatSlab, PTBanded, Waffle
export HollowCore, Vault, Grade
export CompositeDeck, NonCompositeDeck, JoistRoofDeck
export CLT, DLT, NLT, MassTimberJoist
export ShapedSlab

# --- Floor system traits + queries ---
export SpanningBehavior, OneWaySpanning, TwoWaySpanning, BeamlessSpanning
export spanning_behavior, is_one_way, is_two_way, is_beamless, requires_column_tributaries
export SupportCondition, SIMPLE, ONE_END_CONT, BOTH_ENDS_CONT, CANTILEVER
export floor_type, floor_symbol, infer_floor_type

# --- Floor options ---
export AbstractFloorOptions
export FlatPlateOptions, FlatSlabOptions, OneWayOptions, VaultOptions, CompositeDeckOptions, TimberOptions
export flat_slab  # convenience constructor for FlatSlabOptions
export result_materials

# --- Floor result types ---
export AbstractFloorResult
export CIPSlabResult, ProfileResult, CompositeDeckResult, JoistDeckResult
export TimberPanelResult, TimberJoistResult, VaultResult, ShapedSlabResult
export total_thrust, is_adequate
export StripReinforcement, FlatPlatePanelResult, ShearStudDesign, PunchingCheckResult
export deflection_ok, punching_ok, max_punching_ratio, deflection_ratio

# --- Floor common interface ---
export self_weight, total_depth, volume_per_area
export has_structural_effects, apply_effects!, required_materials
export load_distribution, get_gravity_loads, LoadDistributionType
export DISTRIBUTION_ONE_WAY, DISTRIBUTION_TWO_WAY, DISTRIBUTION_POINT, DISTRIBUTION_CUSTOM
export default_tributary_axis, resolve_tributary_axis
export materials, material_volumes

# --- Minimum thickness (ACI deflection-control tables, all CIP types) ---
export min_thickness

# --- Flat plate calculations (ACI 318) ---
export clear_span
export equivalent_square_column, circular_column_Ic
export total_static_moment, distribute_moments_mddm, distribute_moments_aci
export edge_beam_βt, aci_ddm_longitudinal_with_edge_beam, aci_col_strip_ext_neg_fraction
export required_reinforcement, minimum_reinforcement, max_bar_spacing
export cracked_moment_of_inertia, cracked_moment_of_inertia_tbeam
export effective_moment_of_inertia, cracking_moment
export immediate_deflection, long_term_deflection_factor, deflection_limit
export required_Ix_for_deflection
export MDDM_COEFFICIENTS, ACI_DDM_LONGITUDINAL
export estimate_column_size, estimate_column_size_from_span, face_of_support_moment

# --- Flat plate analysis methods ---
export FlatPlateAnalysisMethod, DDM, EFM, EFM_Kc, FEA, RuleOfThumb
export MomentAnalysisResult
export DDMApplicabilityError, EFMApplicabilityError
export EFMSpanProperties, EFMJointStiffness, EFMModelCache, FEAModelCache
export build_efm_asap_model, solve_efm_frame!, extract_span_moments
export distribute_moments_to_strips

# --- Flat plate design helpers ---
export check_punching_for_column, check_punching_at_drop_edge, check_punching
export design_strip_reinforcement, design_single_strip
export build_slab_result, build_column_results
export method_name, round_up_thickness
export run_secondary_moment_analysis
export solve_column_for_punching, target_aspect_ratio
export grow_column!, grow_column_for_axial!
export find_supporting_columns, build_frame_line, build_frame_lines_both_directions
export compute_column_axial_loads, update_asap_column_sections!
export check_pattern_loading_requirement, enforce_method_applicability

# --- Flat plate drop panel ---
export DropPanelGeometry, total_depth_at_drop, drop_extent_1, drop_extent_2
export check_drop_panel_aci

# --- Shear stud design (ACI 318-11 §11.11.5) ---
export punching_capacity_with_studs, punching_capacity_outer
export minimum_stud_reinforcement, stud_area, design_shear_studs, check_punching_with_studs

# --- Moment transfer / integrity reinforcement ---
export transfer_reinforcement, additional_transfer_bars
export integrity_reinforcement, check_integrity_reinforcement

# --- Two-way deflection ---
export load_distribution_factor, frame_deflection_fixed, strip_deflection_fixed
export deflection_from_rotation, support_rotation, two_way_panel_deflection

# --- Punching shear (ACI 22.6, shared) ---
export punching_geometry_interior, punching_geometry_edge, punching_geometry_corner
export punching_geometry, punching_αs, punching_β
export gamma_f, gamma_v, effective_slab_width
export polar_moment_Jc_interior, polar_moment_Jc_edge
export punching_capacity_stress, punching_capacity_interior
export combined_punching_stress, punching_perimeter, punching_demand
export check_punching_shear, check_combined_punching
export one_way_shear_capacity, one_way_shear_demand, check_one_way_shear
export punching_check

# --- Rebar catalog (ACI, shared) ---
export bar_diameter, bar_area, infer_bar_size, select_bars
export select_bars_for_size, select_bars_candidates

# --- EFM stiffnesses (ACI 318 Section 8.11) ---
export slab_moment_of_inertia, column_moment_of_inertia, torsional_constant_C
export slab_beam_stiffness_Ksb, column_stiffness_Kc, torsional_member_stiffness_Kt
export equivalent_column_stiffness_Kec, distribution_factor_DF, carryover_factor_COF
export fixed_end_moment_FEM
# --- Flat Slab / Drop Panel ---
export FlatSlabOptions, as_flat_plate_options
# column_stiffness_Kc and fixed_end_moment_FEM now dispatch on drop panel arity
export DropSectionProperties, gross_section_at_drop, weighted_slab_thickness
export slab_self_weight_with_drop
export weighted_effective_Ie
# check_two_way_deflection now dispatches on drop panel arity
export STANDARD_DROP_DEPTHS_INCH

# --- Slab sizing ---
export size_slabs!, size_slab!
export size_flat_plate_optimized, FlatPlateNLPProblem

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
# Tributary Area (re-exported from Asap)
# =============================================================================

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
export loose_sand, medium_sand, dense_sand
export soft_clay, stiff_clay, hard_clay

# Foundation result types
export AbstractFoundationResult
export SpreadFootingResult, CombinedFootingResult, StripFootingResult, MatFootingResult, PileCapResult

# Foundation demand
export FoundationDemand

# Type mapping
export foundation_type, foundation_symbol

# Common interface
export concrete_volume, steel_volume, footprint_area, footing_length, footing_width, utilization

# Foundation options
export SpreadFootingOptions, StripFootingOptions, MatFootingOptions, FoundationOptions
export AbstractMatMethod, RigidMat, ShuklaAFM, WinklerFEA

# Design functions
export design_footing
export recommend_foundation_strategy

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

# =============================================================================
# Precompilation Workload
# =============================================================================
#
# Tier 0  Shared infrastructure (unit boundary, type constructors)
#         → exercised implicitly by the Tier 1 calls below.
# Tier 1  Material foundations (1 call per function, cheap type-specialization)
#         → concrete props, slab helpers, punching geometry, shear, deflection,
#           steel capacity (single-section, no MIP).
#
# Heavy paths (AISC MIP, ACI column P-M MIP, ACI beam checker, etc.) are
# intentionally omitted — they change frequently and are material-specific.
# The __init__ JuMP warmup handles the solver bridge JIT at runtime.
# =============================================================================

using PrecompileTools

@setup_workload begin
    @compile_workload begin
        redirect_stdio(; stdout=devnull, stderr=devnull) do
            # =================================================================
            # Tier 1a: Steel Foundation (single-section capacity, no MIP)
            # =================================================================
            try
                _s   = all_W()[1]
                _mat = A992_Steel
                get_ϕMn(_s, _mat; Lb=3.0u"m", Cb=1.0, axis=:strong)
                get_ϕVn(_s, _mat; axis=:strong)
                get_ϕPn(_s, _mat, 3.0u"m"; axis=:strong)
            catch; end

            # =================================================================
            # Tier 1b: Concrete Foundation (material props + slab sizing)
            # =================================================================
            try
                _fc  = NWC_4000.fc′
                _wc  = ustrip(pcf, NWC_4000.ρ)
                _Ecs = Ec(_fc, _wc)
                _Ecs1 = Ec(_fc)

                _h   = min_thickness(FlatPlate(), 20.0u"ft")
                _sw  = slab_self_weight(_h, NWC_4000.ρ)
                _ln  = clear_span(20.0u"ft", 16.0u"inch")
                _M0  = total_static_moment(100.0psf, 20.0u"ft", _ln)

                # Flat-plate span sizing dispatch (exercises DDM helpers)
                _size_span_floor(FlatPlate(), 20.0u"ft", 20.0psf, 50.0psf;
                    material=NWC_4000, l2=20.0u"ft", c1=16.0u"inch", c2=16.0u"inch",
                    position=:interior)
            catch; end

            # =================================================================
            # Tier 1c: Punching Shear Geometry (ACI 22.6)
            # =================================================================
            try
                _d  = effective_depth(8.0u"inch")
                _c  = 16.0u"inch"
                _fc = NWC_4000.fc′

                # Interior
                _gi  = punching_geometry_interior(_c, _c, _d)
                _Jci = polar_moment_Jc_interior(_gi.b1, _gi.b2, _d)
                _γv  = gamma_v(_gi.b1, _gi.b2)
                combined_punching_stress(
                    50.0kip, 100.0kip * u"ft",
                    _gi.b0, _d, _γv, _Jci, _gi.cAB,
                )
                punching_capacity_stress(_fc, 1.0, 40, _gi.b0, _d)

                # Edge + Corner
                _ge = punching_geometry_edge(_c, _c, _d)
                polar_moment_Jc_edge(_ge.b1, _ge.b2, _d, _ge.cAB)
                _gc = punching_geometry_corner(_c, _c, _d)
            catch; end

            # =================================================================
            # Tier 1d: Deflection + One-Way Shear (ACI 24 / 22.5)
            # =================================================================
            try
                _fc = NWC_4000.fc′
                _h  = 8.0u"inch"
                _d  = effective_depth(_h)
                _bw = 20.0u"ft"
                _ln = clear_span(20.0u"ft", 16.0u"inch")

                _Vu = one_way_shear_demand(100.0psf, _bw, _ln, _d)
                _Vc = one_way_shear_capacity(_fc, _bw, _d)
                check_one_way_shear(_Vu, _Vc)
            catch; end
        end
    end
end

end # module
