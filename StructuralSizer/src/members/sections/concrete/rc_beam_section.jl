# ==============================================================================
# Reinforced Concrete Beam Section - STUB
# ==============================================================================
# Rectangular RC beam sections per ACI 318.
# TODO: Implement full section analysis with rebar optimization.

"""
    RCBeamSection <: AbstractSection

Reinforced concrete rectangular beam section.

# RC Design Considerations
- Concrete provides compression resistance
- Steel reinforcement (rebar) provides tension resistance
- Design involves selecting both section dimensions AND rebar configuration
- Capacity depends on: b, h, d (effective depth), As (steel area), f'c, fy

# Fields (to be implemented)
- `name`: Section designation
- `b`: Width
- `h`: Total depth
- `d`: Effective depth (to centroid of tension steel)
- `As`: Area of tension reinforcement
- `As_prime`: Area of compression reinforcement (doubly reinforced)
- `n_bars`: Number of tension bars
- `bar_size`: Rebar size (e.g., #8)
- `concrete`: Concrete material (f'c)
- `rebar`: Rebar material (fy)
"""
struct RCBeamSection <: AbstractSection
    name::Union{String, Nothing}
    b::LengthQ           # Width
    h::LengthQ           # Total depth
    d::LengthQ           # Effective depth
    cover::LengthQ       # Clear cover to reinforcement
    # Reinforcement
    As::AreaQ            # Tension steel area
    As_prime::AreaQ      # Compression steel area
    n_bars::Int          # Number of tension bars
    bar_size::Int        # Bar designation (#4, #8, etc.)
end

# Stub constructor
function RCBeamSection(b, h; 
    cover=1.5u"inch", 
    bar_size=8, 
    n_bars=4,
    name=nothing
)
    # Estimate effective depth (simplified)
    d_bar = bar_size / 8 * u"inch"  # Approximate bar diameter
    d = h - cover - d_bar / 2
    
    # Steel area from bar count and size
    As_per_bar = π/4 * d_bar^2
    As = n_bars * As_per_bar
    As_prime = 0.0u"inch^2"
    
    RCBeamSection(name, b, h, d, cover, As, As_prime, n_bars, bar_size)
end

# Interface
area(s::RCBeamSection) = s.b * s.h  # Gross section area
depth(s::RCBeamSection) = s.h
width(s::RCBeamSection) = s.b

"""Reinforcement ratio ρ = As / (b × d)"""
rho(s::RCBeamSection) = s.As / (s.b * s.d)

# Future:
# compute_Mn(s::RCBeamSection, concrete, rebar) = ...
# check_min_reinforcement(s, concrete) = ...
# check_max_reinforcement(s, concrete) = ...
