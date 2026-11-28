# Rib deflection from a grillage frame.
#
# ACI 318-11 §9.5.2.2 (corpus: aci-318-11, PDF page 131) takes immediate
# deflection from an elastic analysis that includes cracking. The grillage
# frame is that analysis. It is solved at one inertia, `Ie_frame`. §9.5.2.3
# Eq. (9-8) is the service inertia at each load level, and the frame
# deflection scales by `Ie_frame / Ie`. §9.5.2.5 Eq. (9-11) (PDF page 132)
# multiplies the sustained-load deflection by λΔ. The limits are Table 9.5(b)
# (PDF page 133), the same limits the beam checker uses.
#
# The strength-model factor on gross inertia is not a service stiffness and
# is not an argument here.

"""
    scale_rib_deflection(Δ_D, Δ_S, Δ_DL, Ie_frame, Ie_D, Ie_S, Ie_DL, L;
                         ξ, ρ_prime, limits) -> NamedTuple

Service deflection of one rib from its grillage-frame deflections.

`Δ_D`, `Δ_S`, and `Δ_DL` are downward deflections of the rib, solved at
`Ie_frame`, for dead load, for the sustained load, and for dead plus live.
`Ie_D`, `Ie_S`, and `Ie_DL` are Eq. (9-8) at those three load levels.
Immediate live deflection is `Δ_DL − Δ_D`. The long-term total is
`λΔ Δ_S + (Δ_DL − Δ_S)`.
"""
function scale_rib_deflection(Δ_D::Length, Δ_S::Length, Δ_DL::Length,
                              Ie_frame, Ie_D, Ie_S, Ie_DL, L::Length;
                              ξ::Real = 2.0, ρ_prime::Real = 0.0,
                              limits::AbstractVector{Symbol} = [:immediate_ll, :total])
    for (name, Δ) in (("dead", Δ_D), ("sustained", Δ_S), ("dead plus live", Δ_DL))
        Δ >= zero(Δ) || throw(ArgumentError(
            "the $name deflection is downward and not negative, got $Δ"))
    end
    L > zero(L) || throw(ArgumentError("the rib span is positive, got $L"))
    ξ >= 0 || throw(ArgumentError("the long-term factor ξ is not negative, got $ξ"))
    ρ_prime >= 0 || throw(ArgumentError(
        "the compression reinforcement ratio is not negative, got $ρ_prime"))
    for (name, Ie) in (("frame", Ie_frame), ("dead", Ie_D),
                       ("sustained", Ie_S), ("dead plus live", Ie_DL))
        ustrip(u"m^4", Ie) > 0 || throw(ArgumentError(
            "the $name inertia is positive, got $Ie"))
    end
    for lim in limits
        lim in (:immediate_ll, :total, :sensitive) || throw(ArgumentError(
            "a rib deflection limit is :immediate_ll, :total, or :sensitive, got :$lim"))
    end
    ΔD = Δ_D * Ie_frame / Ie_D
    ΔS = Δ_S * Ie_frame / Ie_S
    ΔDL = Δ_DL * Ie_frame / Ie_DL
    ΔLL = ΔDL - ΔD
    λΔ = long_term_deflection_factor(Float64(ξ), Float64(ρ_prime))
    Δ_total = λΔ * ΔS + (ΔDL - ΔS)
    checks = Dict{Symbol, NamedTuple}()
    worst = 0.0
    for lim in limits
        allow = deflection_limit(L, lim)
        Δ = lim == :immediate_ll ? ΔLL : Δ_total
        r = ustrip(u"m", Δ) / ustrip(u"m", allow)
        worst = max(worst, r)
        checks[lim] = (Δ = Δ, limit = allow, ok = r <= 1, ratio = r)
    end
    return (
        Δ_D = ΔD, Δ_S = ΔS, Δ_DL = ΔDL, Δ_LL = ΔLL,
        λΔ = λΔ, Δ_total = Δ_total,
        checks = checks, ratio = worst, ok = worst <= 1,
    )
end
