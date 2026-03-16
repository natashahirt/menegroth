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
            "accepted" => "feet, ft, inches, in, meters, m, millimeters, mm, centimeters, cm",
        ),
        "vertices" => Dict(
            "type" => "array of [x, y, z]",
            "required" => true,
            "description" => "Array of vertex coordinates; at least 4 required.",
        ),
        "edges" => Dict(
            "type" => "object",
            "description" => "Beam, column, and brace connectivity.",
            "fields" => Dict(
                "beams" => "Array of [v1, v2] vertex index pairs (1-based).",
                "columns" => "Array of [v1, v2] vertex index pairs (1-based).",
                "braces" => "Array of [v1, v2] vertex index pairs (1-based).",
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
        "params" => Dict(
            "type" => "object",
            "description" => "Design parameters; all fields optional with defaults below.",
            "fields" => Dict(
                "unit_system" => "Display units: \"imperial\" or \"metric\". Default: \"imperial\".",
                "loads" => Dict(
                    "floor_LL_psf" => "Floor live load (psf). Default: 80.",
                    "roof_LL_psf" => "Roof live load (psf). Default: 20.",
                    "grade_LL_psf" => "Grade live load (psf). Default: 100.",
                    "floor_SDL_psf" => "Floor superimposed dead (psf). Default: 15.",
                    "roof_SDL_psf" => "Roof superimposed dead (psf). Default: 15.",
                    "wall_SDL_psf" => "Wall superimposed dead (psf). Default: 10.",
                ),
                "floor_type" => "flat_plate | flat_slab | one_way | vault. Default: flat_plate.",
                "floor_options" => Dict(
                    "method" => "DDM | DDM_SIMPLIFIED | EFM | EFM_HARDY_CROSS | FEA. Default: DDM.",
                    "deflection_limit" => "L_240 | L_360 | L_480. Default: L_360.",
                    "punching_strategy" => "grow_columns | reinforce_last | reinforce_first. Default: grow_columns.",
                    "target_edge_m" => "Optional. FEA mesh target edge length (m). Default: adaptive clamp(min_span/20, 0.15, 0.75). Used when method is FEA.",
                    "vault_lambda" => "Optional vault span/rise ratio (dimensionless, > 0). Used when floor_type is vault.",
                ),
                "visualization_target_edge_m" => "Optional. Visualization shell mesh target edge (m). Default: inherits from FEA target_edge when method is FEA, else adaptive. Coarser = faster viz.",
                "skip_visualization" => "When true, skip shell mesh build and visualization serialization (faster response, frame-only). Default: false.",
                "visualization_detail" => "minimal | full. minimal = frame elements + slab boundaries only (no deflected meshes, no per-face analytical). full = full visualization. Default: full.",
                "scoped_overrides" => "Optional list of scoped floor overrides. Each override provides face polygons and floor-specific options applied only to matching cells.",
                "materials" => Dict(
                    "concrete" => "Slab/floor concrete (e.g. NWC_4000, Earthen_500, Earthen_2000). Default: NWC_4000.",
                    "column_concrete" => "Column concrete (e.g. NWC_6000). Default: NWC_6000.",
                    "rebar" => "Rebar name (e.g. Rebar_60). Default: Rebar_60.",
                    "steel" => "Steel name (e.g. A992). Default: A992.",
                ),
                "column_type" => "rc_rect | rc_circular | steel_w | steel_hss | steel_pipe | pixelframe. Default: rc_rect.",
                "column_catalog" => "Optional column catalog (string or null). Steel (steel_w/steel_hss/steel_pipe): compact_only | preferred | all. RC rectangular (rc_rect): standard | square | rectangular | low_capacity | high_capacity | all. RC circular (rc_circular): standard | low_capacity | high_capacity | all. Ignored for pixelframe. If omitted or null: defaults to preferred (steel) or standard (RC).",
                "column_sizing_strategy" => "discrete (MIP catalog) or nlp (continuous Ipopt). Default: discrete. Applies to RC and steel columns.",
                "mip_time_limit_sec" => "MIP solver time limit (seconds) when discrete sizing. Default: 30.",
                "beam_type" => "steel_w | steel_hss | rc_rect | rc_tbeam | pixelframe. Default: steel_w.",
                "beam_catalog" => "RC beam catalog when beam_type is rc_rect or rc_tbeam: standard | small | large | xlarge | all | custom. Default: large. Use xlarge for vaults with high thrust. Use custom with beam_catalog_bounds for bounds-based catalog. Ignored for pixelframe.",
                "beam_sizing_strategy" => "discrete (MIP catalog) or nlp (continuous Ipopt). Default: discrete. Applies to RC and steel beams.",
                "beam_catalog_bounds" => "Required when beam_catalog is custom. Object: min_width_in, max_width_in, min_depth_in, max_depth_in, resolution_in (all in inches).",
                "pixelframe_options" => "When column_type or beam_type is pixelframe. Object: fc_preset (standard | low | high | extended | custom) or fc_min_ksi, fc_max_ksi, fc_resolution_ksi when custom. Default: standard.",
                "fire_rating" => "Fire rating (hours): 0, 1, 1.5, 2, 3, or 4. Default: 0.",
                "optimize_for" => "weight | carbon | cost. Default: weight.",
                "size_foundations" => "Boolean. Default: false.",
                "foundation_soil" => "Soil name (e.g. medium_sand). Required when size_foundations is true. Default: medium_sand.",
                "foundation_concrete" => "Foundation concrete (e.g. NWC_3000). Default: NWC_3000.",
                "foundation_options" => Dict(
                    "strategy" => "auto | all_spread | all_strip | mat. Default: auto.",
                    "mat_coverage_threshold" => "Switch to mat when coverage ratio exceeds this (0–1). Default: 0.5.",
                    "spread_params" => "Optional. cover_in, min_depth_in, bar_size, depth_increment_in, size_increment_in (inches).",
                    "strip_params" => "Optional. cover_in, min_depth_in, bar_size_long, bar_size_trans, width_increment_in, max_depth_ratio, merge_gap_factor, eccentricity_limit.",
                    "mat_params" => "Optional. cover_in, min_depth_in, bar_size_x, bar_size_y, depth_increment_in, edge_overhang_in, analysis_method (rigid | shukla | winkler).",
                ),
            ),
        ),
        "geometry_hash" => Dict(
            "type" => "string",
            "required" => false,
            "description" => "Ignored; server recomputes hash. Reserved for forward compatibility.",
        ),
    )
end

# ─── Input Schema ────────────────────────────────────────────────────────────
# Input structs are `mutable` so that StructTypes.Mutable() can construct them
# via the no-arg constructor and then set only the fields present in JSON.
# This lets missing JSON keys fall back to @kwdef defaults.

"""Raw edge groups from JSON: `{"beams": [[1,2],...], "columns": [[3,4],...], "braces": [...]}`."""
Base.@kwdef mutable struct APIEdgeGroups
    beams::Vector{Vector{Int}} = Vector{Int}[]
    columns::Vector{Vector{Int}} = Vector{Int}[]
    braces::Vector{Vector{Int}} = Vector{Int}[]
end

"""Raw face groups from JSON (optional). Keys are category names, values are
arrays of polylines (each polyline is an array of [x,y,z] arrays)."""
const APIFaceGroups = Dict{String, Vector{Vector{Vector{Float64}}}}

"""Raw load parameters from JSON."""
Base.@kwdef mutable struct APILoads
    floor_LL_psf::Float64 = 80.0
    roof_LL_psf::Float64 = 20.0
    grade_LL_psf::Float64 = 100.0
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
    steel::String = "A992"
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

"""Optional foundation options from JSON (strategy + per-type overrides)."""
Base.@kwdef mutable struct APIFoundationOptions
    strategy::String = "auto"
    mat_coverage_threshold::Float64 = 0.5
    spread_params::Union{APISpreadParams, Nothing} = nothing
    strip_params::Union{APIStripParams, Nothing} = nothing
    mat_params::Union{APIMatParams, Nothing} = nothing
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
    beam_sizing_strategy::String = "discrete"  # RC beams only: discrete | nlp
    beam_catalog_bounds::Union{APIBeamCatalogBounds, Nothing} = nothing  # Required when beam_catalog is "custom".
    pixelframe_options::Union{APIPixelFrameOptions, Nothing} = nothing  # When column_type or beam_type is pixelframe.
    fire_rating::Float64 = 0.0
    optimize_for::String = "weight"
    size_foundations::Bool = false
    foundation_soil::String = "medium_sand"
    foundation_concrete::String = "NWC_3000"
    foundation_options::Union{APIFoundationOptions, Nothing} = nothing
    scoped_overrides::Vector{APIScopedOverride} = APIScopedOverride[]
    geometry_is_centerline::Bool = false
    visualization_target_edge_m::Union{Float64, Nothing} = nothing  # Viz shell mesh target edge (m). Default: FEA or adaptive.
    skip_visualization::Bool = false  # Skip shell mesh + viz serialization for faster response.
    visualization_detail::String = "full"  # "minimal" | "full". minimal = no deflected slab meshes.
end

"""
Top-level input payload from JSON.

`geometry_hash` is accepted for forward-compatibility but ignored — the server
always recomputes the hash via `compute_geometry_hash(input)`.
"""
Base.@kwdef mutable struct APIInput
    units::String = ""
    vertices::Vector{Vector{Float64}} = Vector{Float64}[]
    edges::APIEdgeGroups = APIEdgeGroups()
    supports::Vector{Int} = Int[]
    stories_z::Vector{Float64} = Float64[]
    faces::APIFaceGroups = APIFaceGroups()
    params::APIParams = APIParams()
    geometry_hash::String = ""
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
StructTypes.StructType(::Type{APIFoundationOptions}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIBeamCatalogBounds}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIPixelFrameOptions}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIParams}) = StructTypes.Mutable()
StructTypes.StructType(::Type{APIInput}) = StructTypes.Mutable()

# ─── Output Schema ───────────────────────────────────────────────────────────
# Output structs are immutable (write-only, never parsed from JSON).

"""Slab result for JSON output."""
Base.@kwdef struct APISlabResult
    id::Int = 0
    ok::Bool = true
    thickness::Float64 = 0.0
    converged::Bool = true
    failure_reason::String = ""
    failing_check::String = ""
    iterations::Int = 0
    deflection_ok::Bool = true
    deflection_ratio::Float64 = 0.0
    punching_ok::Bool = true
    punching_max_ratio::Float64 = 0.0
end

"""Column result for JSON output."""
Base.@kwdef struct APIColumnResult
    id::Int = 0
    section::String = ""
    c1::Float64 = 0.0
    c2::Float64 = 0.0
    shape::String = "rectangular"
    axial_ratio::Float64 = 0.0
    interaction_ratio::Float64 = 0.0
    ok::Bool = true
end

"""Beam result for JSON output."""
Base.@kwdef struct APIBeamResult
    id::Int = 0
    section::String = ""
    flexure_ratio::Float64 = 0.0
    shear_ratio::Float64 = 0.0
    ok::Bool = true
end

"""Foundation result for JSON output."""
Base.@kwdef struct APIFoundationResult
    id::Int = 0
    length::Float64 = 0.0
    width::Float64 = 0.0
    depth::Float64 = 0.0
    bearing_ratio::Float64 = 0.0
    ok::Bool = true
end

"""Design summary for JSON output."""
Base.@kwdef struct APISummary
    all_pass::Bool = true
    concrete_volume::Float64 = 0.0
    steel_weight::Float64 = 0.0
    rebar_weight::Float64 = 0.0
    embodied_carbon_kgCO2e::Float64 = 0.0
    critical_ratio::Float64 = 0.0
    critical_element::String = ""
end

"""Error response payload."""
Base.@kwdef struct APIError
    status::String = "error"
    error::String = ""
    message::String = ""
    traceback::String = ""
end

# ─── Visualization Schema ────────────────────────────────────────────────────────

"""Node position and displacement from analysis model."""
Base.@kwdef struct APIVisualizationNode
    node_id::Int = 0              # 1-based node index in analysis model
    position::Vector{Float64} = [0.0, 0.0, 0.0]  # Original position [x, y, z] in display length units
    displacement::Vector{Float64} = [0.0, 0.0, 0.0]  # [dx, dy, dz] in display length units
    deflected_position::Vector{Float64} = [0.0, 0.0, 0.0]  # position + displacement in display length units
    is_support::Bool = false       # True if node corresponds to a structural support
end

"""Frame element with connectivity and design data."""
Base.@kwdef struct APIVisualizationFrameElement
    element_id::Int = 0           # Element index in analysis model
    node_start::Int = 0            # 1-based start node index
    node_end::Int = 0              # 1-based end node index
    element_type::String = ""     # "beam", "column", "strut", or "other"
    utilization_ratio::Float64 = 0.0
    ok::Bool = true
    section_name::String = ""      # e.g., "W14x90", "16x16"
    material_color_hex::String = "" # Optional material display color (e.g. "#6E6E6E")
    # Section geometry for rendering
    section_type::String = ""      # "W-shape", "rectangular", "HSS_rect", "HSS_round", etc.
    section_depth::Float64 = 0.0
    section_width::Float64 = 0.0
    # Additional dimensions for W-shapes
    flange_width::Float64 = 0.0
    web_thickness::Float64 = 0.0
    flange_thickness::Float64 = 0.0
    # 2D section polygon in local y-z coordinates (centroid at origin)
    # Each vertex is [y, z] in feet, where y = width direction, z = depth direction
    section_polygon::Vector{Vector{Float64}} = []  # [[y1, z1], [y2, z2], ...]
    # Inner boundary for hollow sections (HSS rect/round); empty for solid sections
    section_polygon_inner::Vector{Vector{Float64}} = []  # [[y1, z1], [y2, z2], ...]
    # Interpolated deflected curve (cubic interpolation from FEA)
    original_points::Vector{Vector{Float64}} = []   # [[x,y,z], ...] original positions in feet
    displacement_vectors::Vector{Vector{Float64}} = []  # [[dx,dy,dz], ...] displacements at each point in feet
    # Analytical: signed extremum along element length (value with largest |·|, sign preserved)
    max_axial_force::Float64 = 0.0   # signed P extremum [N] (+ tension, − compression)
    max_moment::Float64 = 0.0        # signed M extremum [N·m] (largest |My| or |Mz|)
    max_shear::Float64 = 0.0         # signed V extremum [N] (largest |Vy| or |Vz|)
end

"""Slab geometry for sized mode (3D boxes from cell boundaries)."""
Base.@kwdef struct APIDropPanelPatch
    center::Vector{Float64} = [0.0, 0.0, 0.0]  # [x,y,z_top] in display length units
    length::Float64 = 0.0  # full extent in local-x/global-x direction
    width::Float64 = 0.0   # full extent in local-y/global-y direction
    extra_depth::Float64 = 0.0  # projection below slab soffit
end

"""Slab geometry for sized mode (3D boxes from cell boundaries)."""
Base.@kwdef struct APISizedSlab
    slab_id::Int = 0
    boundary_vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] cell boundary vertices in feet
    thickness::Float64 = 0.0
    z_top::Float64 = 0.0  # Top surface elevation
    drop_panels::Vector{APIDropPanelPatch} = []
    utilization_ratio::Float64 = 0.0
    ok::Bool = true
    # Vault-specific curved mesh (intrados surface only, extrados = intrados + thickness)
    is_vault::Bool = false
    vault_mesh_vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] intrados surface
    vault_mesh_faces::Vector{Vector{Int}} = []         # [[i,j,k], ...] triangle indices (1-based)
end

"""Slab mesh for deflected mode (analysis model triangulation)."""
Base.@kwdef struct APIDeflectedSlabMesh
    slab_id::Int = 0
    vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] original positions in feet
    vertex_displacements::Vector{Vector{Float64}} = []  # [[dx,dy,dz], ...] displacements at each vertex in feet
    vertex_displacements_local::Vector{Vector{Float64}} = []  # [[dx,dy,dz], ...] local-bending displacements in feet
    faces::Vector{Vector{Int}} = []         # [[i1,i2,i3], ...] triangle indices (1-based)
    thickness::Float64 = 0.0
    drop_panels::Vector{APIDropPanelPatch} = []
    utilization_ratio::Float64 = 0.0
    ok::Bool = true
    is_vault::Bool = false  # For material coloring (earthen vs concrete)
    # Analytical: per-face scalar values for force/stress visualization (one per face, face order matches `faces`)
    # Signed quantities use diverging color (red + → white → blue −); von Mises/shear are always ≥ 0.
    face_bending_moment::Vector{Float64} = []   # signed dominant principal moment [N·m/m] (+ sagging, − hogging)
    face_membrane_force::Vector{Float64} = []   # signed dominant principal membrane force [N/m] (+ tension, − compression)
    face_shear_force::Vector{Float64} = []      # √(Qxz² + Qyz²) transverse shear resultant [N/m] (always ≥ 0)
    face_von_mises::Vector{Float64} = []        # max von Mises stress at top/bottom surface [Pa] (always ≥ 0)
    face_surface_stress::Vector{Float64} = []   # signed dominant principal stress at top/bottom [Pa] (+ tension, − compression)
end

"""Foundation geometry for visualization (axis-aligned block centered at support group centroid)."""
Base.@kwdef struct APIVisualizationFoundation
    foundation_id::Int = 0
    center::Vector{Float64} = [0.0, 0.0, 0.0]  # [x,y,z_top] in display length units
    length::Float64 = 0.0
    width::Float64 = 0.0
    depth::Float64 = 0.0
    utilization_ratio::Float64 = 0.0
    ok::Bool = true
end

"""Complete visualization data from analysis model."""
Base.@kwdef struct APIVisualization
    nodes::Vector{APIVisualizationNode} = []
    frame_elements::Vector{APIVisualizationFrameElement} = []
    sized_slabs::Vector{APISizedSlab} = []
    deflected_slab_meshes::Vector{APIDeflectedSlabMesh} = []
    foundations::Vector{APIVisualizationFoundation} = []
    is_beamless_system::Bool = false
    suggested_scale_factor::Float64 = 1.0
    max_displacement::Float64 = 0.0
    # Global maxima for analytical color normalization (max |value| for diverging scale symmetry)
    max_frame_axial::Float64 = 0.0      # max |P| across all frame elements [N]
    max_frame_moment::Float64 = 0.0     # max |M| across all frame elements [N·m]
    max_frame_shear::Float64 = 0.0      # max |V| across all frame elements [N]
    max_slab_bending::Float64 = 0.0     # max |principal moment| across all slab faces [N·m/m]
    max_slab_membrane::Float64 = 0.0    # max |principal membrane force| across all faces [N/m]
    max_slab_shear::Float64 = 0.0       # max transverse shear across all faces [N/m] (≥ 0)
    max_slab_von_mises::Float64 = 0.0   # max von Mises stress across all faces [Pa] (≥ 0)
    max_slab_surface_stress::Float64 = 0.0 # max |principal stress| across all faces [Pa]
end

"""Top-level output payload."""
Base.@kwdef struct APIOutput
    status::String = "ok"
    compute_time_s::Float64 = 0.0
    phase_timings::Dict{String, Float64} = Dict{String, Float64}()
    length_unit::String = "ft"
    thickness_unit::String = "in"
    volume_unit::String = "ft3"
    mass_unit::String = "lb"
    summary::APISummary = APISummary()
    slabs::Vector{APISlabResult} = APISlabResult[]
    columns::Vector{APIColumnResult} = APIColumnResult[]
    beams::Vector{APIBeamResult} = APIBeamResult[]
    foundations::Vector{APIFoundationResult} = APIFoundationResult[]
    geometry_hash::String = ""
    visualization::Union{APIVisualization, Nothing} = nothing
end

StructTypes.StructType(::Type{APISlabResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIColumnResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIBeamResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIFoundationResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APISummary}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIOutput}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIError}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationNode}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationFrameElement}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIDropPanelPatch}) = StructTypes.Struct()
StructTypes.StructType(::Type{APISizedSlab}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIDeflectedSlabMesh}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationFoundation}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualization}) = StructTypes.Struct()