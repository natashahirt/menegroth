# ==============================================================================
# Glulam Section - STUB
# ==============================================================================
# Glued laminated timber sections per NDS/AITC.
# TODO: Implement full geometry calculations and catalog loading.

using Asap: Length, Area, Volume, SecondMomentOfArea

"""
    GlulamSection <: AbstractSection

Glued laminated timber (glulam) rectangular section.

# Glulam Specifics
- Manufactured from multiple layers of lumber, glued together
- Available in standard widths: 3-1/8", 5-1/8", 6-3/4", 8-3/4", 10-3/4"
- Depths typically in 1.5" lamination increments
- Stress classes: 24F-V4, 26F-V3, etc. (Fb - bending stress, V - shear grade)

# Fields (to be implemented)
- `name`: Section designation
- `b`: Width
- `d`: Depth
- `stress_class`: e.g., "24F-V4"
- `A`: Cross-sectional area (b × d)
- `Ix`: Strong-axis moment of inertia (b × d³ / 12)
- `Iy`: Weak-axis moment of inertia (d × b³ / 12)
- `Sx`: Strong-axis section modulus (b × d² / 6)
- `Sy`: Weak-axis section modulus (d × b² / 6)
"""
struct GlulamSection <: AbstractSection
    name::Union{String, Nothing}
    b::Length           # Width
    d::Length           # Depth
    stress_class::String
    # Section properties
    A::Area
    Ix::SecondMomentOfArea
    Iy::SecondMomentOfArea
    Sx::SectionModulus
    Sy::SectionModulus
end

"""
    GlulamSection(b, d; name=nothing, stress_class="24F-V4")

Construct a `GlulamSection` from width `b` and depth `d`, computing gross
rectangular section properties (A, Ix, Iy, Sx, Sy).

# Arguments
- `b`: Section width (Length).
- `d`: Section depth (Length).
- `name`: Optional section designation string.
- `stress_class`: AITC stress class (default `"24F-V4"`).

# Returns
A `GlulamSection` with computed gross section properties per NDS.
"""
function GlulamSection(b, d; name=nothing, stress_class="24F-V4")
    A = b * d
    Ix = b * d^3 / 12
    Iy = d * b^3 / 12
    Sx = b * d^2 / 6
    Sy = d * b^2 / 6
    GlulamSection(name, b, d, stress_class, A, Ix, Iy, Sx, Sy)
end

"""Return gross cross-sectional area of the glulam section."""
section_area(s::GlulamSection) = s.A

"""Return section depth (parallel to strong axis)."""
section_depth(s::GlulamSection) = s.d

"""Return section width (parallel to weak axis)."""
section_width(s::GlulamSection) = s.b

"""Return strong-axis moment of inertia."""
Ix(s::GlulamSection) = s.Ix

"""Return weak-axis moment of inertia."""
Iy(s::GlulamSection) = s.Iy

"""Return strong-axis section modulus."""
Sx(s::GlulamSection) = s.Sx

"""Return weak-axis section modulus."""
Sy(s::GlulamSection) = s.Sy

"""
Standard glulam widths (inches) per AITC.
"""
const STANDARD_GLULAM_WIDTHS = [3.125, 5.125, 6.75, 8.75, 10.75] .* u"inch"

"""
Standard lamination thickness (inches).
"""
const GLULAM_LAM_THICKNESS = 1.5u"inch"

# Future catalog functions
# all_glulam(; stress_class="24F-V4") = ...
# standard_glulam_depths(max_depth) = ...
