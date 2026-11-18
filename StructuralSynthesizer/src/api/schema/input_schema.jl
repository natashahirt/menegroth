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
            "description" => "Beam, column, brace, and wall connectivity.",
            "fields" => Dict(
                "beams" => "Array of [v1, v2] vertex index pairs (1-based).",
                "columns" => "Array of [v1, v2] vertex index pairs (1-based).",
                "braces" => "Array of [v1, v2] vertex index pairs (1-based).",
                "walls" => "Array of [v1, v2] vertex index pairs (1-based). Optional; omitted means no walls.",
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
        "openings" => Dict(
            "type" => "array of polylines [[x,y,z], ...]",
            "required" => false,
            "description" => "Optional unframed slab openings (stairs, ducts, shafts without beams on every side). " *
                             "The first vertex's z picks the story; repeat the polyline at each story it cuts. " *
                             "Openings framed by beams on every side should be left out of `faces` instead.",
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
                "uniform_column_sizing" => "$(join(API_UNIFORM_COLUMN_SIZING, " | ")). Default: off (independent sizing — lowest material / embodied carbon). per_story: all columns on a story match the governing size (constructability). building: single governing size for the whole structure.",
                "visualization_target_edge_m" => "Optional. Visualization shell mesh target edge (m). Default: inherits from FEA target_edge when method is FEA, else adaptive. Coarser = faster viz.",
                "skip_visualization" => "When true, skip shell mesh build and visualization serialization (faster response, frame-only). Default: false.",
                "visualization_detail" => "minimal | full. minimal = frame elements + slab boundaries only (no deflected meshes, no per-face analytical). full = full visualization. Default: full.",
                "scoped_overrides" => "Optional list of scoped floor overrides. Each override provides face polygons and floor-specific options applied only to matching cells.",
                "framing_levels" => "Optional array requesting auto-generated multi-level framing above each slab (Phase 5). Ordered from the slab outward (index 1 = joists, 2+ = secondary beams / girders). Each entry: material (\"steel\" | \"concrete\" | \"timber\"), spacing_in (optional c-to-c joist spacing, inches), role (\"joist\" | \"beam\", levels >= 2 only), axis ([x, y] joist run-direction; levels >= 2 default to mutually-perpendicular alternation), count (optional member count), end_fixity (optional 2-element per-end releases, e.g. [\"pinned\",\"pinned\"]), analysis (optional \"tributary\" | \"grillage\"; omitted means tributary, or grillage when n_xi/n_eta or module_spacing_in is set; any other value is an error), n_xi and n_eta (optional rib-bay counts, level 1 only, both required, each >= 1; a grillage on a panel that is not a quadrilateral errors before sizing), module_spacing_in (optional [s1, s2] rib spacings in inches, level 1 only: a module grid over any slab outline and its holes, cut by the boundary), module_angle_deg (optional direction of the first rib family in degrees, with module_spacing_in; default 0), solid_head (optional fraction of the panel from each corner, level 1 grillage with n_xi/n_eta only, in [0, 1/2), snapped up to a whole rib module). spacing_in, the bay counts, and module_spacing_in are mutually exclusive. Empty (default) = no auto-generated framing. Per-level sizing options are the Julia framing_opts beam_options field, not a wire key.",
                "materials" => Dict(
                    "concrete" => "Slab/floor concrete (e.g. NWC_4000, Earthen_500, Earthen_2000). Default: NWC_4000.",
                    "column_concrete" => "Column concrete (e.g. NWC_6000). Default: NWC_6000.",
                    "rebar" => "Rebar name (e.g. Rebar_60). Default: Rebar_60.",
                    "rebar_coating" => "uncoated, galvanized, epoxy, or zinc_epoxy. Default: uncoated.",
                    "steel" => "Steel name (e.g. A992). Default: A992.",
                ),
                "column_type" => "$(join(API_COLUMN_TYPES, " | ")). Default: rc_rect.",
                "column_catalog" => "Optional column catalog (string or null). Steel (steel_w/steel_hss/steel_pipe): compact_only | preferred | all. RC rectangular (rc_rect): standard | square | rectangular | low_capacity | high_capacity | all. RC circular (rc_circular): standard | low_capacity | high_capacity | all. Ignored for pixelframe. If omitted or null: defaults to preferred (steel) or standard (RC).",
                "column_sizing_strategy" => "discrete (catalog / MIP) or nlp (continuous Ipopt). Default: discrete. Applies to RC and steel columns.",
                "mip_time_limit_sec" => "MIP solver time limit (seconds) when discrete sizing. Default: 30.",
                "beam_type" => "$(join(API_BEAM_TYPES, " | ")). Default: steel_w.",
                "beam_catalog" => "RC beam catalog when beam_type is rc_rect or rc_tbeam: $(join(API_BEAM_CATALOGS, " | ")). Default: large. Use xlarge for vaults with high thrust. Use custom with beam_catalog_bounds for bounds-based catalog. Ignored for pixelframe.",
                "beam_sizing_strategy" => "discrete (catalog / MIP) or nlp (continuous Ipopt). Default: discrete. NLP applies only to non-composite steel W/HSS beams; RC, PixelFrame, and composite beams require discrete sizing.",
                "composite" => "Boolean. Composite steel beam design (AISC 360 Chapter I). Default: false. Stud: give composite_anchor_d_in, composite_anchor_length_in, and composite_anchor_Fu_ksi together, or omit all three for the default 3/4 in stud with Fu = 65 ksi (AISC Manual 14th ed., ASTM A108 Type B). Thickness and concrete are read from the sized slab unless composite_t_slab_in is set.",
                "composite_slab_type" => "solid or deck. Default: solid. deck also requires composite_deck_hr_in and composite_deck_wr_in.",
                "composite_t_slab_in" => "Optional slab thickness override, inches. Omit to use the sized slab.",
                "composite_anchor_d_in" => "Stud shank diameter, inches. Omit all three stud fields for the default stud.",
                "composite_anchor_length_in" => "Stud length after installation, inches. Omit all three stud fields for the default stud.",
                "composite_anchor_Fu_ksi" => "Stud tensile strength Fu, ksi. Omit all three stud fields for the default stud.",
                "composite_shored" => "Boolean. true skips the pre-cure steel check. Default: false (unshored).",
                "composite_cp_class" => "SEI/ASCE 37-02 personnel class: very_light, light, medium, or heavy. Default: medium.",
                "composite_deck_hr_in" => "Deck rib height, inches. Required when composite_slab_type is deck.",
                "composite_deck_wr_in" => "Average deck rib width, inches. Required when composite_slab_type is deck.",
                "composite_deck_orientation" => "from_slab, perpendicular, or parallel. from_slab reads each beam's rib angle from the slab span axis; skewed ribs use the perpendicular stud rules. Default: from_slab.",
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

