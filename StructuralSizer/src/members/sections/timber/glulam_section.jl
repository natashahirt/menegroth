# ==============================================================================
# Glulam Section - STUB
# ==============================================================================
# Glued laminated timber sections per NDS/AITC.
# TODO: Implement full geometry calculations and catalog loading.

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
    b::LengthQ       # Width
    d::LengthQ       # Depth
    stress_class::String
    # Section properties
    A::AreaQ
    Ix::InertQ
    Iy::InertQ
    Sx::ModQ
    Sy::ModQ
end

# Stub constructor
function GlulamSection(b, d; name=nothing, stress_class="24F-V4")
    A = b * d
    Ix = b * d^3 / 12
    Iy = d * b^3 / 12
    Sx = b * d^2 / 6
    Sy = d * b^2 / 6
    GlulamSection(name, b, d, stress_class, A, Ix, Iy, Sx, Sy)
end

# Interface
area(s::GlulamSection) = s.A
depth(s::GlulamSection) = s.d
width(s::GlulamSection) = s.b

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
