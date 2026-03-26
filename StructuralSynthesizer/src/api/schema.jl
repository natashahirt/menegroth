# =============================================================================
# API Schema — JSON input/output struct definitions
# =============================================================================
#
# These structs mirror the JSON wire format. They are plain data containers
# with no Unitful quantities — conversion happens in deserialize.jl and
# serialize.jl at the boundary.
# =============================================================================

using JSON3
using StructTypes

# ─── Full input schema for GET /schema ─────────────────────────────────────
# Describes the complete APIInput shape so clients have a single source of truth.

"""
    api_input_schema() -> Dict

Return a documentation schema for the full API input payload (APIInput + APIParams).
Used by GET /schema to align documentation with the actual wire format.
"""
function api_input_schema()
    return Dict(
        "units" => Dict(
            "type" => "string",
            "required" => true,
            "description" => "Coordinate units for vertices and story elevations.",
            "accepted" => _accepted_doc(API_UNIT_ALIASES),
        ),
        "vertices" => Dict(
            "type" => "array of [x, y, z]",
            "required" => true,
            "description" => "Array of vertex coordinates; at least 4 required.",
        ),
        "edges" => Dict(
            "type" => "object",
            "description" => "Beam, column, and brace connectivity.",
            "fields" => Dict(
                "beams" => "Array of [v1, v2] vertex index pairs (1-based).",
                "columns" => "Array of [v1, v2] vertex index pairs (1-based).",
                "braces" => "Array of [v1, v2] vertex index pairs (1-based).",
            ),
        ),
        "supports" => Dict(
            "type" => "array of integers",
            "required" => true,
            "description" => "Vertex indices (1-based) that are fixed supports.",
        ),
        "stories_z" => Dict(
            "type" => "array of numbers",
            "required" => false,
            "description" => "Story elevations in coordinate units. If omitted, inferred from vertex Z.",
        ),
        "faces" => Dict(
            "type" => "object",
            "required" => false,
            "description" => "Optional. Keys: floor, roof, grade. Values: arrays of polylines [[x,y,z], ...].",
        ),
        "params" => Dict(
            "type" => "object",
            "description" => "Design parameters; all fields optional with defaults below.",
            "fields" => Dict(
                "unit_system" => "Display units: \"imperial\" or \"metric\". Default: \"imperial\".",
                "loads" => Dict(
                    "floor_LL_psf" => "Floor live load (psf). Default: 80.",
                    "roof_LL_psf" => "Roof live load (psf). Default: floor_LL_psf when omitted.",
                    "grade_LL_psf" => "Grade live load (psf). Default: floor_LL_psf when omitted.",
                    "floor_SDL_psf" => "Floor superimposed dead (psf). Default: 15.",
                    "roof_SDL_psf" => "Roof superimposed dead (psf). Default: 15.",
                    "wall_SDL_psf" => "Wall superimposed dead (psf). Default: 10.",
                ),
                "floor_type" => "$(join(API_FLOOR_TYPES, " | ")). Default: flat_plate.",
                "max_iterations" => "Optional. Maximum beam/column sizing iterations (integer >= 1). Default: 20.",
                "floor_options" => Dict(
                    "method" => "$(join(API_FLOOR_ANALYSIS_METHODS, " | ")). Default: DDM.",
                    "deflection_limit" => "$(join(API_DEFLECTION_LIMITS, " | ")). Default: L_360.",
                    "punching_strategy" => "$(join(API_PUNCHING_STRATEGIES, " | ")). Default: grow_columns.",
                    "target_edge_m" => "Optional. FEA mesh target edge length (m). Default: adaptive clamp(min_span/20, 0.15, 0.75). Used when method is FEA.",
                    "vault_lambda" => "Optional vault span/rise ratio (dimensionless, > 0). Used when floor_type is vault.",
                ),
                "visualization_target_edge_m" => "Optional. Visualization shell mesh target edge (m). Default: inherits from FEA target_edge when method is FEA, else adaptive. Coarser = faster viz.",
                "skip_visualization" => "When true, skip shell mesh build and visualization serialization (faster response, frame-only). Default: false.",
                "visualization_detail" => "minimal | full. minimal = frame elements + slab boundaries only (no deflected meshes, no per-face analytical). full = full visualization. Default: full.",
                "scoped_overrides" => "Optional list of scoped floor overrides. Each override provides face polygons and floor-specific options applied only to matching cells.",
                "materials" => Dict(
                    "concrete" => "Slab/floor concrete (e.g. NWC_4000, Earthen_500, Earthen_2000). Default: NWC_4000.",
                    "column_concrete" => "Column concrete (e.g. NWC_6000). Default: NWC_6000.",
                    "rebar" => "Rebar name (e.g. Rebar_60). Default: Rebar_60.",
                    "steel" => "Steel name (e.g. A992). Default: A992.",
                ),
                "column_type" => "$(join(API_COLUMN_TYPES, " | ")). Default: rc_rect.",
                "column_catalog" => "Optional column catalog (string or null). Steel (steel_w/steel_hss/steel_pipe): compact_only | preferred | all. RC rectangular (rc_rect): standard | square | rectangular | low_capacity | high_capacity | all. RC circular (rc_circular): standard | low_capacity | high_capacity | all. Ignored for pixelframe. If omitted or null: defaults to preferred (steel) or standard (RC).",
                "column_sizing_strategy" => "discrete (MIP catalog) or nlp (continuous Ipopt). Default: discrete. Applies to RC and steel columns.",
                "mip_time_limit_sec" => "MIP solver time limit (seconds) when discrete sizing. Default: 30.",
                "beam_type" => "$(join(API_BEAM_TYPES, " | ")). Default: steel_w.",
                "beam_catalog" => "RC beam catalog when beam_type is rc_rect or rc_tbeam: $(join(API_BEAM_CATALOGS, " | ")). Default: large. Use xlarge for vaults with high thrust. Use custom with beam_catalog_bounds for bounds-based catalog. Ignored for pixelframe.",
                "beam_sizing_strategy" => "discrete (MIP catalog) or nlp (continuous Ipopt). Default: discrete. Applies to RC and steel beams.",
                "beam_catalog_bounds" => "Required when beam_catalog is custom. Object: min_width_in, max_width_in, min_depth_in, max_depth_in, resolution_in (all in inches).",
                "pixelframe_options" => "When column_type or beam_type is pixelframe. Object: fc_preset (standard | low | high | extended | custom) or fc_min_ksi, fc_max_ksi, fc_resolution_ksi when custom. Default: standard.",
                "fire_rating" => "Fire rating (hours): 0, 1, 1.5, 2, 3, or 4. Default: 0.",
                "optimize_for" => "$(join(API_OPTIMIZE_FOR, " | ")). Default: weight.",
                "size_foundations" => "Boolean. Default: false.",
                "foundation_soil" => "Soil name (e.g. medium_sand). Required when size_foundations is true. Default: medium_sand.",
                "foundation_concrete" => "Foundation concrete (e.g. NWC_3000). Default: NWC_3000.",
                "foundation_options" => Dict(
                    "strategy" => "$(join(API_FOUNDATION_STRATEGIES, " | ")). Default: auto.",
                    "mat_coverage_threshold" => "Switch to mat when coverage ratio exceeds this (0–1). Default: 0.5.",
                    "spread_params" => "Optional. cover_in, min_depth_in, bar_size, depth_increment_in, size_increment_in (inches).",
                    "strip_params" => "Optional. cover_in, min_depth_in, bar_size_long, bar_size_trans, width_increment_in, max_depth_ratio, merge_gap_factor, eccentricity_limit.",
                    "mat_params" => "Optional. cover_in, min_depth_in, bar_size_x, bar_size_y, depth_increment_in, edge_overhang_in, analysis_method ($(join(API_MAT_ANALYSIS_METHODS, " | "))).",
                ),
            ),
        ),
    )
end

# ─── Structured Parameter Schema (for LLM agents) ───────────────────────────

"""
    api_params_schema_structured() -> Dict

Return a machine-readable description of every `APIParams` field.
Each entry has: `type`, `default`, `allowed` (for enums), `range` (for numerics),
`depends_on` (conditional availability), and `guidance` (engineering heuristic text
for the LLM to use when recommending or explaining parameters).
"""
function api_params_schema_structured()
    Dict{String, Any}(
        "unit_system" => Dict(
            "type" => "enum", "default" => "imperial",
            "allowed" => collect(API_UNIT_SYSTEMS),
            "guidance" => "Use imperial (ft, in, psf, ksi) for US projects, metric (m, mm, kPa, MPa) for international. Affects all display units in results.",
        ),
        "floor_type" => Dict(
            "type" => "enum", "default" => "flat_plate",
            "allowed" => collect(API_FLOOR_TYPES),
            "guidance" => "flat_plate: beamless two-way slab system (typically economical for regular bays, moderate spans). flat_slab: flat_plate with drop panels for punching/shear demand control. one_way: use when load path is dominantly one direction (long narrow bays). vault: parabolic shell behavior with horizontal thrust; requires RC beams/columns and rectangular orthogonal faces in current implementation. Compatibility checks enforced in API validation: flat_plate/flat_slab require RC columns (steel/pixelframe columns rejected); vault requires RC columns and RC beams.",
            "compatibility_checks" => Dict{String, Any}(
                "implemented_in" => "StructuralSynthesizer/src/api/validation.jl",
                "rules" => Any[
                    Dict{String, Any}(
                        "id" => "floor_rc_columns_for_beamless",
                        "when" => Dict("floor_type" => ["flat_plate", "flat_slab"]),
                        "requires" => Dict("column_type" => ["rc_rect", "rc_circular"]),
                        "rejects" => Dict("column_type" => ["steel_w", "steel_hss", "steel_pipe", "pixelframe"]),
                        "severity" => "error",
                    ),
                    Dict{String, Any}(
                        "id" => "vault_requires_rc_columns_and_beams",
                        "when" => Dict("floor_type" => "vault"),
                        "requires" => Dict(
                            "column_type" => ["rc_rect", "rc_circular"],
                            "beam_type" => ["rc_rect", "rc_tbeam"],
                        ),
                        "rejects" => Dict(
                            "column_type" => ["steel_w", "steel_hss", "steel_pipe"],
                            "beam_type" => ["steel_w", "steel_hss"],
                        ),
                        "severity" => "error",
                    ),
                ],
            ),
        ),
        "column_type" => Dict(
            "type" => "enum", "default" => "rc_rect",
            "allowed" => collect(API_COLUMN_TYPES),
            "guidance" => "rc_rect: standard for concrete buildings, good for fire resistance. rc_circular: aesthetics or round plan. steel_w: common for steel-framed buildings, lighter for tall buildings. steel_hss: compact columns for limited space. pixelframe: experimental 3D-printed concrete.",
        ),
        "beam_type" => Dict(
            "type" => "enum", "default" => "steel_w",
            "allowed" => collect(API_BEAM_TYPES),
            "guidance" => "steel_w: standard W-shapes, widely available. rc_rect: concrete beams for all-concrete buildings. rc_tbeam: T-beams (flange from slab), efficient for one-way systems. steel_hss: compact rectangular tubes. pixelframe: experimental.",
        ),
        "loads" => Dict(
            "type" => "object",
            "fields" => Dict{String, Any}(
                "floor_LL_psf" => Dict("type" => "number", "default" => 80.0, "range" => [20.0, 250.0], "unit" => "psf",
                    "guidance" => "ASCE 7 Table 4.3-1: office=50, residential=40, assembly=100, retail=75-100, storage=125-250. 80 psf is a safe general default."),
                "roof_LL_psf" => Dict("type" => "number", "default" => "same as floor_LL_psf", "range" => [20.0, 100.0], "unit" => "psf",
                    "guidance" => "ASCE 7: ordinary flat roof=20, reducible. Higher for rooftop gardens or equipment."),
                "floor_SDL_psf" => Dict("type" => "number", "default" => 15.0, "range" => [5.0, 50.0], "unit" => "psf",
                    "guidance" => "Superimposed dead load: MEP, partitions, finishes. 15 psf typical for office. 25-30 for heavy MEP."),
                "roof_SDL_psf" => Dict("type" => "number", "default" => 15.0, "range" => [5.0, 40.0], "unit" => "psf",
                    "guidance" => "Roof superimposed dead: roofing, insulation, equipment pads."),
                "wall_SDL_psf" => Dict("type" => "number", "default" => 10.0, "range" => [0.0, 30.0], "unit" => "psf",
                    "guidance" => "Facade dead load applied to perimeter beams. 10 psf for curtain wall, 15-25 for masonry."),
            ),
        ),
        "floor_options" => Dict(
            "type" => "object",
            "fields" => Dict{String, Any}(
                "method" => Dict("type" => "enum", "default" => "DDM",
                    "allowed" => collect(API_FLOOR_ANALYSIS_METHODS),
                    "guidance" => "DDM/DDM_SIMPLIFIED (ACI 318-11 §13.6 / §8.10 checks as implemented): requires rectangular panel geometry, aspect ratio 0.5<=l2/l1<=2.0 (§8.10.2.2), L/D<=2.0 using estimated self-weight (§8.10.2.6), and adequate continuous spans/column lines (>=3 spans target; warning/violation when insufficient, §8.10.2.1). Additional implemented checks include adjacent-span variation <=1/3 when adjacency data exists (§8.10.2.3), column offset <=10% of span from column lines (§8.10.2.4), and practical clear-span minimum ln>=4 ft. EFM/EFM_HARDY_CROSS (ACI 318-11 §13.7 / §8.11 checks as implemented): still requires rectangular/orthogonal panel geometry for frame idealization (§8.11.2), gravity-load framing assumptions (§8.11.1.1), at least two supporting columns, and column-size limits for torsional-stiffness formulation (§8.11.5, c2/l2<=0.5 check). FEA: shell analysis is the most general and allowed for irregular geometry; however, if design_approach=:frame, post-processing uses ACI §8.10.5-style fractions and emits warnings when DDM regularity checks fail. Use FEA for non-rectangular panels, setbacks, or free-form column layouts.",
                    "applicability_checks" => Dict{String, Any}(
                        "implemented_in" => Dict(
                            "DDM" => "StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/ddm.jl",
                            "EFM" => "StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/efm.jl",
                            "FEA" => "StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/helpers.jl",
                        ),
                        "DDM" => Dict{String, Any}(
                            "code_basis" => "ACI 318-11 §13.6 / §8.10 (implemented checks)",
                            "hard_checks" => Any[
                                Dict("id" => "ddm_rectangular_geometry", "clause" => "§8.10.2.2", "check" => "panel geometry rectangular/orthogonal"),
                                Dict("id" => "ddm_aspect_ratio", "clause" => "§8.10.2.2", "check" => "0.5 <= l2/l1 <= 2.0"),
                                Dict("id" => "ddm_live_dead_ratio", "clause" => "§8.10.2.6", "check" => "L/D <= 2.0 using estimated self-weight"),
                                Dict("id" => "ddm_min_clear_span", "clause" => "implementation guardrail", "check" => "clear span ln >= 4 ft"),
                            ],
                            "context_checks" => Any[
                                Dict("id" => "ddm_min_span_continuity", "clause" => "§8.10.2.1", "check" => ">=3 continuous spans target (column-line adequacy check)"),
                                Dict("id" => "ddm_successive_span_variation", "clause" => "§8.10.2.3", "check" => "adjacent span difference <= longer span / 3", "applies_when" => "adjacent slab metadata available"),
                                Dict("id" => "ddm_column_offset", "clause" => "§8.10.2.4", "check" => "column offset <= 10% of span from column lines", "applies_when" => "column coordinates resolvable"),
                            ],
                            "loads_assumption" => Dict("clause" => "§8.10.2.5", "assumption" => "gravity/uniform slab loading model in current workflow"),
                        ),
                        "DDM_SIMPLIFIED" => Dict{String, Any}(
                            "inherits" => "DDM",
                            "note" => "Uses simplified DDM coefficients but same applicability checks in current implementation.",
                        ),
                        "EFM" => Dict{String, Any}(
                            "code_basis" => "ACI 318-11 §13.7 / §8.11 (implemented checks)",
                            "hard_checks" => Any[
                                Dict("id" => "efm_rectangular_geometry", "clause" => "§8.11.2", "check" => "panel geometry rectangular/orthogonal for frame idealization"),
                                Dict("id" => "efm_min_supporting_columns", "clause" => "§8.11.2 (implementation)", "check" => "at least 2 supporting columns"),
                                Dict("id" => "efm_torsion_stiffness_limit", "clause" => "§8.11.5", "check" => "column dimension ratio c2/l2 <= 0.5"),
                                Dict("id" => "efm_min_clear_span", "clause" => "implementation guardrail", "check" => "clear span ln >= 4 ft"),
                            ],
                            "loads_assumption" => Dict("clause" => "§8.11.1.1", "assumption" => "gravity-load frame analysis in current workflow"),
                        ),
                        "EFM_HARDY_CROSS" => Dict{String, Any}(
                            "inherits" => "EFM",
                            "note" => "Same applicability as EFM; differs only in frame-solver backend.",
                        ),
                        "FEA" => Dict{String, Any}(
                            "code_basis" => "Implementation policy + ACI-referenced post-processing",
                            "hard_checks" => Any[
                                Dict("id" => "fea_min_supporting_columns", "clause" => "implementation", "check" => "at least 2 supporting columns"),
                            ],
                            "advisory_checks" => Any[
                                Dict(
                                    "id" => "fea_frame_design_approach_guardrail",
                                    "clause" => "ACI §8.10.5 style CS/MS fraction use in implementation",
                                    "check" => "if design_approach=:frame and DDM regularity checks fail, emit warning (results may be approximate)",
                                ),
                                Dict(
                                    "id" => "fea_strip_non_quad_guardrail",
                                    "clause" => "implementation",
                                    "check" => "for design_approach=:strip, non-quad/non-convex cells trigger integration warnings/fallback behavior",
                                ),
                                Dict(
                                    "id" => "fea_area_transform_guardrail",
                                    "clause" => "implementation",
                                    "check" => "for design_approach=:area, projection/no_torsion transforms are warned as potentially unconservative",
                                ),
                            ],
                        ),
                    )),
                "deflection_limit" => Dict("type" => "enum", "default" => "L_360",
                    "allowed" => collect(API_DEFLECTION_LIMITS),
                    "guidance" => "L_240: lenient (partitions unlikely). L_360: standard for supported partitions. L_480: strict for sensitive finishes."),
                "punching_strategy" => Dict("type" => "enum", "default" => "grow_columns",
                    "allowed" => collect(API_PUNCHING_STRATEGIES),
                    "guidance" => "grow_columns: increase column size to pass punching (preferred). reinforce_first: add shear reinforcement before growing. reinforce_last: grow first, reinforce only if needed. For irregular plans with non-uniform tributary areas, punching shear demands can vary widely — review results carefully at re-entrant corners and edge columns."),
                "target_edge_m" => Dict("type" => "number", "default" => "adaptive", "range" => [0.05, 2.0], "unit" => "m",
                    "depends_on" => Dict("method" => "FEA"),
                    "guidance" => "FEA mesh target edge length. Smaller = more accurate but slower. Default: adaptive based on span."),
                "vault_lambda" => Dict("type" => "number", "default" => 10.0, "range" => [4.0, 30.0],
                    "depends_on" => Dict("floor_type" => "vault"),
                    "guidance" => "Span-to-rise ratio for vault floors. Lower = deeper arch (more efficient structurally, taller). 8-12 typical."),
            ),
        ),
        "materials" => Dict(
            "type" => "object",
            "fields" => Dict{String, Any}(
                "concrete" => Dict("type" => "string", "default" => "NWC_4000",
                    "guidance" => "Slab/floor concrete. NWC_4000 (4 ksi) standard for slabs. NWC_5000 for higher loads. Earthen_2000 for low-carbon."),
                "column_concrete" => Dict("type" => "string", "default" => "NWC_6000",
                    "guidance" => "Column concrete. Higher f'c (6-8 ksi) allows smaller columns for high axial loads."),
                "rebar" => Dict("type" => "string", "default" => "Rebar_60",
                    "guidance" => "Rebar grade. Rebar_60 (Grade 60, fy=60 ksi) is standard. Rebar_80 for reduced congestion."),
                "steel" => Dict("type" => "string", "default" => "A992",
                    "guidance" => "Structural steel. A992 (Fy=50 ksi) standard for W-shapes. A500_GrB for HSS."),
            ),
        ),
        "column_catalog" => Dict(
            "type" => "enum_or_null", "default" => "null (auto: preferred for steel, standard for RC)",
            "allowed" => Dict(
                "steel_w" => collect(API_STEEL_COLUMN_CATALOGS),
                "rc_rect" => collect(API_RC_RECT_COLUMN_CATALOGS),
                "rc_circular" => collect(API_RC_CIRCULAR_COLUMN_CATALOGS),
            ),
            "depends_on" => Dict("column_type" => "not pixelframe"),
            "guidance" => "Controls the pool of available sections. 'preferred' or 'standard' for typical projects. 'all' maximizes optimization range but increases solve time.",
        ),
        "column_sizing_strategy" => Dict(
            "type" => "enum", "default" => "discrete",
            "allowed" => collect(API_SIZING_STRATEGIES),
            "guidance" => "discrete: mixed-integer programming over catalog sections (standard). nlp: continuous optimization (experimental, may find lighter solutions for RC).",
        ),
        "mip_time_limit_sec" => Dict(
            "type" => "number_or_null", "default" => 30.0, "range" => [1.0, 300.0], "unit" => "seconds",
            "depends_on" => Dict("column_sizing_strategy" => "discrete"),
            "guidance" => "MIP solver time limit. 30s is sufficient for most regular buildings. Increase to 60-120s for large or irregular buildings with many distinct column groups.",
        ),
        "beam_catalog" => Dict(
            "type" => "enum", "default" => "large",
            "allowed" => collect(API_BEAM_CATALOGS),
            "depends_on" => Dict("beam_type" => ["rc_rect", "rc_tbeam"]),
            "guidance" => "RC beam catalog size. 'large' is standard. 'xlarge' for vault tie-beams with high thrust. 'custom' allows explicit bounds via beam_catalog_bounds.",
        ),
        "beam_sizing_strategy" => Dict(
            "type" => "enum", "default" => "discrete",
            "allowed" => collect(API_SIZING_STRATEGIES),
            "guidance" => "Same as column_sizing_strategy but for beams.",
        ),
        "beam_catalog_bounds" => Dict(
            "type" => "object_or_null", "default" => "null",
            "depends_on" => Dict("beam_catalog" => "custom"),
            "fields" => Dict(
                "min_width_in" => Dict("type" => "number", "unit" => "in"),
                "max_width_in" => Dict("type" => "number", "unit" => "in"),
                "min_depth_in" => Dict("type" => "number", "unit" => "in"),
                "max_depth_in" => Dict("type" => "number", "unit" => "in"),
                "resolution_in" => Dict("type" => "number", "unit" => "in"),
            ),
            "guidance" => "Custom beam size bounds when beam_catalog='custom'. Width 10-24 in, depth 12-36 in is typical. Resolution 2 in is standard.",
        ),
        "fire_rating" => Dict(
            "type" => "number", "default" => 0.0,
            "allowed" => [0.0, 1.0, 1.5, 2.0, 3.0, 4.0],
            "guidance" => "IBC fire rating in hours. 0 = no fire design. 1-2 hrs typical for most occupancies. Affects concrete cover, minimum thickness, and steel fire protection.",
        ),
        "optimize_for" => Dict(
            "type" => "enum", "default" => "weight",
            "allowed" => collect(API_OPTIMIZE_FOR),
            "guidance" => "Optimization objective. weight: minimize material weight (cheapest). carbon: minimize embodied carbon (greenest). cost: minimize estimated construction cost.",
        ),
        "max_iterations" => Dict(
            "type" => "integer_or_null", "default" => 20, "range" => [1, 100],
            "guidance" => "Maximum column/beam sizing iterations. 20 is usually sufficient for regular buildings. Increase to 30-50 for irregular plans where load redistribution may need more iterations to converge.",
        ),
        "size_foundations" => Dict(
            "type" => "boolean", "default" => false,
            "guidance" => "When true, size spread/strip/mat foundations based on column reactions and soil properties.",
        ),
        "foundation_soil" => Dict(
            "type" => "string", "default" => "medium_sand",
            "depends_on" => Dict("size_foundations" => true),
            "guidance" => "Soil bearing class. medium_sand: qa ~4 ksf. stiff_clay: qa ~3 ksf. Affects footing sizes.",
        ),
        "foundation_concrete" => Dict(
            "type" => "string", "default" => "NWC_3000",
            "depends_on" => Dict("size_foundations" => true),
            "guidance" => "Foundation concrete. NWC_3000 (3 ksi) is standard for footings.",
        ),
        "foundation_options" => Dict(
            "type" => "object_or_null", "default" => "null",
            "depends_on" => Dict("size_foundations" => true),
            "fields" => Dict{String, Any}(
                "strategy" => Dict("type" => "enum", "default" => "auto",
                    "allowed" => collect(API_FOUNDATION_STRATEGIES),
                    "guidance" => "auto: engine picks spread/strip/mat based on coverage. all_spread: force isolated footings. mat: force mat foundation."),
                "mat_coverage_threshold" => Dict("type" => "number", "default" => 0.5, "range" => [0.0, 1.0],
                    "guidance" => "When auto strategy, switch from spread to mat when footing coverage > this fraction of plan area."),
            ),
        ),
        "geometry_is_centerline" => Dict(
            "type" => "boolean", "default" => false,
            "guidance" => "When false, vertices are architectural reference points and columns are offset inward. When true, vertices are structural centerlines — no offset is applied.",
        ),
        "skip_visualization" => Dict(
            "type" => "boolean", "default" => false,
            "guidance" => "Skip visualization mesh generation for faster response. Use when only structural data is needed.",
        ),
        "visualization_detail" => Dict(
            "type" => "enum", "default" => "full",
            "allowed" => collect(API_VISUALIZATION_DETAILS),
            "guidance" => "minimal: frame + slab boundaries only (fast). full: deflected meshes and per-face analytical values.",
        ),
        "pixelframe_options" => Dict(
            "type" => "object_or_null", "default" => "null",
            "depends_on" => Dict("column_type_or_beam_type" => "pixelframe"),
            "fields" => Dict(
                "fc_preset" => Dict("type" => "enum", "default" => "standard",
                    "allowed" => collect(API_PIXELFRAME_FC_PRESETS),
                    "guidance" => "Concrete strength range preset for PixelFrame optimization. standard covers typical 3D-printable mixes."),
            ),
            "guidance" => "PixelFrame options for 3D-printed concrete columns/beams. Only used when column_type or beam_type is pixelframe.",
        ),
    )
end

"""
    api_applicability_schema() -> Dict

Return a compact, machine-readable subset of `api_params_schema_structured()`
containing only method/floor compatibility and applicability rules. Intended for
LLM assistants that need fast eligibility checks without loading the full schema.
"""
function api_applicability_schema()
    s = api_params_schema_structured()

    floor_type = s["floor_type"]
    method = s["floor_options"]["fields"]["method"]

    return Dict{String, Any}(
        "version" => "v1",
        "source" => "api_params_schema_structured",
        "rules" => Dict{String, Any}(
            "floor_type" => Dict{String, Any}(
                "default" => floor_type["default"],
                "allowed" => floor_type["allowed"],
                "compatibility_checks" => floor_type["compatibility_checks"],
            ),
            "analysis_method" => Dict{String, Any}(
                "default" => method["default"],
                "allowed" => method["allowed"],
                "applicability_checks" => method["applicability_checks"],
            ),
        ),
    )
end

"""
    api_diagnose_schema() -> Dict

Return a compact, versioned contract for the `GET /diagnose` payload.
This describes the stable top-level sections and key per-element fields so
assistants/clients can validate presence and parse semantics.
"""
function api_diagnose_schema()
    return Dict{String, Any}(
        "version" => "v1",
        "endpoint" => "GET /diagnose",
        "description" => "High-resolution, machine-readable causal diagnostics for structural sizing decisions.",
        "top_level" => Dict{String, Any}(
            "status" => "string",
            "unit_system" => "enum(imperial|metric)",
            "length_unit" => "string",
            "thickness_unit" => "string",
            "force_unit" => "string",
            "moment_unit" => "string",
            "pressure_unit" => "string",
            "design_context" => "object",
            "agent_summary" => "object",
            "columns" => "array<object>",
            "beams" => "array<object>",
            "slabs" => "array<object>",
            "foundations" => "array<object>",
            "architectural" => "object",
            "constraints" => "object",
        ),
        "design_context" => Dict{String, Any}(
            "required_keys" => [
                "floor_type", "column_type", "beam_type",
                "analysis_method", "deflection_limit", "unit_system", "loads",
            ],
            "loads_keys" => ["floor_SDL", "floor_LL", "roof_SDL", "roof_LL", "unit"],
            "optional_keys" => ["punching_strategy", "punching_strategy_description"],
        ),
        "agent_summary" => Dict{String, Any}(
            "required_keys" => [
                "all_pass", "critical_element", "critical_ratio",
                "total_ec_kgco2e", "governing_check_distribution", "per_type",
            ],
            "distribution_item" => Dict("check" => "string", "count" => "int"),
        ),
        "element_contracts" => Dict{String, Any}(
            "common_required" => [
                "id", "governing_check", "governing_ratio",
                "governing_mode", "ok", "checks", "levers",
                "limit_state_description",
            ],
            "columns_required" => [
                "section", "shape", "Pu", "Mu_x", "Mu_y",
                "axial_ratio", "interaction_ratio", "ec_kgco2e",
            ],
            "beams_required" => [
                "section", "Mu", "Vu", "ec_kgco2e",
            ],
            "slabs_required" => [
                "thickness", "l1", "l2", "M0", "qu",
                "deflection", "deflection_limit", "deflection_unit", "ec_kgco2e",
            ],
            "foundations_required" => [
                "length", "width", "depth", "reaction",
            ],
            "check_required" => [
                "name", "code_clause", "ratio", "headroom", "governing",
            ],
            "check_optional" => [
                "demand", "capacity", "demand_unit", "capacity_phiVc",
                "demand_Mu_x", "demand_Mu_y", "demand_Vu", "demand_vu",
            ],
        ),
        "architectural" => Dict{String, Any}(
            "required_keys" => ["system_narrative", "scale_references", "goal_recommendations"],
        ),
        "constraints" => Dict{String, Any}(
            "required_keys" => ["fixed_by_geometry", "lever_impacts"],
        ),
        "notes" => [
            "All numeric values are emitted in the selected display unit system.",
            "Some fields (e.g., ec_kgco2e) may be null when unavailable.",
            "Keys are ASCII-only for robust machine parsing.",
        ],
    )
end

# ─── Input Schema ────────────────────────────────────────────────────────────
# Input structs are `mutable` so that StructTypes.Mutable() can construct them
# via the no-arg constructor and then set only the fields present in JSON.
# This lets missing JSON keys fall back to @kwdef defaults.

"""Raw edge groups from JSON: `{"beams": [[1,2],...], "columns": [[3,4],...], "braces": [...]}`."""
Base.@kwdef mutable struct APIEdgeGroups
    beams::Vector{Vector{Int}} = Vector{Int}[]
    columns::Vector{Vector{Int}} = Vector{Int}[]
    braces::Vector{Vector{Int}} = Vector{Int}[]
end

"""Raw face groups from JSON (optional). Keys are category names, values are
arrays of polylines (each polyline is an array of [x,y,z] arrays)."""
const APIFaceGroups = Dict{String, Vector{Vector{Vector{Float64}}}}

"""Raw load parameters from JSON."""
Base.@kwdef mutable struct APILoads
    floor_LL_psf::Float64 = 80.0
    roof_LL_psf::Union{Float64, Nothing} = nothing
    grade_LL_psf::Union{Float64, Nothing} = nothing
    floor_SDL_psf::Float64 = 15.0
    roof_SDL_psf::Float64 = 15.0
    wall_SDL_psf::Float64 = 10.0
end

"""Raw floor options from JSON."""
Base.@kwdef mutable struct APIFloorOptions
    method::String = "DDM"
    deflection_limit::String = "L_360"
    punching_strategy::String = "grow_columns"
    target_edge_m::Union{Float64, Nothing} = nothing  # FEA mesh target edge (m). Default: adaptive.
    vault_lambda::Union{Float64, Nothing} = nothing
end

"""Raw scoped floor options from JSON (subset used for face-scoped overrides)."""
Base.@kwdef mutable struct APIScopedFloorOptions
    method::String = "DDM"
    deflection_limit::String = "L_360"
    punching_strategy::String = "grow_columns"
    target_edge_m::Union{Float64, Nothing} = nothing
    concrete::Union{String, Nothing} = nothing
    vault_lambda::Union{Float64, Nothing} = nothing
end

"""Face-scoped override block from JSON."""
Base.@kwdef mutable struct APIScopedOverride
    floor_type::String = "vault"
    floor_options::APIScopedFloorOptions = APIScopedFloorOptions()
    faces::Vector{Vector{Vector{Float64}}} = Vector{Vector{Float64}}[]
end

"""Raw material selections from JSON."""
Base.@kwdef mutable struct APIMaterials
    concrete::String = "NWC_4000"           # Slab/floor concrete (default 4 ksi)
    column_concrete::String = "NWC_6000"   # Column concrete (default 6 ksi)
    rebar::String = "Rebar_60"
    steel::String = "A992"
end

# ─── Foundation options (optional overrides when size_foundations is true) ───
"""Optional spread footing params from JSON. All lengths in inches."""
Base.@kwdef mutable struct APISpreadParams
    cover_in::Union{Float64, Nothing} = nothing
    min_depth_in::Union{Float64, Nothing} = nothing
    bar_size::Union{Int, Nothing} = nothing
    depth_increment_in::Union{Float64, Nothing} = nothing
    size_increment_in::Union{Float64, Nothing} = nothing
end

"""Optional strip footing params from JSON. All lengths in inches."""
Base.@kwdef mutable struct APIStripParams
    cover_in::Union{Float64, Nothing} = nothing
    min_depth_in::Union{Float64, Nothing} = nothing
    bar_size_long::Union{Int, Nothing} = nothing
    bar_size_trans::Union{Int, Nothing} = nothing
    width_increment_in::Union{Float64, Nothing} = nothing
    max_depth_ratio::Union{Float64, Nothing} = nothing
    merge_gap_factor::Union{Float64, Nothing} = nothing
    eccentricity_limit::Union{Float64, Nothing} = nothing
end

"""Optional beam catalog bounds from JSON (used when beam_catalog is "custom"). All lengths in inches."""
Base.@kwdef mutable struct APIBeamCatalogBounds
    min_width_in::Float64 = 12.0
    max_width_in::Float64 = 36.0
    min_depth_in::Float64 = 18.0
    max_depth_in::Float64 = 48.0
    resolution_in::Float64 = 2.0
end

"""PixelFrame concrete strength options. Use fc_preset or (fc_min_ksi, fc_max_ksi, fc_resolution_ksi) when custom."""
Base.@kwdef mutable struct APIPixelFrameOptions
    fc_preset::String = "standard"  # standard | low | high | extended | custom
    fc_min_ksi::Union{Float64, Nothing} = nothing
    fc_max_ksi::Union{Float64, Nothing} = nothing
    fc_resolution_ksi::Union{Float64, Nothing} = nothing
end

"""Optional mat footing params from JSON. All lengths in inches."""
Base.@kwdef mutable struct APIMatParams
    cover_in::Union{Float64, Nothing} = nothing
    min_depth_in::Union{Float64, Nothing} = nothing
    bar_size_x::Union{Int, Nothing} = nothing
    bar_size_y::Union{Int, Nothing} = nothing
    depth_increment_in::Union{Float64, Nothing} = nothing
    edge_overhang_in::Union{Float64, Nothing} = nothing
    analysis_method::Union{String, Nothing} = nothing  # "rigid" | "shukla" | "winkler"
end

"""Optional foundation options from JSON (strategy + per-type overrides)."""
Base.@kwdef mutable struct APIFoundationOptions
    strategy::String = "auto"
    mat_coverage_threshold::Float64 = 0.5
    spread_params::Union{APISpreadParams, Nothing} = nothing
    strip_params::Union{APIStripParams, Nothing} = nothing
    mat_params::Union{APIMatParams, Nothing} = nothing
end

"""Design parameters block from JSON."""
Base.@kwdef mutable struct APIParams
    unit_system::String = "imperial"
    loads::APILoads = APILoads()
    floor_type::String = "flat_plate"
    floor_options::APIFloorOptions = APIFloorOptions()
    materials::APIMaterials = APIMaterials()
    column_type::String = "rc_rect"
    # Optional: when omitted or null, defaults depend on `column_type`:
    # - Steel (steel_w/steel_hss/steel_pipe): "preferred"
    # - RC rectangular (rc_rect): "standard"
    # - RC circular (rc_circular): "standard"
    # Ignored for pixelframe.
    column_catalog::Union{String, Nothing} = nothing
    column_sizing_strategy::String = "discrete"  # RC columns only: discrete | nlp
    mip_time_limit_sec::Union{Float64, Nothing} = nothing  # MIP time limit (s). Default: 30.
    beam_type::String = "steel_w"
    beam_catalog::String = "large"   # RC beam catalog: standard | small | large | xlarge | all | custom. Ignored for steel.
    beam_sizing_strategy::String = "discrete"  # RC beams only: discrete | nlp
    beam_catalog_bounds::Union{APIBeamCatalogBounds, Nothing} = nothing  # Required when beam_catalog is "custom".
    pixelframe_options::Union{APIPixelFrameOptions, Nothing} = nothing  # When column_type or beam_type is pixelframe.
    fire_rating::Float64 = 0.0
    optimize_for::String = "weight"
    max_iterations::Union{Int, Nothing} = nothing
    size_foundations::Bool = false
    foundation_soil::String = "medium_sand"
    foundation_concrete::String = "NWC_3000"
    foundation_options::Union{APIFoundationOptions, Nothing} = nothing
    scoped_overrides::Vector{APIScopedOverride} = APIScopedOverride[]
    geometry_is_centerline::Bool = false
    visualization_target_edge_m::Union{Float64, Nothing} = nothing  # Viz shell mesh target edge (m). Default: FEA or adaptive.
    skip_visualization::Bool = false  # Skip shell mesh + viz serialization for faster response.
    visualization_detail::String = "full"  # "minimal" | "full". minimal = no deflected slab meshes.
end

"""Top-level input payload from JSON."""
Base.@kwdef mutable struct APIInput
    units::String = ""
    vertices::Vector{Vector{Float64}} = Vector{Float64}[]
    edges::APIEdgeGroups = APIEdgeGroups()
    supports::Vector{Int} = Int[]
    stories_z::Vector{Float64} = Float64[]
    faces::APIFaceGroups = APIFaceGroups()
    params::APIParams = APIParams()
end

# ─── JSON3 StructType registrations ──────────────────────────────────────────
# Use Mutable() for input types so missing JSON keys use @kwdef defaults.

StructTypes.StructType(::Type{APIEdgeGroups}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APILoads}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIFloorOptions}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIScopedFloorOptions}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIScopedOverride}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIMaterials}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APISpreadParams}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIStripParams}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIMatParams}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIFoundationOptions}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIBeamCatalogBounds}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIPixelFrameOptions}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIParams}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIInput}) = StructTypes.Mutable()

# ─── Output Schema ───────────────────────────────────────────────────────────
# Output structs are immutable (write-only, never parsed from JSON).

"""Canonical failure reason codes for slab results."""
const API_SLAB_FAILURE_REASONS = (
    "non_convergence",
    "section_inadequate",
    "high_aspect_ratio",
    "ddm_ineligible",
    "applicability",
    "skeleton_build_failed",
    "solver_error",
    "unknown",
    "",
)

"""Canonical failing check codes for slab results."""
const API_SLAB_FAILING_CHECKS = (
    "punching_shear",
    "two_way_deflection",
    "two_way_deflection_secondary",
    "one_way_shear",
    "flexural_adequacy",
    "reinforcement_design",
    "reinforcement_design_secondary",
    "transfer_reinforcement",
    "column_pm",
    "applicability",
    "none",
    "",
)

"""
    _normalize_failure_reason(raw::String) -> String

Map a raw failure_reason string to a canonical enum token.
Joined multi-value strings, exception type names, and stack traces
are mapped to the closest canonical value.
"""
function _normalize_failure_reason(raw::String)
    isempty(raw) && return ""
    stripped = strip(raw)
    stripped in API_SLAB_FAILURE_REASONS && return stripped
    occursin("non_convergence", stripped) && return "non_convergence"
    occursin("section_inadequate", stripped) && return "section_inadequate"
    occursin("high_aspect_ratio", stripped) && return "high_aspect_ratio"
    occursin("ddm_ineligible", stripped) && return "ddm_ineligible"
    occursin("applicability", stripped) && return "applicability"
    occursin("skeleton_build_failed", stripped) && return "skeleton_build_failed"
    occursin("column_pm_infeasible", stripped) && return "section_inadequate"
    occursin("Error", stripped) || occursin("error", stripped) && return "solver_error"
    return "unknown"
end

"""
    _normalize_failing_checks(raw::String) -> Vector{String}

Parse a raw failing_check string into an array of canonical check codes.
Handles comma-separated values, single tokens, and stack trace fallback.
"""
function _normalize_failing_checks(raw::String)
    isempty(raw) && return String[]
    parts = [strip(p) for p in split(raw, r"[,;]")]
    result = String[]
    for part in parts
        isempty(part) && continue
        if part in API_SLAB_FAILING_CHECKS
            push!(result, part)
        elseif occursin("punching", part)
            push!(result, "punching_shear")
        elseif occursin("deflection", part)
            push!(result, "two_way_deflection")
        elseif occursin("shear", part)
            push!(result, "one_way_shear")
        elseif occursin("flexur", part)
            push!(result, "flexural_adequacy")
        elseif occursin("reinforcement", part)
            push!(result, "reinforcement_design")
        elseif occursin("transfer", part)
            push!(result, "transfer_reinforcement")
        elseif occursin("column_pm", part)
            push!(result, "column_pm")
        elseif occursin("applicability", part)
            push!(result, "applicability")
        else
            push!(result, part)
        end
    end
    return unique(result)
end

"""Slab result for JSON output."""
Base.@kwdef struct APISlabResult
    id::Int = 0
    ok::Bool = true
    thickness::Float64 = 0.0
    converged::Bool = true
    failure_reason::String = ""
    failing_checks::Vector{String} = String[]
    failure_detail::Union{String, Nothing} = nothing
    iterations::Int = 0
    deflection_ok::Bool = true
    deflection_ratio::Float64 = 0.0
    punching_ok::Bool = true
    punching_max_ratio::Float64 = 0.0
end

"""Canonical section type codes for column and beam results."""
const API_SECTION_TYPES = (
    "steel_w",
    "steel_hss_rect",
    "steel_hss_round",
    "rc_rect",
    "rc_circular",
    "rc_tbeam",
    "pixelframe",
    "other",
    "",
)

"""Column result for JSON output."""
Base.@kwdef struct APIColumnResult
    id::Int = 0
    section::String = ""
    section_type::String = ""
    c1::Float64 = 0.0
    c2::Float64 = 0.0
    shape::String = "rectangular"
    axial_ratio::Float64 = 0.0
    interaction_ratio::Float64 = 0.0
    ok::Bool = true
end

"""Beam result for JSON output."""
Base.@kwdef struct APIBeamResult
    id::Int = 0
    section::String = ""
    section_type::String = ""
    depth::Float64 = 0.0
    width::Float64 = 0.0
    flexure_ratio::Float64 = 0.0
    shear_ratio::Float64 = 0.0
    ok::Bool = true
end

"""Foundation result for JSON output."""
Base.@kwdef struct APIFoundationResult
    id::Int = 0
    length::Float64 = 0.0
    width::Float64 = 0.0
    depth::Float64 = 0.0
    bearing_ratio::Float64 = 0.0
    ok::Bool = true
end

"""Design summary for JSON output."""
Base.@kwdef struct APISummary
    all_pass::Bool = true
    concrete_volume::Float64 = 0.0
    steel_weight::Float64 = 0.0
    rebar_weight::Float64 = 0.0
    embodied_carbon_kgCO2e::Float64 = 0.0
    critical_ratio::Float64 = 0.0
    critical_element::String = ""
end

"""Error response payload."""
Base.@kwdef struct APIError
    status::String = "error"
    error::String = ""
    message::String = ""
    traceback::String = ""
end

# ─── Visualization Schema ────────────────────────────────────────────────────────

"""Node position and displacement from analysis model."""
Base.@kwdef struct APIVisualizationNode
    node_id::Int = 0              # 1-based node index in analysis model
    position::Vector{Float64} = [0.0, 0.0, 0.0]  # Original position [x, y, z] in display length units
    displacement::Vector{Float64} = [0.0, 0.0, 0.0]  # [dx, dy, dz] in display length units
    deflected_position::Vector{Float64} = [0.0, 0.0, 0.0]  # position + displacement in display length units
    is_support::Bool = false       # True if node corresponds to a structural support
end

"""Frame element with connectivity and design data."""
Base.@kwdef struct APIVisualizationFrameElement
    # For beams/columns: matches `columns[].id` / `beams[].id` in the design payload (skeleton member index).
    # For struts and unmapped edges: Asap analysis `elementID` (internal to the FE model).
    element_id::Int = 0
    node_start::Int = 0            # 1-based start node index
    node_end::Int = 0              # 1-based end node index
    element_type::String = ""     # "beam", "column", "strut", or "other"
    utilization_ratio::Float64 = 0.0
    ok::Bool = true
    section_name::String = ""      # e.g., "W14x90", "16x16"
    material_color_hex::String = "" # Optional material display color (e.g. "#6E6E6E")
    # Section geometry for rendering
    section_type::String = ""      # "W-shape", "rectangular", "HSS_rect", "HSS_round", etc.
    section_depth::Float64 = 0.0
    section_width::Float64 = 0.0
    # Additional dimensions for W-shapes
    flange_width::Float64 = 0.0
    web_thickness::Float64 = 0.0
    flange_thickness::Float64 = 0.0
    # Cross-section rotation about the element axis (radians, CCW from global X).
    # Non-zero for columns with θ ≠ 0; beams always 0.
    orientation_angle::Float64 = 0.0
    # 2D section polygon in local y-z coordinates (centroid at origin)
    # Each vertex is [y, z] in display length units, where y = width direction, z = depth direction
    section_polygon::Vector{Vector{Float64}} = []  # [[y1, z1], [y2, z2], ...]
    # Inner boundary for hollow sections (HSS rect/round); empty for solid sections
    section_polygon_inner::Vector{Vector{Float64}} = []  # [[y1, z1], [y2, z2], ...]
    # Interpolated deflected curve (cubic interpolation from FEA)
    original_points::Vector{Vector{Float64}} = []   # [[x,y,z], ...] original positions in display length units
    displacement_vectors::Vector{Vector{Float64}} = []  # [[dx,dy,dz], ...] displacements at each point in display length units
    # Analytical: signed extremum along element length (value with largest |·|, sign preserved)
    max_axial_force::Float64 = 0.0   # signed P extremum [N] (+ tension, − compression)
    max_moment::Float64 = 0.0        # signed M extremum [N·m] (largest |My| or |Mz|)
    max_shear::Float64 = 0.0         # signed V extremum [N] (largest |Vy| or |Vz|)
    # Sized mode: pre-built mesh for fast rendering (same pattern as deflected_slab_meshes).
    # Empty for hollow sections or when section polygon is invalid; client falls back to sweep.
    mesh_vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] in display length units
    mesh_faces::Vector{Vector{Int}} = []          # [[i1,i2,i3], ...] triangle indices (1-based)
end

"""Slab geometry for sized mode (3D boxes from cell boundaries)."""
Base.@kwdef struct APIDropPanelPatch
    center::Vector{Float64} = [0.0, 0.0, 0.0]  # [x,y,z_top] in display length units
    length::Float64 = 0.0  # full extent in local-x/global-x direction
    width::Float64 = 0.0   # full extent in local-y/global-y direction
    extra_depth::Float64 = 0.0  # projection below slab soffit
end

"""Slab geometry for sized mode (3D boxes from cell boundaries)."""
Base.@kwdef struct APISizedSlab
    slab_id::Int = 0
    boundary_vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] cell boundary vertices in display length units
    thickness::Float64 = 0.0
    z_top::Float64 = 0.0  # Top surface elevation
    drop_panels::Vector{APIDropPanelPatch} = []
    utilization_ratio::Float64 = 0.0
    ok::Bool = true
    material_color_hex::String = ""  # Display color from slab concrete material (e.g. "#B4B4B4")
    # Vault-specific curved mesh (intrados surface only, extrados = intrados + thickness)
    is_vault::Bool = false
    vault_mesh_vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] intrados surface
    vault_mesh_faces::Vector{Vector{Int}} = []         # [[i,j,k], ...] triangle indices (1-based)
end

"""
Drop panel sub-mesh for deflected mode.  Face indices reference into the parent
`APIDeflectedSlabMesh.faces` array (1-based).  The C# renderer builds the drop
panel volume by extracting these faces from the deflected slab mesh and offsetting
downward by `thickness` (top) and `thickness + extra_depth` (bottom).
"""
Base.@kwdef struct APIDeflectedDropPanel
    face_indices::Vector{Int} = []       # 1-based indices into parent faces array
    extra_depth::Float64 = 0.0           # projection below slab soffit (display units)
end

"""Slab mesh for deflected mode (analysis model triangulation)."""
Base.@kwdef struct APIDeflectedSlabMesh
    slab_id::Int = 0
    vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] original positions in display length units
    vertex_displacements::Vector{Vector{Float64}} = []  # [[dx,dy,dz], ...] displacements at each vertex in display length units
    vertex_displacements_local::Vector{Vector{Float64}} = []  # [[dx,dy,dz], ...] local-bending displacements in display length units
    faces::Vector{Vector{Int}} = []         # [[i1,i2,i3], ...] triangle indices (1-based)
    thickness::Float64 = 0.0
    drop_panels::Vector{APIDropPanelPatch} = []
    drop_panel_meshes::Vector{APIDeflectedDropPanel} = []
    utilization_ratio::Float64 = 0.0
    ok::Bool = true
    material_color_hex::String = ""  # Display color from slab concrete material (e.g. "#B4B4B4")
    is_vault::Bool = false  # For material coloring (earthen vs concrete)
    # Analytical: per-face scalar values for force/stress visualization (one per face, face order matches `faces`)
    # Signed quantities use diverging color (red + → white → blue −); von Mises/shear are always ≥ 0.
    face_bending_moment::Vector{Float64} = []   # signed dominant principal moment [N·m/m] (+ sagging, − hogging)
    face_membrane_force::Vector{Float64} = []   # signed dominant principal membrane force [N/m] (+ tension, − compression)
    face_shear_force::Vector{Float64} = []      # √(Qxz² + Qyz²) transverse shear resultant [N/m] (always ≥ 0)
    face_von_mises::Vector{Float64} = []        # max von Mises stress at top/bottom surface [Pa] (always ≥ 0)
    face_surface_stress::Vector{Float64} = []   # signed dominant principal stress at top/bottom [Pa] (+ tension, − compression)
end

"""Foundation geometry for visualization (axis-aligned block centered at support group centroid)."""
Base.@kwdef struct APIVisualizationFoundation
    foundation_id::Int = 0
    center::Vector{Float64} = [0.0, 0.0, 0.0]  # [x,y,z_top] in display length units
    length::Float64 = 0.0
    width::Float64 = 0.0
    depth::Float64 = 0.0
    utilization_ratio::Float64 = 0.0
    ok::Bool = true
    material_color_hex::String = ""  # Display color from foundation concrete material
    along_x::Bool = false  # true when strip long axis runs along X (swap length/width mapping)
end

"""Unit labels for visualization analytical fields.
Positions/displacements use the display length unit; analytical quantities use SI."""
Base.@kwdef struct APIVisualizationUnits
    position::String = "ft"
    displacement::String = "ft"
    force::String = "N"
    moment::String = "N_m"
    distributed_moment::String = "N_m_per_m"
    distributed_force::String = "N_per_m"
    stress::String = "Pa"
end

"""Complete visualization data from analysis model."""
Base.@kwdef struct APIVisualization
    nodes::Vector{APIVisualizationNode} = []
    frame_elements::Vector{APIVisualizationFrameElement} = []
    sized_slabs::Vector{APISizedSlab} = []
    deflected_slab_meshes::Vector{APIDeflectedSlabMesh} = []
    foundations::Vector{APIVisualizationFoundation} = []
    is_beamless_system::Bool = false
    suggested_scale_factor::Float64 = 1.0
    max_displacement::Float64 = 0.0
    # Global maxima for analytical color normalization (max |value| for diverging scale symmetry)
    max_frame_axial::Float64 = 0.0      # max |P| across all frame elements
    max_frame_moment::Float64 = 0.0     # max |M| across all frame elements
    max_frame_shear::Float64 = 0.0      # max |V| across all frame elements
    max_slab_bending::Float64 = 0.0     # max |principal moment| across all slab faces
    max_slab_membrane::Float64 = 0.0    # max |principal membrane force| across all faces
    max_slab_shear::Float64 = 0.0       # max transverse shear across all faces (>= 0)
    max_slab_von_mises::Float64 = 0.0   # max von Mises stress across all faces (>= 0)
    max_slab_surface_stress::Float64 = 0.0 # max |principal stress| across all faces
    units::APIVisualizationUnits = APIVisualizationUnits()
end

"""Top-level output payload."""
Base.@kwdef struct APIOutput
    status::String = "ok"
    compute_time_s::Float64 = 0.0
    phase_timings::Dict{String, Float64} = Dict{String, Float64}()
    length_unit::String = "ft"
    thickness_unit::String = "in"
    volume_unit::String = "ft3"
    mass_unit::String = "lb"
    summary::APISummary = APISummary()
    slabs::Vector{APISlabResult} = APISlabResult[]
    columns::Vector{APIColumnResult} = APIColumnResult[]
    beams::Vector{APIBeamResult} = APIBeamResult[]
    foundations::Vector{APIFoundationResult} = APIFoundationResult[]
    geometry_hash::String = ""
    visualization::Union{APIVisualization, Nothing} = nothing
end

StructTypes.StructType(::Type{APISlabResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIColumnResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIBeamResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIFoundationResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APISummary}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIOutput}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIError}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationNode}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationFrameElement}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIDropPanelPatch}) = StructTypes.Struct()
StructTypes.StructType(::Type{APISizedSlab}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIDeflectedSlabMesh}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationFoundation}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationUnits}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualization}) = StructTypes.Struct()