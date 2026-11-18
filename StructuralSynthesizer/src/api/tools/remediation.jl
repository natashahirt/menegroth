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

