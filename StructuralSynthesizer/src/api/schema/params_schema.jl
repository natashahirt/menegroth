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
                    "guidance" => "DDM/DDM_SIMPLIFIED (ACI 318-11 §13.6; = 318-19 §8.10 — checks as implemented): requires rectangular panel geometry, aspect ratio 0.5<=l2/l1<=2.0 (§13.6.1.2), L/D<=2.0 using estimated self-weight (§13.6.1.5), and adequate continuous spans/column lines (>=3 spans target; warning/violation when insufficient, §13.6.1.1). Additional implemented checks include adjacent-span variation <=1/3 when adjacency data exists (§13.6.1.3), column offset <=10% of span from column lines (§13.6.1.4), and practical clear-span minimum ln>=4 ft. EFM/EFM_HARDY_CROSS (ACI 318-11 §13.7 / §8.11 checks as implemented): still requires rectangular/orthogonal panel geometry for frame idealization (§8.11.2), gravity-load framing assumptions (§8.11.1.1), at least two supporting columns, and column-size limits for torsional-stiffness formulation (§8.11.5, c2/l2<=0.5 check). FEA: shell analysis is the most general and allowed for irregular geometry; however, if design_approach=:frame, post-processing uses ACI §13.6.4/.6-style column-/middle-strip fractions and emits warnings when DDM regularity checks fail. Use FEA for non-rectangular panels, setbacks, or free-form column layouts.",
                    "applicability_checks" => Dict{String, Any}(
                        "implemented_in" => Dict(
                            "DDM" => "StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/ddm.jl",
                            "EFM" => "StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/efm.jl",
                            "FEA" => "StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/helpers.jl",
                        ),
                        "DDM" => Dict{String, Any}(
                            "code_basis" => "ACI 318-11 §13.6 (= 318-19 §8.10) (implemented checks)",
                            "hard_checks" => Any[
                                Dict("id" => "ddm_rectangular_geometry", "clause" => "§13.6.1.2", "check" => "panel geometry rectangular/orthogonal"),
                                Dict("id" => "ddm_aspect_ratio", "clause" => "§13.6.1.2", "check" => "0.5 <= l2/l1 <= 2.0"),
                                Dict("id" => "ddm_live_dead_ratio", "clause" => "§13.6.1.5", "check" => "L/D <= 2.0 using estimated self-weight"),
                                Dict("id" => "ddm_min_clear_span", "clause" => "implementation guardrail", "check" => "clear span ln >= 4 ft"),
                            ],
                            "context_checks" => Any[
                                Dict("id" => "ddm_min_span_continuity", "clause" => "§13.6.1.1", "check" => ">=3 continuous spans target (column-line adequacy check)"),
                                Dict("id" => "ddm_successive_span_variation", "clause" => "§13.6.1.3", "check" => "adjacent span difference <= longer span / 3", "applies_when" => "adjacent slab metadata available"),
                                Dict("id" => "ddm_column_offset", "clause" => "§13.6.1.4", "check" => "column offset <= 10% of span from column lines", "applies_when" => "column coordinates resolvable"),
                            ],
                            "loads_assumption" => Dict("clause" => "§13.6.1.5", "assumption" => "gravity/uniform slab loading model in current workflow"),
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
                                    "clause" => "ACI §13.6.4/.6 style CS/MS fraction use in implementation",
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
                    "guidance" => "grow_columns: increase column dimensions to enlarge critical perimeter b₀ — most reliable punching fix (preferred). " *
                                 "reinforce_first: add shear studs/stirrups before growing columns — columns stay at P-M minimum (may be smaller than grow_columns would produce). " *
                                 "reinforce_last: grow first, add reinforcement only if growth alone is insufficient. " *
                                 "For irregular plans with non-uniform tributary areas, punching demands vary — review at re-entrant corners and edge columns."),
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
            "guidance" => "NLP is supported only for non-composite steel W/HSS beams. RC, PixelFrame, and composite beams require discrete sizing.",
        ),
        "composite" => Dict(
            "type" => "boolean", "default" => false,
            "guidance" => "Composite steel beams (AISC 360 Chapter I). Requires the stud diameter, length, and Fu. Thickness and concrete come from the sized slab unless overridden.",
        ),
        "composite_slab_type" => Dict(
            "type" => "enum", "default" => "solid",
            "allowed" => ["solid", "deck"],
            "guidance" => "solid, or deck. Deck also requires rib height and rib width.",
        ),
        "composite_t_slab_in" => Dict(
            "type" => "number_or_null", "default" => "null", "unit" => "in",
            "guidance" => "Slab thickness override. Omit to use the sized slab.",
        ),
        "composite_anchor_d_in" => Dict(
            "type" => "number_or_null", "default" => "null", "unit" => "in",
            "guidance" => "Stud shank diameter. Omit all three stud fields for the default 3/4 in stud.",
        ),
        "composite_anchor_length_in" => Dict(
            "type" => "number_or_null", "default" => "null", "unit" => "in",
            "guidance" => "Stud length after installation. Omit all three stud fields for the default stud.",
        ),
        "composite_anchor_Fu_ksi" => Dict(
            "type" => "number_or_null", "default" => "null", "unit" => "ksi",
            "guidance" => "Stud tensile strength Fu. Omit all three stud fields for the default 65 ksi stud.",
        ),
        "composite_shored" => Dict(
            "type" => "boolean", "default" => false,
            "guidance" => "true skips the pre-cure steel check. Default is unshored.",
        ),
        "composite_cp_class" => Dict(
            "type" => "enum", "default" => "medium",
            "allowed" => ["very_light", "light", "medium", "heavy"],
            "guidance" => "SEI/ASCE 37-02 personnel and equipment class for the pre-cure load.",
        ),
        "composite_deck_hr_in" => Dict(
            "type" => "number_or_null", "default" => "null", "unit" => "in",
            "guidance" => "Deck rib height. Required when composite_slab_type is deck.",
        ),
        "composite_deck_wr_in" => Dict(
            "type" => "number_or_null", "default" => "null", "unit" => "in",
            "guidance" => "Average deck rib width. Required when composite_slab_type is deck.",
        ),
        "composite_deck_orientation" => Dict(
            "type" => "enum", "default" => "from_slab",
            "allowed" => ["from_slab", "perpendicular", "parallel"],
            "guidance" => "Deck ribs relative to the beam. from_slab reads each beam's angle from the slab span axis; perpendicular or parallel asserts it for every beam.",
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
        "uniform_column_sizing" => Dict(
            "type" => "enum", "default" => "off",
            "allowed" => collect(API_UNIFORM_COLUMN_SIZING),
            "guidance" => "off: each column sized independently (default) — minimises material by right-sizing each column to its own demand; " *
                         "this is an effective embodied-carbon reduction strategy because uniform sizing promotes every column to the governing (largest) size, " *
                         "adding unnecessary concrete/steel to lightly-loaded columns. " *
                         "per_story: all columns on the same story use the governing (largest) size — common for constructability and formwork reuse. " *
                         "building: every column in the structure matches the single governing size — simplest to construct but highest material use. " *
                         "Harmonization is conservative (bigger column only improves capacity). " *
                         "Not supported for pixelframe columns.",
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
    _parameter_space_card() -> String

Generate a compact, plain-text summary of the solver's parameter space from
`api_params_schema_structured()`.  Injected into the LLM system prompt so the
model sees every valid enum, default, numeric range, and compatibility rule
**before** it generates any recommendations.  This is the single source of
truth — hand-written capability lists are no longer needed.
"""
function _parameter_space_card()::String
    s = api_params_schema_structured()

    function _enum_line(label::String, spec::Dict)
        allowed = get(spec, "allowed", nothing)
        isnothing(allowed) && return ""
        default = get(spec, "default", nothing)
        vals = if allowed isa Dict
            unique(vcat(values(allowed)...))
        else
            collect(allowed)
        end
        parts = [isnothing(default) || v != string(default) ? string(v) : "$(v)*" for v in vals]
        "  $label: $(join(parts, " | "))"
    end

    function _num_line(label::String, spec::Dict)
        rng = get(spec, "range", nothing)
        isnothing(rng) && return ""
        unit = get(spec, "unit", "")
        default = get(spec, "default", nothing)
        def_str = isnothing(default) ? "" : " (default $(default))"
        unit_str = isempty(unit) ? "" : " $unit"
        "  $label: [$(rng[1])–$(rng[2])]$unit_str$def_str"
    end

    lines = String["PARAMETER SPACE (authoritative — recommend ONLY values from this card):"]

    push!(lines, _enum_line("floor_type", s["floor_type"]))
    push!(lines, _enum_line("column_type", s["column_type"]))
    push!(lines, _enum_line("beam_type", s["beam_type"]))

    fo = get(s, "floor_options", Dict())
    ff = get(fo, "fields", Dict())
    haskey(ff, "method")           && push!(lines, _enum_line("method", ff["method"]))
    haskey(ff, "deflection_limit") && push!(lines, _enum_line("deflection_limit", ff["deflection_limit"]))
    haskey(ff, "punching_strategy") && push!(lines, _enum_line("punching_strategy", ff["punching_strategy"]))

    push!(lines, _enum_line("optimize_for", s["optimize_for"]))

    haskey(s, "column_sizing_strategy") && push!(lines, _enum_line("column_sizing_strategy", s["column_sizing_strategy"]))
    haskey(s, "beam_sizing_strategy")   && push!(lines, _enum_line("beam_sizing_strategy", s["beam_sizing_strategy"]))

    col_cat = get(s, "column_catalog", Dict())
    col_cat_allowed = get(col_cat, "allowed", nothing)
    if col_cat_allowed isa Dict
        cat_vals = sort(unique(vcat(values(col_cat_allowed)...)))
        push!(lines, "  column_catalog: $(join(cat_vals, " | "))  (varies by column_type; null = auto)")
    end
    haskey(s, "beam_catalog") && push!(lines, _enum_line("beam_catalog", s["beam_catalog"]))

    fo2 = get(s, "foundation_options", Dict())
    ff2 = get(fo2, "fields", Dict())
    haskey(ff2, "strategy") && push!(lines, _enum_line("foundation_strategy", ff2["strategy"]))

    fr = get(s, "fire_rating", Dict())
    fr_allowed = get(fr, "allowed", nothing)
    if !isnothing(fr_allowed)
        fr_def = get(fr, "default", nothing)
        fr_parts = [v == fr_def ? "$(v)*" : "$(v)" for v in fr_allowed]
        push!(lines, "  fire_rating: $(join(fr_parts, " | "))  (hours)")
    end

    loads = get(s, "loads", Dict())
    load_fields = get(loads, "fields", Dict())
    load_items = String[]
    for (k, spec) in sort(collect(load_fields); by=first)
        rng = get(spec, "range", nothing)
        isnothing(rng) && continue
        unit = get(spec, "unit", "")
        push!(load_items, "$k [$(rng[1])–$(rng[2])] $unit")
    end
    !isempty(load_items) && push!(lines, "  loads: $(join(load_items, ", "))")

    mats = get(s, "materials", Dict())
    mat_fields = get(mats, "fields", Dict())
    mat_items = String[]
    for (k, spec) in sort(collect(mat_fields); by=first)
        def = get(spec, "default", "")
        push!(mat_items, "$k ($def*)")
    end
    !isempty(mat_items) && push!(lines, "  materials: $(join(mat_items, ", "))")

    push!(lines, "  (* = default)")

    # Compatibility rules from floor_type schema
    push!(lines, "COMPATIBILITY:")
    compat = get(get(s, "floor_type", Dict()), "compatibility_checks", nothing)
    if !isnothing(compat)
        for rule in get(compat, "rules", Any[])
            when_clause = get(rule, "when", Dict())
            requires    = get(rule, "requires", Dict())
            when_ft     = get(when_clause, "floor_type", nothing)
            ft_str = when_ft isa Vector ? join(when_ft, "/") : string(something(when_ft, "?"))
            req_parts = String[]
            for (param, vals) in requires
                vstr = vals isa Vector ? join(vals, " | ") : string(vals)
                push!(req_parts, "$param must be $vstr")
            end
            push!(lines, "  $ft_str -> $(join(req_parts, "; "))")
        end
    end

    push!(lines, "SCOPE BOUNDARY:")
    push!(lines, "  Gravity loads only. Systems not listed above do not exist in the solver.")
    push!(lines, "  If asked about PT, composite deck, voided/bubble/waffle slabs, timber, CLT, modular: say unsupported, redirect to closest option above.")

    return join(lines, "\n")
end

