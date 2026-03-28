# =============================================================================
# Tool Registry — structured metadata for agent tools + implemented provisions
#
# TOOL_REGISTRY: each entry has name, description, phase, use_when, args,
# returns, requires_design, requires_geometry. The LLM reads `use_when` to
# self-select the right tool.
#
# IMPLEMENTED_PROVISIONS: machine-readable index of every design code clause
# the solver implements. Sourced from docs/src/reference/design_codes.md.
# =============================================================================

# ─── Implemented Provisions ───────────────────────────────────────────────────

const IMPLEMENTED_PROVISIONS = Dict{String, Any}(
    "AISC_360_16" => [
        Dict("section" => "D2",        "provision" => "Tensile yielding and rupture"),
        Dict("section" => "E3",        "provision" => "Flexural buckling without slender elements"),
        Dict("section" => "E7",        "provision" => "Members with slender elements"),
        Dict("section" => "F2",        "provision" => "Doubly symmetric compact I-shapes — yielding and LTB"),
        Dict("section" => "F3",        "provision" => "Doubly symmetric I-shapes with compact webs, noncompact flanges"),
        Dict("section" => "F4",        "provision" => "Other I-shaped members with compact or noncompact webs"),
        Dict("section" => "F5",        "provision" => "Doubly/singly symmetric I-shapes with slender webs"),
        Dict("section" => "F6",        "provision" => "I-shaped members bent about minor axis"),
        Dict("section" => "F7",        "provision" => "Square and rectangular HSS — flexure"),
        Dict("section" => "F8",        "provision" => "Round HSS — flexure"),
        Dict("section" => "G2",        "provision" => "I-shaped members — shear in web"),
        Dict("section" => "G4",        "provision" => "Rectangular HSS — shear"),
        Dict("section" => "G5",        "provision" => "Round HSS — shear"),
        Dict("section" => "G6",        "provision" => "Weak axis shear"),
        Dict("section" => "H1",        "provision" => "Combined forces — doubly and singly symmetric members"),
        Dict("section" => "H1.1",      "provision" => "P-M interaction (Eq. H1-1a, H1-1b)"),
        Dict("section" => "C2",        "provision" => "Amplified first-order analysis (B1, B2)"),
        Dict("section" => "DG9",       "provision" => "Torsional analysis of structural steel members"),
        Dict("section" => "I3.1a",     "provision" => "Composite beam — effective width"),
        Dict("section" => "I3.1b",     "provision" => "Composite beam — construction strength"),
        Dict("section" => "I3.2a",     "provision" => "Composite beam — positive flexural strength (plastic)"),
        Dict("section" => "I3.2b",     "provision" => "Composite beam — negative moment capacity"),
        Dict("section" => "I3.2c",     "provision" => "Formed metal deck — Rg/Rp factors"),
        Dict("section" => "I3.2d",     "provision" => "Composite beam — compression force Cf"),
        Dict("section" => "I8.1",      "provision" => "Stud diameter limit"),
        Dict("section" => "I8.2a",     "provision" => "Headed stud anchors — shear connector strength"),
        Dict("section" => "I8.2d",     "provision" => "Stud spacing limits"),
        Dict("section" => "C-I3.2",    "provision" => "Transformed I, lower-bound I_LB"),
        Dict("section" => "DG19",      "provision" => "Fire resistance of structural steel framing"),
    ],
    "ACI_318" => [
        Dict("section" => "6.6",       "provision" => "Second-order analysis"),
        Dict("section" => "6.6.4.4.4", "provision" => "Stiffness reduction for stability"),
        Dict("section" => "6.6.4.6.2", "provision" => "Drift limit for moment magnifier"),
        Dict("section" => "7.12.2.1",  "provision" => "Minimum shrinkage and temperature reinforcement"),
        Dict("section" => "8.4.2.3",   "provision" => "Transfer reinforcement"),
        Dict("section" => "8.6.1",     "provision" => "One-way slab minimum thickness"),
        Dict("section" => "8.7.4",     "provision" => "Structural integrity reinforcement"),
        Dict("section" => "8.7.4.2",   "provision" => "Integrity rebar at columns"),
        Dict("section" => "8.10.4",    "provision" => "T-beam flange width"),
        Dict("section" => "8.12.2",    "provision" => "Effective flange width for T-beams"),
        Dict("section" => "9.3.2",     "provision" => "Strength reduction factors"),
        Dict("section" => "9.5",       "provision" => "Beam flexure — required strength"),
        Dict("section" => "9.5(a)",    "provision" => "Minimum thickness table — beams"),
        Dict("section" => "9.5(c)",    "provision" => "Minimum thickness table — one-way slabs"),
        Dict("section" => "9.5.3.2",   "provision" => "Immediate deflection (Branson)"),
        Dict("section" => "9.5.3.3",   "provision" => "Long-term deflection multiplier"),
        Dict("section" => "9.8",       "provision" => "Two-way slab minimum thickness"),
        Dict("section" => "10.2",      "provision" => "Whitney rectangular stress block"),
        Dict("section" => "10.3.6.2",  "provision" => "Column axial capacity"),
        Dict("section" => "10.10",     "provision" => "Slenderness effects in compression members"),
        Dict("section" => "10.10.4.1", "provision" => "Moment of inertia reduction factors"),
        Dict("section" => "10.10.7",   "provision" => "Sway magnification factor"),
        Dict("section" => "11.2.1.1",  "provision" => "Concrete shear strength Vc"),
        Dict("section" => "11.4",      "provision" => "Shear reinforcement (Vs)"),
        Dict("section" => "11.11",     "provision" => "Two-way shear (punching) provisions"),
        Dict("section" => "11.11.1.2", "provision" => "Critical section for punching shear"),
        Dict("section" => "11.11.3",   "provision" => "Punching shear strength Vc"),
        Dict("section" => "11.11.3.2", "provision" => "Punching shear with moment transfer"),
        Dict("section" => "11.11.5",   "provision" => "Shear stud reinforcement"),
        Dict("section" => "11.11.5.1", "provision" => "Stud layout requirements"),
        Dict("section" => "11.11.5.2", "provision" => "Stud capacity"),
        Dict("section" => "11.11.5.4", "provision" => "Maximum spacing of studs"),
        Dict("section" => "12.13",     "provision" => "Development of reinforcement"),
        Dict("section" => "13.1.2",    "provision" => "Two-way slab applicability limits"),
        Dict("section" => "13.2",      "provision" => "Column strip, middle strip, panel definitions"),
        Dict("section" => "13.3",      "provision" => "Slab reinforcement limits"),
        Dict("section" => "13.5.3",    "provision" => "Moment transfer at columns"),
        Dict("section" => "13.6",      "provision" => "Direct Design Method (DDM)"),
        Dict("section" => "13.6.2.2",  "provision" => "DDM limitations"),
        Dict("section" => "13.6.3",    "provision" => "DDM total static moment Mo"),
        Dict("section" => "13.6.4",    "provision" => "DDM moment distribution to strips"),
        Dict("section" => "13.7",      "provision" => "Equivalent Frame Method (EFM)"),
        Dict("section" => "13.7.3",    "provision" => "EFM slab-beam stiffness"),
        Dict("section" => "13.7.4",    "provision" => "EFM column stiffness"),
        Dict("section" => "13.7.5",    "provision" => "EFM equivalent column stiffness (torsional members)"),
        Dict("section" => "13.7.6",    "provision" => "EFM loading and analysis"),
        Dict("section" => "13.7.6.2",  "provision" => "Pattern loading threshold (L/D)"),
        Dict("section" => "13.7.7.1",  "provision" => "EFM moment redistribution"),
        Dict("section" => "22.4",      "provision" => "Column P-M interaction"),
        Dict("section" => "22.5",      "provision" => "Shear strength"),
        Dict("section" => "22.5.6.1",  "provision" => "Vc with axial compression"),
        Dict("section" => "22.6",      "provision" => "Punching shear"),
        Dict("section" => "22.7",      "provision" => "Torsion"),
        Dict("section" => "24.2",      "provision" => "Deflection control"),
        Dict("section" => "T7.3.1.1",  "provision" => "Minimum slab thickness table"),
        Dict("section" => "T9.5(a)",   "provision" => "Minimum beam depth table"),
    ],
    "ACI_216_1" => [
        Dict("section" => "T4.2",      "provision" => "Minimum slab thickness for fire rating"),
        Dict("section" => "T4.3.1.1",  "provision" => "Minimum slab cover for fire rating"),
        Dict("section" => "T4.3.1.2",  "provision" => "Minimum beam cover for fire rating"),
        Dict("section" => "T4.5.1a",   "provision" => "Minimum column dimension for fire rating"),
        Dict("section" => "4.5.3",     "provision" => "Column cover for fire rating"),
    ],
    "ACI_336_2R" => [
        Dict("section" => "3.3.2",     "provision" => "Mat bearing pressure distribution"),
        Dict("section" => "4.2",       "provision" => "Allowable bearing pressure"),
        Dict("section" => "6.1.2",     "provision" => "Flexural design of mat"),
        Dict("section" => "6.4",       "provision" => "Punching shear for mat"),
        Dict("section" => "6.7",       "provision" => "One-way shear for mat"),
        Dict("section" => "6.9",       "provision" => "Minimum mat thickness"),
    ],
    "ASCE_7" => [
        Dict("section" => "2.3.1",     "provision" => "LRFD load combinations"),
    ],
    "UL" => [
        Dict("section" => "X772",      "provision" => "SFRM thickness for steel members"),
        Dict("section" => "N643",      "provision" => "Intumescent coating thickness"),
    ],
    "fib_MC2010" => [
        Dict("section" => "5.6.3",     "provision" => "Residual strength parameters (fR1, fR3 from CMOD)"),
        Dict("section" => "5.6.4",     "provision" => "Linear model for ultimate fiber tensile strength"),
        Dict("section" => "7.7.3.2.2", "provision" => "FRC shear capacity"),
    ],
    "NDS_2018" => [
        Dict("section" => "general",   "provision" => "Timber member design (GLT, LVL) — stub"),
        Dict("section" => "T4A_4B",    "provision" => "Reference design values — stub"),
    ],
)

"""
    get_provisions(; code::Union{String, Nothing}=nothing) -> Dict

Return implemented provisions, optionally filtered by code name.
"""
function get_provisions(; code::Union{String, Nothing}=nothing)
    if isnothing(code)
        return IMPLEMENTED_PROVISIONS
    end
    key = uppercase(replace(code, " " => "_", "-" => "_", "." => "_"))
    for k in keys(IMPLEMENTED_PROVISIONS)
        if uppercase(k) == key
            return Dict{String, Any}(k => IMPLEMENTED_PROVISIONS[k])
        end
    end
    return Dict{String, Any}(
        "error" => "unknown_code",
        "message" => "Code \"$code\" not found. Available: $(join(keys(IMPLEMENTED_PROVISIONS), ", ")).",
    )
end

# ─── Lever Surface Map ─────────────────────────────────────────────────────────
#
# Canonical mapping: failure check name → actionable parameters (levers).
# The LLM consults this instead of guessing which parameter affects which check.
# Each entry lists API-level parameters and, where applicable, geometric changes
# (prefixed with "geometry:") that require Grasshopper modification.

const LEVER_SURFACE_MAP = Dict{String, Any}(
    "punching_shear" => Dict(
        "parameters" => ["punching_strategy", "column_concrete", "floor_type"],
        "geometry"   => ["column_size", "slab_span"],
        "direction"  => "grow_columns or reinforce_first reduces demand/capacity ratio; higher f'c increases Vc",
    ),
    "flexure" => Dict(
        "parameters" => ["deflection_limit", "floor_type", "concrete", "rebar"],
        "geometry"   => ["span_length"],
        "direction"  => "thicker slab or higher rebar grade increases capacity; shorter spans reduce demand",
    ),
    "deflection" => Dict(
        "parameters" => ["deflection_limit", "concrete", "floor_type"],
        "geometry"   => ["span_length"],
        "direction"  => "relaxing L/360→L/240 allows thinner slabs; higher f'c increases Ec and reduces deflection",
    ),
    "one_way_shear" => Dict(
        "parameters" => ["concrete", "floor_type"],
        "geometry"   => ["span_length"],
        "direction"  => "thicker slab increases Vc; shorter spans reduce Vu",
    ),
    "P-M_interaction" => Dict(
        "parameters" => ["column_catalog", "column_concrete", "column_type", "column_sizing_strategy"],
        "geometry"   => ["column_count", "story_height"],
        "direction"  => "larger catalog pool or higher f'c increases capacity; more columns redistribute load",
    ),
    "axial_capacity" => Dict(
        "parameters" => ["column_catalog", "column_concrete", "column_type"],
        "geometry"   => ["column_count"],
        "direction"  => "upsizing catalog or increasing f'c increases φPn",
    ),
    "combined_forces" => Dict(
        "parameters" => ["beam_catalog", "beam_type", "beam_sizing_strategy"],
        "geometry"   => ["span_length", "beam_spacing"],
        "direction"  => "larger beam catalog or deeper sections increase capacity",
    ),
    "shear" => Dict(
        "parameters" => ["beam_catalog", "beam_type"],
        "geometry"   => ["span_length"],
        "direction"  => "deeper beams increase Vn; shorter spans reduce Vu",
    ),
    "LTB" => Dict(
        "parameters" => ["beam_catalog", "beam_type"],
        "geometry"   => ["unbraced_length"],
        "direction"  => "shorter unbraced lengths or stockier sections increase LTB capacity",
    ),
    "fire_protection" => Dict(
        "parameters" => ["fire_rating"],
        "geometry"   => [],
        "direction"  => "reducing fire_rating reduces required concrete cover and steel protection thickness",
    ),
    "foundation_bearing" => Dict(
        "parameters" => ["foundation_soil", "foundation_concrete", "foundation_options"],
        "geometry"   => ["column_count"],
        "direction"  => "stiffer soil or larger footings increase bearing capacity",
    ),
    "convergence" => Dict(
        "parameters" => ["max_iterations", "mip_time_limit_sec", "column_sizing_strategy"],
        "geometry"   => [],
        "direction"  => "more iterations or longer MIP time allows optimizer to find feasible assignment",
    ),
)

"""
    get_lever_map(; check::Union{String, Nothing}=nothing) -> Dict

Return the lever surface map, optionally filtered to a single check family.
"""
function get_lever_map(; check::Union{String, Nothing}=nothing)
    if isnothing(check)
        return LEVER_SURFACE_MAP
    end
    key = lowercase(replace(check, " " => "_", "-" => "_"))
    for k in keys(LEVER_SURFACE_MAP)
        if lowercase(k) == key
            return Dict{String, Any}(k => LEVER_SURFACE_MAP[k])
        end
    end
    return Dict{String, Any}(
        "error"     => "unknown_check",
        "message"   => "Check \"$check\" not found. Available: $(join(sort(collect(keys(LEVER_SURFACE_MAP))), ", ")).",
        "available" => sort(collect(keys(LEVER_SURFACE_MAP))),
    )
end

# ─── Tool Registry ────────────────────────────────────────────────────────────

const TOOL_REGISTRY = [
    Dict{String, Any}(
        "name"              => "get_situation_card",
        "description"       => "Single-call orientation snapshot: geometry overview (from server cache when POST /design has run), resolved params, results health, session history, trace availability. When has_geometry is false, geometry_availability explains that BUILDING GEOMETRY text in the chat prompt may still describe the model for qualitative use.",
        "phase"             => "orientation",
        "use_when"          => "FIRST tool call in any conversation. Gives complete orientation in one call instead of three. Also useful after a design run to refresh context.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with has_geometry, has_design, geometry (summary), params, health (pass/fail, critical ratio, n_failing, EC), session (n_designs, can_compare_deltas if ≥2 designs), has_trace.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_building_summary",
        "description"       => "Geometry summary: stories, counts, beam span_stats (all frame edges — not slab cells), span_diversity, slab_panel_plan from slab face outlines in plan (quad corner deviation from 90°, panel aspect ratios, plan_shape_classification), regularity (story heights). span_cv_note ties the two: beam CV ≠ plan irregularity.",
        "phase"             => "orientation",
        "use_when"          => "You need geometry details not covered by get_situation_card, or no design exists yet.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with counts, span_stats (basis=beam_frame_edges), span_diversity, slab_panel_plan?, floor_system? (floor_type + plain-english description when a design exists in server cache), span_cv_note, regularity, structural_flags.",
        "requires_design"   => false,
        "requires_geometry" => true,
    ),
    Dict{String, Any}(
        "name"              => "get_current_params",
        "description"       => "Fully resolved parameter set (defaults + overrides as the solver sees them).",
        "phase"             => "orientation",
        "use_when"          => "You need to know the current design configuration before recommending changes.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with floor_type, analysis_method, loads, materials, deflection_limit, etc.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_design_history",
        "description"       => "Past designs in this session (params patch, pass/fail, critical ratio, EC), each tagged with geometry_hash of the model used for that run.",
        "phase"             => "orientation",
        "use_when"          => "Checking what has already been tried, comparing runs on the same geometry, or contrasting metrics before vs after a geometry change.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Array of design snapshots: index, timestamp, geometry_hash, params, pass/fail, EC, member counts.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_diagnose_summary",
        "description"       => "Lightweight failure overview: counts by element type, top-5 critical elements, failure breakdown by governing check.",
        "phase"             => "diagnosis",
        "use_when"          => "First diagnostic step after orientation. Shows where the problems are without dumping all element data. Follow up with query_elements or get_diagnose for detail.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with by_type (counts), top_critical (top 5 elements), failure_breakdown (checks ranked by frequency).",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_diagnose",
        "description"       => "High-resolution per-element diagnostics: governing checks, demand/capacity, code clauses, levers, EC, recommendations.",
        "phase"             => "diagnosis",
        "use_when"          => "You need detailed per-element structural data, or the user asks why something is sized a certain way. Prefer get_diagnose_summary first.",
        "args"              => Dict{String, Any}("units" => Dict("type" => "string", "enum" => ["imperial", "metric"], "optional" => true)),
        "returns"           => "Three-layer Dict: engineering (elements), architectural (narrative), constraints (levers).",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "query_elements",
        "description"       => "Filter elements by type, ratio range, governing_check, story, or pass/fail status.",
        "phase"             => "diagnosis",
        "use_when"          => "You need details on specific failing or critical elements without loading all element data.",
        "args"              => Dict{String, Any}(
            "type"            => Dict("type" => "string", "enum" => ["column", "beam", "slab", "foundation"], "optional" => true),
            "min_ratio"       => Dict("type" => "number", "optional" => true),
            "max_ratio"       => Dict("type" => "number", "optional" => true),
            "governing_check" => Dict("type" => "string", "optional" => true),
            "ok"              => Dict("type" => "boolean", "optional" => true),
        ),
        "returns"           => "Filtered subset of /diagnose elements matching criteria, with count.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_implemented_provisions",
        "description"       => "List of all design code clauses the solver implements (ACI 318, AISC 360, etc.).",
        "phase"             => "diagnosis",
        "use_when"          => "The user asks whether the solver checks a specific code provision, or you need to verify before citing a clause.",
        "args"              => Dict{String, Any}("code" => Dict("type" => "string", "optional" => true, "description" => "Filter by code, e.g. ACI_318, AISC_360_16")),
        "returns"           => "Dict mapping code names to arrays of {section, provision} entries.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_lever_map",
        "description"       => "Which API parameters and geometry changes affect a given failure check. Canonical source of truth for 'what can I change to fix X'.",
        "phase"             => "diagnosis",
        "use_when"          => "Before recommending a fix for a specific failure check. Tells you exactly which knobs to turn.",
        "args"              => Dict{String, Any}("check" => Dict("type" => "string", "optional" => true, "description" => "Filter to one check family (e.g. 'punching_shear', 'deflection', 'P-M_interaction'). Omit for full map.")),
        "returns"           => "Dict mapping check names to {parameters, geometry, direction}.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "explain_field",
        "description"       => "Definition, units, valid values, default, related checks, and ontology rationale (when available) for any API parameter.",
        "phase"             => "diagnosis",
        "use_when"          => "The user asks what a parameter does, or you need to understand a parameter before recommending it. Now includes code rationale and related structural checks.",
        "args"              => Dict{String, Any}("field" => Dict("type" => "string", "required" => true)),
        "returns"           => "Dict with field, details, rationale (ontology), related_checks (from lever map).",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_provision_rationale",
        "description"       => "Deep ontology lookup: mechanism, rationale, failure consequence, code philosophy, common misconceptions, and actionable levers (split into api_params vs geometry_levers) for a structural code provision.",
        "phase"             => "diagnosis",
        "use_when"          => "The user asks WHY a check failed, what the provision guards against, or common misconceptions. Accepts section numbers, full keys, OR check family names from diagnose output (e.g. 'punching_shear').",
        "args"              => Dict{String, Any}("section" => Dict("type" => "string", "required" => true, "description" => "Section number ('22.6', 'H1'), full key ('ACI_318.22.6'), or check family name ('punching_shear', 'deflection', 'PM_interaction')")),
        "returns"           => "Dict with section, code, provision, mechanism, rationale, failure_consequence, code_philosophy, common_misconceptions, api_params, geometry_levers, coverage.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "validate_params",
        "description"       => "Check a params patch for compatibility violations before running.",
        "phase"             => "exploration",
        "use_when"          => "Before calling run_design — always validate first.",
        "args"              => Dict{String, Any}("params" => Dict("type" => "object", "required" => true)),
        "returns"           => "Dict with ok (bool) and violations (array of strings).",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "run_design",
        "description"       => "Fast parameter-only what-if check (skips visualization, max 2 iterations, 60s timeout).",
        "phase"             => "exploration",
        "use_when"          => "After validate_params passes, to test a parameter change.",
        "args"              => Dict{String, Any}("params" => Dict("type" => "object", "required" => true)),
        "returns"           => "Dict with pass/fail, critical ratio, summary text, warnings.",
        "requires_design"   => false,
        "requires_geometry" => true,
    ),
    Dict{String, Any}(
        "name"              => "compare_designs",
        "description"       => "Delta table between two designs from session history; includes geometry_hash per side and cross_geometry_comparison when the two runs used different models.",
        "phase"             => "exploration",
        "use_when"          => "After run_design, to show what changed. Or the user asks to compare two runs (including across geometry changes — cite comparison_note when cross_geometry_comparison is true).",
        "args"              => Dict{String, Any}(
            "index_a" => Dict("type" => "integer", "required" => true, "description" => "History index (1-based) or 0 for current"),
            "index_b" => Dict("type" => "integer", "required" => true, "description" => "History index (1-based) or 0 for current"),
        ),
        "returns"           => "Dict with design_a/design_b (incl. geometry_hash), deltas, changed_params, cross_geometry_comparison, optional comparison_note.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "suggest_next_action",
        "description"       => "Ontology-informed ranked parameter changes for a design goal. Analyzes runtime failures, ranks actions by how many failing checks each parameter addresses, and attaches code rationale.",
        "phase"             => "exploration",
        "use_when"          => "The user asks what to change, or you need a starting point for optimization. More informative than raw lever_impacts because it knows which checks are actually failing.",
        "args"              => Dict{String, Any}("goal" => Dict("type" => "string", "required" => true, "enum" => ["fix_failures", "reduce_column_size", "reduce_slab_thickness", "reduce_ec"])),
        "returns"           => "Dict with ranked_actions (sorted by failure coverage), enriched lever_impacts (with rationale), failing_checks (frequency + worst ratio), system_context, recommendations.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "run_experiment",
        "description"       => "Fast micro-experiment: re-check one element with a modified parameter (column size, slab thickness, deflection limit) using cached design data. No full re-run needed.",
        "phase"             => "exploration",
        "use_when"          => "Before run_design, to quickly test whether a specific change would help a specific element. Much faster than a full design run.",
        "args"              => Dict{String, Any}(
            "type" => Dict("type" => "string", "required" => true, "enum" => ["punching", "pm_column", "deflection", "catalog_screen"], "description" => "Experiment type"),
            "args" => Dict("type" => "object", "required" => true, "description" => "Experiment-specific args. punching: {col_idx, c1_in?, c2_in?, h_in?}. pm_column: {col_idx, section_size}. deflection: {slab_idx, deflection_limit}. catalog_screen: {col_idx, candidates: [12,14,16,...]}"),
        ),
        "returns"           => "Dict with original vs modified ratios, ok status, and delta.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "list_experiments",
        "description"       => "List available micro-experiment types with their argument schemas.",
        "phase"             => "exploration",
        "use_when"          => "You want to know what micro-experiments are available before running one.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with experiment names, descriptions, and argument schemas.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "batch_experiments",
        "description"       => "Run multiple micro-experiments in one call.",
        "phase"             => "exploration",
        "use_when"          => "You want to test several alternatives simultaneously (e.g. screen 5 column sizes).",
        "args"              => Dict{String, Any}(
            "experiments" => Dict("type" => "array", "required" => true, "description" => "Array of {type, args} objects"),
        ),
        "returns"           => "Dict with array of results, one per experiment.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "narrate_element",
        "description"       => "Plain-English explanation of one element's design, scaled to audience.",
        "phase"             => "communication",
        "use_when"          => "The user asks why an element is sized a certain way, or you want to explain a result.",
        "args"              => Dict{String, Any}(
            "element_type" => Dict("type" => "string", "required" => true, "enum" => ["column", "beam", "slab", "foundation"]),
            "element_id"   => Dict("type" => "integer", "required" => true),
            "audience"     => Dict(
                "type" => "string",
                "required" => true,
                "description" => "Preset \"architect\" or \"engineer\", or free text describing the reader (language, role, tone, format — e.g. German-speaking engineer, ASCII tables).",
            ),
        ),
        "returns"           => "Dict with narrative (string) and key_facts (dict).",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "narrate_comparison",
        "description"       => "Plain-English comparison of two designs from session history.",
        "phase"             => "communication",
        "use_when"          => "The user asks to explain the difference between two runs.",
        "args"              => Dict{String, Any}(
            "index_a"  => Dict("type" => "integer", "required" => true),
            "index_b"  => Dict("type" => "integer", "required" => true),
            "audience" => Dict(
                "type" => "string",
                "required" => true,
                "description" => "Preset \"architect\" or \"engineer\", or free text describing the reader (language, role, format preferences).",
            ),
        ),
        "returns"           => "Dict with narrative (string) and deltas (dict).",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_solver_trace",
        "description"       => "Tiered solver decision trace: why the solver chose specific sections, fell back, converged/diverged, and what check ratios it computed.",
        "phase"             => "diagnosis",
        "use_when"          => "You need to understand WHY a design looks the way it does — not just what passed/failed, but the solver's reasoning path. Start with tier=summary or tier=failures; drill deeper with tier=decisions or tier=full.",
        "args"              => Dict{String, Any}(
            "tier"    => Dict("type" => "string", "enum" => ["summary", "failures", "decisions", "full"], "optional" => true, "description" => "Detail level. Default: failures."),
            "element" => Dict("type" => "string", "optional" => true, "description" => "Filter to events for a specific element (e.g. 'column_group_3', 'slab_2')."),
            "layer"   => Dict("type" => "string", "enum" => ["pipeline", "workflow", "sizing", "optimizer", "checker", "slab"], "optional" => true, "description" => "Filter to a specific trace layer."),
        ),
        "returns"           => "Dict with tier, total_events, shown_events, stage_timeline, events array, and optional hints for deeper inspection.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "explain_trace_lookup",
        "description"       => "Post-hoc microscope: resolve a breadcrumb lookup key (from solver trace bundles) and return per-check feasibility explanation for that exact element/section/demand/geometry.",
        "phase"             => "diagnosis",
        "use_when"          => "You have a breadcrumb lookup object (from get_solver_trace tier=decisions) and want detailed per-check ratios for that element without re-running the full design.",
        "args"              => Dict{String, Any}(
            "lookup" => Dict("type" => "object", "required" => true, "description" => "Lookup dict from solver trace breadcrumbs: events[].data.top_elements[].lookup"),
        ),
        "returns"           => "Dict with lookup echo, element id, checker/material/section types, and FeasibilityExplanation (passed, governing_check, governing_ratio, checks array).",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_result_summary",
        "description"       => "Per-element JSON summary (check ratios, sections, failures).",
        "phase"             => "diagnosis",
        "use_when"          => "You need structured element-level data in the original API format.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with columns, beams, slabs, foundations arrays.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_condensed_result",
        "description"       => "~500-token plain-text result summary.",
        "phase"             => "diagnosis",
        "use_when"          => "You need a quick text overview of results for context injection.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with text (string).",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_applicability",
        "description"       => "DDM/EFM/FEA eligibility rules for the current geometry.",
        "phase"             => "diagnosis",
        "use_when"          => "Checking which analysis methods are valid for this building.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with rules per floor_type.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "clarify_user_intent",
        "description"       => "Structured multiple-choice clarification for the UI.",
        "phase"             => "communication",
        "use_when"          => "User intent is genuinely ambiguous and you need a constrained choice.",
        "args"              => Dict{String, Any}(
            "id"             => Dict("type" => "string", "optional" => true),
            "prompt"         => Dict("type" => "string", "required" => true),
            "options"        => Dict("type" => "array", "required" => true),
            "allow_multiple" => Dict("type" => "boolean", "optional" => true),
        ),
        "returns"           => "Dict with ok, type, clarification payload.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "record_insight",
        "description"       => "Record a structured learning from the current design iteration.",
        "phase"             => "exploration",
        "use_when"          => "After observing a design outcome, record what you learned so you don't repeat dead ends in future turns. Categories: observation (general), discovery (found something useful), dead_end (this didn't work), sensitivity (parameter X has big/small effect), geometry_note (geometry-specific constraint).",
        "args"              => Dict{String, Any}(
            "category"       => Dict("type" => "string", "required" => true, "enum" => ["observation", "discovery", "dead_end", "sensitivity", "geometry_note"]),
            "summary"        => Dict("type" => "string", "required" => true, "description" => "One-line summary of the insight"),
            "detail"         => Dict("type" => "string", "optional" => true),
            "related_checks" => Dict("type" => "array", "optional" => true, "description" => "Check families involved (e.g. punching_shear, flexure)"),
            "related_params" => Dict("type" => "array", "optional" => true, "description" => "Parameter names involved (e.g. column_concrete, floor_type)"),
            "design_index"   => Dict("type" => "integer", "optional" => true, "description" => "Which design history entry this relates to (0 = general)"),
            "confidence"     => Dict("type" => "number", "optional" => true, "description" => "0-1 confidence level (default 0.5)"),
        ),
        "returns"           => "Dict confirming the insight was recorded.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_session_insights",
        "description"       => "Retrieve accumulated learnings from this session.",
        "phase"             => "orientation",
        "use_when"          => "Before making a recommendation, check what you've already learned in this session. Especially useful after multiple design iterations.",
        "args"              => Dict{String, Any}(
            "category"       => Dict("type" => "string", "optional" => true, "enum" => ["observation", "discovery", "dead_end", "sensitivity", "geometry_note"]),
            "check"          => Dict("type" => "string", "optional" => true, "description" => "Filter to insights about a specific check family"),
            "param"          => Dict("type" => "string", "optional" => true, "description" => "Filter to insights about a specific parameter"),
            "min_confidence" => Dict("type" => "number", "optional" => true, "description" => "Minimum confidence threshold (default 0.0)"),
        ),
        "returns"           => "Dict with insights array.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
]

"""
    api_tool_schema() -> Vector{Dict{String, Any}}

Return the full tool registry for the `/schema/tools` endpoint.
"""
api_tool_schema() = TOOL_REGISTRY

const _LLM_CONTRACT_VERSION = "1.1.0"

"""
    _generate_params_list() -> Vector{Dict{String, Any}}

Walk `api_params_schema_structured()` and flatten it into a compact parameter
list for the LLM contract. Nested `object` types are flattened with dot notation.
"""
function _generate_params_list()::Vector{Dict{String, Any}}
    schema = api_params_schema_structured()
    out = Dict{String, Any}[]
    _flatten_schema!(out, schema, "")
    return out
end

function _flatten_schema!(out::Vector{Dict{String, Any}}, schema::Dict, prefix::String)
    for (key, spec) in sort(collect(schema); by=first)
        name = isempty(prefix) ? key : "$(prefix).$(key)"
        if !isa(spec, Dict)
            continue
        end
        ptype = get(spec, "type", "")
        if ptype == "object"
            sub = get(spec, "fields", nothing)
            !isnothing(sub) && _flatten_schema!(out, sub, name)
        else
            entry = Dict{String, Any}("name" => name, "type" => ptype)
            allowed = get(spec, "allowed", nothing)
            !isnothing(allowed) && (entry["values"] = allowed)
            rng = get(spec, "range", nothing)
            !isnothing(rng) && (entry["range"] = rng)
            unit = get(spec, "unit", nothing)
            !isnothing(unit) && (entry["unit"] = unit)
            impact = get(spec, "impact", nothing)
            !isnothing(impact) && (entry["impact"] = impact)
            push!(out, entry)
        end
    end
end

"""
    api_llm_contract() -> Dict{String, Any}

Versioned machine-readable contract describing the system's capabilities,
tools, parameters, scope limits, and experiment types. Intended for LLM
consumption at session start or for external integrations.
"""
function api_llm_contract()::Dict{String, Any}
    tools_compact = [Dict{String, Any}(
        "name" => t["name"],
        "phase" => t["phase"],
        "description" => t["description"],
        "requires_design" => get(t, "requires_design", false),
        "requires_geometry" => get(t, "requires_geometry", false),
    ) for t in TOOL_REGISTRY]

    params_list = _generate_params_list()

    scope_limits = [
        "Cannot modify geometry (spans, heights, column grid) — geometry comes from Grasshopper",
        "Cannot add or remove structural members",
        "Cannot change load paths or framing topology",
        "Cannot perform lateral/seismic analysis — gravity only",
        "Cannot design connections or details",
        "Cannot model construction staging or time-dependent effects",
        "Cannot optimize across multiple floor types simultaneously",
        "Single-material per member type (no hybrid steel-concrete columns)",
    ]

    experiment_types = [
        Dict("name" => "punching", "speed" => "instant", "args" => ["col_idx", "c1_in?", "c2_in?", "h_in?"]),
        Dict("name" => "pm_column", "speed" => "instant", "args" => ["col_idx", "section_size"]),
        Dict("name" => "deflection", "speed" => "instant", "args" => ["slab_idx", "deflection_limit"]),
        Dict("name" => "catalog_screen", "speed" => "instant", "args" => ["col_idx", "candidates[]"]),
    ]

    insight_categories = ["observation", "discovery", "dead_end", "sensitivity", "geometry_note"]

    return Dict{String, Any}(
        "contract_version" => _LLM_CONTRACT_VERSION,
        "system" => "menegroth structural synthesizer",
        "description" => "Automated structural engineering design: gravity sizing for RC and steel buildings",
        "tools" => tools_compact,
        "n_tools" => length(tools_compact),
        "parameters" => params_list,
        "lever_map_checks" => sort(collect(keys(LEVER_SURFACE_MAP))),
        "scope_limits" => scope_limits,
        "experiments" => experiment_types,
        "insight_categories" => insight_categories,
        "trace_tiers" => [string(t) for t in StructuralSizer.TRACE_TIERS],
        "trace_layers" => [string(l) for l in StructuralSizer.TRACE_LAYERS],
        "workflow_sequence" => [
            "get_situation_card → orient",
            "get_diagnose_summary → identify failures",
            "get_lever_map(check=...) → find relevant parameters",
            "run_experiment → instant what-if",
            "validate_params → check compatibility",
            "run_design → full design with new params",
            "compare_designs → measure improvement",
            "record_insight → capture learning",
        ],
    )
end
