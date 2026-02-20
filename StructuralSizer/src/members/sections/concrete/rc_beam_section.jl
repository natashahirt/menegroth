# ==============================================================================
# Reinforced Concrete Beam Section
# ==============================================================================
# Rectangular RC beam sections per ACI 318.
# Supports singly and doubly reinforced configurations.
# ==============================================================================

using Asap: Length, Area, SecondMomentOfArea

# ==============================================================================
# Struct
# ==============================================================================

"""
    RCBeamSection <: AbstractSection

Rectangular reinforced concrete beam section.

# Fields
- `name`: Section designation (auto-generated if not provided)
- `b`: Beam width
- `h`: Total depth
- `d`: Effective depth (centroid of tension steel)
- `cover`: Clear cover to stirrups
- `As`: Total tension steel area
- `n_bars`: Number of tension bars
- `bar_size`: Tension bar designation (#4 – #11)
- `As_prime`: Total compression steel area (0 if singly reinforced)
- `n_bars_prime`: Number of compression bars
- `bar_size_prime`: Compression bar designation
- `d_prime`: Depth from compression face to compression steel centroid
- `stirrup_size`: Stirrup bar designation (#3, #4, etc.)

# Example
```julia
# Singly reinforced 12×20 beam with 3 #9 bars, #3 stirrups
sec = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=9, n_bars=3)

# Doubly reinforced with 2 #6 compression bars
sec = RCBeamSection(b=12u"inch", h=20u"inch",
    bar_size=9, n_bars=4,
    bar_size_prime=6, n_bars_prime=2)
```
"""
struct RCBeamSection{T<:Length, A<:Area} <: AbstractSection
    name::Union{String, Nothing}
    b::T
    h::T
    d::T
    cover::T
    # Tension reinforcement
    As::A
    n_bars::Int
    bar_size::Int
    # Compression reinforcement
    As_prime::A
    n_bars_prime::Int
    bar_size_prime::Int
    d_prime::T
    # Transverse
    stirrup_size::Int
end

# ==============================================================================
# Constructors
# ==============================================================================

"""
    RCBeamSection(; b, h, bar_size, n_bars, cover, stirrup_size,
                    bar_size_prime, n_bars_prime, name)

Construct an RC beam section with automatic effective depth and bar area
computed from the REBAR_CATALOG.

# Arguments
- `b`: Beam width
- `h`: Total depth
- `bar_size`: Tension bar size (4–11)
- `n_bars`: Number of tension bars
- `cover`: Clear cover to stirrups (default 1.5")
- `stirrup_size`: Stirrup bar size (default 3)
- `bar_size_prime`: Compression bar size (default 0 → singly reinforced)
- `n_bars_prime`: Number of compression bars (default 0)
- `name`: Optional designation
"""
function RCBeamSection(;
    b::Length,
    h::Length,
    bar_size::Int,
    n_bars::Int,
    cover::Length = 1.5u"inch",
    stirrup_size::Int = 3,
    bar_size_prime::Int = 0,
    n_bars_prime::Int = 0,
    name::Union{String, Nothing} = nothing
)
    # Convert to inches for consistent arithmetic
    b_in  = float(uconvert(u"inch", b))
    h_in  = float(uconvert(u"inch", h))
    cov   = float(uconvert(u"inch", cover))

    # Bar properties from catalog
    bar_tension = rebar(bar_size)
    Ab      = float(uconvert(u"inch^2", bar_tension.A))
    db      = float(uconvert(u"inch", bar_tension.diameter))
    d_stir  = float(uconvert(u"inch", rebar(stirrup_size).diameter))

    # Effective depth: h − cover − stirrup − db/2
    d_in = h_in - cov - d_stir - db / 2
    As   = n_bars * Ab

    # Compression reinforcement
    if n_bars_prime > 0 && bar_size_prime > 0
        bar_comp = rebar(bar_size_prime)
        Ab_prime = float(uconvert(u"inch^2", bar_comp.A))
        db_prime = float(uconvert(u"inch", bar_comp.diameter))
        As_prime = n_bars_prime * Ab_prime
        d_prime  = cov + d_stir + db_prime / 2
    else
        As_prime = 0.0u"inch^2"
        n_bars_prime = 0
        bar_size_prime = 0
        d_prime = cov + d_stir  # nominal (unused for singly reinforced)
    end

    # Auto-name
    if isnothing(name)
        b_nom = round(Int, ustrip(u"inch", b_in))
        h_nom = round(Int, ustrip(u"inch", h_in))
        comp_str = n_bars_prime > 0 ? "+$(n_bars_prime)#$(bar_size_prime)" : ""
        name = "$(b_nom)x$(h_nom)-$(n_bars)#$(bar_size)$(comp_str)"
    end

    RCBeamSection{typeof(b_in), typeof(As)}(
        name, b_in, h_in, d_in, cov,
        As, n_bars, bar_size,
        As_prime, n_bars_prime, bar_size_prime, d_prime,
        stirrup_size,
    )
end

# ==============================================================================
# Interface: AbstractSection
# ==============================================================================

"""Gross cross-sectional area Ag = b × h."""
section_area(s::RCBeamSection)  = s.b * s.h

"""Total depth."""
section_depth(s::RCBeamSection) = s.h

"""Beam width."""
section_width(s::RCBeamSection) = s.b

"""Tension reinforcement ratio ρ = As / (b × d)."""
rho(s::RCBeamSection) = ustrip(s.As / (s.b * s.d))

# ==============================================================================
# Gross Section Properties
# ==============================================================================

"""
    gross_moment_of_inertia(s::RCBeamSection)

Gross moment of inertia Ig = b h³ / 12 (strong axis).
"""
gross_moment_of_inertia(s::RCBeamSection) = s.b * s.h^3 / 12

"""
    section_modulus_bottom(s::RCBeamSection)

Bottom-fiber section modulus Sb = Ig / yt, where yt = h/2.
"""
section_modulus_bottom(s::RCBeamSection) = gross_moment_of_inertia(s) / (s.h / 2)

"""True if the beam has compression reinforcement."""
is_doubly_reinforced(s::RCBeamSection) = s.n_bars_prime > 0

# ==============================================================================
# Validation (ACI 318-11 §10.5 / §7.6)
# ==============================================================================

"""
    validate(s::RCBeamSection, fc::Pressure, fy::Pressure)

Run ACI 318 geometry and reinforcement ratio checks.  Issues `@warn` for
violations but does not throw — the checker is responsible for pass/fail.
"""
function validate(s::RCBeamSection, fc::Pressure, fy::Pressure)
    # Minimum reinforcement (ACI 9.6.1.2)
    As_min = beam_min_reinforcement(s.b, s.d, fc, fy)
    if s.As < As_min
        @warn "As = $(s.As) < As_min = $(As_min) (ACI 9.6.1.2)"
    end

    # Maximum bar spacing (ACI 24.3.2)
    s_max = beam_max_bar_spacing(fy)
    d_stir = rebar(s.stirrup_size).diameter
    db     = rebar(s.bar_size).diameter
    # Clear spacing between bars
    avail = s.b - 2 * s.cover - 2 * d_stir - s.n_bars * db
    if s.n_bars > 1
        actual_spacing = avail / (s.n_bars - 1) + db  # center-to-center
        if actual_spacing > s_max
            @warn "Bar c/c spacing $(actual_spacing) exceeds s_max = $(s_max) (ACI 24.3.2)"
        end
    end

    return nothing
end
