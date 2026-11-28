# ─── Input Schema ────────────────────────────────────────────────────────────
# Input structs are `mutable` so that StructTypes.Mutable() can construct them
# via the no-arg constructor and then set only the fields present in JSON.
# This lets missing JSON keys fall back to @kwdef defaults.

"""
    APIEdgeGroups

Raw edge groups from JSON: `{"beams": [[1,2],...], "columns": [[3,4],...], "braces": [...], "walls": [...]}`.

Each group is an array of `[v1, v2]` vertex index pairs (1-based). `walls` defaults
to an empty vector, so payloads that omit the key stay valid.
"""
Base.@kwdef mutable struct APIEdgeGroups
    beams::Vector{Vector{Int}} = Vector{Int}[]
    columns::Vector{Vector{Int}} = Vector{Int}[]
    braces::Vector{Vector{Int}} = Vector{Int}[]
    walls::Vector{Vector{Int}} = Vector{Int}[]
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
    # Bar coating for every rebar in the project: uncoated, galvanized, epoxy,
    # or zinc_epoxy. Sets ψe in ACI 318-19 development and lap lengths.
    rebar_coating::String = "uncoated"
    steel::String = "A992"
    # Optional named timber preset for framing_levels material "timber". No
    # NDS-grounded presets ship yet (see TIMBER_MAP in deserialize.jl), so this
    # is nothing by default and a "timber" framing request errors until a
    # verified preset is registered.
    timber::Union{String, Nothing} = nothing
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
    analysis_method::Union{String, Nothing} = nothing  # "rigid" | "winkler"
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

"""
Optional global-stability (sliding/overturning/uplift) knobs from JSON.

Presence of this block turns the ASCE 7-22 global-stability checks ON for
every shallow-footing type (spread/strip/mat); omitting it reproduces the
pre-stability behaviour exactly. Each field is optional and falls back to the
`StructuralSizer.StabilityParams` default (a flagged engineering-judgment
value — see that struct's docstring). The soil friction angle `φ`, cohesion
`c`, and unit weight `γ` come from the named `foundation_soil` preset.

- `delta_ratio`: `δ = delta_ratio·φ` base friction (Bowles Table 4-5,
  `0.5 ≤ ratio ≤ 1`). Default 0.5.
- `ca_ratio`: `cₐ = ca_ratio·c` base adhesion (Bowles Table 4-5 Note 3,
  `0.6 ≤ ratio ≤ 1`). Default 0.6.
- `include_passive`: include the passive-pressure resistance term. Default true.
- `concrete_unit_weight_pcf`: footing concrete unit weight for uplift
  resistance, pounds per cubic foot. Default 150 pcf (≈ 23.6 kN/m³).
- `dead_counteracting_factor`: factor on the stabilizing self-weight,
  matching ASCE 7-22 comb. 7a `0.6D`. Default 0.6.
"""
Base.@kwdef mutable struct APIStabilityParams
    delta_ratio::Union{Float64, Nothing} = nothing
    ca_ratio::Union{Float64, Nothing} = nothing
    include_passive::Union{Bool, Nothing} = nothing
    concrete_unit_weight_pcf::Union{Float64, Nothing} = nothing
    dead_counteracting_factor::Union{Float64, Nothing} = nothing
end

"""Optional foundation options from JSON (strategy + per-type overrides)."""
Base.@kwdef mutable struct APIFoundationOptions
    strategy::String = "auto"
    mat_coverage_threshold::Float64 = 0.5
    spread_params::Union{APISpreadParams, Nothing} = nothing
    strip_params::Union{APIStripParams, Nothing} = nothing
    mat_params::Union{APIMatParams, Nothing} = nothing
    stability::Union{APIStabilityParams, Nothing} = nothing
end

"""
One requested framing level for auto-generation (Phase 5, plan
`joists-roles-materials`). The `framing_levels` array is ordered from the level
directly on the slab (index 1 — joists) outward/downward to secondary beams and
girders (index 2, 3, …).

- `material`: member material family — `"steel"`, `"concrete"`, or `"timber"`.
  Resolved from the top-level `materials` block (`steel` → structural steel;
  `concrete` → reinforced concrete = `materials.concrete` + `materials.rebar`;
  `timber` → the registered `materials.timber` preset).
- `spacing_in`: optional center-to-center joist spacing, in inches. When omitted,
  `populate_levels!` uses the sized joist spacing (mass-timber / OWSJ slabs) or an
  ENGINEERING-JUDGMENT default (opts-schema slabs).
- `role`: optional member role — `"joist"` or `"beam"`. Honored only for levels
  ≥ 2; level 1's role is fixed by the slab type. Default for levels ≥ 2 is
  `"beam"`.
- `axis`: optional in-plane joist run-direction `[x, y]`. For levels ≥ 2 the
  default alternates so consecutive levels are mutually perpendicular; for level 1
  it overrides the schema-convention direction on the opts-schema slab types
  (ignored by the joist-sizing slab types, whose geometry comes from the sizer).
- `count`: optional explicit number of members for the level.
- `end_fixity`: optional 2-element per-end release override, e.g.
  `["pinned", "pinned"]`. Accepted values: `"default"`, `"pinned"`, `"fixed"`,
  `"free"`. `"default"` defers to the `(role, material, lateral_role)` dispatch.
- `analysis`: optional panel-load owner, `"tributary"` or `"grillage"`.
  Omitted means `"tributary"`, unless `n_xi`/`n_eta` or `module_spacing_in` is
  set, which is a grillage. Any other value is an error.
- `n_xi`, `n_eta`: optional rib-bay counts for a grillage, on framing level 1
  only. Both are required together, each at least 1. They replace `spacing_in`:
  a level that sends both is an error, and so is `"tributary"` together with
  bay counts. The ribs are laid on a four-sided panel; a boundary that is not
  a quadrilateral errors when the grid is built, before member sizing.
- `module_spacing_in`: optional `[s1, s2]` rib spacings, in inches, of a module
  grid on framing level 1. The grid covers any slab outline, including holes,
  and the boundary cuts the edge modules. It replaces `n_xi`/`n_eta` and
  `spacing_in`; sending either with it is an error.
- `module_angle_deg`: optional direction of the first rib family, degrees from
  the plan x axis. Goes with `module_spacing_in`; omitted means 0.
- `solid_head`: optional fraction of the panel, from each corner, cast solid
  around the columns. Level 1 grillage with `n_xi`/`n_eta` only, in `[0, 1/2)`.
  It is snapped up to a whole rib module. Omitted means no solid head.

A level's sizing options (`beam_options`) are set on the Julia `framing_opts`
NamedTuple, not on this wire struct. A restricted catalog is
`beam_options.custom_catalog`.
"""
Base.@kwdef mutable struct APIFramingLevel
    material::String = "steel"
    spacing_in::Union{Float64, Nothing} = nothing
    role::Union{String, Nothing} = nothing
    axis::Union{Vector{Float64}, Nothing} = nothing
    count::Union{Int, Nothing} = nothing
    end_fixity::Union{Vector{String}, Nothing} = nothing
    analysis::Union{String, Nothing} = nothing
    n_xi::Union{Int, Nothing} = nothing
    n_eta::Union{Int, Nothing} = nothing
    module_spacing_in::Union{Vector{Float64}, Nothing} = nothing
    module_angle_deg::Union{Float64, Nothing} = nothing
    solid_head::Union{Float64, Nothing} = nothing
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
    beam_sizing_strategy::String = "discrete"  # :nlp only for non-composite steel W/HSS beams
    beam_catalog_bounds::Union{APIBeamCatalogBounds, Nothing} = nothing  # Required when beam_catalog is "custom".
    composite::Bool = false
    composite_slab_type::String = "solid"
    composite_t_slab_in::Union{Float64, Nothing} = nothing
    composite_anchor_d_in::Union{Float64, Nothing} = nothing
    composite_anchor_length_in::Union{Float64, Nothing} = nothing
    composite_anchor_Fu_ksi::Union{Float64, Nothing} = nothing
    composite_shored::Bool = false
    composite_cp_class::String = "medium"
    composite_deck_hr_in::Union{Float64, Nothing} = nothing
    composite_deck_wr_in::Union{Float64, Nothing} = nothing
    composite_deck_orientation::String = "from_slab"
    pixelframe_options::Union{APIPixelFrameOptions, Nothing} = nothing  # When column_type or beam_type is pixelframe.
    fire_rating::Float64 = 0.0
    optimize_for::String = "weight"
    max_iterations::Union{Int, Nothing} = nothing
    size_foundations::Bool = false
    foundation_soil::String = "medium_sand"
    foundation_concrete::String = "NWC_3000"
    foundation_options::Union{APIFoundationOptions, Nothing} = nothing
    scoped_overrides::Vector{APIScopedOverride} = APIScopedOverride[]
    # Optional multi-level framing auto-generation (Phase 5). Ordered from the
    # slab outward (index 1 = joists). Empty (default) is a strict no-op.
    framing_levels::Vector{APIFramingLevel} = APIFramingLevel[]
    uniform_column_sizing::String = "off"  # off | per_story | building. Force uniform column sizes.
    geometry_is_centerline::Bool = true
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
    # Unframed slab openings: polylines [[x, y, z], ...]; z picks the story.
    openings::Vector{Vector{Vector{Float64}}} = Vector{Vector{Float64}}[]
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
StructTypes.StructType(::Type{APIStabilityParams}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIFoundationOptions}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIBeamCatalogBounds}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIPixelFrameOptions}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIFramingLevel}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIParams}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIInput}) = StructTypes.Mutable()

