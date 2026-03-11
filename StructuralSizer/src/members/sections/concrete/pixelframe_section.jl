# ==============================================================================
# PixelFrame Section
# ==============================================================================
# A multi-layup concrete section for the PixelFrame system with external
# post-tensioning.
#
# Defined by 9 design variables per Wongsittikan (2024), Fig. 2.4 + layup.
# The cross-section geometry is a CompoundSection (polygon arms) built from
# Asap's polygon section types, NOT a rectangle.
#
# Layup types:
#   :Y  — 3 arms at 120° (beams, general members)
#   :X2 — 2 arms at 180° (slabs, thin members)
#   :X4 — 4 arms at 90°  (columns, biaxial members)
#
# Unlike RC beam/column sections, the material (FRC) is embedded in the
# section because PixelFrame elements vary material along the span —
# each catalog entry is a (geometry, material) pair.
# ==============================================================================

using Asap: Length, Area, Pressure, Force, CompoundSection

# ==============================================================================
# Struct
# ==============================================================================

"""
    PixelFrameSection <: AbstractSection

PixelFrame cross-section configuration defined by 9 design variables.

# Fields (9 design variables from Wongsittikan 2024, Fig. 2.4 + layup)
- `name`: Section designation (auto-generated if not provided)
- `λ`: Layup type — `:Y` (3-arm), `:X2` (2-arm), or `:X4` (4-arm)
- `L_px`: Pixel arm length [mm] — the length of each radiating leg
- `t`: Pixel wall thickness [mm]
- `L_c`: Straight region before arc [mm]
- `material`: FiberReinforcedConcrete embedding fc′, fR1, fR3, and fiber dosage
- `A_s`: External post-tensioning tendon area [mm²]
- `f_pe`: Initial effective prestress [MPa]
- `d_ps`: Tendon eccentricity from section centroid [mm]
- `section`: CompoundSection — the actual polygon geometry (computed)

# Geometry
The cross-section is a polygon profile (Y, X2, or X4), NOT rectangular.
Section properties (area, centroid, Ix, Iy) are computed from the polygon
geometry via Asap's CompoundSection.

# d_ps convention
`d_ps` is measured from the **centroid** of the concrete section (eccentricity),
consistent with the original Pixelframe.jl. The distance from the top fiber is:
    d_ps_from_top = (ymax - centroid_y) + d_ps

# Example
```julia
frc = FiberReinforcedConcrete(NWC_6000, 20.0, 3.2, 2.5)
sec = PixelFrameSection(
    λ = :Y,
    L_px = 125.0u"mm", t = 30.0u"mm", L_c = 30.0u"mm",
    material = frc,
    A_s = 157.0u"mm^2", f_pe = 500.0u"MPa", d_ps = 200.0u"mm",
)
```
"""
struct PixelFrameSection{T<:Length, A<:Area, P<:Pressure, M<:FiberReinforcedConcrete} <: AbstractSection
    name::Union{String, Nothing}
    λ::Symbol             # layup type: :Y, :X2, :X4
    L_px::T               # pixel arm length
    t::T                  # pixel wall thickness
    L_c::T                # straight region before arc
    material::M           # FRC with fc′, fR1, fR3, and fiber dosage
    A_s::A                # tendon area
    f_pe::P               # effective prestress
    d_ps::T               # tendon eccentricity from centroid
    section::CompoundSection  # polygon geometry (computed)
end

"""
    PixelFrameSection(; L_px, t, L_c, material, A_s, f_pe, d_ps, λ=:Y, name=nothing)

Keyword constructor for [`PixelFrameSection`](@ref).

Promotes all length arguments to a common type, builds the polygon
`CompoundSection` via [`make_pixelframe_section`](@ref), and returns a
fully-initialised section.

# Arguments
- `L_px::Length`: Pixel arm length
- `t::Length`: Wall thickness
- `L_c::Length`: Straight region before arc
- `material::FiberReinforcedConcrete`: FRC material (fc′, fR1, fR3, dosage)
- `A_s::Area`: Post-tensioning tendon area
- `f_pe::Pressure`: Initial effective prestress
- `d_ps::Length`: Tendon eccentricity from section centroid
- `λ::Symbol`: Layup type — `:Y`, `:X2`, or `:X4` (default `:Y`)
- `name::Union{String, Nothing}`: Optional section designation

# Returns
`PixelFrameSection` with computed polygon geometry.
"""
function PixelFrameSection(;
    L_px::Length, t::Length, L_c::Length,
    material::FiberReinforcedConcrete,
    A_s::Area, f_pe::Pressure, d_ps::Length,
    λ::Symbol = :Y,
    name::Union{String, Nothing} = nothing,
)
    # Promote length types to common type
    T = promote_type(typeof(L_px), typeof(t), typeof(L_c), typeof(d_ps))
    L_px_c = convert(T, L_px)
    t_c = convert(T, t)
    L_c_c = convert(T, L_c)
    d_ps_c = convert(T, d_ps)

    # Build polygon geometry from mm values
    cs = make_pixelframe_section(
        λ,
        ustrip(u"mm", L_px_c),
        ustrip(u"mm", t_c),
        ustrip(u"mm", L_c_c),
    )

    PixelFrameSection(name, λ, L_px_c, t_c, L_c_c, material, A_s, f_pe, d_ps_c, cs)
end

# ==============================================================================
# AbstractSection Interface
# ==============================================================================

"""Gross cross-sectional area from polygon geometry [mm²]."""
section_area(s::PixelFrameSection) = s.section.area * u"mm^2"

"""
Section overall depth from polygon geometry [mm].
Measured from ymax to ymin of the CompoundSection.
"""
section_depth(s::PixelFrameSection) = (s.section.ymax - s.section.ymin) * u"mm"

"""
Section overall width from polygon geometry [mm].
Measured from xmax to xmin of the CompoundSection.
"""
section_width(s::PixelFrameSection) = (s.section.xmax - s.section.xmin) * u"mm"

"""
Centroid y-coordinate distance from top fiber [mm].
"""
function _centroid_from_top(s::PixelFrameSection)
    (s.section.ymax - s.section.centroid[2]) * u"mm"
end

"""
Tendon depth from top fiber [mm].
d_ps is eccentricity from centroid; add centroid-to-top distance.
"""
function _d_ps_from_top(s::PixelFrameSection)
    _centroid_from_top(s) + s.d_ps
end

"""Number of pixel arms for the layup type."""
function n_arms(s::PixelFrameSection)
    s.λ === :Y  && return 3
    s.λ === :X2 && return 2
    s.λ === :X4 && return 4
    error("Unknown layup: $(s.λ)")
end

# ==============================================================================
# Display
# ==============================================================================

"""Pretty-print a `PixelFrameSection` as `Name[λ](L×t×Lc, fc′, A)`."""
function Base.show(io::IO, s::PixelFrameSection)
    nm = something(s.name, "PixelFrame")
    L = round(u"mm", s.L_px; digits=0)
    t = round(u"mm", s.t; digits=0)
    Lc = round(u"mm", s.L_c; digits=0)
    fc = round(u"MPa", s.material.concrete.fc′; digits=0)
    A_mm2 = round(s.section.area; digits=1)
    print(io, "$(nm)[$(s.λ)]($(L)×$(t)×$(Lc), fc′=$(fc), A=$(A_mm2)mm²)")
end
