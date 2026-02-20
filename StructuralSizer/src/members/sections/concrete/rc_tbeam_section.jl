# ==============================================================================
# Reinforced Concrete T-Beam Section
# ==============================================================================
# T-shaped RC beam sections per ACI 318.
# Consists of a rectangular web (bw × h) with a flange (bf × hf).
# ==============================================================================

using Asap: Length, Area

# ==============================================================================
# Struct
# ==============================================================================

"""
    RCTBeamSection <: AbstractSection

T-shaped reinforced concrete beam section (monolithic with slab).

# Fields
- `name`: Section designation (auto-generated if not provided)
- `bw`: Web width
- `h`: Total depth (bottom of web to top of flange)
- `d`: Effective depth (centroid of tension steel)
- `bf`: Effective flange width (per ACI 318-11 §8.12.2)
- `hf`: Flange thickness (slab thickness)
- `cover`: Clear cover to stirrups
- `As`: Total tension steel area
- `n_bars`: Number of tension bars
- `bar_size`: Tension bar designation (#4–#11)
- `As_prime`: Total compression steel area (0 if singly reinforced)
- `n_bars_prime`: Number of compression bars
- `bar_size_prime`: Compression bar designation
- `d_prime`: Depth from compression face to compression steel centroid
- `stirrup_size`: Stirrup bar designation (#3, #4, etc.)

# Example
```julia
sec = RCTBeamSection(bw=12u"inch", h=24u"inch", bf=48u"inch", hf=5u"inch",
                     bar_size=9, n_bars=4)
```
"""
struct RCTBeamSection{T<:Length, A<:Area} <: AbstractSection
    name::Union{String, Nothing}
    bw::T          # Web width
    h::T           # Total depth
    d::T           # Effective depth
    bf::T          # Effective flange width
    hf::T          # Flange (slab) thickness
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
    RCTBeamSection(; bw, h, bf, hf, bar_size, n_bars, cover, stirrup_size, ...)

Construct an RC T-beam section with automatic effective depth and bar area
computed from the REBAR_CATALOG.

# Arguments
- `bw`: Web width
- `h`: Total depth
- `bf`: Effective flange width (≥ bw)
- `hf`: Flange (slab) thickness (< h)
- `bar_size`: Tension bar size (4–11)
- `n_bars`: Number of tension bars (placed in web)
- `cover`: Clear cover to stirrups (default 1.5")
- `stirrup_size`: Stirrup bar size (default 3)
- `bar_size_prime`: Compression bar size (default 0 → singly reinforced)
- `n_bars_prime`: Number of compression bars (default 0)
- `name`: Optional designation
"""
function RCTBeamSection(;
    bw::Length,
    h::Length,
    bf::Length,
    hf::Length,
    bar_size::Int,
    n_bars::Int,
    cover::Length = 1.5u"inch",
    stirrup_size::Int = 3,
    bar_size_prime::Int = 0,
    n_bars_prime::Int = 0,
    name::Union{String, Nothing} = nothing,
)
    bw_in = float(uconvert(u"inch", bw))
    h_in  = float(uconvert(u"inch", h))
    bf_in = float(uconvert(u"inch", bf))
    hf_in = float(uconvert(u"inch", hf))
    cov   = float(uconvert(u"inch", cover))

    bf_in ≥ bw_in || throw(ArgumentError("Flange width bf must be ≥ web width bw"))
    hf_in < h_in  || throw(ArgumentError("Flange thickness hf must be < total depth h"))

    # Bar properties from catalog
    bar_tension = rebar(bar_size)
    Ab     = float(uconvert(u"inch^2", bar_tension.A))
    db     = float(uconvert(u"inch", bar_tension.diameter))
    d_stir = float(uconvert(u"inch", rebar(stirrup_size).diameter))

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
        d_prime = cov + d_stir
    end

    # Auto-name: T<bw>x<h>-bf<bf>-<n>#<size>
    if isnothing(name)
        bw_nom = round(Int, ustrip(u"inch", bw_in))
        h_nom  = round(Int, ustrip(u"inch", h_in))
        bf_nom = round(Int, ustrip(u"inch", bf_in))
        comp_str = n_bars_prime > 0 ? "+$(n_bars_prime)#$(bar_size_prime)" : ""
        name = "T$(bw_nom)x$(h_nom)-bf$(bf_nom)-$(n_bars)#$(bar_size)$(comp_str)"
    end

    RCTBeamSection{typeof(bw_in), typeof(As)}(
        name, bw_in, h_in, d_in, bf_in, hf_in, cov,
        As, n_bars, bar_size,
        As_prime, n_bars_prime, bar_size_prime, d_prime,
        stirrup_size,
    )
end

# ==============================================================================
# Interface: AbstractSection
# ==============================================================================

"""Gross T-shaped cross-sectional area: Ag = bf × hf + bw × (h − hf)."""
section_area(s::RCTBeamSection) = s.bf * s.hf + s.bw * (s.h - s.hf)

"""Total depth."""
section_depth(s::RCTBeamSection) = s.h

"""Web width (controls shear and bar placement)."""
section_width(s::RCTBeamSection) = s.bw

"""Effective flange width."""
flange_width(s::RCTBeamSection) = s.bf

"""Flange (slab) thickness."""
flange_thickness(s::RCTBeamSection) = s.hf

"""Tension reinforcement ratio ρ = As / (bw × d)."""
rho(s::RCTBeamSection) = ustrip(s.As / (s.bw * s.d))

"""True if the beam has compression reinforcement."""
is_doubly_reinforced(s::RCTBeamSection) = s.n_bars_prime > 0

# ==============================================================================
# Gross Section Properties (T-shape)
# ==============================================================================

"""
    gross_centroid_from_top(s::RCTBeamSection) -> Length

Distance from the compression face (top of flange) to the centroid of the
gross T-shaped cross section.
"""
function gross_centroid_from_top(s::RCTBeamSection)
    Af = s.bf * s.hf
    Aw = s.bw * (s.h - s.hf)
    Ag = Af + Aw
    return (Af * s.hf / 2 + Aw * (s.hf + (s.h - s.hf) / 2)) / Ag
end

"""
    gross_moment_of_inertia(s::RCTBeamSection)

Gross moment of inertia Ig about the centroidal axis (strong axis) of the
T-shaped cross section using the parallel-axis theorem.
"""
function gross_moment_of_inertia(s::RCTBeamSection)
    ȳ = gross_centroid_from_top(s)
    Af = s.bf * s.hf
    Aw = s.bw * (s.h - s.hf)

    Ig_f = s.bf * s.hf^3 / 12 + Af * (ȳ - s.hf / 2)^2
    Ig_w = s.bw * (s.h - s.hf)^3 / 12 + Aw * (s.hf + (s.h - s.hf) / 2 - ȳ)^2

    return Ig_f + Ig_w
end

"""
    section_modulus_bottom(s::RCTBeamSection)

Bottom-fiber section modulus Sb = Ig / yb.
"""
function section_modulus_bottom(s::RCTBeamSection)
    ȳ = gross_centroid_from_top(s)
    yb = s.h - ȳ
    return gross_moment_of_inertia(s) / yb
end

# ==============================================================================
# Validation (ACI 318-11 §10.5 / §7.6)
# ==============================================================================

"""
    validate(s::RCTBeamSection, fc::Pressure, fy::Pressure)

Run ACI 318 geometry and reinforcement ratio checks for T-beams.
Minimum reinforcement uses bw (web width) per ACI 318-11 §10.5.1.
"""
function validate(s::RCTBeamSection, fc::Pressure, fy::Pressure)
    # Minimum reinforcement (ACI 9.6.1.2) — uses bw for T-beams
    As_min = beam_min_reinforcement(s.bw, s.d, fc, fy)
    if s.As < As_min
        @warn "As = $(s.As) < As_min = $(As_min) (ACI 9.6.1.2, bw=$(s.bw))"
    end

    # Maximum bar spacing within web (ACI 24.3.2)
    s_max = beam_max_bar_spacing(fy)
    d_stir = rebar(s.stirrup_size).diameter
    db     = rebar(s.bar_size).diameter
    avail = s.bw - 2 * s.cover - 2 * d_stir - s.n_bars * db
    if s.n_bars > 1
        actual_spacing = avail / (s.n_bars - 1) + db
        if actual_spacing > s_max
            @warn "Bar c/c spacing $(actual_spacing) exceeds s_max = $(s_max) (ACI 24.3.2)"
        end
    end

    return nothing
end
