# ==============================================================================
# ACI 318 Deflection Calculations
# ==============================================================================
#
# Element-agnostic serviceability calculations per ACI 318-11 §9.5.2.
# Works for beams, one-way slabs, and flat plate strips.
# ==============================================================================

"""
    cracked_moment_of_inertia(As, b, d, Ec, Es) -> SecondMomentOfArea

Cracked section moment of inertia Icr per ACI 24.2.3.5.

Uses transformed section analysis with modular ratio n = Es/Ec.
Solves the quadratic equilibrium equation for the neutral axis depth c,
then computes Icr = b·c³/3 + n·As·(d-c)².

# Arguments
- `As`: Tension steel area
- `b`: Section width
- `d`: Effective depth
- `Ec`: Concrete elastic modulus (Pressure)
- `Es`: Steel elastic modulus — pass from `material.rebar.E`

# Returns
Cracked moment of inertia Icr (in⁴)
"""
function cracked_moment_of_inertia(
    As::Area,
    b::Length,
    d::Length,
    Ec::Pressure,
    Es::Pressure
)
    # Strip to consistent units (psi, inches)
    As_in = ustrip(u"inch^2", As)
    b_in  = ustrip(u"inch", b)
    d_in  = ustrip(u"inch", d)
    Ec_psi = ustrip(u"psi", Ec)
    Es_psi = ustrip(u"psi", Es)

    # Modular ratio
    n = Es_psi / Ec_psi

    # Neutral axis depth from transformed section equilibrium:
    #   b·c²/2 = n·As·(d - c)
    #   c² + (2n·As/b)·c - (2n·As·d/b) = 0
    k1 = 2 * n * As_in / b_in
    k2 = -k1 * d_in
    c = (-k1 + sqrt(k1^2 - 4*k2)) / 2

    # Icr = b·c³/3 + n·As·(d-c)²
    Icr = b_in * c^3 / 3 + n * As_in * (d_in - c)^2

    return Icr * u"inch^4"
end

"""
    effective_moment_of_inertia(Mcr, Ma, Ig, Icr)

Effective moment of inertia per ACI 24.2.3.5 (Branson's equation).

    Ie = Icr + (Ig - Icr) × (Mcr/Ma)³   when Ma > Mcr
    Ie = Ig                               when Ma ≤ Mcr

# Arguments
- `Mcr`: Cracking moment
- `Ma`: Service load moment
- `Ig`: Gross moment of inertia
- `Icr`: Cracked moment of inertia

# Reference
- ACI 318-11 Eq. (9-10)
"""
function effective_moment_of_inertia(Mcr, Ma, Ig, Icr)
    if ustrip(u"N*m", Ma) <= ustrip(u"N*m", Mcr)
        return Ig
    end

    # Use Float64 ratio to avoid Unitful Int64 overflow when Mcr and Ma
    # have different unit representations (e.g. psi·in³ vs kip·ft).
    ratio = ustrip(u"N*m", Mcr) / ustrip(u"N*m", Ma)
    Ie = Icr + (Ig - Icr) * ratio^3

    # Ie cannot exceed Ig
    return min(Ie, Ig)
end

"""
    cracking_moment(fr, Ig, h) -> Moment

Cracking moment per ACI 24.2.3.5.

    Mcr = fr × Ig / yt

where yt = h/2 for rectangular sections.

# Arguments
- `fr`: Modulus of rupture (Pressure)
- `Ig`: Gross second moment of area (L⁴)
- `h`: Section depth (Length)
"""
function cracking_moment(fr::Pressure, Ig::SecondMomentOfArea, h::Length)
    yt = h / 2
    return fr * Ig / yt
end

"""
    immediate_deflection(w, l, Ec, Ie) -> Length

Immediate deflection for a uniformly loaded simply-supported member.

    Δi = 5 × w × l⁴ / (384 × Ec × Ie)

# Arguments
- `w`: Distributed load (force per unit length)
- `l`: Span length
- `Ec`: Concrete elastic modulus
- `Ie`: Effective moment of inertia (Length⁴)

# Reference
- Standard beam formula (simply supported, uniform load)
"""
function immediate_deflection(w, l::Length, Ec::Pressure, Ie)
    return 5 * w * l^4 / (384 * Ec * Ie)
end

"""
    long_term_deflection_factor(ξ, ρ_prime) -> Float64

Long-term deflection multiplier per ACI 24.2.4.1.

    λΔ = ξ / (1 + 50ρ')

# Arguments
- `ξ`: Time-dependent factor (2.0 for 5+ years, 1.4 for 1 year, etc.)
- `ρ_prime`: Compression reinforcement ratio As'/(b·d)

# Reference
- ACI 318-11 §9.5.2.5
"""
function long_term_deflection_factor(ξ::Float64=2.0, ρ_prime::Float64=0.0)
    return ξ / (1 + 50 * ρ_prime)
end

"""
    deflection_limit(l, limit_type::Symbol) -> Length

Allowable deflection per ACI Table 24.2.2.

# Arguments
- `l`: Span length
- `limit_type`:
  - `:immediate_ll` — l/360 (immediate, live load only)
  - `:total`        — l/240 (total after attachment)
  - `:sensitive`    — l/480 (supporting sensitive elements)
"""
function deflection_limit(l::Length, limit_type::Symbol)
    divisor = if limit_type == :immediate_ll
        360
    elseif limit_type == :total
        240
    elseif limit_type == :sensitive
        480
    else
        240  # Default
    end
    return l / divisor
end

# ==============================================================================
# Required Ix for Deflection (Steel Beams)
# ==============================================================================

"""
    required_Ix_for_deflection(w_LL, L, E; support, limit_ratio) -> SecondMomentOfArea

Minimum moment of inertia to satisfy a deflection limit for a uniformly
loaded elastic beam (steel). Inverts the standard beam deflection formula.

# Supported conditions
| `support`              | Δ formula           | coefficient |
|:-----------------------|:--------------------|:------------|
| `:simply_supported`    | 5wL⁴ / (384 EI)    | 5/384       |
| `:cantilever`          | wL⁴ / (8 EI)       | 1/8         |
| `:one_end_continuous`  | wL⁴ / (185 EI)     | 1/185       |
| `:both_ends_continuous`| wL⁴ / (384 EI)     | 1/384       |

# Arguments
- `w_LL`: Service live load per unit length (force/length)
- `L`: Span length
- `E`: Elastic modulus (steel)

# Keyword Arguments
- `support`: Support condition (default `:simply_supported`)
- `limit_ratio`: Deflection limit as fraction of L (default `1/360`).
  Common values: 1/360 (LL floor), 1/240 (total), 1/480 (sensitive).

# Returns
Minimum Ix (in⁴) to satisfy `Δ ≤ L × limit_ratio`.

# Example
```julia
Ix_req = required_Ix_for_deflection(0.8u"kip/ft", 25.0u"ft", 29000.0u"ksi")
# → ~500 in⁴ for L/360
```
"""
function required_Ix_for_deflection(
    w_LL, L::Length, E::Pressure;
    support::Symbol = :simply_supported,
    limit_ratio::Real = 1/360,
)
    coeff = if support == :simply_supported
        5 / 384
    elseif support == :cantilever
        1 / 8
    elseif support == :one_end_continuous
        1 / 185
    elseif support == :both_ends_continuous
        1 / 384
    else
        error("Unknown support condition: $support")
    end

    # Δ = coeff × w × L⁴ / (E × Ix)
    # Δ ≤ L × limit_ratio
    # ⟹ Ix ≥ coeff × w × L³ / (E × limit_ratio)
    Ix_min = coeff * w_LL * L^3 / (E * limit_ratio)
    return uconvert(u"inch^4", Ix_min)
end

# ==============================================================================
# Cracked Moment of Inertia — T-Section
# ==============================================================================

"""
    cracked_moment_of_inertia_tbeam(As, bw, bf, hf, d, Ec, Es) -> SecondMomentOfArea

Cracked section moment of inertia Icr for a T-shaped beam per ACI 24.2.3.5.

Uses transformed section analysis with modular ratio n = Es/Ec.
Two cases:
1. **Neutral axis in flange** (c ≤ hf): behaves as a rectangular beam of width bf.
2. **Neutral axis in web** (c > hf): includes flange overhang contribution.

# Arguments
- `As`: Tension steel area
- `bw`: Web width
- `bf`: Effective flange width
- `hf`: Flange (slab) thickness
- `d`: Effective depth (to centroid of tension steel)
- `Ec`: Concrete elastic modulus
- `Es`: Steel elastic modulus

# Returns
Cracked moment of inertia Icr (in⁴)
"""
function cracked_moment_of_inertia_tbeam(
    As::Area,
    bw::Length, bf::Length, hf::Length,
    d::Length,
    Ec::Pressure, Es::Pressure,
)
    As_in = ustrip(u"inch^2", As)
    bw_in = ustrip(u"inch", bw)
    bf_in = ustrip(u"inch", bf)
    hf_in = ustrip(u"inch", hf)
    d_in  = ustrip(u"inch", d)
    n     = ustrip(u"psi", Es) / ustrip(u"psi", Ec)

    # Trial: assume neutral axis in flange (rectangular with bf)
    k1 = 2 * n * As_in / bf_in
    k2 = -k1 * d_in
    c_trial = (-k1 + sqrt(k1^2 - 4*k2)) / 2

    if c_trial ≤ hf_in
        # Case 1: NA in flange — rectangular beam with width bf
        c = c_trial
        Icr = bf_in * c^3 / 3 + n * As_in * (d_in - c)^2
    else
        # Case 2: NA in web — solve equilibrium for T-section
        #   bf × hf × (c − hf/2) + bw × (c − hf)²/2 = n × As × (d − c)
        # Expanding:  bw/2 × c² + [(bf − bw)×hf + n×As] × c
        #           = (bf − bw)×hf²/2 + n×As×d
        # → (bw/2) c² + [(bf − bw)×hf + n×As] c − [(bf−bw)×hf²/2 + n×As×d] = 0
        a_coeff = bw_in / 2
        b_coeff = (bf_in - bw_in) * hf_in + n * As_in
        c_coeff = -((bf_in - bw_in) * hf_in^2 / 2 + n * As_in * d_in)
        c = (-b_coeff + sqrt(b_coeff^2 - 4*a_coeff*c_coeff)) / (2*a_coeff)

        # Icr via parallel-axis theorem:
        # Flange overhang: (bf − bw) × hf³ /12 + (bf − bw)×hf × (c − hf/2)²
        # Web above NA:    bw × c³ / 3   (measured from NA)
        # But since flange sits within 0..hf and web extends below:
        # Icr = bf×hf³/12 + bf×hf×(c − hf/2)²        (full flange about NA)
        #     + bw×(c − hf)³/3                          (web portion above flange bottom to NA)
        #     + n×As×(d − c)²                            (transformed steel)
        # Wait — more carefully:
        # The T-section above NA has two parts:
        #   Flange rectangle: bf × hf  (top hf of the section)
        #   Web strip: bw × (c − hf)   (from hf down to NA)
        # Below NA is just tension steel (cracked concrete ignored).
        Icr_flange = bf_in * hf_in^3 / 12 + bf_in * hf_in * (c - hf_in / 2)^2
        Icr_web    = bw_in * (c - hf_in)^3 / 3
        Icr_steel  = n * As_in * (d_in - c)^2
        Icr = Icr_flange + Icr_web + Icr_steel
    end

    return Icr * u"inch^4"
end
