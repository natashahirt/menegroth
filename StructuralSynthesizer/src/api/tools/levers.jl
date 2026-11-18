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
        "direction"  => "DEMAND-SIDE: Punching stress = Vu/(b₀·d). Larger column → larger b₀ (critical perimeter) → lower stress. " *
                         "grow_columns directly increases b₀, which is the most reliable lever. " *
                         "CAPACITY-SIDE: reinforce_first adds shear stud/stirrup capacity but does NOT grow columns — " *
                         "columns may be SMALLER (sized for P-M only) so unreinforced punching ratio worsens. " *
                         "⚠ COUPLING: Higher f'c increases Vc in isolation but the column sizer may pick SMALLER columns " *
                         "(less area needed for axial load), shrinking b₀ and potentially NET-WORSENING punching. " *
                         "Always run a micro-experiment before recommending f'c changes for punching.",
    ),
    # Column punching (diagnose: "punching_shear_col")
    "punching_shear_col" => Dict(
        "parameters" => ["punching_strategy", "column_catalog", "column_concrete", "floor_type"],
        "geometry"   => ["column_size", "slab_span"],
        "direction"  => "DEMAND-SIDE: Punching stress = Vu/(b₀·d). Larger column → larger b₀ → lower stress. " *
                         "grow_columns directly increases column dimensions to improve b₀. " *
                         "Enlarging the column_catalog pool allows the sizer to pick bigger sections. " *
                         "CAPACITY-SIDE: reinforce_first adds stud/stirrup capacity but columns stay at P-M minimum — " *
                         "may be SMALLER than grow_columns would produce. " *
                         "⚠ COUPLING: Higher f'c increases Vc but the column sizer may select SMALLER columns " *
                         "(less area needed for axial), shrinking b₀ and potentially NET-WORSENING punching. " *
                         "Always run a micro-experiment before recommending f'c changes for punching.",
    ),
    # Foundation punching (diagnose: "punching_shear_fdn")
    "punching_shear_fdn" => Dict(
        "parameters" => ["foundation_concrete", "foundation_options"],
        "geometry"   => ["column_count"],
        "direction"  => "Thicker footing increases d (effective depth) and therefore punching capacity. " *
                         "Higher f'c increases Vc. Foundation punching is less coupled because footing " *
                         "depth is sized for punching directly, not for a separate check like column P-M.",
    ),
    # Generic alias — matches any "punching_shear" query
    "punching_shear" => Dict(
        "parameters" => ["punching_strategy", "column_concrete", "floor_type", "column_catalog"],
        "geometry"   => ["column_size", "slab_span"],
        "direction"  => "DEMAND-SIDE: Punching stress = Vu/(b₀·d). Larger columns → larger b₀ → lower stress. " *
                         "grow_columns is the most reliable lever because it directly increases b₀. " *
                         "CAPACITY-SIDE: reinforce_first adds shear stud/stirrup capacity but does NOT grow columns — " *
                         "columns may end up SMALLER (sized for P-M only). " *
                         "⚠ COUPLING: Higher f'c increases Vc in isolation, but the column sizer may pick SMALLER " *
                         "columns (less area for axial), shrinking b₀ and potentially WORSENING punching. " *
                         "Always run a micro-experiment to verify before recommending f'c or reinforce_first. " *
                         "See punching_shear_col / punching_shear_slab / punching_shear_fdn for element-specific details.",
    ),
    "flexure" => Dict(
        "parameters" => ["floor_type", "concrete", "rebar"],
        "geometry"   => ["span_length"],
        "direction"  => "thicker slab or higher rebar grade increases capacity; shorter spans reduce demand. " *
                         "Note: deflection_limit does NOT affect flexural strength — it is a serviceability lever " *
                         "(though a stricter limit may force a thicker slab, which indirectly adds flexural capacity).",
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
        "direction"  => "PRIMARY: Reduce span length (deflection ∝ L⁴) — adding columns or subdividing bays " *
                         "in Grasshopper is the most effective lever. " *
                         "SECONDARY: Relaxing L/360→L/240 allows a thinner section but should only be " *
                         "suggested if the project can tolerate additional deflection (no sensitive " *
                         "partitions or equipment). Higher f'c increases Ec and reduces deflection.",
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
        "direction"  => "higher allowable bearing pressure (qa) or larger footings improve bearing adequacy; " *
                         "more columns reduce reaction per footing",
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

