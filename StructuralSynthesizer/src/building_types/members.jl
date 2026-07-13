# =============================================================================
# Member Type Hierarchy
# =============================================================================

"""Abstract base for all structural members (beams, columns, struts)."""
abstract type AbstractMember{T} end

"""
    MemberBase{T}

Shared fields for all member types. Uses composition pattern.

# PixelFrame Per-Pixel Design
For PixelFrame members, `pixel_design` stores the per-pixel material assignment.
The `section` field holds the governing section (highest-demand material), while
`pixel_design.pixel_materials` is a `Vector{FiberReinforcedConcrete}` with one
entry per physical pixel piece along the span. When `pixel_design` is set,
`volumes` is computed from per-pixel contributions rather than `section × L`.
"""
@kwdef mutable struct MemberBase{T}
    segment_indices::Vector{Int} = Int[]
    L::T                                    # Total length
    Lb::T                                   # Unbraced length (governing)
    Kx::Float64 = 1.0                       # Effective length factor (strong axis)
    Ky::Float64 = 1.0                       # Effective length factor (weak axis)
    Cb::Float64 = 1.0                       # Moment gradient factor
    group_id::Union{UInt64, Nothing} = nothing
    section::Union{AbstractSection, Nothing} = nothing
    pixel_design::Union{Nothing, StructuralSizer.PixelFrameDesign} = nothing
    volumes::MaterialVolumes = MaterialVolumes()
end

"""
    Beam{T} <: AbstractMember{T}

Horizontal member (gravity framing system).

# Fields
- `base::MemberBase{T}`: Shared member properties
- `tributary_width`: Width of tributary area for load calculations
- `role::Symbol`: `:girder` (primary), `:beam` (secondary), `:joist` (repetitive), `:infill`
"""
@kwdef mutable struct Beam{T} <: AbstractMember{T}
    base::MemberBase{T}
    tributary_width::Union{T, Nothing} = nothing
    role::Symbol = :beam
end

"""
    Column{T} <: AbstractMember{T}

Vertical member (columns).

# Fields
- `base::MemberBase{T}`: Shared member properties
- `vertex_idx::Int`: Skeleton vertex index (column location)
- `c1`, `c2`: Cross-section dimensions (for punching shear, etc.)
- `shape::Symbol`: `:rectangular` or `:circular` (for circular, c1 = c2 = D)
- `concrete`: Per-column concrete material (`nothing` → use `ConcreteColumnOptions.material`)
- `story::Int`: Story index (0 = ground level)
- `position::Symbol`: `:interior`, `:edge`, `:corner` (for punching shear coefficients)
- `boundary_inward_normals`: Unit vectors pointing from each boundary edge toward the slab interior
- `structural_offset::NTuple{2,Float64}`: Offset (m) from architectural vertex to structural centerline
- `braced`: Whether column is part of a braced frame (no sway amplification needed)
- `story_properties`: Optional story-level data for sway magnification (populated after analysis)

# Tributary Access
Tributary areas are stored in `BuildingStructure._tributary_caches` (TributaryCache).
Use accessor functions:
- `column_tributary_area(struc, col)` → total area (m²)
- `column_tributary_by_cell(struc, col)` → Dict{Int, Float64}
- `column_tributary_polygons(struc, col)` → Dict{Int, Vector{NTuple{2,Float64}}}

# Braced vs Sway Frames
- `braced=true` (default): Column is part of a braced frame. Only P-δ (member) effects apply.
- `braced=false`: Column is part of a sway (unbraced) frame. Both P-δ and P-Δ (story) effects apply.

For sway frames:
- Steel: AISC Chapter C requires B1/B2 moment amplification (not yet implemented)
- RC: ACI 318-11 §10.10.7 requires δs magnification at ends + δns along length

# Story Properties for Sway Magnification
For sway frame analysis (ACI 318-11 §10.10.7), columns need access to story-level 
properties. After structural analysis, call `compute_story_properties!(struc)` to 
populate the `story_properties` field with:
- `ΣPu`: Sum of factored axial loads on all columns in story
- `ΣPc`: Sum of critical buckling loads for all columns
- `Vus`: Factored story shear
- `Δo`: First-order story drift
- `lc`: Story height (center-to-center of joints)
"""
@kwdef mutable struct Column{T} <: AbstractMember{T}
    base::MemberBase{T}
    vertex_idx::Int = 0
    c1::Union{T, Nothing} = nothing
    c2::Union{T, Nothing} = nothing
    # Column cross-section shape: :rectangular or :circular
    # For :circular, c1 = c2 = diameter D.
    shape::Symbol = :rectangular
    # Orientation angle (radians, CCW from global X).
    # c1 is measured along the rotated local-x axis, c2 along local-y.
    # Default 0.0 → axis-aligned (c1 ∥ X, c2 ∥ Y).
    θ::Float64 = 0.0
    # Per-column concrete material (nothing → use ConcreteColumnOptions.material).
    # Set when columns on different stories use different f'c.
    concrete::Union{Nothing, StructuralSizer.Concrete} = nothing
    story::Int = 0
    position::Symbol = :interior
    # Unit vectors pointing along boundary edges (edges that belong to only one face).
    # Empty for interior columns; 1 direction for edge columns; 2+ for corners.
    # Used for DDM/EFM to determine if column is an exterior support for a given span direction.
    boundary_edge_dirs::Vector{NTuple{2, Float64}} = NTuple{2, Float64}[]
    # Inward unit normals corresponding to each boundary_edge_dir (populated by
    # update_structural_offsets!).  Each normal points from the slab edge toward
    # the slab interior, derived from the adjacent face's CCW winding.
    boundary_inward_normals::Vector{NTuple{2, Float64}} = NTuple{2, Float64}[]
    # Structural offset (meters) from the architectural vertex to the column
    # centerline.  For interior columns this is (0,0).  For edge/corner columns
    # the offset shifts inward by half the column dimension normal to each
    # boundary edge.  Recomputed whenever column dimensions change.
    structural_offset::NTuple{2, Float64} = (0.0, 0.0)
    braced::Bool = true  # Default: braced frame (no sway amplification)
    story_properties::Union{Nothing, @NamedTuple{ΣPu::Float64, ΣPc::Float64, Vus::Float64, Δo::Float64, lc::Float64}} = nothing
    # Cell indices in this column's tributary area (populated by compute_vertex_tributaries!)
    tributary_cell_indices::Set{Int} = Set{Int}()
    # Cell tributary areas in m² (populated by compute_vertex_tributaries!)
    tributary_cell_areas::Dict{Int, Float64} = Dict{Int, Float64}()
    # Column at the same (x,y) position on the story above (populated by link_column_stack!).
    # `nothing` at the roof level or when no column exists above.
    column_above::Union{Nothing, Column{T}} = nothing
end

"""
    Strut{T} <: AbstractMember{T}

Diagonal member (lateral bracing system).

# Fields
- `base::MemberBase{T}`: Shared member properties
- `brace_type::Symbol`: `:tension_only`, `:compression_only`, `:both`
"""
@kwdef mutable struct Strut{T} <: AbstractMember{T}
    base::MemberBase{T}
    brace_type::Symbol = :both
end

"""
    Wall{T} <: AbstractMember{T}

Planar vertical member (shear wall / structural wall) — part of the lateral-
force-resisting system. Represented as a line segment in plan spanning one
story height, so it fits alongside `Beam`/`Column`/`Strut` and skew orientations
are expressed directly by the endpoints (the skeleton already supports
arbitrary-angle edges).

This type carries the analytic-stiffness fields required by the efficiency
foundation (plan S1): the reduced diaphragm evaluator and the layout optimizer
compute a wall's in-plane lateral stiffness from geometry + material with NO FE
mesh (see `StructuralSizer/src/walls/`). Keeping these fields on the type from
S1 means S2 (rigid-diaphragm distribution) and S4 (layout optimization) layer on
without reworking `Wall`.

# Fields
- `base::MemberBase{T}`: shared member properties (`base.L` = story height)
- `x1,y1,x2,y2::Float64`: plan endpoints of the wall line [m]
- `thickness::T`: wall thickness (out of plane)
- `story::Int`: story index (0 = ground level)
- `ρl,ρt::Float64`: vertical / horizontal web reinforcement ratios
  (ACI 318-19 §11.6, min 0.0025; corpus: sp-structural-wall-reinforcement-design; VERIFY)
- `concrete`: wall concrete material (`nothing` → use a default at sizing)
- `wall_above`: the stacked wall on the story above (populated like `column_above`)

# Analytic stiffness
Use [`wall_lateral_stiffness`](@ref) to get the in-plane lateral stiffness
`[N/m]`. In-plane stiffness is linear in `thickness` (both flexural and shear
flexibility scale as 1/t), which the layout optimizer's SIMP density relaxation
relies on. Effective (cracked/uncracked) inertia per ACI 318-19
Table 6.6.3.1.1(a) (corpus: sp-effective-flexural-stiffness-aci318-14; VERIFY).
"""
@kwdef mutable struct Wall{T} <: AbstractMember{T}
    base::MemberBase{T}
    x1::Float64 = 0.0
    y1::Float64 = 0.0
    x2::Float64 = 0.0
    y2::Float64 = 0.0
    thickness::T
    story::Int = 0
    ρl::Float64 = 0.0025
    ρt::Float64 = 0.0025
    concrete::Union{Nothing, StructuralSizer.Concrete} = nothing
    wall_above::Union{Nothing, Wall{T}} = nothing
end

# -----------------------------------------------------------------------------
# Convenience constructors
# -----------------------------------------------------------------------------

"""
    Beam(seg_indices, L; Lb, Kx, Ky, Cb, group_id, role, tributary_width) -> Beam

Convenience constructor from segment indices and total length.
"""
function Beam(seg_indices::Vector{Int}, L::T; Lb=L, Kx=1.0, Ky=1.0, Cb=1.0, 
              group_id=nothing, role=:beam, tributary_width=nothing) where T
    base = MemberBase{T}(
        segment_indices=seg_indices, L=L, Lb=Lb,
        Kx=Float64(Kx), Ky=Float64(Ky), Cb=Float64(Cb),
        group_id=group_id, section=nothing, volumes=MaterialVolumes()
    )
    Beam{T}(base=base, tributary_width=tributary_width, role=role)
end

"""Single-segment beam convenience: wraps the index in a vector."""
Beam(seg_idx::Int, L::T; kwargs...) where T = Beam([seg_idx], L; kwargs...)

"""
    Column(seg_indices, L; Lb, Kx, Ky, Cb, group_id, vertex_idx, c1, c2, story, position, ...) -> Column

Convenience constructor from segment indices and total length.
"""
function Column(seg_indices::Vector{Int}, L::T; Lb=L, Kx=1.0, Ky=1.0, Cb=1.0,
                group_id=nothing, vertex_idx=0, c1=nothing, c2=nothing,
                story=0, position=:interior, boundary_edge_dirs=NTuple{2, Float64}[],
                braced=true, story_properties=nothing) where T
    base = MemberBase{T}(
        segment_indices=seg_indices, L=L, Lb=Lb,
        Kx=Float64(Kx), Ky=Float64(Ky), Cb=Float64(Cb),
        group_id=group_id, section=nothing, volumes=MaterialVolumes()
    )
    Column{T}(base=base, vertex_idx=vertex_idx, c1=c1, c2=c2,
              story=story, position=position, boundary_edge_dirs=boundary_edge_dirs,
              braced=braced, story_properties=story_properties)
end

"""Single-segment column convenience: wraps the index in a vector."""
Column(seg_idx::Int, L::T; kwargs...) where T = Column([seg_idx], L; kwargs...)

"""
    Strut(seg_indices, L; Lb, Kx, Ky, Cb, group_id, brace_type) -> Strut

Convenience constructor from segment indices and total length.
"""
function Strut(seg_indices::Vector{Int}, L::T; Lb=L, Kx=1.0, Ky=1.0, Cb=1.0,
               group_id=nothing, brace_type=:both) where T
    base = MemberBase{T}(
        segment_indices=seg_indices, L=L, Lb=Lb,
        Kx=Float64(Kx), Ky=Float64(Ky), Cb=Float64(Cb),
        group_id=group_id, section=nothing, volumes=MaterialVolumes()
    )
    Strut{T}(base=base, brace_type=brace_type)
end

"""Single-segment strut convenience: wraps the index in a vector."""
Strut(seg_idx::Int, L::T; kwargs...) where T = Strut([seg_idx], L; kwargs...)

"""
    Wall(seg_indices, height; thickness, x1, y1, x2, y2, story, ρl, ρt, concrete, group_id) -> Wall

Convenience constructor from segment indices and story height. `height` is the
story (pier) height and becomes `base.L`; `thickness` is required.
"""
function Wall(seg_indices::Vector{Int}, height::T; thickness::T,
              x1=0.0, y1=0.0, x2=0.0, y2=0.0, story=0,
              ρl=0.0025, ρt=0.0025, concrete=nothing, group_id=nothing) where T
    base = MemberBase{T}(
        segment_indices=seg_indices, L=height, Lb=height,
        group_id=group_id, section=nothing, volumes=MaterialVolumes()
    )
    Wall{T}(base=base, thickness=thickness,
            x1=Float64(x1), y1=Float64(y1), x2=Float64(x2), y2=Float64(y2),
            story=story, ρl=Float64(ρl), ρt=Float64(ρt), concrete=concrete)
end

"""Single-segment wall convenience: wraps the index in a vector."""
Wall(seg_idx::Int, height::T; kwargs...) where T = Wall([seg_idx], height; kwargs...)

# -----------------------------------------------------------------------------
# Wall geometry accessors (plan line → center / length / orientation)
# -----------------------------------------------------------------------------

"""Plan-center `(x, y)` of a wall [m]."""
wall_center(w::Wall) = ((w.x1 + w.x2) / 2, (w.y1 + w.y2) / 2)

"""Wall length in plan [m] (Euclidean distance between endpoints)."""
wall_length(w::Wall) = hypot(w.x2 - w.x1, w.y2 - w.y1)

"""In-plane (strong) axis orientation [rad, CCW from +X]."""
wall_orientation(w::Wall) = atan(w.y2 - w.y1, w.x2 - w.x1)

"""
    wall_lateral_stiffness(w::Wall, concrete; cracked=true, boundary=:cantilever) -> Quantity

Analytic in-plane lateral stiffness `[N/m]` of this wall, delegating to the
sizer's closed-form pier stiffness (`StructuralSizer.wall_stiffness_from_thickness_si`).
Extends the sizer's `wall_lateral_stiffness` to the building `Wall` type.
"""
function StructuralSizer.wall_lateral_stiffness(w::Wall, concrete;
                                                cracked::Bool=true,
                                                boundary::Symbol=:cantilever)
    lw = wall_length(w)
    t  = ustrip(u"m", w.thickness)
    H  = ustrip(u"m", w.base.L)
    E  = ustrip(u"Pa", concrete.E)
    ν  = concrete.ν
    k  = StructuralSizer.wall_stiffness_from_thickness_si(t, lw, E, ν, H;
                                                          cracked=cracked, boundary=boundary)
    return k * u"N/m"
end

"""
    to_wall_line(w::Wall, id, concrete; cracked=true, boundary=:cantilever) -> WallLine

Bridge a building `Wall` to the sizer's bare-SI `WallLine` used by the lateral
evaluators (plan S2/S4). Wall length/orientation come from the plan endpoints.
"""
function to_wall_line(w::Wall, id::Int, concrete;
                      cracked::Bool=true, boundary::Symbol=:cantilever)
    cx, cy = wall_center(w)
    k = ustrip(u"N/m", StructuralSizer.wall_lateral_stiffness(w, concrete;
                                                              cracked=cracked, boundary=boundary))
    return StructuralSizer.WallLine(id, cx, cy, wall_orientation(w), k, w.story + 1)
end

# -----------------------------------------------------------------------------
# Accessors (delegate to base)
# -----------------------------------------------------------------------------

"""Skeleton segment indices spanned by this member."""
segment_indices(m::AbstractMember) = m.base.segment_indices

"""Total member length."""
member_length(m::AbstractMember) = m.base.L

"""Governing unbraced length."""
unbraced_length(m::AbstractMember) = m.base.Lb

"""Optimization group hash (or `nothing`)."""
group_id(m::AbstractMember) = m.base.group_id

"""Assigned cross-section (or `nothing` before sizing)."""
section(m::AbstractMember) = m.base.section

"""Per-pixel design for PixelFrame members (or `nothing`)."""
pixel_design(m::AbstractMember) = m.base.pixel_design

"""Material → volume mapping for this member."""
volumes(m::AbstractMember) = m.base.volumes

"""Set the optimization group hash."""
set_group_id!(m::AbstractMember, gid) = (m.base.group_id = gid)

"""Assign a cross-section to this member."""
set_section!(m::AbstractMember, sec) = (m.base.section = sec)

"""Assign a per-pixel design to this member."""
set_pixel_design!(m::AbstractMember, pd) = (m.base.pixel_design = pd)

"""Replace the material → volume mapping."""
set_volumes!(m::AbstractMember, vols) = (m.base.volumes = vols)

"""Optimization grouping for similar members (pure grouping logic + shared section for ASAP)."""
mutable struct MemberGroup
    hash::UInt64
    member_indices::Vector{Int}
    section::Union{AbstractSection, Nothing}  # Shared section for ASAP element updates
end

"""Create an empty `MemberGroup` with the given hash key and no shared section."""
MemberGroup(hash::UInt64) = MemberGroup(hash, Int[], nothing)
