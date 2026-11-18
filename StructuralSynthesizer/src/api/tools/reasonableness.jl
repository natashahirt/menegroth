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

