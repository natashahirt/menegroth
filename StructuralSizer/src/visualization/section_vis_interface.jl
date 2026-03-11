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
