# ─────────────────────────────────────────────────────────────────────────────
# Punching Shear Demand & Combined Stress
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_demand(qu, At, c1, c2, d; shape=:rectangular) → Force

Punching shear demand: Vu = qu × (At − Ac).
"""
function punching_demand(qu::Pressure, At::Area, c1::Length, c2::Length, d::Length;
                          shape::Symbol = :rectangular)
    Ac = shape == :circular ? π * (c1 + d)^2 / 4 : (c1 + d) * (c2 + d)
    return qu * (At - Ac)
end

"""
    combined_punching_stress(Vu, Mub, b0, d, γv, Jc, cAB) → Pressure

Direct + eccentric shear stress per ACI R8.4.4.2.3:

    vu = Vu/(b₀·d) + γv·Mub·cAB / Jc
"""
function combined_punching_stress(Vu::Force, Mub::Torque, b0::Length, d::Length,
                                   γv::Float64, Jc, cAB::Length)
    return Vu / (b0 * d) + γv * Mub * cAB / Jc
end

