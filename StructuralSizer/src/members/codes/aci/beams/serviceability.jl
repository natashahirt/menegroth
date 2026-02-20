# ==============================================================================
# ACI 318 Beam Serviceability — Deflection Checks
# ==============================================================================
#
# Wraps the shared deflection primitives (codes/aci/deflection.jl) into a
# convenient beam-level interface.
#
# Methodology follows StructurePoint / standard ACI 318-11 §9.5.2 approach:
#   1. Compute Ie_D  from Ma_D  (dead load service moment)
#   2. Compute Ie_DL from Ma_DL (total D+L service moment)
#   3. Δ_D  = 5 wD L⁴ / (384 Ec Ie_D)
#   4. Δ_DL = 5 (wD+wL) L⁴ / (384 Ec Ie_DL)
#   5. Δ_LL = Δ_DL − Δ_D    ← subtraction approach
#
# Reference: ACI 318-11 §9.5.2, Table 9.5(b)
#            DE-Simply-Supported-Reinforced-Concrete-Beam-Analysis-and-Design-
#            ACI-318-11-spBeam-v1000 (StructurePoint), pg. 11–14
# ==============================================================================

"""
    design_beam_deflection(b, h, d, As, fc, fy, Es, L, w_dead, w_live;
                           support, wc_pcf, As_prime, ξ, limits) -> NamedTuple

Complete immediate + long-term deflection check for a rectangular RC beam.

Uses the StructurePoint / standard ACI approach where live load deflection is
computed by subtraction: `Δ_LL = Δ_DL − Δ_D`. This properly accounts for the
different effective stiffness at each load level.

# Procedure
1. Compute `Ec` from concrete properties (general or simplified formula)
2. Compute `fr`, `Ig`, `Mcr` for the gross section
3. Compute `Icr` via transformed-section analysis
4. Service moments: `Ma_D` (dead only), `Ma_DL` (dead + live)
5. Effective `Ie_D` from `Ma_D`, effective `Ie_DL` from `Ma_DL`
6. Immediate deflections:
   - `Δ_D  = f(wD, L, Ec, Ie_D)`
   - `Δ_DL = f(wD+wL, L, Ec, Ie_DL)`
   - `Δ_LL = Δ_DL − Δ_D`
7. Long-term: `λΔ` per ACI 318-11 §9.5.2.5
8. Total: `Δ_total = λΔ × Δ_D + Δ_LL`
9. Compare against ACI Table 9.5(b) limits

# Arguments
- `b`, `h`, `d`, `As`: Beam geometry and tension steel area
- `fc`: Concrete compressive strength
- `fy`: Steel yield strength
- `Es`: Steel elastic modulus
- `L`: Span length
- `w_dead`, `w_live`: Unfactored service loads (force/length)
- `support`: `:simply_supported`, `:cantilever`, etc.
- `wc_pcf`: Concrete unit weight in pcf (default 150). When provided, uses the
  general Ec formula `33 × wc^1.5 × √f'c` (ACI 318-11 §8.5.1). Set to `nothing`
  to use the simplified `57000√f'c` formula.
- `As_prime`: Compression steel area for long-term factor (default 0)
- `ξ`: Time-dependent factor (default 2.0 → 5+ years)
- `limits`: Deflection limit types to check (default `[:immediate_ll, :total]`)

# Returns
Named tuple with all intermediate and final results, matching StructurePoint
output format (Ie_D, Ie_DL, Δ_D, Δ_DL, Δ_LL, etc.).

# Reference
- StructurePoint Simply Supported Beam Example §6 (pg. 11–14):
  Ec = 3998.5 ksi, Icr = 3759 in⁴, Ie_D = 4337, Ie_DL = 3812,
  Δ_D = 0.416, Δ_DL = 1.050, Δ_LL = 0.634 in < L/360 = 0.833 ✓
"""
function design_beam_deflection(
    b::Length, h::Length, d::Length, As::Area,
    fc::Pressure, fy::Pressure, Es::Pressure,
    L::Length, w_dead, w_live;
    support::Symbol  = :simply_supported,
    wc_pcf::Union{Real, Nothing} = 150,
    As_prime::Area   = 0.0u"inch^2",
    ξ::Float64       = 2.0,
    limits::Vector{Symbol} = [:immediate_ll, :total]
)
    # --- Material properties ---
    Ec_val = wc_pcf === nothing ? Ec(fc) : Ec(fc, wc_pcf)
    fr_val = fr(fc)

    # --- Gross section ---
    Ig = b * h^3 / 12
    yt = h / 2
    Mcr = cracking_moment(fr_val, Ig, h)

    # --- Cracked section ---
    Icr = cracked_moment_of_inertia(As, b, d, Ec_val, Es)

    # --- Service moments (unfactored, per ACI 318-11 §9.5.2) ---
    Ma_dead  = _beam_moment(w_dead, L, support)
    Ma_live  = _beam_moment(w_live, L, support)
    Ma_total = Ma_dead + Ma_live

    # --- Effective moment of inertia (StructurePoint approach) ---
    # Ie_D  ← from dead load moment
    # Ie_DL ← from total D+L moment
    Ie_D  = effective_moment_of_inertia(Mcr, Ma_dead,  Ig, Icr)
    Ie_DL = effective_moment_of_inertia(Mcr, Ma_total, Ig, Icr)

    # --- Immediate deflections ---
    # Dead load deflection uses Ie_D
    Δ_D  = _beam_deflection(w_dead, L, Ec_val, Ie_D, support)
    # Total D+L deflection uses Ie_DL
    w_total = w_dead + w_live
    Δ_DL = _beam_deflection(w_total, L, Ec_val, Ie_DL, support)
    # Live load by subtraction (standard ACI / StructurePoint approach)
    Δ_LL = Δ_DL - Δ_D

    # --- Long-term deflection (ACI 318-11 §9.5.2.5) ---
    ρ_prime = ustrip(As_prime / (b * d))
    λΔ = long_term_deflection_factor(ξ, ρ_prime)
    Δ_lt_dead = λΔ * Δ_D
    Δ_total   = Δ_lt_dead + Δ_LL   # total long-term deflection after attachments

    # --- Limit checks ---
    checks = Dict{Symbol, NamedTuple}()
    for lim in limits
        Δ_allow = deflection_limit(L, lim)
        Δ_check = lim == :immediate_ll ? Δ_LL : Δ_total
        ok = Δ_check ≤ Δ_allow
        checks[lim] = (Δ=Δ_check, limit=Δ_allow, ok=ok,
                        ratio=ustrip(u"inch", Δ_check) / ustrip(u"inch", Δ_allow))
    end
    all_ok = all(c -> c.ok, values(checks))

    return (
        # Material
        Ec         = Ec_val,
        fr         = fr_val,
        # Section
        Ig         = Ig,
        Icr        = Icr,
        Mcr        = Mcr,
        # Service moments
        Ma_dead    = Ma_dead,
        Ma_live    = Ma_live,
        Ma_total   = Ma_total,
        # Effective Ie (StructurePoint approach: separate D and D+L)
        Ie_D       = Ie_D,
        Ie_DL      = Ie_DL,
        # Immediate deflections
        Δ_D        = Δ_D,
        Δ_DL       = Δ_DL,
        Δ_LL       = Δ_LL,
        # Long-term
        λΔ         = λΔ,
        Δ_lt_dead  = Δ_lt_dead,
        Δ_total    = Δ_total,
        # Checks
        checks     = checks,
        ok         = all_ok,
    )
end

# ==============================================================================
# Internal Helpers — Support-Dependent Moment & Deflection Coefficients
# ==============================================================================

"""Unfactored service moment for a uniformly loaded beam (w is force/length)."""
function _beam_moment(w, L::Length, support::Symbol)
    if support == :simply_supported
        return w * L^2 / 8
    elseif support == :cantilever
        return w * L^2 / 2
    elseif support == :one_end_continuous
        # Approximate: positive moment region
        return w * L^2 / 10
    elseif support == :both_ends_continuous
        return w * L^2 / 16
    else
        error("Unknown support condition: $support")
    end
end

"""Immediate deflection for a uniformly loaded beam (support-dependent coeff)."""
function _beam_deflection(w, L::Length, Ec::Pressure, Ie, support::Symbol)
    EI = Ec * Ie
    if support == :simply_supported
        return 5 * w * L^4 / (384 * EI)
    elseif support == :cantilever
        return w * L^4 / (8 * EI)
    elseif support == :one_end_continuous
        # Propped cantilever (approximate)
        return w * L^4 / (185 * EI)
    elseif support == :both_ends_continuous
        return w * L^4 / (384 * EI)
    else
        error("Unknown support condition: $support")
    end
end

# ==============================================================================
# T-Beam Deflection Check (ACI 318-11 §9.5.2)
# ==============================================================================

"""
    design_tbeam_deflection(bw, bf, hf, h, d, As, fc, fy, Es, L, w_dead, w_live;
                            support, wc_pcf, As_prime, ξ, limits) -> NamedTuple

Complete immediate + long-term deflection check for an RC T-beam.

Follows the same ACI §9.5.2 methodology as `design_beam_deflection` but uses:
- T-shaped gross section properties (Ig, ȳ from top)
- `cracked_moment_of_inertia_tbeam` for Icr (handles NA in flange or web)
- Cracking moment based on bottom-fiber distance (yb = h − ȳ)

# Arguments
- `bw`: Web width
- `bf`: Effective flange width
- `hf`: Flange (slab) thickness
- `h`: Total depth
- `d`: Effective depth (to centroid of tension steel)
- `As`: Tension steel area
- `fc`, `fy`, `Es`: Material properties
- `L`: Span length
- `w_dead`, `w_live`: Unfactored service loads (force/length)
- `support`: Support condition (default `:simply_supported`)
- `wc_pcf`: Concrete unit weight in pcf (default 150)
- `As_prime`: Compression steel area for long-term factor (default 0)
- `ξ`: Time-dependent factor (default 2.0)
- `limits`: Deflection limit types to check (default `[:immediate_ll, :total]`)

# Returns
Named tuple with Ec, fr, Ig, Icr, Mcr, Ie_D, Ie_DL, Δ_D, Δ_DL, Δ_LL,
λΔ, Δ_total, checks, ok — same structure as `design_beam_deflection`.
"""
function design_tbeam_deflection(
    bw::Length, bf::Length, hf::Length, h::Length, d::Length, As::Area,
    fc::Pressure, fy::Pressure, Es::Pressure,
    L::Length, w_dead, w_live;
    support::Symbol  = :simply_supported,
    wc_pcf::Union{Real, Nothing} = 150,
    As_prime::Area   = 0.0u"inch^2",
    ξ::Float64       = 2.0,
    limits::Vector{Symbol} = [:immediate_ll, :total]
)
    # --- Material properties ---
    Ec_val = wc_pcf === nothing ? Ec(fc) : Ec(fc, wc_pcf)
    fr_val = fr(fc)

    # --- Gross section (T-shape) ---
    Af = bf * hf
    Aw = bw * (h - hf)
    Ag = Af + Aw
    ȳ  = (Af * hf / 2 + Aw * (hf + (h - hf) / 2)) / Ag  # from top
    yb = h - ȳ  # bottom fiber distance

    Ig_f = bf * hf^3 / 12 + Af * (ȳ - hf / 2)^2
    Ig_w = bw * (h - hf)^3 / 12 + Aw * (hf + (h - hf) / 2 - ȳ)^2
    Ig   = Ig_f + Ig_w

    Mcr = fr_val * Ig / yb

    # --- Cracked section (T-shape) ---
    Icr = cracked_moment_of_inertia_tbeam(As, bw, bf, hf, d, Ec_val, Es)

    # --- Service moments ---
    Ma_dead  = _beam_moment(w_dead, L, support)
    Ma_live  = _beam_moment(w_live, L, support)
    Ma_total = Ma_dead + Ma_live

    # --- Effective moment of inertia ---
    Ie_D  = effective_moment_of_inertia(Mcr, Ma_dead,  Ig, Icr)
    Ie_DL = effective_moment_of_inertia(Mcr, Ma_total, Ig, Icr)

    # --- Immediate deflections ---
    Δ_D  = _beam_deflection(w_dead, L, Ec_val, Ie_D, support)
    Δ_DL = _beam_deflection(w_dead + w_live, L, Ec_val, Ie_DL, support)
    Δ_LL = Δ_DL - Δ_D

    # --- Long-term ---
    ρ_prime = ustrip(As_prime / (bw * d))
    λΔ = long_term_deflection_factor(ξ, ρ_prime)
    Δ_lt_dead = λΔ * Δ_D
    Δ_total   = Δ_lt_dead + Δ_LL

    # --- Limit checks ---
    checks = Dict{Symbol, NamedTuple}()
    for lim in limits
        Δ_allow = deflection_limit(L, lim)
        Δ_check = lim == :immediate_ll ? Δ_LL : Δ_total
        ok = Δ_check ≤ Δ_allow
        checks[lim] = (Δ=Δ_check, limit=Δ_allow, ok=ok,
                        ratio=ustrip(u"inch", Δ_check) / ustrip(u"inch", Δ_allow))
    end
    all_ok = all(c -> c.ok, values(checks))

    return (
        Ec = Ec_val, fr = fr_val,
        Ig = Ig, Icr = Icr, Mcr = Mcr,
        ȳ = ȳ, yb = yb,
        Ma_dead = Ma_dead, Ma_live = Ma_live, Ma_total = Ma_total,
        Ie_D = Ie_D, Ie_DL = Ie_DL,
        Δ_D = Δ_D, Δ_DL = Δ_DL, Δ_LL = Δ_LL,
        λΔ = λΔ, Δ_lt_dead = Δ_lt_dead, Δ_total = Δ_total,
        checks = checks, ok = all_ok,
    )
end

