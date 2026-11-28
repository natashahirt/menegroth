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

