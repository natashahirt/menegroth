# ==============================================================================
# Composite Flexural Strength — AISC 360-16 Section I3.2
# ==============================================================================
#
# Implements:
#   - Horizontal shear force V' (Cf) per I3.2d
#   - Concrete compression area Ac
#   - PNA solver (continuous, not discretized)
#   - Composite Mn for positive moment (plastic stress distribution, I3.2a(a))
#   - Web compactness guard (I3.2a(b) → NotImplementedError for elastic method)
#   - Negative moment fallback (I3.2b)
#   - Required ΣQn for partial composite

# ==============================================================================
# Horizontal Shear (I3.2d) — Compression Force Cf
# ==============================================================================

"""
    get_Cf(section::ISymmSection, material, slab::AbstractSlabOnBeam, b_eff, ΣQn) -> Force

Compression force at the interface per AISC I3.2d.1.

`Cf = min(V'_concrete, V'_steel, ΣQn)` where:
  (a) V'_concrete = 0.85 fc′ Ac           (concrete crushing, Eq. I3-1a)
  (b) V'_steel    = Fy As                  (tensile yielding, Eq. I3-1b)
  (c) V'_studs    = ΣQn                    (anchor strength, Eq. I3-1c)

For **full** composite: `ΣQn ≥ min(V'_concrete, V'_steel)`.
For **partial** composite: `Cf = ΣQn < min(V'_concrete, V'_steel)`.
"""
function get_Cf(section::ISymmSection, material, slab::AbstractSlabOnBeam, b_eff, ΣQn)
    Ac = _Ac(slab, b_eff)
    V_concrete = 0.85 * slab.fc′ * Ac    # Eq. I3-1a
    V_steel    = material.Fy * section.A  # Eq. I3-1b
    return min(V_concrete, V_steel, ΣQn)
end

"""Concrete slab area within effective width (solid slab)."""
_Ac(slab::SolidSlabOnBeam, b_eff) = b_eff * slab.t_slab

"""
Concrete slab area within effective width for deck slab (AISC I3.2c(2)).
Only concrete above the top of the deck ribs participates in the stress block.
"""
_Ac(slab::DeckSlabOnBeam, b_eff) = b_eff * slab.t_slab

"""Maximum possible Cf (full composite)."""
function _Cf_max(section::ISymmSection, material, slab::AbstractSlabOnBeam, b_eff)
    Ac = _Ac(slab, b_eff)
    V_concrete = 0.85 * slab.fc′ * Ac
    V_steel    = material.Fy * section.A
    return min(V_concrete, V_steel)
end

# ==============================================================================
# Web Compactness Guard (I3.2a)
# ==============================================================================

"""
    _check_web_compact_composite(section::ISymmSection, material) -> nothing

AISC I3.2a: When h/tw ≤ 3.76√(E/Fy), use plastic stress distribution (I3.2a(a)).
When h/tw > 3.76√(E/Fy), the elastic method (I3.2a(b)) must be used — NOT YET IMPLEMENTED.
"""
function _check_web_compact_composite(section::ISymmSection, material)
    E_Fy = ustrip(material.E / material.Fy)
    limit = 3.76 * sqrt(E_Fy)
    if section.λ_w > limit
        throw(ErrorException(
            "Web slenderness h/tw = $(round(section.λ_w; digits=1)) > 3.76√(E/Fy) = $(round(limit; digits=1)). " *
            "Elastic stress distribution method (AISC I3.2a(b)) is required but not implemented. " *
            "Select a section with a compact web for composite flexure."))
    end
    return nothing
end

# ==============================================================================
# PNA Solver — Continuous (Plastic Stress Distribution, I1.2a)
# ==============================================================================
# Solves for the exact PNA location given Cf (compression force transferred
# through anchors). Two cases:
#
#   Case A: PNA in the slab  — Cf = As Fy (steel governs, entire steel in tension)
#   Case B: PNA in the steel — Cf < As Fy (partial composite or concrete governs)
#
# The key insight: PNA is in the slab ONLY when the entire steel section is
# in tension (Cf ≥ As Fy). For ANY partial composite case (Cf < As Fy),
# the PNA is in the steel section regardless of the stress block depth a.

"""
    _solve_pna(section::ISymmSection, material, slab::AbstractSlabOnBeam,
               b_eff, Cf) -> NamedTuple(:y_pna, :Mn)

Solve for the plastic neutral axis position and compute the nominal moment capacity
Mn by summing plastic forces × lever arms.

**Coordinate convention**: y = 0 at top of slab, positive downward.
- Slab:        y ∈ [0, t_slab]
- Top flange:  y ∈ [t_slab, t_slab + tf]
- Web:         y ∈ [t_slab + tf, t_slab + tf + h_web]
- Bot flange:  y ∈ [t_slab + tf + h_web, t_slab + d]

Returns a NamedTuple with:
- `y_pna`: PNA depth from top of slab
- `Mn`:    Nominal moment capacity about the PNA
"""
function _solve_pna(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                    b_eff, Cf)
    # Normalize everything to SI (Pa, m, m², N) to avoid Unitful dimension mismatches
    Fy  = uconvert(u"Pa", material.Fy)
    t_s = uconvert(u"m", slab.t_slab)
    d   = uconvert(u"m", section.d)
    bf  = uconvert(u"m", section.bf)
    tw  = uconvert(u"m", section.tw)
    tf  = uconvert(u"m", section.tf)
    h_w = uconvert(u"m", section.h)
    As  = uconvert(u"m^2", section.A)
    fc′ = uconvert(u"Pa", slab.fc′)
    b   = uconvert(u"m", b_eff)
    Cf  = uconvert(u"N", Cf)

    fc′_085 = 0.85 * fc′
    As_Fy = As * Fy

    # Compute stress block depth. For deck slabs, Cf is already limited by
    # _Ac (above-deck concrete), so a should not exceed t_slab in normal
    # situations. We clamp defensively.
    a_raw = Cf / (fc′_085 * b)
    a = min(a_raw, t_s)

    # Gap between top of steel and bottom of concrete (0 for solid slab, hr for deck)
    gap = uconvert(u"m", _gap_above_steel(slab))

    # Total distance from top of slab to top of steel
    t_s_total = t_s + gap

    if Cf >= As_Fy
        # --- Case A: PNA in the slab (entire steel section in tension) ---
        y_pna = a  # PNA at bottom of stress block, from slab top

        # Concrete resultant at a/2 from slab top; steel centroid at t_s_total + d/2
        arm = (t_s_total + d / 2) - a / 2
        Mn = Cf * arm
        return (; y_pna=y_pna, Mn=uconvert(u"N*m", Mn))

    else
        # --- Case B: PNA in the steel section ---
        C_slab = Cf
        A_steel_comp = (As_Fy - Cf) / (2 * Fy)

        return _pna_in_steel_si(d, bf, tw, tf, h_w, t_s_total, Fy, C_slab, A_steel_comp, a)
    end
end

"""
Locate PNA within the steel section and compute Mn.
All inputs are already in SI (m, Pa, N).

`t_s` is the total distance from the top of the slab to the top of the steel
section (= slab thickness for solid slab, = t_slab + hr for deck slab).
"""
function _pna_in_steel_si(d, bf, tw, tf, h_w, t_s, Fy, C_slab, A_steel_comp, a)
    Af = bf * tf

    if A_steel_comp <= Af
        y_in_flange = A_steel_comp / bf
        y_pna = t_s + y_in_flange
        Mn = _moments_about_pna_si(d, bf, tw, tf, h_w, t_s, Fy,
                                    C_slab, y_pna, y_in_flange, a, :top_flange)
    else
        A_in_web = A_steel_comp - Af
        y_in_web = A_in_web / tw
        y_pna = t_s + tf + y_in_web
        Mn = _moments_about_pna_si(d, bf, tw, tf, h_w, t_s, Fy,
                                    C_slab, y_pna, y_in_web, a, :web)
    end

    return (; y_pna=y_pna, Mn=uconvert(u"N*m", Mn))
end

"""
Sum of force × lever arm about the PNA. All inputs in SI (m, Pa, N).

`t_s` is the total distance from slab top to steel top (includes deck rib
height for deck slabs). The concrete resultant is at `a/2` from the slab
top. The PNA is at `y_pna` from the slab top.
"""
function _moments_about_pna_si(d, bf, tw, tf, h_w, t_s, Fy,
                                C_slab, y_pna, y_in_part, a, pna_location::Symbol)
    Mn = 0.0u"N*m"

    # 1. Concrete slab compression — resultant at a/2 from top of slab
    # (the slab concrete sits above the deck ribs; its centroid is at a/2 from the slab top)
    Mn += C_slab * (y_pna - a / 2)

    # 2. Top flange
    if pna_location === :top_flange
        if y_in_part > 0.0u"m"
            Mn += Fy * bf * y_in_part * (y_in_part / 2)       # comp above PNA
        end
        y_tf_tens = tf - y_in_part
        if y_tf_tens > 0.0u"m"
            Mn += Fy * bf * y_tf_tens * (y_tf_tens / 2)        # tens below PNA
        end
        # Web entirely in tension
        Mn += Fy * tw * h_w * ((tf - y_in_part) + h_w / 2)
    else
        # PNA in web — entire top flange in compression
        Mn += Fy * bf * tf * (y_pna - (t_s + tf / 2))

        if y_in_part > 0.0u"m"
            Mn += Fy * tw * y_in_part * (y_in_part / 2)        # web comp
        end
        y_web_tens = h_w - y_in_part
        if y_web_tens > 0.0u"m"
            Mn += Fy * tw * y_web_tens * (y_web_tens / 2)      # web tens
        end
    end

    # 3. Bottom flange — always in tension
    Mn += Fy * bf * tf * (t_s + d - tf / 2 - y_pna)

    return Mn
end

# ==============================================================================
# Composite Mn — Public API
# ==============================================================================

"""
    get_Mn_composite(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                     b_eff, ΣQn) -> NamedTuple(:Mn, :y_pna, :Cf, :a, :n_studs_half)

Nominal positive flexural strength of a composite beam per AISC I3.2a (plastic stress distribution).

Steps:
1. Check web compactness (I3.2a(a) vs (b)).
2. Compute Cf from min(concrete crushing, steel yielding, ΣQn).
3. Solve PNA position and compute Mn.

Returns Mn, PNA location, Cf, equivalent stress block depth `a`, and number of studs required
on each side of maximum moment.
"""
function get_Mn_composite(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                          b_eff, ΣQn)
    _check_web_compact_composite(section, material)

    Cf = get_Cf(section, material, slab, b_eff, ΣQn)
    result = _solve_pna(section, material, slab, b_eff, Cf)

    a = Cf / (0.85 * slab.fc′ * b_eff)

    return (; Mn=result.Mn, y_pna=result.y_pna, Cf=Cf, a=a)
end

"""
    get_ϕMn_composite(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                      b_eff, ΣQn; ϕ=0.9) -> Force×Length

Design positive flexural strength: ϕ_b × Mn.
"""
function get_ϕMn_composite(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                           b_eff, ΣQn; ϕ=0.9)
    result = get_Mn_composite(section, material, slab, b_eff, ΣQn)
    return (; ϕMn=ϕ * result.Mn, Mn=result.Mn, y_pna=result.y_pna, Cf=result.Cf, a=result.a)
end

# ==============================================================================
# Required ΣQn for a Target Mn (Partial Composite Solver)
# ==============================================================================

"""
    find_required_ΣQn(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                      b_eff, Mn_required, Qn; ϕ=0.9) -> (ΣQn, n_studs_half)

Binary search for the minimum ΣQn (total stud strength between zero and max moment)
that provides ϕMn ≥ Mn_required.

Returns `ΣQn` and `n_studs_half` (studs per half-span, rounded up).
If full composite is required, returns the maximum ΣQn.

# Arguments
- `Qn`: Nominal shear strength of a single stud (from `get_Qn`).
"""
function find_required_ΣQn(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                           b_eff, Mn_required, Qn; ϕ=0.9)
    Cf_max = _Cf_max(section, material, slab, b_eff)

    # Check if even full composite is insufficient
    result_full = get_Mn_composite(section, material, slab, b_eff, Cf_max)
    if ϕ * result_full.Mn < Mn_required
        return (; ΣQn=Cf_max, n_studs_half=ceil(Int, ustrip(u"N", Cf_max) / ustrip(u"N", Qn)),
                 sufficient=false)
    end

    # AISC I3.2d(5): minimum ΣQn ≥ 0.25 × Cf_max
    ΣQn_lo = 0.25 * Cf_max
    ΣQn_hi = Cf_max

    # Binary search
    for _ in 1:50
        ΣQn_mid = (ΣQn_lo + ΣQn_hi) / 2
        result_mid = get_Mn_composite(section, material, slab, b_eff, ΣQn_mid)
        if ϕ * result_mid.Mn >= Mn_required
            ΣQn_hi = ΣQn_mid
        else
            ΣQn_lo = ΣQn_mid
        end
        if abs(ΣQn_hi - ΣQn_lo) / Cf_max < 1e-8
            break
        end
    end

    ΣQn = ΣQn_hi  # conservative: use upper bound
    n_studs_half = ceil(Int, ustrip(u"N", ΣQn) / ustrip(u"N", Qn))

    return (; ΣQn=ΣQn, n_studs_half=n_studs_half, sufficient=true)
end

# ==============================================================================
# Negative Moment (I3.2b)
# ==============================================================================

"""
    get_Mn_negative(section::ISymmSection, material, Asr, Fysr;
                    d_rebar=0.0u"m") -> Moment

Nominal negative flexural strength per AISC I3.2b (plastic stress distribution
on composite section in negative bending).

If `Asr ≈ 0`, falls back to bare steel `Mn = Mp = Fy × Zx` (Chapter F).

For composite negative moment, the slab reinforcement is in tension:
- `T_rebar = Fysr × Asr`
- Steel section carries compression below PNA, tension above PNA.

# Arguments
- `d_rebar`: Distance from the **top of the steel section** to the rebar centroid
  (positive upward into the slab). Default 0 places the rebar resultant at the
  top of steel (conservative). For a more accurate calculation, set
  `d_rebar = cover + d_b/2` where cover is from the slab top to the bar center,
  measured downward. Then `d_rebar = t_slab - cover - d_b/2` above the steel top.
"""
function get_Mn_negative(section::ISymmSection, material, Asr, Fysr;
                          d_rebar=0.0u"m")
    if ustrip(u"m^2", Asr) ≈ 0.0
        return material.Fy * section.Zx
    end

    As  = section.A
    Fy  = material.Fy
    d   = section.d
    bf  = section.bf
    tw  = section.tw
    tf  = section.tf
    h_w = section.h

    T_rebar = Fysr * Asr
    d_r = uconvert(u"m", d_rebar)

    # PNA shifts downward (toward bottom flange) because rebar adds tension at top.
    # Equilibrium: T_rebar + Fy × A_tens_steel = Fy × A_comp_steel
    #   A_comp_below = (As Fy + T_rebar) / (2 Fy)
    A_comp_below = (As * Fy + T_rebar) / (2 * Fy)

    # Locate PNA in steel, measuring from bottom of section
    Af = bf * tf
    if A_comp_below <= Af
        y_from_bot = A_comp_below / bf
        # Rebar is at (d + d_r) from bottom of steel
        Mn = T_rebar * (d + d_r - y_from_bot) +
             Fy * bf * y_from_bot * (y_from_bot / 2) +
             Fy * bf * (tf - y_from_bot) * ((tf - y_from_bot) / 2) +
             Fy * tw * h_w * (tf - y_from_bot + h_w / 2) +
             Fy * bf * tf * (tf - y_from_bot + h_w + tf / 2)
    elseif A_comp_below <= Af + tw * h_w
        A_in_web = A_comp_below - Af
        y_in_web = A_in_web / tw
        y_from_bot = tf + y_in_web

        Mn = T_rebar * (d + d_r - y_from_bot) +
             Fy * bf * tf * (y_from_bot - tf / 2) +
             Fy * tw * y_in_web * (y_in_web / 2) +
             Fy * tw * (h_w - y_in_web) * ((h_w - y_in_web) / 2) +
             Fy * bf * tf * (h_w - y_in_web + tf / 2)
    else
        A_in_tf = A_comp_below - Af - tw * h_w
        y_in_tf = A_in_tf / bf
        y_from_bot = tf + h_w + y_in_tf

        Mn = T_rebar * (d + d_r - y_from_bot) +
             Fy * bf * tf * (y_from_bot - tf / 2) +
             Fy * tw * h_w * (y_from_bot - tf - h_w / 2) +
             Fy * bf * y_in_tf * (y_in_tf / 2) +
             Fy * bf * (tf - y_in_tf) * ((tf - y_in_tf) / 2)
    end

    return uconvert(u"N*m", Mn)
end
