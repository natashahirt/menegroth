# ==============================================================================
# RC beam deflection on a cracked story shell
# ==============================================================================
#
# ACI 318-11 §9.5.2.2 (corpus: aci-318-11, PDF p. 131): immediate deflection
# "by usual methods or formulas for elastic deflections, considering effects of
# cracking and reinforcement on member stiffness". The story shell is that
# elastic method. Each span of an RC beam is the T-section its web forms with
# the slab, and the span is softened by Ie/Ig:
#   • Ie is Eq. (9-8) of §9.5.2.3 (PDF p. 132) with Ma the span's largest
#     service moment, not greater than Ig.
#   • A continuous span averages its positive and negative sections (§9.5.2.4);
#     a cantilever takes its support section.
#   • Long-term deflection is §9.5.2.5, Eq. (9-11) (PDF p. 132). Limits are
#     Table 9.5(b) (PDF p. 133).
# ==============================================================================

"""
    RCShellSpan

One span of an RC beam solved on the cracked story shell. SI units: m, N·m, Pa.

`bf` and `hf` are the flange the shell gave the web: the slab strip width at
midspan and the slab thickness. `Ma_*_pos` is the largest sagging service
moment in the span. `Ma_*_neg` holds the hogging service moment at each
continuous end, or at the support of a cantilever. `D` is dead load, `S` is
the sustained load (dead plus a share of live, R9.5.2.5), and `DL` is dead
plus all of the live load. `Δ_*` are the span's deflections from the shell,
solved with inertias `Ie_*`. With no sustained live load, `S` equals `D`.
`Mu_neg` is the factored hogging moment that sizes the top bars of the
negative section.
"""
struct RCShellSpan
    L::Float64
    bf::Float64
    hf::Float64
    cantilever::Bool
    Ma_D_pos::Float64
    Ma_S_pos::Float64
    Ma_DL_pos::Float64
    Ma_D_neg::Vector{Float64}
    Ma_S_neg::Vector{Float64}
    Ma_DL_neg::Vector{Float64}
    Mu_neg::Float64
    Δ_D::Float64
    Δ_S::Float64
    Δ_DL::Float64
    Ie_D::Float64
    Ie_S::Float64
    Ie_DL::Float64
    Ec::Float64
    Es::Float64
    fr::Float64
    fc::Float64
    fy::Float64
end

"""`S` defaults to `D`: no share of live load is sustained."""
function RCShellSpan(;
    L, bf, hf, cantilever = false,
    Ma_D_pos, Ma_DL_pos, Ma_S_pos = Ma_D_pos,
    Ma_D_neg = Float64[], Ma_DL_neg = Float64[], Ma_S_neg = Ma_D_neg,
    Mu_neg = 0.0,
    Δ_D, Δ_DL, Δ_S = Δ_D,
    Ie_D, Ie_DL, Ie_S = Ie_D,
    Ec, Es, fr, fc, fy,
)
    return RCShellSpan(Float64(L), Float64(bf), Float64(hf), cantilever,
                       Float64(Ma_D_pos), Float64(Ma_S_pos), Float64(Ma_DL_pos),
                       collect(Float64, Ma_D_neg), collect(Float64, Ma_S_neg),
                       collect(Float64, Ma_DL_neg), Float64(Mu_neg),
                       Float64(Δ_D), Float64(Δ_S), Float64(Δ_DL),
                       Float64(Ie_D), Float64(Ie_S), Float64(Ie_DL),
                       Float64(Ec), Float64(Es), Float64(fr), Float64(fc), Float64(fy))
end

"""Web width and the web depth below the slab soffit, as the story shell hangs it."""
_shell_web(s::RCBeamSection)  = (bw = s.b,  hw = s.h)
_shell_web(s::RCTBeamSection) = (bw = s.bw, hw = s.h - s.hf)

"""
Top bars for the negative section: the arrangement `required_top_steel` picks
for `Mu_neg` (N·m), as `(As, d_top)` with `d_top` measured from the bottom face.

# ENGINEERING JUDGMENT
When no arrangement carries `Mu_neg` the strongest one is used. That section
fails its hogging strength check anyway; this only keeps the stiffness finite.
"""
function _shell_top_steel(section, Mu_neg::Real, fc::Real, fy::Real)
    pick = required_top_steel(section, Mu_neg * u"N*m"; fc = fc * u"Pa", fy = fy * u"Pa")
    if pick === nothing
        cands = _each_top_steel_candidate(section, ustrip(u"psi", fc * u"Pa"),
                                          ustrip(u"psi", fy * u"Pa"))
        isempty(cands) && return nothing
        pick = cands[argmax([c.φMn for c in cands])]
    end
    return (As = pick.As * u"inch^2", d_top = pick.d_top * u"inch")
end

"""
    continuous_span_inertia(Ie_m, Ie_ends) -> Ie

ACI 318-11 §9.5.2.4 (corpus: aci-318-11, PDF p. 132): for a continuous member
`Ie` may be "the average of values obtained from Eq. (9-8) for the critical
positive and negative moment sections". `Ie_m` is the positive section and
`Ie_ends` the negative section at each continuous end.

# ENGINEERING JUDGMENT
§9.5.2.4 does not weight two negative sections. The positive section takes
half and the supports share the other half: `½ Ie_m + ¼ (Ie_1 + Ie_2)`. One
continuous end gives `½ (Ie_m + Ie_1)`.
"""
function continuous_span_inertia(Ie_m, Ie_ends::AbstractVector)
    n = length(Ie_ends)
    n == 0 && return Ie_m
    n == 1 && return (Ie_m + Ie_ends[1]) / 2
    n == 2 && return Ie_m / 2 + (Ie_ends[1] + Ie_ends[2]) / 4
    throw(ArgumentError("a span has at most two continuous ends; got $n"))
end

"""
    rc_span_inertia(section, bf, hf, Ma_pos, Ma_neg, Mu_neg;
                    Ec, Es, fr, fc, fy, cantilever=false) -> (Ig, Ie)

Gross and effective inertia (m⁴) of one RC span as the story shell builds it:
the web of `section` hung below a slab `hf` thick, with a flange `bf` wide.
Moments are N·m, `bf` and `hf` metres, moduli and strengths Pa. `fr` already
carries `λ` (Eq. 9-10).

- Sagging: `Icr` of the T with the bottom bars (`cracked_moment_of_inertia_tbeam`).
- Hogging: the compression is the web bottom, width `bw`, and the tension
  steel is the top-bar arrangement for `Mu_neg` (`cracked_moment_of_inertia`).
- `Mcr = fr Ig / yt`, Eq. (9-9), `yt` from the centroid to the tension face.
- `Ie` is Eq. (9-8) at each section (§9.5.2.3), combined by
  [`continuous_span_inertia`](@ref). A cantilever uses its support (§9.5.2.4).
"""
function rc_span_inertia(section::Union{RCBeamSection, RCTBeamSection},
                         bf::Real, hf::Real, Ma_pos::Real, Ma_neg::AbstractVector, Mu_neg::Real;
                         Ec::Real, Es::Real, fr::Real, fc::Real, fy::Real,
                         cantilever::Bool = false)
    web = _shell_web(section)
    bw = uconvert(u"m", web.bw)
    hw = uconvert(u"m", web.hw)
    hw > zero(hw) || throw(ArgumentError("the web must hang below the slab"))
    hf_m = hf * u"m"
    bf_m = max(bf * u"m", bw)
    h = hf_m + hw
    Ig, ȳ = tbeam_gross_inertia(bw, bf_m, hf_m, h)
    Ig = uconvert(u"m^4", Ig)
    Ecq, Esq, frq = Ec * u"Pa", Es * u"Pa", fr * u"Pa"

    # Bottom bars keep their height above the bottom face.
    d_pos = h - (uconvert(u"m", section.h) - uconvert(u"m", section.d))
    Icr_pos = uconvert(u"m^4", cracked_moment_of_inertia_tbeam(section.As, bw, bf_m, hf_m,
                                                               d_pos, Ecq, Esq))
    Mcr_pos = frq * Ig / (h - ȳ)
    Ie_m = effective_moment_of_inertia(Mcr_pos, Ma_pos * u"N*m", Ig, Icr_pos)

    Ie_ends = typeof(Ie_m)[]
    if !isempty(Ma_neg)
        top = _shell_top_steel(section, Mu_neg, fc, fy)
        Icr_neg = top === nothing ? zero(Ig) :
            uconvert(u"m^4", cracked_moment_of_inertia(top.As, bw, top.d_top, Ecq, Esq))
        Mcr_neg = frq * Ig / ȳ
        for M in Ma_neg
            push!(Ie_ends, effective_moment_of_inertia(Mcr_neg, M * u"N*m", Ig, Icr_neg))
        end
    end

    Ie = if cantilever
        isempty(Ie_ends) && throw(ArgumentError("a cantilever span needs its support moment"))
        Ie_ends[1]
    else
        continuous_span_inertia(Ie_m, Ie_ends)
    end
    return (Ig = ustrip(u"m^4", Ig), Ie = ustrip(u"m^4", uconvert(u"m^4", Ie)))
end

"""
    rc_shell_span_deflection(span, section; ξ=2.0, limits=[:immediate_ll, :total])
        -> NamedTuple

Deflection of `span` with `section` in place of the section the shell solved.

Each shell deflection scales by the ratio of inertias: `Δ = Δ_shell ·
Ie_shell / Ie(section)`, at dead, at the sustained load, and at dead plus
live. The immediate live deflection is `Δ_DL − Δ_D` (Table 9.5(b)). The
long-term total is `λΔ Δ_S + (Δ_DL − Δ_S)`: Eq. (9-11) multiplies the
immediate deflection caused by the sustained load (R9.5.2.5). Limits are
[`deflection_limit`](@ref) over the span length.

With the solved section the ratio is one, so the result is the shell's own.

# ENGINEERING JUDGMENT
- The ratio holds the span's share of load fixed. A stiffer section draws
  more load in the shell, so the scaled value flatters an upsized candidate.
  The story-shell loop re-solves until sections stop changing, and the final
  section is then checked at ratio one.
- `ρ′` is taken as zero for a cantilever: §9.5.2.5 wants it at the support,
  where the compression bars are not tracked.
"""
function rc_shell_span_deflection(sp::RCShellSpan, section::Union{RCBeamSection, RCTBeamSection};
                                  ξ::Real = 2.0,
                                  limits::AbstractVector{Symbol} = [:immediate_ll, :total])
    kw = (; Ec = sp.Ec, Es = sp.Es, fr = sp.fr, fc = sp.fc, fy = sp.fy, cantilever = sp.cantilever)
    Ie_D  = rc_span_inertia(section, sp.bf, sp.hf, sp.Ma_D_pos,  sp.Ma_D_neg,  sp.Mu_neg; kw...).Ie
    Ie_S  = rc_span_inertia(section, sp.bf, sp.hf, sp.Ma_S_pos,  sp.Ma_S_neg,  sp.Mu_neg; kw...).Ie
    Ie_DL = rc_span_inertia(section, sp.bf, sp.hf, sp.Ma_DL_pos, sp.Ma_DL_neg, sp.Mu_neg; kw...).Ie
    Δ_D  = sp.Δ_D  * sp.Ie_D  / Ie_D
    Δ_S  = sp.Δ_S  * sp.Ie_S  / Ie_S
    Δ_DL = sp.Δ_DL * sp.Ie_DL / Ie_DL
    # Table 9.5(b): immediate live is the full live load, not the unsustained part.
    Δ_LL = Δ_DL - Δ_D

    web = _shell_web(section)
    ρ′ = sp.cantilever ? 0.0 : ustrip(section.As_prime / (web.bw * section.d))
    λΔ = long_term_deflection_factor(Float64(ξ), ρ′)
    # R9.5.2.5: λΔ multiplies the immediate deflection of the sustained load.
    Δ_total = λΔ * Δ_S + (Δ_DL - Δ_S)

    L = sp.L * u"m"
    checks = Dict{Symbol, NamedTuple}()
    worst = 0.0
    for lim in limits
        allow = ustrip(u"m", deflection_limit(L, lim))
        Δ = lim == :immediate_ll ? Δ_LL : Δ_total
        r = Δ / allow
        worst = max(worst, r)
        checks[lim] = (Δ = Δ * u"m", limit = allow * u"m", ok = r <= 1, ratio = r)
    end
    return (Ie_D = Ie_D, Ie_S = Ie_S, Ie_DL = Ie_DL,
            Δ_D = Δ_D * u"m", Δ_S = Δ_S * u"m", Δ_DL = Δ_DL * u"m",
            Δ_LL = Δ_LL * u"m", λΔ = λΔ, Δ_total = Δ_total * u"m",
            checks = checks, ratio = worst, ok = worst <= 1)
end
