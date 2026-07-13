# ==============================================================================
# Concrete Structural Wall — Out-of-Plane / Slender Wall (ACI 318-19 §11.8)
# ==============================================================================
# The out-of-plane sibling of the in-plane P–M checker (flexure.jl). Implements
# the ACI 318-19 "Alternative Method for Out-of-Plane Slender Wall Analysis"
# (§11.8) — the classic simply-supported, axially-loaded, laterally-loaded
# slender wall panel (tilt-up / precast bearing wall) with a single central
# layer of distributed vertical steel.
#
# The method is intrinsically SECOND-ORDER: the mid-height moment is amplified
# by the P-Δ effect through the cracked flexural stiffness, so the "demand"
# `Mu` and the section stiffness are coupled (unlike the demand-decoupled shear
# and in-plane P–M capacity checks). The whole analysis therefore lives behind a
# single checker that consumes the factored loads directly.
#
# Governing ACI 318-19 clauses (verified verbatim — see canon note w0000014,
# corpus: sp-de-tilt-up-wall-aci19; StructurePoint tilt-up panel, ACI 551.2R-15
# Example B.1):
#   - Applicability gates          §11.8.1.1(a)-(e), §11.8.2.1
#   - Ec = 57000·√f'c              §19.2.2.1(b)
#   - fr = 7.5·λ·√f'c              §19.2.3.1
#   - Mcr = fr·Ig/yt               §24.2.3.5
#   - Ase = As + (Pu/fy)(h/2d)     §R11.8.3.1  (effective steel for Icr)
#   - Icr = n·Ase·(d−c)² + b·c³/3   §11.8.3.1(c)
#   - Mu = Mua/(1 − Pum/(0.75·Kb)) §Eq. 11.8.3.1(d),  Kb = 48·Ec·Icr/(5·lc²)
#   - φMn = φ·Ase·fy·(d − a/2)      §11.5.1.1(b), §22.2  (tension-controlled)
#   - Service deflection Δs         Table 11.8.4.1, §11.8.4.3a  (≤ lc/150)
#
# APPLICABILITY IS A HARD SAFETY BOUNDARY. The §11.8 alternative method is only
# valid for a tension-controlled, lightly-axially-loaded (Pu ≤ 0.06·f'c·Ag),
# simply-supported wall whose design strength exceeds its cracking strength and
# whose service deflection stays under lc/150. If any gate fails the checker
# reports FAILURE (never a silent pass) — the wall must then be designed by a
# more general method (outside this module's scope).
#
# All quantities are per DESIGN STRIP of width `b` (the tributary width carrying
# one bay of load), NOT per full wall length — `As`, `Ig`, `Ag` are all
# per-strip. Bare-SI cores (Pa, m, N, N·m) mirror flexure.jl; a Unitful wrapper
# resolves materials and returns a CheckResult.

using Unitful

# psi → Pa (= _KSI_TO_PA/1000, with _KSI_TO_PA defined in flexure.jl).
const _PSI_TO_PA = _KSI_TO_PA / 1000.0

# ------------------------------------------------------------------------------
# Bare-SI strength + second-order analysis core
# ------------------------------------------------------------------------------

"""
    oop_slender_wall_strength_si(fc, fy, Es, b, h, d, lc, e, As, Pua, Pum, wu;
                                 λ=1.0, εcu=0.003) -> NamedTuple

Full ACI 318-19 §11.8 out-of-plane strength + second-order (P-Δ) analysis of a
slender wall design strip, in bare SI (`fc`,`fy`,`Es` in Pa; `b`,`h`,`d`,`lc`,`e`
in m; `As` in m²; `Pua`,`Pum` in N, compression positive; `wu` in N/m of height).

- `b`  design-strip width (tributary), `h` thickness, `d` effective depth to the
  tension steel, `lc` clear (unsupported) height, `e` eccentricity of the top
  axial load.
- `Pua` factored axial at the top (eccentric roof/floor reaction), `Pum` factored
  axial at mid-height (`Pua` + factored self-weight), `wu` factored out-of-plane
  line load along the height.

Returns the effective steel `Ase` (§R11.8.3.1), stress-block `a`/`c`, tension
strain `εt`, `φ`, nominal/ design flexural strength `Mn`/`φMn`, gross/cracked
inertia `Ig`/`Icr`, cracking moment `Mcr`, effective modulus `Ec`, buckling
stiffness term `Kb`, first-order moment `Mua`, magnified moment `Mu`, mid-height
ultimate deflection `Δu`, the magnification denominator, and a `stable` flag
(false when `Pum ≥ 0.75·Kb`, i.e. the P-Δ magnifier runs away).

Formulas per canon note w0000014 (corpus: sp-de-tilt-up-wall-aci19).
"""
function oop_slender_wall_strength_si(fc::Real, fy::Real, Es::Real,
                                      b::Real, h::Real, d::Real, lc::Real, e::Real,
                                      As::Real, Pua::Real, Pum::Real, wu::Real;
                                      λ::Real=1.0, εcu::Real=0.003)
    fc_psi = fc / _PSI_TO_PA
    β1  = _beta1_from_fc_psi(fc_psi)                       # Table 22.2.2.4.3
    Ec  = 57000.0 * sqrt(fc_psi) * _PSI_TO_PA              # §19.2.2.1(b)  [Pa]
    n   = Es / Ec

    # Effective flexural steel area for the cracked section (§R11.8.3.1).
    Ase = As + (Pum / fy) * (h / (2 * d))

    # Whitney block from the effective steel, neutral axis, tension strain.
    a   = Ase * fy / (0.85 * fc * b)
    c   = a / β1
    εt  = εcu * (d - c) / c
    εty = fy / Es
    tension_controlled = εt ≥ εty + 0.003
    φ   = wall_phi_flexure(εt, εty)                        # Table 21.2.2

    # Flexural strength (§11.5.1.1(b) / §22.2).
    Mn  = Ase * fy * (d - a / 2)
    φMn = φ * Mn

    # Section properties.
    Ig  = b * h^3 / 12
    yt  = h / 2
    fr  = 7.5 * λ * sqrt(fc_psi) * _PSI_TO_PA              # §19.2.3.1  [Pa]
    Mcr = fr * Ig / yt                                     # §24.2.3.5
    Icr = n * Ase * (d - c)^2 + b * c^3 / 3                # §11.8.3.1(c)

    # Second-order (P-Δ) moment magnification (§Eq. 11.8.3.1(d)).
    Kb  = 48 * Ec * Icr / (5 * lc^2)                       # [N], stiffness→force
    Mua = wu * lc^2 / 8 + Pua * e / 2                      # first-order (§11.8.3.1)
    denom = 1 - Pum / (0.75 * Kb)
    stable = denom > 0
    Mu  = stable ? Mua / denom : Inf                       # magnified mid-height moment
    Δu  = stable ? Mu / (0.75 * Kb) : Inf                  # §11.8.3.1(b)

    return (Ase = Ase, a = a, c = c, εt = εt, εty = εty,
            tension_controlled = tension_controlled, φ = φ,
            Mn = Mn, φMn = φMn, Ig = Ig, Icr = Icr, Mcr = Mcr, Ec = Ec,
            Kb = Kb, Mua = Mua, Mu = Mu, Δu = Δu, denom = denom, stable = stable)
end

# ------------------------------------------------------------------------------
# Service mid-height deflection — bilinear Ig→Icr (ACI Table 11.8.4.1)
# ------------------------------------------------------------------------------

"""
    oop_service_deflection_si(Msa, Ps, Mcr, Mn, Ec, Ig, Icr, lc;
                              maxiter=100, tol=1e-10) -> NamedTuple

Service out-of-plane mid-height deflection `Δs` (bare SI, m) by the bilinear
moment–deflection relation of ACI 318-19 Table 11.8.4.1, iterated for the P-Δ
coupling `Ma = Msa + Ps·Δs`.

- `Msa` first-order service moment at mid-height (`ws·lc²/8 + Pa·e/2`, N·m),
- `Ps` service axial at mid-height (N) driving the PΔ term,
- `Mcr`,`Mn` cracking / nominal moment (N·m), `Ec` (Pa), `Ig`,`Icr` (m⁴), `lc` (m).

    Δcr = 5·Mcr·lc²/(48·Ec·Ig)          (§11.8.4.3a)
    Δn  = 5·Mn ·lc²/(48·Ec·Icr)
    Ma ≤ (2/3)Mcr:  Δs = (Ma/Mcr)·Δcr
    else:           Δs = (2/3)Δcr + [(Ma−(2/3)Mcr)/(Mn−(2/3)Mcr)]·(Δn−(2/3)Δcr)

Returns `(Δs, Δcr, Δn, Ma, converged, iters)`.
"""
function oop_service_deflection_si(Msa::Real, Ps::Real, Mcr::Real, Mn::Real,
                                   Ec::Real, Ig::Real, Icr::Real, lc::Real;
                                   maxiter::Int=100, tol::Real=1e-10)
    Δcr = 5 * Mcr * lc^2 / (48 * Ec * Ig)
    Δn  = 5 * Mn  * lc^2 / (48 * Ec * Icr)
    twthird_Mcr = (2 / 3) * Mcr

    _defl(Ma) = Ma ≤ twthird_Mcr ? (Ma / Mcr) * Δcr :
                (2 / 3) * Δcr + (Ma - twthird_Mcr) / (Mn - twthird_Mcr) * (Δn - (2 / 3) * Δcr)

    Δs = _defl(Msa)                          # first pass ignores PΔ
    converged = false
    iters = 0
    for i in 1:maxiter
        iters = i
        Ma = Msa + Ps * Δs
        Δs_new = _defl(Ma)
        if abs(Δs_new - Δs) ≤ tol * max(abs(Δs_new), 1e-12)
            Δs = Δs_new
            converged = true
            break
        end
        Δs = Δs_new
    end
    Ma = Msa + Ps * Δs
    return (Δs = Δs, Δcr = Δcr, Δn = Δn, Ma = Ma, converged = converged, iters = iters)
end

# ------------------------------------------------------------------------------
# Applicability gates (§11.8.1.1 / §11.8.2.1)
# ------------------------------------------------------------------------------

"""
    oop_slender_wall_gates(str, fc, b, h, lc, Pum; Δs=nothing) -> NamedTuple

Evaluate the ACI 318-19 §11.8.1.1 applicability gates against a strength result
`str` (from `oop_slender_wall_strength_si`). Each gate is a `Bool`; `applicable`
is their conjunction (gate (e) only enforced when a service deflection `Δs` is
supplied). Returns the individual gates plus `applicable` and the axial-stress
limit values for reporting.

  (b) tension-controlled            §11.8.1.1(b)
  (c) φMn ≥ Mcr                      §11.8.1.1(c)
  (d) Pu ≤ 0.06·f'c·Ag              §11.8.1.1(d)
  (e) Δs ≤ lc/150                    §11.8.1.1(e)   (if `Δs` given)
  stable: Pum < 0.75·Kb (P-Δ magnifier does not run away)
"""
function oop_slender_wall_gates(str, fc::Real, b::Real, h::Real, lc::Real, Pum::Real;
                                Δs::Union{Nothing,Real}=nothing)
    Ag        = b * h
    σ_axial   = Pum / Ag
    σ_limit   = 0.06 * fc
    gate_b = str.tension_controlled
    gate_c = str.φMn ≥ str.Mcr
    gate_d = σ_axial ≤ σ_limit
    gate_e = Δs === nothing ? true : (Δs ≤ lc / 150)
    applicable = gate_b && gate_c && gate_d && gate_e && str.stable
    return (applicable = applicable, gate_b = gate_b, gate_c = gate_c,
            gate_d = gate_d, gate_e = gate_e, stable = str.stable,
            σ_axial = σ_axial, σ_limit = σ_limit)
end

# ------------------------------------------------------------------------------
# Demand-coupled CheckResult wrapper
# ------------------------------------------------------------------------------

"""
    check_wall_out_of_plane_slender(material, b, h, d, lc, e, As,
                                    Pua, Pum, wu;
                                    fy=nothing, Es=nothing, λ=1.0, εcu=0.003,
                                    ws=nothing, Pa=nothing, Ps=nothing) -> CheckResult

ACI 318-19 §11.8 out-of-plane slender-wall check for one design strip. Geometry
and loads are Unitful quantities or bare SI: `b`,`h`,`d`,`lc`,`e` lengths, `As`
an area, `Pua`/`Pum` forces (compression positive), `wu` a force-per-length
(line load along the height). `fy`/`Es` are required for a plain `Concrete` and
must be Unitful pressures (same safety guard as the in-plane P–M check).

The check runs the full second-order analysis, evaluates the §11.8.1.1
applicability gates, and returns a `CheckResult`:

- If the P-Δ magnifier is unstable (`Pum ≥ 0.75·Kb`) → FAIL, clause
  `"ACI 318-19 11.8.3.1"`.
- If a gate fails → FAIL, reporting the specific governing clause (the method is
  inapplicable, so this is a genuine failure, not a silent pass).
- Otherwise the strength check `φMn ≥ Mu` governs (ratio `Mu/φMn`), clause
  `"ACI 318-19 11.8"`.

Provide the service loads `ws` (service lateral line load), `Pa` (service axial
at top) and `Ps` (service axial at mid-height) to enforce gate (e), the
`Δs ≤ lc/150` serviceability limit; omit them to skip only that gate.
(corpus: sp-de-tilt-up-wall-aci19)
"""
function check_wall_out_of_plane_slender(material, b, h, d, lc, e, As,
                                         Pua, Pum, wu;
                                         fy=nothing, Es=nothing, λ::Real=1.0,
                                         εcu::Real=0.003,
                                         ws=nothing, Pa=nothing, Ps=nothing)
    fc, fyP, EsP = _wall_flexure_materials(material; fy=fy, Es=Es)
    bm  = _oop_len(b);  hm = _oop_len(h);  dm = _oop_len(d)
    lcm = _oop_len(lc); em = _oop_len(e)
    As_m2 = As isa Unitful.Quantity ? ustrip(u"m^2", As) : Float64(As)
    Pua_N = _oop_force(Pua); Pum_N = _oop_force(Pum)
    wu_N  = wu isa Unitful.Quantity ? ustrip(u"N/m", wu) : Float64(wu)

    str = oop_slender_wall_strength_si(fc, fyP, EsP, bm, hm, dm, lcm, em, As_m2,
                                       Pua_N, Pum_N, wu_N; λ=λ, εcu=εcu)

    # Instability of the P-Δ magnifier (Pum ≥ 0.75·Kb): no meaningful capacity.
    if !str.stable
        return CheckResult("out-of-plane slender wall: P-Δ instability", false,
                           Inf, Pum_N, 0.75 * str.Kb, "ACI 318-19 11.8.3.1")
    end

    # Service deflection (gate e), only if service loads are supplied.
    Δs = nothing
    if ws !== nothing && Pa !== nothing && Ps !== nothing
        ws_N = ws isa Unitful.Quantity ? ustrip(u"N/m", ws) : Float64(ws)
        Pa_N = _oop_force(Pa); Ps_N = _oop_force(Ps)
        Msa  = ws_N * lcm^2 / 8 + Pa_N * em / 2
        svc  = oop_service_deflection_si(Msa, Ps_N, str.Mcr, str.Mn,
                                         str.Ec, str.Ig, str.Icr, lcm)
        Δs = svc.Δs
    end

    gates = oop_slender_wall_gates(str, fc, bm, hm, lcm, Pum_N; Δs=Δs)

    # Applicability failures — report the governing clause (method inapplicable).
    if !gates.gate_b
        return CheckResult("out-of-plane slender wall: not tension-controlled", false,
                           (str.εty + 0.003) / max(str.εt, 1e-12), str.εt,
                           str.εty + 0.003, "ACI 318-19 11.8.1.1(b)")
    elseif !gates.gate_c
        return CheckResult("out-of-plane slender wall: φMn < Mcr", false,
                           str.Mcr / max(str.φMn, 1e-9), str.Mcr, str.φMn,
                           "ACI 318-19 11.8.1.1(c)")
    elseif !gates.gate_d
        return CheckResult("out-of-plane slender wall: axial stress > 0.06f'c", false,
                           gates.σ_axial / max(gates.σ_limit, 1e-9),
                           gates.σ_axial, gates.σ_limit, "ACI 318-19 11.8.1.1(d)")
    elseif !gates.gate_e
        return CheckResult("out-of-plane slender wall: service deflection > lc/150", false,
                           Δs / (lcm / 150), Δs, lcm / 150, "ACI 318-19 11.8.1.1(e)")
    end

    # Strength check: φMn ≥ Mu (second-order).
    ratio = str.Mu / max(str.φMn, 1e-9)
    return CheckResult("out-of-plane slender wall (P-Δ)", ratio ≤ 1.0, ratio,
                       str.Mu, str.φMn, "ACI 318-19 11.8")
end

# Length/force coercion helpers (Unitful quantity or bare SI number → SI Float).
_oop_len(x)   = x isa Unitful.Quantity ? ustrip(u"m", x) : Float64(x)
_oop_force(x) = x isa Unitful.Quantity ? ustrip(u"N", x) : Float64(x)
