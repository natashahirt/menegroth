# ==============================================================================
# AISC Design Guide 9 — Torsion for Doubly-Symmetric I-Shapes (W-shapes)
# ==============================================================================
#
# All internal calculations are performed in raw kip/inch units to avoid
# Unitful overflow when mixing ksi with GPa unit systems.
#
# Stresses computed:
#   - Pure (St. Venant) torsional shear: τ_t = G·t·θ'     (Eq. 4.1)
#   - Warping shear stress:  τ_ws = E·Sw·|θ'''| / t        (Eq. 4.2a)
#   - Warping normal stress: σ_w  = E·Wno·θ''              (Eq. 4.3a)
#
# Design checks (LRFD, §4.7.1):
#   - Normal stress yielding: |σ_b| + |σ_w| ≤ φ·Fy        (Eq. 4.12)
#   - Shear stress yielding:  τ_b + τ_t + τ_ws ≤ φ·0.6·Fy (Eq. 4.13)
#   - Interaction: (fun/(φFy))² + (fuv/(φ·0.6Fy))² ≤ 1.0  (Eq. 4.16a)
#
# Reference: AISC Design Guide 9, Example 5.1 (W10x49)
# ==============================================================================

# ==============================================================================
# DG9 Torsional Properties for I-Shapes
# ==============================================================================

"""
    dg9_Wno(s::ISymmSection) -> Area

Normalized warping function at flange tips for doubly-symmetric I-shapes.

    Wno = bf · ho / 4

# Reference
- DG9 Appendix C, Eq. C.13
- W10x49: Wno = 10.0 × 9.44 / 4 = 23.6 in²
"""
dg9_Wno(s::ISymmSection) = s.bf * s.ho / 4

"""
    dg9_Sw1(s::ISymmSection) -> SecondMomentOfArea

Warping statical moment at the web-flange junction for doubly-symmetric I-shapes.

    Sw1 = tf · bf² · ho / 16

# Reference
- DG9 Appendix C
- W10x49: Sw1 = 0.56 × 100 × 9.44 / 16 = 33.0 in⁴
"""
dg9_Sw1(s::ISymmSection) = s.tf * s.bf^2 * s.ho / 16

"""
    dg9_torsional_parameter(s::ISymmSection, mat::Metal) -> Length

Torsional parameter 'a' for open sections:

    a = √(E·Cw / (G·J))

# Reference
- DG9 Eq. 3.4
"""
function dg9_torsional_parameter(s::ISymmSection, mat::Metal)
    return sqrt(mat.E * s.Cw / (mat.G * s.J))
end

# ==============================================================================
# Internal helpers — kip/inch arithmetic (avoids Unitful overflow)
# ==============================================================================

"""
    Warping constant in in⁶.

Catalogue shapes store `Cw` in m⁶. A plate girder from the beam NLP stores it
in in⁶. Either `ustrip` across that pair overflows `Int64`: the rational
inch factor raised to the sixth power does not fit. Branch on the unit and
scale with the float inch factor.
"""
function _cw_inches6(cw)::Float64
    cw isa Real && return Float64(cw)
    u = unit(cw)
    val = Float64(ustrip(cw))
    if u == u"inch^6"
        return val
    elseif u == u"m^6"
        return val / Asap.IN6_TO_M6
    else
        error("Cw must be in inch^6 or m^6, got $u")
    end
end

"""Extract torsion-relevant section properties as raw numbers in inch units."""
function _torsion_props_in(s::ISymmSection)
    d_in   = ustrip(u"inch", s.d)
    bf_in  = ustrip(u"inch", s.bf)
    tw_in  = ustrip(u"inch", s.tw)
    tf_in  = ustrip(u"inch", s.tf)
    ho_in  = ustrip(u"inch", s.ho)
    J_in4  = ustrip(u"inch^4", s.J)
    Cw_in6 = _cw_inches6(s.Cw)
    Ix_in4 = ustrip(u"inch^4", s.Ix)
    Sx_in3 = ustrip(u"inch^3", s.Sx)
    Wno_in2 = bf_in * ho_in / 4
    Sw1_in4 = tf_in * bf_in^2 * ho_in / 16
    return (d=d_in, bf=bf_in, tw=tw_in, tf=tf_in, ho=ho_in,
            J=J_in4, Cw=Cw_in6, Ix=Ix_in4, Sx=Sx_in3,
            Wno=Wno_in2, Sw1=Sw1_in4)
end

# ==============================================================================
# Torsional Functions — Loading Cases (DG9 Appendix B)
# ==============================================================================

"""
    torsion_case3_derivatives(z_in, L_in, T_kipin, a_in, G_ksi, J_in4)

θ and its derivatives for concentrated torque T at midspan, pinned-pinned.
ALL arguments are raw numbers in kip/inch units.

Returns (θ, θp, θpp, θppp) — rad, rad/in, rad/in², rad/in³.
"""
function torsion_case3_derivatives(z_in::Real, L_in::Real, T_kipin::Real,
                                    a_in::Real, G_ksi::Real, J_in4::Real)
    α = L_in / (2 * a_in)
    ζ = z_in / a_in
    GJ = G_ksi * J_in4  # kip·in²
    half_TGJ = T_kipin / (2 * GJ)  # 1/in

    cosh_α = cosh(α)

    if z_in ≤ L_in / 2
        sinh_ζ = sinh(ζ)
        cosh_ζ = cosh(ζ)

        θ    = half_TGJ * (z_in - a_in * sinh_ζ / cosh_α)  # rad
        θp   = half_TGJ * (1.0 - cosh_ζ / cosh_α)          # rad/in
        θpp  = -half_TGJ / a_in * (sinh_ζ / cosh_α)         # rad/in²
        θppp = -half_TGJ / a_in^2 * (cosh_ζ / cosh_α)       # rad/in³
    else
        z2 = L_in - z_in
        ζ2 = z2 / a_in
        sinh_ζ2 = sinh(ζ2)
        cosh_ζ2 = cosh(ζ2)

        θ    = half_TGJ * (z2 - a_in * sinh_ζ2 / cosh_α)
        θp   = -(half_TGJ * (1.0 - cosh_ζ2 / cosh_α))
        θpp  = half_TGJ / a_in * (sinh_ζ2 / cosh_α)
        θppp = -half_TGJ / a_in^2 * (cosh_ζ2 / cosh_α)
    end

    return (θ=θ, θp=θp, θpp=θpp, θppp=θppp)
end

"""
    torsion_case1_derivatives(z_in, L_in, t_kipin_per_in, a_in, G_ksi, J_in4)

θ and derivatives for uniform torque, pinned-pinned.
t_kipin_per_in = distributed torque (kip·in per inch of span).
"""
function torsion_case1_derivatives(z_in::Real, L_in::Real, t_kipin_per_in::Real,
                                    a_in::Real, G_ksi::Real, J_in4::Real)
    GJ = G_ksi * J_in4
    tGJ = t_kipin_per_in / GJ
    α = L_in / (2 * a_in)
    ζ = z_in / a_in
    cosh_α = cosh(α)

    cosh_shifted = cosh(ζ - α)

    θ    = tGJ * (z_in * (L_in - z_in) / 2 + a_in^2 * (cosh_shifted / cosh_α - 1))
    θp   = tGJ * ((L_in - 2*z_in) / 2 + a_in * sinh(ζ - α) / cosh_α)
    θpp  = tGJ * (-1.0 + cosh_shifted / cosh_α)
    θppp = tGJ / a_in * sinh(ζ - α) / cosh_α

    return (θ=θ, θp=θp, θpp=θpp, θppp=θppp)
end

# ==============================================================================
# Torsional Stress Calculations (raw kip/inch)
# ==============================================================================

"""
    torsional_stresses_ksi(E_ksi, G_ksi, tf_in, tw_in, d_in, Ix_in4, Wno_in2, Sw1_in4,
                           θp, θpp, θppp; Vu_kip=0.0) -> NamedTuple

Compute torsional stresses (all in ksi).
"""
function torsional_stresses_ksi(E_ksi::Real, G_ksi::Real,
                                 tf_in::Real, tw_in::Real, d_in::Real, Ix_in4::Real,
                                 Wno_in2::Real, Sw1_in4::Real,
                                 θp::Real, θpp::Real, θppp::Real;
                                 Vu_kip::Real=0.0)
    # Pure torsional shear (Eq. 4.1): τ_t = G·t·|θ'|
    τ_t_flange = G_ksi * tf_in * abs(θp)    # ksi
    τ_t_web    = G_ksi * tw_in * abs(θp)

    # Warping normal stress (Eq. 4.3a): σ_w = E·Wno·θ''
    σ_w = E_ksi * Wno_in2 * θpp              # ksi

    # Warping shear stress (Eq. 4.2a): τ_ws = E·Sw1·|θ'''| / tf
    τ_ws = E_ksi * Sw1_in4 * abs(θppp) / tf_in  # ksi

    # Flexural shear stress in web (approximate): τ_b ≈ V / (d·tw)
    τ_b_web = abs(Vu_kip) / (d_in * tw_in)   # ksi

    return (τ_t_flange=τ_t_flange, τ_t_web=τ_t_web,
            σ_w=σ_w, τ_ws=τ_ws, τ_b_web=τ_b_web)
end

# ==============================================================================
# Design Checks (DG9 §4.7.1 — LRFD)
# ==============================================================================

"""
    check_torsion_yielding(σ_b_ksi, σ_w_ksi, τ_b_ksi, τ_t_ksi, τ_ws_ksi, Fy_ksi;
                           φ=0.90) -> NamedTuple

Check yielding under combined bending + torsion per DG9 §4.7.1 (LRFD).
All arguments in ksi (raw numbers).

Returns named tuple with all check results.
"""
function check_torsion_yielding(σ_b_ksi::Real, σ_w_ksi::Real,
                                 τ_b_ksi::Real, τ_t_ksi::Real, τ_ws_ksi::Real,
                                 Fy_ksi::Real; φ::Real=0.90)
    f_un = abs(σ_b_ksi) + abs(σ_w_ksi)
    f_uv = abs(τ_b_ksi) + abs(τ_t_ksi) + abs(τ_ws_ksi)

    φFy = φ * Fy_ksi
    φFvy = φ * 0.6 * Fy_ksi

    normal_ok = f_un ≤ φFy
    shear_ok  = f_uv ≤ φFvy

    ir = (f_un / φFy)^2 + (f_uv / φFvy)^2
    interaction_ok = ir ≤ 1.0

    return (f_un=f_un, f_uv=f_uv, φFy=φFy, φFvy=φFvy,
            normal_ok=normal_ok, shear_ok=shear_ok,
            interaction_ratio=ir, interaction_ok=interaction_ok,
            ok=normal_ok && shear_ok && interaction_ok)
end

# Unitful convenience wrapper (converts to ksi via Asap, calls raw version)
function check_torsion_yielding(σ_b::Pressure, σ_w::Pressure,
                                 τ_b::Pressure, τ_t::Pressure, τ_ws::Pressure,
                                 Fy::Pressure; φ::Real=0.90)
    result = check_torsion_yielding(
        to_ksi(σ_b), to_ksi(σ_w),
        to_ksi(τ_b), to_ksi(τ_t), to_ksi(τ_ws),
        to_ksi(Fy); φ=φ)
    _ksi = Asap.ksi
    return (f_un = result.f_un * _ksi,
            f_uv = result.f_uv * _ksi,
            φFy  = result.φFy * _ksi,
            φFvy = result.φFvy * _ksi,
            normal_ok = result.normal_ok,
            shear_ok  = result.shear_ok,
            interaction_ratio = result.interaction_ratio,
            interaction_ok = result.interaction_ok,
            ok = result.ok)
end

# ==============================================================================
# Full Torsion Design for W-Shapes
# ==============================================================================

"""
    design_w_torsion(s::ISymmSection, mat::Metal, Tu, Vu, Mu, L;
                     load_type=:concentrated_midspan) -> NamedTuple

Complete torsion design check for a W-shape beam per AISC Design Guide 9.

All stresses in the returned result are in ksi (Float64, raw numbers).

# Arguments
- `s`: W-shape section
- `mat`: Steel material
- `Tu`: Factored torsional moment (Unitful)
- `Vu`: Factored shear (Unitful)
- `Mu`: Factored flexural moment (Unitful)
- `L`: Span length (Unitful)

# Keyword Arguments
- `load_type`: `:concentrated_midspan` (DG9 Case 3) or `:uniform` (DG9 Case 1)
"""
function design_w_torsion(
    s::ISymmSection, mat::Metal,
    Tu, Vu, Mu, L;
    load_type::Symbol = :concentrated_midspan,
)
    # ---- Strip to kip/inch ----
    Tu_kipin = abs(to_kipft(Tu) * 12.0)  # kip·ft → kip·in
    Vu_kip   = abs(to_kip(Vu))
    Mu_kipin = abs(to_kipft(Mu) * 12.0)
    L_in     = to_inches(L)

    E_ksi = to_ksi(mat.E)
    Fy_ksi = to_ksi(mat.Fy)
    G_ksi = to_ksi(mat.G)

    p = _torsion_props_in(s)  # all inch-based
    a_in = sqrt(E_ksi * p.Cw / (G_ksi * p.J))

    # ---- Torsional derivatives at critical locations ----
    if load_type == :concentrated_midspan
        d_mid = torsion_case3_derivatives(L_in/2, L_in, Tu_kipin, a_in, G_ksi, p.J)
        d_sup = torsion_case3_derivatives(0.0, L_in, Tu_kipin, a_in, G_ksi, p.J)
    elseif load_type == :uniform
        t_per_in = Tu_kipin / L_in
        d_mid = torsion_case1_derivatives(L_in/2, L_in, t_per_in, a_in, G_ksi, p.J)
        d_sup = torsion_case1_derivatives(0.0, L_in, t_per_in, a_in, G_ksi, p.J)
    else
        error("Unsupported load_type: $load_type")
    end

    # ---- Bending stress ----
    σ_b_ksi = Mu_kipin / p.Sx   # ksi

    # ---- Stresses at midspan ----
    s_mid = torsional_stresses_ksi(E_ksi, G_ksi, p.tf, p.tw, p.d, p.Ix,
                                    p.Wno, p.Sw1, d_mid.θp, d_mid.θpp, d_mid.θppp)

    # ---- Stresses at support ----
    s_sup = torsional_stresses_ksi(E_ksi, G_ksi, p.tf, p.tw, p.d, p.Ix,
                                    p.Wno, p.Sw1, d_sup.θp, d_sup.θpp, d_sup.θppp;
                                    Vu_kip=Vu_kip)

    # ---- Combined stresses ----
    f_un_mid = abs(σ_b_ksi) + abs(s_mid.σ_w)
    f_uv_mid = s_mid.τ_t_flange + s_mid.τ_ws

    f_un_sup = abs(s_sup.σ_w)
    f_uv_sup = s_sup.τ_b_web + s_sup.τ_t_flange + s_sup.τ_ws

    # ---- Design checks ----
    chk_mid = check_torsion_yielding(σ_b_ksi, s_mid.σ_w, 0.0,
                                      s_mid.τ_t_flange, s_mid.τ_ws, Fy_ksi)
    chk_sup = check_torsion_yielding(0.0, s_sup.σ_w, s_sup.τ_b_web,
                                      s_sup.τ_t_flange, s_sup.τ_ws, Fy_ksi)

    return (
        # Properties (raw numbers, inch-based)
        a_in = a_in,
        Wno_in2 = p.Wno,
        Sw1_in4 = p.Sw1,
        # Stresses at midspan (ksi)
        σ_b_ksi = σ_b_ksi,
        σ_w_midspan_ksi = s_mid.σ_w,
        τ_t_midspan_ksi = s_mid.τ_t_flange,
        τ_ws_midspan_ksi = s_mid.τ_ws,
        f_un_midspan_ksi = f_un_mid,
        f_uv_midspan_ksi = f_uv_mid,
        # Stresses at support (ksi)
        σ_w_support_ksi = s_sup.σ_w,
        τ_t_support_ksi = s_sup.τ_t_flange,
        τ_ws_support_ksi = s_sup.τ_ws,
        τ_b_support_ksi = s_sup.τ_b_web,
        f_un_support_ksi = f_un_sup,
        f_uv_support_ksi = f_uv_sup,
        # Design checks
        check_midspan = chk_mid,
        check_support = chk_sup,
        ok = chk_mid.ok && chk_sup.ok,
        # Rotation at midspan (rad, dimensionless)
        θ_max_rad = d_mid.θ,
    )
end

