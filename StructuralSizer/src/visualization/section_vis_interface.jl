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
#   - HollowRect:   Hollow rectangular (HSS rect)
#   - HollowRound:  Hollow circular (HSS round, pipe)
#   - IShape:       Doubly-symmetric I-section (W-shapes)
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

"""Hollow rectangular section (HSS rect, box sections)."""
struct HollowRect <: AbstractSectionGeometry end

"""Hollow circular section (HSS round, pipe, circular hollow)."""
struct HollowRound <: AbstractSectionGeometry end

"""Doubly-symmetric I-section (W-shapes, wide-flange beams)."""
struct IShape <: AbstractSectionGeometry end

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

"""W-shapes visualize as doubly-symmetric I-sections."""
section_geometry(::Type{<:ISymmSection}) = IShape()
"""HSS rectangular sections visualize as hollow rectangles."""
section_geometry(::Type{<:HSSRectSection}) = HollowRect()
"""HSS round sections visualize as hollow circles."""
section_geometry(::Type{<:HSSRoundSection}) = HollowRound()

"""RC columns visualize as solid rectangles."""
section_geometry(::Type{<:RCColumnSection}) = SolidRect()
"""RC beams visualize as solid rectangles."""
section_geometry(::Type{<:RCBeamSection}) = SolidRect()

"""RC columns have rebar when their `bars` vector is non-empty."""
has_rebar(sec::RCColumnSection) = !isempty(sec.bars)

"""Rebar positions in centroid-relative (y, z) coordinates (meters) for an RC column."""
function section_rebar_positions(sec::RCColumnSection)
    b = ustrip(u"m", section_width(sec))
    h = ustrip(u"m", section_depth(sec))
    # Bars stored with x,y from bottom-left corner → centroid-relative
    return [(ustrip(u"m", bar.x) - b/2, 
             ustrip(u"m", bar.y) - h/2) for bar in sec.bars]
end

"""Rebar radius (meters) for visualization, computed from the first bar's area."""
function section_rebar_radius(sec::RCColumnSection)
    isempty(sec.bars) && return 0.0
    As = ustrip(u"m^2", sec.bars[1].As)
    return sqrt(As / π)
end

"""Glulam sections visualize as solid rectangles."""
section_geometry(::Type{<:GlulamSection}) = SolidRect()

# =============================================================================
# Section Polygon Interface
# =============================================================================
#
# Each section type exposes its 2D outline polygon via section_polygon(sec).
# Returns Vector{NTuple{2, Float64}} in meters, centroid at origin, y = width, z = depth.
# Used by API serialization and visualization (e.g. Grasshopper section sweep).
#
# PixelFrameSection stores polygon geometry in sec.section (CompoundSection);
# other types derive from dimensions (b, h, D, etc.).
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

# --- RCCircularSection: circle (override; default SolidRect would give square) ---
function section_polygon(sec::RCCircularSection)
    r = section_width(sec) / 2
    θ = range(0, 2π, length=25)[1:end-1]
    return NTuple{2, Float64}[(r * cos(t), r * sin(t)) for t in θ]
end

# --- RCTBeamSection: T-beam outline ---
function section_polygon(sec::RCTBeamSection)
    bw = sec.bw
    bf = sec.bf
    h = sec.h
    hf = sec.hf
    Af = bf * hf
    Aw = bw * (h - hf)
    ybar_from_top = (Af * (hf / 2) + Aw * (hf + (h - hf) / 2)) / (Af + Aw)
    z_top = ustrip(u"m", h - ybar_from_top)
    z_bot = -ustrip(u"m", ybar_from_top)
    z_flange_bot = ustrip(u"m", h - hf - ybar_from_top)
    bw_m = ustrip(u"m", bw)
    bf_m = ustrip(u"m", bf)
    return NTuple{2, Float64}[
        (-bw_m/2, z_bot), (bw_m/2, z_bot), (bw_m/2, z_flange_bot),
        (bf_m/2, z_flange_bot), (bf_m/2, z_top), (-bf_m/2, z_top),
        (-bf_m/2, z_flange_bot), (-bw_m/2, z_flange_bot),
    ]
end

# --- PixelFrameSection: extract from stored CompoundSection (like PixelFrame) ---
function section_polygon(sec::PixelFrameSection)
    return _pixelframe_envelope_polygon(sec.section)
end
