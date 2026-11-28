"""Slab result for JSON output."""
Base.@kwdef struct APISlabResult
    id::Int = 0
    ok::Bool = true
    thickness::Float64 = 0.0
    converged::Bool = true
    failure_reason::String = ""
    failing_checks::Vector{String} = String[]
    failure_detail::Union{String, Nothing} = nothing
    iterations::Int = 0
    deflection_ok::Bool = true
    deflection_ratio::Float64 = 0.0
    punching_ok::Bool = true
    punching_max_ratio::Float64 = 0.0
end

"""Canonical section type codes for column and beam results."""
const API_SECTION_TYPES = (
    "steel_w",
    "steel_hss_rect",
    "steel_hss_round",
    "rc_rect",
    "rc_circular",
    "rc_tbeam",
    "pixelframe",
    "other",
    "",
)

"""Column result for JSON output."""
Base.@kwdef struct APIColumnResult
    id::Int = 0
    section::String = ""
    section_type::String = ""
    c1::Float64 = 0.0
    c2::Float64 = 0.0
    shape::String = "rectangular"
    # Nullable: an UNVERIFIED column (steel §E3/§E4 buckling capacity unavailable) carries a
    # NaN axial/interaction sentinel, which `_round_val` serializes as `nothing` (JSON null).
    # These MUST be `Union{Float64, Nothing}` — a strict `Float64` field would throw a
    # `MethodError` (`convert(Float64, nothing)`) in `_serialize_columns`, crashing GET /result
    # for that column. A `null` ratio with `ok = false` reports it honestly as unverified/failing
    # and can never be read as a passing `0.0` utilization.
    axial_ratio::Union{Float64, Nothing} = 0.0
    interaction_ratio::Union{Float64, Nothing} = 0.0
    ok::Bool = true
    # Row F frame check. `nothing` ratio when this column was not in that check.
    seismic_frame_ratio::Union{Float64, Nothing} = nothing
    seismic_frame_check::String = ""
end

"""Beam result for JSON output."""
Base.@kwdef struct APIBeamResult
    id::Int = 0
    section::String = ""
    section_type::String = ""
    depth::Float64 = 0.0
    width::Float64 = 0.0
    flexure_ratio::Float64 = 0.0
    shear_ratio::Float64 = 0.0
    ok::Bool = true
    seismic_frame_ratio::Union{Float64, Nothing} = nothing
    seismic_frame_check::String = ""
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
    # For beams/columns: matches `columns[].id` / `beams[].id` in the design payload (skeleton member index).
    # For struts and unmapped edges: Asap analysis `elementID` (internal to the FE model).
    element_id::Int = 0
    node_start::Int = 0            # 1-based start node index
    node_end::Int = 0              # 1-based end node index
    element_type::String = ""     # "beam", "column", "strut", or "other"
    # Nullable (mirrors `APIColumnResult`): an UNVERIFIED column (steel §E3/§E4 buckling
    # capacity unavailable) carries a NaN axial/interaction sentinel that `_round_val`
    # serializes to `nothing`. `_serialize_visualization_frame_elements` already guards the
    # aggregate to a finite failing sentinel (≥ 1.0), so this never receives `nothing` in
    # practice — but a strict `Float64` here would throw `convert(Float64, nothing)` and crash
    # GET /result if any future path let a non-finite ratio through. `null` + `ok = false`
    # renders as failing/attention and can never be read as a passing `0.0` utilization.
    utilization_ratio::Union{Float64, Nothing} = 0.0
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
    # Cross-section rotation about the element axis (radians, CCW from global X).
    # Non-zero for columns with θ ≠ 0; beams always 0.
    orientation_angle::Float64 = 0.0
    # 2D section polygon in local y-z coordinates (centroid at origin)
    # Each vertex is [y, z] in display length units, where y = width direction, z = depth direction
    section_polygon::Vector{Vector{Float64}} = []  # [[y1, z1], [y2, z2], ...]
    # Inner boundary for hollow sections (HSS rect/round); empty for solid sections
    section_polygon_inner::Vector{Vector{Float64}} = []  # [[y1, z1], [y2, z2], ...]
    # Longitudinal bar centres for RC columns, same frame and units as section_polygon;
    # empty for sections without rebar. rebar_diameter is the equivalent-area bar diameter.
    rebar_positions::Vector{Vector{Float64}} = []  # [[y1, z1], [y2, z2], ...]
    rebar_diameter::Float64 = 0.0
    # Headed studs on a composite beam. Each stud is [[s, y, z], ...] in the
    # same length unit as section_polygon. s is the distance from node_start
    # along the element. y and z are the shank base in the section frame:
    # y across the flange, z at the top of steel. The shank runs stud_length
    # in the +z direction. Empty when the element carries no studs.
    stud_positions::Vector{Vector{Float64}} = []  # [[s, y, z], ...]
    stud_diameter::Float64 = 0.0
    stud_length::Float64 = 0.0
    # Interpolated deflected curve (cubic interpolation from FEA)
    original_points::Vector{Vector{Float64}} = []   # [[x,y,z], ...] original positions in display length units
    displacement_vectors::Vector{Vector{Float64}} = []  # [[dx,dy,dz], ...] displacements at each point in display length units
    # Analytical: signed extremum along element length (value with largest |·|, sign preserved)
    max_axial_force::Float64 = 0.0   # signed P extremum [N] (+ tension, − compression)
    max_moment::Float64 = 0.0        # signed M extremum [N·m] (largest |My| or |Mz|)
    max_shear::Float64 = 0.0         # signed V extremum [N] (largest |Vy| or |Vz|)
    # Sized mode: pre-built mesh for fast rendering (same pattern as deflected_slab_meshes).
    # Empty for hollow sections or when section polygon is invalid; client falls back to sweep.
    mesh_vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] in display length units
    mesh_faces::Vector{Vector{Int}} = []          # [[i1,i2,i3], ...] triangle indices (1-based)
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
    boundary_vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] cell boundary vertices in display length units
    thickness::Float64 = 0.0
    z_top::Float64 = 0.0  # Top surface elevation
    drop_panels::Vector{APIDropPanelPatch} = []
    utilization_ratio::Float64 = 0.0
    ok::Bool = true
    material_color_hex::String = ""  # Display color from slab concrete material (e.g. "#B4B4B4")
    # Vault-specific curved mesh (intrados surface only, extrados = intrados + thickness)
    is_vault::Bool = false
    vault_mesh_vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] intrados surface
    vault_mesh_faces::Vector{Vector{Int}} = []         # [[i,j,k], ...] triangle indices (1-based)
end

"""
Drop panel sub-mesh for deflected mode.  Face indices reference into the parent
`APIDeflectedSlabMesh.faces` array (1-based).  The C# renderer builds the drop
panel volume by extracting these faces from the deflected slab mesh and offsetting
downward by `thickness` (top) and `thickness + extra_depth` (bottom).
"""
Base.@kwdef struct APIDeflectedDropPanel
    face_indices::Vector{Int} = []       # 1-based indices into parent faces array
    extra_depth::Float64 = 0.0           # projection below slab soffit (display units)
end

"""Slab mesh for deflected mode (analysis model triangulation)."""
Base.@kwdef struct APIDeflectedSlabMesh
    slab_id::Int = 0
    vertices::Vector{Vector{Float64}} = []  # [[x,y,z], ...] original positions in display length units
    vertex_displacements::Vector{Vector{Float64}} = []  # [[dx,dy,dz], ...] displacements at each vertex in display length units
    vertex_displacements_local::Vector{Vector{Float64}} = []  # [[dx,dy,dz], ...] local-bending displacements in display length units
    faces::Vector{Vector{Int}} = []         # [[i1,i2,i3], ...] triangle indices (1-based)
    thickness::Float64 = 0.0
    drop_panels::Vector{APIDropPanelPatch} = []
    drop_panel_meshes::Vector{APIDeflectedDropPanel} = []
    utilization_ratio::Float64 = 0.0
    ok::Bool = true
    material_color_hex::String = ""  # Display color from slab concrete material (e.g. "#B4B4B4")
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
    material_color_hex::String = ""  # Display color from foundation concrete material
    along_x::Bool = false  # true when strip long axis runs along X (swap length/width mapping)
end

"""Unit labels for visualization analytical fields.
Positions/displacements use the display length unit; analytical quantities use SI."""
Base.@kwdef struct APIVisualizationUnits
    position::String = "ft"
    displacement::String = "ft"
    force::String = "N"
    moment::String = "N_m"
    distributed_moment::String = "N_m_per_m"
    distributed_force::String = "N_per_m"
    stress::String = "Pa"
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
    max_frame_axial::Float64 = 0.0      # max |P| across all frame elements
    max_frame_moment::Float64 = 0.0     # max |M| across all frame elements
    max_frame_shear::Float64 = 0.0      # max |V| across all frame elements
    max_slab_bending::Float64 = 0.0     # max |principal moment| across all slab faces
    max_slab_membrane::Float64 = 0.0    # max |principal membrane force| across all faces
    max_slab_shear::Float64 = 0.0       # max transverse shear across all faces (>= 0)
    max_slab_von_mises::Float64 = 0.0   # max von Mises stress across all faces (>= 0)
    max_slab_surface_stress::Float64 = 0.0 # max |principal stress| across all faces
    units::APIVisualizationUnits = APIVisualizationUnits()
end

"""One ordinary-wall check, in the checker's units (N, N·m, or a ratio)."""
Base.@kwdef struct APIWallCheck
    wall_index::Int = 0
    story::Int = 0
    direction::String = ""
    case::String = ""
    combination::String = ""
    alternative::String = ""
    check::String = ""
    passed::Bool = false
    ratio::Float64 = 0.0
    demand::Float64 = 0.0
    capacity::Float64 = 0.0
    clause::String = ""
end

"""One seismic design story-drift comparison. Lengths are metres."""
Base.@kwdef struct APISeismicStoryDrift
    story::Int = 0
    direction::String = ""
    torsion::String = ""
    drift_m::Float64 = 0.0
    allowable_m::Float64 = 0.0
    passes::Bool = false
    "`independent`, or the ASCE 7-22 §12.5.1.2 combination the drift came from."
    effect::String = "independent"
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
    walls::Vector{APIWallCheck} = APIWallCheck[]
    seismic_story_drift::Vector{APISeismicStoryDrift} = APISeismicStoryDrift[]
    # What the design did not cover. Informational; not failures.
    scope_notes::Vector{String} = String[]
    geometry_hash::String = ""
    visualization::Union{APIVisualization, Nothing} = nothing
end

StructTypes.StructType(::Type{APISlabResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIColumnResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIBeamResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIFoundationResult}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIWallCheck}) = StructTypes.Struct()
StructTypes.StructType(::Type{APISeismicStoryDrift}) = StructTypes.Struct()
StructTypes.StructType(::Type{APISummary}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIOutput}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIError}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationNode}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationFrameElement}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIDropPanelPatch}) = StructTypes.Struct()
StructTypes.StructType(::Type{APISizedSlab}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIDeflectedSlabMesh}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationFoundation}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualizationUnits}) = StructTypes.Struct()
StructTypes.StructType(::Type{APIVisualization}) = StructTypes.Struct()