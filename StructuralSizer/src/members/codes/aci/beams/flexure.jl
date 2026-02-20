# ==============================================================================
# ACI 318 Beam Flexural Design
# ==============================================================================
#
# Beam-specific flexural design per ACI 318-11 Chapter 10.
# Uses shared Whitney stress block from codes/aci/whitney.jl.
#
# Reference: DE-Simply-Supported-Reinforced-Concrete-Beam-Analysis-and-Design-
#            ACI-318-11-spBeam-v1000 (StructurePoint)
#
# Key ACI sections:
#   Table 9.5(a) - Minimum beam depth (deflection waiver)
#   §10.5.1     - Minimum flexural reinforcement (beams)
#   §10.2.7     - Whitney stress block
#   §9.3.2      - Strength reduction factors
# ==============================================================================

using Unitful
using Asap: kip, ksi, psf, ksf, pcf

# ==============================================================================
# Minimum Beam Depth (ACI 318-11 Table 9.5(a))
# ==============================================================================

"""
    beam_min_depth(L, support::Symbol) -> Length

Minimum beam depth to waive deflection calculations per ACI 318-11 Table 9.5(a).

# Arguments
- `L`: Span length (center-to-center)
- `support`: Support condition
  - `:simply_supported` → L/16
  - `:one_end_continuous` → L/18.5
  - `:both_ends_continuous` → L/21
  - `:cantilever` → L/8

# Reference
- ACI 318-11 Table 9.5(a)
- StructurePoint Example §1: h_min = 300/16 = 18.75 in
"""
function beam_min_depth(L::Length, support::Symbol=:simply_supported)
    divisor = if support == :simply_supported
        16
    elseif support == :one_end_continuous
        18.5
    elseif support == :both_ends_continuous
        21
    elseif support == :cantilever
        8
    else
        error("Unknown support condition: $support. Use :simply_supported, :one_end_continuous, :both_ends_continuous, or :cantilever")
    end
    return L / divisor
end

# ==============================================================================
# Effective Depth
# ==============================================================================

"""
    beam_effective_depth(h; cover, d_stirrup, d_bar) -> Length

Effective depth for a beam section.

    d = h - cover - d_stirrup - d_bar/2

# Arguments
- `h`: Total beam depth
- `cover`: Clear cover (default 1.5" per ACI Table 20.6.1.3.1 for beams)
- `d_stirrup`: Stirrup bar diameter (default 0.375" = #3)
- `d_bar`: Longitudinal bar diameter (default 1.128" = #9)

# Reference
- StructurePoint Example: d = 20 - 1.50 - 0.375 - 1.128/2 = 17.56 in
"""
function beam_effective_depth(h::Length;
    cover = 1.5u"inch",
    d_stirrup = 0.375u"inch",
    d_bar = 1.128u"inch"
)
    return h - cover - d_stirrup - d_bar / 2
end

# ==============================================================================
# Minimum Flexural Reinforcement (ACI 318-11 §10.5.1) — BEAM specific
# ==============================================================================

"""
    beam_min_reinforcement(bw, d, fc, fy) -> Area

Minimum flexural reinforcement for beams per ACI 318-11 §10.5.1.

    As,min = max(As_a, As_b)

where:
- As_a = 3√f'c × bw × d / fy   (Eq. (10-3))
- As_b = 200 × bw × d / fy      (200 bw d / fy)

**Note**: This is DIFFERENT from slab minimum reinforcement (ACI 8.6.1.1),
which uses shrinkage/temperature ratios (0.0018–0.0020) applied to b×h.
Beam minimums are higher and use effective depth d, not total depth h.

# Arguments
- `bw`: Beam web width
- `d`: Effective depth
- `fc`: Concrete compressive strength
- `fy`: Steel yield strength

# Reference
- ACI 318-11 §10.5.1
- StructurePoint Example: As_min = max(0.695, 0.702) = 0.702 in²
"""
function beam_min_reinforcement(bw::Length, d::Length, fc::Pressure, fy::Pressure)
    fc_psi = ustrip(u"psi", fc)
    fy_psi = ustrip(u"psi", fy)
    bw_in  = ustrip(u"inch", bw)
    d_in   = ustrip(u"inch", d)

    # Eq. (10-3): 3√f'c × bw × d / fy
    As_a = 3 * sqrt(fc_psi) * bw_in * d_in / fy_psi

    # (200 bw d / fy)
    As_b = 200 * bw_in * d_in / fy_psi

    return max(As_a, As_b) * u"inch^2"
end

# ==============================================================================
# Stress Block / Strain Check
# ==============================================================================

"""
    stress_block_depth(As, fc, fy, b) -> Length

Whitney stress block depth a = As × fy / (0.85 × f'c × b).

# Reference
- ACI 318-11 §10.2.7
- StructurePoint Example: a = 2.872 × 60000 / (0.85 × 4350 × 12) = 3.88 in
"""
function stress_block_depth(As::Area, fc::Pressure, fy::Pressure, b::Length)
    return As * fy / (0.85 * fc * b)
end

"""
    neutral_axis_depth(a, fc::Pressure) -> Length

Neutral axis depth c = a / β₁.

# Reference
- ACI 318-11 §10.2.7.3
- StructurePoint Example: c = 3.88 / 0.83 = 4.67 in
"""
function neutral_axis_depth(a::Length, fc::Pressure)
    β = beta1(fc)
    return a / β
end

"""
    tensile_strain(d, c) -> Float64

Net tensile strain in extreme tension steel per ACI 318-11 §9.3.2.

    εt = 0.003 × (dt - c) / c

where dt = d for a single layer of tension steel.

# Arguments
- `d`: Effective depth (distance to tension steel centroid)
- `c`: Neutral axis depth from compression face

# Returns
- εt (dimensionless strain)

# Classification (ACI 318-11 §9.3.2)
- εt ≥ 0.005: Tension-controlled (φ = 0.90)
- 0.002 ≤ εt < 0.005: Transition zone (φ interpolated)
- εt < 0.002: Compression-controlled (φ = 0.65)

# Reference
- StructurePoint Example: εt = 0.003 × (17.56 - 4.67) / 4.67 = 0.0083
"""
function tensile_strain(d::Length, c::Length)
    d_val = ustrip(u"inch", d)
    c_val = ustrip(u"inch", c)
    return 0.003 * (d_val - c_val) / c_val
end

"""
    is_tension_controlled(εt) -> Bool

Check whether section is tension-controlled (εt ≥ 0.005).
ACI 318-11 §9.3.2.
"""
is_tension_controlled(εt::Real) = εt ≥ 0.005

"""
    flexure_phi(εt) -> Float64

Strength reduction factor φ for flexure per ACI 318-11 §9.3.2.

- εt ≥ 0.005: φ = 0.90 (tension-controlled)
- εt ≤ 0.002: φ = 0.65 (compression-controlled, tied)
- Transition:  φ = 0.65 + 0.25(εt - 0.002)/0.003
"""
function flexure_phi(εt::Real)
    if εt ≥ 0.005
        return 0.90
    elseif εt ≤ 0.002
        return 0.65
    else
        return 0.65 + 0.25 * (εt - 0.002) / 0.003
    end
end

# ==============================================================================
# Maximum Bar Spacing (ACI 318-11 §10.6.4)
# ==============================================================================

"""
    beam_max_bar_spacing(fy; cc=1.875u"inch") -> Length

Maximum center-to-center spacing of longitudinal tension bars per ACI 318-11 §10.6.4
(crack control for beams and one-way slabs):

    s_max = min(15(ACI_CRACK_CONTROL_FS_PSI/fs) - 2.5cc,  12(ACI_CRACK_CONTROL_FS_PSI/fs))

where fs = (2/3)fy, cc = clear cover to tension steel face.

Default `cc = 1.5 + 0.375 = 1.875 in` (1.5" cover + #3 stirrup).

# Reference
- ACI 318-11 §10.6.4
- StructurePoint Example: s_max = min(10.31, 12) = 10.31 in
"""
function beam_max_bar_spacing(fy::Pressure; cc = 1.875u"inch")
    fs_psi = 2 / 3 * ustrip(u"psi", fy)
    cc_in  = ustrip(u"inch", cc)

    s1 = 15 * (ACI_CRACK_CONTROL_FS_PSI / fs_psi) - 2.5 * cc_in
    s2 = 12 * (ACI_CRACK_CONTROL_FS_PSI / fs_psi)
    return min(s1, s2) * u"inch"
end

# ==============================================================================
# Beam Bar Selection
# ==============================================================================

"""
    select_beam_bars(As_required, b; cover, d_stirrup, d_agg, fy) -> NamedTuple

Select longitudinal bar size and count for a rectangular beam.

Iterates through practical beam bar sizes (#6–#11) and selects the smallest bar
that fits within the beam width with proper clear spacing per ACI 318-11 §7.6.1:

    s_clear_min = max(1 in, d_bar, 4/3 × d_agg)

# Arguments
- `As_required`: Required steel area
- `b`: Beam width
- `cover`: Clear cover (default 1.5")
- `d_stirrup`: Stirrup diameter (default 0.375" = #3)
- `d_agg`: Maximum aggregate size (default 0.75")
- `fy`: Steel yield strength (default 60 ksi, for max spacing check)

# Returns
Named tuple: `(bar_size, n_bars, spacing, As_provided, s_clear)`

# Reference
- ACI 318-11 §7.6.1 (minimum spacing)
- ACI 318-11 §10.6.4 (maximum spacing)
- StructurePoint Example: 3-#9, spacing = 3.38 in, As = 3.00 in²
"""
function select_beam_bars(As_required::Area, b::Length;
        cover = 1.5u"inch",
        d_stirrup = 0.375u"inch",
        d_agg = 0.75u"inch",
        fy = 60000u"psi")

    As_in = ustrip(u"inch^2", As_required)

    # Available width between stirrup legs
    b_inner = b - 2 * (cover + d_stirrup)
    b_inner_in = ustrip(u"inch", b_inner)

    s_max = beam_max_bar_spacing(fy; cc = cover + d_stirrup)
    s_max_in = ustrip(u"inch", s_max)

    for bar_size in [6, 7, 8, 9, 10, 11]
        Ab_in = ustrip(u"inch^2", bar_area(bar_size))
        db_in = ustrip(u"inch", bar_diameter(bar_size))

        n_bars = ceil(Int, As_in / Ab_in)
        n_bars = max(n_bars, 2)

        # Minimum clear spacing (ACI 318-11 §7.6.1)
        s_clear_min = max(1.0, db_in, 4 / 3 * ustrip(u"inch", d_agg))

        # Width needed
        w_needed = n_bars * db_in + (n_bars - 1) * s_clear_min

        if w_needed ≤ b_inner_in
            As_provided = n_bars * bar_area(bar_size)
            # Center-to-center spacing
            s_ctc = (n_bars > 1) ? (b_inner_in - db_in) / (n_bars - 1) : b_inner_in
            s_clear = s_ctc - db_in

            # Check max bar spacing (ACI 318-11 §10.6.4)
            if s_ctc > s_max_in
                # Need more bars to satisfy crack control
                n_bars_max = floor(Int, (b_inner_in - db_in) / s_max_in) + 1
                n_bars = max(n_bars, n_bars_max)
                s_ctc = (n_bars > 1) ? (b_inner_in - db_in) / (n_bars - 1) : b_inner_in
                s_clear = s_ctc - db_in
                As_provided = n_bars * bar_area(bar_size)
            end

            return (
                bar_size = bar_size,
                n_bars = n_bars,
                spacing = s_ctc * u"inch",
                As_provided = As_provided,
                s_clear = s_clear * u"inch",
            )
        end
    end

    # Fallback: maximum #11 bars that fit
    db_in = ustrip(u"inch", bar_diameter(11))
    s_clear_min = max(1.0, db_in, 4 / 3 * ustrip(u"inch", d_agg))
    n_max = floor(Int, (b_inner_in + s_clear_min) / (db_in + s_clear_min))
    n_max = max(n_max, 2)
    As_provided = n_max * bar_area(11)
    s_ctc = (n_max > 1) ? (b_inner_in - db_in) / (n_max - 1) : b_inner_in

    return (
        bar_size = 11,
        n_bars = n_max,
        spacing = s_ctc * u"inch",
        As_provided = As_provided,
        s_clear = (s_ctc - db_in) * u"inch",
    )
end

# ==============================================================================
# Doubly Reinforced Beam Design
# ==============================================================================

"""
    max_singly_reinforced(b, d, fc, fy) -> NamedTuple

Maximum capacity of a tension-controlled singly reinforced rectangular section.

At the tension-controlled limit (εt = 0.005):
    c_max = d × εcu / (εcu + 0.005)
    a_max = β₁ × c_max
    Cc    = 0.85 × f'c × a_max × b
    As_max = Cc / fy
    Mn_max = Cc × (d - a_max/2)

# Returns
Named tuple: `(c_max, a_max, Cc, As_max, Mn_max, β1)`

# Reference
- ACI 318-11 §9.3.2 (εt = 0.005 tension-controlled limit)
- StructurePoint Doubly Reinforced Example §2.1:
  c = 9.75 in, a = 7.80 in, Cc = 464.10 kips, As = 7.74 in², Mn = 854.72 kip-ft
"""
function max_singly_reinforced(b::Length, d::Length, fc::Pressure, fy::Pressure)
    εcu = 0.003
    β = beta1(fc)

    # Neutral axis at tension-controlled limit
    d_in   = ustrip(u"inch", d)
    c_max  = d_in * εcu / (εcu + 0.005)
    a_max  = β * c_max

    # Concrete compression resultant
    fc_psi = ustrip(u"psi", fc)
    b_in   = ustrip(u"inch", b)
    Cc_lb  = 0.85 * fc_psi * a_max * b_in

    # Maximum tension steel
    fy_psi = ustrip(u"psi", fy)
    As_max = Cc_lb / fy_psi

    # Nominal moment capacity
    Mn_lb_in = Cc_lb * (d_in - a_max / 2)

    return (
        c_max  = c_max * u"inch",
        a_max  = a_max * u"inch",
        Cc     = Cc_lb * u"lbf",
        As_max = As_max * u"inch^2",
        Mn_max = Mn_lb_in * u"lbf" * u"inch",
        β1     = β,
    )
end

"""
    compression_steel_stress(c, d_prime, fc, fy, Es) -> (fs_prime, εs_prime, yields)

Stress in compression reinforcement using strain compatibility.

    ε's = εcu × (c - d') / c
    f's = min(Es × ε's,  fy)

# Arguments
- `c`: Neutral axis depth (at tension-controlled limit)
- `d_prime`: Depth to compression steel centroid from compression face
- `fc`: Concrete strength (unused except for documentation)
- `fy`: Steel yield strength
- `Es`: Steel elastic modulus — pass from rebar material

# Returns
Named tuple: `(fs_prime, εs_prime, yields)`

# Reference
- StructurePoint Doubly Reinforced Example:
  ε's = 0.003 × (9.75 - 3) / 9.75 = 0.00208 ≥ εy = 0.00207 → yields
"""
function compression_steel_stress(c::Length, d_prime::Length,
        fc::Pressure, fy::Pressure, Es::Pressure)
    c_in  = ustrip(u"inch", c)
    dp_in = ustrip(u"inch", d_prime)
    εcu   = 0.003

    εs_prime = εcu * (c_in - dp_in) / c_in
    εy       = ustrip(u"psi", fy) / ustrip(u"psi", Es)
    yields   = εs_prime ≥ εy

    fs_psi = min(ustrip(u"psi", Es) * εs_prime, ustrip(u"psi", fy))
    return (
        fs_prime  = fs_psi * u"psi",
        εs_prime  = εs_prime,
        yields    = yields,
    )
end

"""
    design_beam_flexure_doubly(Mu, b, d, d_prime, fc, fy, Es; ...) -> NamedTuple

Doubly reinforced beam design when the singly reinforced section is insufficient.

# Procedure (ACI 318-11 §10.2.7)
1. Compute max singly reinforced capacity (tension-controlled limit)
2. Excess moment: ΔMn = Mn_required - Mn_singly_max
3. Compression couple: Cs = ΔMn / (d - d')
4. Check if compression steel yields (strain compatibility at c_max)
5. Compression steel: A's = Cs / (f's - 0.85f'c)
6. Total tension steel: As = As_max + Cs / fy

# Arguments
- `Mu`: Factored moment demand
- `b`: Beam width
- `d`: Effective depth (tension steel)
- `d_prime`: Depth to compression steel centroid
- `fc`: Concrete compressive strength
- `fy`: Steel yield strength
- `Es`: Steel elastic modulus — pass from rebar material

# Returns
Named tuple with:
- `doubly_reinforced`: true
- `As_tension`: Total tension steel area
- `As_compression`: Compression steel area
- `Mn_singly`: Max singly reinforced nominal moment
- `Mn_required`: Required nominal moment
- `ΔMn`: Excess moment carried by compression couple
- `Cs`: Compression steel force
- `c`: Neutral axis depth (at tension-controlled limit)
- `a`: Stress block depth
- `εt`: Net tensile strain (= 0.005 at limit)
- `εs_prime`: Compression steel strain
- `fs_prime`: Compression steel stress
- `comp_steel_yields`: Bool
- `φ`: Strength reduction factor (0.90)
- `tension_controlled`: true (designed to be at limit)
- `bars_tension`: Bar selection for tension zone
- `bars_compression`: Bar selection for compression zone

# Reference
- StructurePoint Doubly Reinforced Beam Example:
  As' = 1.81 in², As = 9.42 in², Mn = 1048 kip-ft
"""
function design_beam_flexure_doubly(Mu::Moment, b::Length, d::Length, d_prime::Length,
        fc::Pressure, fy::Pressure, Es::Pressure;
        cover = 1.5u"inch",
        d_stirrup = 0.375u"inch",
        d_agg = 0.75u"inch")

    φ = 0.90  # designing for tension-controlled
    fc_psi = ustrip(u"psi", fc)
    fy_psi = ustrip(u"psi", fy)
    d_in   = ustrip(u"inch", d)
    dp_in  = ustrip(u"inch", d_prime)
    b_in   = ustrip(u"inch", b)

    # Step 1: Max singly reinforced capacity
    sr = max_singly_reinforced(b, d, fc, fy)
    Mn_singly_in_lb = ustrip(u"lbf", sr.Cc) * (d_in - ustrip(u"inch", sr.a_max) / 2)
    Mn_singly = Mn_singly_in_lb * u"lbf" * u"inch"

    # Step 2: Required nominal moment
    Mu_in_lb = ustrip(u"lbf*inch", Mu)
    Mn_req_in_lb = Mu_in_lb / φ
    Mn_required = Mn_req_in_lb * u"lbf" * u"inch"

    # Step 3: Excess moment for compression couple
    ΔMn_in_lb = Mn_req_in_lb - Mn_singly_in_lb
    if ΔMn_in_lb ≤ 0
        error("Section is adequate as singly reinforced — use design_beam_flexure instead")
    end

    # Step 4: Compression couple force
    lever = d_in - dp_in  # (d - d') in inches
    Cs_lb = ΔMn_in_lb / lever

    # Step 5: Compression steel stress (strain compatibility at c_max)
    comp = compression_steel_stress(sr.c_max, d_prime, fc, fy, Es)
    fs_prime_psi = ustrip(u"psi", comp.fs_prime)

    # Step 6: Compression steel area (subtract displaced concrete per ACI 318-11 §10.2.7)
    As_prime = Cs_lb / (fs_prime_psi - 0.85 * fc_psi)

    # Step 7: Total tension steel (equilibrium)
    #   As = As_max(singly) + Cs/fy
    As_max_in = ustrip(u"inch^2", sr.As_max)
    As_tension = As_max_in + Cs_lb / fy_psi

    # Bar selection for both zones
    bars_tension = select_beam_bars(As_tension * u"inch^2", b;
        cover=cover, d_stirrup=d_stirrup, d_agg=d_agg, fy=fy)
    bars_compression = select_beam_bars(As_prime * u"inch^2", b;
        cover=cover, d_stirrup=d_stirrup, d_agg=d_agg, fy=fy)

    return (
        doubly_reinforced   = true,
        As_tension          = As_tension * u"inch^2",
        As_compression      = As_prime * u"inch^2",
        Mn_singly           = Mn_singly,
        Mn_required         = Mn_required,
        ΔMn                 = ΔMn_in_lb * u"lbf" * u"inch",
        Cs                  = Cs_lb * u"lbf",
        c                   = sr.c_max,
        a                   = sr.a_max,
        εt                  = 0.005,
        εs_prime            = comp.εs_prime,
        fs_prime            = comp.fs_prime,
        comp_steel_yields   = comp.yields,
        φ                   = φ,
        tension_controlled  = true,
        bars_tension        = bars_tension,
        bars_compression    = bars_compression,
    )
end

# ==============================================================================
# Full Flexural Design (Singly / Doubly Reinforced Auto-Dispatch)
# ==============================================================================

"""
    design_beam_flexure(Mu, b, d, fc, fy, Es; d_prime, cover, d_stirrup, d_agg) -> NamedTuple

Complete beam flexural design for a rectangular section.

Automatically detects whether the section needs compression reinforcement:
- If singly reinforced is sufficient → returns singly reinforced result
- If singly reinforced capacity is exceeded → falls back to doubly reinforced design

# Arguments
- `Mu`: Factored moment demand
- `b`: Beam width
- `d`: Effective depth
- `fc`: Concrete compressive strength
- `fy`: Steel yield strength
- `Es`: Steel elastic modulus — pass from rebar material (needed for doubly reinforced)
- `d_prime`: Depth to compression steel (default = cover + d_stirrup + d_bar/2).
             Only used if doubly reinforced design is needed.
- `cover`: Clear cover (default 1.5")
- `d_stirrup`: Stirrup diameter (default 0.375")
- `d_agg`: Maximum aggregate size (default 0.75")

# Returns (singly reinforced)
Named tuple with:
- `doubly_reinforced`: false
- `As_required`, `As_min`, `As_design`
- `a`, `c`, `εt`, `φ`, `tension_controlled`
- `bars`: Bar selection

# Returns (doubly reinforced)
Named tuple with:
- `doubly_reinforced`: true
- `As_tension`, `As_compression`
- `Mn_singly`, `Mn_required`, `ΔMn`, `Cs`
- `c`, `a`, `εt`, `εs_prime`, `fs_prime`, `comp_steel_yields`
- `φ`, `tension_controlled`
- `bars_tension`, `bars_compression`

# Reference
- StructurePoint Simply Supported Beam Example §4 (singly)
- StructurePoint Doubly Reinforced Beam Example §2 (doubly)
"""
function design_beam_flexure(Mu::Moment, b::Length, d::Length, fc::Pressure, fy::Pressure, Es::Pressure;
        d_prime::Union{Length, Nothing} = nothing,
        cover = 1.5u"inch",
        d_stirrup = 0.375u"inch",
        d_agg = 0.75u"inch")

    # Check if singly reinforced is sufficient
    sr = max_singly_reinforced(b, d, fc, fy)
    Mn_singly_in_lb = ustrip(u"lbf", sr.Cc) * (ustrip(u"inch", d) - ustrip(u"inch", sr.a_max) / 2)
    φ_Mn_singly = 0.90 * Mn_singly_in_lb * u"lbf" * u"inch"

    if Mu ≤ φ_Mn_singly
        # --- Singly reinforced ---
        As_req = required_reinforcement(Mu, b, d, fc, fy)
        if isinf(As_req)
            error("Beam section inadequate: moment demand exceeds capacity. Increase d or f'c.")
        end
        As_min = beam_min_reinforcement(b, d, fc, fy)
        As_design = max(As_req, As_min)

        a = stress_block_depth(As_design, fc, fy, b)
        c = neutral_axis_depth(a, fc)
        εt = tensile_strain(d, c)
        φ = flexure_phi(εt)
        tc = is_tension_controlled(εt)

        bars = select_beam_bars(As_design, b;
            cover=cover, d_stirrup=d_stirrup, d_agg=d_agg, fy=fy)

        return (
            doubly_reinforced = false,
            As_required = As_req,
            As_min = As_min,
            As_design = As_design,
            a = a,
            c = c,
            εt = εt,
            φ = φ,
            tension_controlled = tc,
            bars = bars,
        )
    else
        # --- Doubly reinforced ---
        dp = if d_prime === nothing
            # Default: mirror of tension side
            cover + d_stirrup + 0.5u"inch"  # approximate bar centroid
        else
            d_prime
        end

        return design_beam_flexure_doubly(Mu, b, d, dp, fc, fy, Es;
            cover=cover, d_stirrup=d_stirrup, d_agg=d_agg)
    end
end

