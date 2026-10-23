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

# =============================================================================
# Variable Tributary Profile
# =============================================================================

"""
    TributaryProfile{T}

Piecewise-linear tributary width `w(s)` along a beam, where `s ∈ [0, 1]` is the
normalized position measured from the start node (`s = 0`) to the end node
(`s = 1`). Generalizes the former scalar `tributary_width` so variable flange
widths, irregular joist fields, and shell-panel tributary merging can be
represented end to end.

# Fields
- `positions::Vector{Float64}`: normalized breakpoints in `[0, 1]`, monotonically
  nondecreasing, with `positions[1] == 0.0` and `positions[end] == 1.0`.
- `widths::Vector{T}`: tributary width (length units) at each breakpoint; same
  length as `positions`. Width varies linearly between adjacent breakpoints.
- `axis::Union{Nothing, NTuple{2, Float64}}`: optional in-plane load axis for an
  asymmetric tributary. `nothing` ⇒ symmetric about the beam.

The validating constructor enforces the invariants above.
"""
struct TributaryProfile{T}
    positions::Vector{Float64}
    widths::Vector{T}
    axis::Union{Nothing, NTuple{2, Float64}}

    function TributaryProfile{T}(positions::Vector{Float64}, widths::Vector{T},
                                 axis::Union{Nothing, NTuple{2, Float64}} = nothing) where {T}
        n = length(positions)
        n >= 2 || throw(ArgumentError(
            "TributaryProfile requires >= 2 positions (got $n)"))
        length(widths) == n || throw(ArgumentError(
            "TributaryProfile positions ($n) and widths ($(length(widths))) must be equal length"))
        isapprox(positions[1], 0.0; atol = 1e-9) || throw(ArgumentError(
            "TributaryProfile positions must start at 0.0 (got $(positions[1]))"))
        isapprox(positions[end], 1.0; atol = 1e-9) || throw(ArgumentError(
            "TributaryProfile positions must end at 1.0 (got $(positions[end]))"))
        issorted(positions) || throw(ArgumentError(
            "TributaryProfile positions must be monotonically nondecreasing"))
        all(w -> w >= zero(w), widths) || throw(ArgumentError(
            "TributaryProfile widths must be non-negative"))
        return new{T}(positions, widths, axis)
    end
end

"""Infer the element type `T` from `widths` when constructing a `TributaryProfile`."""
TributaryProfile(positions::Vector{Float64}, widths::Vector{T},
                 axis::Union{Nothing, NTuple{2, Float64}} = nothing) where {T} =
    TributaryProfile{T}(positions, widths, axis)

"""
    TributaryProfile(w; axis=nothing) -> TributaryProfile

Constant-width profile: lifts a scalar tributary width `w` to a two-breakpoint
profile spanning the whole beam (`w` at `s = 0` and `s = 1`).
"""
TributaryProfile(w::T; axis::Union{Nothing, NTuple{2, Float64}} = nothing) where {T} =
    TributaryProfile{T}([0.0, 1.0], T[w, w], axis)

"""Number of breakpoints in the profile."""
Base.length(p::TributaryProfile) = length(p.positions)

"""Breakpoint `i` as a `(position, width)` tuple."""
Base.getindex(p::TributaryProfile, i::Int) = (p.positions[i], p.widths[i])
Base.firstindex(::TributaryProfile) = 1
Base.lastindex(p::TributaryProfile) = length(p.positions)

"""
    sample(profile::TributaryProfile, s::Real) -> width

Interpolated tributary width at normalized position `s` (clamped to `[0, 1]`),
linearly interpolating between adjacent breakpoints.
"""
function sample(p::TributaryProfile, s::Real)
    sc = clamp(Float64(s), 0.0, 1.0)
    pos = p.positions
    w = p.widths
    sc <= pos[1] && return w[1]
    sc >= pos[end] && return w[end]
    idx = clamp(searchsortedlast(pos, sc), 1, length(pos) - 1)
    p0, p1 = pos[idx], pos[idx + 1]
    w0, w1 = w[idx], w[idx + 1]
    p1 == p0 && return w1
    frac = (sc - p0) / (p1 - p0)
    return w0 + (w1 - w0) * frac
end

"""
    tributary_average(profile::TributaryProfile) -> width

Area-average width `∫₀¹ w(s) ds` via trapezoidal integration over the
breakpoints. Because `positions` spans the full `[0, 1]` domain, this integral
equals the mean width — the representative scalar for legacy call sites.
"""
function tributary_average(p::TributaryProfile)
    pos = p.positions
    w = p.widths
    total = zero(w[1])
    @inbounds for i in 1:(length(pos) - 1)
        total += (w[i] + w[i + 1]) * 0.5 * (pos[i + 1] - pos[i])
    end
    return total
end

"""Maximum tributary width over the beam (`max_s w(s)`)."""
tributary_envelope(p::TributaryProfile) = maximum(p.widths)

"""
    Beam{T} <: AbstractMember{T}

Horizontal member (gravity framing system).

# Fields
- `base::MemberBase{T}`: Shared member properties
- `tributary_profile`: Variable tributary width `w(s)` along the beam
  ([`TributaryProfile`](@ref)), or `nothing`. Collapse to a scalar with
  [`tributary_width_scalar`](@ref) (area-average) or
  [`tributary_width_envelope`](@ref) (max).
- `role::Symbol`: framing-hierarchy role, one of
  - `:girder` — column-to-column beam (both ends land on a column vertex);
  - `:joist` — beam that directly supports the slab (and is not a girder);
  - `:beam` — catch-all secondary member (neither of the above).

  Assigned for skeleton-input members by [`classify_beam_role`](@ref).
- `level::Int`: framing-hierarchy level. Skeleton-input members are `0`
  (the primary column-to-column frame); auto-generated members from higher
  framing levels use `1, 2, …`.
- `lateral_role::Symbol`: lateral-system participation. `:gravity` (default)
  means gravity-only; `:moment_frame` means part of a moment frame. Other
  values are reserved for later phases.
- `torsion_released::Union{Nothing, Bool}`: whole-member torsion selector used by
  the release resolver to pick between Asap's `:joist` and `:freefree` element
  releases when both member ends resolve to `:pinned`. `nothing` (default) defers
  to the `(role, material)` dispatch (`StructuralSizer.default_torsion_released`);
  `true`/`false` is an explicit user override.

  !!! warning "Field name reads inverse to the DOF state it selects"
      Despite the name, `torsion_released = true` selects Asap's `:joist` element
      release, which is the **open-web-steel-joist (OWSJ) idealization: pinned
      bending ends with RETAINED torsional stiffness `GJ`** — torsion is *not*
      released. Asap's `:joist` kernel `k_joist`
      (`external/Asap/src/Elements/K.jl`) is built from `E, A, L, G, J` and
      releases only bending; `k_freefree` retains axial alone. So:
      - `torsion_released = true`  → `:joist`    (OWSJ-style: bending pinned, `GJ` kept);
      - `torsion_released = false` → `:freefree` (all end rotations released).

      Read the flag as "want OWSJ-style `:joist` behavior", not literal "torsion
      released". The name is kept (rather than renamed to e.g. `retain_torsion_gj`)
      to avoid churn against the tested Phase 2 mapping; this docstring is the
      reconciliation.

# Back-compat
`beam.tributary_width` (property) returns the area-average scalar of the profile,
so legacy call sites keep working.
"""
@kwdef mutable struct Beam{T} <: AbstractMember{T}
    base::MemberBase{T}
    tributary_profile::Union{TributaryProfile{T}, Nothing} = nothing
    role::Symbol = :beam
    level::Int = 0
    lateral_role::Symbol = :gravity
    torsion_released::Union{Nothing, Bool} = nothing
end

"""
    tributary_profile(beam) -> Union{TributaryProfile, Nothing}

The beam's variable tributary width profile (or `nothing`).
"""
tributary_profile(b::Beam) = getfield(b, :tributary_profile)

"""
    tributary_width_scalar(beam) -> Union{T, Nothing}

Back-compat scalar tributary width: the area-average `∫₀¹ w(s) ds` of the beam's
[`TributaryProfile`](@ref), giving legacy scalar call sites one representative
value. Returns `nothing` when the beam has no tributary profile.
"""
function tributary_width_scalar(b::Beam)
    prof = getfield(b, :tributary_profile)
    isnothing(prof) && return nothing
    return tributary_average(prof)
end

"""
    tributary_width_envelope(beam) -> Union{T, Nothing}

Max-envelope tributary width `max_s w(s)` of the beam's [`TributaryProfile`](@ref)
— the value used where downstream section checks accept only a single width.
Returns `nothing` when the beam has no tributary profile.
"""
function tributary_width_envelope(b::Beam)
    prof = getfield(b, :tributary_profile)
    isnothing(prof) && return nothing
    return tributary_envelope(prof)
end

# Back-compat property shim: `beam.tributary_width` maps to the area-average
# scalar of the profile so pre-existing call sites (e.g. api/diagnose.jl) keep
# working after the field was promoted to `tributary_profile`.
function Base.getproperty(b::Beam, name::Symbol)
    name === :tributary_width && return tributary_width_scalar(b)
    return getfield(b, name)
end

# -----------------------------------------------------------------------------
# Framing-hierarchy role / level predicates (module-level free functions)
# -----------------------------------------------------------------------------

"""`true` if the beam is classified as a column-to-column `:girder`."""
is_girder(b::Beam) = getfield(b, :role) === :girder

"""`true` if the beam is classified as a slab-supporting `:joist`."""
is_joist(b::Beam) = getfield(b, :role) === :joist

"""
    is_beam(b::Beam) -> Bool

`true` only for the catch-all `:beam` role (neither girder nor joist).
"""
is_beam(b::Beam) = getfield(b, :role) === :beam

"""Framing-hierarchy level (`0` for skeleton-input members)."""
level_of(b::Beam) = getfield(b, :level)

"""Lateral-system participation symbol (`:gravity`, `:moment_frame`, …)."""
lateral_role_of(b::Beam) = getfield(b, :lateral_role)

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
    # Refinement of a :corner column by the slab-material angle at the vertex:
    #   :convex    — outside corner, slab fills < 180° (legacy 2-sided section)
    #   :reentrant — inside corner (L-notch), slab fills > 180°; the critical
    #                section carries (nearly) the full 4-sided perimeter and is
    #                routed through the general-shape engine (ACI 421.1R-99 App. B)
    #   :none      — not a corner (interior/edge)
    corner_kind::Symbol = :none
    # Slab-material angle at the vertex (radians), from `slab_material_angle`.
    # ≈3π/2 at an orthogonal re-entrant corner, ≈π/2 at an orthogonal convex
    # corner; other values flag non-orthogonal (skewed) corners. 0.0 for
    # non-corner columns. Used by the punching check to gate which corners may
    # use the orthogonal general-shape critical section vs a conservative fallback.
    corner_angle::Float64 = 0.0
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
    Beam(seg_indices, L; Lb, Kx, Ky, Cb, group_id, role, level, lateral_role,
         torsion_released, tributary_width, tributary_profile) -> Beam

Convenience constructor from segment indices and total length.

`level` defaults to `0` (skeleton-input primary frame) and `lateral_role` to
`:gravity`; `torsion_released` defaults to `nothing` (defers to the
`(role, material)` dispatch). See [`Beam`](@ref) for the semantics.

Accepts either a scalar `tributary_width` (auto-lifted to a constant-width
[`TributaryProfile`](@ref)) or a `tributary_profile` directly. Passing both is an
error.
"""
function Beam(seg_indices::Vector{Int}, L::T; Lb=L, Kx=1.0, Ky=1.0, Cb=1.0, 
              group_id=nothing, role=:beam, level=0, lateral_role=:gravity,
              torsion_released=nothing,
              tributary_width=nothing, tributary_profile=nothing) where T
    base = MemberBase{T}(
        segment_indices=seg_indices, L=L, Lb=Lb,
        Kx=Float64(Kx), Ky=Float64(Ky), Cb=Float64(Cb),
        group_id=group_id, section=nothing, volumes=MaterialVolumes()
    )
    prof = _resolve_tributary_profile(T, tributary_profile, tributary_width)
    Beam{T}(base=base, tributary_profile=prof, role=role,
            level=Int(level), lateral_role=lateral_role,
            torsion_released=torsion_released)
end

"""
Resolve the constructor's `tributary_profile` / `tributary_width` kwargs into a
`Union{TributaryProfile{T}, Nothing}`. A scalar width is auto-lifted to a
constant-width profile; an existing profile is retyped to `T` if needed.
"""
function _resolve_tributary_profile(::Type{T}, profile, width) where {T}
    if !isnothing(profile) && !isnothing(width)
        throw(ArgumentError("Beam: pass either tributary_width or tributary_profile, not both"))
    end
    if !isnothing(profile)
        profile isa TributaryProfile{T} && return profile
        profile isa TributaryProfile && return TributaryProfile{T}(
            profile.positions, convert(Vector{T}, profile.widths), profile.axis)
        throw(ArgumentError("tributary_profile must be a TributaryProfile, got $(typeof(profile))"))
    end
    isnothing(width) && return nothing
    w = convert(T, width)
    return TributaryProfile{T}([0.0, 1.0], T[w, w], nothing)
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

"""
    MemberGroup

Optimization grouping for similar members (pure grouping logic + shared section
for ASAP).

# Fields
- `hash::UInt64`: group key (shared `group_id` of the grouped members).
- `member_indices::Vector{Int}`: indices into the owning member vector
  (e.g. `struc.beams[idx]`).
- `section::Union{AbstractSection, Nothing}`: shared section assigned by sizing;
  `nothing` before the group is sized.
- `catalog_override::Any`: per-group section catalog override, or `nothing`
  (the default). When non-`nothing`, [`size_member_group!`](@ref) passes this to
  the material selector as its `catalog` keyword, overriding the material's
  default catalog for this group only. This is the entry point Phase 5's
  `materialize_level!` uses to restrict a joist group to a specific catalog
  (e.g. "only use these W-shapes for the joists") without forking the sizing
  functions. A value of `nothing` reproduces the pre-Phase-6 behaviour exactly
  (the material's standard catalog is used).

!!! note "Phase 5 seam"
    `FramingLevel.catalog_override` (added in Phase 4) is propagated onto the
    per-level `MemberGroup.catalog_override` by `materialize_level!` in Phase 5
    (`group.catalog_override = level.catalog_override` before sizing). This
    struct only carries the override and hands it to the selector; it does not
    itself generate members.
"""
mutable struct MemberGroup
    hash::UInt64
    member_indices::Vector{Int}
    section::Union{AbstractSection, Nothing}  # Shared section for ASAP element updates
    catalog_override::Any                     # Per-group catalog override (nothing ⇒ material default)
end

"""
Back-compat positional constructor: a group with no per-group catalog override
(`catalog_override = nothing`). Keeps pre-Phase-6 three-argument call sites
working unchanged.
"""
MemberGroup(hash::UInt64, member_indices::Vector{Int},
            section::Union{AbstractSection, Nothing}) =
    MemberGroup(hash, member_indices, section, nothing)

"""
    MemberGroup(hash; catalog_override=nothing) -> MemberGroup

Create an empty `MemberGroup` with the given hash key, no shared section, and an
optional per-group `catalog_override` (default `nothing` ⇒ use the material's
standard catalog at sizing time).
"""
MemberGroup(hash::UInt64; catalog_override = nothing) =
    MemberGroup(hash, Int[], nothing, catalog_override)
