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
- `concrete`: Per-column concrete grade (`nothing` → use `ConcreteColumnOptions.grade`)
- `story::Int`: Story index (0 = ground level)
- `position::Symbol`: `:interior`, `:edge`, `:corner` (for punching shear coefficients)
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
    # Per-column concrete grade (nothing → use ConcreteColumnOptions.grade).
    # Set when columns on different stories use different f'c.
    concrete::Union{Nothing, StructuralSizer.Concrete} = nothing
    story::Int = 0
    position::Symbol = :interior
    # Unit vectors pointing along boundary edges (edges that belong to only one face).
    # Empty for interior columns; 1 direction for edge columns; 2+ for corners.
    # Used for DDM/EFM to determine if column is an exterior support for a given span direction.
    boundary_edge_dirs::Vector{NTuple{2, Float64}} = NTuple{2, Float64}[]
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
