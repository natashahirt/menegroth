# =============================================================================
# Section Visualization Interface
# =============================================================================
#
# Defines geometry traits and dimension getters for section visualization.
# Actual drawing code lives in StructuralSynthesizer (which depends on GLMakie).
#
# Adding a new section type:
#   1. Pick a geometry trait (or define a new one here)
#   2. Define section_geometry(::Type{YourSection}) = YourTrait()
#   3. Ensure dimension getters work for your field names (or add overrides)
#
# Available geometry traits:
#   - SolidRect:    Solid rectangular (RC columns/beams, glulam)
#   - SolidRound:   Solid circular (RC circular columns)
#   - HollowRect:   Hollow rectangular (HSS rect)
#   - HollowRound:  Hollow circular (HSS round, pipe)
#   - IShape:       Doubly-symmetric I-section (W-shapes)
#   - TShape:       T-beam (RC T-beams with effective flange)
#
# PixelFrameSection uses a direct section_polygon override (compound geometry
# from radial sweep that doesn't fit a simple trait).
#
# =============================================================================

using Unitful: ustrip, @u_str

# =============================================================================
# Geometry Traits
# =============================================================================

"""Abstract base for section geometry traits used in visualization."""
abstract type AbstractSectionGeometry end

"""Solid rectangular section (RC columns, RC beams, glulam, etc.)."""
struct SolidRect <: AbstractSectionGeometry end

"""Solid circular section (RC circular columns)."""
struct SolidRound <: AbstractSectionGeometry end

"""Hollow rectangular section (HSS rect, box sections)."""
struct HollowRect <: AbstractSectionGeometry end

"""Hollow circular section (HSS round, pipe, circular hollow)."""
struct HollowRound <: AbstractSectionGeometry end

"""Doubly-symmetric I-section (W-shapes, wide-flange beams)."""
struct IShape <: AbstractSectionGeometry end

"""T-beam section (RC T-beams with effective flange)."""
struct TShape <: AbstractSectionGeometry end

# =============================================================================
# Trait Assignment Interface
# =============================================================================

"""
    section_geometry(::Type{T}) -> AbstractSectionGeometry
    section_geometry(sec) -> AbstractSectionGeometry

Return the geometry trait for a section type. Used by visualization code
to dispatch on shape rather than section type.

# Default
Returns `SolidRect()` for any section type without an explicit assignment.

# Example
```julia
section_geometry(::Type{<:ISymmSection}) = IShape()
section_geometry(::Type{<:HSSRectSection}) = HollowRect()
```
"""
section_geometry(::Type{<:AbstractSection}) = SolidRect()
"""Dispatch on instance by forwarding to the `Type`-based method."""
section_geometry(sec) = section_geometry(typeof(sec))

# =============================================================================
# Dimension Getters
# =============================================================================

# Note: section_width(sec) and section_depth(sec) are defined in the main
# section interface (e.g., rc_column_section.jl). For visualization, use
# ustrip(u"m", section_width(sec)) to get unitless meters.

"""
    section_thickness(sec) -> Float64

Get wall thickness for hollow sections in meters.
Tries fields: :t, :tw (in that order).
"""
function section_thickness(sec)
    for field in (:t, :tw)
        hasproperty(sec, field) && return ustrip(u"m", getproperty(sec, field))
    end
    return 0.01  # fallback
end

# =============================================================================
# I-Shape Specific Getters
# =============================================================================

"""Get flange width for I-shapes (meters)."""
section_flange_width(sec) = ustrip(u"m", section_width(sec))

"""Get flange thickness for I-shapes (meters)."""
section_flange_thickness(sec::ISymmSection) = ustrip(u"m", sec.tf)
"""Fallback flange thickness (0.01 m) for non-I sections."""
section_flange_thickness(sec) = 0.01

"""Get web thickness for I-shapes (meters)."""
section_web_thickness(sec::ISymmSection) = ustrip(u"m", sec.tw)
"""Fallback web thickness (0.01 m) for non-I sections."""
section_web_thickness(sec) = 0.01

# =============================================================================
# Rebar Interface (for RC sections)
# =============================================================================

"""Check if section has rebar to visualize."""
has_rebar(::AbstractSection) = false

"""
    section_rebar_positions(sec) -> Vector{NTuple{2, Float64}}

Return rebar positions in centroid-relative coordinates (y, z) in meters.
"""
section_rebar_positions(::AbstractSection) = NTuple{2, Float64}[]

"""
    section_rebar_radius(sec) -> Float64

Return rebar radius for visualization (meters).
"""
section_rebar_radius(::AbstractSection) = 0.0

# =============================================================================
# Trait Assignments for All Section Types
# =============================================================================
# These must come after section types are defined (in _members.jl).
# Grouped here for easy reference of all visualization traits.

# Steel
section_geometry(::Type{<:ISymmSection}) = IShape()
section_geometry(::Type{<:HSSRectSection}) = HollowRect()
section_geometry(::Type{<:HSSRoundSection}) = HollowRound()

# Concrete — rectangular
section_geometry(::Type{<:RCColumnSection}) = SolidRect()
section_geometry(::Type{<:RCBeamSection}) = SolidRect()

# Concrete — circular
section_geometry(::Type{<:RCCircularSection}) = SolidRound()

# Concrete — T-beam
section_geometry(::Type{<:RCTBeamSection}) = TShape()

# Timber
section_geometry(::Type{<:GlulamSection}) = SolidRect()

# RC column rebar visualization. Bars are stored from the bottom-left corner of
# the bounding box (circular: centre at (D/2, D/2)), so shifting by half the
# width/depth gives the same centroid-origin frame as `section_polygon`.
const _RCColumnWithBars = Union{RCColumnSection, RCCircularSection}

has_rebar(sec::_RCColumnWithBars) = !isempty(sec.bars)

"""Rebar positions in centroid-relative (y, z) coordinates (meters) for an RC column."""
function section_rebar_positions(sec::_RCColumnWithBars)
    b = ustrip(u"m", section_width(sec))
    h = ustrip(u"m", section_depth(sec))
    return [(ustrip(u"m", bar.x) - b/2, 
             ustrip(u"m", bar.y) - h/2) for bar in sec.bars]
end

"""Rebar radius (meters) for visualization, computed from the first bar's area."""
function section_rebar_radius(sec::_RCColumnWithBars)
    isempty(sec.bars) && return 0.0
    As = ustrip(u"m^2", sec.bars[1].As)
    return sqrt(As / π)
end

# A rectangular beam stores one tension layer at `d` and, when doubly reinforced,
# one compression layer at `d_prime`. Both layers use the clear spacing
# `validate` already checks: the outer bar center is one cover, one stirrup
# diameter, and half a bar in from the face, and the rest are spaced evenly.
const _RCBeamWithLayers = Union{RCBeamSection, RCTBeamSection}

has_rebar(sec::_RCBeamWithLayers) = sec.n_bars > 0 || sec.n_bars_prime > 0

"""One layer of equal bars. `z` is the centroid-frame height of the layer."""
function _beam_bar_row(width::Float64, cover::Float64, stirrup::Float64,
                       diameter::Float64, n::Int, z::Float64)
    n > 0 || return NTuple{3, Float64}[]
    outer = width / 2 - cover - stirrup - diameter / 2
    n == 1 && return [(0.0, z, diameter)]
    return [(y, z, diameter) for y in range(-outer, outer; length = n)]
end

"""Tension and compression bars of a rectangular beam, in the centroid frame."""
function section_rebar_bars(sec::RCBeamSection)
    width = ustrip(u"m", sec.b)
    depth = ustrip(u"m", sec.h)
    cover = ustrip(u"m", sec.cover)
    stirrup = ustrip(u"m", rebar(sec.stirrup_size).diameter)
    bars = NTuple{3, Float64}[]
    if sec.n_bars > 0
        diameter = ustrip(u"m", rebar(sec.bar_size).diameter)
        z = -depth / 2 + cover + stirrup + diameter / 2
        append!(bars, _beam_bar_row(width, cover, stirrup, diameter, sec.n_bars, z))
    end
    if sec.n_bars_prime > 0 && sec.bar_size_prime > 0
        diameter = ustrip(u"m", rebar(sec.bar_size_prime).diameter)
        z = depth / 2 - cover - stirrup - diameter / 2
        append!(bars, _beam_bar_row(width, cover, stirrup, diameter, sec.n_bars_prime, z))
    end
    return bars
end

"""Tension and compression bars of a T-beam. The row sits in the web."""
function section_rebar_bars(sec::RCTBeamSection)
    width = ustrip(u"m", sec.bw)
    cover = ustrip(u"m", sec.cover)
    stirrup = ustrip(u"m", rebar(sec.stirrup_size).diameter)
    z_top = ustrip(u"m", sec.h - gross_centroid_from_top(sec))
    bars = NTuple{3, Float64}[]
    if sec.n_bars > 0
        diameter = ustrip(u"m", rebar(sec.bar_size).diameter)
        append!(bars, _beam_bar_row(width, cover, stirrup, diameter, sec.n_bars,
                                    z_top - ustrip(u"m", sec.d)))
    end
    if sec.n_bars_prime > 0 && sec.bar_size_prime > 0
        diameter = ustrip(u"m", rebar(sec.bar_size_prime).diameter)
        append!(bars, _beam_bar_row(width, cover, stirrup, diameter, sec.n_bars_prime,
                                    z_top - ustrip(u"m", sec.d_prime)))
    end
    return bars
end

section_rebar_positions(sec::_RCBeamWithLayers) =
    [(y, z) for (y, z, _) in section_rebar_bars(sec)]

function section_rebar_radius(sec::_RCBeamWithLayers)
    bars = section_rebar_bars(sec)
    return isempty(bars) ? 0.0 : bars[1][3] / 2
end

"""
    section_rebar_bars(sec) -> Vector{NTuple{3,Float64}}

Each bar as `(y, z, diameter)` in the centroid frame of `section_polygon`, meters.
"""
function section_rebar_bars(sec::AbstractSection)
    radius = section_rebar_radius(sec)
    return [(y, z, 2 * radius) for (y, z) in section_rebar_positions(sec)]
end

"""
    section_transverse(sec) -> NamedTuple or nothing

The stirrup, tie, or spiral the section stores. `loop` is the bar centerline
in the centroid frame. `radius` is a circle about the origin for a spiral.
`nothing` when the section has no transverse bar.
"""
section_transverse(::AbstractSection) = nothing

function _closed_loop(width::Float64, depth::Float64, cover::Float64, diameter::Float64)
    inset = cover + diameter / 2
    (2 * inset < width && 2 * inset < depth) || return nothing
    hw, hd = width / 2, depth / 2
    return NTuple{2, Float64}[
        (-hw + inset, -hd + inset),
        ( hw - inset, -hd + inset),
        ( hw - inset,  hd - inset),
        (-hw + inset,  hd - inset),
    ]
end

function section_transverse(sec::RCBeamSection)
    diameter = ustrip(u"m", rebar(sec.stirrup_size).diameter)
    cover = ustrip(u"m", sec.cover)
    loop = _closed_loop(ustrip(u"m", sec.b), ustrip(u"m", sec.h), cover, diameter)
    isnothing(loop) && return nothing
    return (kind = :stirrup, diameter = diameter, cover = cover,
            bar_size = sec.stirrup_size, loop = loop, radius = nothing)
end

function section_transverse(sec::RCTBeamSection)
    diameter = ustrip(u"m", rebar(sec.stirrup_size).diameter)
    cover = ustrip(u"m", sec.cover)
    inset = cover + diameter / 2
    bw = ustrip(u"m", sec.bw)
    z_bot = -ustrip(u"m", gross_centroid_from_top(sec))
    z_top = ustrip(u"m", sec.h) + z_bot
    y_l, y_r = -bw / 2 + inset, bw / 2 - inset
    z_lo, z_hi = z_bot + inset, z_top - inset
    (y_r > y_l && z_hi > z_lo) || return nothing
    return (kind = :stirrup, diameter = diameter, cover = cover, bar_size = sec.stirrup_size,
            loop = NTuple{2, Float64}[(y_l, z_lo), (y_r, z_lo), (y_r, z_hi), (y_l, z_hi)],
            radius = nothing)
end

function section_transverse(sec::RCColumnSection)
    diameter = ustrip(u"m", rebar(sec.tie_bar_size).diameter)
    cover = ustrip(u"m", sec.cover)
    loop = _closed_loop(ustrip(u"m", sec.b), ustrip(u"m", sec.h), cover, diameter)
    isnothing(loop) && return nothing
    kind = sec.tie_type == :spiral ? :spiral : :tie
    return (kind = kind, diameter = diameter, cover = cover,
            bar_size = sec.tie_bar_size, loop = loop, radius = nothing)
end

function section_transverse(sec::RCCircularSection)
    cover = ustrip(u"m", sec.cover)
    diameter_section = ustrip(u"m", sec.D)
    bars = section_rebar_positions(sec)
    isempty(bars) && return nothing
    bar_radius = section_rebar_radius(sec)
    # The constructor seats each bar on the outside of the spiral.
    diameter = diameter_section / 2 - cover - hypot(bars[1]...) - bar_radius
    diameter > 1e-4 || return nothing
    kind = sec.tie_type == :tied ? :tie : :spiral
    return (kind = kind, diameter = diameter, cover = cover, bar_size = nothing,
            loop = nothing, radius = diameter_section / 2 - cover - diameter / 2)
end

# =============================================================================
# Section Polygon Interface
# =============================================================================
#
# Each section type exposes its 2D outline polygon via section_polygon(sec).
# Returns Vector{NTuple{2, Float64}} in meters, centroid at origin, y = width, z = depth.
# Used by API serialization and visualization (e.g. Grasshopper section sweep).
#
# All trait-based implementations go through:
#   section_polygon(sec) → _section_polygon(section_geometry(sec), sec)
#
# PixelFrameSection uses a direct override (compound radial-sweep geometry).
# =============================================================================

"""
    section_polygon(sec) -> Vector{NTuple{2, Float64}}

Return the 2D outline polygon of a section in local y-z coordinates (meters).
Origin at section centroid; y = width direction, z = depth direction.
"""
section_polygon(sec) = _section_polygon(section_geometry(sec), sec)

"""
    section_polygon_inner(sec) -> Vector{NTuple{2, Float64}}

Return the inner boundary polygon for hollow sections (meters). Returns empty for solid sections.
Used for HSS rect/round to show hollow geometry; cap will close the ends correctly.
"""
section_polygon_inner(sec) = NTuple{2, Float64}[]

# --- Solid Rectangular (RCColumnSection, RCBeamSection, GlulamSection) ---
function _section_polygon(::SolidRect, sec)
    w = ustrip(u"m", section_width(sec))
    d = ustrip(u"m", section_depth(sec))
    return NTuple{2, Float64}[
        (-w/2, -d/2), (w/2, -d/2), (w/2, d/2), (-w/2, d/2)
    ]
end

# --- Solid Round (RCCircularSection) ---
function _section_polygon(::SolidRound, sec; n_segments::Int=24)
    r = ustrip(u"m", section_width(sec)) / 2
    θ = range(0, 2π, length=n_segments + 1)[1:end-1]
    return NTuple{2, Float64}[(r * cos(t), r * sin(t)) for t in θ]
end

# --- Hollow Rectangular (HSS rect) ---
function _section_polygon(::HollowRect, sec)
    w = ustrip(u"m", section_width(sec))
    d = ustrip(u"m", section_depth(sec))
    return NTuple{2, Float64}[
        (-w/2, -d/2), (w/2, -d/2), (w/2, d/2), (-w/2, d/2)
    ]
end

"""Inner boundary for hollow rectangular HSS (meters). Returns empty for solid sections."""
function section_polygon_inner(sec::HSSRectSection)
    w = ustrip(u"m", section_width(sec))
    d = ustrip(u"m", section_depth(sec))
    t = section_thickness(sec)
    wi = max(0.0, w - 2t)
    di = max(0.0, d - 2t)
    (wi < 1e-6 || di < 1e-6) && return NTuple{2, Float64}[]
    return NTuple{2, Float64}[
        (-wi/2, -di/2), (wi/2, -di/2), (wi/2, di/2), (-wi/2, di/2)
    ]
end

# --- Hollow Round (HSS round, pipe) ---
function _section_polygon(::HollowRound, sec; n_segments::Int=24)
    r = ustrip(u"m", section_width(sec) / 2)
    θ = range(0, 2π, length=n_segments + 1)[1:end-1]
    return NTuple{2, Float64}[(r * cos(t), r * sin(t)) for t in θ]
end

"""Inner boundary for hollow round HSS (meters). Returns empty for solid sections."""
function section_polygon_inner(sec::HSSRoundSection; n_segments::Int=24)
    r_outer = ustrip(u"m", section_width(sec) / 2)
    t = section_thickness(sec)
    r_inner = max(0.0, r_outer - t)
    r_inner < 1e-6 && return NTuple{2, Float64}[]
    θ = range(0, 2π, length=n_segments + 1)[1:end-1]
    return NTuple{2, Float64}[(r_inner * cos(t), r_inner * sin(t)) for t in θ]
end

# --- I-Shape (W-shapes) ---
function _section_polygon(::IShape, sec)
    d_m = ustrip(u"m", section_depth(sec))
    bf_m = section_flange_width(sec)
    tw_m = section_web_thickness(sec)
    tf_m = section_flange_thickness(sec)
    return NTuple{2, Float64}[
        (-bf_m/2, -d_m/2), (-bf_m/2, -d_m/2 + tf_m), (-tw_m/2, -d_m/2 + tf_m),
        (-tw_m/2, d_m/2 - tf_m), (-bf_m/2, d_m/2 - tf_m), (-bf_m/2, d_m/2),
        (bf_m/2, d_m/2), (bf_m/2, d_m/2 - tf_m), (tw_m/2, d_m/2 - tf_m),
        (tw_m/2, -d_m/2 + tf_m), (bf_m/2, -d_m/2 + tf_m), (bf_m/2, -d_m/2),
    ]
end

# --- T-Shape (RC T-beams) ---
# Centroid is at the composite centroid of flange + web, not at mid-height.
function _section_polygon(::TShape, sec)
    bw_m = ustrip(u"m", section_width(sec))       # web width
    bf_m = ustrip(u"m", flange_width(sec))         # flange width
    h_m  = ustrip(u"m", section_depth(sec))        # total depth
    hf_m = ustrip(u"m", flange_thickness(sec))     # flange thickness

    # Composite centroid measured from top fiber
    Af = bf_m * hf_m
    Aw = bw_m * (h_m - hf_m)
    ybar_from_top = (Af * (hf_m / 2) + Aw * (hf_m + (h_m - hf_m) / 2)) / (Af + Aw)

    z_top = h_m - ybar_from_top
    z_bot = -ybar_from_top
    z_flange_bot = h_m - hf_m - ybar_from_top

    return NTuple{2, Float64}[
        (-bw_m/2, z_bot), (bw_m/2, z_bot), (bw_m/2, z_flange_bot),
        (bf_m/2, z_flange_bot), (bf_m/2, z_top), (-bf_m/2, z_top),
        (-bf_m/2, z_flange_bot), (-bw_m/2, z_flange_bot),
    ]
end

# --- PixelFrameSection: compound geometry from radial sweep (no trait) ---
function section_polygon(sec::PixelFrameSection)
    return _pixelframe_envelope_polygon(sec.section)
end
