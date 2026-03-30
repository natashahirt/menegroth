# =============================================================================
# Tool Registry — structured metadata for agent tools + implemented provisions
#
# TOOL_REGISTRY: each entry has name, description, phase, use_when, args,
# returns, requires_design, requires_geometry. _openai_tool_specs() in chat.jl
# merges description + use_when + returns into a single OpenAI description string.
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
    # Slab punching (diagnose: "punching_shear_slab")
    "punching_shear_slab" => Dict(
        "parameters" => ["punching_strategy", "column_concrete", "floor_type"],
        "geometry"   => ["column_size", "slab_span"],
        "direction"  => "grow_columns or reinforce_first reduces demand/capacity ratio; higher f'c increases Vc",
    ),
    # Column punching (diagnose: "punching_shear_col")
    "punching_shear_col" => Dict(
        "parameters" => ["punching_strategy", "column_catalog", "column_concrete", "floor_type"],
        "geometry"   => ["column_size", "slab_span"],
        "direction"  => "grow_columns increases critical perimeter; reinforce_first adds shear studs; higher f'c increases Vc",
    ),
    # Foundation punching (diagnose: "punching_shear_fdn")
    "punching_shear_fdn" => Dict(
        "parameters" => ["foundation_concrete", "foundation_options"],
        "geometry"   => ["column_count"],
        "direction"  => "thicker footing or higher f'c increases punching capacity",
    ),
    # Generic alias — matches any "punching_shear" query
    "punching_shear" => Dict(
        "parameters" => ["punching_strategy", "column_concrete", "floor_type", "column_catalog"],
        "geometry"   => ["column_size", "slab_span"],
        "direction"  => "grow_columns or reinforce_first reduces demand/capacity ratio; higher f'c increases Vc. See punching_shear_col / punching_shear_slab / punching_shear_fdn for element-specific levers.",
    ),
    "flexure" => Dict(
        "parameters" => ["deflection_limit", "floor_type", "concrete", "rebar"],
        "geometry"   => ["span_length"],
        "direction"  => "thicker slab or higher rebar grade increases capacity; shorter spans reduce demand",
    ),
    # Foundation flexure (diagnose: "flexure_fdn")
    "flexure_fdn" => Dict(
        "parameters" => ["foundation_concrete", "foundation_options"],
        "geometry"   => ["column_count"],
        "direction"  => "thicker footing or higher f'c increases flexural capacity",
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
    # Column P-M interaction (diagnose: "pm_interaction")
    "pm_interaction" => Dict(
        "parameters" => ["column_catalog", "column_concrete", "column_type", "column_sizing_strategy"],
        "geometry"   => ["column_count", "story_height"],
        "direction"  => "larger catalog pool or higher f'c increases capacity; more columns redistribute load",
    ),
    # Column axial (diagnose: "axial_compression")
    "axial_compression" => Dict(
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
    # Foundation bearing (diagnose: "bearing")
    "bearing" => Dict(
        "parameters" => ["foundation_soil", "foundation_concrete", "foundation_options"],
        "geometry"   => ["column_count"],
        "direction"  => "stiffer soil or larger footings increase bearing capacity",
    ),
    "fire_protection" => Dict(
        "parameters" => ["fire_rating"],
        "geometry"   => [],
        "direction"  => "reducing fire_rating reduces required concrete cover and steel protection thickness",
    ),
    "convergence" => Dict(
        "parameters" => ["max_iterations", "mip_time_limit_sec", "column_sizing_strategy"],
        "geometry"   => [],
        "direction"  => "more iterations or longer MIP time allows optimizer to find feasible assignment",
    ),
)

# ─── Element Reasonableness Thresholds ────────────────────────────────────────
# Industry-norm thresholds for detecting abnormally large/small sized elements.
# All dimension thresholds in inches; areas in ft².

const ELEMENT_REASONABLENESS_THRESHOLDS = Dict{String, Any}(
    "slab" => Dict{String, Any}(
        "thickness_max_in"          => 16.0,   # flat plate practical limit
        "thickness_extreme_in"      => 24.0,   # any slab type
        "span_to_depth_min"         => 20,     # below → unreasonably thick for span
        "self_weight_dominance"     => 0.6,    # self_weight / qu fraction
        "deflection_ratio_marginal" => 0.95,   # nearly deflection-governed
    ),
    "column" => Dict{String, Any}(
        "max_dimension_in" => 36.0,   # RC; unusual below ~20 stories
        "min_dimension_in" => 10.0,   # practical minimum
        "rho_g_high"       => 0.06,   # congested reinforcement (ACI max 0.08)
        "rho_g_low"        => 0.015,  # near ACI minimum 0.01
    ),
    "beam" => Dict{String, Any}(
        "depth_max_in"          => 36.0,   # deep beam territory
        "span_to_depth_min"     => 12.0,   # unusually deep for span
        "span_to_depth_max"     => 30.0,   # very slender
        "weight_per_ft_extreme" => 200.0,  # plf; W36x256+ territory
    ),
    "foundation" => Dict{String, Any}(
        "plan_area_max_ft2" => 100.0,  # per footing
        "depth_max_in"      => 36.0,   # very thick footing
    ),
)

# ─── Geometry Remediation Map ─────────────────────────────────────────────────
# Maps failing check families → geometric root-cause thresholds and
# specific Grasshopper geometry changes. Used by agent_suggest_next_action
# when parameter headroom is exhausted.

const GEOMETRY_REMEDIATION_MAP = Dict{String, Any}(
    "deflection" => Dict{String, Any}(
        "geometry_likely_governs_when" => Dict{String, Any}(
            "condition"  => "max_span_m > 9.1 AND floor_type in (flat_plate, flat_slab)",
            "max_span_m" => 9.1,
            "rationale"  => "Deflection scales with L⁴/h³; beyond ~30 ft for flat plate, " *
                            "even maximum practical slab depth (~16 in) cannot satisfy L/360.",
        ),
        "geometric_actions" => [
            Dict{String, Any}(
                "action"    => "reduce_column_spacing",
                "target"    => "Max span ≤ 30 ft (9.1 m) for flat_plate/flat_slab; ≤ 40 ft (12.2 m) for one_way",
                "mechanism" => "Deflection ∝ L⁴: halving span reduces deflection 16×",
                "grasshopper" => "Add intermediate columns along the long-span direction",
            ),
            Dict{String, Any}(
                "action"    => "switch_floor_system",
                "target"    => "One-way beam-and-slab (floor_type=one_way) for spans > 30 ft",
                "mechanism" => "Beams carry load to columns, reducing effective slab span",
                "grasshopper" => "Change floor_type to one_way and add beam edges in the model",
            ),
        ],
    ),
    "punching_shear_slab" => Dict{String, Any}(
        "geometry_likely_governs_when" => Dict{String, Any}(
            "condition"  => "tributary_area_m2 > 51.1 (≈550 ft²) per column",
            "max_trib_area_m2" => 51.1,
            "rationale"  => "Punching demand = tributary_area × factored_load. " *
                            "Large tributary areas create shear demands that exceed " *
                            "what column growth or shear studs can provide.",
        ),
        "geometric_actions" => [
            Dict{String, Any}(
                "action"    => "reduce_column_spacing",
                "target"    => "Column tributary area ≤ 400–500 ft² for flat plate",
                "mechanism" => "Reduces shear demand per column linearly with tributary area",
                "grasshopper" => "Add columns to subdivide large bays",
            ),
        ],
    ),
    "punching_shear_col" => Dict{String, Any}(
        "geometry_likely_governs_when" => Dict{String, Any}(
            "condition"  => "tributary_area_m2 > 51.1 (≈550 ft²) per column",
            "max_trib_area_m2" => 51.1,
            "rationale"  => "Same mechanism as slab punching — large tributary area drives " *
                            "high shear demand at the column critical section.",
        ),
        "geometric_actions" => [
            Dict{String, Any}(
                "action"    => "reduce_column_spacing",
                "target"    => "Column tributary area ≤ 400–500 ft² for flat plate",
                "mechanism" => "Reduces shear demand per column linearly with tributary area",
                "grasshopper" => "Add columns to subdivide large bays",
            ),
        ],
    ),
    "pm_interaction" => Dict{String, Any}(
        "geometry_likely_governs_when" => Dict{String, Any}(
            "condition"  => "story_height_m > 4.5 AND column_tributary_area large",
            "max_story_height_m" => 4.5,
            "rationale"  => "Tall stories increase column slenderness (KL/r ∝ H) and amplify " *
                            "second-order P-Δ moments; large tributary areas create high axial loads. " *
                            "The combination can exhaust available sections.",
        ),
        "geometric_actions" => [
            Dict{String, Any}(
                "action"    => "reduce_story_height",
                "target"    => "Story height ≤ 14 ft (4.3 m) for typical office floors",
                "mechanism" => "Reduces unbraced length, lowering slenderness and P-Δ amplification",
                "grasshopper" => "Adjust stories_z values to reduce floor-to-floor height",
            ),
            Dict{String, Any}(
                "action"    => "add_columns",
                "target"    => "Distribute axial load across more columns",
                "mechanism" => "Reduces P per column, moving interaction point closer to origin",
                "grasshopper" => "Add intermediate columns in the plan",
            ),
        ],
    ),
    "axial_compression" => Dict{String, Any}(
        "geometry_likely_governs_when" => Dict{String, Any}(
            "condition"  => "story_height_m > 4.5 OR very few columns for the floor area",
            "max_story_height_m" => 4.5,
            "rationale"  => "KL/r increases with story height → lower φPn from buckling. " *
                            "Few columns mean each carries more tributary load.",
        ),
        "geometric_actions" => [
            Dict{String, Any}(
                "action"    => "reduce_story_height",
                "target"    => "Story height ≤ 14 ft (4.3 m) for typical floors",
                "mechanism" => "Shorter columns → lower KL/r → higher buckling capacity",
                "grasshopper" => "Adjust stories_z values",
            ),
            Dict{String, Any}(
                "action"    => "add_columns",
                "target"    => "More columns to share axial load",
                "mechanism" => "Axial load per column ∝ 1/n_columns",
                "grasshopper" => "Add intermediate columns",
            ),
        ],
    ),
    "flexure" => Dict{String, Any}(
        "geometry_likely_governs_when" => Dict{String, Any}(
            "condition"  => "max_span_m > 9.1 for slab flexure; > 15 for beam flexure",
            "max_span_m" => 9.1,
            "rationale"  => "Moment ∝ wL²/8. Beyond ~30 ft for flat plates, " *
                            "flexural demands require very thick slabs.",
        ),
        "geometric_actions" => [
            Dict{String, Any}(
                "action"    => "reduce_column_spacing",
                "target"    => "Max span ≤ 30 ft for flat plate; ≤ 45 ft for beams",
                "mechanism" => "Moment ∝ L²: halving span reduces moment by 4×",
                "grasshopper" => "Add intermediate columns or supports",
            ),
        ],
    ),
    "one_way_shear" => Dict{String, Any}(
        "geometry_likely_governs_when" => Dict{String, Any}(
            "condition"  => "max_span_m > 9.1 for flat plate",
            "max_span_m" => 9.1,
            "rationale"  => "Shear demand ∝ wL/2. Long spans with thick (heavy) slabs " *
                            "compound the problem through self-weight.",
        ),
        "geometric_actions" => [
            Dict{String, Any}(
                "action"    => "reduce_column_spacing",
                "target"    => "Max span ≤ 30 ft for flat plate",
                "mechanism" => "Shorter span reduces both load path and slab self-weight",
                "grasshopper" => "Add intermediate columns",
            ),
        ],
    ),
    "bearing" => Dict{String, Any}(
        "geometry_likely_governs_when" => Dict{String, Any}(
            "condition"  => "high column reaction (many stories or large tributary area)",
            "rationale"  => "Bearing pressure = reaction / footing_area. High reactions " *
                            "from large tributary areas require very large footings.",
        ),
        "geometric_actions" => [
            Dict{String, Any}(
                "action"    => "add_columns",
                "target"    => "More columns to distribute total gravity load",
                "mechanism" => "Reaction per column ∝ 1/n_columns; smaller footings needed",
                "grasshopper" => "Add columns — each new column gets its own smaller footing",
            ),
        ],
    ),
    "combined_forces" => Dict{String, Any}(
        "geometry_likely_governs_when" => Dict{String, Any}(
            "condition"  => "max_span_m > 15 for steel beams",
            "max_span_m" => 15.0,
            "rationale"  => "Long unbraced beams face combined flexure + axial + LTB interaction.",
        ),
        "geometric_actions" => [
            Dict{String, Any}(
                "action"    => "reduce_span",
                "target"    => "Beam spans ≤ 45 ft for most steel beams",
                "mechanism" => "Shorter spans reduce moment and improve LTB resistance",
                "grasshopper" => "Add intermediate columns or secondary beams",
            ),
        ],
    ),
    "LTB" => Dict{String, Any}(
        "geometry_likely_governs_when" => Dict{String, Any}(
            "condition"  => "unbraced_length > 20 ft (6.1 m)",
            "max_unbraced_m" => 6.1,
            "rationale"  => "Lateral-torsional buckling capacity degrades rapidly " *
                            "with increasing unbraced length.",
        ),
        "geometric_actions" => [
            Dict{String, Any}(
                "action"    => "add_bracing_points",
                "target"    => "Unbraced length ≤ Lp for the chosen section",
                "mechanism" => "Shorter unbraced segments stay in the plastic LTB plateau",
                "grasshopper" => "Add intermediate supports, secondary framing, or reduce beam span",
            ),
        ],
    ),
)

# ─── Geometric Sensitivity Map ────────────────────────────────────────────────
# Maps geometric variables → structural effects with scaling laws and
# economical ranges. Used by predict_geometry_effect tool.

const GEOMETRIC_SENSITIVITY_MAP = Dict{String, Any}(
    "span_length" => Dict{String, Any}(
        "affects" => [
            Dict{String, Any}(
                "check"        => "deflection",
                "relationship" => "L⁴",
                "direction"    => "increase_span → much_worse",
                "explanation"  => "Deflection ∝ wL⁴/(EI). Doubling span increases deflection 16×.",
            ),
            Dict{String, Any}(
                "check"        => "flexure",
                "relationship" => "L²",
                "direction"    => "increase_span → worse",
                "explanation"  => "Moment ∝ wL²/8. Doubling span quadruples bending moment.",
            ),
            Dict{String, Any}(
                "check"        => "punching_shear",
                "relationship" => "L²",
                "direction"    => "increase_span → worse",
                "explanation"  => "Tributary area ∝ L². More area per column = more shear demand.",
            ),
            Dict{String, Any}(
                "check"        => "slab_thickness",
                "relationship" => "L",
                "direction"    => "increase_span → thicker",
                "explanation"  => "ACI minimum h ≈ L/33 for flat plate. 48 ft → 17.5 in minimum.",
            ),
            Dict{String, Any}(
                "check"        => "self_weight_spiral",
                "relationship" => "L⁵ (effective)",
                "direction"    => "increase_span → nonlinear_worsening",
                "explanation"  => "Thicker slab → heavier → needs even thicker slab. " *
                                  "Beyond ~35 ft flat plate, this positive feedback loop " *
                                  "makes the system increasingly uneconomical.",
            ),
        ],
        "typical_economical_ranges" => Dict{String, Any}(
            "flat_plate" => "20–30 ft (6–9 m)",
            "flat_slab"  => "25–35 ft (7.5–10.5 m)",
            "one_way"    => "25–45 ft (7.5–14 m)",
            "vault"      => "30–60 ft (9–18 m)",
        ),
        "trade_offs" => "Longer spans give more open floor space but increase member sizes, " *
                        "self-weight, and cost. Beyond the economical range, cost escalates nonlinearly.",
    ),
    "story_height" => Dict{String, Any}(
        "affects" => [
            Dict{String, Any}(
                "check"        => "pm_interaction",
                "relationship" => "H (slenderness) + nonlinear P-Δ",
                "direction"    => "increase_height → worse",
                "explanation"  => "Slenderness KL/r ∝ H; P-Δ amplification grows nonlinearly " *
                                  "with height. Taller columns develop larger second-order moments " *
                                  "(ACI 6.6 moment magnification).",
            ),
            Dict{String, Any}(
                "check"        => "axial_compression",
                "relationship" => "H (linear in KL/r)",
                "direction"    => "increase_height → worse",
                "explanation"  => "KL/r ∝ H → lower φPn as slenderness increases (ACI 6.6.4).",
            ),
            Dict{String, Any}(
                "check"        => "column_size",
                "relationship" => "H",
                "direction"    => "increase_height → larger_columns",
                "explanation"  => "Longer columns need stockier sections for stability.",
            ),
        ],
        "typical_economical_ranges" => Dict{String, Any}(
            "office"      => "12–14 ft (3.6–4.3 m)",
            "retail"      => "14–18 ft (4.3–5.5 m)",
            "residential" => "9–11 ft (2.7–3.4 m)",
            "parking"     => "10–12 ft (3.0–3.6 m)",
        ),
        "trade_offs" => "Taller stories improve daylight and flexibility but increase " *
                        "column slenderness, cladding area, and vertical MEP runs.",
    ),
    "column_count" => Dict{String, Any}(
        "affects" => [
            Dict{String, Any}(
                "check"        => "punching_shear",
                "relationship" => "1/n",
                "direction"    => "add_columns → better",
                "explanation"  => "More columns = smaller tributary area = less shear per column.",
            ),
            Dict{String, Any}(
                "check"        => "axial_compression",
                "relationship" => "1/n",
                "direction"    => "add_columns → better",
                "explanation"  => "Axial load per column decreases linearly with column count.",
            ),
            Dict{String, Any}(
                "check"        => "foundation_bearing",
                "relationship" => "1/n",
                "direction"    => "add_columns → better",
                "explanation"  => "Each footing carries less load → smaller footings.",
            ),
            Dict{String, Any}(
                "check"        => "cost_and_usability",
                "relationship" => "n",
                "direction"    => "add_columns → worse",
                "explanation"  => "More columns = more formwork, more footings, less open floor space.",
            ),
        ],
        "typical_economical_ranges" => Dict{String, Any}(
            "open_office" => "25–35 ft column spacing (fewer columns)",
            "residential" => "20–28 ft column spacing",
            "parking"     => "28–35 ft × 55–60 ft bays",
        ),
        "trade_offs" => "Adding columns improves structural efficiency but reduces usable " *
                        "open area and increases foundations. Balance against architectural program.",
    ),
    "column_spacing_uniformity" => Dict{String, Any}(
        "affects" => [
            Dict{String, Any}(
                "check"        => "DDM_applicability",
                "relationship" => "ratio",
                "direction"    => "unequal_spacing → method_restriction",
                "explanation"  => "ACI DDM requires successive spans differ by ≤ 1/3 of longer span. " *
                                  "Irregular spacing may force EFM or FEA.",
            ),
            Dict{String, Any}(
                "check"        => "slab_reinforcement",
                "relationship" => "nonlinear",
                "direction"    => "unequal_spacing → more_complex",
                "explanation"  => "Unequal spans create unbalanced moments at columns, " *
                                  "increasing reinforcement at wide-side supports.",
            ),
        ],
        "typical_economical_ranges" => Dict{String, Any}(
            "general" => "Successive spans within 1/3 ratio for DDM; within 20% for best economy",
        ),
        "trade_offs" => "Regular grids are cheaper and easier to build. Irregular grids " *
                        "suit complex programs but complicate analysis and increase rebar.",
    ),
    "plan_aspect_ratio" => Dict{String, Any}(
        "affects" => [
            Dict{String, Any}(
                "check"        => "two_way_slab_efficiency",
                "relationship" => "ratio",
                "direction"    => "increase_ratio → one_way_behavior",
                "explanation"  => "Panel aspect ratios > 2:1 → slab acts as one-way, " *
                                  "negating two-way slab benefits. DDM limited to ≤ 2:1.",
            ),
            Dict{String, Any}(
                "check"        => "building_drift",
                "relationship" => "L/B",
                "direction"    => "increase_ratio → worse_lateral",
                "explanation"  => "Very elongated plans are more sensitive to lateral loads " *
                                  "in the narrow direction (outside this solver's gravity scope).",
            ),
        ],
        "typical_economical_ranges" => Dict{String, Any}(
            "flat_plate_panel" => "Panel long/short ≤ 2:1 for DDM; ≤ 3:1 for EFM",
            "building_plan"    => "L/B ≤ 3:1 for gravity-only without expansion joints",
        ),
        "trade_offs" => "Elongated panels require more reinforcement in the short direction " *
                        "and may need one-way slab treatment.",
    ),
)

# ─── Helper: lookup helpers used by agent_tools.jl ───────────────────────────
# Canonical ontology lookups (get_system_dependencies / get_provisions_for_check /
# get_code_rationale) live in `api/ontology.jl` to avoid duplicate method defs.

_lever_norm(s::String) = lowercase(replace(s, r"[-\s]+" => "_"))

"""
    get_lever_map(; check::Union{String, Nothing}=nothing) -> Dict

Return the lever surface map, optionally filtered to a single check family.
Uses `_lever_norm` to match diagnose check names (e.g. "pm_interaction")
against map keys regardless of casing or dash/underscore differences.
"""
function get_lever_map(; check::Union{String, Nothing}=nothing)
    if isnothing(check)
        return LEVER_SURFACE_MAP
    end
    key = _lever_norm(check)
    for k in keys(LEVER_SURFACE_MAP)
        if _lever_norm(k) == key
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
        "description"       => "Orientation snapshot: geometry, params, results health, session history, trace availability — all in one call.",
        "phase"             => "orientation",
        "use_when"          => "FIRST tool call in any conversation. Also useful after a design run to refresh context.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with has_geometry, has_design, geometry_context, geometry OR geometry_availability, params, health (all_pass, critical_ratio, critical_element, n_failing, failing_by_type, embodied_carbon), session (n_designs, can_compare_deltas, latest_passed), has_trace, _guidance. When n_failing > 0 always report failing_by_type counts.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_building_summary",
        "description"       => "Geometry summary: stories, counts, beam span_stats (all frame edges — not slab cells), span_diversity, slab_panel_plan from slab face outlines in plan (quad corner deviation from 90°, panel aspect ratios, plan_shape_classification), regularity (story heights). span_cv_note ties the two: beam CV ≠ plan irregularity.",
        "phase"             => "orientation",
        "use_when"          => "You need geometry details not covered by get_situation_card, or no design exists yet.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with n_stories, n_columns, n_beams, n_slabs, n_foundations, span_stats (basis=beam_frame_edges_all_directions), span_diversity?, slab_panel_plan?, floor_system? (floor_type + description when design exists), span_cv_note, regularity, structural_flags?, _guidance.",
        "requires_design"   => false,
        "requires_geometry" => true,
    ),
    Dict{String, Any}(
        "name"              => "get_geometry_digest",
        "description"       => "Structure-based geometry digest: cell spans, slab panels, beam spans (directional), column heights/tributaries, story heights, envelope, and structural flags. Computed from a real BuildingStructure (same pipeline as the solver).",
        "phase"             => "orientation",
        "use_when"          => "Need geometry detail not in get_situation_card, or prompt geometry seems stale. Call INSTEAD of saying geometry is unavailable.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with cells, slabs, beam_spans, column_heights, column_tributaries (with grid_regularity), stories, envelope, structural_flags, plus a plaintext digest.",
        "requires_design"   => false,
        "requires_geometry" => false,
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
        "returns"           => "Dict with history (array of design snapshots: index, timestamp, geometry_hash, params, pass/fail, EC) and count.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_diagnose_summary",
        "description"       => "Lightweight failure overview: counts by element type, top-5 critical elements, failure breakdown by governing check.",
        "phase"             => "diagnosis",
        "use_when"          => "First diagnostic step after orientation. Shows where the problems are without dumping all element data. Follow up with query_elements or get_diagnose for detail.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with by_type {column/beam/slab/foundation: {total, failing}}, top_critical (top 5), failure_breakdown (checks ranked by count), n_total_elements, n_total_failing, note, size_warnings? (nested: n_critical, n_warning, top, note), _guidance?. Always cite by_type counts and top_critical.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_diagnose",
        "description"       => "High-resolution per-element diagnostics: governing checks, demand/capacity, code clauses, levers, EC, recommendations. Slabs include reinforcement detail (bar sizes, spacings, As_provided/As_required).",
        "phase"             => "diagnosis",
        "use_when"          => "You need detailed per-element structural data, or the user asks why something is sized a certain way. Prefer get_diagnose_summary first.",
        "args"              => Dict{String, Any}("units" => Dict("type" => "string", "enum" => ["imperial", "metric"], "optional" => true)),
        "returns"           => "Three-layer Dict: columns, beams, slabs (with reinforcement), foundations, agent_summary, architectural, constraints.",
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
            "story"           => Dict("type" => "integer", "optional" => true, "description" => "Filter by story index (0=ground). Currently available for columns."),
        ),
        "returns"           => "Dict with columns?, beams?, slabs?, foundations? (matching elements per type), total_matched, unit_system.",
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
        "description"       => "Which API parameters and geometry changes affect a given failure check. Canonical source of truth for 'what can I change to fix X'. MUST consult before recommending any fix.",
        "phase"             => "diagnosis",
        "use_when"          => "REQUIRED before recommending a fix for any failure. User asks 'how do I fix punching shear / deflection / P-M interaction?' → call get_lever_map(check=that_check) FIRST. Also use when the user asks about reducing carbon, column size, or slab thickness — the lever map shows which parameters move the needle.",
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
        "description"       => "Check a params patch for compatibility violations before running. Returns field_guidance: which checks each parameter affects and its impact level.",
        "phase"             => "exploration",
        "use_when"          => "Before calling run_design — always validate first.",
        "args"              => Dict{String, Any}("params" => Dict("type" => "object", "required" => true)),
        "returns"           => "Dict with ok (bool), violations (array), warnings (array), and field_guidance (per-param check impacts from lever map).",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "run_design",
        "description"       => "Fast parameter-only what-if check (skips visualization, max 2 iterations, 60s timeout).",
        "phase"             => "exploration",
        "use_when"          => "ONLY if get_situation_card has_geometry is true (server received POST /design from Grasshopper). After validate_params passes. Never call when has_geometry is false — use digest + predict_geometry_effect for Grasshopper geometry advice instead.",
        "args"              => Dict{String, Any}("params" => Dict("type" => "object", "required" => true)),
        "returns"           => "Dict with ok, quick_check, all_pass, critical_ratio, critical_element, summary, warnings, applied_params, note?, _guidance?.",
        "requires_design"   => false,
        "requires_geometry" => true,
    ),
    Dict{String, Any}(
        "name"              => "compare_designs",
        "description"       => "Delta table between two designs from session history; includes geometry_hash per side, cross_geometry_comparison, critical_element per side, and mechanism_shift (whether the governing element changed).",
        "phase"             => "exploration",
        "use_when"          => "After run_design, to show what changed. Or the user asks to compare two runs (including across geometry changes — cite comparison_note when cross_geometry_comparison is true).",
        "args"              => Dict{String, Any}(
            "index_a" => Dict("type" => "integer", "required" => true, "description" => "History index (1-based) or 0 for current"),
            "index_b" => Dict("type" => "integer", "required" => true, "description" => "History index (1-based) or 0 for current"),
        ),
        "returns"           => "Dict with design_a/design_b (index, all_pass, critical_element, embodied_carbon, n_failing, geometry_hash), deltas (pass_improved, pass_regressed), changed_params, mechanism_shift?, cross_geometry_comparison, comparison_note?, _guidance?.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "suggest_next_action",
        "description"       => "Ontology-informed ranked parameter AND geometry changes for a design goal. Analyzes runtime failures, evaluates whether geometry is the bottleneck (parameter_headroom=exhausted), and returns geometry_actions (Grasshopper changes) when applicable.",
        "phase"             => "exploration",
        "use_when"          => "ONLY after a completed design exists (get_situation_card has_design true). For pre-design 'what should I change?' (carbon, spans, bays), use the geometry digest plus predict_geometry_effect — do NOT call this tool without a design.",
        "args"              => Dict{String, Any}("goal" => Dict("type" => "string", "required" => true, "enum" => ["fix_failures", "reduce_column_size", "reduce_slab_thickness", "reduce_ec"])),
        "returns"           => "Dict with goal, tldr, current_status (all_pass, critical_ratio, n_failing), parameter_headroom (exhausted/available), ranked_actions, failing_checks, geometry_actions? (when parameter_headroom=exhausted), system_context?, _guidance.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "predict_geometry_effect",
        "description"       => "Predict structural effects of changing a geometric variable (span_length, story_height, column_count, column_spacing_uniformity, plan_aspect_ratio). Returns affected checks with scaling laws, economical ranges by floor system, and trade-offs.",
        "phase"             => "exploration",
        "use_when"          => "The user asks 'what if I change the spans/add columns/increase story height?' or pre-design questions about carbon/efficiency where shorter spans or more columns would help — works without a completed design.",
        "args"              => Dict{String, Any}(
            "variable"  => Dict("type" => "string", "required" => true, "enum" => ["span_length", "story_height", "column_count", "column_spacing_uniformity", "plan_aspect_ratio"]),
            "direction" => Dict("type" => "string", "required" => true, "enum" => ["increase", "decrease"]),
        ),
        "returns"           => "Dict with variable, direction, affected_checks (scaling relationship + direction), economical_ranges (by floor system), trade_offs.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "run_experiment",
        "description"       => "INSTANT micro-experiment (~0.1s): re-check one element with a modified parameter using cached design data. No full re-run needed. PREFER THIS over run_design for single-element what-if questions.",
        "phase"             => "exploration",
        "use_when"          => "ALWAYS use when the user asks about: punching shear impact, column sizing, deflection limits, material effects on a specific element, 'would X help?', 'what if I change Y?', strategy changes (reinforce_first vs grow_columns), or any single-element what-if. Use BEFORE run_design to give instant feedback. Requires has_design=true.",
        "args"              => Dict{String, Any}(
            "type" => Dict(
                "type" => "string", "required" => true,
                "enum" => ["punching", "pm_column", "deflection", "catalog_screen"],
                "description" => "Experiment type. punching: test column/slab size on punching shear. pm_column: test a different column section. deflection: test a different L/N limit. catalog_screen: screen multiple candidate sections.",
            ),
            "args" => Dict(
                "type" => "object", "required" => true,
                "description" => "Experiment-specific arguments. Include only the fields relevant to the chosen type.",
                "fields" => Dict{String, Any}(
                    "col_idx" => Dict(
                        "type" => "integer",
                        "description" => "Column index (from diagnose). Required for: punching, pm_column, catalog_screen.",
                    ),
                    "slab_idx" => Dict(
                        "type" => "integer",
                        "description" => "Slab index (from diagnose). Required for: deflection.",
                    ),
                    "c1_in" => Dict(
                        "type" => "number",
                        "description" => "New column c1 dimension in inches. Used by: punching. Optional — defaults to current size.",
                    ),
                    "c2_in" => Dict(
                        "type" => "number",
                        "description" => "New column c2 dimension in inches. Used by: punching. Optional — defaults to current size.",
                    ),
                    "h_in" => Dict(
                        "type" => "number",
                        "description" => "New slab thickness in inches. Used by: punching. Optional — defaults to current thickness.",
                    ),
                    "section_size" => Dict(
                        "type" => "string",
                        "description" => "New section size. Used by: pm_column. For RC: numeric inches (e.g. \"18\"). For steel: W-shape designation (e.g. \"W14X82\").",
                    ),
                    "deflection_limit" => Dict(
                        "type" => "string",
                        "description" => "Deflection limit criterion. Used by: deflection. One of: L_240, L_360, L_480.",
                    ),
                    "candidates" => Dict(
                        "type" => "array",
                        "description" => "List of candidate section sizes. Used by: catalog_screen. RC: numeric inches [12,14,16,...]. Steel: W-shape strings [\"W14X82\",\"W14X90\",...].",
                    ),
                ),
            ),
        ),
        "returns"           => "Dict with original vs modified ratios, ok status, delta, and whether the change improved the element.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "list_experiments",
        "description"       => "List available micro-experiment types with their argument schemas.",
        "phase"             => "exploration",
        "use_when"          => "You need the exact argument schema for an experiment type. Usually not needed — run_experiment args are documented inline.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with experiment names, descriptions, and argument schemas.",
        "requires_design"   => false,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "batch_experiments",
        "description"       => "Run multiple micro-experiments in one call. Use to screen several alternatives at once.",
        "phase"             => "exploration",
        "use_when"          => "User asks 'which column sizes would work?' or 'compare these options' — run multiple punching/pm_column experiments in parallel. Also useful after suggest_next_action to test the top-ranked changes instantly.",
        "args"              => Dict{String, Any}(
            "experiments" => Dict(
                "type" => "array", "required" => true,
                "description" => "Array of experiment objects. Each has 'type' (punching|pm_column|deflection|catalog_screen) and 'args' (same fields as run_experiment args). Example: [{type: \"punching\", args: {col_idx: 1, c1_in: 18}}, {type: \"punching\", args: {col_idx: 1, c1_in: 20}}]",
                "items" => Dict(
                    "type" => "object",
                    "fields" => Dict{String, Any}(
                        "type" => Dict(
                            "type" => "string", "required" => true,
                            "enum" => ["punching", "pm_column", "deflection", "catalog_screen"],
                            "description" => "Experiment type.",
                        ),
                        "args" => Dict(
                            "type" => "object", "required" => true,
                            "description" => "Experiment-specific arguments (col_idx, slab_idx, c1_in, c2_in, h_in, section_size, deflection_limit, candidates — same as run_experiment).",
                        ),
                    ),
                ),
            ),
        ),
        "returns"           => "Dict with array of results, one per experiment.",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "narrate_element",
        "description"       => "Plain-English explanation of one element's design, scaled to audience. Produces calibrated narratives from actual design data — ALWAYS prefer this over writing your own explanation.",
        "phase"             => "communication",
        "use_when"          => "User asks to explain a column, beam, slab, or foundation result. Use INSTEAD of writing your own explanation — this tool uses real ratios, code clauses, and solver data. Also use after diagnosing a failure to give the user a clear narrative.",
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
        "description"       => "Plain-English comparison of two designs from session history. Use AFTER compare_designs for a human-friendly summary.",
        "phase"             => "communication",
        "use_when"          => "After compare_designs, when the user wants to understand the differences in plain English. Also use when the user asks 'what changed?' or 'was that better?'.",
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
        "description"       => "Tiered solver decision trace: why the solver chose specific sections, fell back, converged/diverged, and what check ratios it computed. This is the 'show your work' tool.",
        "phase"             => "diagnosis",
        "use_when"          => "User asks 'why is the column so big?', 'why did it pick this section?', 'why did the solver fall back?', 'why didn't it converge?', or any WHY question about solver behavior. Start with tier=failures for failing elements, tier=decisions for section selection reasoning. Use element filter to focus on a specific member.",
        "args"              => Dict{String, Any}(
            "tier"    => Dict("type" => "string", "enum" => ["summary", "failures", "decisions", "full"], "optional" => true, "description" => "Detail level. Default: failures."),
            "element" => Dict("type" => "string", "optional" => true, "description" => "Filter to events for a specific element (e.g. 'column_group_3', 'slab_2')."),
            "layer"   => Dict("type" => "string", "enum" => ["pipeline", "workflow", "sizing", "optimizer", "checker", "slab"], "optional" => true, "description" => "Filter to a specific trace layer."),
        ),
        "returns"           => "Dict with layers_present, elements_present, filter_element?, filter_layer?, events array, hint?, note?, _guidance?.",
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
        "returns"           => "Dict with member_type, member_idx, section, passed, governing_check, governing_ratio, checks (array of per-check results).",
        "requires_design"   => true,
        "requires_geometry" => false,
    ),
    Dict{String, Any}(
        "name"              => "get_result_summary",
        "description"       => "Per-element JSON summary (check ratios, sections, failures).",
        "phase"             => "diagnosis",
        "use_when"          => "You need structured element-level data in the original API format.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with overall, columns, beams, slabs, foundations, materials.",
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
        "description"       => "DDM/EFM/FEA eligibility rules, plus geometry_evaluation (DDM prerequisite checks against actual panel spans and aspect ratios) when server has cached geometry.",
        "phase"             => "diagnosis",
        "use_when"          => "User asks 'should I use DDM, EFM, or FEA?', 'which method is best for this building?', or 'why is DDM not working?'. Also use when the user changes floor_type or geometry and you need to check method compatibility. Reports whether DDM prerequisites (aspect ratio, span differences) are met or violated.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with rules per floor_type and optional geometry_evaluation with per-DDM-check verdicts.",
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
        "description"       => "Record a structured learning from the current design iteration. REQUIRED after every run_design or run_experiment.",
        "phase"             => "exploration",
        "use_when"          => "REQUIRED after every run_design call and recommended after run_experiment. Record what you learned: did the change help? Was it a dead end? How sensitive is the design to this parameter? Categories: observation (general), discovery (found something useful), dead_end (this didn't work), sensitivity (parameter X has big/small effect), geometry_note (geometry-specific constraint). Skipping this leads to repeated dead ends.",
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
        "description"       => "Retrieve accumulated learnings from this session. Check before recommending to avoid repeating failed approaches.",
        "phase"             => "orientation",
        "use_when"          => "REQUIRED before recommending a parameter change (especially after 2+ design iterations). Prevents you from suggesting something already tried as a dead_end. Also useful to summarize what's been learned when the user asks 'what have we tried?'.",
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
    Dict{String, Any}(
        "name"              => "get_response_guidelines",
        "description"       => "Behavioral rules, anti-patterns, tool selection recipes, irregularity rules, geometry rules, and the PARAMETER SPACE card. The system prompt is lean — this tool provides the complete guideline set on demand.",
        "phase"             => "reference",
        "use_when"          => "Uncertain about response protocol, tool sequencing, anti-patterns, or solver scope. Call once early to load the full guideline set.",
        "args"              => Dict{String, Any}(),
        "returns"           => "Dict with tool_selection_recipes, required_sequences, parameter_space (generated from schema), epistemic_boundary, anti_patterns, geometry_rules (recovery, remediation, what_if, stale_cache, client_vs_server), irregularity_rules.",
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
            "run_design → quick-check design with new params",
            "compare_designs → measure improvement",
            "record_insight → capture learning",
        ],
    )
end
