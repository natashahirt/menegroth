# ==============================================================================
# Section Interface
# ==============================================================================

"""Weight per unit length. Default: section_area(s) * mat.ρ"""
weight_per_length(s::AbstractSection, mat::AbstractMaterial) = section_area(s) * mat.ρ

# ==============================================================================
# Material-Organized Sections
# ==============================================================================

# Steel sections (I-shapes, HSS, angles, etc.)
include("steel/_steel_sections.jl")

# Rebar (used across steel and concrete)
include("steel/rebar.jl")

# Timber sections (glulam, LVL, sawn lumber, etc.)
include("timber/_timber_sections.jl")

# Concrete sections (RC beams, columns, etc.)
include("concrete/_concrete_sections.jl")

# Asap.Section conversion (requires all section types to be defined)
include("to_asap_section.jl")

# ==============================================================================
# Bounding Box — Outer Rectangular Envelope
# ==============================================================================

"""
    bounding_box(s::AbstractSection) -> (width=..., depth=...)

Outer rectangular envelope of the section as a named tuple of Unitful lengths.

`width` is the maximum horizontal extent; `depth` is the maximum vertical extent.
Useful for slab-column interaction, clearance checks, and visualization.

The default delegates to [`section_width`](@ref) / [`section_depth`](@ref), which
is correct for all rectangular and circular sections.  Override for sections where
the bounding envelope differs from the structural width (e.g. T-beams).
"""
bounding_box(s::AbstractSection) = (width = section_width(s), depth = section_depth(s))

# T-beam: bounding box uses full flange width, not web width
bounding_box(s::RCTBeamSection) = (width = s.bf, depth = s.h)