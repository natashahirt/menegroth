# ==============================================================================
# HSS (Hollow Structural Sections) - STUB
# ==============================================================================
# Rectangular and square HSS sections per AISC.
# TODO: Implement full geometry calculations and catalog loading.

"""
    HSSSection <: AbstractSection

Rectangular or square hollow structural section (HSS).
Excellent torsional properties due to closed cross-section.

# Fields (to be implemented)
- `name`: Section designation (e.g., "HSS8x8x1/2")
- `H`: Outside height
- `B`: Outside width  
- `t`: Design wall thickness
- `A`: Cross-sectional area
- `Ix`, `Iy`: Moments of inertia
- `Sx`, `Sy`: Elastic section moduli
- `Zx`, `Zy`: Plastic section moduli
- `J`: Torsional constant (≈ 2*t*(H-t)²*(B-t)² / (H+B-2t) for rectangular)
- `C`: HSS torsional constant
"""
struct HSSSection <: AbstractSection
    name::Union{String, Nothing}
    H::LengthQ       # Outside height
    B::LengthQ       # Outside width (= H for square)
    t::LengthQ       # Design wall thickness
    # Section properties
    A::AreaQ
    Ix::InertQ
    Iy::InertQ
    Sx::ModQ
    Sy::ModQ
    Zx::ModQ
    Zy::ModQ
    J::InertQ        # Torsional constant
    rx::LengthQ
    ry::LengthQ
    is_preferred::Bool
end

# Stub constructor
function HSSSection(H, B, t; name=nothing, is_preferred=false)
    error("HSSSection not yet implemented. Contributions welcome!")
end

# Interface stubs
area(s::HSSSection) = s.A
depth(s::HSSSection) = s.H
width(s::HSSSection) = s.B

# Future: Catalog loaders
# all_HSS() = ...
# preferred_HSS() = ...
