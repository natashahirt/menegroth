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

"""Concrete slab area within the effective width for a solid slab —
`Ac = b_eff · t_slab` per AISC 360-16 §I3.2a (corpus aisc-360-16, p. 165)."""
_Ac(slab::SolidSlabOnBeam, b_eff) = b_eff * slab.t_slab

"""
Concrete slab area within the effective width for a deck slab.

Concrete *above* the top of the deck ribs is always counted; rib concrete is
not included for either deck orientation. For perpendicular deck this is
required by AISC 360-16 §I3.2c(2) (corpus aisc-360-16, p. 167). For
parallel deck with `wr/hr ≥ 1.5`, §I3.2c(3) *permits* including rib
concrete; excluding it here is therefore conservative for parallel deck —
under-reporting the available compression block reduces the plastic
neutral-axis shift and the resulting `Mn`. See `DeckSlabOnBeam` docstring.
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
                      b_eff, Mu_required, Qn; ϕ=0.9, partial_composite_min=0.0)
        -> (ΣQn, n_studs_half, sufficient)

Find the minimum number of studs per half-span such that `ϕ Mn ≥ Mu_required`.

Uses a binary search on continuous `ΣQn` to locate the capacity threshold,
then rounds up to the next integer stud count (`n = ceil(ΣQn / Qn)`). This
matches the AISC partial-composite design procedure: determine the required
`ΣQn`, then provide enough studs to achieve it.

`Mu_required` is the *factored* moment demand (e.g. `Mu`). The function
applies `ϕ` internally: it searches for the smallest `ΣQn` where
`ϕ · Mn(ΣQn) ≥ Mu_required`.

There is no strength floor on `ΣQn / Cf`. Commentary Eqs. C-I3-3 and C-I3-4
should not be used below 0.25 (AISC 360-22 Commentary §I3, corpus:
aisc-360-22, PDF p. 502). That limit is not applied here: this search is the
plastic stress distribution of §I3.2a, not those effective-section equations.
`partial_composite_min` defaults to 0.

# Arguments
- `Mu_required`: Required flexural strength (factored moment).
- `Qn`: Nominal shear strength of a single stud (from `get_Qn`).
- `ϕ`: Resistance factor (default `0.90`, AISC 360-22 §I3.2a — corpus
       aisc-360-22, PDF p. 169).
- `partial_composite_min`: Optional lower bound on `ΣQn / Cf_max` for the
       binary search (default `0`).
"""
function find_required_ΣQn(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                           b_eff, Mu_required, Qn; ϕ=0.9, partial_composite_min::Real=0.0)
    Cf_max = _Cf_max(section, material, slab, b_eff)

    # Bail out if even full composite is insufficient.
    result_full = get_Mn_composite(section, material, slab, b_eff, Cf_max)
    if ϕ * result_full.Mn < Mu_required
        return (; ΣQn=Cf_max, n_studs_half=ceil(Int, ustrip(u"N", Cf_max) / ustrip(u"N", Qn)),
                 sufficient=false)
    end

    # No code floor. C-I3-3 and C-I3-4's 0.25 limit is not a strength limit.
    ΣQn_lo = partial_composite_min * Cf_max
    ΣQn_hi = Cf_max

    for _ in 1:50
        ΣQn_mid = (ΣQn_lo + ΣQn_hi) / 2
        result_mid = get_Mn_composite(section, material, slab, b_eff, ΣQn_mid)
        if ϕ * result_mid.Mn >= Mu_required
            ΣQn_hi = ΣQn_mid
        else
            ΣQn_lo = ΣQn_mid
        end
        if abs(ΣQn_hi - ΣQn_lo) / Cf_max < 1e-8
            break
        end
    end

    # Round up to integer stud count
    n_studs_half = ceil(Int, ustrip(u"N", ΣQn_hi) / ustrip(u"N", Qn))
    ΣQn = n_studs_half * Qn

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
                          d_rebar=0.0u"m", ΣQn=nothing)
    # AISC 360-22 §I3.2d.2 Eqs. I3-2a and I3-2b (corpus: aisc-360-22, PDF p. 171):
    # the horizontal shear from the negative-moment region is the lesser of
    # tensile yielding of the developed reinforcement and the anchors in that
    # region. `ΣQn === nothing` leaves the reinforcement force uncapped; the
    # caller has not supplied the negative-region anchors.
    T_cap = Fysr * Asr
    if ΣQn !== nothing
        T_cap = min(uconvert(u"N", T_cap), uconvert(u"N", ΣQn))
    end
    if ustrip(u"N", uconvert(u"N", T_cap)) ≈ 0.0
        return material.Fy * section.Zx
    end

    As  = section.A
    Fy  = material.Fy
    d   = section.d
    bf  = section.bf
    tw  = section.tw
    tf  = section.tf
    h_w = section.h

    T_rebar = T_cap
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

"""
    available_negative_flexure(section, material; Lb, Asr, Fysr,
        neg_moment=false, d_rebar=0.0u"m", Cb=1.0, ϕ=0.9) -> Moment

Available negative flexural strength, AISC 360-22 §I3.2b (corpus: aisc-360-22,
PDF p. 170). The steel section alone is designed with Chapter F. The plastic
composite section is used only when all three limits hold:

  (a) the steel beam is compact and braced in accordance with Chapter F
      (`Lb ≤ Lp`);
  (b) steel anchors connect the slab to the beam in the negative-moment
      region (`neg_moment`), and `ΣQn` is their nominal strength between
      the maximum negative moment and the adjacent zero (§I3.2d.2 Eqs.
      I3-2a and I3-2b, PDF p. 171). A missing `ΣQn` is not the full rebar
      force;
  (c) the slab reinforcement parallel to the beam, within the effective
      width, is developed (`Asr > 0` and `Fysr > 0`). Passing that area
      asserts development. Bar lengths are not on the strip result, so
      development length is not computed.

`φb = 0.90`. When (a)–(c) hold, the available strength is the larger of the
Chapter F strength and `φb` times [`get_Mn_negative`](@ref).

Chapter F `φMn` is the existing AISC 360-16 implementation ([`get_ϕMn`](@ref)).
360-22 §I3.2b(a) points at Chapter F of the same specification. Chapter F has
not been re-derived from 360-22 in this function.

`Cb = 1.0` is the hogging default when the caller does not pass `Cb`. A
gravity-loaded rolled beam whose top flange is restrained uses Commentary
Eq. C-F1-5 when [`cb_gravity_top_flange_restrained`](@ref) is supplied.
"""
function available_negative_flexure(section::ISymmSection, material;
                                    Lb, Asr, Fysr,
                                    neg_moment::Bool = false,
                                    d_rebar = 0.0u"m",
                                    ΣQn = nothing,
                                    Cb::Real = 1.0, ϕ::Real = 0.9)
    ϕMn_steel = uconvert(u"N*m", get_ϕMn(section, material; Lb = Lb, Cb = Cb,
                                         axis = :strong, ϕ = ϕ))
    # §I3.2b(a): braced in accordance with Chapter F means Lb ≤ Lp
    # (AISC 360-16 §F2.2 Eq. F2-5 — corpus: aisc-360-16, PDF p. 104).
    Lp = get_Lp_Lr(section, material).Lp
    braced = ustrip(u"m", uconvert(u"m", Lb)) <= ustrip(u"m", uconvert(u"m", Lp))
    asr_ok = ustrip(u"m^2", uconvert(u"m^2", Asr)) > 0
    fysr_ok = ustrip(u"Pa", uconvert(u"Pa", Fysr)) > 0
    if neg_moment && ΣQn !== nothing && is_compact(section, material) &&
            braced && asr_ok && fysr_ok
        Mn_comp = get_Mn_negative(section, material, Asr, Fysr;
                                  d_rebar = d_rebar, ΣQn = ΣQn)
        return max(ϕMn_steel, uconvert(u"N*m", ϕ * Mn_comp))
    end
    return ϕMn_steel
end

"""
    cb_gravity_top_flange_restrained(Mo, M1, MCL) -> Float64

Moment-gradient factor for a gravity-loaded rolled I-beam whose top flange is
laterally restrained and which bends in reverse curvature.

AISC 360-22 Commentary Eq. C-F1-5 (corpus: aisc-360-22, PDF pp. 442–443).
This is commentary, not a specification equation. Figure C-F1.5, the uplift
cases, is a different set of expressions and is not evaluated here.

Sign convention, Figure C-F1.3: positive moment compresses the top flange,
negative moment compresses the bottom flange. `Mo` is the end moment with the
largest bottom-flange compression. `M1` is the other end. `MCL` is the moment
at mid-length. The unbraced length is the distance between points that restrain
twist.

    Cb = 3 − (2/3)(M1/Mo) − (8/3)(MCL / (Mo + M1)*)

`(Mo + M1)*` equals `Mo` when `M1` is positive. The worked example on PDF
p. 443 is `Mo = −100`, `M1 = +200`, `MCL = +50`, `Cb = 5.67`.
"""
function cb_gravity_top_flange_restrained(Mo, M1, MCL)
    mo = ustrip(u"N*m", uconvert(u"N*m", Mo))
    m1 = ustrip(u"N*m", uconvert(u"N*m", M1))
    mcl = ustrip(u"N*m", uconvert(u"N*m", MCL))
    mo == 0 && throw(ArgumentError(
        "Commentary Eq. C-F1-5 needs a nonzero end moment Mo."))
    # M1 is taken as zero in the last term when it is positive (PDF p. 443).
    denom = m1 > 0 ? mo : mo + m1
    denom == 0 && throw(ArgumentError(
        "Commentary Eq. C-F1-5 has a zero denominator for these end moments."))
    return 3.0 - (2 / 3) * (m1 / mo) - (8 / 3) * (mcl / denom)
end

"""
Cb from a sagging-positive moment field on one span, or `nothing`.

The field's sign matches Commentary Figure C-F1.3: sagging compresses the top
flange. `Mo` is the more negative end. The equation applies when that end
compresses the bottom flange. The unbraced length is taken as the member span.

ENGINEERING JUDGMENT: that span is the distance between twist restraints only
when the supports restrain twist. The moment field does not record twist braces.
"""
function cb_neg_from_moment_field(M_of_s)
    ms = _moment_newton(M_of_s(0.0))
    me = _moment_newton(M_of_s(1.0))
    mm = _moment_newton(M_of_s(0.5))
    if ms <= me
        mo, m1 = ms, me
    else
        mo, m1 = me, ms
    end
    mo < 0 || return nothing
    return cb_gravity_top_flange_restrained(mo * u"N*m", m1 * u"N*m", mm * u"N*m")
end

_moment_newton(M::Unitful.Quantity) = ustrip(u"N*m", uconvert(u"N*m", M))
_moment_newton(M::Real) = Float64(M)
