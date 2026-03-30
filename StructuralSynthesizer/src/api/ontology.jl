# =============================================================================
# Ontology — Codified structural engineering knowledge for agent reasoning
#
# Three complementary structures:
#   PROVISION_ONTOLOGY:   extends IMPLEMENTED_PROVISIONS with rationale, mechanisms,
#                         and design philosophy for the most commonly governing checks.
#   SYSTEM_DEPENDENCIES:  material-system compatibility graph with economic ranges
#                         and design implications.
#   CODE_RATIONALE:       the "why" behind parameter choices — when to tighten,
#                         relax, or reconsider each design lever.
#
# Each entry has a `coverage` field ("full" | "partial" | "stub") for tracking
# completeness. Start with ~10 most commonly governing provisions and grow
# incrementally.
# =============================================================================

"""
    PROVISION_ONTOLOGY

Codified knowledge about structural provisions: not just what the code says,
but why it exists, what mechanism it guards against, and how to reason about it.
"""
const PROVISION_ONTOLOGY = Dict{String, Any}(
    "ACI_318.22.6" => Dict{String, Any}(
        "section" => "22.6",
        "code" => "ACI_318",
        "provision" => "Punching shear",
        "mechanism" => "Two-way shear failure at column-slab connection — a truncated pyramid of concrete punches through the slab around the column perimeter.",
        "rationale" => "Prevents brittle progressive collapse. Punching failure is sudden with no ductile warning; loss of one column-slab connection can cascade to adjacent bays.",
        "failure_consequence" => "catastrophic",
        "code_philosophy" => "Lower-bound strength model using φ=0.75 (shear). Capacity depends on concrete strength, critical perimeter (b₀), and slab effective depth. Three limits: ACI Eq. 11-31/32/33 — the minimum governs.",
        "common_misconceptions" => [
            "Increasing slab thickness is always the best fix (column size or shear reinforcement may be more efficient).",
            "Edge/corner columns have the same capacity as interior (they don't — reduced critical perimeter).",
            "Unbalanced moment can be ignored for gravity-only design (it can't when frame analysis shows moment transfer).",
            "Higher f'c always improves punching (it increases Vc in isolation, but the column sizer may pick SMALLER columns for axial, shrinking b₀ and potentially net-worsening punching — the system effect can be opposite to the isolated effect).",
            "reinforce_first and grow_columns are equivalent (reinforce_first adds stud/stirrup capacity but does NOT grow columns — columns stay at P-M minimum, which may be smaller).",
        ],
        "api_params"      => ["punching_strategy", "column_concrete", "floor_type"],
        "geometry_levers" => ["column_size", "slab_span"],
        "coverage" => "full",
    ),
    "ACI_318.24.2" => Dict{String, Any}(
        "section" => "24.2",
        "code" => "ACI_318",
        "provision" => "Deflection control",
        "mechanism" => "Long-term slab or beam deflection under sustained load. Creep and shrinkage amplify immediate deflection by λΔ ≈ 2.0 (typical).",
        "rationale" => "Prevents damage to attached partitions, doors, and sensitive finishes. Limits are serviceability-based (not strength); a slab that passes all strength checks can still damage partitions if it deflects too much.",
        "failure_consequence" => "serviceability",
        "code_philosophy" => "ACI Table 24.2.2 limits: L/360 for floors with attached partitions (standard), L/480 for sensitive finishes, L/240 without attached nonstructural elements. Computed using effective moment of inertia (Branson's equation).",
        "common_misconceptions" => [
            "Deflection is only about comfort (it can crack partitions and damage door frames).",
            "Higher concrete strength dramatically reduces deflection (Ec ∝ √f'c, so going from 4000→6000 psi only increases Ec by ~22%. " *
                "For already-cracked sections this modest stiffness gain is often not worth the extra cost).",
            "The minimum-thickness table exempts you from deflection calculation (it does, but the table is often unconservative for irregular panels).",
        ],
        "api_params"      => ["deflection_limit", "concrete", "floor_type"],
        "geometry_levers" => ["slab_thickness", "span_length"],
        "coverage" => "full",
    ),
    "ACI_318.22.4" => Dict{String, Any}(
        "section" => "22.4",
        "code" => "ACI_318",
        "provision" => "Column P-M interaction",
        "mechanism" => "Combined axial compression and bending — interaction diagram determines whether the column can resist the combined loading. Points inside the diagram are safe; outside means failure.",
        "rationale" => "Columns carry all vertical load. A column failure can be catastrophic. The P-M diagram captures the complex nonlinear interaction between axial force and moment capacity.",
        "failure_consequence" => "catastrophic",
        "code_philosophy" => "Strain-compatibility analysis with Whitney stress block. φ=0.65 for compression-controlled, 0.90 for tension-controlled, linear interpolation in transition. Slenderness amplifies moments via moment magnification.",
        "common_misconceptions" => [
            "Bigger is always stronger (for compression-controlled columns, upsizing gives diminishing returns at φ=0.65; " *
                "also, adding area without proportional rebar dilutes the reinforcement ratio, potentially requiring more steel to meet ρ_min).",
            "Axial load always makes columns less safe (moderate compression actually increases moment capacity in the tension-controlled region — " *
                "the P-M diagram curves outward before turning over at the balance point).",
        ],
        "api_params"      => ["column_catalog", "column_concrete", "column_type", "column_sizing_strategy"],
        "geometry_levers" => ["column_count", "story_height"],
        "coverage" => "full",
    ),
    "AISC_360.H1" => Dict{String, Any}(
        "section" => "H1",
        "code" => "AISC_360_16",
        "provision" => "Steel P-M interaction",
        "mechanism" => "Combined axial force and flexure in steel members. Eq. H1-1a/b defines a bilinear interaction surface.",
        "rationale" => "Steel columns under combined loading can fail by yielding, local buckling, or lateral-torsional buckling. The interaction equations provide a simple but conservative check.",
        "failure_consequence" => "structural",
        "code_philosophy" => "φ=0.90 for both compression and flexure. Interaction equations are bilinear: H1-1a governs when Pu/φPn ≥ 0.2, H1-1b when below. Both must be checked.",
        "common_misconceptions" => [
            "W-shapes are always governed by strong-axis bending (weak-axis flexural buckling often controls for columns).",
            "Increasing Fy always helps (higher-grade steel can be more slender and trigger local buckling).",
        ],
        "api_params"      => ["column_catalog", "column_type", "column_sizing_strategy"],
        "geometry_levers" => ["column_count", "story_height"],
        "coverage" => "full",
    ),
    "ACI_318.9.5" => Dict{String, Any}(
        "section" => "9.5",
        "code" => "ACI_318",
        "provision" => "Flexure — required strength",
        "mechanism" => "Bending moment demand exceeding section capacity. Cracking reduces stiffness; at ultimate, concrete crushes or steel yields depending on reinforcement ratio.",
        "rationale" => "Ensures beams and slabs have enough reinforced cross-section to resist factored bending moments with adequate safety margin.",
        "failure_consequence" => "structural",
        "code_philosophy" => "Whitney stress block simplifies the nonlinear concrete stress distribution. φ=0.90 for tension-controlled (ductile) flexure. Minimum reinforcement (ρ_min) ensures the section doesn't fail immediately upon cracking.",
        "common_misconceptions" => [
            "Thicker slabs always need less reinforcement (the minimum ratio ρ_min may require more steel in a thicker section).",
        ],
        "api_params"      => ["deflection_limit", "floor_type", "concrete", "rebar"],
        "geometry_levers" => ["span_length"],
        "coverage" => "partial",
    ),
    "ACI_318.11.2" => Dict{String, Any}(
        "section" => "11.2",
        "code" => "ACI_318",
        "provision" => "One-way shear",
        "mechanism" => "Diagonal tension failure along a 45° crack from a concentrated or distributed load. Shear is resisted by concrete (Vc) plus stirrups (Vs).",
        "rationale" => "Shear failures are brittle — proper reinforcement ensures a ductile flexural failure mode governs instead.",
        "failure_consequence" => "structural",
        "code_philosophy" => "φ=0.75. Concrete shear capacity Vc includes size effect and axial load influence. Stirrup spacing limits ensure every potential crack plane is crossed by at least one stirrup.",
        "common_misconceptions" => [
            "Shear only matters near supports (critical section is at d from face of support; the entire shear diagram matters).",
        ],
        "api_params"      => ["concrete", "floor_type"],
        "geometry_levers" => ["span_length"],
        "coverage" => "partial",
    ),
    "AISC_360.F2" => Dict{String, Any}(
        "section" => "F2",
        "code" => "AISC_360_16",
        "provision" => "Lateral-torsional buckling (LTB)",
        "mechanism" => "Compression flange displaces laterally and the section twists between braced points. Capacity drops as unbraced length increases.",
        "rationale" => "A beam that is strong enough in cross-section can still fail prematurely if the compression flange is not braced against lateral displacement.",
        "failure_consequence" => "structural",
        "code_philosophy" => "Three regimes: plastic (Lb ≤ Lp → full Mp), inelastic (Lp < Lb ≤ Lr → linear interpolation), elastic (Lb > Lr → Fcr). Cb factor rewards non-uniform moment diagrams.",
        "common_misconceptions" => [
            "Floor slab always braces the top flange (only if positively attached and the flange is in compression).",
            "Heavier sections always have higher LTB capacity (section shape matters more than weight for Lr).",
        ],
        "api_params"      => ["beam_catalog", "beam_type"],
        "geometry_levers" => ["unbraced_length"],
        "coverage" => "partial",
    ),
    "AISC_360.E3" => Dict{String, Any}(
        "section" => "E3",
        "code" => "AISC_360_16",
        "provision" => "Flexural buckling (columns)",
        "mechanism" => "Euler buckling about the governing axis (typically weak axis for W-shapes). Capacity depends on KL/r.",
        "rationale" => "Slender columns can buckle at loads far below the material yield strength. Effective length and cross-sectional properties determine the critical load.",
        "failure_consequence" => "catastrophic",
        "code_philosophy" => "AISC E3 uses inelastic buckling curve with residual stress effects. Fe = π²E/(KL/r)². φ=0.90.",
        "common_misconceptions" => [
            "Strong-axis buckling always governs (it rarely does for W-shapes — check weak axis).",
        ],
        "api_params"      => ["column_catalog", "column_concrete", "column_type"],
        "geometry_levers" => ["column_count", "story_height"],
        "coverage" => "partial",
    ),
    "ACI_318.10.10" => Dict{String, Any}(
        "section" => "10.10",
        "code" => "ACI_318",
        "provision" => "Slenderness effects",
        "mechanism" => "P-δ (member) and P-Δ (story) effects amplify moments in slender columns. The longer and more slender the column, the larger the amplification.",
        "rationale" => "A column that is adequate for first-order forces may fail when second-order geometric effects are included. Moment magnification captures this without a full nonlinear analysis.",
        "failure_consequence" => "structural",
        "code_philosophy" => "Moment magnification method per ACI 318-19 §6.6.4. Applies when klu/r > 22 (braced) or klu/r > 34-12(M1/M2). Stiffness reduction EI formula uses βdns for sustained loads.",
        "common_misconceptions" => [
            "Slenderness only matters for tall columns (short stocky columns with high axial load can also be affected).",
        ],
        "api_params"      => ["column_catalog", "column_concrete", "column_type"],
        "geometry_levers" => ["column_count", "story_height"],
        "coverage" => "partial",
    ),
    "IBC.Table_601" => Dict{String, Any}(
        "section" => "Table_601",
        "code" => "IBC",
        "provision" => "Fire resistance rating",
        "mechanism" => "Structural members must maintain load-carrying capacity during the rated fire duration. Concrete relies on cover depth; steel requires applied fire protection (SFRM or intumescent coating).",
        "rationale" => "Fire-rated assemblies prevent structural collapse during evacuation and firefighting. Rating depends on building occupancy, height, and construction type.",
        "failure_consequence" => "catastrophic",
        "code_philosophy" => "Prescriptive ratings from IBC Table 601 based on construction type. ACI 216.1 for concrete cover requirements; AISC DG19/UL designs for steel protection.",
        "common_misconceptions" => [
            "Concrete is automatically fire rated (it requires minimum cover and thickness per ACI 216.1).",
            "Fire rating only affects cost (it drives minimum slab thickness, concrete cover, and steel protection — all affect structural sizing).",
        ],
        "api_params"      => ["fire_rating"],
        "geometry_levers" => String[],
        "coverage" => "stub",
    ),
    "general.foundation_bearing" => Dict{String, Any}(
        "section" => "foundation",
        "code" => "ACI_318",
        "provision" => "Foundation bearing capacity",
        "mechanism" => "Column reactions must be transferred to soil through footings without exceeding allowable bearing pressure. Footing size is driven by reaction magnitude and soil capacity.",
        "rationale" => "Foundation failure causes settlement or bearing capacity exceedance. Spread footings distribute column loads over sufficient area; when footings merge, a mat foundation is more economical.",
        "failure_consequence" => "structural",
        "code_philosophy" => "ASD bearing design against allowable soil pressure (qa). ACI 318 for footing structural design (flexure, shear, punching).",
        "common_misconceptions" => [
            "Stronger concrete always helps (footing size is governed by soil bearing, not concrete strength).",
            "Mat foundation is always more expensive than spread footings (when footing coverage exceeds ~50% of plan area, a mat can be cheaper).",
        ],
        "api_params"      => ["foundation_soil", "foundation_concrete", "foundation_options"],
        "geometry_levers" => ["column_count"],
        "coverage" => "stub",
    ),
    "general.convergence" => Dict{String, Any}(
        "section" => "solver",
        "code" => "implementation",
        "provision" => "Slab-column iteration convergence",
        "mechanism" => "The slab and column sizing iterate: slab self-weight depends on thickness, which depends on demands, which depend on column sizes, which depend on reactions. Non-convergence indicates an unstable design loop.",
        "rationale" => "Convergence failure means the solver could not find a self-consistent design in the allowed iterations. This is usually a sign that the building is at the edge of feasibility for the chosen system.",
        "failure_consequence" => "serviceability",
        "code_philosophy" => "Iterative design with weight-based convergence criterion. Typical convergence in 2-4 iterations; failure after max_iterations suggests the system is undersized or the parameters are incompatible.",
        "common_misconceptions" => [
            "More iterations always help (if the design is diverging, more iterations just waste time).",
            "Convergence failure means the building can't be built (it means the current parameter set doesn't work — different parameters might).",
        ],
        "api_params"      => ["max_iterations", "mip_time_limit_sec", "column_sizing_strategy"],
        "geometry_levers" => ["column_grid", "span_lengths"],
        "coverage" => "partial",
    ),
)

"""
    SYSTEM_DEPENDENCIES

Material-system compatibility graph. Maps floor/column system combinations to
their structural implications, required check families, and practical economic
ranges. Used for ontology-informed parameter recommendations.
"""
const SYSTEM_DEPENDENCIES = Dict{String, Any}(
    "flat_plate" => Dict{String, Any}(
        "requires" => Dict("column_type" => ["rc_rect", "rc_circular"]),
        "rejects"  => Dict("column_type" => ["steel_w", "steel_hss", "steel_pipe", "pixelframe"]),
        "enables"  => ["punching_shear_check", "DDM", "DDM_SIMPLIFIED", "EFM", "EFM_HARDY_CROSS", "FEA"],
        "design_implications" => [
            "No beams → all shear transferred directly from slab to column (punching is the governing concern).",
            "Two-way moment distribution between column strips and middle strips.",
            "Deflection often governs for longer spans due to relatively thin slab.",
        ],
        "economic_range" => Dict("span_ft" => [15, 30], "typical_slab_in" => [7, 12]),
        "coverage" => "full",
    ),
    "flat_slab" => Dict{String, Any}(
        "requires" => Dict("column_type" => ["rc_rect", "rc_circular"]),
        "rejects"  => Dict("column_type" => ["steel_w", "steel_hss", "steel_pipe", "pixelframe"]),
        "enables"  => ["punching_shear_check", "drop_panel_design", "DDM", "EFM", "FEA"],
        "design_implications" => [
            "Drop panels at columns provide extra depth for punching resistance without thickening the entire slab.",
            "Better punching capacity than flat plate for same slab thickness.",
            "Drop panel formwork adds cost; economical when punching governs and column growth is undesirable.",
        ],
        "economic_range" => Dict("span_ft" => [20, 35], "typical_slab_in" => [8, 14]),
        "coverage" => "full",
    ),
    "one_way" => Dict{String, Any}(
        "requires" => Dict("beam_type" => ["steel_w", "rc_rect", "rc_tbeam", "steel_hss"]),
        "enables"  => ["beam_flexure_check", "beam_shear_check", "beam_deflection_check"],
        "design_implications" => [
            "Load path is dominantly one direction — slab spans between beams, beams span between columns.",
            "Longer beam spans possible (beams carry the load, not the slab).",
            "Floor depth is slab + beam, increasing story height.",
        ],
        "economic_range" => Dict("slab_span_ft" => [8, 15], "beam_span_ft" => [20, 45]),
        "coverage" => "partial",
    ),
    "vault" => Dict{String, Any}(
        "requires" => Dict(
            "column_type" => ["rc_rect", "rc_circular"],
            "beam_type" => ["rc_rect", "rc_tbeam"],
        ),
        "enables"  => ["shell_analysis", "horizontal_thrust_check"],
        "design_implications" => [
            "Parabolic shell transfers load through compression — very efficient for uniform loads.",
            "Horizontal thrust must be resisted by beams or ties.",
            "Requires RC beams/columns and rectangular orthogonal faces.",
        ],
        "economic_range" => Dict("span_ft" => [15, 40]),
        "coverage" => "stub",
    ),
    "steel_columns" => Dict{String, Any}(
        "applies_to" => Dict("column_type" => ["steel_w", "steel_hss"]),
        "enables"  => ["aisc_pm_interaction", "flexural_buckling", "ltb_check"],
        "design_implications" => [
            "Lighter than RC for same capacity, but requires fire protection (SFRM or intumescent coating).",
            "Not supported with flat plate/flat slab in this solver (punching shear interface requires RC column-slab connection).",
            "Faster erection but higher material cost per unit capacity compared to RC for moderate loads.",
        ],
        "coverage" => "partial",
    ),
    "rc_columns" => Dict{String, Any}(
        "applies_to" => Dict("column_type" => ["rc_rect", "rc_circular"]),
        "enables"  => ["aci_pm_interaction", "slenderness_magnification"],
        "design_implications" => [
            "Required for flat plate/flat slab systems (punching shear interface).",
            "Inherent fire resistance reduces protection costs.",
            "Larger footprint than steel for same capacity; impacts usable floor area.",
        ],
        "coverage" => "partial",
    ),
)

"""
    CODE_RATIONALE

The "why" behind parameter choices — when to tighten, relax, or reconsider.
Structured for incremental growth: each entry explains the engineering
rationale so the agent can explain design decisions to users.
"""
const CODE_RATIONALE = Dict{String, Any}(
    "deflection_limit" => Dict{String, Any}(
        "L_240" => Dict{String, Any}(
            "code_basis" => "ACI 318-19 Table 24.2.2, Row 3",
            "rationale" => "Prevents visible sagging. Appropriate for floors/roofs not supporting or attached to nonstructural elements likely to be damaged by large deflections.",
            "when_appropriate" => "Open floor plans, parking structures, warehouses, roofs without brittle cladding.",
            "when_to_tighten" => "Attached partitions, sensitive equipment, or visible ceiling soffits.",
            "coverage" => "full",
        ),
        "L_360" => Dict{String, Any}(
            "code_basis" => "ACI 318-19 Table 24.2.2, Row 4",
            "rationale" => "Prevents damage to attached nonstructural elements (partitions, door frames). Standard for most occupied buildings.",
            "when_appropriate" => "Standard office, residential, retail with standard partitions.",
            "when_to_relax" => "Open floor plans without brittle partitions → L/240.",
            "when_to_tighten" => "Sensitive finishes, glass partitions, precision equipment → L/480.",
            "coverage" => "full",
        ),
        "L_480" => Dict{String, Any}(
            "code_basis" => "ACI 318-19 Table 24.2.2 (conservative choice beyond code minimum)",
            "rationale" => "Strict limit for sensitive finishes: glass partitions, precision laboratory equipment, or aesthetic requirements for flat soffits.",
            "when_appropriate" => "Labs, hospitals, museums, buildings with full-height glass partitions.",
            "when_to_relax" => "If the extra slab thickness for L/480 makes the design uneconomical and finishes can tolerate L/360.",
            "coverage" => "full",
        ),
    ),
    "punching_strategy" => Dict{String, Any}(
        "grow_columns" => Dict{String, Any}(
            "rationale" => "Increase column cross-section to enlarge the critical perimeter b₀. Simple, robust, no added reinforcement.",
            "when_appropriate" => "Interior columns where column size increase is acceptable architecturally. Usually the most economical first step.",
            "trade_offs" => "Larger columns reduce usable floor area and may conflict with architectural layout.",
            "coverage" => "full",
        ),
        "reinforce_first" => Dict{String, Any}(
            "rationale" => "Add shear studs or closed stirrups before attempting to grow columns. Keeps column sizes small.",
            "when_appropriate" => "When column sizes are architecturally constrained. Also useful for edge/corner columns where growth is limited.",
            "trade_offs" => "Added reinforcement cost, more complex construction. Stud rails need careful placement.",
            "coverage" => "full",
        ),
        "reinforce_last" => Dict{String, Any}(
            "rationale" => "Grow columns first; only add reinforcement if column growth alone is insufficient. Conservative hierarchy.",
            "when_appropriate" => "Default recommendation when no architectural constraints on column size.",
            "trade_offs" => "May result in unnecessarily large columns in some cases.",
            "coverage" => "full",
        ),
    ),
    "analysis_method" => Dict{String, Any}(
        "DDM" => Dict{String, Any}(
            "rationale" => "Direct Design Method — simplified moment coefficients for regular geometry. Fast, conservative, widely understood.",
            "when_appropriate" => "Regular rectangular bays, aspect ratio 0.5–2.0, at least 3 continuous spans, L/D ≤ 2.0.",
            "when_to_switch" => "Irregular geometry, high live-to-dead ratio, or when DDM coefficients are too conservative → EFM or FEA.",
            "coverage" => "full",
        ),
        "EFM" => Dict{String, Any}(
            "rationale" => "Equivalent Frame Method — models the slab as a series of portal frames. More accurate moment distribution than DDM, handles pattern loading.",
            "when_appropriate" => "Regular rectangular geometry but DDM is too conservative, or when pattern loading effects matter.",
            "when_to_switch" => "Non-rectangular panels, free-form column layouts → FEA.",
            "coverage" => "full",
        ),
        "FEA" => Dict{String, Any}(
            "rationale" => "Finite Element Analysis — shell elements discretize the slab. Most general method, handles any geometry.",
            "when_appropriate" => "Irregular panels, non-orthogonal grids, setbacks, free-form layouts, or when DDM/EFM applicability checks fail.",
            "when_to_switch" => "If FEA is overkill for a simple rectangular grid, DDM or EFM will be faster and equally accurate.",
            "coverage" => "full",
        ),
    ),
    "fire_rating" => Dict{String, Any}(
        "rationale" => "Fire rating determines minimum member dimensions and cover per ACI 216.1 (concrete) or AISC DG19/UL (steel). Higher ratings increase costs but are required by IBC based on occupancy and construction type.",
        "0hr" => Dict("when" => "Type V-B construction, sprinklered low-hazard occupancies (IBC §602)."),
        "1hr" => Dict("when" => "Type II-A/III-A construction, typical for most commercial."),
        "2hr" => Dict("when" => "Type I-A/I-B construction, high-rises, critical occupancies."),
        "3hr" => Dict("when" => "Columns in Type I-A buildings (IBC Table 601)."),
        "coverage" => "partial",
    ),
    "optimize_for" => Dict{String, Any}(
        "weight" => Dict("rationale" => "Minimize structural weight. Often correlates with cost for steel; less so for concrete where formwork dominates."),
        "carbon" => Dict("rationale" => "Minimize embodied carbon (kgCO2e). Favors thinner sections, less concrete, less rebar. Growing in importance for sustainable design."),
        "cost" => Dict("rationale" => "Minimize estimated material cost. Accounts for steel/concrete/rebar unit prices."),
        "coverage" => "partial",
    ),
)

# ─── Check family ↔ provision bridge ─────────────────────────────────────────
#
# Diagnose output uses check family names like "punching_shear", "deflection".
# This mapping connects them to PROVISION_ONTOLOGY keys so the LLM can look up
# rationale using the names it already sees in tool results.

const CHECK_FAMILY_TO_PROVISION = Dict{String, Vector{String}}(
    "punching_shear"      => ["ACI_318.22.6"],
    "punching_shear_col"  => ["ACI_318.22.6"],
    "punching_shear_slab" => ["ACI_318.22.6"],
    "punching_shear_fdn"  => ["ACI_318.22.6"],
    "punching"            => ["ACI_318.22.6"],
    "deflection"          => ["ACI_318.24.2"],
    "PM_interaction"      => ["ACI_318.22.4", "AISC_360.H1"],
    "P-M_interaction"     => ["ACI_318.22.4", "AISC_360.H1"],
    "pm_interaction"      => ["ACI_318.22.4", "AISC_360.H1"],
    "flexure"             => ["ACI_318.9.5"],
    "flexure_fdn"         => ["ACI_318.9.5"],
    "one_way_shear"       => ["ACI_318.11.2"],
    "shear"               => ["ACI_318.11.2"],
    "LTB"                 => ["AISC_360.F2"],
    "ltb"                 => ["AISC_360.F2"],
    "flexural_buckling"   => ["AISC_360.E3"],
    "buckling"            => ["AISC_360.E3"],
    "slenderness"         => ["ACI_318.10.10"],
    "convergence"         => ["general.convergence"],
    "combined_forces"     => ["AISC_360.H1"],
    "axial_capacity"      => ["AISC_360.E3", "ACI_318.22.4"],
    "axial_compression"   => ["AISC_360.E3", "ACI_318.22.4"],
    "bearing"             => String[],
    "fire_protection"     => ["IBC.Table_601"],
    "foundation_bearing"  => ["general.foundation_bearing"],
)

# ─── Lookup helpers ──────────────────────────────────────────────────────────

"""
    get_provision_ontology(section::String) -> Union{Dict, Nothing}

Look up a provision by section number (e.g., "22.6", "H1"), full key
(e.g., "ACI_318.22.6"), or check family name (e.g., "punching_shear").
When a check family maps to multiple provisions, returns the first.
"""
function get_provision_ontology(section::String)::Union{Dict{String, Any}, Nothing}
    for (key, entry) in PROVISION_ONTOLOGY
        if entry["section"] == section || key == section
            return entry
        end
    end
    # Fallback: check family name lookup
    prov_keys = get(CHECK_FAMILY_TO_PROVISION, section, nothing)
    if isnothing(prov_keys)
        prov_keys = get(CHECK_FAMILY_TO_PROVISION, lowercase(section), nothing)
    end
    if isnothing(prov_keys)
        base = replace(lowercase(section), r"_(col|slab|fdn|beam)$" => "")
        prov_keys = get(CHECK_FAMILY_TO_PROVISION, base, nothing)
    end
    if !isnothing(prov_keys) && !isempty(prov_keys)
        return get(PROVISION_ONTOLOGY, prov_keys[1], nothing)
    end
    return nothing
end

"""
    get_provisions_for_check(check_family::String) -> Vector{Dict{String, Any}}

Return all PROVISION_ONTOLOGY entries that govern a given check family.
Handles element-type suffixes (`_col`, `_slab`, `_fdn`) and case variations.
"""
function get_provisions_for_check(check_family::String)::Vector{Dict{String, Any}}
    prov_keys = get(CHECK_FAMILY_TO_PROVISION, check_family, nothing)
    if isnothing(prov_keys)
        prov_keys = get(CHECK_FAMILY_TO_PROVISION, lowercase(check_family), nothing)
    end
    if isnothing(prov_keys)
        # Strip common element-type suffixes and retry
        base = replace(lowercase(check_family), r"_(col|slab|fdn|beam)$" => "")
        prov_keys = get(CHECK_FAMILY_TO_PROVISION, base, nothing)
    end
    isnothing(prov_keys) && return Dict{String, Any}[]
    return [PROVISION_ONTOLOGY[k] for k in prov_keys if haskey(PROVISION_ONTOLOGY, k)]
end

"""
    get_system_dependencies(system::String) -> Union{Dict, Nothing}

Look up system dependency info (e.g., "flat_plate", "steel_columns").
"""
function get_system_dependencies(system::String)::Union{Dict{String, Any}, Nothing}
    return get(SYSTEM_DEPENDENCIES, lowercase(system), nothing)
end

"""
    get_code_rationale(parameter::String, value::Union{String, Nothing}=nothing) -> Union{Dict, Nothing}

Look up the rationale for a parameter and optionally a specific value.
Tries exact match first, then common singular/plural variants.
"""
function get_code_rationale(parameter::String, value::Union{String, Nothing}=nothing)::Union{Dict{String, Any}, Nothing}
    entry = get(CODE_RATIONALE, parameter, nothing)
    if isnothing(entry)
        # Try singular/plural normalization
        if endswith(parameter, "s")
            entry = get(CODE_RATIONALE, parameter[1:end-1], nothing)
        else
            entry = get(CODE_RATIONALE, parameter * "s", nothing)
        end
    end
    isnothing(entry) && return nothing
    isnothing(value) && return entry
    return get(entry, value, entry)
end

"""
    ontology_coverage_report() -> Dict{String, Any}

Return a summary of ontology coverage across all three structures.
"""
function ontology_coverage_report()::Dict{String, Any}
    prov_counts = Dict("full" => 0, "partial" => 0, "stub" => 0)
    for (_, e) in PROVISION_ONTOLOGY
        c = get(e, "coverage", "stub")
        prov_counts[c] = get(prov_counts, c, 0) + 1
    end

    sys_counts = Dict("full" => 0, "partial" => 0, "stub" => 0)
    for (_, e) in SYSTEM_DEPENDENCIES
        c = get(e, "coverage", "stub")
        sys_counts[c] = get(sys_counts, c, 0) + 1
    end

    return Dict{String, Any}(
        "provisions" => Dict(
            "total" => length(PROVISION_ONTOLOGY),
            "coverage" => prov_counts,
        ),
        "systems" => Dict(
            "total" => length(SYSTEM_DEPENDENCIES),
            "coverage" => sys_counts,
        ),
        "rationale_families" => length(CODE_RATIONALE),
    )
end
