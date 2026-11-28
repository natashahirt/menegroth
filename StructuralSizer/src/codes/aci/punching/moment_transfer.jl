# ─────────────────────────────────────────────────────────────────────────────
# §13.5.3.3 — Adjusted flexural fraction of the unbalanced moment
# ─────────────────────────────────────────────────────────────────────────────

"""
    polar_moment_Jc_edge_perpendicular(b1, b2, d)

Jc of the 3-sided edge critical section for a moment about the axis
**perpendicular** to the free edge, i.e. the section's axis of symmetry.

    Jc = d b2³/12 + b2 d³/12 + 2 b1 d (b2/2)²

`b1` is the leg length perpendicular to the edge (`c1 + d/2`) and `b2` the
face parallel to it (`c2 + d`). The face along the direction of stress
variation takes its own in-plane and out-of-plane terms; the two legs take
the parallel-axis term only, the same split as `polar_moment_Jc_interior`.
The extreme fiber is `b2/2` from the centroid, which lies on the symmetry
axis, so no reaction-eccentricity shift applies on this axis.

Reference: ACI 318-11 R11.11.7.2 (corpus: aci-318-11, pages 209–211), Jc
"analogous to polar moment of inertia" of the critical section.
"""
function polar_moment_Jc_edge_perpendicular(b1::Length, b2::Length, d::Length)
    return d * b2^3 / 12 + b2 * d^3 / 12 + 2 * b1 * d * (b2 / 2)^2
end

"""
    moment_transfer_gamma_f(b1, b2, case, Vu, φVc, Mu, bb, d, fc, fy) -> (γf, provision)

Flexural fraction of one unbalanced-moment component, raised above Eq. (13-1)
where ACI 318-11 §13.5.3.3 permits it (corpus: aci-318-11, page 250).

`case`:
- `:edge_parallel` — edge column, moment about the axis parallel to the edge.
  §13.5.3.3(a): γf = 1.0 when Vu ≤ 0.75φVc.
- `:corner` — corner column, either plan axis. §13.5.3.3(a): γf = 1.0 when
  Vu ≤ 0.5φVc.
- `:interior` / `:edge_perpendicular` — §13.5.3.3(b): γf = min(1.25 γf₀, 1.0)
  when Vu ≤ 0.4φVc and εt ≥ 0.010 in the effective width `bb` (§13.5.3.2).

`Vu` is the factored direct shear at the support, excluding the shear from
moment transfer (R13.5.3.3). `φVc` is the two-way concrete strength of the
column critical section. The clause takes Vc from §11.11.2.1; callers pass the
same vc as the punching check, which with the ACI 318-19 size-effect factor
λs ≤ 1 never exceeds the §11.11.2.1 value, so the shear limits are not loosened.

The increase is permitted, not required, so it is taken only when the band
`bb` can develop γf·|Mu| as a tension-controlled section
(`required_reinforcement`, εt ≥ `tension_controlled_strain(fy)`), and for (b)
with εt ≥ 0.010 on that required steel. The final design re-checks (b)
against the steel actually placed in `bb`. When a condition fails, Eq. (13-1)
is returned.

`provision` is `:eq_13_1`, `:aci_13_5_3_3a` or `:aci_13_5_3_3b`.
"""
function moment_transfer_gamma_f(b1::Length, b2::Length, case::Symbol,
                                 Vu::Force, φVc::Force, Mu::Moment,
                                 bb::Length, d::Length, fc::Pressure, fy::Pressure)
    γf0 = gamma_f(b1, b2)
    base = (γf = γf0, provision = :eq_13_1)
    Vu_abs = abs(Vu)
    Mu_abs = abs(Mu)
    εt_tc = tension_controlled_strain(fy)
    develops(γf, εt_min) =
        isfinite(required_reinforcement(γf * Mu_abs, bb, d, fc, fy; εt_min = εt_min))

    if case === :edge_parallel || case === :corner
        limit = case === :corner ? 0.5 : 0.75
        Vu_abs <= limit * φVc || return base
        develops(1.0, εt_tc) || return base
        return (γf = 1.0, provision = :aci_13_5_3_3a)
    elseif case === :interior || case === :edge_perpendicular
        γf = min(1.25 * γf0, 1.0)
        Vu_abs <= 0.4 * φVc || return base
        develops(γf, max(0.010, εt_tc)) || return base
        return (γf = γf, provision = :aci_13_5_3_3b)
    end
    throw(ArgumentError("case must be :edge_parallel, :edge_perpendicular, :corner or :interior; got :$case"))
end

"""
    transfer_band_net_tensile_strain(As, bb, d, fc, fy) -> Float64

Net tensile strain εt of a singly reinforced band of width `bb` holding `As`:
a = As fy / (0.85 f'c bb), c = a/β₁, εt = 0.003 (d − c)/c (ACI 318-11
§10.2.7, corpus: aci-318-11, page 140). Used for the §13.5.3.3(b)
εt ≥ 0.010 condition on the steel placed in the effective width.
"""
function transfer_band_net_tensile_strain(As::Area, bb::Length, d::Length,
                                          fc::Pressure, fy::Pressure)
    a = As * fy / (0.85 * fc * bb)
    c = a / beta1(fc)
    ustrip(u"inch", c) <= 0 && return Inf
    return 0.003 * uconvert(NoUnits, (d - c) / c)
end
